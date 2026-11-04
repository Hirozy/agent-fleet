# Agent Fleet Roadmap

The current implementation targets herdr-core. This file describes optional
future work and does not authorize implementation.

1. Local worktree creation: use Git, preserve a review base, and launch the
   agent in the new checkout. Directory removal remains a separate explicit
   Git/Magit operation.
2. Batch launch: report individual successes and failures and group with labels,
   without introducing a separate Task lifecycle.
3. Read-only realtime observation through hc attach --observe, with verified
   terminal size and focus behavior.
4. Remote workflows: stable machine identity, Project identity, path mapping,
   context transfer and checkout review.
5. Provider-specific status setup documentation based on verified OSC 7501
   integrations for each installed coding-agent version.

Current behavior is documented in README.md; the wire contract is in
docs/PROTOCOL.md. Preserve cleanup and attach safety throughout extensions.
