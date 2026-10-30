#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="${repo_root}/scripts/codex-runtime-approval"
temp_root="$(mktemp -d)"
trap 'rm -rf -- "${temp_root}"' EXIT

adoption="host-daemon-rs/src/accounts/codex_migration"
mkdir -p "${temp_root}/docs/codex" "${temp_root}/package/bin" "${temp_root}/${adoption}"
cp "${repo_root}/docs/codex/compatibility.json" \
  "${temp_root}/docs/codex/compatibility.json"
cp "${repo_root}/${adoption}/native.py" "${temp_root}/${adoption}/native.py"

cat >"${temp_root}/package/bin/codex" <<'EOF'
#!/usr/bin/python3 -I
import json, os, pathlib, sqlite3, sys
home = pathlib.Path(os.environ["CODEX_HOME"])
layout = pathlib.Path(sys.argv[0]).resolve().parent.parent / "databases.json"
for name, statements in json.loads(layout.read_text()).items():
    with sqlite3.connect(home / name) as database:
        database.execute("CREATE TABLE _sqlx_migrations(version INTEGER PRIMARY KEY, checksum BLOB, success BOOLEAN)")
        database.execute("INSERT INTO _sqlx_migrations VALUES(1, x'01', 1)")
        for statement in statements:
            database.execute(statement)
    database.close()
for line in sys.stdin:
    message = json.loads(line)
    if "id" in message:
        print(json.dumps({"id": message["id"], "method": "item/tool/requestUserInput", "params": {}}), flush=True)
        result ={"thread": {"id": "thread"}} if message["method"] == "thread/start" else {}
        print(json.dumps({"id": message["id"], "result": result}), flush=True)
EOF
cat >"${temp_root}/package/databases.json" <<'EOF'
{
  "state_5.sqlite": ["CREATE TABLE threads(id TEXT PRIMARY KEY)"],
  "thread_history_1.sqlite": ["CREATE TABLE thread_turns(id TEXT PRIMARY KEY)"],
  "queue_1.sqlite": ["CREATE TABLE queued_items(id TEXT PRIMARY KEY)"],
  "goals_1.sqlite": ["CREATE TABLE thread_goals(id TEXT PRIMARY KEY)"],
  "memories_1.sqlite": ["CREATE TABLE jobs(id TEXT PRIMARY KEY)"],
  "memories_v2_1.sqlite": ["CREATE TABLE jobs(id TEXT PRIMARY KEY)"],
  "logs_2.sqlite": ["CREATE TABLE logs(id TEXT PRIMARY KEY)"]
}
EOF
cp "${temp_root}/package/databases.json" "${temp_root}/databases.json"
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

pin_adoption() {
  local home="${temp_root}/pinned-home"
  rm -rf -- "${home}"
  mkdir "${home}"
  : >"${home}/memories_v2_1.sqlite"
  CODEX_HOME="${home}" "${temp_root}/package/bin/codex" app-server </dev/null
  python3 -I - "${temp_root}/${adoption}/native.py" "${home:A}" \
    >"${temp_root}/${adoption}/schema.json" <<'EOF'
import importlib.util, json, pathlib, sys
specification = importlib.util.spec_from_file_location("native", sys.argv[1])
native = importlib.util.module_from_spec(specification)
specification.loader.exec_module(native)
pins = {}
for name in native.TABLES:
    with native.connect(pathlib.Path(sys.argv[2]) / name, True) as connection:
        fingerprint = native.fingerprint(connection)
    pins[name] = {"schema": fingerprint["schema"], "migrations": fingerprint["migrations"]}
print(json.dumps(pins))
EOF
}

refuse_apply() {
  local reason="$1" expected="$2" output
  if output="$(uv run --script "${script}" apply --repo-root "${temp_root}" --json \
    --package "${temp_root}/package")"; then
    print -u2 -- "approval accepted ${reason}"
    exit 1
  fi
  if ! jq -e --arg expected "${expected}" '.ok == false and (.error | contains($expected))' \
    <<<"${output}" >/dev/null; then
    print -u2 -- "approval refused ${reason} without naming it: ${output}"
    exit 1
  fi
  cmp -s "${temp_root}/before.json" "${temp_root}/docs/codex/compatibility.json"
}

cp "${temp_root}/docs/codex/compatibility.json" "${temp_root}/before.json"
pin_adoption
jq '.["state_5.sqlite"] += ["CREATE INDEX threads_by_id ON threads(id)"]' \
  "${temp_root}/databases.json" >"${temp_root}/package/databases.json"
refuse_apply "a runtime schema that differs from the adoption pins" \
  "Unsupported pinned Codex schema"
jq '.["state_5.sqlite"] += ["CREATE TABLE unexpected_feature(id TEXT)"]' \
  "${temp_root}/databases.json" >"${temp_root}/package/databases.json"
pin_adoption
refuse_apply "a table adoption does not classify" "Unclassified Codex tables"
jq '. + {"unexpected_store_1.sqlite": ["CREATE TABLE value(id TEXT)"]}' \
  "${temp_root}/databases.json" >"${temp_root}/package/databases.json"
pin_adoption
refuse_apply "a database adoption does not classify" "unexpected_store_1.sqlite"
cp "${temp_root}/databases.json" "${temp_root}/package/databases.json"
pin_adoption

uv run --script "${script}" apply --repo-root "${temp_root}" --json \
  --package "${temp_root}/package" |
  jq -e '.ok == true and .adoptionMigrations["state_5.sqlite"] == 1' >/dev/null
jq -e --slurpfile before "${temp_root}/before.json" \
  --arg codex "${codex_hash}" --arg host "${code_mode_hash}" '
    del(.runtimePackageSHA256) == ($before[0] | del(.runtimePackageSHA256) |
      .codexCliVersion = "9.8.7-alpha.6" |
      .codexForkCommit = "0123456789abcdef0123456789abcdef01234567" |
      .runtimeHashes["bin/codex"] = $codex |
      .runtimeHashes["bin/codex-code-mode-host"] = $host) and
    .runtimePackageSHA256 != $before[0].runtimePackageSHA256' \
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
rm -f -- "${temp_root}/approvals/${manifest_hash}.json"
cp -p "${temp_root}/original-approval.json" "${temp_root}/approvals/${manifest_hash}.json"


cp -p "${temp_root}/package/bin/codex" "${temp_root}/codex"
print -rn -- 'tampered' >>"${temp_root}/package/bin/codex"
if uv run --script "${script}" check --repo-root "${temp_root}" \
  --package "${temp_root}/package" >/dev/null 2>&1; then
  print -u2 -- "approval check accepted a package hash mismatch"
  exit 1
fi
cp -p "${temp_root}/codex" "${temp_root}/package/bin/codex"

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
