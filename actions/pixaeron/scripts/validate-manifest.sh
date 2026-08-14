#!/usr/bin/env bash
set -euo pipefail

jq -e '
  type == "array" and
  length > 0 and
  all(.[];
    (.project | type) == "string" and
    (.project | test("\\A[A-Za-z][A-Za-z0-9_-]{0,63}\\z")) and
    (.host | type) == "string" and
    (.host == "application" or .host == "worker") and
    (.deploymentOrder | type) == "number" and
    (.deploymentOrder | floor) == .deploymentOrder and
    (.deploymentOrder >= 0) and
    (.imageName | type) == "string" and
    (.imageName | length) <= 255 and
    (.imageName | test("\\Aghcr\\.io/[a-z0-9]+([._-][a-z0-9]+)*/[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*\\z")) and
    (.dockerfile | type) == "string" and
    (.composeService | type) == "string" and
    (.composeService | test("\\A[a-z0-9][a-z0-9_-]{0,63}\\z")) and
    (.imageTagEnv | type) == "string" and
    (.imageTagEnv | test("\\A[A-Z_][A-Z0-9_]*\\z")) and
    (.ssmPath | type) == "string" and
    (.ssmPath | test("\\A/[A-Za-z0-9._/-]+\\z")) and
    (.ssmPath | contains("//") | not) and
    (.ssmPath | split("/") | index("..") | not) and
    (.ssmPath | endswith("/") | not) and
    (.secureParameters | type) == "array" and
    (.secureParameters | length) > 0 and
    all(.secureParameters[];
      type == "string" and test("\\A[A-Z_][A-Z0-9_]*\\z")
    ) and
    (.secureParameters | length) ==
    (.secureParameters | unique | length) and
    (.runtimeEnvFileEnv | type) == "string" and
    (.runtimeEnvFileEnv | test("\\A[A-Z_][A-Z0-9_]*\\z")) and
    (.migrationCommand | type) == "string" and
    (.migrationCommand | test("[[:cntrl:]]") | not)
  ) and
  ([.[].project] | length) == ([.[].project] | unique | length) and
  ([.[].deploymentOrder] | length) == ([.[].deploymentOrder] | unique | length) and
  ([.[].imageName] | length) == ([.[].imageName] | unique | length) and
  ([.[].composeService] | length) == ([.[].composeService] | unique | length) and
  ([.[].imageTagEnv] | length) == ([.[].imageTagEnv] | unique | length) and
  ([.[].ssmPath] | length) == ([.[].ssmPath] | unique | length) and
  ([.[].runtimeEnvFileEnv] | length) == ([.[].runtimeEnvFileEnv] | unique | length)
' .github/deploy-services.json > /dev/null || {
  echo "Deployment manifest has an invalid field or duplicate unique value." >&2
  exit 1
}

jq -e '
  [.[] | select(.project == "notifications")] as $notifications |
  [.[] | select(.project == "auth")] as $auth |
  ($notifications | length) == 0 or (
    ($notifications | length) == 1 and
    ($auth | length) == 1 and
    ($notifications[0].deploymentOrder < $auth[0].deploymentOrder)
  )
' .github/deploy-services.json > /dev/null || {
  echo "Notifications requires exactly one Auth service and must deploy before it." >&2
  exit 1
}

repository_root="$(pwd -P)"
while IFS= read -r dockerfile; do
  resolved_dockerfile="$(realpath -m -- "$dockerfile")"
  [[ "$resolved_dockerfile" == "$repository_root/"* && -f "$resolved_dockerfile" ]] || {
    echo "Dockerfile not found: $dockerfile" >&2
    exit 1
  }
done < <(jq -r '.[].dockerfile' .github/deploy-services.json)
