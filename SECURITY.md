# Security

Report vulnerabilities privately through
[GitHub security advisories](https://github.com/emileberhard/RemoteCoder/security/advisories/new).
Include the affected version/commit, prerequisites, reproduction steps and
expected impact. Use synthetic inputs and redact credentials, private hostnames,
transcripts, device tokens and personal files. Do not publish an exploit or
sensitive report in a public issue.

Security fixes target the latest stable release. Older versions and custom
builds should update to a supported release; there is no promise of backports.

## Execution authority

An authenticated gateway client has the authority of the host user running the
gateway, including command execution, files, provider accounts and configured
integrations. Revocable installation credentials identify installations; they
are not reduced-privilege users. Anyone admitted by a browser bridge can use
its bound gateways. Do not use a shared bridge or gateway as a tenant boundary.

Keep listeners behind your chosen authenticated private network or secured TLS
endpoint. Use a cryptographically random operator token, private credential
files and HTTPS/WSS for remote access. A trusted-network HTTP/WS setting is an
explicit reliance on that network's protection. Never publish operator tokens,
provider credentials, private keys, release signing material or local config.

The gateway's optional LAN route uses an SPKI pin learned through an already
authorized configured route. A proxy or relay does not remove bearer-token or
inner TLS requirements. Network reachability does not grant gateway access.

Agents and their generated content are powerful inputs. Repository instructions,
attachments, tool output and webpages can influence an agent that has host
execution permission. Generated HTML visuals intentionally support external
HTTPS resources. Review what access an agent needs before giving it the host's
credentials or private data. Optional push, carrier, speech and navigation
services have separate credentials and consequences described in their guides.

Public contribution CI must run on disposable hosted workers without personal
network access or deployment secrets. Production signing and fleet deployment
belong to the private maintainer repository and consume an exact reviewed
release identity. A passing build is not evidence of deployment or device
acceptance.
