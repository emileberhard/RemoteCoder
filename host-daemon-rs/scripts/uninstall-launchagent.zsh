#!/bin/zsh
set -euo pipefail

readonly gateway="${HOME}/localbin/remote-coder-gateway/remote-coder-codex-gateway"
readonly env_file="${HOME}/.remote-coder/codex-gateway.env"

[[ -x "${gateway}" ]] || {
  echo "the installed gateway is missing: ${gateway}" >&2
  exit 1
}

exec "${gateway}" --env-file "${env_file}" runtime uninstall
