# Agent Fleet Roadmap

The current implementation targets herdr-core. This file describes optional
future work and does not authorize implementation.

1. Remote validation over real SSH and an independently configured host,
   beyond the isolated two-Core relay integration test.
2. Full authenticated provider-turn validation, including permission dialogs,
   errors, interruption and completion; the current guide separates source
   evidence from startup-only checks.

Local worktree creation, batch launch reports, read-only observation and remote
agent workflows are implemented. Directory removal remains a separate explicit
Git/Magit operation. Batch labels do not introduce a separate Task lifecycle.
Provider setup and verified-version notes are in [docs/PROVIDERS.md](docs/PROVIDERS.md).

Current behavior is documented in README.md; the wire contract is in
docs/PROTOCOL.md. Preserve cleanup and attach safety throughout extensions.
