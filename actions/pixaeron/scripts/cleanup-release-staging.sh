#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=actions/pixaeron/scripts/deployment-hosts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/deployment-hosts.sh"

if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  echo 'SSH was not configured; no remote staging cleanup is needed.'
  exit 0
fi

while IFS=$'\t' read -r host compose_service; do
  printf -v cleanup_command 'rm -f -- %q' \
    "/opt/pixaeron/$compose_service.env.next"

  if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 \
    "$VPS_USER@$(host_address "$host")" "$cleanup_command"; then
    echo "::warning title=Staging cleanup failed::Could not remove the staged $compose_service runtime environment."
  fi
done < <(jq -r '.include[] | [.host, .composeService] | @tsv' <<< "$DEPLOYMENTS")

while IFS= read -r host; do
  printf -v cleanup_command 'rm -f -- %q' \
    "/opt/pixaeron/$(host_compose_file "$host").next"

  if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 \
    "$VPS_USER@$(host_address "$host")" "$cleanup_command"; then
    echo "::warning title=Staging cleanup failed::Could not remove the staged Compose file on the $host host."
  fi
done < <(jq -r '[.include[].host] | unique[]' <<< "$DEPLOYMENTS")
