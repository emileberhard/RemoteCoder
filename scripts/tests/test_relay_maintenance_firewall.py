import errno
import os
import select
import shutil
import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "relay/server"
NFT = os.environ.get("RC_RELAY_TEST_NFT", "nft")
TC = os.environ.get("RC_RELAY_TEST_TC", "tc")


def listener_pending(family):
    address_family = "-4" if family == socket.AF_INET else "-6"
    query = ["ss", "-H", "-n", "-t", address_family]
    half_open = subprocess.run(
        [*query, "state", "syn-recv", "( sport = :443 )"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    listening = subprocess.run(
        [*query, "-l", "( sport = :443 )"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    if len(listening) != 1:
        raise RuntimeError("expected exactly one relay listener for the address family")
    return bool(half_open), int(listening[0].split()[1])


def wait_until(predicate):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise TimeoutError("socket state did not arrive")


def run_lab(parent_namespace_fd):
    parent_namespace = os.fstat(parent_namespace_fd)
    current_namespace = os.stat("/proc/self/ns/net")
    if (parent_namespace.st_dev, parent_namespace.st_ino) == (
        current_namespace.st_dev,
        current_namespace.st_ino,
    ):
        raise RuntimeError("the firewall test requires a separate network namespace")
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    subprocess.run([NFT, "-c", "-f", str(SERVER / "nftables.conf")], check=True)
    subprocess.run([NFT, "-f", str(SERVER / "nftables.conf")], check=True)
    subprocess.run([NFT, "-c", "-f", str(SERVER / "nftables.conf")], check=True)
    subprocess.run(
        [TC, "qdisc", "add", "dev", "lo", "root", "netem", "delay", "500ms"],
        check=True,
    )
    for family, host in [(socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")]:
        with socket.socket(family) as listener, socket.socket(family) as client:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind((host, 443))
            listener.listen(16)
            listener.settimeout(4)
            client.setblocking(False)
            assert client.connect_ex((host, 443)) in (0, errno.EINPROGRESS)
            wait_until(lambda family=family: listener_pending(family)[0])
            subprocess.run(
                [NFT, "-f", str(SERVER / "maintenance-firewall.nft")], check=True
            )
            assert listener_pending(family)[0]
            _, writable, _ = select.select([], [client], [], 4)
            assert (
                writable and client.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0
            )
            wait_until(lambda family=family: listener_pending(family)[1] > 0)
            with listener.accept()[0]:
                pass
            subprocess.run(
                [NFT, "delete", "table", "inet", "remote_coder_relay_maintenance"],
                check=True,
            )
            print(f"{host}: pending handshake and accept queue block an idle decision")
    subprocess.run([TC, "qdisc", "del", "dev", "lo", "root"], check=True)
    listeners = []
    clients = []
    servers = []
    families = [(socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")]

    def connect(family, host):
        client = socket.socket(family)
        client.settimeout(1)
        try:
            client.connect((host, 443))
        except BaseException:
            client.close()
            raise
        clients.append(client)
        return client

    try:
        for family, host in families:
            listener = socket.socket(family)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listeners.append(listener)
            listener.settimeout(2)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind((host, 443))
            listener.listen(16)
            connect(family, host)
            accepted, _ = listener.accept()
            accepted.settimeout(1)
            servers.append(accepted)
            connect(family, host)

        subprocess.run(
            [NFT, "-f", str(SERVER / "maintenance-firewall.nft")], check=True
        )
        subprocess.run(
            [NFT, "-f", str(SERVER / "maintenance-firewall.nft")], check=True
        )
        subprocess.run([NFT, "-f", str(SERVER / "nftables.conf")], check=True)
        for index, (family, host) in enumerate(families):
            active, queued = clients[index * 2 : index * 2 + 2]
            active.sendall(b"active")
            assert servers[index].recv(6) == b"active"
            servers[index].sendall(b"kept")
            assert active.recv(4) == b"kept"
            queued_server, _ = listeners[index].accept()
            servers.append(queued_server)
            queued.sendall(b"queued")
            assert queued_server.recv(6) == b"queued"
            started = time.monotonic()
            try:
                connect(family, host)
            except ConnectionRefusedError:
                assert time.monotonic() - started < 1
            else:
                raise AssertionError("a new connection was admitted")
            print(f"{host}: existing and queued streams survive; new stream refused")

        subprocess.run(
            [NFT, "delete", "table", "inet", "remote_coder_relay_maintenance"],
            check=True,
        )
        for family, host in families:
            connect(family, host)
            print(f"{host}: admission reopened")
    finally:
        for stream in clients + servers + listeners:
            stream.close()


class RelayMaintenanceFirewallTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux", "requires Linux network namespaces")
    def test_lab_refuses_the_callers_network_namespace(self):
        namespace_fd = os.open("/proc/self/ns/net", os.O_RDONLY)
        try:
            result = subprocess.run(
                [sys.executable, __file__, "--lab", str(namespace_fd)],
                pass_fds=(namespace_fd,),
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        finally:
            os.close(namespace_fd)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a separate network namespace", result.stderr)

    def test_fence_preserves_existing_and_queued_connections(self):
        required = os.environ.get("RC_RELAY_REQUIRE_INGRESS") == "1"
        missing = [
            name for name in ("unshare", "ip", "ss", NFT, TC) if not shutil.which(name)
        ]
        if sys.platform != "linux" or missing:
            if required:
                self.fail(f"Linux, unshare, ip, ss, tc and nft are required: {missing}")
            self.skipTest("Linux network-namespace tools are unavailable")
        preflight = subprocess.run(
            ["unshare", "-Urn", "true"], capture_output=True, text=True, check=False
        )
        if preflight.returncode:
            if required:
                self.fail(f"user network namespaces are required: {preflight.stderr}")
            self.skipTest("user network namespaces are unavailable")
        namespace_fd = os.open("/proc/self/ns/net", os.O_RDONLY)
        try:
            result = subprocess.run(
                [
                    "unshare",
                    "-Urn",
                    sys.executable,
                    __file__,
                    "--lab",
                    str(namespace_fd),
                ],
                pass_fds=(namespace_fd,),
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
        finally:
            os.close(namespace_fd)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("127.0.0.1: admission reopened", result.stdout)
        self.assertIn("::1: admission reopened", result.stdout)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--lab":
        run_lab(int(sys.argv[2]))
    else:
        unittest.main()
