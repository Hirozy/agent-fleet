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

See [provider status setup](docs/PROVIDERS.md) for the checked Claude Code,
Codex and Pi versions, native reporting conditions, first-run setup and the
limits of the validation performed. No additional Fleet status hooks are needed
for the native implementations described there.

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

Dashboard always opens in the selected Emacs window, without a new frame or
split. The former `agent-fleet-dashboard-display` option is no longer used.
`q` / `C-g` restores the preceding buffer, point and scroll position. Each
window retains its own return path. Details, output and other Fleet views
opened from Dashboard return one step at a time. Successful attachment replaces
the review with the selected terminal; failed navigation keeps the review.
Existing terminal clients remain alive while hidden, retaining their PTY size.

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
Type commands with spaces and quoted arguments normally; `TAB` completes command
and template choices. For example, `sh -c "sleep 60"` keeps `sleep 60` as one argument.
Shell operators require an explicit shell command.
Generated names begin with a letter or digit and avoid terminal-ID forms such
as `t7`. For example, `.emacs.d` becomes `emacs-d`; a directory with no usable
characters falls back to `agent`. Conflict suffixes stay within Core's 32-character
limit. Explicit names are checked by Core and its rejection is preserved.

With a prefix argument, use a single form to edit command, directory, optional
name and initial template task. The form starts in the command field, using the
last selected command or the first entry in `agent-fleet-commands`.
`C-c C-c` requests launch once and `C-c C-k` closes from any field.
The form stays open and retains the started, rejected or uncertain result with
its submitted fields. After a successful launch, `C-c C-a` attaches directly in
the origin window. A failed initial template message is reported separately
from a successful launch. Closing the form does not cancel a pending request;
no result triggers an automatic retry or a focus change.
Local input errors detected before dispatch leave the fields editable so they
can be corrected. Submitted forms remain protected against duplicate launches.
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
Agent selection, same-Project selection and adoption show names, addresses and
status, and pin the offered terminal identity before the selection prompt opens.
If Core or the terminal changes while choosing, the subsequent operation rejects
that stale choice instead of acting on a replacement with the same address.

Core records parent relationships. Fleet only reads them for details and
termination impact; there is no separate Fleet Task lifecycle.

## Dashboard and commands

Run `M-x agent-fleet` or `C-c a a`.

Dashboard and review bindings also work with optional Evil enabled. Fleet's
bindings take precedence over Evil's default bindings in these views; explicit
user Evil bindings can still override them. Use the arrow keys or `C-n`/`C-p`
to move between rows. In the Dashboard, `C-c a` commands use the current row
and follow the same return rules as the single-key actions.
The header shows visible/total counts and active filters. Empty lists explain
how to start an agent or adjust filters. When a selected record disappears,
selection moves to a remaining row instead of an empty line.

| Dashboard key | Action |
|---|---|
| RET | Attach |
| v | Observe live without sending input or resizing the agent PTY |
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

The `Type` column shows the program's reported `status.app`, falling back to
the launch executable's name (for example, `claude`, `codex` or `pi`). It is
separate from the `Role` column's agent/helper relationship. Details also shows
whether the type came from a report or the launch command. Unknown types show
an em dash; wrappers remain their literal command name until an app reports.
This fallback never supplies or changes reported work status.

Details (`i`) groups runtime and reported work status, program/location,
relationships and recovery, and labels into readable sections. Each agent has
its own view, pinned to its full identity. `g` refreshes that snapshot while
preserving point; a failed refresh keeps the last successful record visible.
The header always shows current connection health separately from the snapshot.
Use `RET` to attach, `v` to observe, `p` to compose a prompt, `o` for output,
or `m` / `d` for Magit status / diff. These actions use the displayed agent
without another selection prompt and preserve the attached terminal's geometry.

`C-c a P` / `agent-fleet-prompt-dwim` opens an editable prompt with the current
file and selected line range, including selected text up to 4000 characters.
It prefers a same-Project agent and never saves files automatically.
Unsaved text can differ from the file on disk; review the draft before sending.

Prompt buffers use `C-c C-c` to submit once and `C-c C-k` to close. The recipient
and a styled result appear above the draft; status text is separate from the
editable prompt and is never sent. Rejections show Core's readable reason,
while the original structured response is retained. Submission requires a valid
Core acknowledgement with a turn number; it does not confirm work completion.
Drafts are retained on every outcome, including immediate transport errors.
Neither a closed buffer nor a local timeout cancels delivery. Unknown outcomes
are never automatically retried.

## Attachment and review

Ghostel runs `hc attach ADDRESS` with the pinned Core endpoint. One live viewer
is reused for each Core/terminal identity. Attachment replaces the origin
window without splitting. Killing its buffer or process detaches the viewer,
preserving the agent.

When invoked from attach, Fleet output, prompt and Magit views use an auxiliary
child frame on supported graphical Emacs. On a text terminal they replace the
current buffer without splitting. Genuine parent-frame resizing still reaches
the PTY. Arbitrary third-party window commands are outside this geometry
guarantee. Output is a finite snapshot; `g` refreshes the same pinned agent
without moving focus or resizing its terminal. Failed refreshes preserve the
previous snapshot. `C-c a v` / `agent-fleet-observe` instead
opens a realtime `hc attach --observe` viewer. Interactive and observe viewers
are reused separately. Core ignores observer input and resize; explicit Fleet
commands such as Prompt remain available. The external-editor key is disabled
in an observer. Its own viewport may crop/wrap output when its size differs
from the agent's PTY; it does not take over the agent's dimensions.

