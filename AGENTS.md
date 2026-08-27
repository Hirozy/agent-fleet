# Agent Fleet Development Guide

This document defines project-level constraints for future agents working in
this repository. Agent Fleet is an Emacs Lisp client: Emacs provides the
control and viewing interface, while Herdr manages the agents' real PTYs.

## Current baseline

- The active branch is `main`.
- The committed native child-frame dashboard implementation is in commit
  `95bcc32`.
- The committed event-safe `agent.list` reconciliation is in commit `f085c5a`.
- The minimum supported Emacs version is **29.1**.
- Core behavior must remain event-driven; do not poll Herdr state with timers.

## Module responsibilities

- `herdr*.el`: Unix socket protocol, events, model, and connection lifecycle.
- `agent-fleet.el`: control-plane APIs including start, prompt, read, wait,
  interrupt, rename, switch, kill, and output commands.
- `agent-fleet-dashboard.el`: the `*Agent Fleet*` table, row actions, filters,
  notifications, and dashboard display backends.
- `agent-fleet-attach.el`: live PTY attachment through
  `herdr agent attach <pane-id>`, supporting Ghostel and an external command
  fallback.
- `agent-fleet-worktree.el`: worktree listing, opening, status, and cleanup.
- `agent-fleet-magit.el`: optional Magit status and diff integration.
- `agent-fleet-project.el`: `project.el` project detection and agent/worktree
  mapping.
- `agent-fleet-parallel.el`: parallel agents, task aggregation, and isolated
  worktrees.
- `test/`: ERT tests and the mock Herdr server.

Implement a feature in its owning module whenever possible. Do not turn
optional terminal backends, Magit, or GUI dependencies into mandatory core
startup dependencies.

## Agent Fleet architecture

Agent Fleet is organized as an event-driven control plane over Herdr. Emacs
does not own the agents' long-running processes or their PTYs; it sends
commands to Herdr, maintains a local model of the returned state, and renders
user-facing views.

```text
Herdr server and agent PTYs
            │ Unix socket / JSON protocol
            ▼
     herdr-protocol.el
            │ decoded responses and events
            ▼
  herdr-model.el + herdr-events.el
            │ cache updates and lifecycle hooks
            ▼
      agent-fleet.el
            │ control commands and target resolution
      ┌─────┴──────────────┐
      ▼                    ▼
 agent-fleet-display.el   feature modules
 presentation lifecycle    worktree / magit / project / parallel
      │                    │
      └──────┬─────────────┘
             ▼
     dashboard / attach
     contextual interaction
```

### Data and control flow

1. A user command resolves an agent name, pane id, symbol, or model object to a
   stable Herdr identity.
2. The owning control module sends an RPC through the Herdr protocol layer.
3. Responses are decoded and validated at the protocol boundary. Do not make
   dashboard or integration modules parse raw socket payloads.
4. Pushed events are applied to the local model before lifecycle hooks run.
   Consumers can therefore read a post-event cache from their hooks without
   polling or issuing a compensating refresh.
5. The dashboard and other views render the cache. A user-requested refresh may
   explicitly fetch a fresh server snapshot, but no background polling timer
   should be introduced.
6. A synchronous authoritative cache rebuild must be atomic with respect to the
   subscription stream. Use `herdr-call-with-deferred-events` around the request
   and cache replacement: events received while the request pumps process output
   are copied into a queue, then replayed in arrival order after the snapshot is
   installed. The queue must also flush when the protected operation signals.

### Layering rules

- The protocol layer owns socket framing, request IDs, timeouts, subscriptions,
  and typed error handling.
- The model layer owns agent, workspace, task, and worktree identities plus
  cache consistency. It must not contain display logic.
- The control plane owns user commands, target resolution, provisioning, and
  translating high-level operations into Herdr RPCs.
- Feature modules build on the control plane and model. They should not create
  a second connection, duplicate target resolution, or bypass the model with
  ad-hoc socket calls.
