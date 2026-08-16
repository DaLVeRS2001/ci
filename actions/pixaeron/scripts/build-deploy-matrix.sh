#!/usr/bin/env bash
set -euo pipefail

workspace_projects="$(npx nx show projects --json)"
jq -e --argjson workspace_projects "$workspace_projects" '
  all(.[];
    .project as $project |
    ($workspace_projects | index($project)) != null
  )
' .github/deploy-services.json > /dev/null || {
  echo 'Deployment manifest contains an unknown Nx project.' >&2
  exit 1
}

if [[ "$GITHUB_EVENT_NAME" != "workflow_dispatch" ]]; then
  affected="$(npx nx show projects --affected --json)"
fi

if [[ "$GITHUB_EVENT_NAME" == "pull_request" ]]; then
  selected='[]'
elif [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then
  if [[ "$SERVICE_INPUT" == "all" ]]; then
    selected="$(jq -c '.' .github/deploy-services.json)"
  else
    selected="$(jq -c --arg project "$SERVICE_INPUT" \
      '[.[] | select(.project == $project)]' \
      .github/deploy-services.json)"
  fi
else
  selected="$(jq -c --argjson affected "$affected" \
    '[.[] | select(.project as $project | ($affected | index($project)))]' \
    .github/deploy-services.json)"
fi

subgraph_projects="$(npx nx show projects --type app --withTarget schema-check --json)"
subgraphs='[]'
composed_schemas="$(
  grep -E '^[[:space:]]*file:' apps/gateway/supergraph.yaml |
    sed -E 's/.*file:[[:space:]]*//' |
    while IFS= read -r relative; do
      realpath -m --relative-to=. "apps/gateway/$relative"
    done
)"

while IFS= read -r project; do
  [[ "$project" =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]] || {
    echo "Nx project name is not a valid GraphOS subgraph name: $project" >&2
    exit 1
  }

  project_config="$(npx nx show project "$project" --json)"
  jq -e '.targets["schema-export"] != null' <<< "$project_config" > /dev/null || {
    echo "GraphQL subgraph project is missing the schema-export target: $project" >&2
    exit 1
  }

  project_root="$(jq -r '.root // empty' <<< "$project_config")"
  [[ -n "$project_root" ]] || {
    echo "Nx project has no root: $project" >&2
    exit 1
  }

  schema="$project_root/schema.graphql"
  [[ -f "$schema" ]] || {
    echo "GraphQL subgraph schema not found: $schema" >&2
    exit 1
  }
  git ls-files --error-unmatch "$schema" > /dev/null || {
    echo "GraphQL subgraph schema must be committed: $schema" >&2
    exit 1
  }

  if ! grep -qxF "$schema" <<< "$composed_schemas"; then
    echo "GraphQL subgraph $project is not in the Gateway composition yet; excluded from the deployment matrix."
    continue
  fi

  grep -qE "^[[:space:]]+${project}:[[:space:]]*$" apps/gateway/supergraph.yaml || {
    echo "GraphQL subgraph $project is composed under a different key in apps/gateway/supergraph.yaml. The composed name reaches the router, which keys header propagation and error exposure by it, while GraphOS is published under the project name." >&2
    exit 1
  }

  subgraphs="$(
    jq -c \
      --arg project "$project" \
      --arg name "$project" \
      --arg schema "$schema" \
      '. + [{ project: $project, name: $name, schema: $schema }]' \
      <<< "$subgraphs"
  )"
done < <(jq -r '.[]' <<< "$subgraph_projects")

gateway_count="$(jq '[.[] | select(.project == "gateway")] | length' .github/deploy-services.json)"
[[ "$gateway_count" == "1" ]] || {
  echo 'Deployment manifest must contain exactly one Gateway row.' >&2
  exit 1
}
gateway_order="$(jq -r '.[] | select(.project == "gateway") | .deploymentOrder' .github/deploy-services.json)"

