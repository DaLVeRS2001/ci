#!/usr/bin/env bash
set -euo pipefail

mkdir -p .ci/certs
: > .ci/runtime.env
: > .ci/certs/global-bundle.pem

jq -r --arg runtime_env "$PWD/.ci/runtime.env" \
  '.[] | .imageTagEnv + "=validation", .runtimeEnvFileEnv + "=" + $runtime_env' \
  .github/deploy-services.json > .ci/deployment.env

# shellcheck source=actions/pixaeron/scripts/deployment-hosts.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/deployment-hosts.sh"

host_compose_config() {
  local compose_file
  compose_file="$(host_compose_file "$1")"

  PIXAERON_CERTS_DIR="$PWD/.ci/certs" \
    docker compose --env-file .ci/deployment.env \
      -f "$compose_file" \
      config --format json
}

while IFS= read -r host; do
  host_config="$(host_compose_config "$host")"

  while IFS=$'\t' read -r service expected_image; do
    actual_image="$(jq -r --arg service "$service" '.services[$service].image // ""' <<< "$host_config")"
    [[ "$actual_image" == "$expected_image" ]] || {
      echo "Compose service $service must use image $expected_image on the $host host; found ${actual_image:-<missing>}." >&2
      exit 1
    }
  done < <(
    jq -r --arg host "$host" \
      '.[] | select(.host == $host) | [.composeService, (.imageName + ":validation")] | @tsv' \
      .github/deploy-services.json
  )
done < <(jq -r '[.[].host] | unique[]' .github/deploy-services.json)

if jq -e 'any(.[]; .project == "notifications")' \
  .github/deploy-services.json > /dev/null; then
  compose_config="$(host_compose_config application)"

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

if jq -e 'any(.[]; .project == "conversion-api")' \
  .github/deploy-services.json > /dev/null; then
  conversion_config="$(host_compose_config application)"

  jq -e '
    (.networks.entitlements_command.internal == true) and
    (
      [
        .services
        | to_entries[]
        | select((.value.networks // {}) | has("entitlements_command"))
        | .key
      ]
      | sort
    ) == ["auth", "conversion-api"] and
    (.services.auth.networks.entitlements_command.aliases == ["auth-entitlements"]) and
    (.services.auth.environment.ENTITLEMENTS_GRPC_HOST == "auth-entitlements") and
    (.services["conversion-api"].environment.ENTITLEMENTS_GRPC_URL == "auth-entitlements:50053") and
    ((.services["conversion-api"].ports // []) | length == 0)
  ' <<< "$conversion_config" > /dev/null || {
    echo "Conversion API must reach Auth only over the internal entitlements_command network by its alias, and must publish no host port." >&2
    exit 1
  }
fi

if jq -e 'any(.[]; .project == "conversion-worker")' \
  .github/deploy-services.json > /dev/null; then
  worker_config="$(host_compose_config worker)"

  jq -e '
    (.services["conversion-worker"].read_only == true) and
    (.services["conversion-worker"].cap_drop == ["ALL"]) and
    (.services["conversion-worker"].security_opt == ["no-new-privileges:true"]) and
    ((.services["conversion-worker"].ports // []) | length == 0) and
    ((.services["conversion-worker"].healthcheck.test // []) | length > 0)
  ' <<< "$worker_config" > /dev/null || {
    echo "The conversion worker must run read-only without capabilities, privilege escalation, published ports, or a missing health check." >&2
    exit 1
  }
fi