The optional `agent-fleet-editor-bridge-mode` retains the external-editor
workflow. In attach, `C-c C-g` arms it and sends exactly Ctrl-G; no Enter is
injected. The editor opens separately and closing it preserves the attach client.
Configure the provider's external editor to use `emacsclient` connected to this
Emacs server. Fleet does not provision `EDITOR` or `VISUAL` for Core terminals.

Magit opens the agent's actual local checkout. When Fleet recorded a review
base, the diff includes tracked changes since that commit, including commits
made by the agent. Status also lists untracked files.

## Worktrees and batch launch

`C-c a w` / `agent-fleet-start-worktree` asks for a command, source repository,
new branch and new directory. It creates a local Git worktree, records the exact
starting commit as `fleet.review-base`, and starts the agent there. Existing
destinations and branches are not overwritten. The worktree and branch remain
even if startup fails. Remove them explicitly through Git or Magit after review;
Fleet cleanup never deletes them.

```elisp
(agent-fleet-start-worktree '("claude") "/code/repo" "/code/worker" "feature/x"
                            :base "HEAD")
```

`C-c a b` / `agent-fleet-start-batch` collects a command and member directories,
optionally creating a new worktree for each member. A review buffer lists the
launches. `C-c C-c` requests them once; the same buffer retains each member's
started, failed or uncertain result. Closing the report does not cancel launches
already requested. Successful members are preserved when another fails. An
uncertain launch is not retried; inspect the Dashboard before starting again.
The review includes each initial task and starts on the first member. Use `n` /
`p` to move by member; asynchronous replies keep the current member selected.
For an acknowledged launch, `RET` attaches, `i` opens Details, `o` opens output,
and `C-c a p` composes a prompt. All actions use that member's original identity.
Results include counts, readable errors and retained checkout paths. Original
records and structured errors remain attached to each entry. Interruption or an
uncertain outcome stops launches that have not yet been dispatched; previously
dispatched requests still complete, and their later acknowledgements remain visible.

```elisp
(agent-fleet-start-batch
 '((:argv ("claude") :cwd "/code/repo"
    :worktree (:directory "/code/worker-a" :branch "feature/a"))
   (:argv ("codex") :cwd "/code/other")))
```

Members carry a shared `fleet.batch` label visible in Details. The report tracks
launch acknowledgements only; program and work status continue to come from Core.

## Remote agents and context

Configure machines through `hc machine add`; Fleet does not manage machine
provisioning. `C-c a r` / `agent-fleet-start-remote` chooses a connected machine,
remote command or template, and absolute POSIX cwd. Git on the remote machine
discovers the Project and review base; a non-Git directory remains a valid cwd
without a Project. Remote template arguments can include an initial task.

References pin the machine's permanent Core ID, terminal ID and creation time.
Route names can change without redirecting a pinned operation to a different
machine. Offline or replaced machines fail closed. Identity checks precede RPCs;
Core 0.1.17 does not offer an atomic identity precondition on routed mutations,
so avoid concurrently rebinding machine routes while issuing operations.

Remote Projects are separate by default. Explicitly associate one with a local
codebase for same-Project selection and context path mapping:

```elisp
(setq agent-fleet-remote-projects
      '((:machine "PERMANENT-CORE-ID"
         :remote "/srv/code/repo" :local "/Users/me/code/repo")))
```

Find the permanent ID with `hc machine ls --json`. This mapping does not sync
files. Prompt context maps relative paths into the agent's actual remote
checkout, including linked worktrees. Without a mapping the draft explicitly
identifies a local reference. Externally adopted agents have no inferred remote
Project metadata; their Project stays absent until explicitly supplied.

`C-c a f` / `agent-fleet-send-file` transfers a local file of at most 8 MiB through
`terminal.put`, then opens an unsent prompt containing the acknowledged remote
path. It writes a Core-owned artifact, not a checkout file. Submit explicitly
with `C-c C-c`; history removal also removes these artifacts.

For remote targets, the status/diff commands show a read-only status and tracked
diff snapshot via `machine.exec`, without requiring Magit or interpreting remote
paths locally. The recorded review base includes agent commits; untracked files
are listed without reading their contents. Timed-out or truncated responses are
reported as incomplete failures. There is no automatic repository synchronization.

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

The review starts on the first record. Use `n` / `p` to move between records;
selection changes keep the current record in focus. The review shows the selected
count, and the result shows counts for each outcome, including unattempted records.

Dashboard filters do not restrict cleanup. Live agents, including those reporting
done, are preserved. Records with remaining children are retained so relationships
are not lost. Finished children are processed before parents. New records created
after review are not added to the selection.

Identity, current state and Fleet association are rechecked before each removal.
Core also rejects removal of live terminals. Failed/uncertain results and
unattempted targets remain visible; uncertain outcomes stop further removals.
Each result retains its reason and structured error, including the original
response when a removal acknowledgement does not match the reviewed target.
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
  reconnect, history removal, parent/child termination, and a second Core reached
  through a local relay for remote launch, context transfer, review and rename.
  This tests real Core routing but does not test SSH authentication or a WAN.
  Set `FLEET_TEST_HC`
  when hc is outside PATH.
- `make test-optional OPTIONAL_LOAD_PATH='-L /path/to/evil -L /path/to/goto-chg'`:
  separate integration checks for actual Evil keymaps and widget fields.
- `make test-gui GUI_LOAD_PATH='-L /path/to/ghostel/lisp -L /path/to/compat ...'`:
  a fresh graphical Emacs with your optional packages on its load path. Tests
  real Ghostel attachment, frame lifecycle, geometry and detach, plus Magit when
  available. When Evil is on the load path, it also checks Dashboard and form
  commands with Evil active. Results go to `FLEET_GUI_RESULT` or `/tmp/fleet-gui-result`.

See [the protocol contract](docs/PROTOCOL.md) and
[the pinned schema](docs/hc-0.1.17.openrpc.json).
