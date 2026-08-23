# agent-fleet

An Emacs package that turns Emacs into a **multi-agent supervisor** over the
[Herdr](https://herdr.dev) terminal workspace server.

> **Do not bring the agents into Emacs. Bring their control plane into Emacs.**

Claude Code, Codex, Pi (and any future CLI agents) keep running in their real
PTY/TUI inside Herdr; Emacs sees them, organizes them, controls them, and reviews
the code they produce — over Herdr's socket API.

This repository implements **Phase 1** through **Phase 7** of the plan in
`PLAN.md`: the low-level, async, event-driven Herdr client (`herdr.el` and
friends), the agent-facing control layer (`agent-fleet.el`) that turns
Emacs into a supervisor over Herdr-managed agents — start, prompt, read,
wait, interrupt, rename, kill, switch, list, and get, driven by an event
bus rather than polling — the live supervisor dashboard
(`agent-fleet-dashboard.el`): a `tabulated-list-mode` buffer that lists
every agent with its state and refreshes itself from the event bus (no
polling) — the project layer (`agent-fleet-project.el`): `project.el`
integration that maps each agent to its Emacs project by canonical cwd,
starts agents scoped to the current project, and narrows the dashboard to
a project — the worktree layer (`agent-fleet-worktree.el`): git worktree
isolation so multiple agents work in separate checkouts of one repo, with
standalone list/open/remove/status commands and the dashboard `w` action —
the Magit layer (`agent-fleet-magit.el`): open Magit status / diff on an
agent's checkout from the dashboard `m`/`d` keys, plus a finished-worktree
cleanup command — and the parallel-orchestration layer
(`agent-fleet-parallel.el`): spawn N isolated worktree agents, send each
its own prompt, and track their aggregate status live (the package's core
value) — and the interactive-terminal layer (`agent-fleet-attach.el`):
attach live to an agent's pane inside an Emacs terminal (eat/ghostel/vterm)
so you can drive its real PTY/TUI without leaving Emacs. Broadcast/pipeline
orchestration is a later phase.

## Status

| Layer | File | Status |
|---|---|---|
| Wire transport | `herdr-protocol.el` | ✅ done |
| Data model + cache | `herdr-model.el` | ✅ done |
| Subscription logic + event bus | `herdr-events.el` | ✅ done |
| Top-level client | `herdr.el` | ✅ done |
| Fake Herdr server (tests) | `test/herdr-mock-server.el` | ✅ done |
| Agent control layer | `agent-fleet.el` | ✅ Phase 2 |
| Dashboard | `agent-fleet-dashboard.el` | ✅ Phase 3 |
| Project integration | `agent-fleet-project.el` | ✅ Phase 4 |
| Worktree isolation + management | `agent-fleet-worktree.el` | ✅ Phase 5 |
| Magit integration | `agent-fleet-magit.el` | ✅ Phase 6 |
| Parallel orchestration | `agent-fleet-parallel.el` | ✅ Phase 7 |
| Interactive terminal | `agent-fleet-attach.el` | ✅ Phase 8 |
| Broadcast / pipeline | — | ⏳ later phases |

Verified against **Herdr 0.8.2** (protocol 20). All source byte-compiles with
zero warnings; 150 unit tests (mock) + 4 live integration tests pass.
Magit is an optional dependency (PLAN §55); the Magit layer `user-error's
clearly when it is absent. Terminal backends (eat/ghostel/vterm) are likewise
optional (PLAN §45); `agent-fleet-attach` degrades gracefully when none is
installed.

## Requirements

- Emacs **29.1** or newer (developed on 30.2).
- Herdr installed and its server reachable on the local Unix socket.
- Phase 1 depends only on built-in packages: `json`, `cl-lib`, `subr-x`.

## Architecture

```
Emacs
  │
  agent-fleet-dashboard.el   live dashboard: tabulated list, faces, actions (Phase 3)
  agent-fleet-project.el     project.el mapping: cwd↔project, start-for-project (Phase 4)
  agent-fleet-worktree.el    git worktree isolation + management (Phase 5)
  agent-fleet-magit.el       Magit status/diff + cleanup (Phase 6, optional dep)
  agent-fleet-parallel.el    parallel orchestration: spawn N, aggregate status (Phase 7)
  agent-fleet-attach.el      interactive terminal: live attach to an agent pane (Phase 8, optional dep)
  agent-fleet.el             control plane: start/prompt/read/wait/kill … (Phase 2)
  │
  herdr.el          top-level: connect / request / subscribe / reconnect
  │
  herdr-events.el   subscription logic + local hook bus
  herdr-model.el    snapshot/event cache (Herdr is source of truth)
  herdr-protocol.el wire transport (newline-delimited JSON over Unix socket)
  │
  ▼
Herdr Server  ── real PTY runtime ──▶  Claude Code / Codex / Pi
```

The authoritative protocol reference — captured by reverse-engineering a live
Herdr 0.8.0 server — lives in [`docs/PROTOCOL.md`](docs/PROTOCOL.md). Read it
before touching `herdr-protocol.el`.

### Connection model (important)

Verified empirically against Herdr 0.8.0:

- **Request connections are one-shot**: open a socket, send one
  `{"id","method","params"}` request, read one `{"id","result"}` (or
  `{"id","error"}`) response, the server closes the connection. Each request
  opens a fresh connection — no request multiplexing needed.
- **Subscription connections are long-lived**: send `events.subscribe`, read the
  `subscription_started` ack, then the server pushes
  `{"event":"<kind>","data":{...}}` frames indefinitely. Pushed events have no
  `id`; they route by the underscored `event`/`data.type` field.

`herdr.el` holds N short-lived one-shot request sockets (created on demand) +
1 long-lived subscription socket (held for the session, with automatic
exponential-backoff reconnect + snapshot resync).

## Installation

This is an Emacs-Lisp package (no build step). Put the `.el` files on your
`load-path`:

```elisp
(add-to-list 'load-path "/path/to/agent-fleet")
(require 'herdr)
(global-set-key (kbd "C-c h") (make-sparse-keymap))   ; bind to taste
```

## Usage (Phase 1)

```elisp
(herdr-connect)                 ; ping -> snapshot -> subscribe
(herdr-connected-p)             ; => t
(herdr-workspaces)              ; list of workspace structs
(herdr-agents)                  ; list of agent structs (keyed by pane-id)
(herdr-find-agent "w6:p1")     ; a specific agent
(herdr-request "workspace.focus" '(("workspace_id" . "w6")))
(herdr-disconnect)

;; observe events on the local bus:
(add-hook 'herdr-event-agent-status-hook
          (lambda (d)
            (message "agent %s -> %s"
                     (plist-get d :id) (plist-get d :status))))

;; diagnostics:
M-x herdr-doctor
```

## Usage (Phase 2 — agent control)

```elisp
(herdr-connect)                       ; Phase 1 bootstrap (ping/snapshot/subscribe)

;; Start a Claude agent (provisions a pane, calls agent.start):
(setq arch (agent-fleet-start 'claude :name "arch"))
(agent-fleet-status arch)             ; => 'idle | 'working | 'blocked | 'done

;; Drive it — no TUI needed (PLAN.md §67 acceptance):
(agent-fleet-prompt arch "refactor src/foo.el")
(agent-fleet-prompt-and-wait arch "fix the bug" :until '(done blocked))
(agent-fleet-read arch :lines 50)     ; read-snapshot of the pane (§23)
(agent-fleet-interrupt arch)          ; sends [ctrl+c] (§21), not "cancel"
(agent-fleet-rename arch "arch-2")
(agent-fleet-kill arch)               ; pane.close + cache removal
(agent-fleet-list)                    ; cached agents
(agent-fleet-list t)                  ; refresh from agent.list first
(agent-fleet-get arch)                ; agent.get + cache upsert

;; Event-driven hooks (fed by the event bus, never polled — §25):
(add-hook 'agent-fleet-agent-done-hook
          (lambda (d) (message "done: %s" (plist-get d :pane-id))))
(add-hook 'agent-fleet-agent-blocked-hook #'my/on-blocked)
(add-hook 'agent-fleet-agent-started-hook #'my/on-started)
(add-hook 'agent-fleet-agent-exited-hook  #'my/on-exited)

;; Targets resolve by struct, name, symbol, or pane-id string:
(agent-fleet-prompt "arch" "go")      ; name -> pane-id from cache
(agent-fleet-prompt 'arch "go")       ; symbol -> name

;; Diagnostics (adds the agent-CLI checks on top of herdr-doctor):
M-x agent-fleet-doctor
```

`agent-fleet-show-output` opens a read-only buffer with a fresh
read-snapshot of a pane — it does not persist or mirror pane output
(PLAN.md §23/§46: pane output may contain secrets).

## Usage (Phase 3 — dashboard)

```elisp
(herdr-connect)
M-x agent-fleet            ; opens *Agent Fleet*, live-updating
```

The dashboard lists every agent with columns **Project / Agent / Kind /
State / Task** and refreshes itself from the event bus — no polling
(PLAN.md §25/§68). Each state has a face; `blocked` is the most prominent
(§28). Row keys (§27):

```
RET / o   inspect (read-snapshot of the agent's output, §23)
p         prompt
i         interrupt (ctrl+c)
k         kill
r         rename
g         refresh (re-fetch agent.list, then reprint)
w         worktree status (path/branch/repo, read-only — §46)
d         diff (working-tree, via Magit — §71)
m         magit status on the agent's checkout (§36/§71)
a         attach live to the agent's terminal (Phase 8, §73; prefix = --takeover)
P         narrow to the project at point (§69; re-press/prefix to clear)
T         narrow to the parallel task at point (Phase 7, §72; re-press/prefix to clear)
```

The package binds **no global key** (§53). To get a prefix map, bind it
yourself, e.g.:

```elisp
(global-set-key (kbd "C-c a") agent-fleet-command-map)
;; C-c a a  dashboard   C-c a s start   C-c a p prompt
;; C-c a o  read        C-c a i interrupt
```

Notifications on `working → blocked` / `working → done` are optional and
gated by `agent-fleet-notify-on` (default `(blocked done)`; §29). Set it
to nil to disable.

The **Project** column resolves each agent to its Emacs `project.el` project
by canonical cwd (Phase 4, §32) — not the workspace label. `P` narrows the
list to the project of the agent at point (re-press or prefix to clear).
The **Task** column shows the pane's terminal title as the best available
signal of current activity; for an agent launched by `agent-fleet-parallel`
(Phase 7) it shows the parallel-task title instead.

## Usage (Phase 4 — projects)

```elisp
(herdr-connect)

;; Start an agent in the current project (finds/creates a workspace, starts
;; the pane at the project root):
(agent-fleet-start-for-project 'claude :name "arch")

;; All agents whose cwd belongs to the current project (cwd-based, so agents
;; in separate worktrees of one repo all match — §32):
(agent-fleet-project-agents)

;; Pass a specific project (struct or root dir):
(agent-fleet-project-agents (project-current))
(agent-fleet-start-for-project 'codex :project "~/src/foo")
```

`M-x agent-fleet-start-for-project` is the project-scoped entry point. It
resolves the project root, reuses a Herdr workspace that already hosts the
project (else the focused one, else creates one with `cwd=root`), and starts
the agent at the root so the project association is immediate. Mapping is
**by canonical cwd, not workspace label** (§32: "不要仅通过 label 判断") —
the association is derived from agent cwds each time, with no stale table,
so multiple workspaces per repo (worktrees, investigation workspaces) are
fine.

In the dashboard, `P` toggles a project filter (the agent at point's
project); the column and filter both use `project.el` (preferred over
Projectile, §31). `agent-fleet-start-for-project` also forwards `:worktree`
so a project can start an agent in an isolated worktree (Phase 5, below).

## Usage (Phase 5 — worktrees)

Start an agent in an isolated worktree — a separate checkout of the repo —
so multiple agents don't modify the same working tree (PLAN.md §34/§70):

```elisp
(herdr-connect)

;; From a project buffer: the project root is the worktree source repo.
;; Herdr decides the branch; the agent starts in a fresh checkout.
(agent-fleet-start-for-project 'claude :name "backend" :worktree t)

;; Or directly, with optional branch/base overrides:
(agent-fleet-start 'codex :name "feat" :worktree t :cwd "~/src/myapp"
                   :branch "feature-x" :base "main")
```

`worktree.create` provisions a new workspace + a root pane (a shell at the
worktree cwd), and `agent.start` targets that pane directly — no separate
`pane.split`. The worktree + workspace are cached eagerly so the dashboard
`w` action resolves before the pushed `worktree_created` event lands.

Standalone management (user-initiated, never polled — §25):

```elisp
(agent-fleet-worktree-list)                 ; refresh worktree.list → cache
(agent-fleet-worktree-open "~/src/myapp")   ; reopen an existing worktree's ws
(agent-fleet-worktree-remove "w6")          ; remove by workspace id
(agent-fleet-worktree-remove "w6" t)        ; ...force
```

In the dashboard, `w` shows the agent-at-point's worktree — path, branch,
and repo source — read-only (metadata only; pane output is never persisted,
§23/§46). `M-x agent-fleet-worktree-list`, `-remove`, and `-open` are the
interactive entry points.

## Usage (Phase 6 — Magit)

Open Magit on an agent's checkout directly from the dashboard (PLAN.md
§36/§71). Magit's own buffers/commands are used — no reinvented diff or
cherry-pick UI:

```elisp
(herdr-connect)

;; Dashboard keys (agent at point):
;;   m  magit-status on the agent's checkout (worktree root, or main repo)
;;   d  working-tree diff (uncommitted changes the agent is making now)
;;
;; From magit-status, cherry-pick (c), merge (m), worktree-delete, etc. are
;; Magit's own keys — Phase 6 does not re-wrap them.

;; Or via M-x, prompting for an agent:
M-x agent-fleet-magit-status
M-x agent-fleet-magit-diff
```

`m`/`d` resolve the agent's git root by canonical cwd (worktree agents open
on the worktree root; bare agents on the main repo). When the agent has no
usable cwd, a cached worktree path is the fallback (§36). Magit is an
**optional** dependency (§55): if it is not installed, `m`/`d` `user-error`
with install advice rather than crashing; `M-x herdr-doctor` reports whether
Magit is available.

Finished-worktree cleanup (§71 "delete finished worktree"):

```elisp
M-x agent-fleet-worktree-cleanup     ; remove worktrees of all `done' agents
;; prefix arg (C-u) skips the confirmation prompt
```

It lists each `done` agent's worktree, confirms, then removes them via
`worktree.remove` (agents that are not `done`, or have no worktree, are
left alone). A worktree with uncommitted changes is not force-removed —
review it first with `d`/`m`.

## Usage (Phase 7 — parallel orchestration)

Spawn N isolated worktree agents and prompt each in parallel — the
package's core value (PLAN.md §37/§72). Each agent gets its own git
worktree and its own prompt; they run concurrently and their aggregate
status is tracked live from the event bus:

```elisp
(herdr-connect)

;; Fire-and-forget: spawns 3 worktree agents, prompts each, returns at once.
(setq task
      (agent-fleet-parallel
       '((claude . "Analyze architecture")
         (codex  . "Analyze implementation")
         (pi     . "Analyze tests"))
       :title "auth-refactor" :cwd "~/src/myapp"))

(agent-fleet-task-state task)          ; => 'running | 'blocked | 'failed | 'done
(agent-fleet-task-agents task)         ; list of pane-ids spawned

;; Block until the task settles (event-driven pump, not polling — §25):
(agent-fleet-task-wait task)           ; default until (done blocked failed)
(agent-fleet-task-wait task '(done))   ; only when ALL agents are done

;; Inspect any agent's output as a read-snapshot (§23) — no extraction:
(agent-fleet-read (nth 0 (agent-fleet-task-agents task)) :lines 50)

;; Remove the task's worktrees when finished, then drop the task:
(agent-fleet-task-cleanup task)        ; C-u skips the confirm prompt
```

Parallel execution is free: `agent-fleet-prompt` blocks only on the submit
*ack*, not on agent completion, so the N agents work concurrently after
`agent-fleet-parallel` returns. The task is **not a race** (§38): no agent
is killed when the first one finishes — `done` is reached only when *all*
agents are done; a single `blocked` agent makes the task `blocked`. There
is **no result extraction** (§40): agents are persistent interactive
workers, not RPC functions — `task-wait` returns STATUS only, never agent
output; use `agent-fleet-read` to inspect a finished agent.

In the dashboard, `T` narrows the list to one task's agents and the
mode-line shows `Parallel task: {title} — {aggregate-state}` live. The
**Task** column shows the task title for task agents.

`M-x agent-fleet-parallel` is the interactive entry point (prompts for a
title, the agent kinds, one shared prompt, and the source repo).

## Usage (Phase 8 — interactive terminal)

Attach live to an agent's pane inside an Emacs terminal so you can drive its
real PTY/TUI without leaving Emacs (PLAN.md §43/§44/§73/§79):

```elisp
(herdr-connect)

;; From the dashboard: put point on an agent, press `a'.
;; Or via M-x / a call, prompting for an agent:
M-x agent-fleet-attach
(agent-fleet-attach "arch")             ; by name / symbol / pane-id / struct
```

This spawns `herdr agent attach <pane-id>` — a CLI helper that bridges one
live pane as an interactive PTY client (§44 path A) — inside an Emacs
terminal backend. There is **no `agent.attach` socket RPC** (§43): attach is
a client-side PTY bridge, not socket I/O; the existing event bus is
untouched. The buffer is named `*agent:<name>*` (§73); a prefix arg
(`C-u`) passes `--takeover`.

```elisp
(agent-fleet-attach "arch" t)           ; --takeover
```

Terminal backends are **optional** (PLAN §45): `agent-fleet-attach-backend`
(default `auto`) picks the first ready backend in preference order —
**ghostel** (highest fidelity, libghostty-vt, §45.1) > **eat** (pure Elisp)
> **vterm** > **external**. `external` is always "ready": when no Emacs
backend is installed it `user-error`s with the exact `herdr agent attach`
command for you to run in your own terminal (§44 path C). ghostel is
preferred only when its dynamic module actually loaded (`featurep
'ghostel-module`) — a missing or broken module (e.g. an older build, or a
missing libghostty-vt dependency) leaves that feature unset, so `auto`
falls through to eat (set `agent-fleet-attach-backend` to an explicit symbol
to force one).

This is a **live interactive session**, not a persisted or mirrored view
(§46/§23): the buffer is transient — killing the process **detaches** and
the agent is **preserved** (detach does not close the pane, §79). Contrast
`o` (read-only read-snapshot, §23) with `a` (live interactive attach).

## Development

```bash
make compile      # byte-compile everything (zero warnings expected)
make test         # unit tests against the mock server (no Herdr needed)
make test-live    # live integration tests against a real Herdr (HERDR_TEST_LIVE=1)
make doctor       # run herdr-doctor
```

Tests run without a Herdr install thanks to `test/herdr-mock-server.el`, a tiny
fake Herdr that speaks the real one-shot + subscription wire protocol. Live
tests are gated on `HERDR_TEST_LIVE=1`.

## What is deliberately deferred (later phases)

Phases 1–8 deliver the wire client, the agent **control plane**
(start/prompt/read/wait/interrupt/rename/kill/switch/list/get over an
event-driven hook bus, no polling — §25/§67), the live **dashboard**,
**project integration** (`project.el` mapping, project-scoped start/list,
dashboard `P` filter — §69), **worktree isolation** (`worktree.create`/
`open`/`remove`, `:worktree t`, the dashboard `w` action — §33/§70),
**Magit integration** (`m` status / `d` diff / finished-worktree cleanup —
§36/§71), **parallel orchestration** (`agent-fleet-parallel`, the
dashboard `T` filter, `task-wait`/`task-cleanup` — §37/§72), and the
**interactive terminal** (`agent-fleet-attach`, the dashboard `a` action,
eat/ghostel/vterm backends — §43/§73/§79). Not yet built (per `PLAN.md`
§65/§88): dedicated cherry-pick/merge commands and a branch-vs-base diff
view (reachable via `m` + Magit's own keys), a Transient UI (§54),
broadcast/pipeline orchestration and a worktree policy (never/ask/always),
and §42 prompt history. Pane output is exposed only as a transient
read-snapshot or a transient interactive attach — never persisted or
mirrored (§23/§46). All socket I/O is local-only — no TCP/HTTP/remote
proxy (§48).

## License

GPL-3.0-or-later.
