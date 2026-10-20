# Agent Fleet Agent Rules

## Scope and references

Agent Fleet brings Herdr-managed coding agents into Emacs. Herdr owns processes,
PTYs, and lifecycle state; Emacs provides control, viewing, and review.

- Follow the user's request. Roadmap items and available RPCs do not authorize
  additional features.
- Read `README.md` for behavior, `docs/PROTOCOL.md` for the verified wire
  contract, and `ROADMAP.md` when discussing priorities. Code and tests take
  precedence when documentation lags.
- Project is the user-facing codebase grouping. Sessions are connection
  endpoints; Workspaces are internal provisioning and ownership identities.
  Do not add generic Session, Workspace, or layout management without approval.
- Support Emacs **29.1+**. Keep optional packages and GUI support optional;
  provide the documented fallback or a clear `user-error`. Use opt-in keymaps,
  not global bindings. Documented public commands must be autoloadable.

## Code ownership

- `herdr-protocol.el`, `herdr-model.el`, `herdr-events.el`, `herdr.el` own
  transport, decoding/validation, cache updates, and connection lifecycle.
- `agent-fleet.el` owns shared control APIs, target resolution, candidates,
  hooks, and output snapshots. Feature modules reuse these interfaces.
- `agent-fleet-display.el` owns generic frame lifecycle and presentation;
  dashboard, attach, and editor modules own their respective interactions.
- Project, worktree, parallel, and cleanup behavior belongs in the matching
  `agent-fleet-*.el` module. Magit and Consult integrations remain optional leaves.
- Do not duplicate connections, target resolution, state stores, or raw payload
  parsing in feature modules. Preserve structured errors for Lisp callers.

## State and cleanup safety

- Herdr is the sole lifecycle authority. Use pushed events, not background
  polling or terminal-text inference. Output buffers are finite snapshots.
- Apply events to the model before consumer hooks. For authoritative cache
  replacement, use `herdr-call-with-deferred-events`; replay queued events in
  order, including on error.
- Use stable pane/Herdr IDs for operations and ownership, not display names.
- Canonicalize Project paths and unify linked worktrees under one identity.
  Reuse `agent-fleet-project-agents` for set queries. An unresolved Project
  stays absent; do not substitute a cwd basename.
- Derive task state from live members. All required members must be
  authoritatively done before a task is done; missing agents are not completion.
- Cleanup preserves every agent-associated Workspace and its resources,
  regardless of status. Unknown ownership fails closed. Recheck identities and
  ownership before each destructive operation; retain partial results and
  enough identity for retry. Never infer success without acknowledgement.
- Use Herdr RPCs and metadata for worktree operations. A clean working tree
  does not prove commits are safe to discard; cleanup must preserve worktrees.

## Attach and display

- Reuse one live attach buffer per pane. Killing its buffer/process only
  detaches the client; it must not close the Herdr pane or agent.
- CLI subprocesses must use the active connection's resolved socket. Scope
  environment changes to the subprocess, not global `process-environment`.
- Probe required Ghostel APIs and module availability, not just `require`.
  Keep prompt submission explicit; never silently inject Enter.
- Use the shared presentation API and explicit success outcomes. A third-party
  nil return does not establish whether a view opened.
- Child frames require supported Emacs, GUI, and APIs; follow the documented
  fallback. Center them on the non-child origin; never nest auxiliary children.
- Launch dashboard-child actions from the recorded origin. Close the child
  only after the destination opens; restore focus and retain it on failure.
- Attach replaces the origin window without splitting. Auxiliary output,
  tree, diff, and Magit views must not resize the attached terminal window;
  genuine parent-frame resizing must still reach the PTY. Document third-party
  limitations before adding window-configuration save/restore exceptions.
- Closing a temporary review/view must preserve its origin buffer and any
  attached terminal client.

## Editing and verification

- Check `git status` before editing; preserve unrelated and concurrent changes.
  Use `apply_patch` for manual edits and `rg` for searches. Avoid destructive
  Git/filesystem operations; clarify ambiguous targets first.
- Commit only when requested, after inspecting the staged diff.
- Write Markdown documentation in English. Update user docs when behavior
  changes; keep plans and implementation history out of this file.
- For code changes, run `make test` (includes compilation with warnings as
  errors) and `git diff --check`. For documentation-only edits, check the diff
  and referenced paths. Preserve existing safety regression coverage.
- Add relevant regressions: event ordering and replay on error for snapshots;
  endpoint stability and subprocess isolation for socket changes; linked
  worktrees and absent Projects for identity changes; success, nil/error,
  repeated-open, and unsupported-runtime paths for display changes.
- For GUI/attach display changes, also smoke-test graphical Emacs, including
  centering, focus, close timing, and origin preservation. Use mocks for ordinary
  ERT; keep real-service/optional-integration checks separate.
- Report actual checks and results, including unavailable GUI or live-service
  validation. Do not claim tests passed against current code if they loaded
  stale bytecode.
