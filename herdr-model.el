;;; herdr-model.el --- Local cache and data model for Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, terminals
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Local in-memory cache of the Herdr runtime state.  Herdr is the
;; source of truth; this is just a local projection that the rest of
;; the package reads and that events update incrementally.
;;
;; The cache is bootstrapped from `session.snapshot' and then kept in
;; step by `herdr-model-apply-event', which reconciles one pushed event
;; against the cache.  On reconnect the cache is replaced wholesale by a
;; fresh snapshot (see `herdr.el').  The client does not replay missed events;
;; server-buffered events delivered after subscribing are handled idempotently.
;;
;; All parsing is tolerant: unknown fields in the Herdr JSON are ignored,
;; so the client survives forward-compatible protocol changes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)


;;; --- Data structures -----------------------------------------------

;; Structs mirror the snapshot entry shapes documented in
;; docs/PROTOCOL.md.  Slot names use lisp-case; the parser maps the
;; snake_case JSON fields onto them.

(cl-defstruct herdr-session
  "Local projection of a Herdr session.
WORKSPACES, TABS, PANES, AGENTS and WORKTREES are hash tables keyed by id
(string).  Agents are keyed by `pane-id' (the snapshot does not
carry a stable agent `name'; see docs/PROTOCOL.md §6).  Worktrees are keyed
by `path' (the snapshot carries no worktree collection; worktree state is
populated from `worktree.list' and `worktree.*' events, PROTOCOL.md §10).
GONE-PANES is a hash table of pane ids the server no longer reports
(populated by `pane.list' reconciliation); Herdr never recycles a pane id,
so a `pane_created' replayed from the EventHub ring buffer for one of them
is a stale replay and is ignored (see `herdr-model-apply-event')."
  protocol version
  focused-workspace-id focused-tab-id focused-pane-id
  workspaces tabs panes agents worktrees    ; hash-tables string -> struct
  gone-panes)                               ; hash-table pane-id -> t (never recycled)

(cl-defstruct herdr-workspace
  "A Herdr workspace.
CACHED-LABEL is the last fresh `WorkspaceInfo.label' received (snapshot
or a non-replayed workspace event) and is a FALLBACK only — the live
display name is `herdr-workspace-label', computed like Herdr's TUI from
the root-pane cwd.  CUSTOM-NAME is a user-set name captured from
`workspace_renamed' (and from a snapshot mismatch, see
`herdr-model-parse-snapshot'); when set it wins over the cwd-derived
name, matching the server's `display_name_from'."
  id cached-label custom-name number focused active-tab-id
  tab-count pane-count agent-status)

(cl-defstruct herdr-tab
  "A Herdr tab within a workspace."
  id workspace-id label number focused pane-count agent-status)

(cl-defstruct herdr-pane
  "A terminal pane.  AGENT is the agent kind string or nil."
  id workspace-id tab-id terminal-id
  terminal-title terminal-title-stripped
  cwd foreground-cwd
  focused revision scroll
  agent agent-status agent-session)

(cl-defstruct herdr-agent
  "An agent-bearing pane (a superset of `herdr-pane' plus
`state-change-seq' and agent-identity fields).
The `id' slot holds the pane id (agents are keyed by pane-id in the
cache).  `name' is the human label assigned by `agent.start' /
`agent.rename'; it is unique across live agents but may be nil for
agents started outside this client (see docs/PROTOCOL.md §6)."
  id workspace-id tab-id terminal-id
  terminal-title terminal-title-stripped
  cwd foreground-cwd
  focused revision state-change-seq scroll
  agent agent-status agent-session
  name display-agent title
  interactive-ready launch-pending
  state-labels tokens)

(cl-defstruct herdr-agent-session
  "Native agent session identity reported by an integration."
  agent kind source value)

(cl-defstruct herdr-worktree
  "A Herdr git worktree (a separate checkout of a repo).
Keyed by `path' (the canonical id; `WorktreeInfo.path').  OPEN-WORKSPACE-ID
links a worktree to the workspace currently hosting it (nil when the
worktree exists but no workspace is open for it).  The snapshot carries no
worktree collection, so this struct is populated only from `worktree.list'
and `worktree.created'/`opened' events."
  path branch is-bare is-detached is-prunable
  is-linked-worktree label open-workspace-id)


;;; --- Cache singleton ----------------------------------------------

(defvar herdr-model--cache nil
  "The current `herdr-session', or nil when disconnected.")

(defun herdr-model-cache ()
  "Return the current cached Herdr session, or nil."
  herdr-model--cache)

(defun herdr-model-set-cache (session)
  "Install SESSION as the current cache."
  (setq herdr-model--cache session))

(defun herdr-model-clear-cache ()
  "Drop the current cache (used on disconnect)."
  (setq herdr-model--cache nil))

