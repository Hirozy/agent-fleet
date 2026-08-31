# Herdr Socket API Protocol Reference

Authoritative reference for the Herdr wire protocol, captured by reading the
**Herdr 0.8.2** (protocol **20**) source (`src/` in github.com/herdrdev/herdr)
and confirmed with direct socket probes.

This document is the spec the Emacs client (`herdr-protocol.el`, `herdr-model.el`,
`herdr-events.el`, `herdr.el`) is built against. It is **runtime-verified**, not
assumed — but Herdr may change between versions, so the client must always:

- discover the socket and protocol version at runtime (`ping`, `herdr status`),
- tolerate unknown JSON fields (Herdr protocol clients are expected to be
  forward-compatible),
- treat `session.snapshot` as the canonical resync; never synthesize a
  client-side missed-event replay. Herdr may still drain its bounded EventHub
  buffer on subscribe, so event application must be idempotent.

---

## 1. Transport

- **Unix domain socket** (AF_UNIX). The client discovers the path with
  the following precedence (highest first): a nonempty explicit
  `herdr-socket-path`; the configured `herdr-default-session-name`
  (`default` → `~/.config/herdr/herdr.sock`; any other valid name →
  `~/.config/herdr/sessions/<name>/herdr.sock`); the `HERDR_SOCKET_PATH`
  environment variable; the path printed by `herdr status` under
  `server.socket`; and the default `~/.config/herdr/herdr.sock`. A nil
  `herdr-default-session-name` keeps the legacy chain (explicit, env,
  status, default). A missing socket for a configured Session is a
  connection error; the name must be a safe single path component. The
  resolved endpoint is saved on the connection and reused by reconnect
  and every RPC, so a later setting change does not move a live
  connection.
- **Newline-delimited JSON.** Each message is one UTF-8 JSON object terminated by
  `\n`. A single JSON object may be split across multiple `recv` calls, so a
  client must buffer until the terminating `\n`.
- No length prefix. No authentication on the local socket.

## 2. Connection model  ⚠ critical

Probed empirically — this is the single most important design fact:

- **Request connections are one-shot.** Open a socket, send exactly one
  request line, read exactly one response line, then the **server closes the
  connection** (confirmed: a second request on the same socket gets
  `BrokenPipeError`). Each request opens a fresh connection. There is therefore
  no request-multiplexing / pending-request table — the `id` field is still
  echoed in the response and is useful for logging, but is not needed for
  correlation on a shared socket.
- **Subscription connections are long-lived.** Open a socket, send
  `events.subscribe`, read the `subscription_started` ack, then the server
  pushes event lines indefinitely until the client closes. A subscription
  connection does **not** accept further requests.
- One client therefore holds: N short-lived one-shot request sockets (created
  on demand) + 1 long-lived subscription socket (held for the session).

## 3. Message envelopes

```
request      : {"id":"<str>","method":"<str>","params":{...}}      required: id, method, params
success      : {"id":"<str>","result":<method-specific>}            required: id, result
error        : {"id":"<str>","error":{"code":"<str>","message":"<str>"}}  required: id, error
```

Pushed events use **two** envelope shapes depending on which subscription
produced them (verified against `src/api/schema/events.rs`):

```
GLOBAL push  : {"event":"<underscored>","data":{"type":"<underscored>",...payload}}
PER-PANE push: {"event":"<dotted>","data":{...payload}}            // NOTE: data is UNTAGGED (no "type")
```

- **Global** events (`EventEnvelope`): `event` is an *underscored* `EventKind`
  (`#[serde(rename_all="snake_case")]`, e.g. `"pane_created"`), and `data` is
  an `EventData` enum tagged `#[serde(tag="type")]` — so `data.type` repeats
  the underscored kind.
- **Per-pane** subscription events (`SubscriptionEventEnvelope`): `event` is a
  *dotted* `SubscriptionEventKind` (explicit dotted renames, e.g.
  `"pane.agent_status_changed"`), and `data` is a `SubscriptionEventData`
  enum marked `#[serde(untagged)]` — so there is **no `type` field** inside
  `data`, and `event` is dotted, not underscored. The three per-pane kinds are
  `pane.agent_status_changed`, `pane.output_matched`, `pane.scroll_changed`.
- `params` is always a JSON object; for parameter-less methods (`ping`,
  `session.snapshot`, `server.*` with `EmptyParams`) it is `{}` (empty object),
  **not** `null`.
- Pushed subscription messages have **no `id`** — they are not correlated to a
  request. Route them by the `event` field. Because per-pane pushes are dotted
  while the model's event arms speak the underscored form, the client
  normalizes dotted→underscored on receipt (a no-op for global pushes, which
  contain no dots).

## 4. Error model

Server errors come back on the same one-shot connection as the request:

```json
{"id":"r1","error":{"code":"invalid_request","message":"invalid request: missing field `pane_id` at line 1 column 220"}}
```

