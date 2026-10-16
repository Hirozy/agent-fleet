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

(defun agent-fleet-cleanup--task-members (workspace-id session)
  "Return all remaining members of tasks owning WORKSPACE-ID."
  (when (fboundp 'agent-fleet-task-cleanup-members)
    (agent-fleet-task-cleanup-members workspace-id session)))

(defun agent-fleet-cleanup--pane-reason (pane session)
  "Return a reason to preserve PANE in SESSION, or nil.
An agent-free terminal is selectable, not presumed empty: its label and
confirmation explicitly warn that shells and other processes will close."
  (let* ((id (herdr-pane-id pane))
         (agent (herdr-model-find-agent session id))
         (live (herdr-model-find-agent id))
         (live-pane (herdr-model-find-pane id))
         (members (agent-fleet-cleanup--task-members
                   (herdr-pane-workspace-id pane) session)))
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
  (pcase (completing-read "Cleanup range: "
                          (append '("All" "Project")
                                  (when (and (fboundp 'agent-fleet-task-list)
                                             (agent-fleet-task-list))
                                    '("Task (Emacs parallel group)"))) nil t)
    ("Project"
     (let ((project (agent-fleet-project-root-for-cwd
                     (read-directory-name "Project directory: "))))
       (unless project (user-error "No Project at that directory"))
       (list :project project)))
    ("Task (Emacs parallel group)"
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
                            :kind 'worktree
                            :label (format "DELETE %s | branch: %s — %s"
                                           (herdr-worktree-path wt) (or (herdr-worktree-branch wt) "detached")
                                           (mapconcat (lambda (p) (agent-fleet-cleanup--pane-label p session)) panes "; ")))
                      candidates)))))
      (dolist (pane (herdr-model-panes session))
        (when (or (eq scope t) (member (herdr-pane-id pane) scope))
          (let ((reason (or (and (agent-fleet-cleanup--worktree-p
                                  (herdr-pane-workspace-id pane) context)
                                 "Worktree-associated; cannot close separately")
                            (agent-fleet-cleanup--pane-reason pane session))))
            (if reason (push (cons (herdr-pane-id pane) reason) protected)
              (push (list :id (herdr-pane-id pane)
                          :kind 'runtime
                          :workspace (herdr-pane-workspace-id pane)
                          :panes (list (agent-fleet-cleanup--signature pane session))
                          :label (agent-fleet-cleanup--pane-label pane session))
                    candidates))))))
    (list :candidates (nreverse candidates) :protected (nreverse protected))))


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
                        :label (format "Close %s%s"
                                       (mapconcat (lambda (p) (agent-fleet-cleanup--pane-label p session))
                                                  panes "; ")
                                       (if (or whole-ws whole-tab)
                                           "; reclaim selected container" "")))
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

(defun agent-fleet-cleanup--report (context project task)
  "Combine typed resources from CONTEXT, filtered by PROJECT and TASK."
  (let* ((runtime (agent-fleet-cleanup--candidates context nil project task))
         (trees (agent-fleet-cleanup--candidates context t project task))
         (session (plist-get context :session))
         (tree-owners (mapcar #'herdr-worktree-open-workspace-id
                             (cl-remove-if-not #'herdr-worktree-is-linked-worktree
                                               (plist-get context :worktrees))))
         (candidates (append (plist-get runtime :candidates)
                             (plist-get trees :candidates))))
    (unless (= (length candidates)
               (length (delete-dups (mapcar (lambda (c) (plist-get c :id)) candidates))))
      (signal 'herdr-protocol-error '(:reason ambiguous-cleanup-resource-ids)))
    ;; A linked worktree is one resource, including all its terminals.
    (list :candidates candidates
          :protected
          (append
           (cl-remove-if
            (lambda (entry)
              (when-let* ((pane (herdr-model-find-pane session (car entry))))
                (member (herdr-pane-workspace-id pane) tree-owners)))
            (plist-get runtime :protected))
           (plist-get trees :protected)))))

