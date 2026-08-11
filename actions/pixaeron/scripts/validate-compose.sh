#!/usr/bin/env bash
set -euo pipefail

mkdir -p .ci/certs
: > .ci/runtime.env
: > .ci/certs/global-bundle.pem

jq -r --arg runtime_env "$PWD/.ci/runtime.env" \
  '.[] | .imageTagEnv + "=validation", .runtimeEnvFileEnv + "=" + $runtime_env' \
  .github/deploy-services.json > .ci/deployment.env

compose_config="$(
  PIXAERON_CERTS_DIR="$PWD/.ci/certs" \
  docker compose --env-file .ci/deployment.env \
    -f docker-compose.production.yaml \
    config --format json
)"

while IFS=$'\t' read -r service expected_image; do
  actual_image="$(jq -r --arg service "$service" '.services[$service].image // ""' <<< "$compose_config")"
  [[ "$actual_image" == "$expected_image" ]] || {
    echo "Compose service $service must use image $expected_image; found ${actual_image:-<missing>}." >&2
    exit 1
  }
done < <(jq -r '.[] | [.composeService, (.imageName + ":validation")] | @tsv' .github/deploy-services.json)

if jq -e 'any(.[]; .project == "notifications")' \
  .github/deploy-services.json > /dev/null; then
  jq -e '
    (.networks.notifications_command.internal == true) and
    (
      [
        .services
        | to_entries[]
        | select((.value.networks // {}) | has("notifications_command"))
        | .key
      ]
      | sort
    ) == ["auth", "notifications"] and
    (
      [
        .services
        | to_entries[]
        | select((.value.networks // {}) | has("notifications_egress"))
        | .key
      ]
    ) == ["notifications"] and
    (.networks.notifications_egress.internal != true) and
    (.services.auth.environment.NOTIFICATIONS_GRPC_URL == "notifications-command:50052") and
    (.services.notifications.environment.NOTIFICATIONS_GRPC_HOST == "notifications-command") and
    (.services.notifications.networks.notifications_command.aliases == ["notifications-command"]) and
    (.services.auth.environment.NOTIFICATIONS_GRPC_DEADLINE_MS == "2000") and
    (.services.auth.environment.EMAIL_ACTION_RESPONSE_BUDGET_MS == "2500") and
    ((.services.auth.environment | has("AUTH_EMAIL_RESPONSE_BUDGET_MS")) | not) and
    ((.services.notifications.ports // []) | length == 0) and
    ((.services.auth.ports // []) | length > 0) and
    all(.services.auth.ports[]; .host_ip == "127.0.0.1") and
    ((.services.gateway.ports // []) | length > 0) and
    all(.services.gateway.ports[]; .host_ip == "127.0.0.1")
  ' <<< "$compose_config" > /dev/null || {
    echo "Notifications gRPC must bind only to its command-network alias; Notifications must own the only egress attachment and publish no host ports." >&2
    exit 1
  }
fi