Observed codes: `invalid_request`. The schema defines `error.code` (string) and
`error.message` (string), both required. The client maps these to structured
Lisp errors (`herdr-request-error` carrying the `code`), not bare `error`.

A missing/unknown-field request is rejected with `invalid_request` and the
**whole request** fails (it is atomic). The response `id` may be the request's
`id` or empty `""` on early parse failure — do not rely on it for correlation;
the one-shot connection already disambiguates.

## 5. `ping`

- Request: `{"id":"1","method":"ping","params":{}}`
- Result:
  ```json
  {"type":"pong","version":"0.8.2","protocol":20,
   "capabilities":{"live_handoff":true,"detached_server_daemon":true}}
  ```
- `protocol` (int) is the authoritative protocol version; compare against
  `herdr-required-protocol-version`. `capabilities` is a map of bools —
  tolerate unknown keys (it is `Option` and may be omitted/null on some
  builds).

## 6. `session.snapshot`

- Request: `{"id":"1","method":"session.snapshot","params":{}}`
- Result: `{"snapshot":{ ... }}` where the snapshot object is:

```
snapshot = {
  protocol: int,
  version: str,
  focused_workspace_id, focused_tab_id, focused_pane_id: str,
  workspaces: [ WorkspaceInfo ],
  tabs:       [ TabInfo ],
  panes:      [ PaneInfo ],
  agents:     [ AgentInfo ],   // agents are panes-with-agents; fields ⊇ PaneInfo
  layouts:    [ PaneLayoutSnapshot ],
}
```

### WorkspaceInfo
```
workspace_id, label (str, required), number (int), focused (bool),
active_tab_id (str, required), tab_count (int), pane_count (int),
agent_status (str: idle|working|blocked|done|unknown),
tokens? ({str:str}), worktree? (WorkspaceWorktreeInfo)
```

### TabInfo
```
tab_id, workspace_id, label (str, required), number (int), focused (bool),
pane_count (int), agent_status (str)
```

### PaneInfo
```
pane_id, terminal_id, workspace_id, tab_id (str, required),
focused (bool, required), cwd?, foreground_cwd?,
label?, agent? (str: "claude"|"codex"|"pi"|...), title?,
terminal_title?, terminal_title_stripped?, display_agent?,
agent_status (str, required),
state_labels? ({str:str}), tokens? ({str:str}),
agent_session? ({ agent, kind: "id"|"path", source, value }),
scroll? ({ offset_from_bottom, max_offset_from_bottom, viewport_rows }),
revision (int, required)
```

### AgentInfo
A **distinct** struct (NOT a superset of PaneInfo). It shares most fields with
`PaneInfo` but adds `name?`, `screen_detection_skipped?`,
`launch_pending?`, `interactive_ready?`, `state_change_seq?` and **omits**
`label` and `scroll`. The agent-kind field is `agent?` (Option<String>); the
optional human name is `name?`. An "agent" in the snapshot is identified by
`pane_id` and `agent` (kind). The named-agent concept (regex
`[a-z][a-z0-9_-]{0,31}`, unique across live agents) applies to agents created
via `agent.start`, which takes `name`/`kind`/`pane_id`/`args`. Phase 1 keys
agents by `pane_id`; the optional `name` slot is populated in Phase 2.

### AgentStatus enum
`idle`, `working`, `blocked`, `done`, `unknown`.
The client may add local-only runtime states `dead` / `disconnected` for panes
whose agent process has exited or whose socket is down — these are not Herdr
lifecycle states.

## 7. Events: subscribe + push

### 7.1 `events.subscribe`
- Request params: `{"subscriptions":[ Subscription, ... ]}` (required:
  `subscriptions`).
- A `Subscription` is an object with a `type` field (dotted kind) plus,
  for pane-scoped subscriptions, extra required fields.
- Result: `{"type":"subscription_started"}`. The connection then becomes
  push-only.

### 7.2 Subscription `type` values (dotted), 27 total

Global (no extra fields):
```
workspace.created workspace.updated workspace.metadata_updated
workspace.renamed workspace.moved workspace.reordered workspace.closed
workspace.focused
worktree.created worktree.opened worktree.removed
tab.created tab.closed tab.focused tab.renamed tab.moved
pane.created pane.closed pane.updated pane.focused pane.moved pane.exited
pane.agent_detected
layout.updated
```

Pane-scoped (require `pane_id`):
```
pane.agent_status_changed   { type, pane_id, agent_status? }
pane.scroll_changed         { type, pane_id }
```

Content-match (require `pane_id` + `source` + `match`):
```
pane.output_matched         { type, pane_id, source, match, lines?, strip_ansi? }
```

Because `pane.agent_status_changed` needs a `pane_id`, a fleet client must
subscribe **per agent pane** and **rebuild** that subset whenever panes are
created/closed.

### 7.3 Pushed event kinds

