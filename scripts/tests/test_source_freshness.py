import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from build_support import source_sync_command


class SourceFreshnessTests(unittest.TestCase):
    def test_current_bytes_build_forward_reverse_and_reuse_identical_sources(self):
        for timestamps in ("backdated", "same-mtime"):
            with (
                self.subTest(timestamps=timestamps),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                source = root / "source"
                mirror = root / "mirror"
                (source / "src").mkdir(parents=True)
                mirror.mkdir()
                (source / "Cargo.toml").write_text(
                    '[package]\nname = "source-freshness"\nversion = "0.1.0"\nedition = "2024"\n'
                )
                main = source / "src/main.rs"
                main.write_text('fn main() { println!("left"); }\n')
                environment = os.environ.copy()
                environment.update(
                    {
                        "CARGO_TARGET_DIR": str(root / "target"),
                        "CARGO_BUILD_BUILD_DIR": str(root / "target"),
                        "RUSTC_WRAPPER": "",
                    }
                )
                subprocess.run(
                    ["cargo", "generate-lockfile", "--offline"],
                    cwd=source,
                    env=environment,
                    capture_output=True,
                    check=True,
                )
                executable = root / "target/debug/source-freshness"
                previous = None
                for index, value in enumerate(("left", "next", "left", "left")):
                    main.write_text('fn main() { println!("' + value + '"); }\n')
                    mtime = 1_600_000_000 - index
                    if timestamps == "same-mtime" and previous is not None:
                        mtime = (mirror / "src/main.rs").stat().st_mtime
                    os.utime(main, (mtime, mtime))
                    stage = root / "runs" / str(index)
                    stage.mkdir(parents=True)
                    snapshot_command = [
                        sys.executable,
                        str(SCRIPTS / "rsync-source.py"),
                        "sync",
                        "--link-dest=" + str(mirror),
                        str(source) + "/",
                        str(stage) + "/",
                    ]
                    subprocess.run(snapshot_command, check=True, capture_output=True)
                    fingerprints = {
                        name: self.fingerprint(directory)
                        for name, directory in (("source", source), ("stage", stage))
                    }
                    print(
                        json.dumps(
                            {
                                "timestamps": timestamps,
                                "step": index,
                                "snapshotCommand": snapshot_command,
                                "fingerprints": fingerprints,
                            }
                        ),
                        flush=True,
                    )
                    self.assertEqual(fingerprints["stage"], fingerprints["source"])
                    if index == 3:
                        self.assertEqual(
                            (stage / "src/main.rs").stat().st_ino,
                            (mirror / "src/main.rs").stat().st_ino,
                        )
                    before = {
                        str(path.relative_to(mirror)): path.stat().st_mtime_ns
                        for path in mirror.rglob("*")
                        if path.is_file()
                    }
                    promotion_command = source_sync_command(
                        [
                            "--delete",
                            str(stage) + "/",
                            str(mirror) + "/",
                        ]
                    )
                    subprocess.run(promotion_command, check=True, capture_output=True)
                    self.assertEqual(self.fingerprint(mirror), fingerprints["source"])
                    after = {
                        str(path.relative_to(mirror)): path.stat().st_mtime_ns
                        for path in mirror.rglob("*")
                        if path.is_file()
                    }
                    cargo_command = [
                        "cargo",
                        "build",
                        "--locked",
                        "--offline",
                        "--verbose",
                    ]
                    build = subprocess.run(
                        cargo_command,
                        cwd=mirror,
                        env=environment,
                        capture_output=True,
                        text=True,
                        check=True,
                    )
                    output = subprocess.check_output(
                        [str(executable)], text=True
                    ).strip()
                    binary_mtime = executable.stat().st_mtime_ns
                    print(
                        json.dumps(
                            {
                                "timestamps": timestamps,
                                "step": index,
                                "promotionCommand": promotion_command,
                                "mirrorFingerprint": self.fingerprint(mirror),
                                "sourceMtimesBefore": before,
                                "sourceMtimesAfter": after,
                                "cargoCommand": cargo_command,
                                "cargoLog": build.stderr,
                                "expected": value,
                                "actual": output,
                                "executableSHA256": hashlib.sha256(
                                    executable.read_bytes()
                                ).hexdigest(),
                                "executableMtime": binary_mtime,
                            }
                        ),
                        flush=True,
                    )
                    self.assertEqual(output, value)
                    if previous is not None:
                        for name in ("Cargo.toml", "Cargo.lock"):
                            self.assertEqual(after[name], before[name])
                    if index == 3:
                        self.assertEqual(after, before)
                        self.assertEqual(binary_mtime, previous)
                    previous = binary_mtime

    @staticmethod
    def fingerprint(directory):
        digest = hashlib.sha256()
        for path in sorted(directory.rglob("*")):
            if path.is_file():
                digest.update(str(path.relative_to(directory)).encode() + b"\0")
                digest.update(path.read_bytes() + b"\0")
        return digest.hexdigest()
