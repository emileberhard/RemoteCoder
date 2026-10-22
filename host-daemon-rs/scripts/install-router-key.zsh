#!/bin/zsh
set -euo pipefail
umask 077
readonly state_dir="$HOME/.remote-coder"
readonly env_file="$state_dir/codex-gateway.env"
readonly key_file="$state_dir/llm-router.key"
[[ -d "$state_dir" && -f "$env_file" ]] || { print -u2 'Gateway environment is missing'; exit 1; }
[[ $# -eq 2 ]] || { print -u2 'Usage: install-router-key.zsh INFERENCE_ORIGIN ACCOUNTS_ORIGIN < key-file'; exit 2; }
readonly inference_origin="$1"
readonly accounts_origin="$2"
key_stage="$(mktemp "$state_dir/.router-key-XXXXXXXX")"
env_stage="$(mktemp "$state_dir/.router-env-XXXXXXXX")"
trap 'rm -f "$key_stage" "$env_stage"' EXIT
python3 -c 'import pathlib,sys; data=sys.stdin.buffer.read(65); assert len(data)<=64, "Router key exceeds its limit"; pathlib.Path(sys.argv[1]).write_bytes(data)' "$key_stage"
python3 - "$key_stage" "$key_file" "$env_file" "$env_stage" "$inference_origin" "$accounts_origin" <<'PY'
import pathlib
import re
import sys
import shlex
stage, key_file, env_file, env_stage, inference_origin, accounts_origin = sys.argv[1:]
from urllib.parse import urlsplit
for origin in [inference_origin, accounts_origin]:
    url = urlsplit(origin)
    if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password or url.path not in {"", "/"} or url.query or url.fragment:
        raise SystemExit("Router listeners must be HTTP(S) origins without paths or credentials")
inference_origin = inference_origin.rstrip("/")
accounts_origin = accounts_origin.rstrip("/")
if not re.fullmatch(rb'llmr_[A-Za-z0-9_-]{43}\n?', pathlib.Path(stage).read_bytes()):
    raise SystemExit('Invalid llm-router key')
lines = pathlib.Path(env_file).read_text().splitlines()
settings = {
    'RC_CODEX_GATEWAY_ROUTER_URL': inference_origin,
    'RC_CODEX_GATEWAY_ROUTER_ACCOUNTS_URL': accounts_origin,
    'RC_CODEX_GATEWAY_ROUTER_KEY_FILE': key_file,
    'RC_CODEX_GATEWAY_ROUTER_ALLOWED_ORIGINS': f'{inference_origin},{accounts_origin}',
}
lines = [line for line in lines if not any(re.match(r'(?:export\s+)?' + name + r'\s*=', line) for name in settings)]
lines.extend(f'{name}={shlex.quote(value)}' for name, value in settings.items())
pathlib.Path(env_stage).write_text('\n'.join(lines) + '\n')
PY
chmod 600 "$key_stage" "$env_stage"
mv -f "$key_stage" "$key_file"
mv -f "$env_stage" "$env_file"
print '{"status":"configured","restart_performed":false}'
