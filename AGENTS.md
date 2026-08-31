# Agent Fleet Agent Rules

This file contains mandatory, long-lived rules for agents working in this
repository. It is not a system design, implementation history, or feature
roadmap.

- Read `README.md` for current user-visible behavior.
- Read `ROADMAP.md` for non-binding product priorities.
- Read `docs/PROTOCOL.md` for the verified Herdr wire contract.
- Treat code and tests as the source of truth when descriptive documents lag,
  and update affected documentation as part of a behavior change.
- A roadmap item or protocol method is not authorization to implement it.
  Follow the user's current request and ask before expanding the product
  boundary.

## Product boundary

Agent Fleet brings Herdr-managed coding agents into Emacs. Emacs provides an
agent-centric control, viewing, contextual interaction, and review surface;
Herdr owns the agents' processes, real PTYs, and lifecycle state.

- Design features around starting, controlling, inspecting, attaching to,
  grouping, and reviewing agents.
- Treat a Herdr Session as a connection endpoint, not a user-facing resource.
  Do not add Session enumeration, runtime switching, creation, stopping,
  deletion, or multi-Session state without an explicit product decision.
- Use Herdr Workspaces internally for provisioning, pane identity, and
  worktree linkage. Do not add generic Workspace CRUD, a Workspace browser, or
  a Workspace dashboard filter without an explicit product decision.
- Use Project as the user-facing codebase grouping. A Project may contain
  agents from several Herdr Workspaces and linked Git worktrees.
- Do not treat the full RPC catalog as a backlog. Add an RPC only when it is
  necessary for an approved agent-centric workflow.
- Do not build general tab, pane, layout, server, plugin, or integration
  management UI as incidental scope.

## Supported environment

- The minimum supported Emacs version is **29.1**.
- Core behavior must work without Magit, Ghostel, Consult, Projectile, Evil, or
  a graphical display unless the invoked feature explicitly requires one.
- Do not add global key bindings. Users opt in through package keymaps.
- Preserve non-graphical and missing-optional-dependency paths with a usable
  fallback or a clear `user-error`, according to the command's documented
  contract.

## Module ownership

Put a change in its owning module whenever possible:

- `herdr-protocol.el`: socket discovery, framing, request IDs, timeouts, and
  typed protocol errors.
- `herdr-model.el`: Herdr identities, decoded model objects, and cache
  consistency.
- `herdr-events.el`: event decoding, model application, and lifecycle event
  descriptors.
- `herdr.el`: connection, subscription, reconnect, resync, and transport
  lifecycle.
- `agent-fleet.el`: agent control-plane APIs, provisioning, shared target
  resolution, candidate data, hooks, and output snapshots.
- `agent-fleet-display.el`: generic child-frame capability checks, centering,
  auxiliary-frame lifecycle, and presentation outcomes.
- `agent-fleet-dashboard.el`: dashboard rendering, row actions, filters,
  notifications, and dashboard-specific display containers.
- `agent-fleet-attach.el`: live PTY attachment and attach-buffer contextual
  commands.
- `agent-fleet-project.el`: Project detection and agent/Project mapping.
- `agent-fleet-worktree.el`: worktree RPCs, metadata views, and cleanup.
- `agent-fleet-magit.el`: optional Magit status, diff, and review integration.
- `agent-fleet-parallel.el`: Fleet-side task grouping, aggregation, and
  isolated-worktree orchestration.
- `consult-agent-fleet.el`: optional Consult integration using public Fleet
  candidate and action APIs.
- `test/`: ERT tests and the mock Herdr server.

Feature modules may depend on the control plane and model. They must not open a
second Herdr connection, duplicate target resolution, parse raw socket
payloads, or become a second state store. Optional integrations remain leaves
of the dependency graph and must not become core startup dependencies.

## State and event invariants

- Herdr is the sole source of truth for agent, pane, PTY, and lifecycle state.
  Do not infer lifecycle from terminal text or maintain competing client-side
  agent status.
- Keep state propagation event-driven. Do not poll Herdr with background
  timers. A user-requested refresh may issue an authoritative request.
- Apply a pushed event to the model before running consumer hooks. Hook
  consumers must observe the post-event cache.
- Resolve names, symbols, structs, and pane IDs through the shared target
  resolver and perform control operations using the stable Herdr identity.
- Protocol response validation and raw payload decoding belong at the protocol
  or model boundary, never in a dashboard or optional integration.
- An authoritative snapshot or list replacement must be atomic with respect to
  pushed events. Use `herdr-call-with-deferred-events`; install the snapshot,
  then replay queued events in arrival order. Replay must also occur if the
  protected operation signals.
- Fleet-side task metadata may be stored separately, but aggregate task state
  must be derived from the live member-agent model. Persisted task metadata
  must never become a second source of agent lifecycle truth.

## Project, task, and worktree invariants

- Project means a logical codebase identity derived from agent cwd. It is not
  a Herdr Workspace and is not necessarily the literal root returned by one
  `project.el` call.
- Canonicalize Project paths. Git linked worktrees of one repository must map
  to the same Project identity.
- The Project column, Project filter, completion metadata, and Project-agent
  queries must use one identity rule. Reuse `agent-fleet-project-agents` for
  set queries instead of implementing a second matcher.
- An agent with no resolvable Project has no Project identity; do not present a
  plain cwd basename as if it were a Project.
- Worktree operations use Herdr worktree RPCs and metadata. Do not infer a
  worktree relationship solely from buffer names or terminal output.
- Cleanup must protect unfinished work and preserve enough identity to retry a
  partial failure. Never equate a missing agent with successful completion.
- One member finishing must not complete or terminate a parallel task. A task
  is done only when all required members are authoritatively done.

## PTY, attach, and output invariants

