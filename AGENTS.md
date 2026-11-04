# Agent Fleet Agent Rules

## Scope

Agent Fleet brings herdr-core coding agents into Emacs. Core owns programs,
PTYs and status; Fleet owns Emacs interaction, attention and code review.
Read README.md for behavior and docs/PROTOCOL.md for the verified contract.
Follow the user's scope; ROADMAP.md is not implementation authorization.

Support Emacs 29.1+. Keep Ghostel, Magit, Consult and GUI optional.
Public commands must be autoloadable. Keymaps are opt-in or buffer-local.
Write Markdown in English.

## Ownership and state

- herdr-core.el owns transport, pinned endpoints, validation, cache, events
  and reconnect. Feature modules reuse its APIs.
- agent-fleet.el owns Agent identity, selection and shared control operations.
  Display owns generic frame lifecycle. Feature modules own their interactions.
- Core is the sole lifecycle authority. Keep runtime state, reported work
  status and connection health distinct. Unreported status stays unreported.
- Install snapshots before subsequent events, apply events before hooks, and
  isolate consumer failures. Reconnect gets a fresh snapshot; do not replay
  mutation requests after an uncertain result.
- Use Core identity, terminal address and creation identity, never names, to
  pin operations and buffers. Preserve structured errors and partial outcomes.
- Parent relationships come from Core; do not maintain a Fleet Task lifecycle.
- Project is a canonical codebase identity. Unify linked Git worktrees and
  retain absent Projects. Never interpret a remote path on the local machine.

## Lifecycle safety

- Closing an attach buffer/process only detaches the viewer.
- Prompt submission is explicit. Sending, acknowledged submission and work
  completion are different outcomes. Preserve drafts on errors and uncertainty.
- Kill is explicit and includes dependent-descendant impact. Do not silently
  broaden it or pretend a client preview freezes server topology.
- Cleanup only removes finished Fleet history through terminal.rm. Never call
  terminal.kill or delete files from cleanup. A live agent reporting done is
  protected. Unknown ownership/identity fails closed.
- Revalidate reviewed targets before each removal. Preserve parent records
  with remaining children. Stop dispatch after uncertain results; retain
  exact diagnostics and unattempted targets. Never infer acknowledgement.
- Use isolated Core sessions and temporary XDG config/state for integration
  tests; never stop or clean the user's default Core.

## Presentation

- Pin attach and all CLI subprocesses to the control connection's endpoint.
  Scope environment changes to subprocesses.
- Probe Ghostel's required APIs and native module availability.
- Dashboard reuses the selected window. Preserve per-window return buffers,
  point and scrolling; nested reviews return one step at a time. Attachment
  ends that return path only on success. Retain the review on failure.
- Auxiliary child frames require supported Emacs, GUI and APIs. Center on a
  non-child origin; preserve focus and the view when destination opening fails.
- Attach replaces the origin window. Auxiliary Fleet views must not resize
  the attached terminal; genuine frame resizing must still reach the PTY.
- Preserve origin buffers and terminal clients when closing temporary views.
  Document third-party limitations.

## Editing and verification

- Check git status; preserve unrelated changes. Use rg and apply_patch.
- Commit/push only when requested. Inspect staged changes before committing.
- Update behavior docs and tests with changes; preserve relevant safety
  regressions when replacing obsolete protocols.
- Run make test (strict compilation), git diff --check and affected live
  tests. For display changes also smoke-test graphical Emacs and real attach.
- Report actual results and unavailable validation. Never test stale bytecode.
