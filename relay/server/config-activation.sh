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
        [[ -f "$record" ]] && rm "$record"
    done
    rmdir "$activation_dir/$service"
}

activate_config_change() {
    local service=$1 action=$2 record path original current changed=false
    [[ -d "$activation_dir/$service" ]] || return 0
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
    if "$changed"; then
        if [[ "$service" == daemon-reload ]]; then
            systemctl daemon-reload
        else
            systemctl "$action" "$service"
        fi
    fi
    clear_config_change "$service"
}