- `agent-fleet-read` and output buffers are finite read snapshots. They are not
  live terminal mirrors.
- `agent-fleet-attach` is a live user-controlled PTY bridge implemented by the
  Herdr CLI inside an optional terminal backend.
- Killing an attach buffer or attach process only detaches that client. It
  must not close the Herdr pane or kill the agent.
- Reuse one live attach buffer per pane. Buffer display names are labels; pane
  IDs are the stable ownership identity.
- Do not add continuous output mirroring, client-side screen scraping, or
  lifecycle parsing from terminal contents.
- Probe the actual Ghostel capabilities used by a code path. A successful
  Lisp `require` does not prove that its dynamic module or required entry
  points are usable.
- A CLI subprocess that talks to Herdr must target the same resolved socket as
  the active control connection. Scope endpoint environment changes to that
  subprocess; do not mutate Emacs's global `process-environment`.
- Keep attach input explicit. Do not silently submit a composed prompt, inject
  Enter, or reinterpret terminal control keys beyond the documented command.

## Display invariants

- Keep generic frame lifecycle in `agent-fleet-display.el`. Feature modules
  call its presentation API and must not grow independent frame registries or
  global quit handling.
- Keep domain/view computation separate from presentation. Explicit
  `-in-buffer` and `-in-child-frame` commands should share one operation.
- Use explicit presentation outcomes. A nil domain return can still represent
  a successfully opened view; do not infer display success from arbitrary
  third-party return values.
- An explicit child-frame command must check the Emacs version, graphical
  frame, and required APIs. Follow its documented unsupported-runtime behavior
  rather than silently choosing a different presentation.
- Never nest an auxiliary child under another child. Resolve and reuse the
  non-child origin frame.
- External actions launched from a temporary dashboard child must run from the
  recorded origin. Close the dashboard child only after the destination is
  successfully opened; on nil/not-opened/error, keep it available and restore
  focus.
- Attach must replace the current origin window after success. It must not
  create a split or side window.
- Auxiliary output, tree, diff, and Magit views must not resize an attached
  terminal's parent window. Genuine parent-frame resize events must still
  propagate immediately to the PTY.
- If a third-party UI cannot work inside an auxiliary child, document the
  concrete limitation before adding an explicit window-configuration
  save/restore path. Do not silently resize the terminal.

## API and dependency rules

- Keep public commands autoloadable when they are documented for direct
  `M-x` use.
- Prefer small public candidate, resolver, hook, and presentation interfaces
  over optional packages advising or calling private implementation details.
- Do not duplicate dashboard/list/completion display semantics. Shared agent
  presentation data should remain UI-independent.
- Do not make Magit, Ghostel, Consult, Projectile, Evil, or GUI support a hard
  dependency of the core control plane.
- Preserve structured error types at layer boundaries. Interactive commands
  may translate them into concise `user-error` messages, but must not erase
  useful diagnostics for programmatic callers.

## Working-tree and editing rules

- Check `git status` before editing. Existing changes belong to the user or
  another agent unless ownership is explicitly established.
- Preserve unrelated changes and adapt to concurrent edits. Do not revert,
  restage, or reformat files outside the requested scope.
- Use `apply_patch` for manual file edits. Do not overwrite source files with
  shell redirection.
- Use `rg` or `rg --files` for repository searches when available.
- Avoid destructive Git or filesystem operations. Resolve exact targets first
  and ask when scope is ambiguous.
- Do not create a commit unless the user requests one. Before committing,
  inspect the staged diff and exclude unrelated files.
- Write all repository Markdown documentation in English. Do not add
  non-English prose to Markdown files. Treat historical non-English documents
  as migration debt; when substantively revising one, translate it or move the
  new material into an English document.
- Update README/user documentation when user-visible behavior, commands,
  configuration, or compatibility changes. Put plans and design rationale in
  dedicated documents, not in this rules file.

## Claude delegation

You are the primary orchestrator and reviewer.

For substantial implementation tasks, prefer delegating the actual
implementation to Claude Code when appropriate.

Use the `claude` CLI in non-interactive mode:

```text
claude -p "<task>"
```

Responsibilities:

- Codex owns planning, task decomposition, review, and final verification.
- Claude owns implementation when a task is delegated to it.
- Give Claude a narrow, self-contained task with:
  - objective
  - relevant files/modules
  - constraints
  - acceptance criteria
  - tests to run
- Allow Claude to inspect and modify the current working tree.
- Do not modify the same files concurrently while Claude is working.
- After Claude finishes:
  1. inspect `git diff`
  2. review the implementation independently
  3. run relevant tests
  4. fix small issues directly or delegate another bounded task to Claude
- Never accept Claude's implementation without review.

## Verification rules

At minimum, run:

```text
make test
git diff --check
```

Also apply the relevant checks below:

- Loadable Lisp changes: batch load or byte-compile with warnings treated as
  errors.
- GUI, child-frame, or attach display changes: ERT coverage for success,
  not-opened/nil, error, repeated-open, and unsupported-runtime paths, plus a
  graphical Emacs smoke test covering parent, centering, close timing, focus,
  and the origin window.
- Authoritative list/snapshot changes: test an event arriving before an older
  response is installed; verify queued order and replay on error.
- Socket discovery or default Session changes: test precedence, invalid names,
  missing sockets, reconnect endpoint stability, and subprocess environment
  isolation.
- Project identity changes: test linked worktrees, multiple Herdr Workspaces,
  unrelated Projects, no-Project agents, and agreement among all Project
  presentations and queries.
- Optional integrations: use mocks/stubs in ordinary ERT so the default suite
  does not require external packages or services; test the real integration in
  a separate optional job when available.

Report the actual commands and results. Do not claim a check that was not run,
and record unavailable graphical or live-service validation explicitly.
