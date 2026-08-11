#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$RUNNER_TEMP/pixaeron-runtime"
install -m 700 -d "$runtime_dir"
umask 077

prepare_runtime_env() {
  local deployment="$1"
  local project compose_service ssm_path secure_parameters
  local parameters prefix key parameter_type service_env
  local name encoded_value value

  project="$(jq -r '.project' <<< "$deployment")"
  compose_service="$(jq -r '.composeService' <<< "$deployment")"
  ssm_path="$(jq -r '.ssmPath' <<< "$deployment")"
  secure_parameters="$(jq -c '.secureParameters' <<< "$deployment")"

  echo "Validating runtime configuration for $project."

  parameters="$(
    aws ssm get-parameters-by-path \
      --path "$ssm_path" \
      --recursive \
      --with-decryption \
      --query 'Parameters' \
      --output json
  )"

  prefix="$ssm_path/"
  jq -e --arg prefix "$prefix" '
    length > 0 and
    all(.[];
      (.Name | startswith($prefix)) and
      ((.Name | ltrimstr($prefix)) | test("\\A[A-Z_][A-Z0-9_]*\\z")) and
      (.Value | contains("\u0000") | not) and
      (.Value | contains("\n") | not) and
      (.Value | contains("\r") | not)
    ) and
    ([.[] | .Name | ltrimstr($prefix)] | length) ==
    ([.[] | .Name | ltrimstr($prefix)] | unique | length)
  ' <<< "$parameters" > /dev/null || {
    echo "No valid, unique environment parameters found under $ssm_path." >&2
    exit 1
  }

  while IFS= read -r key; do
    parameter_type="$(
      jq -r --arg name "$prefix$key" '
        first(.[] | select(.Name == $name) | .Type) // ""
      ' <<< "$parameters"
    )"

    if [[ "$parameter_type" != 'SecureString' ]]; then
      echo "$prefix$key must exist and use the SecureString type." >&2
      exit 1
    fi
  done < <(jq -r '.[]' <<< "$secure_parameters")

  service_env="$runtime_dir/$compose_service.env"
  : > "$service_env"

  while IFS=$'\t' read -r name encoded_value; do
    key="${name#"$prefix"}"
    value="$(printf '%s' "$encoded_value" | base64 --decode)"
    printf '%s=%s\n' "$key" "$value" >> "$service_env"
  done < <(
    jq -r 'sort_by(.Name)[] | [.Name, (.Value | @base64)] | @tsv' \
      <<< "$parameters"
  )
}

while IFS= read -r deployment; do
  prepare_runtime_env "$deployment"
done < <(jq -c '.[]' .github/deploy-services.json)

ssh -o BatchMode=yes "$VPS_USER@$VPS_HOST" \
  'install -d -m 755 /opt/pixaeron'

while IFS= read -r deployment; do
  project="$(jq -r '.project' <<< "$deployment")"
  compose_service="$(jq -r '.composeService' <<< "$deployment")"
  service_env="$runtime_dir/$compose_service.env"
  staged_env="/opt/pixaeron/$compose_service.env.next"
  live_env="/opt/pixaeron/$compose_service.env"

  scp -p -o BatchMode=yes "$service_env" \
    "$VPS_USER@$VPS_HOST:$staged_env"

  printf -v bootstrap_command \
    'if [ ! -f %q ]; then install -m 600 -- %q %q; fi' \
    "$live_env" "$staged_env" "$live_env"
  ssh -n -o BatchMode=yes "$VPS_USER@$VPS_HOST" "$bootstrap_command"

  echo "Runtime configuration for $project is ready."
done < <(jq -c '.[]' .github/deploy-services.json)