(defun agent-fleet-cleanup--plan (selected context)
  "Build disjoint operations for SELECTED resources from CONTEXT."
  (append
   (agent-fleet-cleanup--runtime-plan
    (cl-remove-if (lambda (c) (eq (plist-get c :kind) 'worktree)) selected)
    (plist-get context :session))
   (cl-remove-if-not (lambda (c) (eq (plist-get c :kind) 'worktree)) selected)))

(defun agent-fleet-cleanup--preview-text (selected operations)
  "Describe SELECTED resources and exact OPERATIONS before confirmation."
  (concat
   (if (cl-some (lambda (c) (eq (plist-get c :kind) 'worktree)) selected)
       "WARNING: Selected worktree directories and their terminals will be deleted.\nPreserve wanted changes and unmerged/unpushed commits first. No force is used.\n"
     "Close selected terminals and their processes. No code directories will be deleted.\n")
   "\nSelected resources:\n"
   (mapconcat (lambda (c) (concat "  " (plist-get c :label))) selected "\n")
   "\n\nActions:\n"
   (mapconcat (lambda (op) (concat "  " (plist-get op :label))) operations "\n")
   "\n\nUnselected terminals are preserved. Task records update only after acknowledged cleanup.\n"))

(defun agent-fleet-cleanup--execute (context report operations)
  "Execute approved OPERATIONS from CONTEXT, extending REPORT with results.
Revalidate the original identities, not a newly broadened selection."
  (let ((connection (plist-get context :connection)) closed failed)
    (dolist (operation operations)
      (condition-case err
          (let* ((fresh (agent-fleet-cleanup--context connection))
                 (worktree (eq (plist-get operation :kind) 'worktree)))
            (agent-fleet-cleanup--recheck operation fresh worktree)
            (agent-fleet-cleanup--check-connection connection)
            (if worktree
                (progn
                  (require 'agent-fleet-worktree)
                  (agent-fleet-worktree-remove (plist-get operation :id)))
              (let* ((method (plist-get operation :method))
                     (key (pcase method ("workspace.close" 'workspace_id)
                                 ("tab.close" 'tab_id) (_ 'pane_id))))
                (herdr-protocol-validate-ok
                 (herdr-request method (list (cons key (plist-get operation :id))))
                 method)))
            ;; These are independently acknowledged resource obligations.
            (push (plist-get operation :id) closed)
            (when (fboundp 'agent-fleet-task-cleanup-record)
              (agent-fleet-task-cleanup-record
               (and worktree (plist-get operation :id))
               (mapcar #'car (plist-get operation :panes)))))
        (error (push (cons (plist-get operation :id) err) failed))))
    (append report (list :closed (nreverse closed) :failed (nreverse failed)))))

(defun agent-fleet-cleanup--run (project task targets select no-confirm)
  "Inspect or clean resources for PROJECT, TASK and TARGETS.
SELECT opens the resource buffer.  NO-CONFIRM is only for explicit Lisp targets."
  (agent-fleet--ensure-connected)
  (when project
    (setq project (or (agent-fleet-project-root-for-cwd project)
                      (user-error "Cleanup requires a resolvable Project"))))
  (let* ((context (agent-fleet-cleanup--context (herdr-connection)))
         (report (agent-fleet-cleanup--report context project task))
         (candidates (plist-get report :candidates)))
    (if select
        (agent-fleet-cleanup--open context report project task)
      (let* ((selected
              (mapcar
               (lambda (id)
                 (let ((matches (cl-remove-if-not
                                 (lambda (c) (equal id (plist-get c :id))) candidates)))
                   (unless (= (length matches) 1)
                     (user-error "Ineligible or ambiguous cleanup target: %s" id))
                   (car matches)))
               (delete-dups (copy-sequence targets))))
             (operations (agent-fleet-cleanup--plan selected context))
             (use-short-answers nil))
        (cond
         ((null operations) report)
         ((or no-confirm
              (yes-or-no-p (concat (agent-fleet-cleanup--preview-text selected operations)
                                   "\nProceed? ")))
          (agent-fleet-cleanup--execute context report operations))
         (t (append report (list :cancelled t))))))))

;;; Resource selection / preview / result buffer

(defvar-local agent-fleet-cleanup--view-context nil)
(defvar-local agent-fleet-cleanup--view-report nil)
(defvar-local agent-fleet-cleanup--view-selected nil)
(defvar-local agent-fleet-cleanup--view-operations nil)
(defvar-local agent-fleet-cleanup--view-project nil)
(defvar-local agent-fleet-cleanup--view-task nil)
(defvar-local agent-fleet-cleanup--view-phase 'select)

(defvar agent-fleet-cleanup-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "SPC") #'agent-fleet-cleanup-toggle)
    (define-key map (kbd "RET") #'agent-fleet-cleanup-continue)
    (define-key map (kbd "n") #'agent-fleet-cleanup-next)
    (define-key map (kbd "p") #'agent-fleet-cleanup-previous)
    (define-key map (kbd "g") #'agent-fleet-cleanup-refresh)
    (define-key map (kbd "b") #'agent-fleet-cleanup-back)
    (define-key map (kbd "<escape>") #'agent-fleet-cleanup-back)
    map)
  "Local keys for explicit resource cleanup.")

(define-derived-mode agent-fleet-cleanup-mode special-mode "Fleet-Cleanup"
  "Select resources with SPC, preview with RET, then confirm with RET.
Use n/p to navigate, b or Escape to go back, g to refresh, and q to quit.")

(defun agent-fleet-cleanup--position (id)
  "Return the start of resource ID in the current buffer, or nil."
  (let ((pos (point-min)))
    (while (and (< pos (point-max))
                (not (equal id (get-text-property pos 'agent-fleet-cleanup-resource))))
      (setq pos (next-single-property-change pos 'agent-fleet-cleanup-resource
                                             nil (point-max))))
    (and (< pos (point-max)) pos)))

(defun agent-fleet-cleanup--render ()
  "Render the current cleanup step without changing the approved identities."
  (let ((inhibit-read-only t)
        (old-id (get-text-property (point) 'agent-fleet-cleanup-resource)))
    (erase-buffer)
    (insert (format "Agent Fleet / Cleanup / %s\n\n"
                    agent-fleet-cleanup--view-phase))
    (pcase agent-fleet-cleanup--view-phase
      ('select
       (insert (format "Selected: %d    SPC mark   RET preview   n/p move   g refresh   q quit\n\n"
                       (length agent-fleet-cleanup--view-selected)))
       (dolist (c (plist-get agent-fleet-cleanup--view-report :candidates))
         (let ((id (plist-get c :id)))
           (insert (propertize
                    (format "[%s] [%s] %s\n\n"
                            (if (member id agent-fleet-cleanup--view-selected) "x" " ")
                            (if (eq (plist-get c :kind) 'worktree) "Worktree" "Runtime")
                            (plist-get c :label))
                    'agent-fleet-cleanup-resource id))))
       (unless (plist-get agent-fleet-cleanup--view-report :candidates)
         (insert "No eligible resources.\n\n"))
       (insert "Protected (not selectable):\n")
       (dolist (entry (plist-get agent-fleet-cleanup--view-report :protected))
         (insert (format "  %s: %s\n" (car entry) (cdr entry)))))
      ('preview
       (insert (agent-fleet-cleanup--preview-text
                (cl-remove-if-not
                 (lambda (c) (member (plist-get c :id) agent-fleet-cleanup--view-selected))
                 (plist-get agent-fleet-cleanup--view-report :candidates))
                agent-fleet-cleanup--view-operations))
       (insert "\nRET confirm    b / Escape return to selection    q cancel\n"))
      ('result
       (dolist (id (plist-get agent-fleet-cleanup--view-report :closed))
         (insert (format "OK    %s\n" (agent-fleet-cleanup--result-label id))))
       (dolist (entry (plist-get agent-fleet-cleanup--view-report :failed))
         (insert (format "FAILED %s: %s\n" (agent-fleet-cleanup--result-label (car entry))
                         (error-message-string (cdr entry)))))
       (insert (format "\n%d protected resource(s). Failed resources retain retry information.\n"
                       (length (plist-get agent-fleet-cleanup--view-report :protected))))
       (insert "RET / g reload resources    q close\n")))
    (goto-char (or (and old-id (agent-fleet-cleanup--position old-id))
                   (point-min)))))

(defun agent-fleet-cleanup--result-label (id)
  "Describe result ID using the approved operation rather than container IDs."
  (or (plist-get (cl-find id agent-fleet-cleanup--view-operations
                          :key (lambda (op) (plist-get op :id)) :test #'equal) :label)
      id))

(defun agent-fleet-cleanup--open (context report project task)
  "Open resource selection for CONTEXT and REPORT with PROJECT/TASK filters."
  (let ((buffer (get-buffer-create "*Agent Fleet Cleanup*")))
    (with-current-buffer buffer
      (agent-fleet-cleanup-mode)
      (setq agent-fleet-cleanup--view-context context
            agent-fleet-cleanup--view-report report
            agent-fleet-cleanup--view-project project
            agent-fleet-cleanup--view-task task)
      (agent-fleet-cleanup--render))
    ;; Replace this window; never split or resize an attached terminal.
    (switch-to-buffer buffer)
    buffer))

(defun agent-fleet-cleanup-toggle ()
  "Toggle the resource at point; protected resources cannot be selected."
  (interactive)
  (unless (eq agent-fleet-cleanup--view-phase 'select)
    (user-error "Return to resource selection first"))
  (let ((id (get-text-property (point) 'agent-fleet-cleanup-resource)))
    (unless id (user-error "No selectable resource at point"))
    (setq agent-fleet-cleanup--view-selected
          (if (member id agent-fleet-cleanup--view-selected)
              (delete id agent-fleet-cleanup--view-selected)
            (append agent-fleet-cleanup--view-selected (list id))))
    (agent-fleet-cleanup--render)))

(defun agent-fleet-cleanup-next ()
  "Move to the next selectable resource."
  (interactive)
  (let* ((property 'agent-fleet-cleanup-resource)
         (pos (next-single-property-change (point) property nil (point-max))))
    (while (and (< pos (point-max)) (null (get-text-property pos property)))
      (setq pos (next-single-property-change pos property nil (point-max))))
    (goto-char pos)))

(defun agent-fleet-cleanup-previous ()
  "Move to the previous selectable resource."
  (interactive)
  (let* ((property 'agent-fleet-cleanup-resource)
         (pos (point)))
    (while (and (> pos (point-min))
                (equal (get-text-property (1- pos) property)
                       (get-text-property (point) property)))
      (setq pos (previous-single-property-change pos property nil (point-min))))
    (while (and (> pos (point-min)) (null (get-text-property (1- pos) property)))
      (setq pos (previous-single-property-change pos property nil (point-min))))
    (when (> pos (point-min))
      (goto-char (previous-single-property-change pos property nil (point-min))))))

(defun agent-fleet-cleanup-continue ()
  "Preview selections, confirm approved operations, or reload results."
  (interactive)
  (pcase agent-fleet-cleanup--view-phase
    ('select
     (unless agent-fleet-cleanup--view-selected (user-error "Select resources first"))
     (setq agent-fleet-cleanup--view-operations
           (agent-fleet-cleanup--plan
            (cl-remove-if-not
             (lambda (c) (member (plist-get c :id) agent-fleet-cleanup--view-selected))
             (plist-get agent-fleet-cleanup--view-report :candidates))
            agent-fleet-cleanup--view-context)
           agent-fleet-cleanup--view-phase 'preview)
     (agent-fleet-cleanup--render))
    ('preview
     (let ((use-short-answers nil))
       (when (yes-or-no-p
              (if (cl-some (lambda (op) (eq (plist-get op :kind) 'worktree))
                           agent-fleet-cleanup--view-operations)
                  "Delete the worktree directories shown above and close selected terminals? "
                "Close selected terminals and processes (no code directories deleted)? "))
         (setq agent-fleet-cleanup--view-report
               (agent-fleet-cleanup--execute agent-fleet-cleanup--view-context
                                             agent-fleet-cleanup--view-report
                                             agent-fleet-cleanup--view-operations)
               agent-fleet-cleanup--view-phase 'result)
         (agent-fleet-cleanup--render))))
    ('result (agent-fleet-cleanup-refresh))))

(defun agent-fleet-cleanup-refresh ()
  "Fetch fresh resources, clearing all selections and previous approvals."
  (interactive)
  (agent-fleet-cleanup--check-connection
   (plist-get agent-fleet-cleanup--view-context :connection))
  (let* ((context (agent-fleet-cleanup--context (herdr-connection)))
         (task agent-fleet-cleanup--view-task)
         (report (if (and task
                          (not (agent-fleet-task-find
                                (if (stringp task) task (agent-fleet-task-id task)))))
                     (list :candidates nil :protected nil)
                   (agent-fleet-cleanup--report context agent-fleet-cleanup--view-project task))))
    (setq agent-fleet-cleanup--view-context context
          agent-fleet-cleanup--view-report report
          agent-fleet-cleanup--view-selected nil
          agent-fleet-cleanup--view-operations nil
          agent-fleet-cleanup--view-phase 'select)
    (agent-fleet-cleanup--render)))

(defun agent-fleet-cleanup-back ()
  "Return to selection, reload results, or leave without executing cleanup."
  (interactive)
  (pcase agent-fleet-cleanup--view-phase
    ('preview
     (setq agent-fleet-cleanup--view-phase 'select
           agent-fleet-cleanup--view-operations nil)
     (agent-fleet-cleanup--render))
    ('result (agent-fleet-cleanup-refresh))
    (_ (quit-window))))

;;;###autoload
(cl-defun agent-fleet-cleanup (&key project task targets select no-confirm)
  "Select runtime resources and worktrees in one cleanup workflow.
Interactively choose a scope, mark resources with SPC, preview with RET,
then confirm with RET.  Task is an Emacs-side filter, not a Herdr resource.
No resources are selected by default.  No force is sent for worktree removal.
From Lisp, TARGETS contains candidate IDs: pane IDs for runtime resources,
hosting Workspace IDs for worktrees.  Omit TARGETS for a read-only report.
SELECT opens the resource buffer and always requires explicit confirmation;
NO-CONFIRM applies only to explicit Lisp targets.  Return the report with
:candidates, :protected, :closed and :failed, or the opened selection buffer."
  (interactive (append (agent-fleet-cleanup--read-filter) (list :select t)))
  (agent-fleet-cleanup--run project task targets select no-confirm))

(provide 'agent-fleet-cleanup)
;;; agent-fleet-cleanup.el ends here
