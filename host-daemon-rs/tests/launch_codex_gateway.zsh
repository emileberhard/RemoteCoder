#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h:h}"
mkdir -p "${repo_root}/host-daemon-rs/target"
readonly scratch="$(mktemp -d "${repo_root}/host-daemon-rs/target/launcher-fixture.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
export SSL_CERT_FILE="${scratch}/host-ca.pem"
touch "${SSL_CERT_FILE}"
export HOME="${scratch}/home"
readonly install_dir="${HOME}/localbin/remote-coder-gateway"
readonly env_file="${HOME}/.remote-coder/codex-gateway.env"
readonly arguments="${scratch}/arguments"
readonly ssl_cert_file="${scratch}/ssl-cert-file"
readonly launch_state="${HOME}/.remote-coder/gateway-launch-state"
mkdir -p "${install_dir}" "${env_file:h}"
cp "${repo_root}/host-daemon-rs/scripts/launch-codex-gateway.zsh" "${install_dir}/launch-codex-gateway"
cat >"${install_dir}/remote-coder-codex-gateway" <<EOF
#!/bin/zsh
print -r -- "\${*}" >${(q)arguments}
print -r -- "\${SSL_CERT_FILE:-}" >${(q)ssl_cert_file}
EOF
touch "${env_file}"
chmod 755 "${install_dir}/launch-codex-gateway" "${install_dir}/remote-coder-codex-gateway"

"${install_dir}/launch-codex-gateway"
[[ "$(<"${arguments}")" == "--env-file ${env_file}" ]]
[[ "$(<"${ssl_cert_file}")" == "${SSL_CERT_FILE}" ]]
[[ -f "${launch_state}/last-started-at" ]]

print -r -- "planned-generation" >"${launch_state}/planned-handoff"
print -r -- "$(( $(date +%s) + 1 ))" >"${launch_state}/last-started-at"
SECONDS=0
RC_CODEX_GATEWAY_RESTART_BACKOFF_SECONDS=5 "${install_dir}/launch-codex-gateway"
(( SECONDS < 2 ))
[[ ! -e "${launch_state}/planned-handoff" ]]

print -r -- "$(( $(date +%s) + 1 ))" >"${launch_state}/last-started-at"
SECONDS=0
RC_CODEX_GATEWAY_RESTART_BACKOFF_SECONDS=1 "${install_dir}/launch-codex-gateway"
(( SECONDS >= 1 ))

readonly lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly fixture_identifier="com.remote-coder.launcher-fixture.$(uuidgen)"
readonly first_bundle="${scratch}/first version/RemoteCoderGateway.app"
readonly second_bundle="${scratch}/second version/RemoteCoderGateway.app"
trap '"${lsregister}" -u "${first_bundle}" "${second_bundle}"; rm -rf "${scratch}"' EXIT
for fixture_bundle in "${first_bundle}" "${second_bundle}"; do
  mkdir -p "${fixture_bundle:h}"
  cp -R "${repo_root}/host-daemon-rs/RemoteCoderGateway.template" "${fixture_bundle}"
  mkdir -p "${fixture_bundle}/Contents/MacOS"
  plutil -replace CFBundleIdentifier -string "${fixture_identifier}" "${fixture_bundle}/Contents/Info.plist"
done
cp /usr/bin/true "${first_bundle}/Contents/MacOS/remote-coder-codex-gateway"
cp /usr/bin/false "${second_bundle}/Contents/MacOS/remote-coder-codex-gateway"
codesign --force --sign - --timestamp=none "${first_bundle}" "${second_bundle}"
"${lsregister}" -f "${first_bundle}" "${second_bundle}"

registered_fixture_bundles() {
  /usr/bin/osascript -l JavaScript - "${fixture_identifier}" <<'JXA'
ObjC.import('AppKit');
function run(arguments) {
  const urls = $.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier(arguments[0]);
  const paths = [];
  for (let index = 0; index < Number(urls.count); index++) {
    paths.push(ObjC.unwrap(urls.objectAtIndex(index).path));
  }
  return paths.sort().join('\n');
}
JXA
}

[[ "$(registered_fixture_bundles)" == "${first_bundle}"$'\n'"${second_bundle}" ]]
ln -sf "${first_bundle}/Contents/MacOS/remote-coder-codex-gateway" "${install_dir}/remote-coder-codex-gateway"
print -r -- "planned-generation" >"${launch_state}/planned-handoff"
"${install_dir}/launch-codex-gateway"
[[ "$(registered_fixture_bundles)" == "${first_bundle}" ]]

ln -sf "${second_bundle}/Contents/MacOS/remote-coder-codex-gateway" "${install_dir}/remote-coder-codex-gateway"
print -r -- "planned-generation" >"${launch_state}/planned-handoff"
if "${install_dir}/launch-codex-gateway"; then
  echo 'Gateway launcher did not execute the selected second binary' >&2
  exit 1
fi
[[ "$(registered_fixture_bundles)" == "${second_bundle}" ]]

if (unset SSL_CERT_FILE; "${install_dir}/launch-codex-gateway") >"${scratch}/ca-policy.err" 2>&1; then
  echo 'missing inherited CA policy was accepted' >&2
  exit 1
fi
grep -F 'SSL_CERT_FILE must inherit a readable CA bundle' "${scratch}/ca-policy.err" >/dev/null
if SSL_CERT_FILE="${scratch}/missing-ca.pem" "${install_dir}/launch-codex-gateway" >"${scratch}/ca-policy.err" 2>&1; then
  echo 'unreadable inherited CA policy was accepted' >&2
  exit 1
fi
grep -F 'SSL_CERT_FILE must inherit a readable CA bundle' "${scratch}/ca-policy.err" >/dev/null

echo 'Gateway launcher inherits the host CA bundle and supplies planned restart policy'
echo 'Gateway launcher keeps one LaunchServices registration across signed executable changes'
