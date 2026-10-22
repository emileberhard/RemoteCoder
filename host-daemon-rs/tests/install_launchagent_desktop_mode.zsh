#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h:h}"
readonly scratch="$(mktemp -d /tmp/remote-coder-install-handoff.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT

readonly gateway_label="com.remote-coder.codex-gateway"
readonly desktop_label="com.remote-coder.chatgpt-shared-codex"

run_install() {
  local outcome="${1}"
  local root="${scratch}/${outcome}"
  local staged_repo="${root}/repo"

  export HOME="${root}/home"
  export TEST_LOG="${root}/calls.log"
  export TEST_OUTCOME="${outcome}"
  export TEST_SIGNED_FORMAT="${3:-app bundle with Mach-O thin (arm64)}"
  export TEST_SIGNED_IDENTIFIER="${2:-${gateway_label}}"
  export TEST_REPO="${repo_root}"

  mkdir -p "${staged_repo}/host-daemon-rs/scripts" "${staged_repo}/host-daemon-rs/launchd" \
    "${HOME}/.remote-coder" "${HOME}/Library/LaunchAgents" "${HOME}/localbin/remote-coder-gateway"
  : >"${TEST_LOG}"

  cp "${repo_root}/host-daemon-rs/scripts/install-launchagent.zsh" \
    "${repo_root}/host-daemon-rs/scripts/launch-codex-gateway.zsh" \
    "${repo_root}/host-daemon-rs/scripts/gateway-bundle.sh" \
    "${staged_repo}/host-daemon-rs/scripts/"
  cp "${repo_root}/host-daemon-rs/launchd/${gateway_label}.plist" \
    "${repo_root}/host-daemon-rs/launchd/${desktop_label}.plist" \
    "${staged_repo}/host-daemon-rs/launchd/"
  cat >"${staged_repo}/host-daemon-rs/scripts/manage-chatgpt-update-policy.zsh" <<'EOF'
#!/bin/zsh
exit 0
EOF

  cp -R "${repo_root}/host-daemon-rs/RemoteCoderGateway.template" "${staged_repo}/host-daemon-rs/"
  cp -R "${repo_root}/host-daemon-rs/RemoteCoderGateway.template" "${root}/RemoteCoderGateway.app"
  mkdir -p "${root}/RemoteCoderGateway.app/Contents/MacOS" "${root}/RemoteCoderGateway.app/Contents/_CodeSignature"
  print -r -- sealed >"${root}/RemoteCoderGateway.app/Contents/_CodeSignature/CodeResources"
  cat >"${root}/RemoteCoderGateway.app/Contents/MacOS/remote-coder-codex-gateway" <<'EOF'
#!/bin/zsh
[[ "${1:-}" == "--version" ]] && exit 0
[[ "${1:-}" == "--env-file" ]] && shift 2
print -r -- "${0:t} $*" >>"${TEST_LOG}"
[[ "$*" == "runtime prepare-gateway-stage --stage-id "<-> ]] && exit 0
if [[ "$*" == "runtime clear-gateway-stage --stage-id "<-> ]]; then
  suffix="${@[-1]}"
  rm -rf "${HOME}/localbin/remote-coder-gateway/RemoteCoderGateway.app.new.${suffix}"
  rm -f \
    "${HOME}/localbin/remote-coder-gateway/launch-codex-gateway.new.${suffix}" \
    "${HOME}/Library/LaunchAgents/com.remote-coder.codex-gateway.plist.new.${suffix}" \
    "${HOME}/Library/LaunchAgents/com.remote-coder.chatgpt-shared-codex.plist.new.${suffix}"
  exit 0
fi
[[ "$*" == "runtime install-gateway --stage-id "<-> ]] || exit 64
readonly stage_id="${@[-1]}"
readonly bin_dir="${HOME}/localbin/remote-coder-gateway"
[[ "${0}" == "${bin_dir}/RemoteCoderGateway.app.new.${stage_id}/Contents/MacOS/remote-coder-codex-gateway" ]] || exit 65
for member in Contents/Info.plist Contents/_CodeSignature/CodeResources; do
  cmp -s "${0:A:h:h:h}/${member}" "${TEST_CANDIDATE}/${member}" || exit 68
done
cmp -s "${TEST_REPO}/host-daemon-rs/scripts/launch-codex-gateway.zsh" \
  "${bin_dir}/launch-codex-gateway.new.${stage_id}" || exit 66
for label in com.remote-coder.codex-gateway com.remote-coder.chatgpt-shared-codex; do
  cmp -s "${TEST_REPO}/host-daemon-rs/launchd/${label}.plist" \
    "${HOME}/Library/LaunchAgents/${label}.plist.new.${stage_id}" || exit 67
done
[[ "${TEST_OUTCOME}" == success ]]
EOF
  mkdir -p "${root}/bin"
  cat >"${root}/bin/codesign" <<'EOF'
#!/bin/zsh
if [[ "${1:-}" == "--display" ]]; then
  print -r -- "Identifier=${TEST_SIGNED_IDENTIFIER}" >&2
  print -r -- "Format=${TEST_SIGNED_FORMAT}" >&2
fi
exit 0
EOF
  chmod 755 "${staged_repo}/host-daemon-rs/scripts/"*.zsh "${root}/RemoteCoderGateway.app/Contents/MacOS/remote-coder-codex-gateway" "${root}/bin/codesign"

  cat >"${HOME}/.remote-coder/codex-gateway.env" <<EOF
RC_CODEX_GATEWAY_BIND_HOST=127.0.0.1
RC_CODEX_GATEWAY_PORT=18787
RC_CODEX_GATEWAY_AUTH_TOKEN=test-token
RC_CODEX_GATEWAY_CODEX_PATH=${root}/codex
EOF

  export TEST_CANDIDATE="${root}/RemoteCoderGateway.app"
  if [[ "${outcome}" == flat ]]; then
    cp "${TEST_CANDIDATE}/Contents/MacOS/remote-coder-codex-gateway" "${root}/gateway"
    TEST_CANDIDATE="${root}/gateway"
  fi
  PATH="${root}/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    RC_CODEX_GATEWAY_INSTALL_OWNER=launchd \
    "${staged_repo}/host-daemon-rs/scripts/install-launchagent.zsh" "${TEST_CANDIDATE}" \
    >"${root}/stdout.log" 2>"${root}/stderr.log"
}

