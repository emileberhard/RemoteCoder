#!/bin/zsh
set -euo pipefail

readonly script_path="${0:A}"
readonly script_dir="${script_path:h}"
readonly repo_root="${script_dir:h:h}"
source "${script_dir}/gateway-bundle.sh"
readonly label="com.remote-coder.shared-codex-install"
readonly domain="gui/$(id -u)"
readonly job="${domain}/${label}"
readonly state_dir="${HOME}/.remote-coder/shared-codex-install"
readonly plist="${state_dir}/${label}.plist"
readonly logs_dir="${HOME}/Library/Logs/remote-coder/deployments"
readonly stdout_log="${logs_dir}/shared-codex-install.out.log"
readonly stderr_log="${logs_dir}/shared-codex-install.err.log"

runtime_matches_package() {
  local package_dir="${1}"
  local current_dir="${HOME}/.codex/packages/standalone/current"

  [[ -f "${current_dir}/codex-package.json" \
    && -x "${current_dir}/bin/codex" \
    && -x "${current_dir}/bin/codex-code-mode-host" ]] || return 1

  cmp -s "${package_dir}/codex-package.json" "${current_dir}/codex-package.json" \
    && cmp -s "${package_dir}/bin/codex" "${current_dir}/bin/codex" \
    && cmp -s \
      "${package_dir}/bin/codex-code-mode-host" \
      "${current_dir}/bin/codex-code-mode-host"
}

chatgpt_matches_release() {
  local package_dir="${1}"
  local repo_root="${2}"
  local app_path="${RC_CHATGPT_APP_PATH:-/Applications/ChatGPT.app}"
  local package_version expected_build actual_build bundled_identity bundled_codex
  local legacy_codex="${app_path}/Contents/Resources/codex"
  local packaged_codex="${app_path}/Contents/Resources/codex-cli/bin/codex"

  package_version="$(plutil -extract version raw -o - "${package_dir}/codex-package.json")" \
    || return 1
  expected_build="$(plutil -extract chatgptBuild raw -o - \
    "${repo_root}/docs/codex/compatibility.json")" || return 1
  actual_build="$(plutil -extract CFBundleShortVersionString raw -o - \
    "${app_path}/Contents/Info.plist")" || {
    echo "ChatGPT is missing or unreadable at ${app_path}" >&2
    return 1
  }
  if [[ ( -e "${legacy_codex}" || -L "${legacy_codex}" ) \
    && ( -e "${packaged_codex}" || -L "${packaged_codex}" ) ]]; then
    echo "ChatGPT bundled Codex layout is ambiguous: both official executable paths are present" >&2
    return 1
  elif [[ -e "${legacy_codex}" || -L "${legacy_codex}" ]]; then
    bundled_codex="${legacy_codex}"
  elif [[ -e "${packaged_codex}" || -L "${packaged_codex}" ]]; then
    bundled_codex="${packaged_codex}"
  else
    echo "ChatGPT bundled Codex layout is missing" >&2
    return 1
  fi
  bundled_identity="$("${bundled_codex}" --version)" \
    || return 1

  if [[ "${actual_build}" != "${expected_build}" ]]; then
    echo "ChatGPT build ${actual_build} does not match approved build ${expected_build}; update the official app before shared-stack deployment" >&2
    return 1
  fi
  if [[ "${bundled_identity}" != "codex-cli ${package_version}" ]]; then
    echo "ChatGPT bundled Codex identity '${bundled_identity}' does not match 'codex-cli ${package_version}'; update the official app before shared-stack deployment" >&2
    return 1
  fi
}