(defun herdr-model--empty-session ()
  "Return a fresh empty `herdr-session'."
  (make-herdr-session
   :workspaces (make-hash-table :test 'equal)
   :tabs (make-hash-table :test 'equal)
   :panes (make-hash-table :test 'equal)
   :agents (make-hash-table :test 'equal)
   :worktrees (make-hash-table :test 'equal)
   :gone-panes (make-hash-table :test 'equal)))

(defun herdr-model--hash-values (table)
  "Return the values of hash TABLE as a list."
  (let (vals)
    (maphash (lambda (_k v) (push v vals)) table)
    (nreverse vals)))


;;; --- Snapshot parsing ---------------------------------------------

(defun herdr-model-parse-snapshot (result)
  "Build a `herdr-session' from a snapshot RESULT plist.
RESULT is the decoded `result' field of a session.snapshot response,
i.e. a plist with a `:snapshot' key.  Unknown fields are ignored."
  (let* ((snap (or (plist-get result :snapshot) result))
         (session (herdr-model--empty-session)))
    (unless (and (listp snap)
                 (cl-every (lambda (key) (plist-member snap key))
                           '(:workspaces :tabs :panes :agents)))
      (signal 'herdr-protocol-error
              (list :reason 'malformed-snapshot :result result)))
    (setf (herdr-session-protocol session)
          (plist-get snap :protocol))
    (setf (herdr-session-version session)
          (plist-get snap :version))
    (setf (herdr-session-focused-workspace-id session)
          (plist-get snap :focused_workspace_id))
    (setf (herdr-session-focused-tab-id session)
          (plist-get snap :focused_tab_id))
    (setf (herdr-session-focused-pane-id session)
          (plist-get snap :focused_pane_id))
    (dolist (w (plist-get snap :workspaces))
      (when-let* ((id (plist-get w :workspace_id)))
        (puthash id (herdr-model--parse-workspace w)
                 (herdr-session-workspaces session))))
    (dolist (tb (plist-get snap :tabs))
      (when-let* ((id (plist-get tb :tab_id)))
        (puthash id (herdr-model--parse-tab tb)
                 (herdr-session-tabs session))))
    (dolist (pn (plist-get snap :panes))
      (when-let* ((id (plist-get pn :pane_id)))
        (puthash id (herdr-model--parse-pane pn)
                 (herdr-session-panes session))))
    (dolist (ag (plist-get snap :agents))
      (when-let* ((id (plist-get ag :pane_id)))
        (puthash id (herdr-model--parse-agent ag)
                 (herdr-session-agents session))))
    ;; Post-pass (panes are now parsed): capture pre-connect renames.
    ;; At snapshot time both the wire label and the cwd-derived auto
    ;; label are "current", so a workspace whose cached-label differs
    ;; from its auto label MUST have a custom name (the server's
    ;; `display_name_from' returns custom_name verbatim).  Freeze it as
    ;; `custom-name' so later root-pane cwd changes recompute `auto'
    ;; without wrongly overriding the custom name.  No rename event will
    ;; arrive for a pre-connect rename, so this is the only chance to
    ;; learn it.
    (dolist (ws (herdr-model--hash-values (herdr-session-workspaces session)))
      (let ((cached (herdr-workspace-cached-label ws))
            (auto (herdr-model--workspace-auto-label ws session)))
        (when (and (stringp cached) (not (string-empty-p cached))
                   auto (not (equal cached auto)))
          (setf (herdr-workspace-custom-name ws) cached))))
    session))

(defun herdr-model--parse-workspace (w)
  "Parse a workspace plist W (a WorkspaceInfo) into a struct.
Stores the wire `label' as CACHED-LABEL (a fallback); the live name is
derived in `herdr-workspace-label'.  CUSTOM-NAME is left nil here and
resolved by `herdr-model-parse-snapshot' (snapshot mismatch) or by a
later `workspace_renamed' event."
  (make-herdr-workspace
   :id (plist-get w :workspace_id)
   :cached-label (plist-get w :label)
   :number (plist-get w :number)
   :focused (herdr-model--bool (plist-get w :focused))
   :active-tab-id (plist-get w :active_tab_id)
   :tab-count (plist-get w :tab_count)
   :pane-count (plist-get w :pane_count)
   :agent-status (plist-get w :agent_status)))

(defun herdr-model--parse-worktree (wt)
  "Parse a worktree plist WT (a WorktreeInfo) into a struct.
PATH is the canonical key.  BRANCH is nil for a detached worktree."
  (make-herdr-worktree
   :path (plist-get wt :path)
   :branch (plist-get wt :branch)
   :is-bare (herdr-model--bool (plist-get wt :is_bare))
   :is-detached (herdr-model--bool (plist-get wt :is_detached))
   :is-prunable (herdr-model--bool (plist-get wt :is_prunable))
   :is-linked-worktree (herdr-model--bool (plist-get wt :is_linked_worktree))
   :label (plist-get wt :label)
   :open-workspace-id (plist-get wt :open_workspace_id)))

(defun herdr-model--parse-tab (tb)
  "Parse a tab plist TB (a TabInfo) into a struct."
  (make-herdr-tab
   :id (plist-get tb :tab_id)
   :workspace-id (plist-get tb :workspace_id)
   :label (plist-get tb :label)
   :number (plist-get tb :number)
   :focused (herdr-model--bool (plist-get tb :focused))
   :pane-count (plist-get tb :pane_count)
   :agent-status (plist-get tb :agent_status)))

(defun herdr-model--parse-pane (pn)
  "Parse a pane plist PN (a PaneInfo) into a struct."
  (make-herdr-pane
   :id (plist-get pn :pane_id)
   :workspace-id (plist-get pn :workspace_id)
   :tab-id (plist-get pn :tab_id)
   :terminal-id (plist-get pn :terminal_id)
   :terminal-title (plist-get pn :terminal_title)
   :terminal-title-stripped (plist-get pn :terminal_title_stripped)
   :cwd (plist-get pn :cwd)
   :foreground-cwd (plist-get pn :foreground_cwd)
   :focused (herdr-model--bool (plist-get pn :focused))
   :revision (plist-get pn :revision)
   :scroll (plist-get pn :scroll)
   :agent (plist-get pn :agent)
   :agent-status (plist-get pn :agent_status)
   :agent-session (herdr-model--parse-agent-session
                   (plist-get pn :agent_session))))

(defun herdr-model--parse-agent (ag)
  "Parse an agent plist AG (an AgentInfo) into a struct."
  (make-herdr-agent
   :id (plist-get ag :pane_id)
   :workspace-id (plist-get ag :workspace_id)
   :tab-id (plist-get ag :tab_id)
   :terminal-id (plist-get ag :terminal_id)
   :terminal-title (plist-get ag :terminal_title)
   :terminal-title-stripped (plist-get ag :terminal_title_stripped)
   :cwd (plist-get ag :cwd)
   :foreground-cwd (plist-get ag :foreground_cwd)
   :focused (herdr-model--bool (plist-get ag :focused))
   :revision (plist-get ag :revision)
   :state-change-seq (plist-get ag :state_change_seq)
   :scroll (plist-get ag :scroll)
   :agent (plist-get ag :agent)
   :agent-status (plist-get ag :agent_status)
   :agent-session (herdr-model--parse-agent-session
                   (plist-get ag :agent_session))
   :name (plist-get ag :name)
   :display-agent (plist-get ag :display_agent)
   :title (plist-get ag :title)
   :interactive-ready (herdr-model--bool (plist-get ag :interactive_ready))
   :launch-pending (herdr-model--bool (plist-get ag :launch_pending))
   :state-labels (plist-get ag :state_labels)
   :tokens (plist-get ag :tokens)))

(defun herdr-model--parse-agent-session (s)
  "Parse an agent-session plist S, or return nil."
  (when s
    (make-herdr-agent-session
     :agent (plist-get s :agent)
     :kind (plist-get s :kind)
     :source (plist-get s :source)
     :value (plist-get s :value))))

(defun herdr-model--bool (v)
  "Normalize a JSON boolean V (which may be :false) to t/nil."
  (cond
   ((eq v :false) nil)
   ((null v) nil)
   (t t)))


;;; --- Event reconciliation -----------------------------------------

;; Each handler mutates the session's hash tables in place and returns a
;; descriptor plist describing what changed, for the local event bus.
;; The descriptor shape is (:event KIND :what SYMBOL :id ID :status
;; STATUS-OR-NIL).  Unknown event kinds return a no-op descriptor so the
;; bus can still route them to a catch-all hook.

(defun herdr-model--remove-pane-cascade (session pane-id)
  "Remove PANE-ID and its agent from SESSION and remember it as gone."
  (when pane-id
    (remhash pane-id (herdr-session-panes session))
    (remhash pane-id (herdr-session-agents session))
    (puthash pane-id t (herdr-session-gone-panes session))
    (when (equal pane-id (herdr-session-focused-pane-id session))
      (setf (herdr-session-focused-pane-id session) nil))))

(defun herdr-model--remove-tab-cascade (session tab-id)
  "Remove TAB-ID and every child pane/agent from SESSION."
  (let (pane-ids)
    (maphash (lambda (pane-id pane)
               (when (equal tab-id (herdr-pane-tab-id pane))
                 (push pane-id pane-ids)))
             (herdr-session-panes session))
    ;; Also cover a partial cache containing AgentInfo but no PaneInfo.
    (maphash (lambda (pane-id agent)
               (when (equal tab-id (herdr-agent-tab-id agent))
                 (cl-pushnew pane-id pane-ids :test #'equal)))
             (herdr-session-agents session))
    (dolist (pane-id pane-ids)
      (herdr-model--remove-pane-cascade session pane-id)))
  (remhash tab-id (herdr-session-tabs session))
  (when (equal tab-id (herdr-session-focused-tab-id session))
    (setf (herdr-session-focused-tab-id session) nil))
  (maphash (lambda (_id workspace)
             (when (equal tab-id (herdr-workspace-active-tab-id workspace))
               (setf (herdr-workspace-active-tab-id workspace) nil)))
           (herdr-session-workspaces session)))

(defun herdr-model--remove-workspace-cascade (session workspace-id)
  "Remove WORKSPACE-ID and all descendant tabs/panes/agents from SESSION."
  (let (tab-ids pane-ids)
    (maphash (lambda (tab-id tab)
               (when (equal workspace-id (herdr-tab-workspace-id tab))
                 (push tab-id tab-ids)))
             (herdr-session-tabs session))
    (dolist (tab-id tab-ids)
      (herdr-model--remove-tab-cascade session tab-id))
    ;; Partial event streams can contain panes whose tab was never cached.
    (maphash (lambda (pane-id pane)
               (when (equal workspace-id (herdr-pane-workspace-id pane))
                 (push pane-id pane-ids)))
             (herdr-session-panes session))
    (maphash (lambda (pane-id agent)
               (when (equal workspace-id (herdr-agent-workspace-id agent))
                 (cl-pushnew pane-id pane-ids :test #'equal)))
             (herdr-session-agents session))
    (dolist (pane-id pane-ids)
      (herdr-model--remove-pane-cascade session pane-id)))
  (remhash workspace-id (herdr-session-workspaces session))
  (when (equal workspace-id (herdr-session-focused-workspace-id session))
    (setf (herdr-session-focused-workspace-id session) nil)))

(defun herdr-model--focus-workspace (session workspace-id)
  "Make WORKSPACE-ID the sole focused workspace in SESSION."
  (setf (herdr-session-focused-workspace-id session) workspace-id)
  (maphash (lambda (id workspace)
             (setf (herdr-workspace-focused workspace)
                   (equal id workspace-id)))
           (herdr-session-workspaces session)))

(defun herdr-model--focus-tab (session tab-id workspace-id)
  "Make TAB-ID the sole focused tab and update its WORKSPACE-ID."
  (setf (herdr-session-focused-tab-id session) tab-id)
  (maphash (lambda (id tab)
             (setf (herdr-tab-focused tab) (equal id tab-id)))
           (herdr-session-tabs session))
  (when workspace-id
    (herdr-model--focus-workspace session workspace-id)
    (when-let* ((workspace (herdr-model-find-workspace session workspace-id)))
      (setf (herdr-workspace-active-tab-id workspace) tab-id))))

(defun herdr-model--focus-pane (session pane-id workspace-id)
  "Make PANE-ID the sole focused pane, deriving its tab when cached."
  (setf (herdr-session-focused-pane-id session) pane-id)
  (maphash (lambda (id pane)
             (setf (herdr-pane-focused pane) (equal id pane-id)))
           (herdr-session-panes session))
  (maphash (lambda (id agent)
             (setf (herdr-agent-focused agent) (equal id pane-id)))
           (herdr-session-agents session))
  (let ((pane (herdr-model-find-pane session pane-id)))
    (if (and pane (herdr-pane-tab-id pane))
        (herdr-model--focus-tab session (herdr-pane-tab-id pane)
                                (or workspace-id
                                    (herdr-pane-workspace-id pane)))
      (when workspace-id
        (herdr-model--focus-workspace session workspace-id)))))

(defun herdr-model-apply-event (session kind data)
  "Reconcile one pushed event against SESSION (mutated in place).
KIND is the underscored event type (e.g. \"pane_agent_status_changed\").
DATA is the decoded event payload plist.  Returns a descriptor plist
\(:event KIND :what CHANGE-KEYWORD :id ENTITY-ID :status STATUS)."
  (pcase kind
    ;; --- workspaces ---
    ("workspace_created"
     (let ((w (plist-get data :workspace)))
       ;; A creation event for a workspace already cached (from the
       ;; snapshot) is a connect-time replay (the EventHub ring buffer
       ;; is drained on every subscribe; see docs/PROTOCOL.md §9).
       ;; Skipping it avoids replacing the snapshot-correct struct with
       ;; a replayed one; a genuinely new workspace is still inserted.
       ;; (Labels are derived in `herdr-workspace-label', so a replayed
       ;; label cannot stale the display name regardless; the skip is
       ;; belt-and-suspenders plus it avoids needless struct churn.)
       (herdr-model--upsert-workspace session w t)
       `(:event ,kind :what :workspace-updated
         :id ,(plist-get w :workspace_id))))
    ((or "workspace_updated" "workspace_metadata_updated")
     (let ((w (plist-get data :workspace)))
       (herdr-model--upsert-workspace session w)
       `(:event ,kind :what :workspace-updated
         :id ,(plist-get w :workspace_id))))
    ("workspace_renamed"
     (let* ((wid (plist-get data :workspace_id))
            (w (herdr-model-find-workspace session wid)))
       ;; A rename is the sole unambiguous custom-name source after
       ;; connect: store it as `custom-name', which `herdr-workspace-label'
       ;; prefers over the cwd-derived name (mirrors the server's
       ;; `display_name_from', which returns custom_name verbatim).
       (when w
         (setf (herdr-workspace-custom-name w) (plist-get data :label)))
       `(:event ,kind :what :workspace-updated :id ,wid)))
    ("workspace_closed"
     (let* ((wid (or (plist-get data :workspace_id)
                     (plist-get (plist-get data :workspace) :workspace_id)))
            (closed-agents
             (cl-remove-if-not
              (lambda (agent)
                (equal wid (herdr-agent-workspace-id agent)))
              (herdr-model--hash-values (herdr-session-agents session))))
            (changed
             (or (herdr-model-find-workspace session wid)
                 closed-agents
                 (cl-some (lambda (tab)
                            (equal wid (herdr-tab-workspace-id tab)))
                          (herdr-model--hash-values
                           (herdr-session-tabs session)))
                 (cl-some (lambda (pane)
                            (equal wid (herdr-pane-workspace-id pane)))
                          (herdr-model--hash-values
                           (herdr-session-panes session))))))
       (herdr-model--remove-workspace-cascade session wid)
       `(:event ,kind :what :workspace-closed :id ,wid
         :closed-agents ,closed-agents :replayp ,(not changed))))
    ("workspace_focused"
     (let ((wid (plist-get data :workspace_id)))
       (herdr-model--focus-workspace session wid)
       `(:event ,kind :what :workspace-focused :id ,wid)))
    ((or "workspace_moved" "workspace_reordered")
     (dolist (workspace (append (plist-get data :workspaces) nil))
       (herdr-model--upsert-workspace session workspace))
     `(:event ,kind :what :workspace-reordered
       :id ,(or (plist-get data :workspace_id)
                (car (append (plist-get data :workspace_ids) nil)))))
    ;; --- worktrees (Phase 5) ---
    ;; The snapshot carries no worktree collection, so the cache is seeded
    ;; by these events and by `worktree.list'.  `worktree_created'/`opened'
    ;; carry a full `:worktree' (WorktreeInfo) and `:workspace' (WorkspaceInfo);
    ;; `worktree_removed' carries `:workspace_id' + `:worktree' + `:forced'
    ;; (`:workspace' may be null).  A create/open also upserts the workspace
    ;; (the server opens a new workspace for the worktree) so the cache gains
    ;; it without waiting for a separate workspace event.
    ((or "worktree_created" "worktree_opened")
     (let* ((wt (plist-get data :worktree))
            (path (plist-get wt :path)))
       (herdr-model--upsert-worktree session wt)
       (when-let* ((ws (plist-get data :workspace)))
         (herdr-model--upsert-workspace session ws))
       `(:event ,kind
         :what ,(if (equal kind "worktree_created")
                    :worktree-created :worktree-opened)
         :id ,path
         ,@(when (plist-member data :already_open)
             (list :already-open (herdr-model--bool
                                  (plist-get data :already_open)))))))
    ("worktree_removed"
     (let* ((wt (plist-get data :worktree))
            (path (or (plist-get wt :path) (plist-get data :path))))
       (when path
         (remhash path (herdr-session-worktrees session)))
       `(:event ,kind :what :worktree-removed :id ,path
         :forced ,(herdr-model--bool (plist-get data :forced)))))
    ;; --- tabs ---
    ("tab_created"
     (let ((tb (plist-get data :tab)))
       (herdr-model--upsert-tab session tb)
       `(:event ,kind :what :tab-updated :id ,(plist-get tb :tab_id))))
    ("tab_renamed"
     (let* ((tab-id (plist-get data :tab_id))
            (tab (herdr-model-find-tab session tab-id)))
       (when tab
         (setf (herdr-tab-label tab) (plist-get data :label)))
       `(:event ,kind :what :tab-updated :id ,tab-id)))
    ("tab_moved"
     (dolist (tab (append (plist-get data :tabs) nil))
       (herdr-model--upsert-tab session tab))
     `(:event ,kind :what :tab-updated :id ,(plist-get data :tab_id)))
    ("tab_closed"
     (let* ((tid (plist-get data :tab_id))
            (closed-agents
             (cl-remove-if-not
              (lambda (agent) (equal tid (herdr-agent-tab-id agent)))
              (herdr-model--hash-values (herdr-session-agents session))))
            (changed
             (or (herdr-model-find-tab session tid)
                 closed-agents
                 (cl-some (lambda (pane)
                            (equal tid (herdr-pane-tab-id pane)))
                          (herdr-model--hash-values
                           (herdr-session-panes session))))))
       (herdr-model--remove-tab-cascade session tid)
       `(:event ,kind :what :tab-closed :id ,tid
         :closed-agents ,closed-agents :replayp ,(not changed))))
    ("tab_focused"
     (let ((tid (plist-get data :tab_id))
           (wid (plist-get data :workspace_id)))
       (herdr-model--focus-tab session tid wid)
       `(:event ,kind :what :tab-focused :id ,tid)))
    ;; --- panes & agents ---
    ("pane_created"
     (let* ((pn (plist-get data :pane))
            (id (plist-get pn :pane_id)))
       (cond
        ((and id (gethash id (herdr-session-gone-panes session)))
         ;; The server drained the EventHub ring buffer on subscribe
         ;; (global subscriptions replay from sequence 0), and a pane id is
         ;; never recycled.  So a `pane_created' for a pane we already
         ;; learned (via `pane.list' reconciliation) is GONE is a stale
         ;; replay whose matching `pane_closed'/`pane_exited' aged out of
         ;; the bounded ring.  Re-inserting it would put a dead pane_id in
         ;; the per-pane subscribe set, and one stale id rejects the whole
         ;; batch (real Herdr `pane_get(...)?' propagates `pane_not_found').
         ;; Ignore it; flag :replayp so no needless resubscribe is queued.
         `(:event ,kind :what :pane-replayed :id ,id :replayp t))
        ((and id (herdr-model-find-pane session id))
         ;; Already cached (from the snapshot): a replayed create for a
         ;; pane still present.  The snapshot struct is fresher than the
         ;; replayed event, so skip the upsert (mirrors `workspace_created');
         ;; a replayed create adds no new pane, so flag :replayp to skip the
         ;; per-pane resubscribe it would otherwise trigger.
         `(:event ,kind :what :pane-replayed :id ,id :replayp t))
        (t
         (herdr-model--upsert-pane session pn)
         (herdr-model--maybe-upsert-agent-from-pane session pn)
         `(:event ,kind :what :pane-updated :id ,id)))))
    ((or "pane_updated" "pane_moved")
     (let* ((pn (plist-get data :pane))
            (id (plist-get pn :pane_id))
            (prev (plist-get data :previous_pane_id)))
       (if (and id (gethash id (herdr-session-gone-panes session)))
           `(:event ,kind :what :pane-replayed :id ,id :replayp t)
         ;; A move may change the workspace-qualified pane id; drop the
         ;; stale entries from BOTH tables and permanently retire the old id.
         (let ((previous-agent
                (and prev (herdr-model-find-agent session prev))))
           (when (and prev (not (equal prev id)))
             (herdr-model--remove-pane-cascade session prev))
           (herdr-model--upsert-pane session pn)
           (herdr-model--maybe-upsert-agent-from-pane session pn previous-agent)
           `(:event ,kind :what :pane-updated :id ,id)))))
    ((or "pane_closed" "pane_exited")
     (let* ((pid (plist-get data :pane_id))
            (already-gone (and pid
                               (gethash pid
                                        (herdr-session-gone-panes session))))
            (pane (and pid (herdr-model-find-pane session pid)))
            ;; Remember whether this was an agent pane before removing it.
            ;; The explicit kill path may already have removed the AgentInfo,
            ;; while the PaneInfo still carries its detected agent kind.
            (agentp (or (and pid (herdr-model-find-agent session pid))
                        (and pane (herdr-pane-agent pane)))))
       (remhash pid (herdr-session-panes session))
       (remhash pid (herdr-session-agents session))
       (when pid
         ;; Pane ids are never recycled.  Recording every observed close
         ;; prevents a replayed pane_created from resurrecting it and
         ;; repeatedly rebuilding/rejecting the subscription batch.
         (puthash pid t (herdr-session-gone-panes session)))
       `(:event ,kind :what :pane-closed :id ,pid
         :agentp ,(and agentp t) :replayp ,(and already-gone t))))
    ("pane_focused"
     (let ((pid (plist-get data :pane_id))
           (wid (plist-get data :workspace_id)))
       (herdr-model--focus-pane session pid wid)
       `(:event ,kind :what :pane-focused :id ,pid)))
    ("pane_output_changed"
     (let* ((pid (plist-get data :pane_id))
            (rev (plist-get data :revision))
            (pn (herdr-model-find-pane session pid)))
       (when pn (setf (herdr-pane-revision pn) rev))
       `(:event ,kind :what :pane-output :id ,pid :revision ,rev)))
    ("pane_scroll_changed"
     (let ((pid (plist-get data :pane_id)))
       `(:event ,kind :what :pane-scroll :id ,pid)))
    ("pane_agent_detected"
     ;; `pane_agent_detected' carries NO `:pane' field.  Its payload is
     ;; {pane_id, workspace_id, agent?(str), released(bool),
     ;; final_status?(AgentStatus)} — the screen-detection signal.  `agent'
     ;; is the agent KIND string, not an AgentInfo struct.  So:
     ;;  - pane remembered gone        -> stale replay, skip (pane_ids never
     ;;                                  recycle; a replayed detection for a
     ;;                                  closed pane must not re-insert it).
     ;;  - agent already cached        -> patch kind/status in place; this is
     ;;                                  a stale replay on reconnect (the
     ;;                                  snapshot already cached the agent),
     ;;                                  so flag :replayp to skip the
     ;;                                  resubscribe churn (the per-pane sub
     ;;                                  already exists).
     ;;  - not cached, not gone        -> first detection on a pane that had
     ;;                                  no agent: create a minimal entry
     ;;                                  (enriched later by `pane_updated'/
     ;;                                  snapshot) and rebuild so the new
     ;;                                  agent gets a per-pane subscription.
     ;; (Earlier code read a nonexistent `:pane' and upserted nil, so
     ;; detection never updated the cache at all.)
     (let* ((pid (plist-get data :pane_id))
            (ws-id (plist-get data :workspace_id))
            (ag-kind (plist-get data :agent))
            (final-status (plist-get data :final_status))
            (gone (and pid (gethash pid (herdr-session-gone-panes session))))
            (cached (and pid (not gone) (herdr-model-find-agent session pid)))
            (pn (and pid (not gone) (herdr-model-find-pane session pid))))
       (cond
        ((null pid) `(:event ,kind :what :agent-detected :id nil))
        (gone `(:event ,kind :what :agent-detected :id ,pid :replayp t))
        (cached
         (when ag-kind      (setf (herdr-agent-agent cached) ag-kind))
         (when final-status (setf (herdr-agent-agent-status cached) final-status))
         (when ws-id        (setf (herdr-agent-workspace-id cached) ws-id))
         (when pn
           (when ag-kind      (setf (herdr-pane-agent pn) ag-kind))
           (when final-status (setf (herdr-pane-agent-status pn) final-status))
           (when ws-id        (setf (herdr-pane-workspace-id pn) ws-id)))
         `(:event ,kind :what :agent-detected :id ,pid
           :status ,final-status :replayp t))
        (t
         (when ag-kind
           (puthash pid
                    (make-herdr-agent :id pid
                                       :workspace-id (or ws-id "")
                                       :agent ag-kind
                                       :agent-status (or final-status "unknown"))
                    (herdr-session-agents session)))
         (when pn
           (when ag-kind      (setf (herdr-pane-agent pn) ag-kind))
           (when final-status (setf (herdr-pane-agent-status pn) final-status)))
         `(:event ,kind :what :agent-detected :id ,pid
           :status ,final-status)))))
    ("pane_agent_status_changed"
     (let* ((pid (plist-get data :pane_id))
            (status (plist-get data :agent_status))
            ;; `agent' is Option<String> — the agent KIND/name, NOT an
            ;; AgentInfo struct.  The per-pane `PaneAgentStatusChangedEvent'
            ;; carries a bare string, so patch the cached agent in place
            ;; (the agent was established by the snapshot or a prior
            ;; `pane_agent_detected').  The old code called
            ;; `herdr-model--parse-agent' on this string, building an
            ;; all-nil struct that wiped the cached identity fields.
            (ag-kind (plist-get data :agent))
            (title (plist-get data :title))
            (display (plist-get data :display_agent))
            (state-labels (plist-get data :state_labels))
            (cached (herdr-model-find-agent session pid))
            (pn (herdr-model-find-pane session pid)))
       ;; A per-pane status frame can race ahead of the global detection
       ;; event after subscribe.  If it identifies an agent kind, create a
       ;; minimal AgentInfo projection instead of dropping the only status
       ;; signal and leaving the dashboard empty until the next snapshot.
       (when (and (null cached) pid ag-kind
                  (not (gethash pid (herdr-session-gone-panes session))))
         (setq cached
               (make-herdr-agent
                :id pid
                :workspace-id (and pn (herdr-pane-workspace-id pn))
                :tab-id (and pn (herdr-pane-tab-id pn))
                :terminal-id (and pn (herdr-pane-terminal-id pn))
                :cwd (and pn (herdr-pane-cwd pn))
                :focused (and pn (herdr-pane-focused pn))
                :agent ag-kind :agent-status (or status "unknown")))
         (puthash pid cached (herdr-session-agents session)))
       (when cached
         (when status       (setf (herdr-agent-agent-status cached) status))
         (when ag-kind      (setf (herdr-agent-agent cached) ag-kind))
         (when title        (setf (herdr-agent-title cached) title))
         (when display      (setf (herdr-agent-display-agent cached) display))
         (when state-labels (setf (herdr-agent-state-labels cached) state-labels)))
       (when pn
         (when status  (setf (herdr-pane-agent-status pn) status))
         (when ag-kind (setf (herdr-pane-agent pn) ag-kind)))
       `(:event ,kind :what :agent-status :id ,pid :status ,status)))
    ("layout_updated"
     `(:event ,kind :what :layout :id nil))
    (_
     `(:event ,kind :what :unknown :id nil))))

(defun herdr-model--upsert-workspace (session w &optional created-p)
  "Insert or update WORKSPACE plist W in SESSION.
When CREATED-P is non-nil the caller is handling a `workspace_created'
event: if a workspace with the same id is ALREADY cached, W is a
connect-time replay (the EventHub ring buffer is drained on every
subscribe; reconnect contract, docs/PROTOCOL.md §9) and is IGNORED — a
genuine new workspace is still inserted.  When CREATED-P is nil
\(`workspace_updated' / `workspace_metadata_updated') W replaces the
cached struct (those events carry authoritative fresh field values),
but an existing `custom-name' is PRESERVED across the replace — a
`workspace_updated' never renames (rename is a separate event), and the
label is derived in `herdr-workspace-label' from `custom-name' first."
  (when-let* ((id (plist-get w :workspace_id)))
    (unless (and created-p (gethash id (herdr-session-workspaces session)))
      (let* ((old (gethash id (herdr-session-workspaces session)))
             (new (herdr-model--parse-workspace w)))
        (when old
          (setf (herdr-workspace-custom-name new)
                (herdr-workspace-custom-name old)))
        (puthash id new (herdr-session-workspaces session))))))

(defun herdr-model--upsert-worktree (session wt)
  "Insert or update WORKTREE plist WT (a WorktreeInfo) in SESSION.
Keyed by `path'.  No-op if WT has no `:path'."
  (when-let* ((path (plist-get wt :path)))
    (puthash path (herdr-model--parse-worktree wt)
             (herdr-session-worktrees session))))

(defun herdr-model--upsert-tab (session tb)
  "Insert or update TAB plist TB in SESSION."
  (when-let* ((id (plist-get tb :tab_id)))
    (puthash id (herdr-model--parse-tab tb)
             (herdr-session-tabs session))))

(defun herdr-model--upsert-pane (session pn)
  "Insert or update PANE plist PN in SESSION."
  (when-let* ((id (plist-get pn :pane_id)))
    (puthash id (herdr-model--parse-pane pn)
             (herdr-session-panes session))))

(defun herdr-model--maybe-upsert-agent-from-pane (session pn &optional previous-agent)
  "Reconcile SESSION.agents with the agent field of pane plist PN.
PN is the `:pane' payload of a `pane_created'/`pane_updated'/`pane_moved'
event (a PaneInfo).  The `:agent' field is `str|null', but an event may
OMIT it entirely (carrying only a layout/title delta) — and the
connection-time replay pushes `pane_created' events with no `:agent' at
all.  Treating a missing `:agent' as \"no agent\" wrongly evicts a known
agent (a focused agent vanishes from the dashboard because repeated
`pane_created' events with no `:agent' keep remhash-ing
it).  So:
  - `:agent' present and non-nil -> upsert the agent.
  - `:agent' key present but nil  -> the pane genuinely has no agent; remove.
  - `:agent' key absent           -> the event says nothing about agents;
                                     leave the cached agent (if any) alone.
A real agent departure arrives as `pane_closed'/`pane_exited' (which
remhash unconditionally) or a later event carrying `:agent' nil."
  (when-let* ((id (plist-get pn :pane_id)))
    (if (plist-member pn :agent)
        (if (plist-get pn :agent)
            (let* ((old (or (gethash id (herdr-session-agents session))
                            previous-agent))
                   (new (herdr-model--parse-agent pn)))
              ;; PaneInfo does not contain AgentInfo-only identity/lifecycle
              ;; fields.  Preserve them across pane.updated and pane.moved;
              ;; replacing the struct wholesale used to erase the live agent
              ;; name after an ordinary cwd/title/focus update.
              (when old
                (setf (herdr-agent-name new) (herdr-agent-name old)
                      (herdr-agent-state-change-seq new)
                      (herdr-agent-state-change-seq old)
                      (herdr-agent-interactive-ready new)
                      (herdr-agent-interactive-ready old)
                      (herdr-agent-launch-pending new)
                      (herdr-agent-launch-pending old)))
              (puthash id new (herdr-session-agents session)))
          (remhash id (herdr-session-agents session)))
      ;; No :agent key: a partial pane delta — preserve the cached agent.
      nil)))


;;; --- Read accessors -----------------------------------------------

(defun herdr-model-workspaces (&optional session)
  "Return a list of all workspace structs in SESSION (default: cache).
Returns nil when there is no session (e.g. not yet connected)."
  (when-let* ((s (or session (herdr-model-cache))))
    (herdr-model--hash-values (herdr-session-workspaces s))))

(defun herdr-model-tabs (&optional session)
  "Return a list of all tab structs in SESSION (default: cache).
Returns nil when there is no session (e.g. not yet connected)."
  (when-let* ((s (or session (herdr-model-cache))))
    (herdr-model--hash-values (herdr-session-tabs s))))

(defun herdr-model-panes (&optional session)
  "Return a list of all pane structs in SESSION (default: cache).
Returns nil when there is no session (e.g. not yet connected)."
  (when-let* ((s (or session (herdr-model-cache))))
    (herdr-model--hash-values (herdr-session-panes s))))

(defun herdr-model-agents (&optional session)
  "Return a list of all agent structs in SESSION (default: cache).
Returns nil when there is no session (e.g. not yet connected)."
  (when-let* ((s (or session (herdr-model-cache))))
    (herdr-model--hash-values (herdr-session-agents s))))

(defun herdr-model-find-workspace (session-or-id &optional id)
  "Look up a workspace.
With one arg SESSION-OR-ID it searches the cache for ID; with two args
it searches SESSION for ID.  Returns nil if there is no session (e.g.
not yet connected) or no such entity."
  (let* ((s (if id session-or-id (herdr-model-cache)))
         (key (if id id session-or-id)))
    (and s (gethash key (herdr-session-workspaces s)))))

(defun herdr-model-find-tab (session-or-id &optional id)
  "Look up a tab (see `herdr-model-find-workspace')."
  (let* ((s (if id session-or-id (herdr-model-cache)))
         (key (if id id session-or-id)))
    (and s (gethash key (herdr-session-tabs s)))))

(defun herdr-model-find-pane (session-or-id &optional id)
  "Look up a pane (see `herdr-model-find-workspace')."
  (let* ((s (if id session-or-id (herdr-model-cache)))
         (key (if id id session-or-id)))
    (and s (gethash key (herdr-session-panes s)))))

(defun herdr-model-find-agent (session-or-id &optional id)
  "Look up an agent by pane id (see `herdr-model-find-workspace')."
  (let* ((s (if id session-or-id (herdr-model-cache)))
         (key (if id id session-or-id)))
    (and s (gethash key (herdr-session-agents s)))))

(defun herdr-model-worktrees (&optional session)
  "Return a list of all worktree structs in SESSION (default: cache).
Returns nil when there is no session (e.g. not yet connected)."
  (when-let* ((s (or session (herdr-model-cache))))
    (herdr-model--hash-values (herdr-session-worktrees s))))

(defun herdr-model-find-worktree (session-or-id &optional id)
  "Look up a worktree by path (see `herdr-model-find-workspace')."
  (let* ((s (if id session-or-id (herdr-model-cache)))
         (key (if id id session-or-id)))
    (and s (gethash key (herdr-session-worktrees s)))))

(defun herdr-model-find-worktree-for-workspace (workspace-id &optional session)
  "Return the worktree whose open workspace is WORKSPACE-ID, or nil.
Scans the worktree cache (default: cache singleton) for a worktree whose
`open-workspace-id' equals WORKSPACE-ID.  nil when there is no session or
no worktree is currently open for that workspace."
  (when-let* ((s (or session (herdr-model-cache)))
              (workspaces (herdr-session-worktrees s)))
    (let (found)
      (maphash (lambda (_path wt)
                 (when (and (equal (herdr-worktree-open-workspace-id wt)
                                   workspace-id)
                            (not found))
                   (setq found wt)))
               workspaces)
      found)))


;;; --- Workspace label (live, like the TUI) -------------------------
;;
;; The server's workspace `label' is not a stored field: it is computed
;; live by `display_name_from' (src/workspace.rs:1139) as
;;   custom_name || basename(root-pane cwd) || "workspace"
;; and the TUI recomputes it every frame (src/ui/sidebar.rs:154).  A
;; root-pane cwd change is pushed only as `pane_updated' (never a
;; workspace event), so a cached label goes stale on every `cd'.  We
;; mirror the TUI: derive the label on read from the root-pane cwd, so
;; replays and real cwd changes cannot stale it.

(defconst herdr-model--public-id-alphabet
  "123456789ABCDEFGHJKMNPQRSTVWXYZ0"
  "Herdr's public pane/tab id alphabet (src/workspace.rs:107).
A 32-symbol base; number 1 encodes as \"1\", so a root pane id is
\"{ws}:p1\".  Skips I/L/O/U to avoid 1/I, 0/O confusion.")

(defun herdr-model--decode-public-number (encoded)
  "Decode ENCODED (the `:p...' suffix of a pane id) to its integer, or nil.
Port of the server's `decode_public_number' (src/workspace.rs:128)."
  (when (and (stringp encoded) (not (string-empty-p encoded)))
    (let ((len (length herdr-model--public-id-alphabet))
          (result 0))
      (catch 'invalid
        (dolist (ch (string-to-list encoded))
          (let ((idx (string-match-p (regexp-quote (char-to-string ch))
                                     herdr-model--public-id-alphabet)))
            (if (null idx)
                (throw 'invalid nil)
              (setq result (+ (* result len) (1+ idx))))))
        result))))

(defun herdr-model--pane-public-number (pane-id)
  "Return the integer public number encoded in PANE-ID, or nil.
PANE-ID is \"{ws}:p{encoded}\" (src/workspace.rs:145).  Numbers are
assigned in creation order and never recycled (src/workspace.rs:1247),
so the smallest number in a workspace identifies its first tab's root
pane — the cwd the server derives the workspace label from."
  (when (and (stringp pane-id) (string-match ":p\\(.+\\)$" pane-id))
    (herdr-model--decode-public-number (match-string 1 pane-id))))

(defun herdr-model--workspace-identity-cwd (session ws)
  "Return the cwd of WS's root pane, or nil.
The root pane is the pane in WS with the smallest public pane number
(= the first tab's root pane; mirrors the server's
`resolved_identity_cwd_from', src/workspace.rs:1148).  nil when WS has
no known panes.  SESSION defaults to the cache singleton."
  (when-let* ((s (or session (herdr-model-cache)))
              (ws-id (herdr-workspace-id ws)))
    (let (best-num best-cwd)
      (dolist (pn (herdr-model--hash-values (herdr-session-panes s)))
        (when (equal (herdr-pane-workspace-id pn) ws-id)
          (let* ((num (herdr-model--pane-public-number (herdr-pane-id pn)))
                 (cwd (herdr-pane-cwd pn)))
            (when (and num cwd (not (string-empty-p cwd))
                       (or (null best-num) (< num best-num)))
              (setq best-num num best-cwd cwd)))))
      best-cwd)))

(defun herdr-model--workspace-auto-label (ws &optional session)
  "Return the cwd-derived workspace label (root-pane cwd basename), or nil.
Mirrors the server's `automatic_display_name_for_cwd'
(src/workspace.rs:1153).  SESSION defaults to the cache singleton."
  (when-let* ((cwd (herdr-model--workspace-identity-cwd session ws)))
    (file-name-nondirectory (directory-file-name cwd))))

(defun herdr-workspace-label (ws)
  "Return WS's live display name, computed like Herdr's TUI.
Order: `custom-name' (set by `workspace_renamed') -> basename of the
root-pane cwd (derived live from the pane cache, so it tracks real `cd's
the server pushes as `pane_updated') -> the cached snapshot label
(fallback) -> \"workspace\".  The server computes this every frame
(`display_name_from', src/workspace.rs:1139); deriving it on read —
rather than caching a label field that events overwrite — means
buffered-event replays and real cwd changes cannot stale it."
  (cond
   ((not (herdr-workspace-p ws)) nil)
   ((let ((c (herdr-workspace-custom-name ws)))
      (and (stringp c) (not (string-empty-p c)) c)))
   ((herdr-model--workspace-auto-label ws))
   ((let ((l (herdr-workspace-cached-label ws)))
      (and (stringp l) (not (string-empty-p l)) l)))
   (t "workspace")))

(defun herdr-model-find-agent-by-name (name &optional session)
  "Return the cached agent struct named NAME, or nil.
NAME comparison is case-sensitive and exact.  Returns nil if NAME is
nil/empty or no agent has that name.  Searches SESSION (default: cache)."
  (when (and name (not (string-empty-p name)))
    (cl-find name (herdr-model-agents (or session (herdr-model-cache)))
             :test #'equal
             :key (lambda (a) (or (herdr-agent-name a) "")))))

(defun herdr-model-upsert-agent-info (info &optional session)
  "Insert or update an agent from an AgentInfo plist INFO.
Uses INFO's `pane_id' as the cache key.  No-op (returns nil) if INFO
has no `pane_id' or there is no live cache.  This lets the agent
control layer (Phase 2) keep the cache consistent immediately after an
`agent.start' / `agent.get' / `agent.list' RPC, without waiting for the
pushed event.  Returns the parsed struct, or nil."
  (when-let* ((pid (plist-get info :pane_id))
              (s (or session (herdr-model-cache))))
    (let ((agent (herdr-model--parse-agent info)))
      (puthash pid agent (herdr-session-agents s))
      agent)))

(defun herdr-model-upsert-workspace (info &optional session)
  "Insert or update a workspace from a WorkspaceInfo plist INFO.
Uses INFO's `workspace_id' as the cache key.  No-op (returns nil) if INFO
has no `workspace_id' or there is no live cache.  This lets the control
layer keep the cache consistent immediately after a `workspace.create' or
`worktree.create' RPC, without waiting for the pushed event.  An existing
`custom-name' is preserved (a create never renames; the label is derived
in `herdr-workspace-label').  Returns the parsed struct, or nil."
  (when-let* ((id (plist-get info :workspace_id))
              (s (or session (herdr-model-cache))))
    (herdr-model--upsert-workspace s info)
    (gethash id (herdr-session-workspaces s))))

(defun herdr-model-upsert-worktree (info &optional session)
  "Insert or update a worktree from a WorktreeInfo plist INFO.
Uses INFO's `path' as the cache key.  No-op (returns nil) if INFO has no
`path' or there is no live cache.  This lets the control layer keep the
cache consistent immediately after a `worktree.create' RPC, without waiting
for the pushed `worktree_created' event.  Returns the parsed struct, or nil."
  (when-let* ((path (plist-get info :path))
              (s (or session (herdr-model-cache))))
    (let ((wt (herdr-model--parse-worktree info)))
      (puthash path wt (herdr-session-worktrees s))
      wt)))

(defun herdr-model-remove-agent (pane-id &optional session)
  "Remove the agent with PANE-ID from the cache.
Used for eager cleanup after an explicit kill; the matching
`pane_closed' / `pane_exited' event would also remove it.  No-op if
there is no live cache."
  (when-let* ((s (or session (herdr-model-cache))))
    (remhash pane-id (herdr-session-agents s))))

(defun herdr-model-mark-pane-gone (pane-id &optional session)
  "Record that PANE-ID no longer exists on the server, and drop it.
Called by `pane.list' reconciliation (herdr.el) when the server reports a
pane id the cache still holds — typically a `pane_created' replayed from
the EventHub ring buffer whose matching `pane_closed'/`pane_exited' aged
out of the bounded ring.  Herdr never recycles a pane id, so remembering
it gone lets `herdr-model-apply-event' ignore a future replayed
`pane_created' for it, instead of re-inserting a dead id that would
reject the per-pane subscribe batch.  No-op if there is no live cache."
  (when-let* ((s (or session (herdr-model-cache))))
    (herdr-model--remove-pane-cascade s pane-id)))

(defun herdr-model-remove-worktree (path &optional session)
  "Remove the worktree with PATH from the cache.
Used for eager cleanup after an explicit `worktree.remove'; the matching
`worktree_removed' event would also remove it.  No-op if there is no
live cache or no worktree at PATH."
  (when-let* ((s (or session (herdr-model-cache))))
    (remhash path (herdr-session-worktrees s))))

(defun herdr-model-focused-workspace (&optional session)
  "Return the focused workspace struct, or nil.
Returns nil when there is no session (e.g. not yet connected)."
  (when-let* ((s (or session (herdr-model-cache)))
              (id (herdr-session-focused-workspace-id s)))
    (gethash id (herdr-session-workspaces s))))

(defun herdr-model-focused-pane (&optional session)
  "Return the focused pane struct, or nil.
Returns nil when there is no session (e.g. not yet connected)."
  (when-let* ((s (or session (herdr-model-cache)))
              (id (herdr-session-focused-pane-id s)))
    (gethash id (herdr-session-panes s))))

(defun herdr-model--agent-workspace-label (agent)
  "Return AGENT's workspace label, or nil.
This is Herdr's primary identity for an agent (its sidebar shows
`{workspace-label} · {kind}').  Returns nil when the agent has no
workspace, the workspace is not in the cache, or its label is
empty/nil."
  (when-let* ((ws-id (herdr-agent-workspace-id agent))
              (ws (herdr-model-find-workspace ws-id))
              (label (herdr-workspace-label ws)))
    (and (not (string-empty-p label)) label)))

(defun herdr-model--agent-cwd-basename (agent)
  "Return AGENT's cwd basename, or nil.
Herdr derives a workspace name from the project directory when no label
is set, so this is the identity fallback below the workspace label."
  (when-let* ((cwd (herdr-agent-cwd agent)))
    (and (not (string-empty-p cwd))
         (file-name-nondirectory (directory-file-name cwd)))))

(defun herdr-agent-display-name (agent)
  "Return a human label for AGENT, matching Herdr's agent identity.
Fallback order: name -> workspace-label -> cwd-basename ->
terminal-title-stripped -> terminal-title -> agent (kind) -> id
\(pane-id).  An explicit `name' (set via `agent.start'/`agent.rename')
always wins.  For TUI-started agents (no `name') the identity is the
Herdr workspace label (else the cwd basename) — NOT the terminal title,
which is the agent's current *task* (surfaced separately in the
dashboard Task column).  The terminal title is only a late fallback for
a malformed agent with no workspace/cwd.  Returns nil if AGENT is nil."
  (when agent
    (or (herdr-agent-name agent)
        (herdr-model--agent-workspace-label agent)
        (herdr-model--agent-cwd-basename agent)
        (herdr-agent-terminal-title-stripped agent)
        (herdr-agent-terminal-title agent)
        (herdr-agent-agent agent)
        (herdr-agent-id agent))))


(provide 'herdr-model)
;;; herdr-model.el ends here
