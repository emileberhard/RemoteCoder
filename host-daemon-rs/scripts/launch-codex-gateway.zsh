#!/bin/zsh
set -euo pipefail

readonly install_dir="${0:A:h}"
readonly gateway="${install_dir}/remote-coder-codex-gateway"
readonly env_file="${1:-${HOME}/.remote-coder/codex-gateway.env}"
readonly state_dir="${HOME}/.remote-coder/gateway-launch-state"
readonly last_start_file="${state_dir}/last-started-at"
readonly planned_handoff_file="${state_dir}/planned-handoff"
readonly restart_backoff_seconds="${RC_CODEX_GATEWAY_RESTART_BACKOFF_SECONDS:-60}"

[[ -x "${gateway}" && -f "${env_file}" ]] || {
  echo "incomplete RemoteCoder gateway installation" >&2
  exit 1
}
[[ "${restart_backoff_seconds}" == <-> && "${restart_backoff_seconds}" -gt 0 ]] || {
  echo "gateway restart backoff must be a positive integer" >&2
  exit 1
}

[[ -n "${SSL_CERT_FILE:-}" && -r "${SSL_CERT_FILE}" ]] || {
  echo "SSL_CERT_FILE must inherit a readable CA bundle from the host environment" >&2
  exit 1
}

mkdir -p "${state_dir}"
chmod 700 "${state_dir}"

planned_handoff=false
[[ ! -f "${planned_handoff_file}" ]] || planned_handoff=true
rm -f "${planned_handoff_file}"

now="$(date +%s)"
if [[ "${planned_handoff}" != true && -f "${last_start_file}" ]]; then
  last_start="$(<"${last_start_file}")"
  if [[ "${last_start}" == <-> ]]; then
    elapsed=$(( now - last_start ))
    (( elapsed >= 0 )) || elapsed=0
    remaining=$(( restart_backoff_seconds - elapsed ))
    (( remaining <= 0 )) || sleep "${remaining}"
  fi
fi

now="$(date +%s)"
last_start_staged="${last_start_file}.$$"
print -r -- "${now}" >"${last_start_staged}"
chmod 600 "${last_start_staged}"
mv -f "${last_start_staged}" "${last_start_file}"


readonly gateway_executable="${gateway:A}"
readonly gateway_bundle="${gateway_executable:h:h:h}"
if [[ -f "${gateway_bundle}/Contents/Info.plist" ]]; then
  readonly lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  gateway_bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "${gateway_bundle}/Contents/Info.plist")"
  registered_bundles="$(/usr/bin/osascript -l JavaScript - "${gateway_bundle_identifier}" <<'JXA'
ObjC.import('AppKit');
function run(arguments) {
  const urls = $.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier(arguments[0]);
  const paths = [];
  for (let index = 0; index < Number(urls.count); index++) {
    paths.push(ObjC.unwrap(urls.objectAtIndex(index).path));
  }
  return paths.join('\n');
}
JXA
)"
  for registered_bundle in "${(@f)registered_bundles}"; do
    [[ -n "${registered_bundle}" && "${registered_bundle}" != "${gateway_bundle}" ]] || continue
    "${lsregister}" -u "${registered_bundle}"
  done
  "${lsregister}" -f "${gateway_bundle}"
fi

exec "${gateway_executable}" --env-file "${env_file}"