**Global** pushes carry an underscored `event` (and a tagged `data.type` that
repeats it) — the 26 `EventKind` variants (`src/api/schema/events.rs`):

```
workspace_created workspace_updated workspace_metadata_updated workspace_closed
workspace_renamed workspace_moved workspace_reordered workspace_focused
worktree_created worktree_opened worktree_removed
tab_created tab_closed tab_renamed tab_moved tab_focused
pane_created pane_closed pane_updated pane_focused pane_moved
pane_output_changed pane_exited pane_agent_detected pane_agent_status_changed
layout_updated
```

Note `pane_scroll_changed` is **not** a global `EventKind` — it exists only as a
per-pane subscription kind. (`pane_agent_status_changed` *is* a global
`EventKind` and enters the `EventHub` ring, but there is no *global* subscription
type for it — see §7.2 — so a fleet client only ever receives it via the
per-pane subscription below.)

**Per-pane** pushes carry a dotted `event` and untagged `data` — the 3
`SubscriptionEventKind` variants (`src/api/schema/events.rs`):

```
pane.agent_status_changed   { pane_id, workspace_id, agent_status,
                              agent?(str), title?(str),
                              display_agent?(str), state_labels }
pane.output_matched         { pane_id, matched_line(str), read(PaneReadResult) }
pane.scroll_changed         { pane_id, workspace_id, scroll(PaneScrollInfo) }
```

**The dotted→underscored mapping is one-way and global-only.** A *global*
subscription type (`pane.created`) produces an *underscored* global push
(`pane_created`) — the `.`→`_` mapping holds. A *per-pane* subscription type
(`pane.output_matched`) produces a *dotted* per-pane push
(`pane.output_matched`) — the kind is **not** remapped to `pane_output_changed`
(earlier versions of this doc had that backwards); `pane_output_changed` is a
separate *global* `EventKind` pushed to global subscribers, not to
`pane.output_matched` subscribers.

### 7.4 Event payloads (selected)

- `workspace_*`: carry `workspace` (WorkspaceInfo) and/or `workspace_id`.
- `tab_*`: carry `tab` (TabInfo) and/or `tab_id`/`workspace_id`.
- `pane_created`/`pane_updated`: carry `pane` (PaneInfo).
- `pane_closed`/`pane_exited`: carry `pane_id`/`workspace_id`.
- `pane_focused`: `pane_id`/`workspace_id`.
- `pane_moved`: carries `pane`, `previous_pane_id/tab_id/workspace_id`, and
  possibly `created_*`/`closed_*` — a move may change a pane's
  workspace-qualified `pane_id`; the agent `name` (Phase 2) survives as a live
  alias. Phase 1 treats `pane_id` as mutable across moves and resyncs from
  snapshot on reconnect.
- `pane_agent_detected`: `pane_id`, `workspace_id`, `agent?` (the agent
  **kind string**, not AgentInfo), `released` (bool), `final_status?`
  (AgentStatus). This is the screen-detection signal; the agent kind may not
  be known yet, so `agent` is omitted when none was recognized. `final_status`
  is `Some` **only when `released` is true** (the agent already finished);
  a freshly-detected active agent carries `released: false` and no
  `final_status` — its status arrives in the following
  `pane_agent_status_changed` event, never in the detection itself. The
  detection carries no `:pane` and no `agent_status`; the cwd/terminal-title
  identity comes from the pane (a `pane_created`/`pane_updated` event or the
  snapshot), so a detection alone yields only a minimal cache entry
  (enriched by `pane_*` events and `agent.get`/`agent.start` results).
- `pane_agent_status_changed`: `pane_id`, `workspace_id`, `agent_status`,
  `agent?` (kind **string**), `title?`, `display_agent?`, `state_labels`.
  Note `agent` here is `Option<String>` (the kind), NOT an `AgentInfo` struct
  — a status event only PATCHES the already-cached agent's status/kind, it
  never carries a full agent to parse-and-replace (the agent was established
  by the snapshot or a prior detection/`pane_created`). The Phase 3 dashboard
  (`agent-fleet-dashboard.el`) drives its live refresh from this event via
  the `agent-fleet-agent-status-changed-hook` — no polling, no new wire
  protocol. The `AgentStatus` enum (above) is authoritative
  for the five rendered states.

## 8. Other Phase-1-relevant methods

The schema (`src/api/schema.rs`, surfaced via `herdr api schema`) defines the
full method catalog; only the methods the client actually issues are below.
Every success result is a `ResponseResult` tagged
`#[serde(tag="type", rename_all="snake_case")]`, so a result is always
`{"type":"<variant>",...fields}` — never a bare payload. The client unwraps
these envelopes tolerantly (`agent-fleet--unwrap-agent` for the `:agent`
envelope, `agent-fleet--unwrap-read` for `:read`).

