#!/usr/bin/env bash
# nixos-deploy deploys a nixos-instantiate-generated drvPath to a target host
#
# Usage: nixos-deploy.sh <drvPath> <outPath> <targetHost> <targetPort> <buildOnTarget> <sshPrivateKey> <switch-action> <deleteOlderThan> <runGarbageCollection> [<build-opts>] ignoreme
set -euo pipefail

### Defaults ###

buildArgs=(
  --option extra-binary-caches https://cache.nixos.org/
)
profile=/nix/var/nix/profiles/system
# will be set later
sshOpts=(
  -o "ControlMaster=auto"
  -o "ControlPersist=60"
  # Avoid issues with IP re-use. This disable TOFU security.
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=/dev/null"
  -o "GlobalKnownHostsFile=/dev/null"
  # interactive authentication is not possible
  -o "BatchMode=yes"
  # verbose output for easier debugging
  -v
)

###  Argument parsing ###

drvPath="$1"
outPath="$2"
targetHost="$3"
targetPort="$4"
buildOnTarget="$5"
sshPrivateKey="$6"
action="$7"
deleteOlderThan="$8"
runGarbageCollection="$9"
shift 9

# remove the last argument
set -- "${@:1:$(($# - 1))}"
buildArgs+=("$@")

sshOpts+=( -p "${targetPort}" )

workDir=$(mktemp -d)
trap 'rm -rf "$workDir"' EXIT

if [[ -n "${sshPrivateKey}" && "${sshPrivateKey}" != "-" ]]; then
  sshPrivateKeyFile="$workDir/ssh_key"
  echo "$sshPrivateKey" > "$sshPrivateKeyFile"
  chmod 0700 "$sshPrivateKeyFile"
  sshOpts+=( -o "IdentityFile=${sshPrivateKeyFile}" )
fi

### Functions ###

log() {
  echo "--- $*" >&2
}

# Use nix-copy-closure to copy some things to the target host.
# nix-copy-closure avoids copying store objects that are already on the target
# host.  It performs well when copying large objects.
copyToTarget() {
  NIX_SSHOPTS="${sshOpts[*]}" nix-copy-closure --to "$targetHost" "$@"
}

# Use nix-store --export/--import via ssh to copy some things to the target
# host.  This removes a lot of round-trips compared to copyToTarget which is
# beneficial when copying many small store objects - such as .drv files.
exportToTarget() {
    nix-store --export $(nix-store --query --requisites "$1") |
	ssh -o Compression=yes "${sshOpts[@]}" "$targetHost" 'nix-store --import'
}

# assumes that passwordless sudo is enabled on the server
targetHostCmd() {
  # ${*@Q} escapes the arguments losslessly into space-separted quoted strings.
  # `ssh` did not properly maintain the array nature of the command line,
  # erroneously splitting arguments with internal spaces, even when using `--`.
  # Tested with OpenSSH_7.9p1.
  #
  # shellcheck disable=SC2029
  ssh "${sshOpts[@]}" "$targetHost" "./maybe-sudo.sh ${*@Q}"
}

# Setup a temporary ControlPath for this session. This speeds-up the
# operations by not re-creating SSH sessions between each command. At the end
# of the run, the session is forcefully terminated.
setupControlPath() {
  sshOpts+=(
    -o "ControlPath=$workDir/ssh_control"
  )
  cleanupControlPath() {
    local ret=$?
    # Avoid failing during the shutdown
    set +e
    # Close ssh multiplex-master process gracefully
    log "closing persistent ssh-connection"
    ssh "${sshOpts[@]}" -O stop "$targetHost"
    rm -rf "$workDir"
    exit "$ret"
  }
  trap cleanupControlPath EXIT
}

### Main ###

setupControlPath

if [[ "${buildOnTarget:-false}" == true ]]; then

  # Upload derivation
  log "uploading derivations"
  # Since derivations are small and there are likely many, use exportToTarget
  # which should be faster than copyToTarget most of the time.
  exportToTarget "$drvPath"

  # Build remotely
  log "building on target"
  set -x
  targetHostCmd "nix-store" "--realize" "$drvPath" "${buildArgs[@]}"

else

  # Build derivation
  log "building on deployer"
  outPath=$(nix-store --realize "$drvPath" "${buildArgs[@]}")

  # Upload build results
  log "uploading build results"
  # Since we are copying build outputs they are probably not all very small
  # objects so use copyToTarget which might be able to avoid copying some of
  # them.
  copyToTarget "$outPath" --gzip --use-substitutes

fi

# Activate
log "activating configuration"
targetHostCmd nix-env --profile "$profile" --set "$outPath"
targetHostCmd "$outPath/bin/switch-to-configuration" "$action"

if [[ "${runGarbageCollection:-true}" == "true" ]]; then
  # Cleanup previous generations
  log "collecting old nix derivations"
  # Deliberately not quoting $deleteOlderThan so the user can configure
  # something like "1 2 3" to keep generations with those numbers
  targetHostCmd "nix-env" "--profile" "$profile" "--delete-generations" $deleteOlderThan
  targetHostCmd "nix-store" "--gc"
fi
