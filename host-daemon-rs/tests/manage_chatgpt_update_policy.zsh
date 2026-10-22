#!/bin/zsh
set -euo pipefail

readonly this_dir="$(cd -- "$(dirname -- "${0}")" && pwd)"
readonly script="${this_dir}/../scripts/manage-chatgpt-update-policy.zsh"
readonly root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export RC_CHATGPT_REQUIREMENTS_PATH="${root}/etc/codex/requirements.toml"

"${script}" install
"${script}" check
"${script}" install

print '[features]\nin_app_updates = true' > "${RC_CHATGPT_REQUIREMENTS_PATH}"
if "${script}" remove 2>/dev/null; then
  echo "remove accepted requirements it does not own" >&2
  exit 1
fi

cp "${this_dir}/../config/chatgpt-shared-runtime-requirements.toml" \
  "${RC_CHATGPT_REQUIREMENTS_PATH}"
"${script}" remove
[[ ! -e "${RC_CHATGPT_REQUIREMENTS_PATH}" ]]
