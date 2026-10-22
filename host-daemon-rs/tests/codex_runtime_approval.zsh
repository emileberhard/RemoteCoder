#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="${repo_root}/scripts/codex-runtime-approval"
temp_root="$(mktemp -d)"
trap 'rm -rf -- "${temp_root}"' EXIT

mkdir -p "${temp_root}/docs/codex" "${temp_root}/package/bin"
cp "${repo_root}/docs/codex/compatibility.json" \
  "${temp_root}/docs/codex/compatibility.json"

print -rn -- 'test-codex' >"${temp_root}/package/bin/codex"
print -rn -- 'test-code-mode-host' >"${temp_root}/package/bin/codex-code-mode-host"
chmod 755 "${temp_root}/package/bin/codex" \
  "${temp_root}/package/bin/codex-code-mode-host"
codex_hash="$(shasum -a 256 "${temp_root}/package/bin/codex" | awk '{print $1}')"
code_mode_hash="$(shasum -a 256 "${temp_root}/package/bin/codex-code-mode-host" | awk '{print $1}')"
cat >"${temp_root}/package/codex-package.json" <<EOF
{
  "layoutVersion": 1,
  "version": "9.8.7-alpha.6",
  "target": "aarch64-apple-darwin",
  "variant": "codex",
  "entrypoint": "bin/codex",
  "resourcesDir": "codex-resources",
  "pathDir": "codex-path",
  "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
  "binaries": {
    "bin/codex": {"sha256": "${codex_hash}"},
    "bin/codex-code-mode-host": {"sha256": "${code_mode_hash}"}
  }
}
EOF

manifest_hash="$(shasum -a 256 "${temp_root}/package/codex-package.json" | awk '{print $1}')"

jq '.externalAuthAcceptance.status = "validated" |
    .externalAuthAcceptance.verifiedHosts = ["old-host"] |
    .externalAuthAcceptance.evidenceCommit = "old-commit" |
    .externalAuthAcceptance.receipts = ["old-receipt"] |
    .externalAuthAcceptance.liveAcceptanceStatus = "passed"' \
  "${temp_root}/docs/codex/compatibility.json" >"${temp_root}/accepted.json"
mv "${temp_root}/accepted.json" "${temp_root}/docs/codex/compatibility.json"

uv run --script "${script}" apply --repo-root "${temp_root}" --json \
  --package "${temp_root}/package" | jq -e '.ok == true' >/dev/null
jq -e \
  '.status == "candidate-unvalidated" and .validatedOnCommit == null and .verification.smokeTests == []' \
  "${temp_root}/docs/codex/compatibility.json" >/dev/null
jq -e '.externalAuthAcceptance |
    .required == true and .gate == "just shared-codex-check <host>" and
    .status == "pending-host-acceptance" and .verifiedHosts == [] and
    .liveAcceptanceStatus == "pending" and
    has("evidenceCommit") == false and has("receipts") == false' \
  "${temp_root}/docs/codex/compatibility.json" >/dev/null

jq '.externalAuthAcceptance.status = "validated" |
    .externalAuthAcceptance.verifiedHosts = ["accepted-host"] |
    .externalAuthAcceptance.evidenceCommit = "accepted-commit" |
    .externalAuthAcceptance.receipts = ["accepted-receipt"] |
    .externalAuthAcceptance.liveAcceptanceStatus = "passed"' \
  "${temp_root}/docs/codex/compatibility.json" >"${temp_root}/accepted.json"
mv "${temp_root}/accepted.json" "${temp_root}/docs/codex/compatibility.json"
uv run --script "${script}" apply --repo-root "${temp_root}" --json \
  --package "${temp_root}/package" | jq -e '.ok == true' >/dev/null
jq -e '.externalAuthAcceptance |
    .status == "validated" and .verifiedHosts == ["accepted-host"] and
    .evidenceCommit == "accepted-commit" and .receipts == ["accepted-receipt"] and
    .liveAcceptanceStatus == "passed"' \
  "${temp_root}/docs/codex/compatibility.json" >/dev/null

uv run --script "${script}" check --repo-root "${temp_root}" --json \
  --package "${temp_root}/package" | jq -e '.ok == true' >/dev/null

