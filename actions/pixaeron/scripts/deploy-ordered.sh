#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$RUNNER_TEMP/pixaeron-runtime"
[[ -d "$runtime_dir" ]] || {
  echo 'Prepared runtime environment directory is missing.' >&2
  exit 1
}

scp -o BatchMode=yes "$DEPLOYMENT_SCRIPT" \
  "$VPS_USER@$VPS_HOST:/opt/pixaeron/deploy-service.sh"

scp -o BatchMode=yes docker-compose.production.yaml \
  "$VPS_USER@$VPS_HOST:/opt/pixaeron/docker-compose.production.yaml.next"

ssh -n -o BatchMode=yes "$VPS_USER@$VPS_HOST" '
  set -eu
  cd /opt/pixaeron
  rm -f docker-compose.production.yaml.release-rollback
  if [ -f docker-compose.production.yaml ]; then
    cp -p docker-compose.production.yaml docker-compose.production.yaml.release-rollback
  fi
  mv -f docker-compose.production.yaml.next docker-compose.production.yaml
'

while IFS= read -r deployment; do
  project="$(jq -r '.project' <<< "$deployment")"
  deployment_order="$(jq -r '.deploymentOrder' <<< "$deployment")"
  compose_service="$(jq -r '.composeService' <<< "$deployment")"
  image_tag_env="$(jq -r '.imageTagEnv' <<< "$deployment")"
  migration_command="$(jq -r '.migrationCommand' <<< "$deployment")"
  runtime_env_file_env="$(jq -r '.runtimeEnvFileEnv' <<< "$deployment")"

  echo "Deploying $project as release step $deployment_order."

  printf -v remote_command '%q ' \
    bash /opt/pixaeron/deploy-service.sh \
    "$compose_service" \
    "$image_tag_env" \
    "$IMAGE_TAG" \
    "$runtime_env_file_env" \
    "$migration_command"

  if ! ssh -n -o BatchMode=yes "$VPS_USER@$VPS_HOST" "$remote_command"; then
    echo "::error title=Deployment failed::$project failed during release step $deployment_order. Review the SSH or deployment error above."
    exit 1
  fi
done < <(jq -c '.include[]' <<< "$DEPLOYMENTS")
