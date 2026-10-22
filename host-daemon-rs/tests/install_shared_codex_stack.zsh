#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h:h}"
readonly source_script="${repo_root}/host-daemon-rs/scripts/install-shared-codex-stack.zsh"
readonly scratch="$(mktemp -d /tmp/remote-coder-shared-install.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT
export SSL_CERT_FILE="${scratch}/host-ca.pem"
touch "${SSL_CERT_FILE}"

export HOME="${scratch}/home"
export TEST_SHARED_INSTALL_LOG="${scratch}/install.log"
readonly mock_bin="${scratch}/bin"
readonly staged_repo="${scratch}/repo"
readonly scripts_dir="${staged_repo}/host-daemon-rs/scripts"
readonly package_dir="${scratch}/package"
readonly gateway_bundle="${scratch}/RemoteCoderGateway.app"
readonly gateway_binary="${gateway_bundle}/Contents/MacOS/remote-coder-codex-gateway"
readonly chatgpt_app="${scratch}/ChatGPT.app"
readonly legacy_codex="${chatgpt_app}/Contents/Resources/codex"
readonly packaged_codex="${chatgpt_app}/Contents/Resources/codex-cli/bin/codex"
readonly installed_gateway_dir="${HOME}/localbin/remote-coder-gateway"
readonly installed_gateway="${installed_gateway_dir}/remote-coder-codex-gateway"
readonly gateway_env="${HOME}/.remote-coder/codex-gateway.env"

write_bundled_codex() {
  local executable="${1}" body="${2}"
  mkdir -p "${executable:h}"
  printf '#!/bin/sh\nprintf called >> "%s"\n%s\n' "${scratch}/bundle-probes" "${body}" >"${executable}"
  chmod 755 "${executable}"
}

expect_bundle_rejected() {
  local case_name="${1}"
  if "${scripts_dir}/install-shared-codex-stack.zsh" \
    --worker "${package_dir}" "${gateway_bundle}" \
    >"${scratch}/${case_name}.out" 2>"${scratch}/${case_name}.err"; then
    echo "worker accepted ${case_name} official bundle" >&2
    exit 1
  fi
  [[ ! -s "${TEST_SHARED_INSTALL_LOG}" ]]
}

mkdir -p "${mock_bin}" "${scripts_dir}" "${package_dir}/bin" \
  "${staged_repo}/docs/codex" "${chatgpt_app}/Contents/Resources/codex-cli/bin" \
  "${installed_gateway_dir}" "${gateway_env:h}"
cp "${source_script}" "${scripts_dir}/install-shared-codex-stack.zsh"
cp "${repo_root}/host-daemon-rs/scripts/gateway-bundle.sh" "${scripts_dir}/"
cp -R "${repo_root}/host-daemon-rs/RemoteCoderGateway.template" "${staged_repo}/host-daemon-rs/"
cp -R "${repo_root}/host-daemon-rs/RemoteCoderGateway.template" "${gateway_bundle}"
mkdir -p "${gateway_binary:h}"
cat >"${mock_bin}/codesign" <<'EOF'
#!/bin/zsh
if [[ "${1:-}" == "--display" ]]; then
  print -r -- "Identifier=com.remote-coder.codex-gateway" >&2
  print -r -- "Format=app bundle with Mach-O thin (arm64)" >&2
fi
EOF
chmod 755 "${mock_bin}/codesign"

