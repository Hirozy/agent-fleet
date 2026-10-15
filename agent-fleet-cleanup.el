;;; agent-fleet-cleanup.el --- Explicit resource cleanup -*- lexical-binding: t; -*-

;; Copyright (C) 2026 agent-fleet contributors
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Runtime reclamation and worktree deletion share selection and safety checks,
;; not destructive semantics.  Task/Project are filters, never cleanup engines.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'crm)
(require 'agent-fleet)
(require 'agent-fleet-project)

(declare-function agent-fleet-task-list "agent-fleet-parallel")
(declare-function agent-fleet-task-find "agent-fleet-parallel")
(declare-function agent-fleet-task-id "agent-fleet-parallel")
(declare-function agent-fleet-task-title "agent-fleet-parallel")
(declare-function agent-fleet-task-agents "agent-fleet-parallel")
(declare-function agent-fleet-task-workspaces "agent-fleet-parallel")
(declare-function agent-fleet-task-cleanup-members "agent-fleet-parallel")
(declare-function agent-fleet-task-cleanup-record "agent-fleet-parallel")
(declare-function agent-fleet-worktree-remove "agent-fleet-worktree")

(defun agent-fleet-cleanup--check-connection (connection)
  "Require the original live CONNECTION throughout an operation."
  (unless (and (eq connection (herdr-connection)) (herdr-connected-p))
    (signal 'herdr-connection-error '(:reason cleanup-connection-changed))))

(defun agent-fleet-cleanup--context (connection)
  "Fetch authoritative topology and worktree linkage on CONNECTION.
Do not replace the live cache: pushed events may provide newer veto evidence."
  (agent-fleet-cleanup--check-connection connection)
  (let* ((session (herdr-model-parse-cleanup-snapshot
                   (herdr-request "session.snapshot" nil)))
         (seen (make-hash-table :test 'equal))
         worktrees)
    ;; This RPC lists ONE repository, defaulting to Herdr's active workspace.
    ;; Never use that implicit scope as evidence about other resources.
    (dolist (workspace (herdr-model-workspaces session))
      (agent-fleet-cleanup--check-connection connection)
      (condition-case err
          (dolist (wt (herdr-model-parse-worktree-list
                      (herdr-request "worktree.list"
                                     `((workspace_id . ,(herdr-workspace-id workspace))))))
            (let* ((path (herdr-worktree-path wt))
                   (previous (gethash path seen)))
              (when (and previous (not (equal previous wt)))
                (signal 'herdr-protocol-error
                        '(:reason conflicting-worktree-lists)))
              (unless previous
                (puthash path wt seen)
                (push wt worktrees))))
        (herdr-request-error
         (unless (equal (plist-get (cdr err) :code) "not_git_worktree")
           (signal (car err) (cdr err))))))
    (agent-fleet-cleanup--check-connection connection)
    (list :connection connection :session session :worktrees worktrees)))

(defun agent-fleet-cleanup--worktree-p (ws-id context)
  "Return non-nil when WS-ID has worktree linkage in CONTEXT or the cache."
  (or (cl-find ws-id (plist-get context :worktrees)
               :key #'herdr-worktree-open-workspace-id :test #'equal)
      (herdr-model-find-worktree-for-workspace ws-id)
      (when-let* ((ws (herdr-model-find-workspace
                       (plist-get context :session) ws-id)))
        (herdr-workspace-worktree ws))
      (when-let* ((ws (herdr-model-find-workspace ws-id)))
        (herdr-workspace-worktree ws))))

(defun agent-fleet-cleanup--done-p (agent)
  "Whether AGENT is present, done, and not awaiting launch."
  (and agent (equal (herdr-agent-agent-status agent) "done")
       (not (herdr-agent-launch-pending agent))))

(defun agent-fleet-cleanup--members-done-p (ids session)
  "Require IDS to be present and done in SESSION, honoring live vetoes."
  (cl-every
   (lambda (id)
     (and (not (and (herdr-model-cache)
                    (gethash id (herdr-session-gone-panes (herdr-model-cache)))))
          (agent-fleet-cleanup--done-p (herdr-model-find-agent session id))
          (let ((live (herdr-model-find-agent id)))
            (or (null live) (agent-fleet-cleanup--done-p live)))))
   ids))

(defun agent-fleet-cleanup--task-members (workspace-id)
  "Return all remaining members of tasks owning WORKSPACE-ID."
  (when (fboundp 'agent-fleet-task-cleanup-members)
    (agent-fleet-task-cleanup-members workspace-id)))

(defun agent-fleet-cleanup--pane-reason (pane session)
  "Return a reason to preserve PANE in SESSION, or nil.
An agent-free terminal is selectable, not presumed empty: its label and
confirmation explicitly warn that shells and other processes will close."
  (let* ((id (herdr-pane-id pane))
         (agent (herdr-model-find-agent session id))
         (live (herdr-model-find-agent id))
         (live-pane (herdr-model-find-pane id))
         (members (agent-fleet-cleanup--task-members
                   (herdr-pane-workspace-id pane))))
    (cond
     ((and (herdr-model-cache)
           (gethash id (herdr-session-gone-panes (herdr-model-cache))))
      "Pane disappeared; refresh")
     ((and agent (not (agent-fleet-cleanup--done-p agent)))
      "Agent is unfinished or launching")
     ((and (herdr-pane-agent pane)
           (or (null agent) (not (equal "done" (herdr-pane-agent-status pane)))))
      "Incomplete or unfinished pane agent state")
     ((and live (or (null agent) (not (agent-fleet-cleanup--done-p live))))
      "Newer agent activity in the live cache")
     ((and live-pane (herdr-pane-agent live-pane)
           (or (null agent)
               (not (equal "done" (herdr-pane-agent-status live-pane)))))
      "Newer pane activity in the live cache")
     ((and members (not (agent-fleet-cleanup--members-done-p members session)))
      "Task has unfinished or missing members"))))

(defun agent-fleet-cleanup--signature (pane session)
  "Return the identity and ownership approved for PANE in SESSION."
  (let ((agent (herdr-model-find-agent session (herdr-pane-id pane))))
    (list (herdr-pane-id pane) (herdr-pane-terminal-id pane)
          (herdr-pane-workspace-id pane) (herdr-pane-tab-id pane)
          (herdr-pane-cwd pane)
          (and agent (herdr-agent-agent agent))
          (and agent (herdr-agent-name agent)))))

(defun agent-fleet-cleanup--read-filter ()
  "Read a Project/Task filter, independent of the cleanup operation."
  (pcase (completing-read "Cleanup range: " '("All" "Project" "Task") nil t)
    ("Project"
     (let ((project (agent-fleet-project-root-for-cwd
                     (read-directory-name "Project directory: "))))
       (unless project (user-error "No Project at that directory"))
       (list :project project)))
    ("Task"
     (require 'agent-fleet-parallel)
     (let* ((choices (mapcar
                      (lambda (task)
                        (cons (format "%s [%s]" (agent-fleet-task-title task)
                                      (agent-fleet-task-id task)) task))
                      (agent-fleet-task-list))))
       (unless choices (user-error "No tasks"))
       (list :task (cdr (assoc (completing-read "Task: " choices nil t)
                               choices)))))
    (_ nil)))

(defun agent-fleet-cleanup--scope-ids (session project task)
  "Return allowed pane IDs for PROJECT and TASK in SESSION, or t for all."
  (let ((ids t))
    (when project
      ;; Reuse the public Project set query against this authoritative snapshot.
      (let ((herdr-model--cache session))
        (setq ids (mapcar #'herdr-agent-id (agent-fleet-project-agents project))))
      ;; Shells have no agent identity, but may have a real Project via cwd.
      (dolist (pane (herdr-model-panes session))
        (when (and (null (herdr-model-find-agent session (herdr-pane-id pane)))
                   (equal (agent-fleet-project-root-for-cwd (herdr-pane-cwd pane))
                          (agent-fleet-project-root-for-cwd project)))
          (push (herdr-pane-id pane) ids))))
    (when task
      (require 'agent-fleet-parallel)
      (when (stringp task) (setq task (agent-fleet-task-find task)))
      (unless task (user-error "Unknown task"))
      (setq ids (if (eq ids t) (agent-fleet-task-agents task)
                  (cl-intersection ids (agent-fleet-task-agents task) :test #'equal))))
    ids))

(defun agent-fleet-cleanup--pane-label (pane session)
  "Describe PANE from SESSION without implying an agent-free shell is empty."
  (let ((agent (herdr-model-find-agent session (herdr-pane-id pane))))
    (format "%s | %s [%s]"
            (if agent (format "%s (done)" (herdr-agent-display-name agent))
              "NO AGENT: shell/other processes will close")
            (or (herdr-pane-cwd pane) "cwd unknown") (herdr-pane-id pane))))

(defun agent-fleet-cleanup--candidates (context worktrees project task)
  "Return (:candidates ... :protected ...) for CONTEXT and filters.
WORKTREES selects code-directory deletion rather than runtime reclamation."
  (let* ((session (plist-get context :session))
         (scope (agent-fleet-cleanup--scope-ids session project task))
         candidates protected)
    (if worktrees
        (dolist (wt (plist-get context :worktrees))
          (let* ((ws-id (herdr-worktree-open-workspace-id wt))
                 (panes (and ws-id (cl-remove-if-not
                                    (lambda (p) (equal ws-id (herdr-pane-workspace-id p)))
                                    (herdr-model-panes session))))
                 (reason (cond
                          ((null panes) "No open terminal ownership; manual review required")
                          ((not (herdr-worktree-is-linked-worktree wt))
                           "Not a linked worktree")
                          (t (cl-some (lambda (p) (agent-fleet-cleanup--pane-reason p session))
                                      panes)))))
            (when (or (eq scope t)
                      (cl-some (lambda (p) (member (herdr-pane-id p) scope)) panes)
                      (and task ws-id
                           (let ((task-object (if (stringp task)
                                                  (agent-fleet-task-find task) task)))
                             (rassoc ws-id (agent-fleet-task-workspaces task-object)))))
              (if reason
                  (push (cons (herdr-worktree-path wt) reason) protected)
                (push (list :id ws-id :workspace ws-id :path (herdr-worktree-path wt)
                            :panes (mapcar (lambda (p) (agent-fleet-cleanup--signature p session)) panes)
                            :label (format "DELETE %s [%s] — %s"
                                           (herdr-worktree-path wt) ws-id
                                           (mapconcat (lambda (p) (agent-fleet-cleanup--pane-label p session)) panes "; ")))
                      candidates)))))
      (dolist (pane (herdr-model-panes session))
        (when (or (eq scope t) (member (herdr-pane-id pane) scope))
          (let ((reason (or (and (agent-fleet-cleanup--worktree-p
                                  (herdr-pane-workspace-id pane) context)
                                 "Worktree-associated; use cleanup-worktrees")
                            (agent-fleet-cleanup--pane-reason pane session))))
            (if reason (push (cons (herdr-pane-id pane) reason) protected)
              (push (list :id (herdr-pane-id pane)
                          :workspace (herdr-pane-workspace-id pane)
                          :panes (list (agent-fleet-cleanup--signature pane session))
                          :label (agent-fleet-cleanup--pane-label pane session))
                    candidates))))))
    (list :candidates (nreverse candidates) :protected (nreverse protected))))

(defun agent-fleet-cleanup--select (candidates)
  "Explicitly select CANDIDATES; an empty response selects nothing."
  (let* ((choices (mapcar (lambda (c) (cons (plist-get c :id) c)) candidates))
         (annotation (lambda (id) (concat "  " (plist-get (cdr (assoc id choices)) :label))))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata (annotation-function . ,annotation))
                    (complete-with-action action choices string predicate))))
         (selected (completing-read-multiple
                    "Select IDs (TAB shows names/paths; comma separates; empty cancels): "
                    table nil t)))
    (mapcar (lambda (id) (or (cdr (assoc id choices))
                             (user-error "Unknown cleanup selection: %s" id)))
            (delete-dups selected))))

(defun agent-fleet-cleanup--runtime-plan (candidates session)
  "Collapse selected CANDIDATES into disjoint close operations in SESSION."
  (let ((ids (mapcar (lambda (c) (plist-get c :id)) candidates)) covered result)
    (dolist (candidate candidates)
      (let* ((id (plist-get candidate :id))
             (pane (herdr-model-find-pane session id))
             (ws (herdr-pane-workspace-id pane))
             (tab (herdr-pane-tab-id pane))
             (ws-panes (cl-remove-if-not
                        (lambda (p) (equal ws (herdr-pane-workspace-id p)))
                        (herdr-model-panes session)))
             (tab-panes (cl-remove-if-not
                         (lambda (p) (equal tab (herdr-pane-tab-id p))) ws-panes))
             (all-selected (lambda (panes)
                             (cl-every (lambda (p) (member (herdr-pane-id p) ids)) panes))))
        (unless (member id covered)
          (let* ((whole-ws (funcall all-selected ws-panes))
                 (whole-tab (funcall all-selected tab-panes))
                 (panes (cond (whole-ws ws-panes) (whole-tab tab-panes) (t (list pane))))
                 (method (cond (whole-ws "workspace.close") (whole-tab "tab.close") (t "pane.close")))
                 (target (cond (whole-ws ws) (whole-tab tab) (t id))))
            (setq covered (append (mapcar #'herdr-pane-id panes) covered))
            (push (list :method method :id target :workspace ws
                        :panes (mapcar (lambda (p) (agent-fleet-cleanup--signature p session)) panes)
                        :label (format "%s %s (%d terminal(s))" method target (length panes)))
                  result)))))
    (nreverse result)))

(defun agent-fleet-cleanup--same-panes-p (left right)
  "Whether LEFT and RIGHT contain exactly the same approved identities."
  (equal (sort (copy-sequence left) (lambda (a b) (string< (car a) (car b))))
         (sort (copy-sequence right) (lambda (a b) (string< (car a) (car b))))))

(defun agent-fleet-cleanup--recheck (operation context worktrees)
  "Require OPERATION to remain exactly within its approved scope in CONTEXT."
  (let* ((session (plist-get context :session))
         (ws (plist-get operation :workspace))
         (method (plist-get operation :method))
         (panes (cl-remove-if-not
                 (lambda (p)
                   (cond ((or worktrees (equal method "workspace.close"))
                          (equal ws (herdr-pane-workspace-id p)))
                         ((equal method "tab.close")
                          (equal (plist-get operation :id) (herdr-pane-tab-id p)))
                         (t (equal (plist-get operation :id) (herdr-pane-id p)))))
                 (herdr-model-panes session))))
    (unless (and panes
                 (agent-fleet-cleanup--same-panes-p
                  (plist-get operation :panes)
                  (mapcar (lambda (p) (agent-fleet-cleanup--signature p session)) panes)))
      (user-error "Resource membership or identity changed; refresh and select again"))
    (if worktrees
        (unless (cl-find-if
                 (lambda (wt) (and (equal ws (herdr-worktree-open-workspace-id wt))
                                   (equal (plist-get operation :path) (herdr-worktree-path wt))
                                   (herdr-worktree-is-linked-worktree wt)))
                 (plist-get context :worktrees))
          (user-error "Worktree ownership changed"))
      (when (agent-fleet-cleanup--worktree-p ws context)
        (user-error "Resource now has worktree linkage")))
    (dolist (pane panes)
      (when-let* ((reason (agent-fleet-cleanup--pane-reason pane session)))
        (user-error "%s: %s" (herdr-pane-id pane) reason)))
    ;; A pushed creation or move can be newer than the snapshot.
    (dolist (pane (herdr-model-panes))
      (when (and (cond ((or worktrees (equal method "workspace.close"))
                        (equal ws (herdr-pane-workspace-id pane)))
                       ((equal method "tab.close")
                        (equal (plist-get operation :id) (herdr-pane-tab-id pane)))
                       (t (equal (plist-get operation :id) (herdr-pane-id pane))))
                 (not (member (agent-fleet-cleanup--signature pane (herdr-model-cache))
                              (plist-get operation :panes))))
        (user-error "Newer terminal identity or membership in live cache")))))

(defun agent-fleet-cleanup--run (worktrees project task targets select no-confirm)
  "Run explicit cleanup with WORKTREES, PROJECT, TASK, TARGETS and SELECT.
NO-CONFIRM skips only the final prompt, never revalidation.  Without SELECT
or explicit TARGETS, return a read-only candidate report."
  (agent-fleet--ensure-connected)
  (when project
    (setq project (or (agent-fleet-project-root-for-cwd project)
                      (user-error "Cleanup requires a resolvable Project"))))
  (let* ((connection (herdr-connection))
         (context (agent-fleet-cleanup--context connection))
         (report (agent-fleet-cleanup--candidates context worktrees project task))
         (candidates (plist-get report :candidates))
         (selected (if select (and candidates (agent-fleet-cleanup--select candidates))
                     (mapcar (lambda (id)
                               (or (cl-find id candidates :key (lambda (c) (plist-get c :id)) :test #'equal)
                                   (user-error "Ineligible cleanup target: %s" id)))
                             (delete-dups (copy-sequence targets)))))
         (operations (if worktrees selected
                       (agent-fleet-cleanup--runtime-plan selected (plist-get context :session))))
         closed failed cancelled)
    (when (and select (plist-get report :protected))
      (message "Protected: %s"
               (mapconcat (lambda (entry) (format "%s: %s" (car entry) (cdr entry)))
                          (plist-get report :protected) "; ")))
    (when (and operations
               (or (and no-confirm (not select))
                   (not (setq cancelled (not (yes-or-no-p
					      (concat (if worktrees
							  "Delete selected code directories and close their terminals? Preserve wanted commits first.\n"
							"Close selected terminals, including shells/other processes, and reclaim their containers? No code directories will be deleted.\n")
						      (mapconcat (lambda (c) (plist-get c :label)) selected "\n")
						      "\nActions:\n"
						      (mapconcat (lambda (c) (plist-get c :label)) operations "\n")
						      "\nProceed? ")))))))
      (dolist (operation operations)
        (condition-case err
            (let ((fresh (agent-fleet-cleanup--context connection)))
              (agent-fleet-cleanup--recheck operation fresh worktrees)
              (agent-fleet-cleanup--check-connection connection)
              (if worktrees
                  (progn
                    (require 'agent-fleet-worktree)
                    (agent-fleet-worktree-remove (plist-get operation :id))
                    (when (fboundp 'agent-fleet-task-cleanup-record)
                      (agent-fleet-task-cleanup-record (plist-get operation :id))))
                (let* ((method (plist-get operation :method))
                       (key (pcase method ("workspace.close" 'workspace_id)
				   ("tab.close" 'tab_id) (_ 'pane_id))))
                  (herdr-protocol-validate-ok
                   (herdr-request method (list (cons key (plist-get operation :id))))
                   method)))
              (push (plist-get operation :id) closed))
          (error (push (cons (plist-get operation :id) err) failed)))))
    (when select
      (message "Cleanup: %s%d succeeded, %d protected, %d failed%s"
               (if cancelled "cancelled; " "")
               (length closed) (length (plist-get report :protected)) (length failed)
               (if failed (concat ": " (mapconcat
					(lambda (e) (format "%s: %s" (car e) (error-message-string (cdr e))))
					failed "; ")) "")))
    (append report (list :closed (nreverse closed) :failed (nreverse failed)
                         :cancelled cancelled))))

;;;###autoload
(cl-defun agent-fleet-cleanup (&key project task targets select no-confirm)
  "Reclaim explicitly selected runtime resources, never delete worktrees.
Interactively filter by Project/Task, select terminals, and confirm.  The
planner closes a whole ordinary Workspace only when all its terminals are
selected; otherwise it closes selected tabs or panes.  Worktree resources,
unfinished agents, and incomplete tasks are protected.  Agent-free shells
are explicitly labeled as potentially containing other processes.
From Lisp, TARGETS is a list of pane IDs.  Omit TARGETS for a read-only
candidate report.  SELECT invokes selection; NO-CONFIRM is Lisp-only.
Return a plist containing :candidates, :protected, :closed and :failed."
  (interactive (append (agent-fleet-cleanup--read-filter) (list :select t)))
  (agent-fleet-cleanup--run nil project task targets select no-confirm))

(provide 'agent-fleet-cleanup)
;;; agent-fleet-cleanup.el ends here
