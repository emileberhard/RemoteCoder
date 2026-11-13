#!/usr/bin/env bash

activation_dir=${activation_dir:?activation directory is required}

config_digest() {
    if [[ -f "$1" ]]; then
        openssl dgst -sha256 < "$1"
    elif [[ -e "$1" || -L "$1" ]]; then
        echo "Cannot fingerprint configuration: $1" >&2
        return 1
    else
        printf '%s\n' missing
    fi
}

record_original_config() {
    local path=$1 service=$2 key record digest
    key=$(printf '%s' "$path" | openssl dgst -sha256)
    key=${key##* }
    record="$activation_dir/$service/$key"
    mkdir -p "$activation_dir/$service"
    if [[ ! -e "$record" ]]; then
        digest=$(config_digest "$path")
        printf '%s\n%s\n' "$path" "$digest" > "$record.next"
        mv "$record.next" "$record"
    fi
}

record_config_change() {
    if ! cmp -s "$1" "$2"; then
        record_original_config "$2" "$3"
    fi
}

record_config_removal() {
    if [[ -e "$1" || -L "$1" ]]; then
        record_original_config "$1" "$2"
    fi
}

clear_config_change() {
    local service=$1 record
    [[ -d "$activation_dir/$service" ]] || return 0
    for record in "$activation_dir/$service"/*; do
        [[ "$record" != "$activation_dir/$service/attempted" ]] || continue
        [[ -f "$record" ]] && rm "$record"
    done
    if [[ -e "$activation_dir/$service/attempted" ]]; then
        python3 - "$activation_dir/$service" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
        rm "$activation_dir/$service/attempted"
    fi
    rmdir "$activation_dir/$service"
}

record_activation_attempt() {
    python3 - "$activation_dir/$1" <<'PY'
import os
import sys

directory = sys.argv[1]
fd = os.open(os.path.join(directory, "attempted"), os.O_WRONLY | os.O_CREAT, 0o600)
try:
    os.fsync(fd)
finally:
    os.close(fd)
fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

activate_config_change() {
    local service=$1 action=$2 record path original current changed=false
    [[ -d "$activation_dir/$service" ]] || return 0
    if [[ -e "$activation_dir/$service/attempted" ]]; then
        changed=true
    else
        for record in "$activation_dir/$service"/*; do
            [[ -f "$record" ]] || continue
            [[ "$record" != *.next ]] || continue
            IFS= read -r path < "$record"
            original=$(sed -n '2p' "$record")
            [[ -n "$path" && -n "$original" ]] || { echo "Invalid configuration record: $record" >&2; return 1; }
            current=$(config_digest "$path")
            if [[ "$current" != "$original" ]]; then
                changed=true
            fi
        done
    fi
    if "$changed"; then
        record_activation_attempt "$service"
        if [[ "$service" == daemon-reload ]]; then
            systemctl daemon-reload
        else
            systemctl "$action" "$service"
        fi
    fi
    clear_config_change "$service"
}
