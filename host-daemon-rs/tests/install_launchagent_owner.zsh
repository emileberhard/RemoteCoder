#!/bin/zsh
set -euo pipefail
unset RC_CODEX_GATEWAY_INSTALL_OWNER

readonly repo_root="${0:A:h:h:h}"
readonly source_script="${repo_root}/host-daemon-rs/scripts/install-launchagent.zsh"
readonly scratch="$(mktemp -d /tmp/remote-coder-install-owner.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT

export HOME="${scratch}/home"
readonly staged_repo="${scratch}/repo"
readonly scripts_dir="${staged_repo}/host-daemon-rs/scripts"
readonly fake_codex="${scratch}/bin/codex"
readonly env_file="${HOME}/.remote-coder/codex-gateway.env"
readonly stderr_file="${scratch}/stderr.log"

mkdir -p "${scripts_dir}" "${fake_codex:h}" "${env_file:h}"
cp "${source_script}" "${scripts_dir}/install-launchagent.zsh"
cp "${repo_root}/host-daemon-rs/scripts/gateway-bundle.sh" "${scripts_dir}/"
cp -R "${repo_root}/host-daemon-rs/RemoteCoderGateway.template" "${staged_repo}/host-daemon-rs/"

cat >"${fake_codex}" <<'EOF'
#!/bin/zsh
if [[ "${1:-}" == "app-server" && "${2:-}" == "daemon" && "${3:-}" == "version" ]]; then
  print -r -- '{"status":"running","pid":42}'
  exit 0
fi
exit 1
EOF
chmod 755 "${fake_codex}" "${scripts_dir}/install-launchagent.zsh"
print -r -- "RC_CODEX_GATEWAY_CODEX_PATH=${fake_codex}" >"${env_file}"

if "${scripts_dir}/install-launchagent.zsh" >/dev/null 2>"${stderr_file}"; then
  echo "live synchronous install unexpectedly succeeded" >&2
  exit 1
fi
grep -F "refusing a synchronous gateway install" "${stderr_file}" >/dev/null
grep -F "just gateway-install-prebuilt" "${stderr_file}" >/dev/null

cat >"${scripts_dir}/manage-chatgpt-update-policy.zsh" <<'EOF'
#!/bin/zsh
exit 42
EOF
chmod 755 "${scripts_dir}/manage-chatgpt-update-policy.zsh"

set +e
RC_CODEX_GATEWAY_INSTALL_OWNER=launchd \
  "${scripts_dir}/install-launchagent.zsh" >/dev/null 2>"${stderr_file}"
readonly detached_status=$?
set -e
[[ "${detached_status}" -eq 42 ]]
! grep -F "refusing a synchronous gateway install" "${stderr_file}" >/dev/null

echo "Gateway installer requires the launchd owner for a live cutover"
