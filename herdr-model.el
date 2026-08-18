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
;; fresh snapshot (see `herdr.el'); events are never replayed.
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
WORKSPACES, TABS, PANES and AGENTS are hash tables keyed by id
(string).  Agents are keyed by `pane-id' (the snapshot does not
carry a stable agent `name'; see docs/PROTOCOL.md §6)."
  protocol version
  focused-workspace-id focused-tab-id focused-pane-id
  workspaces tabs panes agents)              ; hash-tables string -> struct

(cl-defstruct herdr-workspace
  "A Herdr workspace."
  id label number focused active-tab-id tab-count pane-count agent-status)

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
`state-change-seq')."
  id workspace-id tab-id terminal-id
  terminal-title terminal-title-stripped
  cwd foreground-cwd
  focused revision state-change-seq scroll
  agent agent-status agent-session)

(cl-defstruct herdr-agent-session
  "Native agent session identity reported by an integration."
  agent kind source value)


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
   :agents (make-hash-table :test 'equal)))

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
    session))

(defun herdr-model--parse-workspace (w)
  "Parse a workspace plist W (a WorkspaceInfo) into a struct."
  (make-herdr-workspace
   :id (plist-get w :workspace_id)
   :label (plist-get w :label)
   :number (plist-get w :number)
   :focused (herdr-model--bool (plist-get w :focused))
   :active-tab-id (plist-get w :active_tab_id)
   :tab-count (plist-get w :tab_count)
   :pane-count (plist-get w :pane_count)
   :agent-status (plist-get w :agent_status)))

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
                   (plist-get ag :agent_session))))

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

