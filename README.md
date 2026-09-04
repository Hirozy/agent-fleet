# agent-fleet

An Emacs package for bringing Herdr-managed coding agents into Emacs as a
multi-agent control and viewing interface.

Claude Code, Codex, Pi, and other CLI agents keep running in real PTYs
managed by Herdr. Emacs provides the control plane: start agents, send
prompts, watch their state, inspect output, isolate work in Git worktrees,
review changes with Magit, and attach to a live terminal when direct
interaction is needed.

Agent Fleet deliberately focuses on agents. It uses Herdr workspaces, panes,
worktrees, and events to provision and locate them, but it is not a general
Emacs frontend for managing every Herdr Session or Workspace resource.

## Features

- A live dashboard for every Herdr-managed agent, with project and task
  context and filters.
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

The transport and control plane load without Magit or Ghostel. Optional Magit
and terminal integrations are detected only when their commands are used.

## Installation

For a source checkout, generate the autoload definitions once (and again after
updating the checkout):

```sh
make autoloads
```

Package managers generate the same file during installation. The package does
not bind any global keys; set them up with `use-package`:

```elisp
(use-package agent-fleet
  :load-path "/path/to/agent-fleet"
  :bind (;; Open the dashboard
         ("s-d" . agent-fleet)
         ;; Prefix map for agent-fleet commands
         ("s-a" . agent-fleet-command-map))
  :custom
  ;; Optional: use a native child frame for the dashboard
  (agent-fleet-dashboard-display 'buffer))
```

With the prefix above, these commands are available:

| Key | Command |
|---|---|
| `s-d` | Open the dashboard |
| `s-a s` | Start an agent |
| `s-a p` | Prompt an agent |
| `s-a o` | Show recent output |
| `s-a i` | Interrupt an agent |

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

The interactive command asks for an agent kind, the workspace to start
in, and a name. A default of `<workspace-label>-<serial>` (for example
`demo-1`) is suggested — press `RET` to accept it or type your own. Project,
worktree, and programmatic entry points can supply a working directory, branch,
and extra CLI arguments without expanding the ordinary interactive prompt.

## Dashboard

`M-x agent-fleet` opens `*Agent Fleet*`. Each row shows the agent's project,
name, kind, state, and task. The buffer updates from Herdr events; it does not
periodically poll the server. Opening also reconciles the list from the server,
like the `g` action, so the dashboard opens on fresh state rather than a
possibly-stale cache. That reconciliation is atomic with respect to the live
subscription: events received while `agent.list` is in flight are queued, the
server snapshot is installed first, and the queued events are then replayed in
arrival order. A newer status or lifecycle event therefore cannot be replaced
by an older list response, and received events are still replayed if the refresh
fails.

| Key | Action |
|---|---|
| `N` | Start a new agent |
| `o` | Inspect recent output |
| `s` | Send a prompt |
| `i` | Send `Ctrl-C` |
| `x` | Kill the agent |
| `r` | Rename the agent |
| `g` | Refresh from the server |
| `P` | Show agents in this project / clear the project filter |
| `T` | Toggle a parallel-task filter |
| `w` | Show worktree status |
| `d` | Open the working-tree diff |
| `m` | Open Magit status |
| `a` / `RET` | Attach to the live terminal |
| `!` | Jump to the next agent needing attention (`blocked`; prefix adds `done`) |
| `h` | Open the transient help menu |
| `p` / `k` / `↑` | Move up a row (skips the project-group separator) |
| `n` / `j` / `↓` | Move down a row (skips the project-group separator) |
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

The dashboard mode line surfaces the Herdr connection state when it is not
healthy: `Reconnecting (n/max)…` while a dropped subscription is being
re-established, or `Disconnected — M-x herdr-connect` when there is no
connection (after an explicit disconnect, a failed initial connect, or once
reconnect gives up). No banner is shown while connected. The state is driven
by `herdr-connection-state-changed-hook` — there is no polling timer — so the
banner tracks the real transitions reported by the Herdr connection layer.

## Start and control agents

Every control command is available interactively as `M-x agent-fleet-<name>`
and accepts an agent name, pane ID, symbol, or `herdr-agent` object where
applicable.

