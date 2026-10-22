# Build the matched Codex runtime

RemoteCoder uses the public Apache-2.0 [Codex fork](https://github.com/emileberhard/codex). A stock upstream binary does not implement all of RemoteCoder's history, authentication and restart contracts. The exact source is `codexForkCommit` in [compatibility.json](compatibility.json); a newer fork `main` is not automatically the matched runtime.

The supported bootstrap is a source build on an Apple Silicon Mac. Install the Xcode version in `.xcode-version`, Rust/rustup, Python, uv and just. Run the following from the RemoteCoder checkout:

```sh
git clone https://github.com/emileberhard/codex.git ../remotecoder-codex
python3 - <<'PY'
import json
import subprocess
from pathlib import Path
commit = json.loads(Path("docs/codex/compatibility.json").read_text())["codexForkCommit"]
subprocess.run(["git", "-C", "../remotecoder-codex", "checkout", "--detach", commit], check=True)
PY
RC_GATEWAY_BUILD_HOST=local just codex-runtime-build ../remotecoder-codex "$HOME/.local/share/remotecoder/codex-package"
just codex-runtime-approve "$HOME/.local/share/remotecoder/codex-package"
```

The builder installs the fork's pinned Rust toolchain through rustup as needed, verifies the pinned OpenAI V8 archive, resolves the checksum-pinned ripgrep distribution, and produces the complete package: `bin/codex`, its `bin/codex-code-mode-host` sibling, `codex-path/rg`, package metadata, LICENSE, NOTICE and LICENSES. Keep this layout intact. The built package may have different executable hashes from the maintainer's build; approval records the actual local bytes while retaining the exact source/version identity.

Sign in with your own account and create the gateway configuration:

```sh
"$HOME/.local/share/remotecoder/codex-package/bin/codex" login
python3 host-daemon-rs/scripts/setup.py --codex "$HOME/.local/share/remotecoder/codex-package/bin/codex"
```

Then continue with the gateway README's build and startup instructions. The setup helper creates a private gateway token and refuses to overwrite an existing environment. This bootstrap does not require the maintainer's router, hostnames, configuration repository, signing identities or deployed runtime paths.

Do not replace executables or the current package directory under a running daemon. The transactional installer owns exact interruption, recovery, activation and rollback. Maintainer deployments follow the private [RemoteCoder-deploy operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

Approval also records `runtimePackageSHA256`, covering package resources, notices and executable modes. A tagged release resolves that exact fingerprint from the build owner’s bounded immutable package cache and retains a verified copy inside its versioned release cache before compiling or deploying. Missing packages fail early; build-cache eviction cannot remove the release’s retained package. Source/version and executable-hash checks remain mandatory.

The checked-in source pins and hashes describe one matched runtime. Host-specific acceptance, installed paths and private configuration are operator records outside this repository.
