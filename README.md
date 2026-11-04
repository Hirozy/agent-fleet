# Agent Fleet

Agent Fleet brings herdr-core coding agents into Emacs. Core owns terminals,
processes and reported status. Emacs provides launch, prompts, attention,
terminal attachment, code review and finished-history cleanup.

## Requirements

- Emacs 29.1 or newer.
- herdr-core `hc` 0.1.17 or newer with protocol generation 1 and the required
  methods. The checked-in schema is from 0.1.17.
- An installed coding-agent command or Core template.
- Optional Ghostel with a working native module for interactive attachment.
- Optional Magit for code review; optional Consult for agent selection.

A terminal can be live while its program reports `done`. Programs without
OSC 7501 reports display `unreported`; Fleet never infers status from text.
Missing status does not remove an agent from Fleet. Wait reasons are preserved:
a timeout, blocked status or process exit is not presented as successful work.

## Installation

Run `make autoloads` after updating a source checkout, then load the generated
autoload file through your package manager or configuration:

```elisp
(add-to-list 'load-path "/path/to/agent-fleet")
(load "/path/to/agent-fleet/agent-fleet-autoloads.el")
(setq herdr-core-executable (expand-file-name "~/.local/bin/hc"))
(global-set-key (kbd "C-c a") 'agent-fleet-command-map)
```

Fleet installs no global bindings. Its attach mode provides a buffer-local
`C-c a` map whose commands use the current terminal.

The default Dashboard opens in a buffer. To opt into a centered child frame:

```elisp
(setq agent-fleet-dashboard-display 'child-frame)
```

Unsupported graphical runtimes fall back to a buffer. Child views always use
a non-child origin, and Dashboard navigation closes its child only after the
destination opens successfully.

## Connect

The first operation connects using `hc connect`. By default hc may start Core;
set `herdr-core-auto-start` to nil to require an existing socket.

Configure `herdr-core-session` (default `"default"`) and optionally
`herdr-core-socket`. Endpoint precedence is explicit socket, `HC_SOCKET`,
then the standard session socket under the XDG runtime/state directory.
If Core's config.toml specifies a custom socket, configure the same path
in `herdr-core-socket`.

The executable and subprocess environment are captured at connection time.
Reconnect and attach use that same endpoint. Configuration changes apply after
an explicit disconnect/reconnect. `M-x herdr-core-disconnect` detaches Fleet;
it does not stop Core or any program. No Fleet command stops the Core server.

## Start and include agents

`C-c a n` / `agent-fleet-start` asks for a template or command and a working
directory. The name defaults to the Project name, or directory name when no
Project exists, normalized for Core and suffixed on conflict. Names are display
labels, never identity.

With a prefix argument, use a single form to edit command, directory, optional
name and initial template task. `C-c C-c` requests launch once.
`agent-fleet-start-for-project` starts in the current Project.

```elisp
(agent-fleet-start '("claude") :cwd "/path/to/code")
(agent-fleet-start '("reviewer") :cwd "/path/to/code"
                   :task "Review the changes without editing.")
```

These calls return asynchronous request IDs. Fleet starts independent root
terminals with `keep` and automatic removal disabled. A first message that
was not sent is reported; the already-started program is preserved. Inspect
Details and open Prompt to explicitly submit again.

Fleet marks its agents with `fleet.role=agent`. Use `agent-fleet-adopt` to
include an external terminal, or set the label through Core. Descendants of
included agents appear as helpers unless explicitly marked as agents.
A missing status does not mean a terminal is safe to discard.

Core records parent relationships. Fleet only reads them for details and
termination impact; there is no separate Fleet Task lifecycle.

## Dashboard and commands

Run `M-x agent-fleet` or `C-c a a`.

| Dashboard key | Action |
|---|---|
| RET | Attach |
| n | Open the start form |
| p | Compose a prompt |
| o | Read an output snapshot |
| i | Identity, state and parent details |
| m / d | Magit status / working-tree diff |
| s / k | Interrupt / explicitly end a program |
| h | Toggle finished history |
| P | Toggle the current row's Project filter |
| ! | Toggle blocked/error members |
| c | Review finished-history cleanup |
| g | Render the current event-driven cache |
| q | Close |

