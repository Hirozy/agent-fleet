# Agent Fleet Roadmap

Status: planning guidance; not automatic authorization to implement.

This document records possible implementation and optimization directions for
Agent Fleet. Before starting any item, confirm the scope against the latest
user request, code, and tests. Long-lived execution rules live in `AGENTS.md`,
current user-visible behavior lives in `README.md`, and the verified Herdr
interface lives in `docs/PROTOCOL.md`.

## Product position

Agent Fleet brings Herdr-managed coding agents into Emacs. Herdr owns agent
processes, real PTYs, and lifecycle state. Agent Fleet provides the Emacs
surface for control, inspection, contextual handoff, attention management, and
code review.

The most valuable work shortens this loop:

```text
current code context
  -> find or start an agent
  -> send a task
  -> receive blocked/done attention
  -> inspect output or attach
  -> review changes
  -> continue prompting or clean up the worktree
```

Features that shorten this loop fit the product. General management of Herdr
Sessions, Workspaces, tabs, panes, and layouts does not belong to Agent Fleet's
default expansion path.

## Priority overview

| Priority | Direction | Primary value |
|---|---|---|
| P0 | Default Session configuration and attach endpoint pinning | Prevent control RPCs and attach from reaching different Sessions |
| P0 | Consistent Project semantics and same-Project agents | Align display, filtering, queries, and discovery |
| P1 | Prompts from Emacs context | Hand work off directly from a file, region, or diagnostic |
| P1 | Attention workflow | Handle blocked and done agents faster |
| P1 | Review of committed changes | Review agent commits after the working tree becomes clean |
| P1 | Parallel-task recovery | Preserve Fleet-side task grouping across Emacs restarts |
| P2 | Shared action and view models | Eliminate drift across dashboard, list, attach, and completion UIs |
| P2 | Diagnostics, release, and compatibility work | Improve explainability and cross-version reliability |

## P0: complete the agreed product scope

### Default Session name

Allow users to configure the Herdr Session used by the next connection without
adding a Session management interface:

- add `herdr-default-session-name`, defaulting to nil;
- keep an explicit `herdr-socket-path` at the highest precedence;
- require a Session name to be a safe, single path component;
- do not let a configuration change affect an existing connection; reconnect
  must continue using the endpoint saved on that connection;
- do not add runtime Session switching, enumeration, multi-Session caches, or
  server lifecycle commands;
- do not make automatic connection start Herdr; report a missing Session with
  a clear diagnostic and CLI hint.

Every CLI subprocess that connects to Herdr must be pinned to the control
connection's socket. Ghostel attach should set `HERDR_SOCKET_PATH` through a
subprocess-local `process-environment`, never the global Emacs environment. The
external fallback command must show the same endpoint.

See `SESSION_PROJECT_AGENTS_DESIGN.md` for the detailed interface proposal.

### Project semantics and same-Project agents

Project is a logical codebase identity derived from agent cwd, not a Herdr
Workspace:

- map Git linked worktrees to the same canonical Project;
- use one identity rule for the Project column, dashboard `P`, and
  `agent-fleet-project-agents`;
- show `—` when no Project can be resolved instead of presenting a cwd basename
  as a Project;
- provide a discoverable same-Project agent view that reuses the existing query
  and list renderer;
- do not add a Workspace filter or Workspace-peers concept.

## P1: strengthen the in-Emacs agent workflow

### `agent-fleet-prompt-dwim`

Build a lightweight task reference from the current Emacs context:

- current file path;
- line range of the active region;
- symbol near point;
- optionally, the selected text;
- by default, prefer an agent in the same Project.

Prefer paths and line numbers so the agent reads files from its working
directory. Do not copy an entire buffer by default, do not save user files
automatically, and require confirmation or a size limit for a large region.

### Attention workflow

Shorten the path from a status event to a user action:

- add `agent-fleet-next-needs-attention` to locate the next blocked agent;
- where the platform supports it, add notification actions that open output,
  attach, or the dashboard at the relevant agent;
- show disconnected, reconnecting, or potentially stale state explicitly in
  the dashboard;
- keep connection-state propagation hook/event-driven without polling timers.

### Review of committed changes

The existing working-tree diff covers only uncommitted changes. Add separately
named review commands that ask Magit to compare the agent branch with its base
or merge base:

- `agent-fleet-magit-review-in-buffer`;
- `agent-fleet-magit-review-in-child-frame`.

Keep the existing `agent-fleet-magit-diff-*` commands scoped to working-tree
changes. A parallel task may record its base commit OID at creation so review
remains stable after an agent commits. Do not implement a replacement Git diff
UI.

### Parallel-task recovery

The Agent Fleet task registry is client-side grouping metadata. Persist only
the minimum useful set:

- task ID and title;
- pane IDs;
- worktree Workspace IDs;
- base revision;
- start and finish timestamps.

Reconcile this metadata with the Herdr cache after reconnect. Agent state must
remain derived from the live Herdr model; persisted task data must never become
a second source of lifecycle truth.

## P2: converge internal extension interfaces

### Shared agent presentation descriptor

Define UI-independent presentation data such as:

```text
pane-id / name / project / kind / status / task
```

The dashboard, quick list, same-Project list, minibuffer completion, and
optional Consult integration should consume the same descriptor. This avoids
one UI using Project while another leaks Workspace as the user-facing group.

### Shared action registry and completion API

- converge common dashboard, attach-transient, and completion actions into
  stable action metadata while preserving context-specific presentation;
- provide a public completion table/category and annotation or affixation data;
- make optional Consult and Embark integrations use public APIs instead of
  advising a private reader;
- keep Consult, Embark, Magit, and Ghostel optional.

### Agent explanation and details

When the runtime Herdr protocol supports `agent.explain`, an agent-centric
diagnostic command may show detection evidence, manifest data, state reasons,
cwd, Project, worktree, and agent-session identity. It should explain an agent,
not grow into a Workspace or server management interface.

### Release and compatibility

- run compile and ERT matrices on the minimum supported Emacs 29.1 and the
  current Emacs release;
- make graphical child-frame smoke tests a repeatable release check;
- provide a separate CI job for optional Consult tests;
- verify that core loads without Magit, Ghostel, or graphical APIs;
- align package versions, autoloads, obsolete aliases, and documentation at
  release time.

## Explicit non-goals

Unless the user makes a new product decision, do not implement:

- Session enumeration, runtime switching, or simultaneous multi-Session
  connections;
- Workspace CRUD, browsers, or filters;
- general tab, pane, or layout management UI;
- continuous terminal-output mirroring or agent-state inference from terminal
  text;
- replacements for Magit, Ghostel, or Herdr;
- Herdr plugin, integration, or server lifecycle management UI.

## Suggested implementation order

1. Default Session configuration and attach endpoint pinning.
2. Consistent Project semantics and a same-Project agent entry point.
3. `agent-fleet-prompt-dwim` and the attention workflow.
4. Review of committed changes.
5. Parallel-task recovery.
6. Shared action/view models, completion APIs, and release engineering.
