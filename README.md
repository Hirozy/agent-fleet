# agent-fleet

An Emacs package that turns Emacs into a multi-agent supervisor over the
[Herdr](https://herdr.dev) terminal workspace server.

Claude Code, Codex, Pi, and other CLI agents keep running in real PTYs managed
by Herdr. Emacs provides the control plane: start agents, send prompts, watch
their state, inspect output, isolate work in Git worktrees, review changes with
Magit, and attach to a live terminal when direct interaction is needed.

## Features

- A live dashboard for every Herdr-managed agent, grouped by project and task.
- Agent lifecycle commands: start, prompt, wait, read, interrupt, rename, switch,
  and kill.
- Automatic connection to a running Herdr server on first use.
- `project.el` integration and per-agent Git worktree isolation.
- Parallel tasks that run multiple agents in independent worktrees.
- Magit status and diff commands for an agent's checkout.
- Interactive terminal attach through Ghostel, Eat, or vterm.
- Event-driven state updates, notifications, reconnect, and snapshot recovery.

## Requirements

- Emacs 29.1 or newer.
- A running Herdr server reachable through its local Unix socket.
- `transient` 0.7.2 or newer.
- One or more supported agent CLIs, such as Claude Code, Codex, or Pi.
- Magit for the optional status and diff integration.
- Ghostel, Eat, or vterm for an interactive terminal inside Emacs.

The core client uses only Emacs built-in libraries. Magit and terminal backends
are detected when their commands are used.

## Installation

Put the repository on `load-path`, require the package, and optionally bind its
prefix map:

```elisp
(add-to-list 'load-path "/path/to/agent-fleet")
(require 'agent-fleet)

(global-set-key (kbd "C-c a") agent-fleet-command-map)
```

The package does not bind global keys by itself. With the example prefix above,
these commands are available:

| Key | Command |
|---|---|
| `C-c a a` | Open the dashboard |
| `C-c a s` | Start an agent |
| `C-c a p` | Prompt an agent |
| `C-c a o` | Show recent output |
| `C-c a i` | Interrupt an agent |

## Quick start

Start the Herdr server, then open the dashboard:

```text
M-x agent-fleet
```

By default, the first dashboard or control command connects to Herdr
automatically. From the dashboard, press `h` to open the transient command
menu, or start an agent directly with:

```text
M-x agent-fleet-start
```

The interactive command asks for an agent kind and an optional name. From
Emacs Lisp, you can also supply the working directory and other options:

```elisp
(setq reviewer
      (agent-fleet-start 'codex
                         :name "reviewer"
                         :cwd "~/src/my-project"))

(agent-fleet-prompt reviewer
                    "Review the current changes and report correctness issues.")

(agent-fleet-wait reviewer)

(plist-get (agent-fleet-read reviewer :lines 200) :text)
```

Agent arguments can be passed as a list of strings:

```elisp
(agent-fleet-start 'codex
                   :name "implementer"
                   :cwd "~/src/my-project"
                   :args '("--full-auto"))
```

## Dashboard

`M-x agent-fleet` opens `*Agent Fleet*`. Each row shows the agent's project,
name, kind, state, and task. The buffer updates from Herdr events; it does not
periodically poll the server.

| Key | Action |
|---|---|
| `RET` or `o` | Inspect recent output |
| `p` | Send a prompt |
| `i` | Send `Ctrl-C` |
| `k` | Kill the agent |
| `r` | Rename the agent |
| `g` | Refresh from the server |
| `P` | Toggle a project filter |
| `T` | Toggle a parallel-task filter |
| `w` | Show worktree status |
| `d` | Open the working-tree diff |
| `m` | Open Magit status |
| `a` | Attach to the live terminal |
| `h` | Open the transient help menu |
| `q` | Close the dashboard window or frame |

The dashboard normally opens in an ordinary Emacs window. It can instead use
Emacs's native child-frame support or a standalone graphical frame:

```elisp
;; Float the dashboard over the current Emacs frame.
(setq agent-fleet-dashboard-display 'child-frame)

;; Or use an independent operating-system window.
(setq agent-fleet-dashboard-display 'frame)
```

Native child-frame display requires Emacs 29.1 or newer, a graphical Emacs
frame, and `display-buffer-in-child-frame`. If any requirement is unavailable,
agent-fleet reports the reason and opens the regular dashboard buffer instead.
The package's overall minimum supported Emacs version is also 29.1.

The configured default can be bypassed for one invocation:

```text
M-x agent-fleet-dashboard-open-buffer
M-x agent-fleet-dashboard-open-child-frame
M-x agent-fleet-dashboard-open-frame
```

Child dashboards open in the center of their parent frame and retain
proportional size and position when it is resized. Opening output, worktree
status, Magit, a diff, or a terminal attach uses the originating main frame and
closes the child dashboard after the destination opens successfully. Attach
additionally replaces that frame's current window with the live terminal.
Refresh, filters, prompt, interrupt, kill, rename, and transient help remain in
the child dashboard. Closing a dashboard frame does not disconnect Herdr or
stop agents.

The dashboard supports its keys in normal and motion states when Evil is
loaded. Notifications are enabled for `blocked` and `done` by default:

```elisp
;; Notify only when an agent needs input.
(setq agent-fleet-notify-on '(blocked))

;; Disable agent notifications.
(setq agent-fleet-notify-on nil)
```

## Start and control agents

Every command accepts an agent name, pane ID, symbol, or returned `herdr-agent`
object where applicable.

```elisp
;; Submit without waiting.
(agent-fleet-prompt "reviewer" "Run the test suite.")

;; Submit and wait atomically for done or blocked.
(agent-fleet-prompt-and-wait "reviewer" "Fix the failing tests.")

;; Read a terminal snapshot.
(agent-fleet-read "reviewer" :source 'recent_unwrapped :lines 120)

;; Wait for a specific state.
(agent-fleet-wait "reviewer" '(done blocked) :timeout-ms 300000)

;; Send terminal keys or interrupt with Ctrl-C.
(agent-fleet-send-keys "reviewer" '("esc" "enter"))
(agent-fleet-interrupt "reviewer")

;; Rename, focus in Herdr, or stop the agent.
(agent-fleet-rename "reviewer" "reviewer-2")
(agent-fleet-switch "reviewer-2")
(agent-fleet-kill "reviewer-2")
```

Useful query commands include `agent-fleet-list`, `agent-fleet-get`,
`agent-fleet-status`, and `agent-fleet-show-output`. Agent state comes directly
from Herdr and is one of `idle`, `working`, `blocked`, `done`, or `unknown`.

For automation, register functions on the lifecycle hooks:

```elisp
(add-hook 'agent-fleet-agent-blocked-hook
          (lambda (agent)
            (message "Agent needs attention: %s"
                     (plist-get agent :name))))

(add-hook 'agent-fleet-agent-done-hook
          (lambda (agent)
            (message "Agent finished: %s"
                     (plist-get agent :name))))
```

## Projects and worktrees

Start an agent for the current `project.el` project:

```elisp
(agent-fleet-start-for-project 'codex
                               :name "project-reviewer")
```

Agents in linked worktrees are mapped back to the same canonical project, so
the dashboard's `P` filter includes all checkouts of one repository.

To give an agent an isolated checkout, pass `:worktree t` and the source
repository:

```elisp
(agent-fleet-start 'codex
                   :name "isolated-fix"
                   :cwd "~/src/my-project"
                   :worktree t
                   :branch "agent/isolated-fix"
                   :base "main")
```

The branch and base are optional; when omitted, Herdr chooses them. Standalone
worktree commands are also available:

- `M-x agent-fleet-worktree-list`
- `M-x agent-fleet-worktree-open`
- `M-x agent-fleet-worktree-status`
- `M-x agent-fleet-worktree-remove`
- `M-x agent-fleet-worktree-cleanup`

Removal protects worktrees with uncommitted changes unless force is requested.
Review the agent's changes before cleanup.

## Parallel tasks

`agent-fleet-parallel` starts each agent in a separate worktree, sends its
prompt, and tracks the group as one task:

```elisp
(setq review-task
      (agent-fleet-parallel
       '((codex . "Review the implementation for correctness.")
         (claude . "Review the tests and identify missing cases."))
       :title "release-review"
       :cwd "~/src/my-project"
       :base "main"))

(agent-fleet-task-wait review-task)
(agent-fleet-task-state review-task)
(agent-fleet-task-agents-state review-task)
```

Task state is derived from its agents. Waiting ends when the task is `done`,
`blocked`, or `failed` by default. It does not stop the other agents when one
finishes. Use `agent-fleet-read` to inspect individual results.

After reviewing and preserving any wanted changes, remove the task's worktrees:

```elisp
(agent-fleet-task-cleanup review-task)
```

You can also run `M-x agent-fleet-parallel` interactively and use `T` in the
dashboard to focus on one task.

## Review changes with Magit

With Magit installed, the dashboard can open the selected agent's checkout:

- Press `m` for Magit status.
- Press `d` for the working-tree diff.
- Run `M-x agent-fleet-magit-status` or `M-x agent-fleet-magit-diff` directly.

The agent's actual checkout is used, including an isolated Herdr worktree. If
Magit is unavailable, the commands report how to enable the integration.

## Attach to a live terminal

Press `a` on a dashboard row or run:

```text
M-x agent-fleet-attach
```

The command runs `herdr agent attach <pane-id>` inside the first available
backend in this order: Ghostel, Eat, then vterm. The attach buffer is named
`*agent:NAME*` and is reused for the same pane. Killing the buffer or terminal
process detaches from the PTY; it does not kill the agent or close its pane.

Use a prefix argument to request terminal takeover:

```text
C-u M-x agent-fleet-attach
```

Choose a backend explicitly if desired:

```elisp
(setq agent-fleet-attach-backend 'eat) ; auto, ghostel, eat, vterm, external
```

When no in-Emacs backend is available, run the command shown by agent-fleet in
an external terminal.

### Evil and evil-escape

Attach buffers inhibit `evil-escape` locally by default. Some terminal modes
forward both the synthetic first key used by `evil-escape` and the real key to
the PTY, which can duplicate the first character of an escape sequence such as
`jk`.

The default prevents that input corruption without changing Evil globally:

```elisp
(setq agent-fleet-attach-inhibit-evil-escape t)
```

Set it to nil only if your terminal backend integrates safely with
`evil-escape`.

Terminal TUIs usually implement their own scrollback. If scrolling feels slow
because the backend sends navigation keys into the TUI, switch to the terminal
backend's copy or scrollback mode before navigating the buffer.

## Connection and configuration

`agent-fleet-auto-connect` controls when Emacs connects to Herdr:

- `on-demand` (default): connect before the first dashboard or control command.
- `after-init`: also attempt a connection shortly after Emacs starts.
- `nil`: require `M-x herdr-connect` explicitly.

To connect after startup:

```elisp
(setq agent-fleet-auto-connect 'after-init
      agent-fleet-auto-connect-delay 1.0)
(require 'agent-fleet)
```

Automatic connection does not start or own the Herdr server. If the server is
restarted, the subscription reconnects with backoff and refreshes the local
snapshot. A command issued after a failed startup connection retries on demand.

The socket is discovered from `HERDR_SOCKET_PATH`, `herdr status`, or
`~/.config/herdr/herdr.sock`. Override it when using a non-default location:

```elisp
(setq herdr-socket-path "/path/to/herdr.sock")
```

Common defaults can be customized globally:

```elisp
(setq agent-fleet-default-read-lines 200
      agent-fleet-default-read-source 'recent_unwrapped
      agent-fleet-wait-timeout-ms 300000
      agent-fleet-default-wait-until '(done blocked))
```

Run `M-x agent-fleet-doctor` to check the socket, Herdr connection, agent
manifests, and configured CLI executables.

## Low-level Herdr client

The `herdr` library is available when direct protocol access is useful:

```elisp
(herdr-connect)
(herdr-request "server.agent_manifests")
(herdr-disconnect)
```

Most users should prefer the `agent-fleet-*` commands because they resolve
targets, keep the local model synchronized, and expose lifecycle hooks.

The protocol implementation uses one short-lived socket per request and one
long-lived event subscription. Herdr remains the source of truth; reconnecting
rebuilds the local snapshot. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the
wire protocol and event shapes verified by this client.

## Architecture

```text
Emacs
  |
  +-- agent-fleet-dashboard.el  live dashboard and actions
  +-- agent-fleet-project.el    project.el mapping
  +-- agent-fleet-worktree.el   isolated checkout management
  +-- agent-fleet-magit.el      status and diff integration
  +-- agent-fleet-parallel.el   multi-agent task orchestration
  +-- agent-fleet-attach.el     interactive terminal attach
  +-- agent-fleet.el            agent lifecycle and control
  |
  +-- herdr.el                  connection and requests
      +-- herdr-events.el       subscriptions and hook dispatch
      +-- herdr-model.el        live cache
      +-- herdr-protocol.el     newline-delimited JSON transport
  |
  v
Herdr server --> real PTYs --> Claude Code / Codex / Pi / other CLI agents
```

## Development

Run the complete byte-compilation and mock regression suite:

```sh
make test
```

Run live integration tests against a running local Herdr server:

```sh
make test-live
```

Other useful targets:

```sh
make compile
make doctor
make clean
```

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