cat >"${mock_bin}/launchctl" <<'EOF'
#!/bin/zsh
print -r -- "launchctl $*" >>"${TEST_SHARED_INSTALL_LOG}"
EOF
cat >"${scripts_dir}/install-codex-runtime.zsh" <<'EOF'
#!/bin/zsh
print -r -- "install-codex-runtime $*" >>"${TEST_SHARED_INSTALL_LOG}"
EOF
cat >"${scripts_dir}/install-launchagent.zsh" <<'EOF'
#!/bin/zsh
print -r -- "install-launchagent $*" >>"${TEST_SHARED_INSTALL_LOG}"
EOF
cat >"${installed_gateway}" <<'EOF'
#!/bin/zsh
print -r -- "installed-gateway $*" >>"${TEST_SHARED_INSTALL_LOG}"
EOF
chmod 755 "${mock_bin}/launchctl" "${scripts_dir}"/*.zsh "${installed_gateway}"
export PATH="${mock_bin}:/usr/bin:/bin:/usr/sbin:/sbin"

print -r -- '{"version":"0.151.0-alpha.7.1"}' >"${package_dir}/codex-package.json"
print -r -- '{"chatgptBuild":"26.825.41651"}' \
  >"${staged_repo}/docs/codex/compatibility.json"
plutil -create xml1 "${chatgpt_app}/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 26.825.41651 \
  "${chatgpt_app}/Contents/Info.plist"
write_bundled_codex "${packaged_codex}" "echo 'codex-cli 0.151.0-alpha.7.1'"
cat >"${package_dir}/bin/codex" <<'EOF'
#!/bin/sh
echo 'codex-cli 0.151.0-alpha.7.1'
EOF
print -r -- '#!/bin/sh' >"${package_dir}/bin/codex-code-mode-host"
cat >"${gateway_binary}" <<'EOF'
#!/bin/zsh
print -r -- "candidate-check $*" >>"${TEST_SHARED_INSTALL_LOG}"
[[ "${TEST_CANDIDATE_REJECT:-0}" == 0 ]]
EOF
chmod 755 "${package_dir}/bin/codex" \
  "${package_dir}/bin/codex-code-mode-host" \
  "${packaged_codex}" \
  "${gateway_binary}"
export RC_CHATGPT_APP_PATH="${chatgpt_app}"
mkdir -p "${HOME}/.codex/packages/standalone/current/bin"
print -r -- '{"version":"0.151.0-alpha.7.1"}' \
  >"${HOME}/.codex/packages/standalone/current/codex-package.json"
cp "${package_dir}/bin/codex" \
  "${HOME}/.codex/packages/standalone/current/bin/codex"
ln -s bin/codex "${HOME}/.codex/packages/standalone/current/codex"
print -r -- "RC_CODEX_GATEWAY_CODEX_PATH=${HOME}/.codex/packages/standalone/current/codex" \
  >"${gateway_env}"

"${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}"

readonly check_line="$(grep -n -F 'candidate-check --env-file' "${TEST_SHARED_INSTALL_LOG}" | cut -d: -f1)"
readonly runtime_line="$(grep -n -F 'install-codex-runtime' "${TEST_SHARED_INSTALL_LOG}" | cut -d: -f1)"
readonly gateway_line="$(grep -n -F 'install-launchagent' "${TEST_SHARED_INSTALL_LOG}" | cut -d: -f1)"
! grep -F 'installed-gateway' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
grep -F "install-codex-runtime ${package_dir}" \
  "${TEST_SHARED_INSTALL_LOG}" >/dev/null
(( check_line < runtime_line && runtime_line < gateway_line ))

: >"${TEST_SHARED_INSTALL_LOG}"
export TEST_CANDIDATE_REJECT=1
if "${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}" \
  >"${scratch}/rejected-package.out" 2>"${scratch}/rejected-package.err"; then
  echo "worker prepared a handoff for a candidate-rejected package" >&2
  exit 1
fi
grep -F 'candidate-check --env-file' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
! grep -E 'launchctl|installed-gateway|install-codex-runtime' \
  "${TEST_SHARED_INSTALL_LOG}" >/dev/null
unset TEST_CANDIDATE_REJECT
: >"${TEST_SHARED_INSTALL_LOG}"
print -r -- '{"version":"0.150.0-alpha.8"}' \
  >"${HOME}/.codex/packages/standalone/current/codex-package.json"
if "${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}" \
  >"${scratch}/cross-version.out" 2>"${scratch}/cross-version.err"; then
  echo "worker accepted cross-version handoff" >&2
  exit 1
fi
grep -F 'source version is not proven' \
  "${scratch}/cross-version.err" >/dev/null
[[ ! -s "${TEST_SHARED_INSTALL_LOG}" ]]
cat >"${HOME}/.codex/packages/standalone/current/bin/codex" <<'EOF'
#!/bin/sh
echo 'codex-cli 0.150.0-alpha.8'
EOF
"${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}"
grep -F 'candidate-check --env-file' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
grep -F 'install-codex-runtime' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
! grep -F 'installed-gateway' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
: >"${TEST_SHARED_INSTALL_LOG}"
cp "${package_dir}/bin/codex" \
  "${HOME}/.codex/packages/standalone/current/bin/codex"
print -r -- '{"version":"0.151.0-alpha.7.1"}' \
  >"${HOME}/.codex/packages/standalone/current/codex-package.json"

mv "${HOME}/.codex/packages/standalone/current/codex-package.json" \
  "${scratch}/approved-manifest"
if "${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}" \
  >"${scratch}/missing-source.out" 2>"${scratch}/missing-source.err"; then
  echo "worker accepted unknown installed source package" >&2
  exit 1
fi
grep -F 'unknown source package' "${scratch}/missing-source.err" >/dev/null
[[ ! -s "${TEST_SHARED_INSTALL_LOG}" ]]
mv "${scratch}/approved-manifest" \
  "${HOME}/.codex/packages/standalone/current/codex-package.json"

cat >"${scratch}/other-codex" <<'EOF'
#!/bin/sh
echo 'codex-cli 0.150.0-alpha.8'
EOF
chmod 755 "${scratch}/other-codex"
print -r -- "RC_CODEX_GATEWAY_CODEX_PATH=${scratch}/other-codex" \
  >"${gateway_env}"
if "${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}" \
  >"${scratch}/different-source.out" 2>"${scratch}/different-source.err"; then
  echo "worker accepted a different configured source executable" >&2
  exit 1
fi
grep -F 'source executable differs' "${scratch}/different-source.err" >/dev/null
[[ ! -s "${TEST_SHARED_INSTALL_LOG}" ]]
print -r -- "RC_CODEX_GATEWAY_CODEX_PATH=${HOME}/.codex/packages/standalone/current/codex" \
  >"${gateway_env}"

# A completed runtime swap awaiting gateway health validation is still served
# by this exact package. The candidate checks that identity, then the gateway
# installer owns commit after its health and Desktop gates.
cp "${package_dir}/codex-package.json" \
  "${HOME}/.codex/packages/standalone/current/codex-package.json"
cp "${package_dir}/bin/codex-code-mode-host" \
  "${HOME}/.codex/packages/standalone/current/bin/codex-code-mode-host"
: >"${TEST_SHARED_INSTALL_LOG}"
"${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}"
grep -F -- '--check-only --check-installed' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
grep -F 'install-launchagent' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
! grep -F 'install-codex-runtime' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
: >"${TEST_SHARED_INSTALL_LOG}"

plutil -replace CFBundleShortVersionString -string 26.820.60940 \
  "${chatgpt_app}/Contents/Info.plist"
if "${scripts_dir}/install-shared-codex-stack.zsh" \
  --worker "${package_dir}" "${gateway_bundle}" \
  >"${scratch}/mismatch.out" 2>"${scratch}/mismatch.err"; then
  echo "worker accepted a mismatched ChatGPT build" >&2
  exit 1
fi
grep -F 'update the official app before shared-stack deployment' \
  "${scratch}/mismatch.err" >/dev/null
[[ ! -s "${TEST_SHARED_INSTALL_LOG}" ]]
plutil -replace CFBundleShortVersionString -string 26.825.41651 \
  "${chatgpt_app}/Contents/Info.plist"
for selected_codex in "${legacy_codex}" "${packaged_codex}"; do
  rm -f "${legacy_codex}" "${packaged_codex}"
  write_bundled_codex "${selected_codex}" "echo 'codex-cli 0.151.0-alpha.7.1'"
  "${scripts_dir}/install-shared-codex-stack.zsh" \
    --worker "${package_dir}" "${gateway_bundle}"
  grep -F 'candidate-check --env-file' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
  grep -F 'install-launchagent' "${TEST_SHARED_INSTALL_LOG}" >/dev/null
  : >"${TEST_SHARED_INSTALL_LOG}"
  for bad_probe in mismatch malformed failed unreadable dangling; do
    case "${bad_probe}" in
      mismatch) write_bundled_codex "${selected_codex}" "echo 'codex-cli 0.150.0-alpha.8'" ;;
      malformed) write_bundled_codex "${selected_codex}" "echo 'not-codex 0.151.0-alpha.7.1'" ;;
      failed) write_bundled_codex "${selected_codex}" "echo 'codex-cli 0.151.0-alpha.7.1'; exit 1" ;;
      unreadable) chmod 000 "${selected_codex}" ;;
      dangling) rm -f "${selected_codex}"; ln -s missing "${selected_codex}" ;;
    esac
    expect_bundle_rejected "${bad_probe}"
    if [[ "${bad_probe}" == mismatch || "${bad_probe}" == malformed ]]; then
      grep -F 'update the official app before shared-stack deployment' "${scratch}/${bad_probe}.err" >/dev/null
    fi
  done
done
rm -f "${legacy_codex}" "${packaged_codex}" "${scratch}/bundle-probes"
expect_bundle_rejected missing-layout
grep -F 'layout is missing' "${scratch}/missing-layout.err" >/dev/null
[[ ! -e "${scratch}/bundle-probes" ]]
write_bundled_codex "${legacy_codex}" "echo 'codex-cli 0.151.0-alpha.7.1'"
write_bundled_codex "${packaged_codex}" "echo 'codex-cli 0.151.0-alpha.7.1'"
expect_bundle_rejected ambiguous-layout
grep -F 'layout is ambiguous' "${scratch}/ambiguous-layout.err" >/dev/null
[[ ! -e "${scratch}/bundle-probes" ]]
rm -f "${legacy_codex}"
ln -s missing "${legacy_codex}"
expect_bundle_rejected ambiguous-broken-layout
grep -F 'layout is ambiguous' "${scratch}/ambiguous-broken-layout.err" >/dev/null
[[ ! -e "${scratch}/bundle-probes" ]]
rm -f "${legacy_codex}"

for action in start --worker; do
  if SSL_CERT_FILE="${scratch}/missing-ca.pem" "${scripts_dir}/install-shared-codex-stack.zsh" \
    "${action}" "${package_dir}" "${gateway_bundle}" >"${scratch}/ca-policy.err" 2>&1; then
    echo 'detached installer accepted an unreadable inherited CA bundle' >&2
    exit 1
  fi
  grep -F 'SSL_CERT_FILE must inherit a readable CA bundle' "${scratch}/ca-policy.err" >/dev/null
done

"${scripts_dir}/install-shared-codex-stack.zsh" \
  start "${package_dir}" "${gateway_bundle}"
readonly worker_plist="${HOME}/.remote-coder/shared-codex-install/com.remote-coder.shared-codex-install.plist"
[[ "$(plutil -extract ProcessType raw -o - "${worker_plist}")" == "Interactive" ]]
if plutil -extract EnvironmentVariables.SSL_CERT_FILE raw -o - "${worker_plist}" >/dev/null 2>&1; then
  echo 'detached installer must inherit host CA policy' >&2
  exit 1
fi
[[ "$(plutil -extract WorkingDirectory raw -o - "${worker_plist}")" == "${HOME}" ]]
[[ "$(plutil -extract EnvironmentVariables.RC_CODEX_GATEWAY_INSTALL_OWNER raw -o - "${worker_plist}")" == "launchd" ]]
[[ "$(plutil -extract ProcessType raw -o - \
  "${repo_root}/host-daemon-rs/launchd/com.remote-coder.codex-gateway.plist")" == "Interactive" ]]
[[ "$(plutil -extract ProcessType raw -o - \
  "${repo_root}/host-daemon-rs/launchd/com.remote-coder.chatgpt-shared-codex.plist")" == "Standard" ]]

echo 'Shared Codex installer gates the matched app, source identity and candidate before cutover'
