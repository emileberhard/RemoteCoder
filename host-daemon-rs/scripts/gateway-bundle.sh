gateway_bundle_source="${repo_root}/host-daemon-rs/RemoteCoderGateway.template"
gateway_bundle_name="${gateway_bundle_source##*/}"
gateway_bundle_name="${gateway_bundle_name%.template}.app"
gateway_executable_name="$(plutil -extract CFBundleExecutable raw -o - "${gateway_bundle_source}/Contents/Info.plist")"
gateway_bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "${gateway_bundle_source}/Contents/Info.plist")"

verify_gateway_bundle() {
  local bundle="${1}" details
  [[ -d "${bundle}" && -f "${bundle}/Contents/Info.plist" \
    && -x "${bundle}/Contents/MacOS/${gateway_executable_name}" ]] || {
    echo "gateway candidate must be an app bundle: ${bundle}" >&2
    return 1
  }
  [[ "$(plutil -extract CFBundleExecutable raw -o - "${bundle}/Contents/Info.plist")" == "${gateway_executable_name}" \
    && "$(plutil -extract CFBundleIdentifier raw -o - "${bundle}/Contents/Info.plist")" == "${gateway_bundle_identifier}" ]] || {
    echo "gateway bundle metadata does not match its identity" >&2
    return 1
  }
  codesign --verify --strict "${bundle}" || {
    echo "gateway bundle has no valid code signature; build it with 'just gateway-candidate'" >&2
    return 1
  }
  details="$(codesign --display --verbose=1 "${bundle}" 2>&1)" || return 1
  [[ "$(printf '%s\n' "${details}" | sed -n 's/^Identifier=//p')" == "${gateway_bundle_identifier}" ]] || {
    echo "gateway bundle is not signed as ${gateway_bundle_identifier}" >&2
    return 1
  }
  printf '%s\n' "${details}" | grep -q '^Format=app bundle with Mach-O ' || {
    echo "gateway candidate is not signed as an app bundle" >&2
    return 1
  }
}
