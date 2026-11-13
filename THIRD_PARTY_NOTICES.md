# Third-party notices

RemoteCoder's license applies to its own code. The components below retain their own licenses, copyright notices and source rights. The RemoteCoder name and app icon are reserved; no trademark license is granted. The Claude, OpenAI and GitHub Copilot marks identify the agents and services RemoteCoder connects to; they belong to Anthropic, OpenAI and GitHub, which do not sponsor or endorse RemoteCoder.

| Distribution | Component | License and notices |
| --- | --- | --- |
| iOS and Mac apps | [SpeechKit 0.8.0](https://github.com/emileberhard/SpeechKit/tree/0.8.0) | MIT; [notice](LICENSES/SpeechKit.txt), [source](https://github.com/emileberhard/SpeechKit) |
| iOS and Mac apps | WeSpeaker ResNet34-LM speaker model, converted to Core ML and 8-bit palettized by [SpeechKit 0.8.0](https://github.com/emileberhard/SpeechKit/tree/0.8.0) | CC BY 4.0; [license](LICENSES/CC-BY-4.0.txt), [weights and attribution](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM/tree/f0c48c298fd835726c27956a5d617bad7115627e), [WeSpeaker source](https://github.com/wenet-e2e/wespeaker) |
| iOS and Mac apps, browser client | Codex mark path from Lobe Icons (`@lobehub/icons-static-svg` 1.95.0) | MIT; [license](LICENSES/LobeHub-icons.txt), [source](https://github.com/lobehub/lobe-icons) |
| iOS and Mac apps | GitHub Copilot mark path from Primer Octicons (`copilot-24`, as packaged in Simple Icons 16.32.0) | MIT; [license](LICENSES/Primer-Octicons.txt), [source](https://github.com/primer/octicons) |
| iOS app | WebRTC 156.0.0 | BSD-3-Clause; [WebRTC](LICENSES/WebRTC.txt), [native third-party notices](LICENSES/WebRTC-third-party.md) and [Swift package wrapper](LICENSES/WebRTC-package.txt) |
| iOS app, when enabled | Google Maps and Navigation SDKs 11.2.0 | [Google terms and bundled notices](LICENSES/Google-SDKs.md); Google licenses also remain available in Settings |
| iOS and Mac apps | Mermaid 12.0.0 and its bundled dependencies | MIT, Apache-2.0, BSD, ISC and EPL-2.0; [native bundle notices](LICENSES/mermaid-native.md) and [EPL-2.0 text](LICENSES/EPL-2.0.txt) |
| Linux gateway/runtime | Linux Rust dependency closures and native libraries | [Gateway](LICENSES/gateway-linux-rust.md), [Codex CLI](LICENSES/codex-linux-rust.md), [code-mode host](LICENSES/codex-linux-code-mode-host-rust.md), [native components](LICENSES/linux-native.md) |
| Gateway | Rust dependencies | [Versioned inventory, source and license texts](LICENSES/gateway-rust.md) |
| Codex runtime | Modified OpenAI Codex and codex-code-mode-host | Apache-2.0; [OpenAI license](LICENSES/Codex-Apache-2.0.txt), [OpenAI/Ratatui NOTICE](LICENSES/Codex-NOTICE.txt), [CLI Rust dependencies](LICENSES/codex-rust.md) and [code-mode-host Rust dependencies](LICENSES/codex-code-mode-host-rust.md) |
| Codex runtime | ripgrep 15.2.0 | MIT; [license and attribution](LICENSES/ripgrep.txt) |
| Codex code-mode host | rusty_v8, V8 and native dependencies | [License and attribution](LICENSES/V8.txt) |
| Browser client | npm dependencies, including Mermaid 12.2.0 and ELK 0.9.3 | [Versioned inventory and license texts](LICENSES/web-npm.md) |

ELK is distributed unmodified as part of Mermaid. Its source is available at [elkjs 0.9.3](https://github.com/kieler/elkjs/tree/0.9.3) and as a [versioned source archive](https://registry.npmjs.org/elkjs/-/elkjs-0.9.3.tgz). ELK remains under EPL-2.0; RemoteCoder's license does not restrict those rights. Native Mermaid's exact embedded dependency versions and source links appear in its notice file.

The gateway's MPL-2.0 dependencies are unmodified. Their exact versioned source archives are linked in the Rust inventory. These source files remain available under MPL-2.0, including when combined with RemoteCoder. The same applies to MPL-2.0 components listed in the Codex runtime inventory.

The host runtime bundles Codex, codex-code-mode-host and ripgrep. The private Linux host artifact additionally retains the unmodified, separately licensed Claude Code binary selected in `docs/claude/compatibility.json`; Anthropic’s terms apply to that binary, and it is not covered by RemoteCoder’s license. Public redistribution must obtain its own authorization. tmux, ChatGPT and llm-router are separately installed and retain their own terms. Optional Python voice environments are resolved from the checked-in uv lockfiles rather than embedded in the native apps or gateway binary; redistributors of a prepared environment must also retain its dependency and linked FFmpeg notices.

The three WAV resources are original synthesized audio: the notification sound is reproduced by `scripts/generate-notification-sound.py`; the message-sent sound uses 523.25/659.25 Hz sine tones, and the thinking sound uses 392/784 Hz sine tones. No sampled audio is included. The app icon is original artwork created for RemoteCoder with OpenAI image generation; it is reserved and not licensed for other uses.

Generated Rust inventories use cargo-about 0.9.2. `scripts/render-third-party-notices.py` renders its JSON without local build paths. Retain this file and the LICENSES directory together in distributions.
