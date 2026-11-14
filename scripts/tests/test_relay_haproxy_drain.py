import os
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SERVER = Path(__file__).resolve().parents[2] / "relay/server"
HAPROXY = os.environ.get("RC_RELAY_TEST_HAPROXY", "haproxy")


def wait_until(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise TimeoutError("HAProxy did not reach the expected state")


def run_lab(parent_fd):
    parent = os.fstat(parent_fd)
    current = os.stat("/proc/self/ns/net")
    if (parent.st_dev, parent.st_ino) == (current.st_dev, current.st_ino):
        raise RuntimeError("the HAProxy test requires a separate network namespace")
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    sys.path.insert(0, str(SERVER))
    import maintenance_drain

    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        cert = temporary / "cert.pem"
        key = temporary / "key.pem"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
                "-nodes",
                "-keyout",
                str(key),
                "-out",
                str(cert),
                "-days",
                "1",
                "-subj",
                "/CN=relay.test",
            ],
            check=True,
            capture_output=True,
        )
        cert.write_bytes(key.read_bytes() + cert.read_bytes())
        master_socket = temporary / "master.sock"
        maintenance_drain.MASTER_SOCKET = master_socket
        with socket.socket() as backend:
            backend.bind(("127.0.0.1", 0))
            backend.listen()
            backend.settimeout(5)
            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                port = reserved.getsockname()[1]
            config = temporary / "haproxy.cfg"
            config.write_text(f"""global
    maxconn 512
    ssl-default-bind-options ssl-min-ver TLSv1.3
defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h
frontend relay
    bind 127.0.0.1:{port} ssl crt {cert} alpn http/1.1
    tcp-request inspect-delay 5s
    tcp-request content reject unless {{ req.payload(0,8) -m str "CONNECT " }}
    default_backend tinyproxy
backend tinyproxy
    server tinyproxy 127.0.0.1:{backend.getsockname()[1]}
""")
            with (temporary / "haproxy.log").open("w+") as log:
                process = subprocess.Popen(
                    [HAPROXY, "-W", "-db", "-S", str(master_socket), "-f", str(config)],
                    stdout=log,
                    stderr=log,
                    start_new_session=True,
                )
                try:
                    wait_until(
                        lambda: master_socket.exists() or process.poll() is not None
                    )
                    if process.poll() is not None:
                        log.seek(0)
                        raise RuntimeError("disposable HAProxy failed: " + log.read())

                    def ready():
                        if process.poll() is not None:
                            log.seek(0)
                            raise RuntimeError(
                                "disposable HAProxy exited: " + log.read()
                            )
                        try:
                            identity = maintenance_drain.haproxy_identity()
                            return (
                                identity
                                if not maintenance_drain.haproxy_busy()
                                else None
                            )
                        except (OSError, RuntimeError):
                            return None

                    identity = wait_until(ready)
                    with (
                        socket.create_connection(("127.0.0.1", port), timeout=5) as raw,
                        ssl._create_unverified_context().wrap_socket(
                            raw, server_hostname="relay.test"
                        ) as client,
                    ):
                        client.sendall(b"CONNECT test.invalid:443 HTTP/1.1\r\n\r\n")
                        peer, _ = backend.accept()
                        with peer:
                            peer.settimeout(5)
                            assert peer.recv(1024).startswith(b"CONNECT ")
                            wait_until(maintenance_drain.haproxy_busy)
                            assert maintenance_drain.haproxy_identity() == identity
                    wait_until(lambda: not maintenance_drain.haproxy_busy())
                finally:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)


class RelayHAProxyDrainTests(unittest.TestCase):
    def test_real_haproxy_reports_sessions_and_generation(self):
        required = os.environ.get("RC_RELAY_REQUIRE_HAPROXY") == "1"
        missing = [
            name
            for name in ("unshare", "ip", "openssl", HAPROXY)
            if not shutil.which(name)
        ]
        if sys.platform != "linux" or missing:
            if required:
                self.fail(f"Linux HAProxy test tools are required: {missing}")
            self.skipTest("Linux HAProxy test tools are unavailable")
        preflight = subprocess.run(
            ["unshare", "-Urn", "true"], capture_output=True, check=False
        )
        if preflight.returncode:
            if required:
                self.fail("user network namespaces are required")
            self.skipTest("user network namespaces are unavailable")
        parent_fd = os.open("/proc/self/ns/net", os.O_RDONLY)
        try:
            result = subprocess.run(
                ["unshare", "-Urn", sys.executable, __file__, "--lab", str(parent_fd)],
                pass_fds=(parent_fd,),
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        finally:
            os.close(parent_fd)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--lab":
        run_lab(int(sys.argv[2]))
    else:
        unittest.main()