The connection banner shows stale/disconnected state independently of program
state. Project identity follows the canonical Git common root across linked
worktrees. Non-project directories display an em dash. Remote paths are never
resolved against the local filesystem.

`C-c a P` / `agent-fleet-prompt-dwim` opens an editable prompt with the current
file and selected line range, including selected text up to 4000 characters.
It prefers a same-Project agent and never saves files automatically.
Unsaved text can differ from the file on disk; review the draft before sending.

Prompt buffers use `C-c C-c` to submit once and `C-c C-k` to close. The header
distinguishes sending, sent, rejected and uncertain results. Sent means
submitted, not completed. Drafts are retained. Neither a closed buffer nor a
local timeout cancels delivery. Unknown outcomes are never automatically retried.

## Attachment and review

Ghostel runs `hc attach ADDRESS` with the pinned Core endpoint. One live viewer
is reused for each Core/terminal identity. Attachment replaces the origin
window without splitting. Killing its buffer or process detaches the viewer,
preserving the agent.

When invoked from attach, Fleet output, prompt and Magit views use an auxiliary
child frame on supported graphical Emacs. On a text terminal they replace the
current buffer without splitting. Genuine parent-frame resizing still reaches
the PTY. Arbitrary third-party window commands are outside this geometry
guarantee. Output is a finite snapshot; realtime observe is not implemented.

The optional `agent-fleet-editor-bridge-mode` retains the external-editor
workflow. In attach, `C-c C-g` arms it and sends exactly Ctrl-G; no Enter is
injected. The editor opens separately and closing it preserves the attach client.

Magit opens the agent's actual checkout. Existing worktrees are supported as
cwd values; creating worktrees and remote checkout review are deferred.

## End programs and clean history

Interrupt asks the program to stop its current work. Kill explicitly ends its
program and previews dependent descendants. Core may also end descendants
created after that preview; Fleet cannot atomically freeze this relationship.

Cleanup has one meaning: remove finished Fleet terminal records and their
retained output history. It never kills programs and never deletes directories.

```text
agent-fleet-cleanup
  -> review all eligible finished Fleet records on this connection
  -> SPC to exclude individual records
  -> C-c C-c to execute once
  -> results in the same buffer
```

Dashboard filters do not restrict cleanup. Live agents, including those reporting
done, are preserved. Records with remaining children are retained so relationships
are not lost. Finished children are processed before parents. New records created
after review are not added to the selection.

Identity, current state and Fleet association are rechecked before each removal.
Core also rejects removal of live terminals. Failed/uncertain results and
unattempted targets remain visible; uncertain outcomes stop further removals.
There is no automatic retry and no worktree cleanup.

## Migration from the original Herdr backend

This version uses herdr-core exclusively. Restart Emacs when switching from the
old backend so old bytecode, hooks and loaded definitions are not retained.

Removed: the original `herdr-*` connection commands, Workspace/Tab/Pane
provisioning, `agent-fleet-parallel`, Task APIs and old worktree RPC commands.
Configure `herdr-core-*` options and use literal argv lists for the Lisp start API.
Consult now exposes the optional `consult-agent-fleet` command.

Existing old-Herdr programs are not transferred to Core. The migration does not
close them. Start new Core agents explicitly. Existing Git checkouts can be reused.

## Verification

- `make test`: strict byte compilation and isolated ERT, including retained
  external-editor safety regressions.
- `make test-live`: fresh temporary Core session/config/state; validates events,
  reconnect, history removal and parent/child termination. Set `FLEET_TEST_HC`
  when hc is outside PATH.
- `make test-gui GUI_LOAD_PATH='-L /path/to/ghostel/lisp -L /path/to/compat ...'`:
  a fresh graphical Emacs with your optional packages on its load path. Tests
  real Ghostel attachment, frame lifecycle, geometry and detach, plus Magit when
  available. Results go to `FLEET_GUI_RESULT` or `/tmp/fleet-gui-result`.

See [the protocol contract](docs/PROTOCOL.md) and
[the pinned schema](docs/hc-0.1.17.openrpc.json).
