#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h:h}"
readonly scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
export SSL_CERT_FILE="${scratch}/host-ca.pem"
touch "${SSL_CERT_FILE}"
export HOME="${scratch}/home"
readonly env_file="${HOME}/.remote-coder/codex-gateway.env"
readonly package="${scratch}/package"
readonly canonical_package="${package:A}"
readonly owner="${scratch}/runtime-owner"
readonly arguments="${scratch}/arguments"
readonly ssl_cert_file="${scratch}/ssl-cert-file"
mkdir -p "${env_file:h}" "${package}"
touch "${env_file}"
cat >"${owner}" <<EOF
#!/bin/zsh
print -r -- "\${*}" >${(q)arguments}
print -r -- "\${SSL_CERT_FILE:-}" >${(q)ssl_cert_file}
EOF
chmod 755 "${owner}"
RC_CODEX_RUNTIME_OWNER="${owner}" \
  "${repo_root}/host-daemon-rs/scripts/install-codex-runtime.zsh" \
  "${package}"
[[ "$(<"${arguments}")" == \
  "--env-file ${env_file} runtime install ${canonical_package}" ]]
[[ "$(<"${ssl_cert_file}")" == "${SSL_CERT_FILE}" ]]

if RC_CODEX_RUNTIME_OWNER="${scratch}/missing-owner" \
  "${repo_root}/host-daemon-rs/scripts/install-codex-runtime.zsh" \
  "${package}" >/dev/null 2>&1; then
  echo 'runtime installer accepted a missing runtime owner' >&2
  exit 1
fi

if (unset SSL_CERT_FILE; RC_CODEX_RUNTIME_OWNER="${owner}" "${repo_root}/host-daemon-rs/scripts/install-codex-runtime.zsh" "${package}") >"${scratch}/ca-policy.err" 2>&1; then
  echo 'missing inherited CA policy was accepted' >&2
  exit 1
fi
grep -F 'SSL_CERT_FILE must inherit a readable CA bundle' "${scratch}/ca-policy.err" >/dev/null
if SSL_CERT_FILE="${scratch}/missing-ca.pem" RC_CODEX_RUNTIME_OWNER="${owner}" "${repo_root}/host-daemon-rs/scripts/install-codex-runtime.zsh" "${package}" >"${scratch}/ca-policy.err" 2>&1; then
  echo 'unreadable inherited CA policy was accepted' >&2
  exit 1
fi
grep -F 'SSL_CERT_FILE must inherit a readable CA bundle' "${scratch}/ca-policy.err" >/dev/null

echo 'Codex runtime installer inherits the host CA bundle'
echo 'Codex runtime installer requires a prebuilt runtime owner'
