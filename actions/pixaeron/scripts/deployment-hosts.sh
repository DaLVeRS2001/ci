#!/usr/bin/env bash

host_address() {
  case "$1" in
    application) printf '%s' "$VPS_HOST" ;;
    worker) printf '%s' "$WORKER_VPS_HOST" ;;
    *)
      echo "Unknown deployment host: $1" >&2
      exit 1
      ;;
  esac
}

host_compose_file() {
  case "$1" in
    application) printf '%s' 'docker-compose.production.yaml' ;;
    worker) printf '%s' 'docker-compose.worker.yaml' ;;
    *)
      echo "Unknown deployment host: $1" >&2
      exit 1
      ;;
  esac
}