(defun herdr-model-apply-event (session kind data)
  "Reconcile one pushed event against SESSION (mutated in place).
KIND is the underscored event type (e.g. \"pane_agent_status_changed\").
DATA is the decoded event payload plist.  Returns a descriptor plist
\(:event KIND :what CHANGE-KEYWORD :id ENTITY-ID :status STATUS)."
  (pcase kind
    ;; --- workspaces ---
    ((or "workspace_created" "workspace_updated"
         "workspace_metadata_updated")
     (let ((w (plist-get data :workspace)))
       (herdr-model--upsert-workspace session w)
       `(:event ,kind :what :workspace-updated
         :id ,(plist-get w :workspace_id))))
    ("workspace_renamed"
     (let* ((wid (plist-get data :workspace_id))
            (w (herdr-model-find-workspace session wid)))
       (when w
         (setf (herdr-workspace-label w) (plist-get data :label)))
       `(:event ,kind :what :workspace-updated :id ,wid)))
    ("workspace_closed"
     (let ((wid (or (plist-get data :workspace_id)
                    (plist-get (plist-get data :workspace) :workspace_id))))
       (remhash wid (herdr-session-workspaces session))
       `(:event ,kind :what :workspace-closed :id ,wid)))
    ("workspace_focused"
     (let ((wid (plist-get data :workspace_id)))
       (setf (herdr-session-focused-workspace-id session) wid)
       `(:event ,kind :what :workspace-focused :id ,wid)))
    ((or "workspace_moved" "workspace_reordered")
     `(:event ,kind :what :workspace-reordered
       :id ,(plist-get data :workspace_id)))
    ;; --- worktrees (Phase 5; tolerate silently) ---
    ((or "worktree_created" "worktree_opened" "worktree_removed")
     `(:event ,kind :what :worktree :id nil))
    ;; --- tabs ---
    ("tab_created"
     (let ((tb (plist-get data :tab)))
       (herdr-model--upsert-tab session tb)
       `(:event ,kind :what :tab-updated :id ,(plist-get tb :tab_id))))
    ((or "tab_renamed" "tab_moved")
     `(:event ,kind :what :tab-updated
       :id ,(plist-get data :tab_id)))
    ("tab_closed"
     (let ((tid (plist-get data :tab_id)))
       (remhash tid (herdr-session-tabs session))
       `(:event ,kind :what :tab-closed :id ,tid)))
    ("tab_focused"
     (let ((tid (plist-get data :tab_id)))
       (setf (herdr-session-focused-tab-id session) tid)
       `(:event ,kind :what :tab-focused :id ,tid)))
    ;; --- panes & agents ---
    ("pane_created"
     (let* ((pn (plist-get data :pane))
            (id (plist-get pn :pane_id)))
       (herdr-model--upsert-pane session pn)
       (herdr-model--maybe-upsert-agent-from-pane session pn)
       `(:event ,kind :what :pane-updated :id ,id)))
    ((or "pane_updated" "pane_moved")
     (let* ((pn (plist-get data :pane))
            (id (plist-get pn :pane_id))
            (prev (plist-get data :previous_pane_id)))
       (when prev (remhash prev (herdr-session-panes session)))
       (herdr-model--upsert-pane session pn)
       (herdr-model--maybe-upsert-agent-from-pane session pn)
       `(:event ,kind :what :pane-updated :id ,id)))
    ((or "pane_closed" "pane_exited")
     (let ((pid (plist-get data :pane_id)))
       (remhash pid (herdr-session-panes session))
       (remhash pid (herdr-session-agents session))
       `(:event ,kind :what :pane-closed :id ,pid)))
    ("pane_focused"
     (let ((pid (plist-get data :pane_id)))
       (setf (herdr-session-focused-pane-id session) pid)
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
     (let* ((pn (plist-get data :pane))
            (pid (or (plist-get data :pane_id)
                     (plist-get pn :pane_id))))
       (herdr-model--maybe-upsert-agent-from-pane session pn)
       `(:event ,kind :what :agent-detected :id ,pid
         :status ,(plist-get data :final_status))))
    ("pane_agent_status_changed"
     (let* ((pid (plist-get data :pane_id))
            (ag (plist-get data :agent))
            (status (plist-get data :agent_status)))
       (when ag
         (puthash pid (herdr-model--parse-agent ag)
                  (herdr-session-agents session)))
       (let ((pn (herdr-model-find-pane session pid)))
         (when pn
           (setf (herdr-pane-agent pn) (plist-get ag :agent))
           (setf (herdr-pane-agent-status pn) status)))
       `(:event ,kind :what :agent-status :id ,pid :status ,status)))
    ("layout_updated"
     `(:event ,kind :what :layout :id nil))
    (_
     `(:event ,kind :what :unknown :id nil))))

(defun herdr-model--upsert-workspace (session w)
  "Insert or update WORKSPACE plist W in SESSION."
  (when-let* ((id (plist-get w :workspace_id)))
    (puthash id (herdr-model--parse-workspace w)
             (herdr-session-workspaces session))))

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

(defun herdr-model--maybe-upsert-agent-from-pane (session pn)
  "If PANE plist PN carries an agent, upsert it into SESSION.agents."
  (when-let* ((id (plist-get pn :pane_id)))
    (if (plist-get pn :agent)
        (puthash id (herdr-model--parse-agent pn)
                 (herdr-session-agents session))
      (remhash id (herdr-session-agents session)))))


;;; --- Read accessors -----------------------------------------------

(defun herdr-model-workspaces (&optional session)
  "Return a list of all workspace structs in SESSION (default: cache)."
  (herdr-model--hash-values
   (herdr-session-workspaces (or session (herdr-model-cache)))))

(defun herdr-model-tabs (&optional session)
  "Return a list of all tab structs in SESSION (default: cache)."
  (herdr-model--hash-values
   (herdr-session-tabs (or session (herdr-model-cache)))))

(defun herdr-model-panes (&optional session)
  "Return a list of all pane structs in SESSION (default: cache)."
  (herdr-model--hash-values
   (herdr-session-panes (or session (herdr-model-cache)))))

(defun herdr-model-agents (&optional session)
  "Return a list of all agent structs in SESSION (default: cache)."
  (herdr-model--hash-values
   (herdr-session-agents (or session (herdr-model-cache)))))

(defun herdr-model-find-workspace (session-or-id &optional id)
  "Look up a workspace.
With one arg SESSION-OR-ID it searches the cache for ID; with two args
it searches SESSION for ID."
  (if id
      (gethash id (herdr-session-workspaces session-or-id))
    (gethash session-or-id
             (herdr-session-workspaces (herdr-model-cache)))))

(defun herdr-model-find-tab (session-or-id &optional id)
  "Look up a tab (see `herdr-model-find-workspace')."
  (if id
      (gethash id (herdr-session-tabs session-or-id))
    (gethash session-or-id
             (herdr-session-tabs (herdr-model-cache)))))

(defun herdr-model-find-pane (session-or-id &optional id)
  "Look up a pane (see `herdr-model-find-workspace')."
  (if id
      (gethash id (herdr-session-panes session-or-id))
    (gethash session-or-id
             (herdr-session-panes (herdr-model-cache)))))

(defun herdr-model-find-agent (session-or-id &optional id)
  "Look up an agent by pane id (see `herdr-model-find-workspace')."
  (if id
      (gethash id (herdr-session-agents session-or-id))
    (gethash session-or-id
             (herdr-session-agents (herdr-model-cache)))))

(defun herdr-model-focused-workspace (&optional session)
  "Return the focused workspace struct, or nil."
  (let* ((s (or session (herdr-model-cache)))
         (id (herdr-session-focused-workspace-id s)))
    (and id (gethash id (herdr-session-workspaces s)))))

(defun herdr-model-focused-pane (&optional session)
  "Return the focused pane struct, or nil."
  (let* ((s (or session (herdr-model-cache)))
         (id (herdr-session-focused-pane-id s)))
    (and id (gethash id (herdr-session-panes s)))))


(provide 'herdr-model)
;;; herdr-model.el ends here