- `events.wait` — `{"match_event":{"event":"<underscored>","workspace_id"?...},
  "timeout_ms":<int|null>}`. Blocks (one-shot connection) until a matching
  event arrives or timeout. An `events.wait` match against
  `pane_agent_status_changed` is the one server-side wait that targets a status
  transition (the `EventMatch.event` is the underscored global `EventKind`).

### 8.1 Phase 2 agent control methods

These are the RPCs the `agent-fleet.el` control layer (Phase 2) issues over
the Phase 1 client. `agent.*` methods take a **`target`** string — an agent
name *or* a pane id, resolved by the server. `pane.*` methods
require a real `pane_id`.

| Method | Request params | Result (`{type, ...}`) |
|---|---|---|
| `agent.start` | `{name, kind, pane_id, args?, timeout_ms?}` | `agent_started` → `{agent: AgentInfo, argv: [str]}` |
| `agent.prompt` | `{target, text}` | `agent_prompted` → `{agent: AgentInfo}` |
| `agent.prompt` (wait) | `{target, text, wait:{until, timeout_ms}}` | success: `agent_prompted` → `{agent: AgentInfo}`; failure: error `timeout`/`agent_prompt_stalled`/`agent_not_running` |
| `agent.wait` | `{target, until, timeout_ms}` | `agent_info` → `{agent: AgentInfo}` |
| `agent.read` | `{target, source, lines, format, strip_ansi}` | `pane_read` → `{read: PaneReadResult}` |
| `agent.send_keys` | `{target, keys:[...]}` | `ok` → `{}` |
| `agent.rename` | `{target, name}` | `agent_info` → `{agent: AgentInfo}` |
| `agent.focus` | `{target}` | `agent_info` → `{agent: AgentInfo}` |
| `agent.list` | `{}` | `agent_list` → `{agents: [AgentInfo]}` |
| `agent.get` | `{target}` | `agent_info` → `{agent: AgentInfo}` |

Notes on params:
- `agent.start` requires `name`, `kind`, and `pane_id`; `args` is an optional
  list of extra CLI arguments. `target` (for the other `agent.*` methods) is
  a name *or* pane id, resolved by the server.

Provisioning / teardown (used by `agent-fleet-start` / `-kill`):

| Method | Request params | Result (`{type, ...}`) |
|---|---|---|
| `workspace.create` | `{cwd?, focus?, label?, env?}` | `workspace_created` → `{workspace: WorkspaceInfo, tab: TabInfo, root_pane: PaneInfo}` |
| `pane.split` | `{workspace_id?, target_pane_id?, direction, ratio?, cwd?, focus?, right_click?, env?}` | `pane_info` → `{pane: PaneInfo}` |
| `tab.create` | `{workspace_id, cwd?}` | `tab_created` → `{tab: TabInfo, root_pane: PaneInfo}` |
| `pane.current` | `{}` | `pane_info` → `{pane: PaneInfo}` (focused pane) |
| `pane.close` | `{pane_id}` | `ok` → `{}` — also drives `pane_closed` removal + exited hook |

Notes:

- **`workspace.create` returns a ready root pane.** The client targets that
  pane directly for `agent.start`; creating another tab would leak an unused
  shell and was previously hidden by an unfaithful mock response.
- **`pane.split` has no `tab_id`.** The required field is `direction`
  (`"right"`\|`"down"`, a `SplitDirection` enum), not `split_direction`.
  `target_pane_id` selects the pane to split from (defaulting to the focused
  pane); `ratio`/`cwd` are optional; `focus` (bool) defaults false. The client
  reads the result's `:pane` for the new `pane_id`.
- **`tab.create` returns `root_pane`.** The result carries `:tab` (TabInfo)
  and `:root_pane` (a shell PaneInfo at the tab cwd); the client targets
  `root_pane.pane_id` for `agent.start` — no separate `pane.split`.

- **`wait` field** on `agent.prompt` makes submit+wait a single atomic RPC,
  avoiding the race where the agent finishes between a separate prompt and
  wait (§19). `until` is a JSON array of `AgentStatus` strings.
- **Interrupt** is `agent.send_keys` with `keys:["ctrl+c"]`, *not* a `cancel`
  method — different CLIs attach different semantics to Ctrl-C, so the key is
  exposed directly (§21).
- **Output is a read-snapshot.** `agent.read` returns a `PaneReadResult`
  (`{pane_id, workspace_id, tab_id, source, format, text, revision,
  truncated}`); it is never mirrored or persisted (§23/§46 — pane output may
  contain secrets). `agent-fleet-show-output-in-buffer` opens a fresh snapshot in a
  read-only buffer.
- **`strip_ansi` is a JSON boolean**, not a string. The Emacs client encodes
  `t`→`true` and `nil`/`:false`→`false` (via `(json-false :false)`).
- **`ReadSource`** enum (for `agent.read`/`pane.read`): `visible`, `recent`,
  `recent_unwrapped` (default — ignores soft wrapping, best for logs), `detection`.