mkdir -p "${temp_root}/cache"
cp -R "${temp_root}/package" "${temp_root}/cache/candidate"
resolved="$(uv run --script "${script}" resolve --repo-root "${temp_root}" \
  --packages-dir "${temp_root}/cache")"
[[ "${resolved}" == "${temp_root:A}/cache/candidate" ]]
print -r -- 'changed-resource' >"${temp_root}/cache/candidate/NOTICE"
if uv run --script "${script}" resolve --repo-root "${temp_root}" \
  --packages-dir "${temp_root}/cache" >/dev/null 2>&1; then
  print -u2 -- "resolver accepted different resources with matching executable hashes"
  exit 1
fi
rm "${temp_root}/cache/candidate/NOTICE"
rm -rf "${temp_root}/cache/candidate"
if uv run --script "${script}" resolve --repo-root "${temp_root}" \
  --packages-dir "${temp_root}/cache" >/dev/null 2>&1; then
  print -u2 -- "resolver accepted an absent approved package"
  exit 1
fi

uv run --script "${script}" install-record --repo-root "${temp_root}" --json \
  --package "${temp_root}/package" | jq -e '.ok == true' >/dev/null
approval_digest="$(shasum -a 256 "${temp_root}/approvals/${manifest_hash}.json" | awk '{print $1}')"
[[ "$(stat -f %Lp "${temp_root}/approvals/${manifest_hash}.json")" == "444" ]]
uv run --script "${script}" install-record --repo-root "${temp_root}" --json \
  --package "${temp_root}/package" | jq -e '.ok == true' >/dev/null
[[ "$(shasum -a 256 "${temp_root}/approvals/${manifest_hash}.json" | awk '{print $1}')" == "${approval_digest}" ]]
cp -p "${temp_root}/approvals/${manifest_hash}.json" "${temp_root}/original-approval.json"
chmod 600 "${temp_root}/approvals/${manifest_hash}.json"
print -r -- '{}' >"${temp_root}/approvals/${manifest_hash}.json"
chmod 444 "${temp_root}/approvals/${manifest_hash}.json"
divergent_digest="$(shasum -a 256 "${temp_root}/approvals/${manifest_hash}.json" | awk '{print $1}')"
if uv run --script "${script}" install-record --repo-root "${temp_root}" --json \
  --package "${temp_root}/package" >/dev/null 2>&1; then
  print -u2 -- "install-record replaced a divergent immutable approval"
  exit 1
fi
[[ "$(shasum -a 256 "${temp_root}/approvals/${manifest_hash}.json" | awk '{print $1}')" == "${divergent_digest}" ]]
rm -- "${temp_root}/approvals/${manifest_hash}.json"
cp -p "${temp_root}/original-approval.json" "${temp_root}/approvals/${manifest_hash}.json"


print -rn -- 'tampered' >>"${temp_root}/package/bin/codex"
if uv run --script "${script}" check --repo-root "${temp_root}" \
  --package "${temp_root}/package" >/dev/null 2>&1; then
  print -u2 -- "approval check accepted a package hash mismatch"
  exit 1
fi
print -rn -- 'test-codex' >"${temp_root}/package/bin/codex"

jq '.codexCliVersion = "9.8.7-alpha.5"' "${temp_root}/docs/codex/compatibility.json" \
  >"${temp_root}/drifted.json"
mv "${temp_root}/drifted.json" "${temp_root}/docs/codex/compatibility.json"
if uv run --script "${script}" check --repo-root "${temp_root}" \
  --package "${temp_root}/package" >/dev/null 2>&1; then
  print -u2 -- "approval check accepted a record that differs from the package"
  exit 1
fi

jq '.runtimeHashes["bin/codex"] = "not-a-hash"' "${temp_root}/docs/codex/compatibility.json" \
  >"${temp_root}/invalid.json"
mv "${temp_root}/invalid.json" "${temp_root}/docs/codex/compatibility.json"
if uv run --script "${script}" check --repo-root "${temp_root}" >/dev/null 2>&1; then
  print -u2 -- "approval check accepted an invalid record"
  exit 1
fi

print -- "codex runtime approval tests passed"
