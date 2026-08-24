# agent-fleet

An Emacs package that turns Emacs into a multi-agent supervisor over the
[Herdr](https://herdr.dev) terminal workspace server.

Claude Code, Codex, Pi, and other CLI agents keep running in real PTYs
managed by Herdr. Emacs provides the control plane: start agents, send
prompts, watch their state, inspect output, isolate work in Git worktrees,
review changes with Magit, and attach to a live terminal when direct
interaction is needed.

## Features

- A live dashboard for every Herdr-managed agent, grouped by project and task.
- Agent lifecycle commands: start, prompt, wait, read, interrupt, rename, switch,
  and kill.
- Automatic connection to a running Herdr server on first use.
- `project.el` integration and per-agent Git worktree isolation.
- Parallel tasks that run multiple agents in independent worktrees.
- Magit status and diff commands for an agent's checkout.
- Interactive terminal attach through Ghostel.
- Event-driven state updates, notifications, reconnect, and snapshot recovery.

## Requirements

- Emacs 29.1 or newer.
- A running Herdr server reachable through its local Unix socket.
- `transient` 0.7.2 or newer.
- One or more supported agent CLIs, such as Claude Code, Codex, or Pi.
- Magit for the optional status and diff integration.
- Ghostel for an interactive terminal inside Emacs (optional; the core
  works without it installed).

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

The interactive command asks for an agent kind and an optional name. The
working directory, branch, and extra CLI arguments can be supplied through the
command prompts; defaults are covered in [Configuration](#configuration).

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
Emacs's native child-frame support or a standalone graphical frame; set
`agent-fleet-dashboard-display` accordingly (see
[Configuration](#configuration)):

- `'buffer` (default): a regular window.
- `'child-frame`: a native child frame.
- `'frame`: a standalone operating-system window.

Native child-frame display requires Emacs 29.1 or newer, a graphical Emacs
frame, and `display-buffer-in-child-frame`. If any requirement is unavailable,
agent-fleet reports the reason and opens the regular dashboard buffer instead.

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
loaded. Notifications can be tuned with `agent-fleet-notify-on`; see
[Configuration](#configuration).

## Start and control agents

Every control command is available interactively as `M-x agent-fleet-<name>`
and accepts an agent name, pane ID, symbol, or `herdr-agent` object where
applicable.

| Command | Action |
|---|---|
| `M-x agent-fleet-start` | Start an agent (prompts for kind and name) |
| `M-x agent-fleet-prompt` | Send a prompt |
| `M-x agent-fleet-prompt-and-wait` | Prompt and wait atomically for done/blocked |
| `M-x agent-fleet-read` | Read a terminal snapshot |
| `M-x agent-fleet-show-output` | Open a recent output snapshot |
| `M-x agent-fleet-wait` | Wait for a specific state |
| `M-x agent-fleet-send-keys` | Send terminal keys |
| `M-x agent-fleet-interrupt` | Send `Ctrl-C` |
| `M-x agent-fleet-rename` | Rename the agent |
| `M-x agent-fleet-switch` | Focus the agent in Herdr |
| `M-x agent-fleet-kill` | Stop the agent |
| `M-x agent-fleet-list` | List cached agents |
| `M-x agent-fleet-get` | Show one agent |
| `M-x agent-fleet-status` | Show an agent's state |
| `M-x agent-fleet-doctor` | Check socket, connection, manifests, and CLIs |

Agent state comes directly from Herdr and is one of `idle`, `working`,
`blocked`, `done`, or `unknown`.

Lifecycle hooks (`agent-fleet-agent-started-hook`,
`agent-fleet-agent-status-changed-hook`, and `agent-fleet-agent-exited-hook`)
run with the post-event cache already updated, so custom automation can read
fresh state without polling.

## Projects and worktrees

Start an agent for the current `project.el` project:

```text
M-x agent-fleet-start-for-project
```

Agents in linked worktrees are mapped back to the same canonical project, so
the dashboard's `P` filter includes all checkouts of one repository.

Standalone worktree commands:

- `M-x agent-fleet-worktree-list`
- `M-x agent-fleet-worktree-open`
- `M-x agent-fleet-worktree-status`
- `M-x agent-fleet-worktree-remove`
- `M-x agent-fleet-worktree-cleanup`

Removal protects worktrees with uncommitted changes unless force is requested.
Review the agent's changes before cleanup.

## Parallel tasks

Run multiple agents in independent worktrees as one aggregate task:

```text
M-x agent-fleet-parallel
```

The interactive command prompts for each agent's kind and prompt. Use the
dashboard `T` key to focus on one task; the task title and its aggregate state
then show in the mode line. Task state is derived from its members — `done`
only when all agents are done, `blocked` when one is blocked — and no agent is
killed when another finishes. Use `M-x agent-fleet-read` to inspect individual
results, and `M-x agent-fleet-task-cleanup` to remove the task's worktrees
after preserving any wanted changes.

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

The command runs `herdr agent attach <pane-id>` inside the Ghostel terminal
backend. The attach buffer is named `*agent:NAME*` and is reused for the same
pane. Killing the buffer or terminal process detaches from the PTY; it does
not kill the agent or close its pane.

Use a prefix argument to request terminal takeover:

```text
C-u M-x agent-fleet-attach
```

Choose a backend explicitly via `agent-fleet-attach-backend`; see
[Configuration](#configuration). When no in-Emacs backend is available,
agent-fleet reports the `herdr agent attach` command to run in your own
terminal.

### Evil and evil-escape

Attach buffers inhibit `evil-escape` locally by default. Some terminal modes
forward both the synthetic first key used by `evil-escape` and the real key to
the PTY, which can duplicate the first character of an escape sequence such as
`jk`. The default prevents that input corruption without changing Evil
globally; toggle it with `agent-fleet-attach-inhibit-evil-escape` (see
[Configuration](#configuration)).

Terminal TUIs usually implement their own scrollback. If scrolling feels slow
because the backend sends navigation keys into the TUI, switch to the terminal
backend's copy or scrollback mode before navigating the buffer.

## Connection

`agent-fleet-auto-connect` controls when Emacs connects to Herdr:

- `'on-demand` (default): connect before the first dashboard or control command.
- `'after-init`: also attempt a connection shortly after Emacs starts.
- `nil`: require `M-x herdr-connect` explicitly.

Automatic connection does not start or own the Herdr server. If the server is
restarted, the subscription reconnects with backoff and refreshes the local
snapshot. A command issued after a failed startup connection retries on demand.

The socket is discovered from `HERDR_SOCKET_PATH`, `herdr status`, or
`~/.config/herdr/herdr.sock`; override it with `herdr-socket-path` when using a
non-default location. Run `M-x agent-fleet-doctor` to check the socket, Herdr
connection, agent manifests, and configured CLI executables.

## Configuration

All options are Emacs customization variables in the `agent-fleet` and `herdr`
groups; set them with `setq` or <kbd>M-x customize-group RET agent-fleet</kbd>.

### Connection and transport

| Option | Default | Meaning |
|---|---|---|
| `herdr-socket-path` | `nil` | Herdr Unix socket path; `nil` auto-discovers from `HERDR_SOCKET_PATH`, `herdr status`, then `~/.config/herdr/herdr.sock` |
| `herdr-protocol-request-timeout` | `5.0` | Default timeout in seconds for a synchronous Herdr request |
| `herdr-protocol-ping-timeout` | `3.0` | Timeout in seconds for a `ping` |
| `herdr-subscription-start-timeout` | `3.0` | Seconds to wait for the `subscription_started` acknowledgement |
| `herdr-reconnect-max-attempts` | `12` | Maximum reconnection attempts before giving up |
| `herdr-reconnect-delay` | `2.0` | Base delay in seconds between reconnection attempts |
| `herdr-reconnect-max-delay` | `60.0` | Cap in seconds on the reconnection backoff |
| `herdr-log-level` | `'warn` | Logging verbosity: `'error`, `'warn`, `'info`, `'debug`, `'trace` (trace records full frames; terminal output may contain secrets) |
| `herdr-log-buffer` | `*herdr-log*` | Name of the Herdr log buffer |

### Agent control

| Option | Default | Meaning |
|---|---|---|
| `agent-fleet-auto-connect` | `'on-demand` | When to connect: `nil` (manual), `'on-demand`, or `'after-init` |
| `agent-fleet-auto-connect-delay` | `1.0` | Idle seconds before an `after-init` connection |
| `agent-fleet-agent-executables` | claude/codex/pi | Known agent kinds and their CLI executables; used by `agent-fleet-doctor` and kind completion |
| `agent-fleet-default-read-source` | `'recent_unwrapped` | Default `agent.read` source: `'visible`, `'recent`, `'recent_unwrapped`, or `'detection` |
| `agent-fleet-default-read-lines` | `120` | Default line count for reads and output snapshots |
| `agent-fleet-default-read-format` | `'text` | Default read format: `'text` (ANSI stripped) or `'ansi` |
| `agent-fleet-start-timeout-ms` | `30000` | Startup timeout in ms passed to `agent.start` (Herdr requires 3000–300000) |
| `agent-fleet-wait-timeout-ms` | `120000` | Default timeout in ms for `agent-fleet-wait` and `-prompt-and-wait` |
| `agent-fleet-default-wait-until` | `'(done blocked)` | Default statuses `wait`/`prompt-and-wait` wait for |
| `agent-fleet-output-buffer-prefix` | `*Agent Output: ` | Prefix for output buffer names (buffer is `PREFIX<name>*`) |

### Dashboard

| Option | Default | Meaning |
|---|---|---|
| `agent-fleet-notify-on` | `'(blocked done)` | Agent statuses that trigger a notification; `nil` disables notifications |
| `agent-fleet-dashboard-buffer-name` | `*Agent Fleet*` | Name of the dashboard buffer |
| `agent-fleet-dashboard-display` | `'buffer` | Display backend: `'buffer`, `'child-frame`, or `'frame` |
| `agent-fleet-dashboard-child-frame-parameters` | alist | Frame parameters for the native child-frame dashboard (size, centering, borders) |
| `agent-fleet-dashboard-frame-parameters` | alist | Frame parameters for the standalone dashboard frame |
| `agent-fleet-dashboard-child-frame-fit-height` | `nil` | When non-nil, fit the child-frame height to the agent count (event-driven, idempotent) |
| `agent-fleet-dashboard-child-frame-min-height` | `4` | Minimum child-frame height in lines when fit-height is on |
| `agent-fleet-dashboard-child-frame-max-height` | `24` | Maximum child-frame height in lines when fit-height is on |
| `agent-fleet-dashboard-child-frame-help-height` | `8` | Bottom lines reserved for the transient help page |

### Terminal attach

| Option | Default | Meaning |
|---|---|---|
| `agent-fleet-attach-backend` | `'auto` | Terminal backend: `'auto` or `'ghostel` |
| `agent-fleet-attach-buffer-prefix` | `*agent:` | Prefix for attach buffer names (buffer is `PREFIX<name>*`) |
| `agent-fleet-attach-inhibit-evil-escape` | `t` | Inhibit `evil-escape` locally in attach buffers to avoid duplicated input |

## Low-level Herdr client

The `herdr` library is available for direct protocol access
(`M-x herdr-connect`, `M-x herdr-disconnect`, and `M-x herdr-doctor`), but most
users should prefer the `agent-fleet-*` commands, which resolve targets, keep
the local model synchronized, and expose lifecycle hooks. The protocol uses one
short-lived socket per request and one long-lived event subscription; Herdr
remains the source of truth and reconnecting rebuilds the local snapshot. See
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the wire protocol and event shapes.

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
