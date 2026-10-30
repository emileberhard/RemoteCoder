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
devices=[{"name":n,"id":str(i),"uid":"uid-"+n} for i,n in enumerate(["Fixture microphone","Fixture speakers","BlackHole 2ch"])]
show=lambda d: json.dumps(d) if "-f" in a else d["name"]
if "-a" in a:
 for d in devices: print(show(d))
elif "-c" in a: print(show(next(d for d in devices if d["name"]==s[route])))
else:
 name=a[a.index("-s")+1] if "-s" in a else next(d["name"] for d in devices if d["id"]==a[a.index("-i")+1])
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
    resolved = json.loads(
        (
            TOOLS.parent
            / "RemoteCoder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        ).read_text()
    )
    revision = next(
        pin["state"]["revision"] for pin in resolved["pins"] if pin["identity"] == "webrtc"
    )
    packages = tmp_path / "Library/Developer/Xcode/DerivedData/Fixture/SourcePackages"
    xcframework = packages / "artifacts/webrtc/WebRTC/WebRTC.xcframework"
    framework = xcframework / "macos-x86_64_arm64/WebRTC.framework"
    framework.mkdir(parents=True)
    (framework / "WebRTC").touch()
    (packages / "workspace-state.json").write_text(
        json.dumps(
            {
                "object": {
                    "dependencies": [
                        {
                            "packageRef": {"identity": "webrtc"},
                            "state": {"checkoutState": {"revision": revision}},
                        }
                    ],
                    "artifacts": [
                        {
                            "packageRef": {"identity": "webrtc"},
                            "targetName": "WebRTC",
                            "path": str(xcframework),
                        }
                    ],
                }
            }
        )
    )
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
    assert [call for call in restored["calls"] if "-s" in call or "-i" in call] == [
        ["-s", "BlackHole 2ch", "-t", "input"],
        ["-s", "BlackHole 2ch", "-t", "output"],
        ["-t", "input", "-i", "0"],
        ["-t", "output", "-i", "1"],
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
    assert "Existing audio routes are unknown" not in result.stderr
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
