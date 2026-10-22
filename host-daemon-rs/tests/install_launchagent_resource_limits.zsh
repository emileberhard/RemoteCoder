#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h:h}"
readonly gateway_plist="${repo_root}/host-daemon-rs/launchd/com.remote-coder.codex-gateway.plist"
readonly desktop_plist="${repo_root}/host-daemon-rs/launchd/com.remote-coder.chatgpt-shared-codex.plist"

plutil -lint "${gateway_plist}" "${desktop_plist}" >/dev/null
[[ "$(plutil -extract SoftResourceLimits.NumberOfFiles raw -o - "${gateway_plist}")" == 8192 ]]
[[ "$(plutil -extract HardResourceLimits.NumberOfFiles raw -o - "${gateway_plist}")" == 8192 ]]
[[ "$(plutil -extract ProcessType raw -o - "${gateway_plist}")" == Interactive ]]
[[ "$(plutil -extract ProcessType raw -o - "${desktop_plist}")" == Standard ]]
[[ "$(plutil -extract EnvironmentVariables.RC_DESKTOP_TRIGGER raw -o - "${desktop_plist}")" == periodic ]]

echo 'LaunchAgent templates keep the resource and scheduling contract the installer verifies'
