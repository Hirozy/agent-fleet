# Herdr Socket API Protocol Reference

Authoritative reference for the Herdr wire protocol, captured by reverse-engineering
a live **Herdr 0.8.0** (protocol **19**) server with the bundled schema
(`herdr api schema --json`, 9973 lines / 251 KB) and direct socket probes.

This document is the spec the Emacs client (`herdr-protocol.el`, `herdr-model.el`,
`herdr-events.el`, `herdr.el`) is built against. It is **runtime-verified**, not
assumed — but Herdr may change between versions, so the client must always:

- discover the socket and protocol version at runtime (`ping`, `herdr status`),
- tolerate unknown JSON fields (Herdr protocol clients are expected to be
  forward-compatible),
- treat `session.snapshot` as the canonical resync, never replay events.

---

## 1. Transport

- **Unix domain socket** (AF_UNIX), path `$HERDR_SOCKET_PATH` if set, else
  `~/.config/herdr/herdr.sock` (the path printed by `herdr status` under
  `server.socket`).
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
subscription : {"event":"<underscored-kind>","data":{"type":"<kind>",...payload}}  required: event, data
```

- `params` is always a JSON object; for parameter-less methods (`ping`,
  `session.snapshot`, `server.*` with `EmptyParams`) it is `{}` (empty object),
  **not** `null`.
- Pushed subscription messages have **no `id`** — they are not correlated to a
  request. Route them by the `event` field.
- The pushed `event` field equals `data.type` (both the underscored event kind,
  e.g. `"workspace_focused"`).

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
  {"type":"pong","version":"0.8.0","protocol":19,
   "capabilities":{"live_handoff":true,"detached_server_daemon":true}}
  ```
- `protocol` (int) is the authoritative protocol version; compare against
  `herdr-required-protocol-version`. `capabilities` is a map of bools —
  tolerate unknown keys.

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
workspace_id, label (str|null), number (int), focused (bool),
active_tab_id (str|null), tab_count (int), pane_count (int),
agent_status (str: idle|working|blocked|done|unknown)
```

### TabInfo
```
tab_id, workspace_id, label (str|null), number (int), focused (bool),
pane_count (int), agent_status (str)
```

### PaneInfo
```
pane_id, workspace_id, tab_id, terminal_id, terminal_title,
terminal_title_stripped, cwd, foreground_cwd (str),
focused (bool), revision (int),
scroll: { offset_from_bottom (int), max_offset_from_bottom (int), viewport_rows (int) } | null,
agent (str: "claude"|"codex"|"pi"|...)|null,
agent_status (str)|null,
agent_session: { agent, kind: "id"|"path", source, value } | null
```

### AgentInfo
Superset of PaneInfo plus `state_change_seq` (int). An "agent" in the snapshot
is identified by `pane_id` and `agent` (kind). The snapshot does **not** carry a
live agent `name`; the named-agent concept (regex `[a-z][a-z0-9_-]{0,31}`,
unique across live agents) applies to agents created via `agent.start`, which
takes `name`/`kind`/`pane_id`/`args`. Phase 1 keys agents by `pane_id`; the
optional `name` slot is populated in Phase 2.

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

### 7.3 Pushed event `data.type` values (underscored), 25 total

```
workspace_created workspace_updated workspace_metadata_updated workspace_closed
workspace_renamed workspace_moved workspace_reordered workspace_focused
worktree_created worktree_opened worktree_removed
tab_created tab_closed tab_renamed tab_moved tab_focused
pane_created pane_closed pane_updated pane_focused pane_moved pane_exited
pane_output_changed pane_agent_detected pane_agent_status_changed pane_scroll_changed
layout_updated
```

**Dotted subscription ↔ underscored event mapping is just `.` → `_`.**
The schema's `Subscription.type` uses dotted form; the pushed `event`/`data.type`
and the `events.wait` `EventMatch.event` use underscored form. Note one naming
quirk: subscribing `pane.output_matched` yields pushed events of kind
`pane_output_changed`.

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
- `pane_agent_detected`: `pane_id`, `agent` (AgentInfo), `final_status`,
  `released`, `workspace_id`.
- `pane_agent_status_changed`: `pane_id`, `agent` (AgentInfo), `agent_status`,
  `display_agent`, `title`, `state_labels`, `workspace_id`.

## 8. Other Phase-1-relevant methods (full catalog: 90 methods)

- `events.wait` — `{"match_event":{"event":"<underscored>","workspace_id"?...},
  "timeout_ms":<int|null>}`. Blocks (one-shot connection) until a matching
  event arrives or timeout. Useful for prompt-and-wait semantics (Phase 2).
- Agent control (Phase 2): `agent.list`, `agent.get`, `agent.start`
  `{name,kind,pane_id,args?,timeout_ms?}`, `agent.prompt` `{target,text,wait?}`,
  `agent.wait` `{target,until,timeout_ms?}`, `agent.read`
  `{target,source,lines?,format?,strip_ansi?}`, `agent.send_keys`
  `{target,keys}`, `agent.rename`, `agent.focus`, `agent.explain`.
- `agent` `target` is a string (agent name or pane id, server-resolved).
- `ReadSource` enum (for `agent.read`/`pane.read`): `visible`, `recent`,
  `recent-unwrapped`, `detection`.
- `AgentStatus` (the `until` array for `agent.wait`): the five statuses above.

## 9. Reconnect contract

- On subscription-socket close: mark `disconnected`, cancel no assumptions,
  schedule reconnect with backoff.
- On reconnect: `ping` (check protocol) → `session.snapshot` → **replace**
  local cache wholesale → re-`events.subscribe` with the recomputed
  subscription set.
- **Do not replay missed events.** Snapshot is the canonical resync; any
  in-flight per-pane subscriptions are rebuilt from the fresh snapshot.
