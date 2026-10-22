# Contributing

Use a focused branch and pull request against `main`. Describe the problem,
resulting behavior and checks actually run. Read [AGENTS.md](AGENTS.md) and the
area instructions before changing code; keep ownership, identity, bounded
resources and exact recovery contracts intact.

Run the smallest checks that exercise the change. Use isolated state and
synthetic inputs. Never run probes against another person's gateway, send real
messages, make calls or operate a physical device without authorization.

Do not commit local configuration, credentials, transcripts, live screenshots,
operator receipts or build products. Example identities and domains must be
invented and reserved for documentation. Report vulnerabilities through
[SECURITY.md](SECURITY.md).

Contributions are submitted under the repository's [license](LICENSE).
Third-party code keeps its upstream attribution and license. Distributed forks
must use their own name and icon.
