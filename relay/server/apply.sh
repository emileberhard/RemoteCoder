#!/usr/bin/env bash
set -euo pipefail
trap 'echo "apply.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR
src="$1"
export DEBIAN_FRONTEND=noninteractive
umask 022

apt-get update -qq
apt-get install -y -qq haproxy tinyproxy nftables unattended-upgrades >/dev/null

install -m 0644 "$src/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable --quiet --now nftables
systemctl restart nftables

id relay-tunnel >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/relay-tunnel --shell /usr/sbin/nologin relay-tunnel
install -d -m 0700 -o relay-tunnel -g relay-tunnel /home/relay-tunnel/.ssh
install -m 0600 -o relay-tunnel -g relay-tunnel "$src/authorized_keys" /home/relay-tunnel/.ssh/authorized_keys

install -m 0640 -o root -g haproxy "$src/relay.pem" /etc/haproxy/relay.pem
install -m 0644 "$src/haproxy.cfg" /etc/haproxy/haproxy.cfg
haproxy -c -q -f /etc/haproxy/haproxy.cfg

install -m 0640 -o root -g tinyproxy "$src/tinyproxy.conf" /etc/tinyproxy/tinyproxy.conf
install -m 0644 "$src/filter" /etc/tinyproxy/filter

install -d -m 0700 /etc/remote-coder-relay
install -m 0644 "$src/hosts-block" /etc/remote-coder-relay/hosts
install -m 0755 "$src/remote-coder-relay-hosts" /usr/local/sbin/remote-coder-relay-hosts
install -m 0644 "$src/remote-coder-relay-hosts.service" /etc/systemd/system/remote-coder-relay-hosts.service
systemctl daemon-reload
systemctl enable --quiet remote-coder-relay-hosts
systemctl restart remote-coder-relay-hosts

install -m 0644 "$src/sshd.conf" /etc/ssh/sshd_config.d/remote-coder-relay.conf
sshd -t

install -m 0644 "$src/unattended-upgrades.conf" /etc/apt/apt.conf.d/52remote-coder-relay
systemctl unmask --quiet apt-daily.timer apt-daily.service apt-daily-upgrade.timer apt-daily-upgrade.service unattended-upgrades.service

pin="$(openssl x509 -in /etc/haproxy/relay.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
host_key="$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
(umask 077; printf '{"username":"%s","password":"%s","proxySpkiSha256":"%s","sshHostKey":"%s"}\n' \
    "$(cat "$src/username")" "$(cat "$src/credential")" "$pin" "$host_key" > /etc/remote-coder-relay/client.json)

systemctl enable --quiet haproxy tinyproxy unattended-upgrades
systemctl enable --quiet --now apt-daily.timer apt-daily-upgrade.timer
systemctl restart tinyproxy haproxy
systemctl reload ssh
for unit in nftables remote-coder-relay-hosts tinyproxy haproxy ssh apt-daily-upgrade.timer; do
    systemctl is-active --quiet "$unit" || { journalctl -u "$unit" -n 5 --no-pager >&2; exit 1; }
done
