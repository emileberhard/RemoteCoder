#!/usr/bin/env bash
set -euo pipefail
trap 'echo "apply.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR
src="$1"
export DEBIAN_FRONTEND=noninteractive
umask 022

install -d -m 0700 /var/lib/remote-coder-relay
exec 9>/var/lib/remote-coder-relay/provision.lock
flock -n 9 || { echo "Relay provisioning is already running" >&2; exit 1; }
sh "$src/maintenance-fence-check"

policy=/usr/sbin/policy-rc.d
relay_policy=/usr/local/lib/remote-coder-relay/policy-rc.d
if [[ -L "$policy" ]]; then
    [[ $(readlink "$policy") == "$relay_policy" ]] || { echo "An existing policy-rc.d has another owner" >&2; exit 1; }
elif [[ -e "$policy" ]]; then
    echo "An existing policy-rc.d has another owner" >&2
    exit 1
fi
install -d -m 0755 /usr/local/lib/remote-coder-relay
install -m 0755 "$src/maintenance-fence-check" /usr/local/lib/remote-coder-relay/maintenance-fence-check.next
mv -f /usr/local/lib/remote-coder-relay/maintenance-fence-check.next /usr/local/lib/remote-coder-relay/maintenance-fence-check
install -d -m 0755 /etc/dpkg/dpkg.cfg.d
install -m 0644 "$src/dpkg-maintenance.conf" /etc/dpkg/dpkg.cfg.d/remote-coder-relay-maintenance.next
mv -f /etc/dpkg/dpkg.cfg.d/remote-coder-relay-maintenance.next /etc/dpkg/dpkg.cfg.d/remote-coder-relay-maintenance
install -m 0755 "$src/policy-rc.d" "$relay_policy.next"
mv -f "$relay_policy.next" "$relay_policy"
if [[ ! -L "$policy" ]]; then
    ln -s "$relay_policy" "$policy"
fi

activation_dir=/var/lib/remote-coder-relay/activation
install -d -m 0700 "$activation_dir"
source "$src/config-activation.sh"

apt-get update -qq
apt-get install -y -qq conntrack haproxy iptables tinyproxy nftables unattended-upgrades >/dev/null

record_config_change "$src/haproxy-maintenance.conf" /etc/systemd/system/haproxy.service.d/10-relay-maintenance.conf daemon-reload
record_config_change "$src/nftables-maintenance.conf" /etc/systemd/system/nftables.service.d/10-relay-maintenance.conf daemon-reload
record_config_change "$src/remote-coder-relay-maintenance-recover.service" /etc/systemd/system/remote-coder-relay-maintenance-recover.service daemon-reload
record_config_change "$src/remote-coder-relay-maintenance-recover.path" /etc/systemd/system/remote-coder-relay-maintenance-recover.path daemon-reload
record_config_change "$src/remote-coder-relay-maintenance.service" /etc/systemd/system/remote-coder-relay-maintenance.service daemon-reload
record_config_change "$src/remote-coder-relay-maintenance.timer" /etc/systemd/system/remote-coder-relay-maintenance.timer daemon-reload
install -m 0644 "$src/maintenance-firewall.nft" /usr/local/lib/remote-coder-relay/maintenance-firewall.nft
install -m 0755 "$src/maintenance-startup" /usr/local/lib/remote-coder-relay/maintenance-startup
install -m 0755 "$src/maintenance-recover" /usr/local/lib/remote-coder-relay/maintenance-recover
install -m 0755 "$src/maintenance-prepare" /usr/local/lib/remote-coder-relay/maintenance-prepare
install -m 0644 "$src/maintenance_state.py" /usr/local/lib/remote-coder-relay/maintenance_state.py
install -m 0644 "$src/maintenance_drain.py" /usr/local/lib/remote-coder-relay/maintenance_drain.py
install -d -m 0755 /etc/systemd/system/haproxy.service.d
install -m 0644 "$src/haproxy-maintenance.conf" /etc/systemd/system/haproxy.service.d/10-relay-maintenance.conf
install -d -m 0755 /etc/systemd/system/nftables.service.d
install -m 0644 "$src/nftables-maintenance.conf" /etc/systemd/system/nftables.service.d/10-relay-maintenance.conf
install -m 0644 "$src/remote-coder-relay-maintenance-recover.service" /etc/systemd/system/remote-coder-relay-maintenance-recover.service
install -m 0644 "$src/remote-coder-relay-maintenance-recover.path" /etc/systemd/system/remote-coder-relay-maintenance-recover.path
install -m 0644 "$src/remote-coder-relay-maintenance.service" /etc/systemd/system/remote-coder-relay-maintenance.service
install -m 0644 "$src/remote-coder-relay-maintenance.timer" /etc/systemd/system/remote-coder-relay-maintenance.timer
activate_config_change daemon-reload daemon-reload
systemctl enable --quiet remote-coder-relay-maintenance-recover
systemctl enable --quiet --now remote-coder-relay-maintenance-recover.path

record_config_change "$src/nftables.conf" /etc/nftables.conf nftables
install -m 0644 "$src/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable --quiet nftables
if systemctl is-active --quiet nftables; then
    activate_config_change nftables restart
