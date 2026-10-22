#!/bin/zsh
set -euo pipefail

readonly this_dir="$(cd -- "$(dirname -- "${0}")" && pwd)"
readonly repo_root="$(cd -- "${this_dir}/../.." && pwd)"
source "${this_dir}/gateway-bundle.sh"

readonly label="com.remote-coder.codex-gateway"
readonly desktop_label="com.remote-coder.chatgpt-shared-codex"
readonly plist_src="${repo_root}/host-daemon-rs/launchd/${label}.plist"
readonly plist_dst="${HOME}/Library/LaunchAgents/${label}.plist"
readonly desktop_plist_src="${repo_root}/host-daemon-rs/launchd/${desktop_label}.plist"
readonly desktop_plist_dst="${HOME}/Library/LaunchAgents/${desktop_label}.plist"
readonly logs_dir="${HOME}/Library/Logs/remote-coder"
readonly env_file="${HOME}/.remote-coder/codex-gateway.env"
readonly install_bin_dir="${HOME}/localbin/remote-coder-gateway"
readonly gateway_launcher_src="${repo_root}/host-daemon-rs/scripts/launch-codex-gateway.zsh"
readonly gateway_launcher="${install_bin_dir}/launch-codex-gateway"
readonly update_policy_script="${repo_root}/host-daemon-rs/scripts/manage-chatgpt-update-policy.zsh"
readonly staged_bundle="${install_bin_dir}/${gateway_bundle_name}.new.$$"
readonly staged_bin="${staged_bundle}/Contents/MacOS/${gateway_executable_name}"
readonly staged_gateway_launcher="${gateway_launcher}.new.$$"
readonly staged_plist="${plist_dst}.new.$$"
readonly staged_desktop_plist="${desktop_plist_dst}.new.$$"
readonly prebuilt_bundle="${1:-}"
readonly prebuilt_bin="${prebuilt_bundle}/Contents/MacOS/${gateway_executable_name}"

stage_claimed=false
runtime_pid=""
cleanup_staging() {
  if [[ -n "${runtime_pid}" ]]; then
    kill -TERM "${runtime_pid}" 2>/dev/null || true
    wait "${runtime_pid}" 2>/dev/null || true
  fi
  if [[ "${stage_claimed}" == true ]]; then
    "${prebuilt_bin}" runtime clear-gateway-stage --stage-id "$$"
  fi
}
trap cleanup_staging EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${logs_dir}"
mkdir -p "${install_bin_dir}"

if [[ ! -f "${env_file}" ]]; then
  echo "missing ${env_file}" >&2
  echo "create it from: ${repo_root}/host-daemon-rs/config/codex-gateway.env.example" >&2
  exit 1
fi

assert_safe_install_owner() {
  [[ "${RC_CODEX_GATEWAY_INSTALL_OWNER:-}" == "launchd" ]] && return 0

  (
    set -a
    source "${env_file}"
    set +a

    local codex_path="${RC_CODEX_GATEWAY_CODEX_PATH}"
    if [[ "${codex_path}" != */* ]]; then
      codex_path="$(command -v "${codex_path}" 2>/dev/null || true)"
    fi
    [[ -x "${codex_path}" ]] || return 0

    local daemon_version daemon_status
    daemon_version="$("${codex_path}" app-server daemon version 2>/dev/null)" || return 0
    daemon_status="$(print -rn -- "${daemon_version}" \
      | plutil -extract status raw -o - - 2>/dev/null || true)"
    [[ "${daemon_status}" == "running" ]] || return 0

    echo "refusing a synchronous gateway install while the managed app-server is running" >&2
    echo "the cutover may suspend the turn that launched this process and strand its restart fence" >&2
    echo "use 'just gateway-install' or 'just gateway-install-prebuilt <gateway>'; both submit the launchd-owned installer" >&2
    return 1
  )
}

assert_safe_install_owner

"${update_policy_script}" check


(
  set -a
  source "${env_file}"
  set +a
  readonly port_registry="${HOME}/configs/scripts/mac-mini-service-ports"
  if [[ -x "${port_registry}" ]]; then
    "${port_registry}" claim \
      remote-coder-gateway \
      "${RC_CODEX_GATEWAY_BIND_HOST:-127.0.0.1}" \
      "${RC_CODEX_GATEWAY_PORT:-8787}"
    if [[ -n "${RC_CODEX_GATEWAY_LAN_PORT:-}" ]]; then
      "${port_registry}" claim \
        remote-coder-gateway \
        0.0.0.0 \
        "${RC_CODEX_GATEWAY_LAN_PORT}"
    fi
  fi
)

if [[ -z "${prebuilt_bundle}" ]]; then
  echo "a prebuilt gateway is required; use 'just gateway-install' or 'just gateway-install-prebuilt <gateway>'" >&2
  exit 2
fi
run_with_timeout() {
  local seconds="${1}"
  shift
  perl -e 'my $seconds = shift @ARGV; alarm $seconds; exec @ARGV; die "exec failed: $!\n";' "${seconds}" "${@}"
}

# The build host signs each candidate once; installing the same bytes on every
# host keeps the privacy grants that name this identifier valid.
verify_gateway_bundle "${prebuilt_bundle}"
run_with_timeout 5 "${prebuilt_bin}" --version >/dev/null || {
  echo "gateway binary failed its smoke test" >&2
  exit 1
}

"${prebuilt_bin}" runtime prepare-gateway-stage --stage-id "$$"
stage_claimed=true

cp -R "${prebuilt_bundle}" "${staged_bundle}"
verify_gateway_bundle "${staged_bundle}"
cp "${gateway_launcher_src}" "${staged_gateway_launcher}"
chmod 755 "${staged_gateway_launcher}"
cp "${plist_src}" "${staged_plist}"
cp "${desktop_plist_src}" "${staged_desktop_plist}"
plutil -lint "${staged_plist}" >/dev/null
plutil -lint "${staged_desktop_plist}" >/dev/null
[[ "$(plutil -extract ProcessType raw -o - "${staged_plist}")" == "Interactive" ]] || {
  echo "gateway LaunchAgent must use ProcessType Interactive" >&2
  exit 1
}
[[ "$(plutil -extract ProcessType raw -o - "${staged_desktop_plist}")" == "Standard" ]] || {
  echo "Desktop helper LaunchAgent must use ProcessType Standard" >&2
  exit 1
}
# Without this the desktop journal cannot separate the five-minute check from
# a hand-run one, which is the first thing an unexpected relaunch is triaged by.
[[ "$(plutil -extract EnvironmentVariables.RC_DESKTOP_TRIGGER raw -o - "${staged_desktop_plist}")" == "periodic" ]] || {
  echo "Desktop helper LaunchAgent must declare RC_DESKTOP_TRIGGER=periodic" >&2
  exit 1
}

"${staged_bin}" --env-file "${env_file}" runtime install-gateway --stage-id "$$" &
runtime_pid="$!"
result=0
wait "${runtime_pid}" || result="$?"
runtime_pid=""
exit "${result}"