| Command | Action |
|---|---|
| `M-x agent-fleet-start` | Start an agent (prompts for kind and name) |
| `M-x agent-fleet-prompt` | Send a prompt |
| `M-x agent-fleet-prompt-and-wait` | Prompt and wait atomically for done/blocked |
| `M-x agent-fleet-show-output-in-buffer` | Open output in an ordinary buffer |
| `M-x agent-fleet-wait` | Wait for a specific state |
| `M-x agent-fleet-send-keys` | Send terminal keys |
| `M-x agent-fleet-interrupt` | Send `Ctrl-C` |
| `M-x agent-fleet-rename` | Rename the agent |
| `M-x agent-fleet-switch` | Focus the agent in Herdr |
| `M-x agent-fleet-kill` | Stop the agent |
| `M-x agent-fleet-list` | List cached agents in a read-only table (Name, Status, Kind, Task, Project) |
| `M-x agent-fleet-get` | Show one agent |
| `M-x agent-fleet-status` | Show an agent's state |
| `M-x agent-fleet-doctor` | Check socket, connection, manifests, and CLIs |

When started interactively, you are always prompted to pick the workspace
the agent starts in, and the agent opens as a fresh tab in that workspace
— never a new frame. After a successful interactive start the agent's
terminal is attached automatically (see
[Attach to a live terminal](#attach-to-a-live-terminal)). Programming
callers such as `agent-fleet-parallel` are unaffected: they pass an
explicit workspace, are never prompted, and never attach.

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

This reuses a workspace already serving the project, or the focused one; if
neither exists, an interactive start prompts you to pick a workspace. Like
`agent-fleet-start`, an interactive project start opens the agent as a new
tab in that workspace and attaches the terminal afterward.

Here, Project means the logical codebase identity derived from an agent's cwd;
it is deliberately distinct from a Herdr Workspace. Project detection defaults
to the built-in `project.el`. Set
`agent-fleet-project-backend` to `'projectile` to source it from Projectile
instead; either way, a git repository resolves to its primary checkout
regardless of backend, so the option only affects how non-git projects are
detected.

Agents in linked worktrees are mapped back to the same canonical Project, so
the dashboard's `P` filter shows all agents in that codebase even when they run
in different Herdr Workspaces. The Lisp API `agent-fleet-project-agents`
returns the same cached set without issuing a server request. An agent whose
cwd has no resolvable Project shows `—` in the column; `P` requires an
actual Project identity.

Standalone worktree commands:

- `M-x agent-fleet-worktree-list`
- `M-x agent-fleet-worktree-open`
- `M-x agent-fleet-worktree-status-in-buffer`
- `M-x agent-fleet-worktree-remove`
- `M-x agent-fleet-worktree-cleanup`

Removal protects worktrees with uncommitted changes unless force is requested.
Review the agent's changes before cleanup.

### Handing a task from the current buffer

`M-x agent-fleet-prompt-dwim` hands the current buffer context to an agent:

- the file path (relative to the agent's project root when possible);
- the active region's line range;
- the symbol near point;
- the selected text, when the region is within
  `agent-fleet-prompt-dwim-max-region-lines` and
  `agent-fleet-prompt-dwim-max-region-chars`.

The command first opens an agent completion list. It prefers agents in the
same Project as the current buffer, and still requires an explicit selection
when there is only one matching agent. If the buffer has no Project or no
agent is associated with it, the completion falls back to all cached agents
and says so in the minibuffer prompt/message. After selection, Agent Fleet
attaches to the live terminal and opens the existing compose child frame with
the reference prefilled. Append the task there and press `C-c C-c` to paste it
into the terminal; Enter remains a separate, explicit submission step.
When native child frames are unavailable, the context is instead pasted
directly into the live attach terminal using bracketed paste, without Enter;
finish the task in the terminal and submit it explicitly.

The selected text is included only when it is at most
`agent-fleet-prompt-dwim-max-region-lines` lines and
`agent-fleet-prompt-dwim-max-region-chars` characters. The character limit is
also a compatibility setting for configurations that predate the line limit,
and protects against very large single-line selections. When either limit is
exceeded, the file and line-range reference is retained and the selected text
is omitted. It does not save user files or copy an entire buffer by default.

## Parallel tasks

Run multiple agents in independent worktrees as one aggregate task:

```text
M-x agent-fleet-parallel
```

The interactive command prompts for each agent's kind and prompt. Use the
dashboard `T` key to focus on one task; the task title and its aggregate state
then show in the mode line. Task state is derived from its members — `done`
only when all agents are done, `blocked` when one is blocked — and no agent is
killed when another finishes. Use `M-x agent-fleet-show-output-in-buffer` to
inspect individual results, and `M-x agent-fleet-task-cleanup` to remove the
task's worktrees after preserving any wanted changes.

## Review changes with Magit

With Magit installed, the dashboard can open the selected agent's checkout:

- Press `m` for Magit status.
- Press `d` for the working-tree diff.
- Run `M-x agent-fleet-magit-status-in-buffer` or
  `M-x agent-fleet-magit-diff-in-buffer` directly.

The agent's actual checkout is used, including an isolated Herdr worktree. If
Magit is unavailable, the commands report how to enable the integration.

## Auxiliary views

Every auxiliary view — recent output, worktree status, Magit status, and the
working-tree diff — opens in an ordinary Emacs buffer (`-in-buffer`): a
read snapshot of the agent's output or a full Magit session on its
checkout, sized by Emacs's normal window rules.

Native child frames are reserved for two surfaces that benefit from
floating over the terminal without disturbing its window geometry (and the
PTY size the agent sees): the dashboard itself (see
`agent-fleet-dashboard-display`) and the compose editor opened by
`agent-fleet-attach-prompt-in-child-frame`. Repeated compose opens reuse a
single auxiliary child frame per parent, and `M-x
agent-fleet-dashboard-aux-quit` (or `q` inside the compose buffer) closes
it and returns focus to the parent.

The unsuffixed view names (`M-x agent-fleet-show-output`,
`M-x agent-fleet-worktree-status`, `M-x agent-fleet-magit-status`, and
`M-x agent-fleet-magit-diff`) are obsolete aliases of their `-in-buffer`
variants and will be removed in a future release.

## Attach to a live terminal

Press `a` on a dashboard row or run:

```text
M-x agent-fleet-attach
```

The command runs `herdr agent attach <pane-id>` inside the Ghostel terminal
backend. The attach buffer is named `*agent:NAME*` and is reused for the same
pane. It opens in the selected window, replacing its contents, so the terminal
fills the window you acted from. Killing the buffer or terminal process
detaches from the PTY; it does not kill the agent or close its pane.

Use a prefix argument to request terminal takeover:

```text
C-u M-x agent-fleet-attach
```

Choose a backend explicitly via `agent-fleet-attach-backend`; see
[Configuration](#configuration). When no in-Emacs backend is available,
agent-fleet reports the `herdr agent attach` command to run in your own
terminal.

The attach CLI targets the same Herdr socket as the active control
connection: Ghostel inherits a subprocess-local `HERDR_SOCKET_PATH`
pinned to that socket (Emacs's global `process-environment` is never
changed), and the no-backend fallback command embeds the same endpoint
with shell quoting. The PTY attach and the control RPCs therefore
always reach the same Herdr Session.

### Acting on the attached agent

An attach buffer already knows which agent it is driving, so once attached you
do not need to return to the dashboard or pick from a completion listing. The
single-key bindings live in `agent-fleet-attach-command-map`; the package does
not bind a prefix key by default, so set one yourself:

```elisp
(keymap-set agent-fleet-attach-mode-map "C-c C-a"
            #'agent-fleet-attach-command-map)
```

With the prefix above, these keys act on the current agent directly:

| Key | Action |
|---|---|
| `C-c C-a o` | Inspect recent output (buffer) |
| `C-c C-a d` | Open the working-tree diff (Magit, buffer) |
| `C-c C-a m` | Open Magit status (buffer) |
| `C-c C-a w` | Show worktree status (buffer) |
| `C-c C-a s` | Send a prompt |
| `C-c C-a S` | Compose a prompt in a child frame |
| `C-c C-a k` | Send keys |
| `C-c C-a i` | Send `Ctrl-C` |
| `C-c C-a x` | Kill the agent |
| `C-c C-a r` | Rename the agent |
| `C-c C-a h` | Open the transient action menu |

View keys (`o`/`d`/`m`/`w`) open an ordinary buffer; `S` opens the compose
child frame. The compose child frame floats over the terminal's parent so
the attached terminal's window geometry — and the PTY size the agent sees
— never changes while composing.

`C-c` passes through to Emacs in the terminal's char mode, so the prefix
reaches Emacs rather than the PTY; `h` (or `?`) lists the same actions
for discoverability. The commands are also available as `M-x
agent-fleet-attach-*` and signal a clear error outside an attach buffer.

### Composing prompts with C-g

Inside an attach buffer, `C-g` is handled by Agent Fleet. With the optional
editor bridge disabled (the default), it opens
`agent-fleet-attach-prompt-in-child-frame`, preserving the local compose
workflow. With the bridge enabled, Agent Fleet arms a one-shot route and sends
`Ctrl-G` to the exact Herdr pane. The CLI can then export its complete draft
to the file passed to `$EDITOR`; that file is opened by Emacs in an Agent Fleet
editor buffer in a new right-side window. The attach window remains visible.

#### Configure `emacsclient` as the agent editor

When Agent Fleet provisions a new pane for an agent, it sets both `EDITOR` and
`VISUAL` to `emacsclient --quiet` by default. No global environment change is
required. Enable the bridge before using the agent's external-editor action:

```elisp
(agent-fleet-editor-bridge-mode 1)
```

The default command connects to Emacs's default server. If this Emacs uses a
custom server name, configure a matching command before creating the agent:

```elisp
;; Set the server name before any Emacs server is started.
(setq server-name "agent-fleet"
      agent-fleet-agent-editor-command
      "emacsclient --quiet --socket-name agent-fleet")
(agent-fleet-editor-bridge-mode 1)
```

Use `--quiet` to prevent `emacsclient` from writing `Waiting for Emacs...` into
the agent PTY. Do **not** use `--no-wait` or `-n`: the editor process must wait
until `C-c C-c` or `C-c C-k` releases it, otherwise the agent may read the
draft before editing is complete.

Environment injection applies to panes created through `workspace.create`,
`pane.split`, or `tab.create`. An explicitly reused `:pane` and the root pane
returned by `worktree.create` retain their existing environment because those
Herdr operations do not expose an environment override. Agent Fleet never
mutates Emacs's global `process-environment`. The editor bridge is intended for
agents and Emacs on the same host with a shared filesystem.

| Key | Action |
|---|---|
| `C-g` (bridge disabled) | Open the Agent Fleet compose child frame |
| `C-g` (bridge enabled) | Send `Ctrl-G` and route the CLI editor file |
| `C-c C-c` (editor view) | Save, release `emacsclient`, and close the view |
| `C-c C-k` (editor view) | Discard unsaved edits and release `emacsclient` successfully |
| `C-c C-a S` | Open the independent Agent Fleet compose child frame |

The editor bridge does not use a child frame and works in graphical and
terminal Emacs. It creates a dedicated side window rather than replacing the
attach window or reusing an unrelated existing window. If the frame cannot
accommodate a separate side window, the editor request is aborted and the CLI
is released. Finishing or aborting deletes the side window and returns focus
to the attach window. The route accepts one server file visit only, expires
after `agent-fleet-editor-route-timeout`, and cannot distinguish simultaneous
`C-g` requests from multiple agents; a second pending request is rejected.

In the bridge-disabled compose workflow, text is pasted into the agent's
Ghostel terminal via bracketed paste (so multi-line prompts stay atomic) but
Enter is **not** pressed — the user reviews the text and presses Enter manually
to submit. In the bridge workflow, the CLI owns restoring its draft after the
editor exits; Agent Fleet does not scrape terminal output or inject Enter.
`C-c C-a S` remains available regardless of bridge state.

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
The dashboard mode line reports `Reconnecting`/`Disconnected` during these
transitions (see [Dashboard](#dashboard)), so a stale-looking list is never
silent about why.

The socket is discovered with the following precedence (highest first):
a nonempty explicit `herdr-socket-path`; the configured
`herdr-default-session-name`; the `HERDR_SOCKET_PATH` environment
variable; the `herdr status` socket line; and the default
`~/.config/herdr/herdr.sock`. Override the location explicitly with
`herdr-socket-path`, or name a Herdr Session with
`herdr-default-session-name`:

```elisp
;; Use the default Session (~/.config/herdr/herdr.sock).
(setq herdr-default-session-name "default")

;; Use a named Session (~/.config/herdr/sessions/work/herdr.sock).
(setq herdr-default-session-name "work")
```

A Session name must be a safe single path component (no separator or
NUL, not `.` or `..`). The client only resolves the path; it never
creates directories or starts Herdr, so a configured Session whose
socket is missing is a connection error with a `herdr session attach
NAME` hint. `nil` (the default) preserves the legacy discovery chain.

This is a connection-configuration option: changing it does not affect
an existing connection. Reconnect and every RPC stay pinned to the
endpoint saved on the current connection; only the next `M-x
herdr-connect` after an explicit disconnect resolves the current
setting. Agent Fleet maintains one active Herdr connection and does not
expose runtime Session switching or general Session/Workspace
management. Run `M-x agent-fleet-doctor` to check the configured default
Session, the effective socket, the Herdr connection, agent manifests,
and configured CLI executables.

## Configuration

All options are Emacs customization variables in the `agent-fleet` and `herdr`
groups; set them with `setq` or <kbd>M-x customize-group RET agent-fleet</kbd>.

### Connection and transport

| Option | Default | Meaning |
|---|---|---|
| `herdr-socket-path` | `nil` | Explicit Herdr Unix socket path; highest discovery precedence. `nil` auto-discovers from `herdr-default-session-name`, then `HERDR_SOCKET_PATH`, `herdr status`, then `~/.config/herdr/herdr.sock` |
| `herdr-default-session-name` | `nil` | Default Herdr Session name. A valid name resolves to its socket (`default` → `~/.config/herdr/herdr.sock`; other → `~/.config/herdr/sessions/NAME/herdr.sock`). `nil` keeps the legacy discovery chain. Changing it does not affect an existing connection; only the next connect after a disconnect resolves it |
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
| `agent-fleet-project-backend` | `'project` | Project detection source: `'project` (built-in `project.el`) or `'projectile` (requires Projectile); git repos resolve the same either way |
| `agent-fleet-default-read-source` | `'recent_unwrapped` | Default `agent.read` source: `'visible`, `'recent`, `'recent_unwrapped`, or `'detection` |
| `agent-fleet-default-read-lines` | `120` | Default line count for reads and output snapshots |
| `agent-fleet-default-read-format` | `'text` | Default read format: `'text` (ANSI stripped) or `'ansi` |
| `agent-fleet-start-timeout-ms` | `30000` | Startup timeout in ms passed to `agent.start` (Herdr requires 3000–300000) |
| `agent-fleet-wait-timeout-ms` | `120000` | Default timeout in ms for `agent-fleet-wait` and `-prompt-and-wait` |
| `agent-fleet-default-wait-until` | `'(done blocked)` | Default statuses `wait`/`prompt-and-wait` wait for |
| `agent-fleet-output-buffer-prefix` | `*Agent Output: ` | Prefix for output buffer names (buffer is `PREFIX<name>*`) |
| `agent-fleet-prompt-dwim-max-region-lines` | `50` | Maximum selected-region lines included verbatim by `agent-fleet-prompt-dwim`; larger regions send reference-only context |
| `agent-fleet-prompt-dwim-max-region-chars` | `4000` | Secondary character ceiling for selected text, retained for compatibility and very long single-line regions |

### External editor bridge

| Option | Default | Meaning |
|---|---|---|
| `agent-fleet-agent-editor-command` | `"emacsclient --quiet"` | Command assigned to `EDITOR` and `VISUAL` when Agent Fleet provisions a new agent pane; nil disables injection |
| `agent-fleet-editor-auto-start-server` | `t` | When enabling the bridge, start this Emacs's built-in server if it does not own one; never changes or stops an existing server |
| `agent-fleet-editor-route-timeout` | `30.0` | One-shot seconds to wait for the next `$EDITOR` server file visit |
| `agent-fleet-editor-side-window-width` | `0.5` | Width of the right-side editor window, as a frame fraction or column count |

The bridge is opt-in: run `M-x agent-fleet-editor-bridge-mode` and enable it.
It lazily loads `server`; ordinary Agent Fleet load/connect has no server side
effect. Set `agent-fleet-editor-auto-start-server` to `nil` when the server
must be started manually. `agent-fleet-agent-editor-command` must invoke
`emacsclient` for that same server.

### Dashboard

| Option | Default | Meaning |
|---|---|---|
| `agent-fleet-notify-on` | `'(blocked done)` | Agent statuses that trigger a notification; `nil` disables notifications |
| `agent-fleet-dashboard-buffer-name` | `*Agent Fleet*` | Name of the dashboard buffer |
| `agent-fleet-dashboard-display` | `'buffer` | Display backend: `'buffer`, `'child-frame`, or `'frame` |

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
remains the source of truth and reconnecting rebuilds the local snapshot.
The low-level protocol documentation covers Herdr methods that Agent Fleet does
not surface; their presence is not a commitment to build a general Herdr UI.
Authoritative cache rebuilds use the same event-deferral boundary described in
the dashboard section, so synchronous request pumping cannot discard a pushed
event that arrived during the rebuild. See
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the wire protocol and event shapes.

## Architecture

```text
Emacs
  |
  +-- agent-fleet-dashboard.el  live dashboard and contextual actions
  +-- agent-fleet-attach.el     interactive terminal attach
  +-- agent-fleet-editor.el     optional $EDITOR/server bridge for attaches
  +-- agent-fleet-display.el    shared child-frame presentation lifecycle
  +-- agent-fleet-project.el    logical project/codebase mapping
  +-- agent-fleet-worktree.el   isolated checkout management
  +-- agent-fleet-magit.el      optional status and diff integration
  +-- agent-fleet-parallel.el   multi-agent task orchestration
  +-- agent-fleet.el            agent lifecycle, target resolution, and control
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
