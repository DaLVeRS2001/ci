#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=actions/pixaeron/scripts/deployment-hosts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/deployment-hosts.sh"

runtime_dir="$RUNNER_TEMP/pixaeron-runtime"
[[ -d "$runtime_dir" ]] || {
  echo 'Prepared runtime environment directory is missing.' >&2
  exit 1
}

while IFS= read -r host; do
  address="$(host_address "$host")"
  compose_file="$(host_compose_file "$host")"

  scp -o BatchMode=yes "$DEPLOYMENT_SCRIPT" \
    "$VPS_USER@$address:/opt/pixaeron/deploy-service.sh"

  scp -o BatchMode=yes "$compose_file" \
    "$VPS_USER@$address:/opt/pixaeron/$compose_file.next"

  printf -v stage_command '
    set -eu
    cd /opt/pixaeron
    rm -f %q.release-rollback
    if [ -f %q ]; then
      cp -p %q %q.release-rollback
    fi
    mv -f %q.next %q
  ' "$compose_file" "$compose_file" "$compose_file" "$compose_file" \
    "$compose_file" "$compose_file"

  ssh -n -o BatchMode=yes "$VPS_USER@$address" "$stage_command"
done < <(jq -r '[.include[].host] | unique[]' <<< "$DEPLOYMENTS")

while IFS= read -r deployment; do
  project="$(jq -r '.project' <<< "$deployment")"
  host="$(jq -r '.host' <<< "$deployment")"
  deployment_order="$(jq -r '.deploymentOrder' <<< "$deployment")"
  compose_service="$(jq -r '.composeService' <<< "$deployment")"
  image_tag_env="$(jq -r '.imageTagEnv' <<< "$deployment")"
  migration_command="$(jq -r '.migrationCommand' <<< "$deployment")"
  runtime_env_file_env="$(jq -r '.runtimeEnvFileEnv' <<< "$deployment")"
  address="$(host_address "$host")"

  echo "Deploying $project to the $host host as release step $deployment_order."

  printf -v remote_command '%q ' \
    bash /opt/pixaeron/deploy-service.sh \
    "$compose_service" \
    "$image_tag_env" \
    "$IMAGE_TAG" \
    "$runtime_env_file_env" \
    "$migration_command" \
    "$(host_compose_file "$host")"

  if ! ssh -n -o BatchMode=yes "$VPS_USER@$address" "$remote_command"; then
    echo "::error title=Deployment failed::$project failed during release step $deployment_order. Review the SSH or deployment error above."
    exit 1
  fi
done < <(jq -c '.include[]' <<< "$DEPLOYMENTS")

while IFS= read -r host; do
  printf -v discard_command 'rm -f -- %q' \
    "/opt/pixaeron/$(host_compose_file "$host").release-rollback"

  if ! ssh -n -o BatchMode=yes "$VPS_USER@$(host_address "$host")" \
    "$discard_command"; then
    echo "::warning title=Baseline cleanup failed::Could not remove the release Compose baseline on the $host host."
  fi
done < <(jq -r '[.include[].host] | unique[]' <<< "$DEPLOYMENTS")