while IFS= read -r project; do
  deployment_count="$(
    jq --arg project "$project" '[.[] | select(.project == $project)] | length' .github/deploy-services.json
  )"
  [[ "$deployment_count" == "1" ]] || {
    echo "GraphQL subgraph must have exactly one deployment manifest row: $project" >&2
    exit 1
  }

  deployment_order="$(
    jq -r --arg project "$project" '.[] | select(.project == $project) | .deploymentOrder' .github/deploy-services.json
  )"
  (( deployment_order < gateway_order )) || {
    echo "GraphQL subgraph $project must deploy before Gateway." >&2
    exit 1
  }
done < <(jq -r '.[].project' <<< "$subgraphs")

if [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then
  if [[ "$SERVICE_INPUT" == "all" ]]; then
    selected_subgraphs="$subgraphs"
  else
    selected_subgraphs="$(jq -c --arg project "$SERVICE_INPUT" '[.[] | select(.project == $project)]' <<< "$subgraphs")"
  fi
else
  selected_subgraphs="$(jq -c --argjson affected "$affected" '[.[] | select(.project as $project | ($affected | index($project)))]' <<< "$subgraphs")"
fi

if [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" && "$SERVICE_INPUT" != "all" ]]; then
  if [[ "$SERVICE_INPUT" == "gateway" ]] ||
    jq -e 'length > 0' <<< "$selected_subgraphs" > /dev/null; then
    echo 'A subgraph or Gateway release must use service=all so the static supergraph stays aligned.' >&2
    exit 1
  fi
fi

if [[ "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "workflow_dispatch" ]]; then
  changed_subgraphs=0
  while IFS= read -r schema; do
    git diff --quiet "$NX_BASE" "$NX_HEAD" -- "$schema" ||
      changed_subgraphs=$((changed_subgraphs + 1))
  done < <(jq -r '.[].schema' <<< "$selected_subgraphs")

  (( changed_subgraphs < 2 )) || {
    echo 'Releases changing more than one subgraph schema require one batch GraphOS publishSubgraphs operation.' >&2
    exit 1
  }
fi

if [[ "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "workflow_dispatch" ]] &&
  jq -e 'length > 0' <<< "$selected_subgraphs" > /dev/null; then
  selected="$(jq -c --argjson selected "$selected" '
    ($selected | map(.project) + ["gateway"] | unique) as $projects |
    [.[] | select(.project as $project | $projects | index($project))]
  ' .github/deploy-services.json)"
fi

selected="$(jq -c 'sort_by(.deploymentOrder)' <<< "$selected")"

{
  echo '### Deployment selection'
  echo
  echo "- event \`$GITHUB_EVENT_NAME\` on \`$GITHUB_REF\`, service input \`$SERVICE_INPUT\`"
  echo "- services: \`$(jq -c 'map(.project)' <<< "$selected")\`"
  echo "- subgraphs: \`$(jq -c 'map(.project)' <<< "$selected_subgraphs")\`"
} >> "$GITHUB_STEP_SUMMARY"

deploy_matrix="$(jq -cn --argjson include "$selected" '{include: $include}')"
subgraph_matrix="$(jq -cn --argjson include "$selected_subgraphs" '{include: $include}')"
echo "matrix=$deploy_matrix" >> "$GITHUB_OUTPUT"
echo "subgraph_matrix=$subgraph_matrix" >> "$GITHUB_OUTPUT"

if jq -e 'length > 0' <<< "$selected" > /dev/null; then
  echo "has_deployments=true" >> "$GITHUB_OUTPUT"
else
  echo "has_deployments=false" >> "$GITHUB_OUTPUT"
fi

if jq -e 'length > 0' <<< "$selected_subgraphs" > /dev/null && [[ "$TRUSTED_GRAPHOS_RUN" == "true" ]]; then
  echo "graphos_check_required=true" >> "$GITHUB_OUTPUT"
else
  echo "graphos_check_required=false" >> "$GITHUB_OUTPUT"
fi
