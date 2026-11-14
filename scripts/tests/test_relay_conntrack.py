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

SERVER = Path(__file__).resolve().parents[2] / "relay/server"
NFT = os.environ.get("RC_RELAY_TEST_NFT", "nft")
TC = os.environ.get("RC_RELAY_TEST_TC", "tc")
CONNTRACK = os.environ.get("RC_RELAY_TEST_CONNTRACK", "conntrack")


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise TimeoutError("conntrack state did not arrive")


def run_lab(parent_fd, mode, version):
    parent = os.fstat(parent_fd)
    current = os.stat("/proc/self/ns/net")
    if (parent.st_dev, parent.st_ino) == (current.st_dev, current.st_ino):
        raise RuntimeError("the conntrack test requires a separate network namespace")
    family = socket.AF_INET if version == "4" else socket.AF_INET6
    host = "127.0.0.1" if version == "4" else "::1"
    sys.path.insert(0, str(SERVER))
    import maintenance_drain

    maintenance_drain.CONNTRACK = CONNTRACK
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    Path("/proc/sys/net/ipv4/tcp_syncookies").write_text("2")
    if mode == "expire":
        Path("/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_syn_recv").write_text(
            "1"
        )
    subprocess.run([NFT, "-f", str(SERVER / "nftables.conf")], check=True)
    subprocess.run(
        [
            TC,
            "qdisc",
            "add",
            "dev",
            "lo",
            "root",
            "netem",
            "delay",
            "1500ms" if mode == "expire" else "500ms",
        ],
        check=True,
    )

    def state():
        return subprocess.run(
            [
                CONNTRACK,
                "-L",
                "-f",
                "ipv4" if version == "4" else "ipv6",
                "-p",
                "tcp",
                "--dport",
                "443",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout

    with socket.socket(family) as listener, socket.socket(family) as client:
        if family == socket.AF_INET6:
            listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        listener.bind((host, 443))
        listener.listen(16)
        listener.settimeout(7)
        client.setblocking(False)
        assert client.connect_ex((host, 443)) in (0, errno.EINPROGRESS)
        wait_until(lambda: "SYN_RECV" in state(), 5)
        assert maintenance_drain.active_conntrack({443})
        half_open = subprocess.run(
            [
                "ss",
                "-H",
                "-n",
                "-t",
                "-4" if version == "4" else "-6",
                "state",
                "syn-recv",
                "( sport = :443 )",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        assert not half_open.strip()
        subprocess.run(
            [NFT, "-f", str(SERVER / "maintenance-firewall.nft")], check=True
        )
        if mode == "expire":
            wait_until(lambda: "SYN_RECV" not in state(), 4)
            assert not maintenance_drain.active_conntrack({443})
        _, writable, _ = select.select([], [client], [], 8)
        assert writable and client.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0
        client.setblocking(True)
        client.settimeout(8)
        if mode == "keep":
            wait_until(lambda: "ESTABLISHED" in state(), 4)
            accepted, _ = listener.accept()
            with accepted:
                accepted.settimeout(4)
                client.sendall(b"test")
                assert accepted.recv(4) == b"test"
            print(f"IPv{version}: cookie handshake remains tracked and completes")
        else:
            try:
                client.sendall(b"test")
                client.recv(1)
            except (ConnectionResetError, BrokenPipeError):
                pass
            else:
                raise AssertionError("the expired handshake was not reset")
            try:
                accepted, _ = listener.accept()
            except TimeoutError:
                pass
            else:
                accepted.close()
                raise AssertionError("the expired handshake was accepted")
            print(f"IPv{version}: expired cookie handshake was reset")


class RelayConntrackTests(unittest.TestCase):
    def test_cookie_handshakes_are_tracked_and_expiry_is_fenced(self):
        required = os.environ.get("RC_RELAY_REQUIRE_INGRESS") == "1"
        missing = [
            name
            for name in ("unshare", "ip", "ss", TC, NFT, CONNTRACK)
            if not shutil.which(name)
        ]
        if sys.platform != "linux" or missing:
            if required:
                self.fail(f"Linux network-namespace tools are required: {missing}")
            self.skipTest("Linux network-namespace tools are unavailable")
        preflight = subprocess.run(
            ["unshare", "-Urn", "true"], capture_output=True, text=True, check=False
        )
        if preflight.returncode:
            if required:
                self.fail(f"user network namespaces are required: {preflight.stderr}")
            self.skipTest("user network namespaces are unavailable")
        parent_fd = os.open("/proc/self/ns/net", os.O_RDONLY)
        try:
            for mode in ("keep", "expire"):
                for version in ("4", "6"):
                    with self.subTest(mode=mode, version=version):
                        result = subprocess.run(
                            [
                                "unshare",
                                "-Urn",
                                sys.executable,
                                __file__,
                                "--lab",
                                str(parent_fd),
                                mode,
                                version,
                            ],
                            pass_fds=(parent_fd,),
                            capture_output=True,
                            text=True,
                            timeout=30,
                            check=False,
                        )
                        self.assertEqual(
                            result.returncode, 0, result.stdout + result.stderr
                        )
        finally:
            os.close(parent_fd)


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--lab":
        run_lab(int(sys.argv[2]), sys.argv[3], sys.argv[4])
    else:
        unittest.main()
