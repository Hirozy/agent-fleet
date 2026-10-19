;;; agent-fleet-cleanup.el --- Explicit resource cleanup -*- lexical-binding: t; -*-

;; Copyright (C) 2026 agent-fleet contributors
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Reclaim only resources proven unrelated to agents.  Agent presence, not
;; completion status, is the protection boundary.  Worktrees require manual review.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-fleet)
(require 'agent-fleet-project)

(declare-function agent-fleet-task-list "agent-fleet-parallel")
(declare-function agent-fleet-task-find "agent-fleet-parallel")
(declare-function agent-fleet-task-agents "agent-fleet-parallel")
(declare-function agent-fleet-task-workspaces "agent-fleet-parallel")

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
  "Whether WS-ID has linked or unclassified worktree evidence.
A known primary checkout never blocks runtime cleanup merely for being Git."
  (or (cl-find-if
       (lambda (wt) (and (equal ws-id (herdr-worktree-open-workspace-id wt))
                         (not (herdr-model-worktree-primary-p wt))))
       (plist-get context :worktrees))
      (cl-find-if
       (lambda (wt) (and (equal ws-id (herdr-worktree-open-workspace-id wt))
                         (not (herdr-model-worktree-primary-p wt))))
       (herdr-model-worktrees))
      (memq (herdr-model-workspace-worktree-linkage
             (herdr-model-find-workspace (plist-get context :session) ws-id))
            '(linked unknown))
      (memq (herdr-model-workspace-worktree-linkage
             (herdr-model-find-workspace ws-id)) '(linked unknown))))

(defun agent-fleet-cleanup--workspace-panes (ws session)
  "Return panes belonging to WS in SESSION."
  (cl-remove-if-not (lambda (p) (equal ws (herdr-pane-workspace-id p)))
                    (herdr-model-panes session)))

(defun agent-fleet-cleanup--known-id-p (id)
  "Whether ID establishes a usable ownership identity."
  (and (stringp id) (not (string-empty-p id))))

(defun agent-fleet-cleanup--task-owned-p (ws session)
  "Whether any task still associates WS with agent work in SESSION."
  (when (fboundp 'agent-fleet-task-list)
    (cl-some
     (lambda (task)
       (or (rassoc ws (agent-fleet-task-workspaces task))
           (cl-some
            (lambda (id)
              (let* ((pane (herdr-model-find-pane session id))
                     (agent (herdr-model-find-agent session id))
                     (owner (or (and agent (herdr-agent-workspace-id agent))
                                (and pane (herdr-pane-workspace-id pane)))))
                (or (equal ws owner)
                    (and (not (agent-fleet-cleanup--known-id-p owner))
                         (not (assoc id (agent-fleet-task-workspaces task)))))))
            (agent-fleet-task-agents task))))
     (agent-fleet-task-list))))

(defun agent-fleet-cleanup--workspace-reason (ws context)
  "Return why all resources in WS must be preserved in CONTEXT.
An agent is protected in every status, including done.  Positive live
evidence vetoes an older snapshot, including evidence on sibling panes."
  (let* ((session (plist-get context :session))
         (live (herdr-model-cache))
         (panes (agent-fleet-cleanup--workspace-panes ws session))
         (live-panes
          (and live
               (cl-remove-if-not
                (lambda (p)
                  (or (not (agent-fleet-cleanup--known-id-p (herdr-pane-workspace-id p)))
                      (equal ws (herdr-pane-workspace-id p))
                      (cl-find (herdr-pane-id p) panes :key #'herdr-pane-id :test #'equal)))
                (herdr-model-panes live)))))
    (cond
     ((or (cl-some (lambda (agent)
                    (or (not (agent-fleet-cleanup--known-id-p (herdr-agent-workspace-id agent)))
                        (equal ws (herdr-agent-workspace-id agent))
                        (cl-find (herdr-agent-id agent) panes :key #'herdr-pane-id :test #'equal)))
                   (append (herdr-model-agents session)
                           (and live (herdr-model-agents live))))
          (cl-some (lambda (p) (or (herdr-pane-agent p)
                                   (herdr-pane-agent-session p)))
                   (append panes live-panes)))
      "Agent-associated workspace; all agent states are protected")
     ((or (agent-fleet-cleanup--task-owned-p ws session)
          (and live (agent-fleet-cleanup--task-owned-p ws live)))
      "Task association remains; missing agents are not completion evidence")
     ((agent-fleet-cleanup--worktree-p ws context)
      "Linked or unclassified worktree; preserve code and review manually")
     ((or (null panes)
          (cl-some (lambda (p)
                     (or (not (stringp (herdr-pane-terminal-id p)))
                         (string-empty-p (herdr-pane-terminal-id p))
                         (and live
                              (gethash (herdr-pane-id p)
                                       (herdr-session-gone-panes live)))))
                   panes))
      "Missing or uncertain terminal identity; refresh before cleanup"))))

(defun agent-fleet-cleanup--signature (pane session)
  "Return the identity and ownership approved for PANE in SESSION."
  (let ((agent (herdr-model-find-agent session (herdr-pane-id pane))))
    (list (herdr-pane-id pane) (herdr-pane-terminal-id pane)
          (herdr-pane-workspace-id pane) (herdr-pane-tab-id pane)
          (herdr-pane-cwd pane)
          (and agent (herdr-agent-agent agent))
          (and agent (herdr-agent-name agent)))))


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

(defun agent-fleet-cleanup--pane-label (pane _session)
  "Describe the agent-free PANE without implying its processes are disposable."
  (format "shell/other processes | %s [%s]"
          (or (herdr-pane-cwd pane) "cwd unknown") (herdr-pane-id pane)))

(defun agent-fleet-cleanup--agent-ids (session)
  "Return identities with agent evidence in SESSION."
  (when session
    (append (mapcar #'herdr-agent-id (herdr-model-agents session))
            (mapcar #'herdr-pane-id
                    (cl-remove-if-not
                     (lambda (p) (or (herdr-pane-agent p) (herdr-pane-agent-session p)))
                     (herdr-model-panes session))))))

(defun agent-fleet-cleanup--report (context project task)
  "Report safe runtime candidates and protected resources from CONTEXT.
PROJECT and TASK are Lisp-only filters.  No directory deletion is authorized:
worktree metadata does not prove changes and commits have been preserved."
  (let* ((session (plist-get context :session))
         (scope (agent-fleet-cleanup--scope-ids session project task))
         candidates protected)
    (dolist (workspace (herdr-model-workspaces session))
      (let* ((ws (herdr-workspace-id workspace))
             (panes (agent-fleet-cleanup--workspace-panes ws session))
             (reason (agent-fleet-cleanup--workspace-reason ws context)))
        (when (or (eq scope t)
                  (cl-some (lambda (p) (member (herdr-pane-id p) scope)) panes))
          (if reason
              (push (cons ws reason) protected)
            (dolist (pane panes)
              (when (or (eq scope t) (member (herdr-pane-id pane) scope))
                (push (list :id (herdr-pane-id pane) :kind 'runtime :workspace ws
                            :panes (list (agent-fleet-cleanup--signature pane session))
                            :label (agent-fleet-cleanup--pane-label pane session))
                      candidates)))))))
    (dolist (wt (plist-get context :worktrees))
      (unless (herdr-model-worktree-primary-p wt)
        (push (cons (herdr-worktree-path wt)
                    "Directory and commit preservation not proven; manual review required")
              protected)))
    (list :candidates (nreverse candidates) :protected (nreverse protected)
          :preserved-agents
          (length (delete-dups
                   (append (agent-fleet-cleanup--agent-ids session)
                           (agent-fleet-cleanup--agent-ids (herdr-model-cache))))))))

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
                        :workspace-panes (mapcar (lambda (p) (agent-fleet-cleanup--signature p session)) ws-panes)
                        :label (format "%s %s: %s"
                                       (cond (whole-ws "Workspace") (whole-tab "Tab") (t "Terminal"))
                                       target
                                       (mapconcat (lambda (p)
                                                    (format "%s [%s]" (or (herdr-pane-cwd p) "cwd unknown")
                                                            (herdr-pane-id p)))
                                                  panes "; ")))
                  result)))))
    (nreverse result)))

(defun agent-fleet-cleanup--same-panes-p (left right)
  "Whether LEFT and RIGHT contain exactly the same approved identities."
  (equal (sort (copy-sequence left) (lambda (a b) (string< (car a) (car b))))
         (sort (copy-sequence right) (lambda (a b) (string< (car a) (car b))))))

(defun agent-fleet-cleanup--recheck (operation context)
  "Require OPERATION and its whole workspace to remain safe in CONTEXT."
  (let* ((session (plist-get context :session))
         (ws (plist-get operation :workspace))
         (panes (agent-fleet-cleanup--workspace-panes ws session))
         (approved (plist-get operation :workspace-panes)))
    (when-let* ((reason (agent-fleet-cleanup--workspace-reason ws context)))
      (user-error "%s: %s" ws reason))
    (unless (and panes
                 (agent-fleet-cleanup--same-panes-p
                  approved (mapcar (lambda (p) (agent-fleet-cleanup--signature p session)) panes)))
      (user-error "Workspace membership or identity changed; run cleanup again"))
    (when (herdr-model-cache)
      (dolist (pane (agent-fleet-cleanup--workspace-panes ws (herdr-model-cache)))
        (unless (member (agent-fleet-cleanup--signature pane (herdr-model-cache)) approved)
          (user-error "Newer terminal identity or membership in live cache"))))))

(defun agent-fleet-cleanup--summary (report operations)
  "Describe exact OPERATIONS and preserved resources in REPORT."
  (concat
   (format "Cleanup: %d target(s); preserve %d agent(s); %d protected.\n"
           (length operations) (plist-get report :preserved-agents)
           (length (plist-get report :protected)))
   "Shells and other processes will terminate. No code directories deleted.\n"
   (mapconcat (lambda (op) (plist-get op :label)) operations "\n")))

(defun agent-fleet-cleanup--execute (context report operations)
  "Execute only approved OPERATIONS, rechecking each against fresh state."
  (let ((connection (plist-get context :connection)) closed failed skipped)
    (dolist (operation operations)
      (condition-case err
          (let ((fresh (agent-fleet-cleanup--context connection)))
            (agent-fleet-cleanup--recheck operation fresh)
            (agent-fleet-cleanup--check-connection connection)
            (let* ((method (plist-get operation :method))
                   (key (pcase method
                          ("workspace.close" 'workspace_id)
                          ("tab.close" 'tab_id)
                          ("pane.close" 'pane_id)
                          (_ (error "Unsupported cleanup operation")))))
              (herdr-protocol-validate-ok
               (herdr-request method (list (cons key (plist-get operation :id))))
               method))
            (push (plist-get operation :id) closed))
        (user-error (push (cons (plist-get operation :id) err) skipped))
        (error (push (cons (plist-get operation :id) err) failed))))
    (append report (list :closed (nreverse closed) :failed (nreverse failed)
                         :skipped (nreverse skipped)))))

(defun agent-fleet-cleanup--result-message (report)
  "Report cleanup results through messages only, without opening a view."
  (dolist (entry (plist-get report :protected))
    (message "Cleanup preserved %s: %s" (car entry) (cdr entry)))
  (dolist (id (plist-get report :closed)) (message "Cleanup closed: %s" id))
  (dolist (key '(:skipped :failed))
    (dolist (entry (plist-get report key))
      (message "Cleanup %s %s: %s" key (car entry) (error-message-string (cdr entry)))))
  (message "Cleanup: %d closed; %d agents preserved at scan; %d protected; %d skipped; %d failed"
           (length (plist-get report :closed)) (plist-get report :preserved-agents)
           (length (plist-get report :protected)) (length (plist-get report :skipped))
           (length (plist-get report :failed))))

(defun agent-fleet-cleanup--run (project task targets select no-confirm)
  "Inspect or clean agent-unrelated resources, with at most one confirmation.
PROJECT and TASK filter Lisp calls; TARGETS are explicit pane IDs.  SELECT
scans all eligible resources and never bypasses confirmation via NO-CONFIRM."
  (agent-fleet--ensure-connected)
  (when project
    (setq project (or (agent-fleet-project-root-for-cwd project)
                      (user-error "Cleanup requires a resolvable Project"))))
  (let* ((context (agent-fleet-cleanup--context (herdr-connection)))
         (report (agent-fleet-cleanup--report context project task))
         (candidates (plist-get report :candidates))
         (selected (if select candidates
                     (mapcar (lambda (id)
                               (or (cl-find id candidates :key (lambda (c) (plist-get c :id))
                                            :test #'equal)
                                   (user-error "Protected or unknown cleanup target: %s" id)))
                             (delete-dups (copy-sequence targets)))))
         (operations (agent-fleet-cleanup--runtime-plan selected (plist-get context :session)))
         (use-short-answers nil))
    (cond
     ((null operations)
      (when select
        (dolist (entry (plist-get report :protected))
          (message "Cleanup preserved %s: %s" (car entry) (cdr entry)))
        (message "No resources can be safely cleaned; %d agents preserved"
                 (plist-get report :preserved-agents)))
      report)
     ((or (and no-confirm (not select))
          (let ((summary (agent-fleet-cleanup--summary report operations)))
            ;; Retain the full exact-target summary even if the minibuffer is small.
            (dolist (entry (plist-get report :protected))
              (message "Cleanup preserved %s: %s" (car entry) (cdr entry)))
            (message "%s" summary)
            (yes-or-no-p (concat summary "\nProceed with cleanup? "))))
      (let ((result (agent-fleet-cleanup--execute context report operations)))
        (when select (agent-fleet-cleanup--result-message result))
        result))
     (t
      (when select (message "Cleanup cancelled; no resources changed"))
      (append report (list :cancelled t))))))

;;;###autoload
(cl-defun agent-fleet-cleanup (&key project task targets select no-confirm)
  "Clean only resources unrelated to any agent, regardless of agent status.
Interactively scan all resources, confirm one exact-target summary, and
report via messages.  No menus or result buffers are opened.  All resources
in agent-associated workspaces are protected, including siblings of done
agents.  Worktrees are skipped: code and commit preservation is not proven.
From Lisp, omit TARGETS for a read-only report; PROJECT and TASK are optional
filters and TARGETS contains eligible runtime pane IDs.  SELECT scans all
eligible resources and always confirms.  NO-CONFIRM applies only to explicit
Lisp targets.  Return :candidates, :protected, :preserved-agents and, after
execution, :closed, :skipped and :failed.  Cancellation adds :cancelled."
  (interactive (list :select t))
  (agent-fleet-cleanup--run project task targets select no-confirm))

(provide 'agent-fleet-cleanup)
;;; agent-fleet-cleanup.el ends here
