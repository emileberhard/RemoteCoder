#!/bin/sh

if [ "${1:-}" = --quiet ]; then
    shift
fi

case "${2:-}" in
    \(*\)) exit 101 ;;
esac

service=${1%.service}
service=${service%.socket}
marker=${DPKG_ROOT:-}/var/lib/remote-coder-relay/maintenance.json
if [ "$service" = nftables ] && { [ -e "$marker" ] || [ -L "$marker" ]; }; then
    case "${2:-}" in
        start|status) exit 0 ;;
        *) exit 101 ;;
    esac
fi
case "$service" in
    haproxy|tinyproxy|ssh|sshd|ssh@*|sshd@*)
        case "${2:-}" in
            start|status) exit 0 ;;
            *) exit 101 ;;
        esac
        ;;
esac
exit 0