else
    activate_config_change nftables start
    systemctl is-active --quiet nftables || systemctl start nftables
fi

id relay-tunnel >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/relay-tunnel --shell /usr/sbin/nologin relay-tunnel
install -d -m 0700 -o relay-tunnel -g relay-tunnel /home/relay-tunnel/.ssh
install -m 0600 -o relay-tunnel -g relay-tunnel "$src/authorized_keys" /home/relay-tunnel/.ssh/authorized_keys

record_config_change "$src/relay.pem" /etc/haproxy/relay.pem haproxy
record_config_change "$src/haproxy.cfg" /etc/haproxy/haproxy.cfg haproxy
install -m 0640 -o root -g haproxy "$src/relay.pem" /etc/haproxy/relay.pem
install -m 0644 "$src/haproxy.cfg" /etc/haproxy/haproxy.cfg
haproxy -c -q -f /etc/haproxy/haproxy.cfg

record_config_change "$src/tinyproxy.conf" /etc/tinyproxy/tinyproxy.conf tinyproxy
record_config_change "$src/filter" /etc/tinyproxy/filter tinyproxy
install -m 0640 -o root -g tinyproxy "$src/tinyproxy.conf" /etc/tinyproxy/tinyproxy.conf
install -m 0644 "$src/filter" /etc/tinyproxy/filter

install -d -m 0700 /etc/remote-coder-relay
record_config_change "$src/hosts-block" /etc/remote-coder-relay/hosts remote-coder-relay-hosts
record_config_change "$src/remote-coder-relay-hosts" /usr/local/sbin/remote-coder-relay-hosts remote-coder-relay-hosts
record_config_change "$src/remote-coder-relay-hosts.service" /etc/systemd/system/remote-coder-relay-hosts.service remote-coder-relay-hosts
record_config_change "$src/remote-coder-relay-hosts.service" /etc/systemd/system/remote-coder-relay-hosts.service daemon-reload
install -m 0644 "$src/hosts-block" /etc/remote-coder-relay/hosts
install -m 0755 "$src/remote-coder-relay-hosts" /usr/local/sbin/remote-coder-relay-hosts
install -m 0644 "$src/remote-coder-relay-hosts.service" /etc/systemd/system/remote-coder-relay-hosts.service
activate_config_change daemon-reload daemon-reload
systemctl enable --quiet remote-coder-relay-hosts
if systemctl is-active --quiet remote-coder-relay-hosts; then
    activate_config_change remote-coder-relay-hosts restart
else
    activate_config_change remote-coder-relay-hosts start
    systemctl is-active --quiet remote-coder-relay-hosts || systemctl start remote-coder-relay-hosts
fi

record_config_change "$src/sshd.conf" /etc/ssh/sshd_config.d/00-0-remote-coder-relay.conf ssh
for old in /etc/ssh/sshd_config.d/00-hostup-auth.conf /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/remote-coder-relay.conf; do
    record_config_removal "$old" ssh
done
install -m 0644 "$src/sshd.conf" /etc/ssh/sshd_config.d/00-0-remote-coder-relay.conf
rm -f /etc/ssh/sshd_config.d/00-hostup-auth.conf /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/remote-coder-relay.conf
sshd -t
check_sshd() {
    local sshd_config
    sshd_config="$(sshd -T "$@")"
    for expected in 'pubkeyauthentication yes' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin without-password'; do
        grep -qx "$expected" <<<"$sshd_config" || { echo "Unexpected sshd configuration ($*): expected $expected" >&2; return 1; }
    done
}
check_sshd
for user in root relay-tunnel; do
    check_sshd -C "user=$user,host=localhost,addr=127.0.0.1"
done
if [[ -n ${SSH_CONNECTION:-} ]]; then
    read -r remote_addr _ local_addr local_port <<<"$SSH_CONNECTION"
    check_sshd -C "user=root,host=$remote_addr,addr=$remote_addr,laddr=$local_addr,lport=$local_port"
fi

install -m 0644 "$src/unattended-upgrades.conf" /etc/apt/apt.conf.d/52remote-coder-relay
systemctl unmask --quiet apt-daily.timer apt-daily.service apt-daily-upgrade.timer apt-daily-upgrade.service unattended-upgrades.service

pin="$(openssl x509 -in /etc/haproxy/relay.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
host_key="$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
(umask 077; printf '{"username":"%s","password":"%s","proxySpkiSha256":"%s","sshHostKey":"%s"}\n' \
    "$(cat "$src/username")" "$(cat "$src/credential")" "$pin" "$host_key" > /etc/remote-coder-relay/client.json)

systemctl enable --quiet haproxy tinyproxy unattended-upgrades
systemctl enable --quiet --now apt-daily.timer apt-daily-upgrade.timer
activate_config_change tinyproxy restart
activate_config_change haproxy restart
activate_config_change ssh reload
for unit in nftables remote-coder-relay-hosts tinyproxy haproxy ssh apt-daily-upgrade.timer; do
    systemctl is-active --quiet "$unit" || { journalctl -u "$unit" -n 5 --no-pager >&2; exit 1; }
done
