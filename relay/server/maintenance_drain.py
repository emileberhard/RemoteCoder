import csv
import io
import json
import math
import socket
import subprocess
import time
from pathlib import Path

from maintenance_state import worker_identity

MASTER_SOCKET = Path("/run/haproxy-master.sock")
TINYPROXY_CONFIG = Path("/etc/tinyproxy/tinyproxy.conf")
PROC_TCP = (Path("/proc/net/tcp"), Path("/proc/net/tcp6"))
CONNTRACK = "/usr/sbin/conntrack"
NFT = "/usr/sbin/nft"
LEGACY = ("/usr/sbin/iptables-legacy", "/usr/sbin/ip6tables-legacy")
TERMINAL_STATES = {"TIME_WAIT", "CLOSE"}
TCP_STATES = {
    "SYN_SENT",
    "SYN_RECV",
    "ESTABLISHED",
    "FIN_WAIT",
    "CLOSE_WAIT",
    "LAST_ACK",
    "TIME_WAIT",
    "CLOSE",
    "SYN_SENT2",
}


def remaining_time(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("relay drain timed out")
    return min(5, remaining)


def command(args, deadline=None):
    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=5 if deadline is None else remaining_time(deadline),
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"relay inspection failed: {Path(args[0]).name}")
    return result.stdout


def tracked_ports():
    ports = {443, 8888}
    configured = set()
    for line in TINYPROXY_CONFIG.read_text().splitlines():
        parts = line.split()
        if parts and parts[0].lower() == "connectport":
            if (
                len(parts) != 2
                or not parts[1].isdigit()
                or not 0 < int(parts[1]) < 65536
            ):
                raise RuntimeError("invalid tinyproxy connect port")
            configured.add(int(parts[1]))
    if not configured:
        raise RuntimeError("no tinyproxy connect ports configured")
    return ports | configured


def tracking_is_configured(deadline=None):
    ruleset = json.loads(command([NFT, "-j", "list", "ruleset"], deadline))
    if not isinstance(ruleset, dict) or not isinstance(ruleset.get("nftables"), list):
        raise TypeError("invalid nftables ruleset")
    rules = ruleset["nftables"]
    if "notrack" in json.dumps(rules).lower():
        raise RuntimeError("nftables excludes connections from tracking")
    tracked = False
    for item in rules:
        rule = item.get("rule", {})
        if (rule.get("family"), rule.get("table"), rule.get("chain")) != (
            "inet",
            "filter",
            "input",
        ):
            continue
        expressions = rule.get("expr", [])
        for expression in expressions:
            match = expression.get("match", {})
            if match.get("left") == {
                "ct": {"key": "state"}
            } and "established" in match.get("right", []):
                tracked = True
    if not tracked:
        raise RuntimeError("relay baseline connection tracking is absent")
    for binary in LEGACY:
        rules = command([binary, "-t", "raw", "-S"], deadline).lower()
        if "notrack" in rules or "--notrack" in rules:
            raise RuntimeError("legacy firewall excludes connections from tracking")


def fence_is_configured(deadline=None):
    data = json.loads(
        command(
            [NFT, "-j", "list", "table", "inet", "remote_coder_relay_maintenance"],
            deadline,
        )
    )
    entries = data.get("nftables", [])
    chains = [item["chain"] for item in entries if "chain" in item]
    rules = [item["rule"] for item in entries if "rule" in item]
    if len(chains) != 1 or len(rules) != 1:
        raise RuntimeError("relay maintenance fence is not uniquely configured")
    chain = chains[0]
    if (
        chain.get("family"),
        chain.get("table"),
        chain.get("name"),
        chain.get("type"),
        chain.get("hook"),
        chain.get("prio"),
        chain.get("policy"),
    ) != (
        "inet",
        "remote_coder_relay_maintenance",
        "input",
        "filter",
        "input",
        -1,
        "accept",
    ):
        raise RuntimeError("relay maintenance chain changed")
    rule = rules[0]
    if (rule.get("family"), rule.get("table"), rule.get("chain")) != (
        "inet",
        "remote_coder_relay_maintenance",
        "input",
    ) or rule.get("expr") != [
        {
            "match": {
                "op": "==",
                "left": {"payload": {"protocol": "tcp", "field": "dport"}},
                "right": 443,
            }
        },
        {"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": "new"}},
        {"reject": {"type": "tcp reset"}},
    ]:
        raise RuntimeError("relay maintenance rule changed")


def fence_is_absent(deadline):
    ruleset = json.loads(command([NFT, "-j", "list", "ruleset"], deadline))
    if not isinstance(ruleset, dict) or not isinstance(ruleset.get("nftables"), list):
        raise TypeError("invalid nftables ruleset")
    for item in ruleset["nftables"]:
        table = item.get("table", {})
        if (table.get("family"), table.get("name")) == (
            "inet",
            "remote_coder_relay_maintenance",
        ):
            raise RuntimeError("relay admission is already fenced")


def active_conntrack(ports, deadline=None):
    for family in ("ipv4", "ipv6"):
        for port in sorted(ports):
            output = command(
                [CONNTRACK, "-L", "-f", family, "-p", "tcp", "--dport", str(port)],
                deadline,
            )
            for line in output.splitlines():
                fields = line.split()
                if len(fields) < 4 or fields[0] != "tcp" or fields[3] not in TCP_STATES:
                    raise RuntimeError("unknown conntrack TCP entry")
                if fields[3] not in TERMINAL_STATES:
                    return True
    return False