run_install success
[[ "$(wc -l <"${scratch}/success/calls.log" | tr -d ' ')" == 3 ]]
grep -Eq -- "^remote-coder-codex-gateway runtime install-gateway --stage-id [0-9]+$" \
  "${scratch}/success/calls.log"
[[ -z "$(ls "${scratch}/success/home/localbin/remote-coder-gateway")" ]]
[[ -z "$(ls "${scratch}/success/home/Library/LaunchAgents")" ]]

if run_install failure; then
  echo "installer ignored a failed gateway transaction" >&2
  exit 1
fi
[[ -z "$(ls "${scratch}/failure/home/localbin/remote-coder-gateway")" ]]
[[ -z "$(ls "${scratch}/failure/home/Library/LaunchAgents")" ]]

if run_install foreign com.example.other; then
  echo "installer accepted a gateway signed with another identifier" >&2
  exit 1
fi
[[ ! -s "${scratch}/foreign/calls.log" ]]
[[ -z "$(ls "${scratch}/foreign/home/localbin/remote-coder-gateway")" ]]

if run_install flat; then
  echo "installer accepted a flat gateway binary" >&2
  exit 1
fi
grep -F 'must be an app bundle' "${scratch}/flat/stderr.log" >/dev/null
[[ ! -s "${scratch}/flat/calls.log" ]]

if run_install unbundled "${gateway_label}" 'Mach-O thin (arm64)'; then
  echo "installer accepted a non-bundle signature" >&2
  exit 1
fi
grep -F 'not signed as an app bundle' "${scratch}/unbundled/stderr.log" >/dev/null
[[ ! -s "${scratch}/unbundled/calls.log" ]]

echo "Gateway installer verifies the build-host signature, stages its files and hands the cutover to the Rust transaction"