- The display module (`agent-fleet-display.el`) owns generic frame lifecycle:
  child-frame capability checks, frame parameter merging, parent resolution,
  centering, auxiliary child reuse/close, and the `quit-restore-window` advice.
  It depends only on Emacs primitives, not on Magit, worktree, attach, the
  dashboard buffer, or any Herdr RPC. Feature modules call its `--aux-run`
  API; the dashboard calls its capability and centering helpers.
- GUI and optional integrations are leaves of the dependency graph. Their
  absence must not prevent the core control plane from loading.
- The dashboard is a view and interaction layer. It may invoke control
  commands, but it must not become a second state store or protocol client.

### PTY and output boundaries

There are two deliberately different ways to inspect an agent:

- `agent-fleet-read` and the output view commands
  (`agent-fleet-show-output-in-buffer` / `-in-child-frame`) request a read
  snapshot. Their buffers are derived views and must not be treated as a live
  terminal mirror.
- `agent-fleet-attach` starts the Herdr CLI attach bridge inside an optional
  Emacs terminal backend. This is a live user-controlled PTY session. Killing
  its buffer or process detaches the client but does not close the Herdr pane.

Do not implement continuous output mirroring, client-side status parsing, or
agent lifecycle inference from terminal text. Herdr remains the source of
truth for state and lifecycle.

### Worktree and task relationships

An agent may run in the primary checkout or in an isolated Git worktree. The
project layer maps linked worktrees to their canonical project, while the
worktree layer owns worktree RPCs and metadata. Parallel tasks create separate
worktrees and track members as one aggregate task; task state must be derived
from the member agent states rather than inferred from buffer contents.

### Display lifecycle

The dashboard display backend is independent from the control-plane data flow:

- a regular buffer uses ordinary Emacs window display;
- a child frame stores its parent and lifecycle metadata in frame parameters;
- a standalone frame stores its origin and can be reused;
- external actions select the recorded origin frame, display the destination,
  and then close the temporary child frame only after success.

Keep frame lifecycle handling centralized in the display module
(`agent-fleet-display.el`). New display backends must preserve the same
success, nil-result, error, and no-GUI fallback semantics.

## Current dashboard implementation

`M-x agent-fleet` opens a regular Emacs buffer by default. The
`agent-fleet-dashboard-display` option can select:

- `buffer`: a regular window;
- `child-frame`: a native Emacs child frame;
- `frame`: a standalone graphical frame.

The native child-frame implementation must satisfy these requirements:

- Emacs 29.1 or newer;
- a graphical frame;
- `display-buffer-in-child-frame` available at runtime;
- a clear reason and fallback to a regular buffer when requirements are not
  met;
- default centering relative to the parent frame with `left = 0.5` and
  `top = 0.5`;
- default size of approximately `0.48 × 0.55` of the parent frame, with
  proportional resizing preserved;
- reopening from an existing dashboard child frame must reuse its original
  parent and must not create recursively nested child frames;
- a standalone dashboard frame may be reused.

## Dashboard interaction contract

Dashboard row actions fall into two categories.

Inline actions remain in the current dashboard:

- refresh and project/task filters;
- prompt, interrupt, kill, and rename;
- transient help.

External-interface actions must run from the dashboard's origin frame:

- output, worktree status, working-tree diff, and Magit status/diff;
- live terminal attach.

When the dashboard is displayed in a child frame, external actions follow this
lifecycle:

1. Switch back to the frame from which the dashboard was opened.
2. Run the requested action.
3. If the destination opens successfully and returns a non-nil result, close
   the dashboard child frame.
4. If the destination returns nil, fails, or signals an error, keep the child
   dashboard open and restore its focus.

Attach has one additional requirement: after a successful attach, the terminal
must replace the current window in the origin frame, and the dashboard child
frame must then close. If attach fails, the child frame remains open so the
user can recover. Closing the dashboard, detaching, or exiting the terminal
process must never kill the Herdr agent.

