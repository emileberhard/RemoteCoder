import json
import subprocess
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]


@pytest.fixture
def isolated_routes(tmp_path):
    binaries = tmp_path / "bin"
    binaries.mkdir()
    state = tmp_path / "routes.json"
    state.write_text(
        json.dumps(
            {"input": "Fixture microphone", "output": "Fixture speakers", "calls": []}
        )
    )
    driver = binaries / "SwitchAudioSource"
    driver.write_text("""#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ["PROBE_ROUTE_STATE"])
s=json.loads(p.read_text())
a=sys.argv[1:]
s["calls"].append(a)
route=a[a.index("-t")+1]
if "-a" in a: print("BlackHole 2ch")
elif "-c" in a: print(s[route])
elif "-s" in a:
 name=a[a.index("-s")+1]
 if os.environ.get("PROBE_FAIL_RESTORE")=="1" and name=="Fixture speakers":
  p.write_text(json.dumps(s)); sys.exit(1)
 s[route]=name
p.write_text(json.dumps(s))
""")
    driver.chmod(0o700)
    hostname = binaries / "hostname"
    hostname.write_text("#!/bin/sh\nprintf 'fixture-macbook\\n'\n")
    hostname.chmod(0o700)
    compiler = binaries / "xcrun"
    compiler.write_text("""#!/usr/bin/env python3
import sys
from pathlib import Path
out=Path(sys.argv[sys.argv.index("-o")+1])
out.write_text("#!/usr/bin/env python3\\nimport json,os\\nfrom pathlib import Path\\ns=json.loads(Path(os.environ['PROBE_ROUTE_STATE']).read_text())\\nassert s['input']==s['output']=='BlackHole 2ch'\\n")
out.chmod(0o700)
""")
    compiler.chmod(0o700)
    framework = (
        tmp_path
        / "Library/Developer/Xcode/DerivedData/Fixture/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework"
    )
    framework.mkdir(parents=True)
    environment = {
        "HOME": str(tmp_path),
        "PATH": f"{binaries}:/usr/bin:/bin:/usr/sbin:/sbin",
        "PROBE_ROUTE_STATE": str(state),
    }
    return tmp_path, state, environment


def test_silent_signaling_routes_before_executable_and_restores_both(isolated_routes):
    _, state, environment = isolated_routes
    result = subprocess.run(
        ["/bin/zsh", str(TOOLS / "realtime-voice-probe"), "--silent"],
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    restored = json.loads(state.read_text())
    assert restored["input"] == "Fixture microphone"
    assert restored["output"] == "Fixture speakers"
    assert [call for call in restored["calls"] if "-s" in call] == [
        ["-s", "BlackHole 2ch", "-t", "input"],
        ["-s", "BlackHole 2ch", "-t", "output"],
        ["-s", "Fixture microphone", "-t", "input"],
        ["-s", "Fixture speakers", "-t", "output"],
    ]


def test_silent_missing_fixture_refuses_without_generating_or_changing_routes(
    isolated_routes,
):
    home, state, environment = isolated_routes
    result = subprocess.run(
        ["/bin/zsh", str(TOOLS / "realtime-voice-probe"), "--silent", "--media"],
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 2
    assert "existing cached fixture" in result.stderr
    assert not list(
        (home / "Library/Caches/RemoteCoder/realtime-voice-probe").glob("*.mp3")
    )
    assert not any("-s" in call for call in json.loads(state.read_text())["calls"])


def test_restore_failure_fails_an_otherwise_successful_silent_probe(isolated_routes):
    _, _, environment = isolated_routes
    environment["PROBE_FAIL_RESTORE"] = "1"
    result = subprocess.run(
        ["/bin/zsh", str(TOOLS / "realtime-voice-probe"), "--silent"],
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode != 0
    assert "FAIL restoring audio output" in result.stderr


def test_build_only_does_not_acquire_routes_prepare_media_or_run_probe(isolated_routes):
    home, state, environment = isolated_routes
    result = subprocess.run(
        [
            "/bin/zsh",
            str(TOOLS / "realtime-voice-probe"),
            "--build-only",
            "--silent",
            "--media",
        ],
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert "compiled; no live session" in result.stdout
    assert json.loads(state.read_text())["calls"] == []
    assert not (home / "Library/Caches/RemoteCoder/realtime-voice-probe").exists()
