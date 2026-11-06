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
(global-set-key (kbd "s-d") #'agent-fleet)
```

Fleet installs no global bindings. The opt-in global `C-c a` prefix contains
only `a` (Dashboard) and `P` (DWIM prompt). The optional global `s-d` binding
opens Dashboard from any view, including terminal input mode. Attach mode
extends `C-c a` locally with the complete agent actions listed below.

Dashboard always opens in the selected Emacs window, without a new frame or
split.
`q` / `C-g` restores the preceding buffer, point and scroll position. Each
window retains its own return path. Details, output and other Fleet views
opened from Dashboard return one step at a time. Successful attachment replaces
the review with the selected terminal; failed navigation keeps the review.
Existing terminal clients remain alive while hidden, retaining their PTY size.
Returning to Dashboard preserves the selected agent across background refreshes
and reordering. If that row disappears, selection moves to a remaining agent.

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

`M-x agent-fleet-start` asks for a template or command and a working
directory, then attaches after successful startup. Interactive Project launch
(`agent-fleet-start-for-project`, including Projectile bindings) uses the same
flow, defaulting to the current checkout root. The name defaults to the Project name, or directory name when no
Project exists, normalized for Core and suffixed on conflict. Names are display
labels, never identity.
Type commands with spaces and quoted arguments normally; `TAB` completes command
and template choices. For example, `sh -c "sleep 60"` keeps `sleep 60` as one argument.
Shell operators require an explicit shell command.
Generated names begin with a letter or digit and avoid terminal-ID forms such
as `t7`. For example, `.emacs.d` becomes `emacs-d`; a directory with no usable
characters falls back to `agent`. Conflict suffixes stay within Core's 32-character
limit. Explicit names are checked by Core and its rejection is preserved.

Dashboard's `h N`, or terminal `C-c a N`, starts entirely through the minibuffer: choose a command or
template, confirm the working directory, then launch and attach. Both prompts
offer defaults, so `h N RET RET` repeats the last command in the Dashboard context.
The name is generated automatically. Dashboard uses the selected local agent's
working directory, falling back to the directory from which Dashboard was opened.
Remote directories are never resolved locally. `C-g` at any prompt starts nothing.
Using a prefix argument with `N` additionally asks for an optional name, an initial task when a template
was selected, and whether to attach or stay in the background. No form buffer
opens. A pending launch prevents accidental duplicate submission from that view.
If you leave the initiating window while waiting, the agent starts without
taking focus. Failed attachment never launches again; use `RET` on the new agent.
Launch outcomes and original errors are retained in `agent-fleet-control-results`.

`agent-fleet-start-form`, or a prefix argument to `agent-fleet-start`, still
provides an explicit editable form for callers who want it.
Choose a configured agent with its button, use **Choose command / template**
(`C-c C-p`) for completion, or edit the command directly. **Browse directory**
(`C-c C-d`) opens directory completion. The form remembers the last command;
name and initial template task are optional.

**Start & attach** (`C-c C-a`) launches once and enters the new terminal if the
form is still selected in the focused Emacs frame when Core acknowledges it. **Start in background**
(`C-c C-c`) keeps the result in the form. After success, the same `C-c C-a`
attaches without launching again. If you leave the form while waiting, the
result is retained without taking focus. A failed initial template message or
failed attach stays visible; neither causes another launch. `C-c C-k` returns
to the preceding view from any field. Closing does not cancel a pending request.
Local input errors detected before dispatch leave the fields editable so they
can be corrected. For a definite Core rejection, **Edit request** (`C-c C-e`)
unlocks the existing fields for correction and an explicit new submission.
Uncertain results remain locked; inspect Dashboard before starting again.
`agent-fleet-start-for-project` starts at the current checkout's project root.
Inside a linked worktree it stays in that worktree, never switching to the
primary checkout used for Project grouping. The ordinary start command defaults
to the current buffer's working directory; Dashboard `h N` retains the selected
agent's exact working directory, including subdirectories.

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
to move between rows. Dashboard actions live in the `h` Transient menu.
Its action keys match the terminal's `C-c a` suffixes, except `a`: Dashboard
uses it to attach, while `C-c a a` always opens Dashboard. Both interfaces are
generated from the same action definitions. Code buffers retain only the global Dashboard/DWIM entry
points; prompt buffers retain their local submit, attach and return keys.
The table shows Agent, Type, Status and ID. The name column uses up to the space
available in the window, expanding for long names and shrinking in narrow views.
Truncated names have an ellipsis; hover for the full text or open Details (`h I`).
Type retains room for names such as `claude-code`. Role and parent information
are in Details; a member with a parent also has a muted relationship annotation.
Projects appear once as emphasized group headings with visible member counts
and a muted canonical root path (`~` abbreviates the local home directory).
The header shows column titles; the mode line shows connection health,
visible/total counts and active filters. Project filter labels are shortened;
their full identity remains in heading tooltips, the mode-line tooltip and Details. Empty lists explain
how to start an agent or adjust filters. When a selected record disappears,
selection moves to a remaining row instead of an empty line.

| Dashboard `h` suffix / terminal `C-c a` suffix | Action |
|---|---|
| a | Attach in Dashboard; open Dashboard from the terminal prefix |
| RET | Attach |
| v | Observe live without sending input or resizing the agent PTY |
| N | Start an agent through minibuffer prompts |
| J | Start for the current Project |
| s | Compose a prompt |
| P | DWIM prompt |
| o | Read an output snapshot |
| I | Identity, state and parent details |
| m / d | Magit status / working-tree diff |
| i / x | Interrupt / explicitly end a program |
| c | Review finished-history cleanup |
| w / b / r | Start in a worktree / batch / remote machine |
| f / + | Send a file / include a terminal |

Dashboard directly binds `h` (menu), `a/RET` (attach), `n/p`, `j/k`, arrows and
`C-n/C-p` (agent navigation), `g` (refresh), and `q/C-g/Escape` (return).
Within the menu, `n/p` also navigate and keep the menu open. Only explicit
navigation updates the pinned menu target; background events cannot redirect
an action. Dashboard-only menu keys are `/` (Project filter), `!` (attention),
`H` (history), `g` (refresh) and `q` (return). Project filtering moved from `P`
to `/` so `P` always means DWIM. Terminal `n/p` suffixes are unbound.

Existing terminal bindings change from `n` to `N` for a new agent, `N` to `J`
for Project launch, `p` to `s` for prompt, `i` to `I` for Details, `s` to `i`
for interrupt, and `k` to `x` for ending a program.
Restart Emacs after upgrading to replace keymaps already loaded in the session.

Agents are grouped by canonical Project, with disambiguated short headings.
Linked worktrees share one group; absent Projects have a separate
`— No Project` group. The current
Project is placed first when opening from code or an attached agent. Within
groups, status priority and name determine row order. Row highlighting and
navigation always target agents, not headings. The Transient menu pins the
selected agent identity when opened, so later events cannot redirect its actions.

The connection banner shows stale/disconnected state independently of program
state. Project identity follows the canonical Git common root across linked
worktrees. Group headings use the project root's directory name; same-name
projects gain enough parent path components to distinguish them. Filtering
continues to use full canonical identity, never the displayed name. Independent
clones and nested repositories remain separate Projects.

Subdirectories get a muted relative location such as `./frontend/` beneath
their agent row. Linked worktrees show `Worktree:` followed by the actual
working directory, including any subdirectory. Ordinary project-root rows
need no annotation because the path is already in the heading. Long paths
retain their trailing components with a leading ellipsis; full paths remain
available in tooltips and Details (`h I`). A heading's path moves to its own line
when little space remains beside the title. `n` / `p` skips annotations and
heading paths, while actions on an agent's annotation still target that agent.

Non-project agents stay together under `— No Project`, with their actual
directory shown beneath each row without a redundant label. Missing or
inaccessible directories get an explicit warning instead of silently looking
like ordinary non-project folders.
No historical project identity is fabricated for them. Remote working paths
are marked `Remote:` and never resolved or home-abbreviated locally.

Local Project discovery is cached by canonical directory and project backend
for up to 30 seconds, including results with no Project. Events reuse that
discovery rather than running Git for every status change. A directory change
uses a different entry; missing directories invalidate their entry immediately.
`g` in Dashboard or Details forces rediscovery (use it after creating project
markers or changing repository layout). Automatic refreshes rediscover expired
entries on demand; this cache is not lifecycle state. Explicit project launches
always rediscover the current checkout before starting.

The `Type` column shows the program's reported `status.app`, falling back to
the launch executable's name (for example, `claude`, `codex` or `pi`). It is
separate from the agent/helper role shown in Details. Details also shows
whether the type came from a report or the launch command. Unknown types show
an em dash; wrappers remain their literal command name until an app reports.
This fallback never supplies or changes reported work status.

Details (`h I` in Dashboard) groups runtime and reported work status, program/location,
relationships and recovery, and labels into readable sections. Each agent has
its own view, pinned to its full identity. `g` refreshes that snapshot while
preserving point; a failed refresh keeps the last successful record visible.
The header always shows current connection health separately from the snapshot.
Use `RET` to attach, `v` to observe, `p` to compose a prompt, `o` for output,
or `m` / `d` for Magit status / diff. These actions use the displayed agent
without another selection prompt and preserve the attached terminal's geometry.

`C-c a P` / `agent-fleet-prompt-dwim` opens an editable prompt with the current
file and selected line range, including selected text up to 4000 characters.
In code buffers it prefers a same-Project agent. In Fleet views it uses the
selected or attached agent without another picker. It never saves files automatically.
Unsaved text can differ from the file on disk; review the draft before sending.

Prompt buffers use `C-c C-c` to submit once and enter the agent's terminal after
Core acknowledges submission. `C-c C-a` opens that agent directly without
sending text; `C-c C-k` returns to the preceding view. Automatic attachment only
happens while the submitting window still shows the prompt and has focus; it
does not interrupt another window, application or active minibuffer. If attaching
fails, the prompt retains its submission result and attachment error. Use
`C-c C-a` to retry attachment without resending. Successful attachment hides the
prompt but retains its text and result in the buffer.

The recipient and a styled result appear above the draft; status text is separate from the
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
are reused separately. In an observer, `q` closes the observer client and returns
to the preceding buffer and position; the agent and any interactive attach
client keep running. Ordinary interactive attach still sends `q` to the program.
Core ignores observer input and resize; explicit Fleet
commands such as Prompt remain available. The external-editor key is disabled
in an observer. Its own viewport may crop/wrap output when its size differs
from the agent's PTY; it does not take over the agent's dimensions.

In attach, `C-c C-g` sends exactly Ctrl-G through Core, without Enter. The CLI
decides what that key does. For CLIs that use it to edit their current prompt,
configure their external editor to use `emacsclient --create-frame` connected
to your Emacs server (start it with `M-x server-start`; use `--socket-name` for
a named server). Do not use `--no-wait`: the CLI must wait for editing to finish.
Use Emacs's `C-x #` (`server-edit`) to save and finish editing, then review the
returned draft in the CLI before submitting according to that CLI's behavior.
A separate editor frame leaves the attach window's size intact.

Fleet does not route server requests, manage external-editor frames or configure
`EDITOR` / `VISUAL`. Configure the editor where the agent actually runs; changing
Emacs's environment does not reconfigure an existing Core program. Automatic
focus restoration and editor cancellation follow Emacs and the CLI's behavior.
For a new message composed and submitted entirely through Fleet, use terminal `C-c a s`.
When upgrading from the editor bridge, remove its require/mode settings and
restart Emacs after finishing active external edits.

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
and `s` composes a prompt. All actions use that member's original identity.
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
End, interrupt and wait show concise results with the agent name and address.
An interrupt that leaves the agent working, a wait timeout and an unknown
outcome are reported explicitly; none is presented as successful completion.
Responses are never retried automatically. `M-x agent-fleet-control-results`
opens the latest 30 outcomes in this Emacs session, retaining pinned identities,
original responses and structured diagnostics without interrupting navigation.

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
selection changes keep the current record in focus. Records are grouped by their
reported directory, with aligned agent names and terminal IDs. Directory groups
only affect presentation; removal still processes children before parents.
The review shows the selected count and checkboxes. Results replace checkboxes
with outcome labels and show only nonzero outcome counts, including unattempted
records. Success, skipped and error outcomes use theme-aware faces; diagnostic
text remains visible beneath the affected record.

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

## Verification

- `make test`: strict byte compilation and isolated ERT, including terminal-key
  dispatch, lifecycle safety and presentation regressions.
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