## Current attach implementation

`agent-fleet-attach` accepts an agent name, pane id, symbol, or `herdr-agent`
struct. It resolves the stable pane id and starts:

```text
herdr agent attach <pane-id>
```

Backend selection uses Ghostel when its dynamic module is actually loaded. If
Ghostel is unavailable, attach reports the external `herdr agent attach`
command for the user to run. Eat and vterm are not current attach backends.

Attach buffers are named `*agent:NAME*`. They are temporary interactive views;
terminal output must not be persisted or continuously mirrored. A live attach
buffer for the same pane must be reused instead of creating a second attach
session. Killing the buffer or terminal process only detaches; it must not
close the agent pane.

## Terminal-size stability

Addressed by the auxiliary child-frame presentation layer. Every auxiliary
view (output, worktree status, Magit status, working-tree diff) has two
explicit presentation commands: an `-in-buffer` variant for an ordinary
window, and an `-in-child-frame` variant that opens the view inside a native
child frame floating over the terminal's parent frame. The view's data is
computed once regardless of presentation. The requirements this satisfies:

- the terminal stays the only full-size window in the origin parent frame;
- no splits, side windows, or other layout changes touch the terminal PTY's
  rows or columns; Magit may split only inside the auxiliary child frame;
- genuine parent-frame resizes still propagate to the PTY immediately;
- the auxiliary child frame is owned by `agent-fleet-dashboard.el` (one child
  per origin, reused across opens, never nested under another child frame);
  it fills the parent frame rather than inheriting the dashboard's compact
  dimensions, and the base layer stays free of frame lifecycle;
- closing an auxiliary child (via `q` inside the view, which is intercepted
  with `quit-restore-window` advice scoped to auxiliary frames, via
  `agent-fleet-dashboard-aux-quit`, or the lifecycle rules on nil/error
  results) deletes it, forgets the reuse entry, and refocuses the origin —
  no nested or orphaned frames.

The child-frame presentation contract is stricter than the dashboard's: an
explicit `-in-child-frame` command signals a `user-error` on an unsupported
runtime (Emacs older than 29.1, non-graphical frame, missing
`display-buffer-in-child-frame`) instead of silently falling back to a buffer.
Users who want the buffer presentation use the `-in-buffer` variant.

If a third-party interface cannot work inside an auxiliary child frame, record
the concrete limitation first, then design an explicit parent window-
configuration save/restore mechanism. Do not silently change the terminal PTY
size.

## Compatibility and optional dependencies

- Before using child frames, check the Emacs version, graphical-frame status,
  and required API availability.
- Ghostel's Lisp package may load while its dynamic module is unavailable. The
  readiness check must test actual module capability, not only whether
  `require` succeeded.
- Ghostel and Magit must not become hard dependencies of the core control
  plane.
- Non-graphical frames, missing optional dependencies, and unavailable GUI APIs
  must provide a usable fallback or a clear error message.
- Do not add global key bindings. Users opt in through
  `agent-fleet-command-map`.

## Change and verification rules

Check `git status` before editing. Preserve unrelated worktree changes. Use
`apply_patch` for file edits; do not overwrite source files with shell
redirection.

At minimum, run:

```text
make test
```

Changes involving GUI, child frames, or attach display behavior should also
include:

- ERT coverage for success, nil, error, repeated-open, and unsupported-runtime
  paths;
- a graphical Emacs smoke test checking the child frame's parent, centered
  position, close timing, and the current window after attach;
- `git diff --check`;
- batch loading or byte compilation when loadable Lisp is modified.

Changes involving authoritative list/snapshot reconciliation should include an
interleaving test where a pushed event arrives before the older response is
installed, plus coverage that queued events preserve order and still replay
when the protected operation signals.

Use mocks or stubs for the Herdr socket, optional terminal backends, and Magit
in ordinary ERT tests so they do not require external services. Report the
actual commands and results; do not merely claim that verification was done.