def listener_queues(ports):
    required = {(0, 443), (1, 443), (0, 8888)} | {
        (0, port) for port in ports - {443, 8888}
    }
    found = {}
    for family, path in enumerate(PROC_TCP):
        for line in path.read_text().splitlines()[1:]:
            fields = line.split()
            if len(fields) < 10:
                raise RuntimeError("invalid kernel TCP socket entry")
            address, port_hex = fields[1].rsplit(":", 1)
            port = int(port_hex, 16)
            if fields[3] != "0A" or (family, port) not in required:
                continue
            expected = (
                ("00000000" if family == 0 else "0" * 32) if port == 443 else "0100007F"
            )
            if address != expected:
                raise RuntimeError("relay listener address changed")
            key = family, port
            if key in found:
                raise RuntimeError("multiple relay listeners found")
            found[key] = int(fields[4].split(":", 1)[1], 16)
    if set(found) != required:
        raise RuntimeError("expected relay listeners are missing")
    return any(found.values())


def haproxy_command(request, deadline=None):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5 if deadline is None else remaining_time(deadline))
        connection.connect(str(MASTER_SOCKET))
        connection.sendall((request + "\n").encode())
        connection.shutdown(socket.SHUT_WR)
        result = bytearray()
        while True:
            if deadline is not None:
                connection.settimeout(remaining_time(deadline))
            part = connection.recv(65536)
            if not part:
                break
            result.extend(part)
            if len(result) > 1024 * 1024:
                raise RuntimeError("HAProxy status is too large")
    return result.decode()


def haproxy_identity(deadline=None):
    master = []
    workers = []
    for line in haproxy_command("show proc", deadline).splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 3 or not fields[0].isdigit():
            raise RuntimeError("unknown HAProxy process entry")
        if fields[1] == "master":
            master.append(int(fields[0]))
        elif fields[1] == "worker" and fields[2] == "0":
            workers.append(int(fields[0]))
        else:
            raise RuntimeError("retiring or auxiliary HAProxy process")
    if len(master) != 1 or len(workers) != 1:
        raise RuntimeError("HAProxy must have one master and one serving worker")
    return {"master": worker_identity(master[0]), "worker": worker_identity(workers[0])}


def haproxy_busy(deadline=None):
    info = {}
    for line in haproxy_command("@1 show info", deadline).splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            if key in info:
                raise RuntimeError("duplicate HAProxy info field")
            info[key] = value.strip()
    if not info.get("CurrConns", "").isdigit():
        raise RuntimeError("HAProxy connection count is unavailable")
    rows = csv.DictReader(io.StringIO(haproxy_command("@1 show stat", deadline)))
    if rows.fieldnames is None:
        raise RuntimeError("HAProxy statistics are unavailable")
    rows.fieldnames[0] = rows.fieldnames[0].removeprefix("# ")
    counts = {}
    for row in rows:
        key = row.get("pxname"), row.get("svname")
        if key in (("relay", "FRONTEND"), ("tinyproxy", "BACKEND")):
            if key in counts or not row.get("scur", "").isdigit():
                raise RuntimeError("invalid HAProxy session count")
            if key == ("relay", "FRONTEND") and row.get("status") != "OPEN":
                raise RuntimeError("HAProxy relay frontend is not open")
            counts[key] = int(row["scur"])
    if len(counts) != 2:
        raise RuntimeError("relay HAProxy statistics are incomplete")
    return int(info["CurrConns"]) != 0 or any(counts.values())


def _live_work(expected_identity, deadline):
    ports = tracked_ports()
    if haproxy_identity(deadline) != expected_identity:
        raise RuntimeError("HAProxy generation changed")
    busy = (
        active_conntrack(ports, deadline)
        or listener_queues(ports)
        or haproxy_busy(deadline)
    )
    if haproxy_identity(deadline) != expected_identity:
        raise RuntimeError("HAProxy generation changed")
    return busy


def snapshot(expected_identity, deadline):
    tracking_is_configured(deadline)
    fence_is_configured(deadline)
    return _live_work(expected_identity, deadline)


def candidate_snapshot(expected_identity, deadline):
    tracking_is_configured(deadline)
    fence_is_absent(deadline)
    return _live_work(expected_identity, deadline)


def wait_for_candidate(expected_identity, timeout_seconds):
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("relay candidate timeout must be positive")
    deadline = time.monotonic() + timeout_seconds
    while True:
        remaining_time(deadline)
        busy = candidate_snapshot(expected_identity, deadline)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("relay idle candidate timed out")
        if not busy:
            return
        time.sleep(min(1, remaining))


def wait_for_drain(expected_identity, timeout_seconds):
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 2:
        raise ValueError("relay drain timeout must exceed two seconds")
    deadline = time.monotonic() + timeout_seconds
    clean_passes = 0
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("relay drain timed out")
        time.sleep(min(1, remaining))
        if time.monotonic() >= deadline:
            raise TimeoutError("relay drain timed out")
        busy = snapshot(expected_identity, deadline)
        if time.monotonic() >= deadline:
            raise TimeoutError("relay drain timed out")
        if busy:
            clean_passes = 0
        else:
            clean_passes += 1
            if clean_passes == 2:
                return


def verify_local_boot_prerequisites(timeout_seconds):
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("relay health timeout must be positive")
    deadline = time.monotonic() + timeout_seconds
    for unit in (
        "nftables.service",
        "ssh.service",
        "tinyproxy.service",
        "haproxy.service",
    ):
        command(["/usr/bin/systemctl", "is-active", "--quiet", unit], deadline)
    tracking_is_configured(deadline)
    fence_is_configured(deadline)
    ports = tracked_ports()
    identity = haproxy_identity(deadline)
    if listener_queues(ports) or haproxy_busy(deadline):
        raise RuntimeError("relay is not locally idle after boot")
    if haproxy_identity(deadline) != identity:
        raise RuntimeError("HAProxy generation changed during health verification")
    remaining_time(deadline)
    return identity
