import json
import platform
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LOG_ROOTS = ROOT / "protocol-fixtures/host-log-roots.json"
LOG_ROOT_VARIABLE = "RC_LOG_ROOT"
UNSUPPORTED_OS_EXIT = 5


def _roots() -> dict[str, str]:
    return json.loads(LOG_ROOTS.read_text())["logRoots"]


def local_log_root() -> Path:
    system = platform.system()
    roots = _roots()
    if system not in roots:
        raise RuntimeError(f"no RemoteCoder log root is defined for {system}")
    return Path.home() / roots[system]


def log_root_shell() -> str:
    cases = " ".join(f'{system}) {LOG_ROOT_VARIABLE}="$HOME/{root}";;' for system, root in _roots().items())
    return (f'case "$(uname -s)" in {cases} '
            f'*) echo "no RemoteCoder log root is defined for $(uname -s)" >&2; exit {UNSUPPORTED_OS_EXIT};; esac; ')
