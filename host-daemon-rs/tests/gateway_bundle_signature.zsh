#!/bin/zsh
set -euo pipefail

readonly repo_root="${0:A:h:h:h}"
source "${repo_root}/host-daemon-rs/scripts/gateway-bundle.sh"
readonly scratch="$(mktemp -d /tmp/remote-coder-bundle-signature.XXXXXX)"
trap 'rm -rf "${scratch}"' EXIT

readonly bundle="${scratch}/${gateway_bundle_name}"
cp -R "${gateway_bundle_source}" "${bundle}"
mkdir -p "${bundle}/Contents/MacOS"
cp /usr/bin/true "${bundle}/Contents/MacOS/${gateway_executable_name}"
codesign --force --sign - --timestamp=none "${bundle}"
verify_gateway_bundle "${bundle}"

readonly staged="${bundle}.new.$$"
cp -R "${bundle}" "${staged}"
verify_gateway_bundle "${staged}"
cmp "${bundle}/Contents/_CodeSignature/CodeResources" "${staged}/Contents/_CodeSignature/CodeResources"

readonly flat="${scratch}/${gateway_executable_name}"
cp "${bundle}/Contents/MacOS/${gateway_executable_name}" "${flat}"
if verify_gateway_bundle "${flat}" >"${scratch}/out" 2>"${scratch}/err"; then
  echo "signature gate accepted an unbundled executable" >&2
  exit 1
fi
grep -F 'must be an app bundle' "${scratch}/err" >/dev/null

plutil -replace CFBundleIdentifier -string com.example.other "${staged}/Contents/Info.plist"
codesign --force --sign - --timestamp=none "${staged}"
if verify_gateway_bundle "${staged}" >"${scratch}/out" 2>"${scratch}/err"; then
  echo "signature gate accepted a foreign bundle" >&2
  exit 1
fi
grep -F 'metadata does not match' "${scratch}/err" >/dev/null

print -r -- changed >>"${bundle}/Contents/Info.plist"
if verify_gateway_bundle "${bundle}" >"${scratch}/out" 2>"${scratch}/err"; then
  echo "signature gate accepted changed signed metadata" >&2
  exit 1
fi

echo 'Gateway signature gate validates real bundles before and after staging'