worker() {
  [[ -n "${SSL_CERT_FILE:-}" && -r "${SSL_CERT_FILE}" ]] || {
    echo "SSL_CERT_FILE must inherit a readable CA bundle from the host environment" >&2
    return 1
  }
  local package_dir="${1}"
  local gateway_bundle="${2}"
  verify_gateway_bundle "${gateway_bundle}"
  local gateway_binary="${gateway_bundle}/Contents/MacOS/${gateway_executable_name}"
  local installed_gateway="${HOME}/localbin/remote-coder-gateway/remote-coder-codex-gateway"
  local gateway_env="${RC_CODEX_GATEWAY_ENV_FILE:-${HOME}/.remote-coder/codex-gateway.env}"

  # The matched official app is part of the release. Refuse before handing
  # runtime ownership to a version Desktop cannot use.
  chatgpt_matches_release "${package_dir}" "${repo_root}"

  local current_manifest="${HOME}/.codex/packages/standalone/current/codex-package.json"
  if [[ -x "${installed_gateway}" && -f "${gateway_env}" && ! -f "${current_manifest}" ]]; then
    echo "Installed gateway has an unknown source package; refusing exact handoff before source identity is verified" >&2
    return 1
  fi
  if [[ -f "${current_manifest}" ]]; then
    local source_version
    source_version="$(plutil -extract version raw -o - "${current_manifest}")"
  fi
  if [[ -x "${installed_gateway}" && -f "${gateway_env}" ]]; then
    local configured_codex current_codex actual_version
    configured_codex="$(
      set -a
      source "${gateway_env}"
      print -r -- "${RC_CODEX_GATEWAY_CODEX_PATH:-}"
    )"
    if [[ "${configured_codex}" != */* ]]; then
      configured_codex="$(command -v "${configured_codex}" 2>/dev/null || true)"
    fi
    current_codex="${current_manifest:h}/codex"
    if [[ ! -x "${configured_codex}" || ! -x "${current_codex}" ]] \
      || ! cmp -s "${configured_codex}" "${current_codex}"; then
      echo "Installed gateway source executable differs from the approved current package; refusing handoff" >&2
      return 1
    fi
    actual_version="$("${configured_codex}" --version)" || return 1
    if [[ "${actual_version}" != "codex-cli ${source_version}" ]]; then
      echo "Installed gateway source version is not proven by the current package; refusing handoff" >&2
      return 1
    fi
  fi

  # The candidate validates the package, installed source and recovery state
  # before any service is touched. An exact installed package can finish a
  # pending swap only through install-launchagent's health-gated commit.
  local runtime_already_matches=0
  if runtime_matches_package "${package_dir}"; then
    runtime_already_matches=1
    "${gateway_binary}" --env-file "${gateway_env}" runtime install \
      "${package_dir}" \
      --check-only --check-installed
  else
    "${gateway_binary}" --env-file "${gateway_env}" runtime install \
      "${package_dir}" --check-only
  fi

  print -r -- "gatewayIdentity=$("${gateway_binary}" --version)"
  print -r -- "codexPackageManifestSha256=$(shasum -a 256 "${package_dir}/codex-package.json" | awk '{print $1}')"
  print -r -- "gatewayCandidateSha256=$(shasum -a 256 "${gateway_binary}" | awk '{print $1}')"

  if (( runtime_already_matches )); then
    echo "Codex runtime already matches the requested package; skipping replacement"
  else
    RC_CODEX_RUNTIME_OWNER="${gateway_binary}" \
      "${script_dir}/install-codex-runtime.zsh" "${package_dir}"
  fi
  "${script_dir}/install-launchagent.zsh" "${gateway_bundle}"
}

status() {
  if ! launchctl print "${job}"; then
    echo "no shared Codex install job is registered" >&2
    return 1
  fi
  print -r -- "stdout=${stdout_log}"
  print -r -- "stderr=${stderr_log}"
}

start() {
  [[ -n "${SSL_CERT_FILE:-}" && -r "${SSL_CERT_FILE}" ]] || {
    echo "SSL_CERT_FILE must inherit a readable CA bundle from the host environment" >&2
    return 1
  }
  if [[ "${#}" -ne 2 ]]; then
    echo "usage: ${0:t} start <codex-package-directory> <gateway-bundle>" >&2
    return 2
  fi

  local package_dir="${1:A}"
  local gateway_bundle="${2:A}"
  [[ -d "${package_dir}" && -f "${package_dir}/codex-package.json" ]] || {
    echo "Codex package is missing or incomplete: ${package_dir}" >&2
    return 1
  }
  verify_gateway_bundle "${gateway_bundle}"

  if launchctl print "${job}" >/dev/null 2>&1; then
    local job_state
    job_state="$(launchctl print "${job}" | sed -n 's/^[[:space:]]*state = //p' | head -n 1)"
    if [[ "${job_state}" == "running" || "${job_state}" == "xpcproxy" ]]; then
      echo "shared Codex installation is already running" >&2
      return 1
    fi
    launchctl bootout "${job}"
  fi

  mkdir -p "${state_dir}" "${logs_dir}"
  chmod 700 "${state_dir}"
  [[ ! -f "${stdout_log}" ]] || mv -f "${stdout_log}" "${stdout_log}.previous"
  [[ ! -f "${stderr_log}" ]] || mv -f "${stderr_log}" "${stderr_log}.previous"

  plutil -create xml1 "${plist}"
  plutil -insert Label -string "${label}" "${plist}"
  plutil -insert ProgramArguments -json '[]' "${plist}"
  plutil -insert ProgramArguments.0 -string "${script_path}" "${plist}"
  plutil -insert ProgramArguments.1 -string --worker "${plist}"
  plutil -insert ProgramArguments.2 -string "${package_dir}" "${plist}"
  plutil -insert ProgramArguments.3 -string "${gateway_bundle}" "${plist}"
  plutil -insert WorkingDirectory -string "${HOME}" "${plist}"
  plutil -insert EnvironmentVariables -json '{}' "${plist}"
  plutil -insert EnvironmentVariables.HOME -string "${HOME}" "${plist}"
  plutil -insert EnvironmentVariables.PATH -string "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" "${plist}"
  plutil -insert EnvironmentVariables.RC_CODEX_GATEWAY_INSTALL_OWNER -string launchd "${plist}"
  plutil -insert RunAtLoad -bool true "${plist}"
  plutil -insert KeepAlive -bool false "${plist}"
  # This short-lived job may start the canonical app-server during cutover.
  # Keep that process out of Darwin's inherited background throttle.
  plutil -insert ProcessType -string Interactive "${plist}"
  plutil -insert StandardOutPath -string "${stdout_log}" "${plist}"
  plutil -insert StandardErrorPath -string "${stderr_log}" "${plist}"
  chmod 600 "${plist}"
  plutil -lint "${plist}"

  launchctl bootstrap "${domain}" "${plist}"
  print -r -- "submitted=${job}"
  print -r -- "stdout=${stdout_log}"
  print -r -- "stderr=${stderr_log}"
}

case "${1:-}" in
  --worker)
    shift
    [[ "${#}" -eq 2 ]] || exit 2
    worker "${1}" "${2}"
    ;;
  start)
    shift
    start "${@}"
    ;;
  status)
    status
    ;;
  *)
    echo "usage: ${0:t} {start <codex-package-directory> <gateway-bundle>|status}" >&2
    exit 2
    ;;
esac
