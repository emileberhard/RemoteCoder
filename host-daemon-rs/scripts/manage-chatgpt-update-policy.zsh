#!/bin/zsh
set -euo pipefail

readonly this_dir="$(cd -- "$(dirname -- "${0}")" && pwd)"
readonly source_file="${this_dir}/../config/chatgpt-shared-runtime-requirements.toml"
readonly destination="${RC_CHATGPT_REQUIREMENTS_PATH:-/etc/codex/requirements.toml}"
readonly action="${1:-install}"

require_root() {
  if [[ "${destination}" == /etc/* && "${EUID}" -ne 0 ]]; then
    echo "${action} requires root; run this script through Agent Sudo" >&2
    exit 1
  fi
}

case "${action}" in
  install)
    require_root
    if [[ -e "${destination}" ]] && ! cmp -s "${source_file}" "${destination}"; then
      echo "refusing to replace existing managed Codex requirements: ${destination}" >&2
      exit 1
    fi
    install -d -m 755 "${destination:h}"
    install -m 644 "${source_file}" "${destination}"
    ;;
  check)
    cmp -s "${source_file}" "${destination}" || {
      echo "ChatGPT in-app update policy is not installed at ${destination}" >&2
      exit 1
    }
    ;;
  remove)
    require_root
    if [[ ! -e "${destination}" ]]; then
      exit 0
    fi
    cmp -s "${source_file}" "${destination}" || {
      echo "refusing to remove requirements not owned by RemoteCoder: ${destination}" >&2
      exit 1
    }
    rm -f "${destination}"
    ;;
  *)
    echo "usage: ${0:t} [install|check|remove]" >&2
    exit 2
    ;;
esac