- **`AgentStatus`** (the `until` array for `agent.wait`/`prompt` wait): the
  five statuses in §AgentStatus. `agent-fleet` maps them straight from Herdr
  with no client-side parsing (§12).

### 8.2 Phase 4 project integration (no new wire protocol)

`agent-fleet-project.el` (Phase 4, §69) is a **client-side** layer: it maps
agents to Emacs `project.el` projects by **canonical cwd** (`file-truename
(project-root …)`), not the workspace label (§32: "do not identify a project
from its label alone"). It
adds no protocol — it reuses the Phase 2 RPCs above:

- `agent-fleet-start-for-project` resolves `(project-current)`, then calls
  `workspace.create` (with `cwd=root`, already documented) when no existing
  workspace hosts the project, and targets its returned `root_pane` directly.
  When reusing an existing workspace it provisions via `pane.split {cwd?}`.
- `agent-fleet-project-agents` and the dashboard `P` filter match agents by
  the canonical root of their `cwd` (an `AgentInfo`/`PaneInfo` field), so
  multiple workspaces per repo (worktrees, §32) all resolve to one project.

`agent-fleet-start-for-project` also forwards `:worktree`/`:branch`/`:base`
(Phase 5, §8.3) so a project can start an agent in an isolated worktree.

### 8.3 Phase 5 worktree RPCs

`worktree.*` methods create/open/list/remove git worktrees — separate
checkouts of a repo — so multiple agents do not modify the same working
tree.  The client layer is `agent-fleet-worktree.el`
plus the `:worktree t` branch of `agent-fleet-start`.

| Method | Request params | Result |
|---|---|---|
| `worktree.create` | `{cwd, base?, branch?, focus?, label?, path?, workspace_id?}` | `(:type "worktree_created" :workspace <WorkspaceInfo> :tab <TabInfo> :root_pane <PaneInfo> :worktree <WorktreeInfo>)` |
| `worktree.open`   | same as create | same as create plus `:already_open` (bool) |
| `worktree.list`   | `{cwd?, workspace_id?}` | `(:type "worktree_list" :source <WorktreeSourceInfo> :worktrees [<WorktreeInfo>...])` |
| `worktree.remove` | `{workspace_id (required), force?}` | `(:type "worktree_removed" :path :workspace_id :forced)` |

Notes:

- **`worktree.create` auto-provisions the root pane.**  The result carries
  `:workspace`, `:tab`, and `:root_pane` (a shell at the worktree cwd), so
  `agent.start` targets `root_pane.pane_id` directly — no separate
  `pane.split`.  This is the `:worktree t` flow in
  `agent-fleet-start` → `agent-fleet--provision-worktree`.
- **`WorktreeInfo`** (keyed by `path`, the canonical id): `path, branch
  (str|null), is_bare, is_detached, is_prunable, is_linked_worktree, label,
  open_workspace_id (str|null)`.  `open_workspace_id` links a worktree to
  the workspace currently hosting it; the dashboard `w` action resolves an
  agent's worktree by matching its `workspace_id` against this field.
- **`WorktreeSourceInfo`** (from `worktree.list`'s `:source`): `repo_key,
  repo_name, repo_root, source_checkout_path, source_workspace_id?` — repo
  metadata shown read-only by the `w` status view.
- **The session snapshot has NO `:worktrees` key.**  Worktree state is
  populated only from `worktree.*` events (§7.2/§7.4) and the
  `worktree.list` RPC — never from `session.snapshot`.  The client upserts
  the worktree + workspace eagerly after `worktree.create`/`open` (closing
  the race before the pushed `worktree_created`/`opened` event lands), the
  same pattern used for agents after `agent.start`.
- **No polling (§25).**  `worktree.list` is called only on a user action
  (a command or the dashboard `w` key), never on a timer.

### 8.4 Phase 6 Magit integration (no new wire protocol)

`agent-fleet-magit.el` (Phase 6, §36/§71) adds **no RPC** — Magit status
and diff operate on the local filesystem (the agent's checkout), not over
the Herdr socket.  The git root is resolved client-side: by canonical cwd
(`agent-fleet-project-root-for-cwd`, §8.2) — which yields the *worktree*
root for a worktree agent (vc/project.el resolve per-worktree) and the main
repo root for a bare agent — with the cached worktree path
(`WorktreeInfo.path`, §8.3) as a fallback when the agent has no usable cwd
(§36 "open agent worktree in Magit").  `magit-status` / `magit-diff-working-tree`
are then called with that root as `default-directory`; cherry-pick, merge,
and worktree deletion are Magit's own keys inside the status buffer (§71:
"use Magit public API").  Magit is an optional dependency (§55): the entry
points `user-error` when it is absent; `herdr-doctor` reports availability.
The finished-worktree cleanup (`agent-fleet-worktree-cleanup`) reuses the
Phase 5 `worktree.remove` RPC (§8.3), filtered to `done` agents.

### 8.5 Phase 7 parallel orchestration (no new wire protocol)

`agent-fleet-parallel.el` (Phase 7, §37/§38/§72) adds **no RPC**.  It
composes the Phase 2/5 primitives to spawn N isolated worktree agents,
prompt each, and track their aggregate status — all client-side:

- Per spec `(kind . prompt)`: `worktree.create` (§8.3) → `agent.start`
  (§8.1, targeting the auto-provisioned root pane) → `agent.prompt`
  (§8.1, submit-ack only — no `wait` field).  Parallel execution is free:
  `agent.prompt` returns on the submit ack, so the N agents work
  concurrently after `agent-fleet-parallel` returns.
- **Aggregate status is client-side.**  The task's `running`/`blocked`/
  `done` state is computed live from the cache by mapping
  `agent-fleet-status` over the spawned pane-ids; the
  `pane_agent_status_changed` event (§7) drives it via the existing
  status-changed hook bus — no new event, no polling (§25).  It is **not a
  race** (§38): `done` only when *all* agents are done; a single
  `blocked` agent makes the task `blocked`; no agent is killed on first
  `done`.
- **No result extraction (§40).**  Agents are persistent interactive
  workers, not RPC functions — `agent.read` is terminal state, never a
  structured final answer.  `agent-fleet-task-wait` pumps
  `accept-process-output` (event-driven, like `agent-fleet-wait`) and
  returns STATUS only; `agent-fleet-task-cleanup` reuses the Phase 5
  `worktree.remove` RPC per agent.
- The **task is fleet-side metadata** (§41), not Herdr-cached: a registry
  of `agent-fleet-task` structs mapping pane-ids → task-ids, so the
  dashboard `T` filter and the Task column resolve without scanning.

### 8.6 Phase 8 interactive terminal (no new wire protocol)

`agent-fleet-attach.el` (Phase 8, §43/§44/§45/§73/§79) adds **no RPC**.
There is **no `agent.attach` socket method** (§43): attach is a client-side
PTY bridge, not socket I/O.  It spawns the `herdr agent attach <pane-id>`
CLI helper — which bridges a single live pane as an interactive PTY client
(§44 path A) — inside the optional Ghostel terminal backend:

```
Emacs Ghostel terminal backend
  ↓  PTY
herdr agent attach <pane-id>            ← CLI subprocess, not an RPC
  ↓  socket
Herdr server → one live agent pane
```

- **No socket involvement.**  The pane-id is resolved client-side
  (`agent-fleet--resolve-pane-id`, §8.1) from the cache; the attach CLI is a
  subprocess started with `ghostel-exec`.  The existing subscription/event
  bus is untouched.
- **The terminal backend is optional (§45).**
  `agent-fleet-attach-backend` (default `auto`) uses Ghostel when its dynamic
  module is ready. Otherwise path C applies: a `user-error` prints the command
  for the user to run in their own terminal. Eat and vterm are not current
  attach backends, and the core control plane works without Ghostel installed.
- **The §45.1 stale-module guard.**  ghostel's lisp can `require`
  successfully while its dynamic module fails to load (an older/broken
  on-disk module, or a missing libghostty-vt dependency).  `auto` checks
  `featurep 'ghostel-module` (the feature `module-load` sets only on a
  successful load), not just the `require`, so a ghostel whose module did
  not take falls back to the external command hint rather than calling a
  `ghostel-exec` that would fail.
- **Security (§46/§23, unchanged).**  Attach is user-initiated interactive
  viewing — the terminal buffer is **transient**, not persisted or
  continuously mirrored (the same boundary as the output view's
  read-snapshot).  Killing the process detaches and the agent is preserved
  (detach does **not** close the pane — §79).  No result extraction (§40):
  the buffer is a live terminal, never a structured answer.

## 9. Reconnect contract

- On subscription-socket close: mark `disconnected`, cancel no assumptions,
  schedule reconnect with backoff.
- On reconnect: `ping` (check protocol) → `session.snapshot` → **replace**
  local cache wholesale → re-`events.subscribe` with the recomputed
  subscription set.
- **Do not synthesize missed events client-side.** Snapshot is the canonical
  resync; any in-flight per-pane subscriptions are rebuilt from it. Herdr's
  own bounded buffered-event drain may follow the subscribe ack, and those
  frames are reconciled idempotently against the snapshot.
- **Workspace labels are derived, not stored.** The server computes a
  workspace's `label` live every frame (`display_name_from`:
  `custom_name` → basename of the first tab's root-pane cwd → `"workspace"`),
  and the client mirrors this: `herdr-workspace-label` derives the same value
  on read from the cached root-pane cwd (the pane with the smallest public
  pane number, `{ws}:p1`-style). Because the label is computed rather than
  cached as an overwriteable field, the server's buffered-event drain on
  `events.subscribe` (Herdr's `EventHub` is a 512-event ring buffer and
  `EventsSubscribeParams` carries no `from_sequence`, so each subscribe
  re-drains the buffer) cannot stale it: a buffered `workspace_created`/
  `workspace_updated` carrying a frozen `label` only refreshes the fallback
  `cached-label`, never the live value. Real cwd changes arrive as
  `pane_updated` (never a workspace event) and flow straight into the derived
  label with no resync needed. A `workspace_renamed` sets the `custom-name`,
  which wins over the cwd-derived name (matching the server).

## 10. Full RPC catalog (not yet implemented)

The methods below are available in the Herdr socket API
(<https://herdr.dev/docs/socket-api/>) but not currently issued by
agent-fleet. They are documented here as a reference for future
feature work — workspace/tab management, layout export/import, pane
navigation, notifications, plugins, and integrations. Parameter and
result field names follow the Herdr JSON wire convention
(`snake_case`); the Emacs client maps them to `:kebab-case` plists.

### 10.1 Workspace management

| Method | Params | Result |
|---|---|---|
| `workspace.list` | `{}` | list of `WorkspaceInfo` |
| `workspace.get` | `{workspace_id}` | `WorkspaceInfo` |
| `workspace.focus` | `{workspace_id}` | focused workspace info |
| `workspace.rename` | `{workspace_id, label}` | `WorkspaceInfo` |
| `workspace.move` | `{workspace_id, before_workspace_id?}` | reordered list |
| `workspace.move_block` | `{workspace_ids: [...], before_workspace_id?}` | authoritative ordered list (`workspace_ids` must be unique; the anchor cannot be part of the block) |
| `workspace.close` | `{workspace_id}` | closed ack |
| `workspace.report_metadata` | `{workspace_id, source, tokens, ttl_ms}` | metadata ack |

Notes:
- The session snapshot already carries all workspaces (`snapshot.workspaces`),
  so `workspace.list` is only needed for a live refresh without re-snapshotting.
- `workspace.move` / `workspace.move_block` reorder workspaces; the result is
  the authoritative ordered list (the server assigns `number` fields).
- `workspace.report_metadata` attaches display-only token metadata with a TTL;
  it does not change the workspace's identity or label.

### 10.2 Tab management

| Method | Params | Result |
|---|---|---|
| `tab.list` | `{}` | list of `TabInfo` |
| `tab.get` | `{tab_id}` | `TabInfo` |
| `tab.focus` | `{tab_id}` | focused tab info |
| `tab.rename` | `{tab_id, label}` | `TabInfo` |
| `tab.move` | `{tab_id, before_tab_id?}` | reordered list |
| `tab.close` | `{tab_id}` | closed ack |

Notes:
- The snapshot carries all tabs (`snapshot.tabs`); `tab.list` is a live
  refresh without re-snapshotting.
- `tab.create` is already used internally by `agent-fleet-start`
  (§8.1); `tab.close` would close a tab without killing the agent pane
  (unlike `pane.close`).

### 10.3 Pane management (beyond §8.1)

| Method | Params | Result |
|---|---|---|
| `pane.list` | `{}` | list of `PaneInfo` |
| `pane.get` | `{pane_id?}` | `PaneInfo` (defaults to focused pane) |
| `pane.rename` | `{pane_id, label}` | `PaneInfo` |
| `pane.close` | `{pane_id}` | `ok` |
| `pane.swap` | `{pane_id, direction}` or `{source_pane_id, target_pane_id}` | `pane_swap` (`changed`, `focused_pane_id`, `layout`, `reason?`) |
| `pane.move` | `{pane_id, destination, focus}` | `pane_move` (`changed`, previous ids, `pane`, layouts, `focused_pane_id`, `reason?`) |
| `pane.zoom` | `{pane_id?, mode: "toggle"\|"on"\|"off"}` | `pane_zoom` (`changed`, `zoom_changed`, `focus_changed`, `pane_id`, `zoomed`, `layout`, `reason?`) |
| `pane.resize` | `{pane_id, direction, amount}` | layout update |
| `pane.focus_direction` | `{direction}` | focused pane info |
| `pane.layout` | `{pane_id?}` | tab layout snapshot (`workspace_id`, `tab_id`, `zoomed`, `area`, `focused_pane_id`, pane/split rectangles) |
| `pane.process_info` | `{pane_id}` | shell PID, foreground PGID, process details (PID, name, argv, cwd) |
| `pane.neighbor` | `{pane_id, direction}` | adjacent pane info |
| `pane.edges` | `{pane_id}` | layout geometry |
| `pane.send_text` | `{pane_id, text}` | ack |
| `pane.send_input` | `{pane_id, ...}` | ack |
| `pane.input.set` | `{pane_id, right_click}` | ack |
| `pane.report_agent` | `{pane_id, source, agent, state, message}` | ack |
| `pane.report_agent_session` | `{pane_id, source, agent, agent_session_id}` | ack |
| `pane.report_metadata` | `{pane_id, title, display_agent, state_labels, tokens, ttl_ms, seq}` | ack |
| `pane.clear_agent_authority` | `{pane_id}` | ack |
| `pane.release_agent` | `{pane_id}` | ack |
| `pane.wait_for_output` | `{pane_id, ...}` | output match result |
| `pane.graphics.info` | `{}` | client display metrics + visibility |
| `pane.graphics.set` | `{pane_id, format, data_base64, placement}` | ack |
| `pane.graphics.clear` | `{pane_id}` | ack |
| `pane.graphics.stream` | `{pane_id, ...}` | ack |

Notes:
- `pane.send_text` / `pane.send_input` inject raw text/input; agent-fleet
  uses `agent.send_keys` instead (§8.1) which resolves a target by name or
  pane id.
- `pane.report_agent` / `pane.report_agent_session` / `pane.report_metadata`
  are for integration reporting (external tools pushing state into Herdr);
  agent-fleet does not push state, it only reads it.
- `pane.graphics.*` manages experimental image overlays on panes.

### 10.4 Layout management

| Method | Params | Result |
|---|---|---|
| `layout.export` | `{tab_id?, pane_id?}` | BSP tree (`workspace_id`, `tab_id`, `zoomed`, `focused_pane_id`, `root`) |
| `layout.apply` | `{workspace_id, tab_id?, tab_label, focus, root}` | creates a fresh tab |
| `layout.set_split_ratio` | `{tab_id, path, ratio}` | `layout_split_ratio_set` |

Notes:
- `layout.export` serializes a tab's pane tree into a portable BSP structure.
- `layout.apply` reconstructs a tab from a declarative tree (splits, panes with
  labels, cwd, commands, env vars).

### 10.5 Agent view and explain

| Method | Params | Result |
|---|---|---|
| `agent.view.set` | `{source, label, filter, sort}` | `agent_view` (`active`, `source`, `label?`) |
| `agent.view.clear` | `{source?}` | `agent_view` |
| `agent.explain` | `{target}` | detection rules, manifest source/version, matched rule, evidence, skip-state reason, idle fallback reason |

Notes:
- `agent.view.set` / `clear` configure Herdr's UI agent projections (filtering
  and sorting the sidebar). The `filter` uses operations like `any`/`eq`/`in`
  with fields and context values; `sort` specifies fields and asc/desc.
- `agent.explain` returns the detection rules and state evaluation for a
  specific agent, useful for debugging why an agent was or was not detected.

### 10.6 Server, client, notification

| Method | Params | Result |
|---|---|---|
| `server.stop` | `{}` | stopped |
| `server.reload_config` | `{}` | reloaded |
| `server.agent_manifests` | `{}` | `agent_manifest_status` (update diagnostics) |
| `server.reload_agent_manifests` | `{}` | `agent_manifest_reload` |
| `client.window_title.set` | `{title}` | `client_window_title` (`changed`, `reason`) |
| `client.window_title.clear` | `{}` | `client_window_title` |
| `notification.show` | `{title, body?, position?, sound?}` | `notification_show` (`shown`, `reason`) |

Notes:
- `notification.show` `sound` values: `none`, `done`, `request`. `position`
  and `sound` are optional. The `shown` boolean and `reason` (e.g.
  `shown`, `disabled`, `rate_limited`, `no_foreground_client`, `busy`)
  indicate whether the notification was actually displayed.
- `server.agent_manifests` / `server.reload_agent_manifests` manage the
  agent CLI manifest cache; `herdr-doctor` already reports manifest status
  via the `herdr.el` doctor layer (no direct RPC from agent-fleet).

### 10.7 Plugin and integration management

| Method | Params | Result |
|---|---|---|
| `plugin.link` | `{path, plugin_id, source}` | ack |
| `plugin.list` | `{}` | list of plugins |
| `plugin.unlink` | `{plugin_id}` | ack |
| `plugin.enable` | `{plugin_id}` | ack |
| `plugin.disable` | `{plugin_id}` | ack |
| `plugin.action.list` | `{plugin_id}` | list of actions |
| `plugin.action.invoke` | `{plugin_id, action_id, context}` | ack |
| `plugin.log.list` | `{plugin_id}` | list of logs |
| `plugin.pane.open` | `{plugin_id, entrypoint, placement}` | pane info |
| `plugin.pane.focus` | `{plugin_id}` | pane info |
| `plugin.pane.close` | `{plugin_id}` | ack |
| `integration.install` | `{...}` | ack |
| `integration.uninstall` | `{...}` | ack |

Notes:
- The plugin system allows external tools to register manifests, invoke
  actions, and manage plugin-owned terminal panes. agent-fleet does not
  currently interact with the plugin system.
