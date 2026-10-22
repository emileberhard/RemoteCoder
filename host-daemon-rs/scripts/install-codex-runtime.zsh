#!/bin/zsh
set -euo pipefail

if [[ "${#}" -ne 1 ]]; then
  echo "usage: ${0:t} <codex-package-directory>" >&2
  exit 2
fi

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h:h}"
readonly package_dir="${1:A}"
readonly env_file="${RC_CODEX_GATEWAY_ENV_FILE:-${HOME}/.remote-coder/codex-gateway.env}"
readonly runtime_owner="${RC_CODEX_RUNTIME_OWNER:-${repo_root}/host-daemon-rs/target/release/remote-coder-codex-gateway}"

[[ -d "${package_dir}" && -f "${env_file}" ]] || {
  echo "Codex package or gateway environment is missing" >&2
  exit 1
}

[[ -n "${SSL_CERT_FILE:-}" && -r "${SSL_CERT_FILE}" ]] || {
  echo "SSL_CERT_FILE must inherit a readable CA bundle from the host environment" >&2
  exit 1
}

[[ -x "${runtime_owner}" ]] || {
  echo "runtime owner is missing or not executable: ${runtime_owner}" >&2
  echo "build it with 'just gateway-candidate' and pass it as RC_CODEX_RUNTIME_OWNER" >&2
  exit 1
}

exec "${runtime_owner}" --env-file "${env_file}" runtime install "${package_dir}"
