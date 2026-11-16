#!/usr/bin/env bash
set -euo pipefail
src="$1"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
umask 022

install -d -m 0700 /var/lib/remote-coder-relay
exec 9>/var/lib/remote-coder-relay/provision.lock
flock -n 9 || { echo "Relay provisioning is already running" >&2; exit 1; }
sh "$src/maintenance-fence-check"

timer=remote-coder-relay-maintenance.timer
enabled=$(systemctl is-enabled "$timer" 2>/dev/null || :)
active=$(systemctl is-active "$timer" 2>/dev/null || :)
case "$enabled" in disabled|not-found) ;; *) echo "Maintenance timer is not disabled: $enabled" >&2; exit 1 ;; esac
case "$active" in inactive|unknown) ;; *) echo "Maintenance timer is not inactive: $active" >&2; exit 1 ;; esac

policy=/usr/sbin/policy-rc.d
relay_policy=/usr/local/lib/remote-coder-relay/policy-rc.d
if [[ -L "$policy" ]]; then
    [[ $(readlink "$policy") == "$relay_policy" ]] || { echo "An existing policy-rc.d has another owner" >&2; exit 1; }
elif [[ -e "$policy" ]]; then
    echo "An existing policy-rc.d has another owner" >&2
    exit 1
fi
install -d -m 0755 /usr/local/lib/remote-coder-relay /etc/dpkg/dpkg.cfg.d
install -m 0755 "$src/maintenance-fence-check" /usr/local/lib/remote-coder-relay/maintenance-fence-check.next
mv -f /usr/local/lib/remote-coder-relay/maintenance-fence-check.next /usr/local/lib/remote-coder-relay/maintenance-fence-check
install -m 0644 "$src/dpkg-maintenance.conf" /etc/dpkg/dpkg.cfg.d/remote-coder-relay-maintenance.next
mv -f /etc/dpkg/dpkg.cfg.d/remote-coder-relay-maintenance.next /etc/dpkg/dpkg.cfg.d/remote-coder-relay-maintenance
install -m 0755 "$src/policy-rc.d" "$relay_policy.next"
mv -f "$relay_policy.next" "$relay_policy"
if [[ ! -L "$policy" ]]; then
    ln -s "$relay_policy" "$policy"
fi

apt-get install -y -qq --no-upgrade --no-install-recommends conntrack >/dev/null

for name in maintenance-startup maintenance-recover maintenance-prepare; do
    install -m 0755 "$src/$name" "/usr/local/lib/remote-coder-relay/$name"
done
for name in maintenance-firewall.nft maintenance_state.py maintenance_drain.py maintenance_updates.py; do
    install -m 0644 "$src/$name" "/usr/local/lib/remote-coder-relay/$name"
done
install -d -m 0755 /etc/systemd/system/haproxy.service.d /etc/systemd/system/nftables.service.d
install -m 0644 "$src/haproxy-maintenance.conf" /etc/systemd/system/haproxy.service.d/10-relay-maintenance.conf
install -m 0644 "$src/nftables-maintenance.conf" /etc/systemd/system/nftables.service.d/10-relay-maintenance.conf
for name in remote-coder-relay-maintenance-recover.service remote-coder-relay-maintenance-recover.path remote-coder-relay-maintenance.service remote-coder-relay-maintenance.timer; do
    install -m 0644 "$src/$name" "/etc/systemd/system/$name"
done
install -m 0644 "$src/nftables.conf" /etc/nftables.conf
systemctl enable --no-reload --quiet remote-coder-relay-maintenance-recover.service remote-coder-relay-maintenance-recover.path
systemctl daemon-reload
systemctl start remote-coder-relay-maintenance-recover.path
