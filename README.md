# agent-fleet

An Emacs package that turns Emacs into a **multi-agent supervisor** over the
[Herdr](https://herdr.dev) terminal workspace server.

> **Do not bring the agents into Emacs. Bring their control plane into Emacs.**

Claude Code, Codex, Pi (and any future CLI agents) keep running in their real
PTY/TUI inside Herdr; Emacs sees them, organizes them, controls them, and reviews
the code they produce — over Herdr's socket API.

This repository currently implements **Phase 1** of the plan in `PLAN.md`:
the low-level, async, event-driven Herdr client (`herdr.el` and friends).
The agent-facing supervisor (`agent-fleet.el`, dashboard, project/worktree
integration, multi-agent orchestration) is Phase 2+ and not yet built.

## Status

| Layer | File | Status |
|---|---|---|
| Wire transport | `herdr-protocol.el` | ✅ done |
| Data model + cache | `herdr-model.el` | ✅ done |
| Subscription logic + event bus | `herdr-events.el` | ✅ done |
| Top-level client | `herdr.el` | ✅ done |
| Fake Herdr server (tests) | `test/herdr-mock-server.el` | ✅ done |
| Agent supervisor / dashboard | `agent-fleet.el` … | ⏳ Phase 2+ |

Verified against **Herdr 0.8.0** (protocol 19). All source byte-compiles with
zero warnings; 24 unit tests (mock) + 4 live integration tests pass.

## Requirements

- Emacs **29.1** or newer (developed on 30.2).
- Herdr installed and its server reachable on the local Unix socket.
- Phase 1 depends only on built-in packages: `json`, `cl-lib`, `subr-x`.

## Architecture

```
Emacs
  │
  agent-fleet.el   (Phase 2+ — not yet built)
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

## What Phase 1 deliberately does NOT do

(per `PLAN.md` §65/§88): no agent UI, no Claude/Codex/Pi-specific logic, no
worktrees, no Magit, no Eat integration, no orchestration. Phase 1 is only the
Herdr protocol client + cache + event bus + reconnect. The agent supervisor
builds on this in Phase 2+.

## License

GPL-3.0-or-later.
