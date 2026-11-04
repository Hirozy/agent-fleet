# Agent Fleet Roadmap

The current implementation targets herdr-core. This file describes optional
future work and does not authorize implementation.

1. Provider-specific status setup documentation based on verified OSC 7501
   integrations for each installed coding-agent version.
2. Remote validation over real SSH and an independently configured host,
   beyond the isolated two-Core relay integration test.

Local worktree creation, batch launch reports, read-only observation and remote
agent workflows are implemented. Directory removal remains a separate explicit
Git/Magit operation. Batch labels do not introduce a separate Task lifecycle.

Current behavior is documented in README.md; the wire contract is in
docs/PROTOCOL.md. Preserve cleanup and attach safety throughout extensions.
