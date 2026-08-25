;;; agent-fleet-interactive-test.el --- Interactive command regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; This file exercises every command through `call-interactively'.  The
;; inventory test is deliberately closed-world: adding a new interactive
;; command to one of the package source files without registering a regression
;; test here fails the suite.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr)
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'agent-fleet-worktree)
(require 'agent-fleet-magit)
(require 'agent-fleet-parallel)
(require 'agent-fleet-attach)
(require 'agent-fleet-dashboard)


;;; --- Inventory -------------------------------------------------------

(defconst agent-fleet-interactive-test--file
  (let ((loaded (or load-file-name buffer-file-name)))
    (if (and loaded (string-suffix-p ".elc" loaded))
        (substring loaded 0 -1)
      loaded))
  "Source path of this test, used to audit its ERT forms.")

(defconst agent-fleet-interactive-test--source-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory agent-fleet-interactive-test--file)))
  "Repository directory containing the package source files.")

(defconst agent-fleet-interactive-test--coverage
  '((herdr-connect . agent-fleet-interactive-herdr-lifecycle)
    (herdr-disconnect . agent-fleet-interactive-herdr-lifecycle)
    (herdr-doctor . agent-fleet-interactive-doctors)
    (agent-fleet-start . agent-fleet-interactive-start)
    (agent-fleet-prompt . agent-fleet-interactive-prompt-family)
    (agent-fleet-prompt-and-wait . agent-fleet-interactive-prompt-family)
    (agent-fleet-read . agent-fleet-interactive-read-wait-and-input)
    (agent-fleet-wait . agent-fleet-interactive-read-wait-and-input)
    (agent-fleet-send-keys . agent-fleet-interactive-read-wait-and-input)
    (agent-fleet-interrupt . agent-fleet-interactive-read-wait-and-input)
    (agent-fleet-rename . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-kill . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-switch . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-list . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-show-output . agent-fleet-interactive-output-viewer)
    (agent-fleet-doctor . agent-fleet-interactive-doctors)
    (agent-fleet-start-for-project . agent-fleet-interactive-project-start)
    (agent-fleet-worktree-list . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-open . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-remove . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-status . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-cleanup . agent-fleet-interactive-worktrees)
    (agent-fleet-magit-status . agent-fleet-interactive-magit)
    (agent-fleet-magit-diff . agent-fleet-interactive-magit)
    (agent-fleet-parallel . agent-fleet-interactive-parallel)
    (agent-fleet-task-wait . agent-fleet-interactive-task-commands)
    (agent-fleet-task-cleanup . agent-fleet-interactive-task-commands)
    (agent-fleet-attach . agent-fleet-interactive-attach)
    (agent-fleet-mode . agent-fleet-interactive-dashboard-entry-and-mode)
    (agent-fleet . agent-fleet-interactive-dashboard-entry-and-mode)
    (agent-fleet-dashboard-open-buffer . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard-open-child-frame . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard-open-frame . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard-quit . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard-refresh . agent-fleet-interactive-dashboard-refresh-and-filters)
    (agent-fleet-dashboard-toggle-project-filter . agent-fleet-interactive-dashboard-refresh-and-filters)
    (agent-fleet-dashboard-toggle-task-filter . agent-fleet-interactive-dashboard-refresh-and-filters)
    (agent-fleet-dashboard-help . agent-fleet-interactive-dashboard-help)
    (agent-fleet-dashboard-inspect . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-prompt . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-interrupt . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-kill . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-rename . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-worktree . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-diff . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-magit . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-attach . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard-new . agent-fleet-interactive-dashboard-row-actions))
  "Alist mapping every package command to its interactive regression test.")

(defun agent-fleet-interactive-test--read-forms (file)
  "Read and return all top-level Lisp forms in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file))
      (nreverse forms))))

(defun agent-fleet-interactive-test--contains-interactive-p (form)
  "Return non-nil when FORM contains an `(interactive ...)' form."
  (and (consp form)
       (or (eq (car form) 'interactive)
           (agent-fleet-interactive-test--contains-interactive-p (car form))
           (agent-fleet-interactive-test--contains-interactive-p (cdr form)))))

(defun agent-fleet-interactive-test--commands ()
  "Return every command declared in every package source file.
This parses files rather than scanning loaded symbols, so a newly added
module cannot evade the inventory merely because no existing module requires
it yet."
  (let ((files (directory-files
                agent-fleet-interactive-test--source-directory t
                "\\`\\(?:agent-fleet\\|herdr\\).*\\.el\\'"))
        commands)
    (dolist (file files)
      (dolist (form (agent-fleet-interactive-test--read-forms file))
        (pcase (car-safe form)
          ((or 'defun 'cl-defun)
           (when (agent-fleet-interactive-test--contains-interactive-p form)
             (push (cadr form) commands)))
          ((or 'define-derived-mode 'define-minor-mode
               'define-globalized-minor-mode 'transient-define-prefix)
           (push (cadr form) commands)))))
    (sort (delete-dups commands)
          (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun agent-fleet-interactive-test--calls-in-form (form)
  "Return commands invoked by `call-interactively' within FORM."
  (let (commands)
    (when (consp form)
      (when (and (eq (car form) 'call-interactively)
                 (consp (cadr form))
                 (eq (caadr form) 'function)
                 (symbolp (cadadr form)))
        (push (cadadr form) commands))
      (setq commands
            (nconc commands
                   (agent-fleet-interactive-test--calls-in-form (car form))
                   (agent-fleet-interactive-test--calls-in-form (cdr form)))))
    commands))

(defun agent-fleet-interactive-test--test-calls ()
  "Return an alist mapping ERT names to interactively invoked commands."
  (let (result)
    (dolist (form (agent-fleet-interactive-test--read-forms
                   agent-fleet-interactive-test--file))
      (when (eq (car-safe form) 'ert-deftest)
        (push (cons (cadr form)
                    (delete-dups
                     (agent-fleet-interactive-test--calls-in-form form)))
              result)))
    result))

(ert-deftest agent-fleet-interactive-command-inventory ()
  "Every package command is registered and points to a real ERT test."
  (let ((actual (agent-fleet-interactive-test--commands))
        (registered (sort (mapcar #'car agent-fleet-interactive-test--coverage)
                          (lambda (a b) (string< (symbol-name a)
                                                (symbol-name b)))))
        (test-calls (agent-fleet-interactive-test--test-calls)))
    (should (equal actual registered))
    (dolist (entry agent-fleet-interactive-test--coverage)
      (should (commandp (car entry)))
      (should (ert-test-boundp (cdr entry)))
      (should (memq (car entry) (alist-get (cdr entry) test-calls))))))


;;; --- Shared state ----------------------------------------------------

(defun agent-fleet-interactive-test--session (&optional status)
  "Return a small cache with one named agent and one cached worktree."
  (let* ((session (herdr-model--empty-session))
         (workspace (make-herdr-workspace :id "w1" :cached-label "demo"
                                          :custom-name "demo"))
         (pane (make-herdr-pane :id "w1:p1" :workspace-id "w1"
                                :tab-id "w1:t1" :cwd "/tmp"
                                :agent "claude"
                                :agent-status (or status "working")))
         (agent (make-herdr-agent :id "w1:p1" :workspace-id "w1"
                                  :tab-id "w1:t1" :cwd "/tmp"
                                  :name "arch" :agent "claude"
                                  :agent-status (or status "working")))
         (worktree (make-herdr-worktree :path "/tmp/agent-wt"
                                        :open-workspace-id "w1")))
    (setf (herdr-session-focused-workspace-id session) "w1"
          (herdr-session-focused-pane-id session) "w1:p1")
    (puthash "w1" workspace (herdr-session-workspaces session))
    (puthash "w1:p1" pane (herdr-session-panes session))
    (puthash "w1:p1" agent (herdr-session-agents session))
    (puthash "/tmp/agent-wt" worktree (herdr-session-worktrees session))
    session))

(defun agent-fleet-interactive-test--param (name params)
  "Return string-keyed NAME from raw request PARAMS."
  (alist-get name params nil nil #'equal))


;;; --- Herdr lifecycle + doctors --------------------------------------

(ert-deftest agent-fleet-interactive-herdr-lifecycle ()
  "Connect and disconnect run end-to-end through their interactive forms."
  (let ((herdr--conn nil)
        (herdr-model--cache nil)
        (herdr--resubscribe-timer nil)
        (herdr--resubscribe-pending nil)
        unsubscribed)
    (cl-letf (((symbol-function 'herdr-protocol-socket-path)
               (lambda () "/tmp/interactive-herdr.sock"))
              ((symbol-function 'herdr-protocol-ping)
               (lambda (&rest _) '(:protocol 20 :version "interactive")))
              ((symbol-function 'herdr-protocol-request)
               (lambda (&rest _) '(:snapshot t)))
              ((symbol-function 'herdr-model-parse-snapshot)
               (lambda (_) (agent-fleet-interactive-test--session)))
              ((symbol-function 'herdr--start-subscription)
               (lambda (conn)
                 (setf (herdr--connection-subscription-proc conn) 'sub)
                 'sub))
              ((symbol-function 'herdr-protocol-subscription-alive-p)
               (lambda (proc) (eq proc 'sub)))
              ((symbol-function 'herdr--await-subscription)
               (lambda (proc) (eq proc 'sub)))
              ((symbol-function 'herdr-protocol-unsubscribe)
               (lambda (proc) (setq unsubscribed proc))))
      (should (eq t (call-interactively #'herdr-connect)))
      (should (equal "/tmp/interactive-herdr.sock"
                     (herdr--connection-socket-path herdr--conn)))
      (call-interactively #'herdr-disconnect)
      (should (eq 'sub unsubscribed))
      (should-not herdr--conn)
      (should-not (herdr-model-cache)))))

(ert-deftest agent-fleet-interactive-doctors ()
  "Both doctor entry points gather checks and render their documented buffers."
  (let (renders)
    (cl-letf (((symbol-function 'herdr--doctor-checks)
               (lambda () '(("core" t "ok"))))
              ((symbol-function 'agent-fleet--doctor-agent-checks)
               (lambda () '(("agent" t "ok"))))
              ((symbol-function 'herdr--doctor-render)
               (lambda (checks buffer title)
                 (push (list checks buffer title) renders)
                 0)))
      (should (= 0 (call-interactively #'herdr-doctor)))
      (should (= 0 (call-interactively #'agent-fleet-doctor))))
    (let ((herdr-render
           (cl-find "*herdr-doctor*" renders :key #'cadr :test #'equal))
          (fleet-render
           (cl-find "*agent-fleet-doctor*" renders :key #'cadr :test #'equal)))
      (should (equal '(("core" t "ok")) (car herdr-render)))
      (should (equal '(("core" t "ok") ("agent" t "ok"))
                     (car fleet-render))))))


;;; --- Agent control commands -----------------------------------------

(ert-deftest agent-fleet-interactive-start ()
  "Interactive start reads kind/name and provisions with the selected values."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        (agent-fleet--name-counter 0)
        (agent-fleet-agent-started-hook nil)
        captured)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "codex"))
              ((symbol-function 'read-string)
               (lambda (&rest _) "reviewer"))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet--provision-pane)
               (lambda (&rest _) "w1:p2"))
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _)
                 (setq captured (list method params))
                 '(:type "agent_started"
                   :agent (:pane_id "w1:p2" :workspace_id "w1"
                           :name "reviewer" :agent "codex"
                           :agent_status "idle")))))
      (let ((agent (call-interactively #'agent-fleet-start)))
        (should (equal "reviewer" (herdr-agent-name agent)))
        (should (equal "codex" (herdr-agent-agent agent)))))
    (should (equal "agent.start" (car captured)))
    (should (equal "reviewer"
                   (agent-fleet-interactive-test--param
                    "name" (cadr captured))))
    (should (equal "codex"
                   (agent-fleet-interactive-test--param
                    "kind" (cadr captured))))))

(ert-deftest agent-fleet-interactive-prompt-family ()
  "Prompt and prompt-and-wait read the target/text and preserve wait semantics."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session)) calls)
    (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
               (lambda (_) "w1:p1"))
              ((symbol-function 'read-string)
               (lambda (&rest _) "do the work"))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest keys)
                 (push (list method params keys) calls)
                 '(:type "agent_prompted"
                   :agent (:pane_id "w1:p1" :workspace_id "w1"
                           :name "arch" :agent_status "done")))))
      (call-interactively #'agent-fleet-prompt)
      (call-interactively #'agent-fleet-prompt-and-wait))
    (should (= 2 (length calls)))
    (dolist (call calls)
      (should (equal "agent.prompt" (car call)))
      (should (equal "w1:p1"
                     (agent-fleet-interactive-test--param
                      "target" (cadr call))))
      (should (equal "do the work"
                     (agent-fleet-interactive-test--param
                      "text" (cadr call)))))
    (should (= 1 (cl-count-if
                  (lambda (call) (assoc "wait" (cadr call))) calls)))))

(ert-deftest agent-fleet-interactive-read-wait-and-input ()
  "Read/wait/send-keys/interrupt consume minibuffer input and dispatch correctly."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        shown calls)
    (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
               (lambda (_) "w1:p1"))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Keys" prompt) "enter" "unused")))
              ((symbol-function 'agent-fleet-show-output)
               (lambda (&rest args) (setq shown args) 'shown))
              ;; `called-interactively-p' only reports the command-loop
              ;; case, not a batch `call-interactively', so model that one
              ;; distinction explicitly while still exercising the real
              ;; interactive argument form.
              ((symbol-function 'called-interactively-p) (lambda (_) t))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _)
                 (push (list method params) calls)
                 '(:type "agent_info"
                   :agent (:pane_id "w1:p1" :agent_status "done")))))
      (should (eq 'shown (call-interactively #'agent-fleet-read)))
      (call-interactively #'agent-fleet-wait)
      (call-interactively #'agent-fleet-send-keys)
      (call-interactively #'agent-fleet-interrupt))
    (should (equal '("w1:p1" 120 recent_unwrapped) shown))
    (should (member "agent.wait" (mapcar #'car calls)))
    (should (= 2 (cl-count "agent.send_keys" calls :key #'car :test #'equal)))
    (should (cl-some (lambda (call)
                       (equal ["enter"]
                              (agent-fleet-interactive-test--param
                               "keys" (cadr call))))
                     calls))
    (should (cl-some (lambda (call)
                       (equal ["ctrl+c"]
                              (agent-fleet-interactive-test--param
                               "keys" (cadr call))))
                     calls))))

(ert-deftest agent-fleet-interactive-rename-kill-switch-list ()
  "Rename/kill/switch/list cover input, confirmation, cancellation and prefix refresh."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        calls confirm)
    (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
               (lambda (_) "w1:p1"))
              ((symbol-function 'read-string)
               (lambda (&rest _) "architect"))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) confirm))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _)
                 (push (list method params) calls)
                 (pcase method
                   ("agent.list"
                    '(:type "agent_list"
                      :agents ((:pane_id "w1:p1" :workspace_id "w1"
                                :name "arch" :agent "claude"
                                :agent_status "working"))))
                   ("pane.close" '(:ok t))
                   (_ '(:type "agent_info"
                        :agent (:pane_id "w1:p1" :workspace_id "w1"
                                :name "architect" :agent "claude"
                                :agent_status "working")))))))
      (call-interactively #'agent-fleet-rename)
      (call-interactively #'agent-fleet-switch)
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-fleet-list))
      (setq confirm nil)
      (should-error (call-interactively #'agent-fleet-kill) :type 'user-error)
      (should-not (member "pane.close" (mapcar #'car calls)))
      (setq confirm t)
      (call-interactively #'agent-fleet-kill))
    (should (member "agent.rename" (mapcar #'car calls)))
    (should (member "agent.focus" (mapcar #'car calls)))
    (should (member "agent.list" (mapcar #'car calls)))
    (should (member "pane.close" (mapcar #'car calls)))))

(ert-deftest agent-fleet-interactive-output-viewer ()
  "Show-output honors its prefix line count and builds a read-only snapshot buffer."
  (let* ((herdr-model--cache (agent-fleet-interactive-test--session))
         (buf-name "*Agent Output: arch*")
         captured)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
                   (lambda (_) "w1:p1"))
                  ((symbol-function 'read-number)
                   (lambda (&rest _) 7))
                  ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                  ((symbol-function 'agent-fleet-read)
                   (lambda (target &rest keys)
                     (setq captured (cons target keys))
                     '(:text "interactive output")))
                  ((symbol-function 'display-buffer) (lambda (&rest _) nil)))
          (let ((current-prefix-arg '(4)))
            (call-interactively #'agent-fleet-show-output))
          (should (equal "w1:p1" (car captured)))
          (should (= 7 (plist-get (cdr captured) :lines)))
          (with-current-buffer buf-name
            (should buffer-read-only)
            (should (equal "interactive output" (buffer-string)))))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))


;;; --- Project/worktree/Magit -----------------------------------------

(ert-deftest agent-fleet-interactive-project-start ()
  "Project start reads kind/name and delegates with the current project root."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session)) captured)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "claude"))
              ((symbol-function 'read-string) (lambda (&rest _) "project-agent"))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'project-current) (lambda (&rest _) 'project))
              ((symbol-function 'agent-fleet--project-root) (lambda (_) "/repo"))
              ((symbol-function 'agent-fleet--workspace-for-root) (lambda (_) "w1"))
              ((symbol-function 'agent-fleet-start)
               (lambda (&rest args)
                 (setq captured args)
                 (make-herdr-agent :id "w1:p2" :name "project-agent"))))
      (call-interactively #'agent-fleet-start-for-project))
    (should (eq 'claude (car captured)))
    (should (equal "project-agent" (plist-get (cdr captured) :name)))
    (should (equal "/repo" (plist-get (cdr captured) :cwd)))
    (should (equal "w1" (plist-get (cdr captured) :workspace)))))

(ert-deftest agent-fleet-interactive-worktrees ()
  "Every worktree command covers interactive path input, prefix and confirmation."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session "done"))
        fetches requests displayed)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'read-directory-name) (lambda (&rest _) "/repo"))
              ((symbol-function 'agent-fleet--read-agent-name) (lambda (_) "w1:p1"))
              ((symbol-function 'agent-fleet-worktree--fetch)
               (lambda (&optional cwd)
                 (push cwd fetches)
                 (cons (list (herdr-model-find-worktree-for-workspace "w1"))
                       '(:repo_name "repo"))))
              ((symbol-function 'agent-fleet-worktree--display)
               (lambda (&rest args) (setq displayed args)))
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _)
                 (push (list method params) requests)
                 (if (equal method "worktree.open")
                     '(:type "worktree_opened"
                       :workspace (:workspace_id "w2")
                       :root_pane (:pane_id "w2:p1")
                       :worktree (:path "/repo/wt" :open_workspace_id "w2")
                       :already_open :false)
                   '(:type "worktree_removed" :workspace_id "w1")))))
      (call-interactively #'agent-fleet-worktree-list)
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-fleet-worktree-list))
      (call-interactively #'agent-fleet-worktree-open)
      (call-interactively #'agent-fleet-worktree-status))
    (should (member nil fetches))
    (should (member "/repo" fetches))
    (should (member "worktree.open" (mapcar #'car requests)))
    (should displayed))
  ;; Remove must preserve the prefix as the wire-level force flag.
  (let ((herdr-model--cache (agent-fleet-interactive-test--session "done"))
        request)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet-worktree--workspace-choices)
               (lambda () '(("wt" . "w1"))))
              ((symbol-function 'completing-read) (lambda (&rest _) "wt"))
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _)
                 (setq request (list method params))
                 '(:type "worktree_removed" :workspace_id "w1"))))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-fleet-worktree-remove)))
    (should (equal "worktree.remove" (car request)))
    (should (eq t (agent-fleet-interactive-test--param
                   "force" (cadr request)))))
  ;; Cleanup delegates one non-forced removal and prefix skips confirmation.
  (let ((herdr-model--cache (agent-fleet-interactive-test--session "done"))
        removed asked)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq asked t) t))
              ((symbol-function 'agent-fleet-worktree-remove)
               (lambda (workspace &optional force)
                 (push (list workspace force) removed)
                 '(:ok t))))
      (let ((current-prefix-arg '(4)))
        (should (= 1 (call-interactively
                      #'agent-fleet-worktree-cleanup)))))
    (should (equal '(("w1" nil)) removed))
    (should-not asked)))

(ert-deftest agent-fleet-interactive-magit ()
  "Magit status/diff read the target and invoke public Magit entry points."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session)) calls)
    (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
               (lambda (_) "w1:p1"))
              ((symbol-function 'agent-fleet-magit--available-p) (lambda () t))
              ((symbol-function 'agent-fleet-magit--root-for-agent)
               (lambda (_) "/tmp"))
              ((symbol-function 'magit-status)
               (lambda (root) (push (list 'status root) calls)))
              ((symbol-function 'magit-diff-working-tree)
               (lambda (&rest _) (push (list 'diff default-directory) calls))))
      (call-interactively #'agent-fleet-magit-status)
      (call-interactively #'agent-fleet-magit-diff))
    (should (member '(status "/tmp") calls))
    (should (member '(diff "/tmp") calls))))


;;; --- Parallel/task/attach -------------------------------------------

(ert-deftest agent-fleet-interactive-parallel ()
  "Parallel reads title/kinds/prompt and starts one isolated agent per kind."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        (agent-fleet--tasks nil)
        (agent-fleet--agent-tasks (make-hash-table :test 'equal))
        (agent-fleet--name-counter 0)
        (agent-fleet--task-id-counter 0)
        starts prompts)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Task title" prompt) "review" "same prompt")))
              ((symbol-function 'completing-read-multiple)
               (lambda (&rest _) '("claude" "codex")))
              ((symbol-function 'agent-fleet-project-root-for-cwd)
               (lambda (_) "/tmp"))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet-start)
               (lambda (kind &rest keys)
                 (push (cons kind keys) starts)
                 (make-herdr-agent
                  :id (if (eq kind 'claude) "w2:p1" "w3:p1")
                  :agent (symbol-name kind) :agent-status "working")))
              ((symbol-function 'agent-fleet-prompt)
               (lambda (agent text)
                 (push (list (herdr-agent-id agent) text) prompts))))
      (let ((task (call-interactively #'agent-fleet-parallel)))
        (should (equal "review" (agent-fleet-task-title task)))
        (should (= 2 (length (agent-fleet-task-agents task))))))
    (should (= 2 (length starts)))
    (should (equal '(("w2:p1" "same prompt") ("w3:p1" "same prompt"))
                   (sort prompts (lambda (a b) (string< (car a) (car b))))))))

(ert-deftest agent-fleet-interactive-task-commands ()
  "Task wait resolves by agent; cleanup honors prefix and errors with no tasks."
  (let* ((herdr-model--cache (agent-fleet-interactive-test--session "done"))
         (done-task (make-agent-fleet-task :id "task-done" :title "done"
                                           :agents '("w1:p1")
                                           :finished-at 1.0))
         (running-task (make-agent-fleet-task :id "task-run" :title "running"
                                              :agents nil))
         (agent-fleet--tasks (list running-task done-task))
         (agent-fleet--agent-tasks (make-hash-table :test 'equal))
         asked)
    (puthash "w1:p1" "task-done" agent-fleet--agent-tasks)
    (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
               (lambda (_) "w1:p1"))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "running (running)"))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq asked t) t)))
      (should (eq done-task (call-interactively #'agent-fleet-task-wait)))
      (let ((current-prefix-arg '(4)))
        (should (= 0 (call-interactively #'agent-fleet-task-cleanup))))
      (should-not asked)
      (should-not (agent-fleet-task-find "task-run"))
      (let ((agent-fleet--tasks nil))
        (should-error (call-interactively #'agent-fleet-task-cleanup)
                      :type 'user-error)))))

(ert-deftest agent-fleet-interactive-attach ()
  "Attach reads the target and forwards a prefix argument as takeover."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session)) captured)
    (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
               (lambda (_) "w1:p1"))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet-attach--pick-backend)
               (lambda () 'ghostel))
              ((symbol-function 'agent-fleet-attach--live-buffer-p)
               (lambda (_buffer &optional _pane-id) nil))
              ((symbol-function 'agent-fleet-attach--spawn)
               (lambda (&rest args) (setq captured args))))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-fleet-attach)))
    (should (equal '(ghostel "*agent:arch*" "w1:p1" (4)) captured))))


;;; --- Dashboard -------------------------------------------------------

(ert-deftest agent-fleet-interactive-dashboard-entry-and-mode ()
  "The mode command initializes a buffer and the entry command displays it."
  (with-temp-buffer
    (call-interactively #'agent-fleet-mode)
    (should (derived-mode-p 'agent-fleet-mode)))
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        (buf-name agent-fleet-dashboard-buffer-name)
        popped)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) (setq popped buffer))))
          (let ((buffer (call-interactively #'agent-fleet)))
            (should (buffer-live-p buffer))
            (should (eq buffer popped))
            (with-current-buffer buffer
              (should (derived-mode-p 'agent-fleet-mode)))))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))

(ert-deftest agent-fleet-interactive-dashboard-display-backends ()
  "Explicit display commands select their backend and q quits its window."
  (let (opened quit)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--open)
               (lambda (display) (push display opened)))
              ((symbol-function 'selected-frame) (lambda () 'ordinary))
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'quit-window)
               (lambda (&rest _) (setq quit t))))
      (call-interactively #'agent-fleet-dashboard-open-buffer)
      (call-interactively #'agent-fleet-dashboard-open-child-frame)
      (call-interactively #'agent-fleet-dashboard-open-frame)
      (call-interactively #'agent-fleet-dashboard-quit))
    (should (equal '(frame child-frame buffer) opened))
    (should quit)))

(ert-deftest agent-fleet-interactive-dashboard-refresh-and-filters ()
  "Dashboard g fetches server state; project/task filters set and prefix-clear."
  (let* ((herdr-model--cache (agent-fleet-interactive-test--session))
         (task (make-agent-fleet-task :id "task-1" :title "review"
                                      :agents '("w1:p1") :finished-at 1.0))
         (agent-fleet--tasks (list task))
         fetched (refreshes 0))
    (with-temp-buffer
      (agent-fleet-mode)
      ;; The interactive `g' action fetches authoritative server state.
      (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                ((symbol-function 'agent-fleet-list)
                 (lambda (&optional refresh) (setq fetched refresh) nil))
                ((symbol-function 'agent-fleet-dashboard--set-entries) #'ignore)
                ((symbol-function 'agent-fleet-dashboard--update-task-banner) #'ignore)
                ((symbol-function 'tabulated-list-print) #'ignore))
        (call-interactively #'agent-fleet-dashboard-refresh))
      (should fetched)
      ;; `tabulated-list-get-id' is a byte-compiled accessor, so install a
      ;; real row id at point instead of mocking the accessor.
      (let ((inhibit-read-only t))
        (insert "row\n")
        (put-text-property (point-min) (1- (point-max))
                           'tabulated-list-id "w1:p1"))
      (goto-char (point-min))
      ;; Filter commands do local refreshes after setting or clearing state.
      (cl-letf (((symbol-function 'agent-fleet--find-agent)
                 (lambda (_) (make-herdr-agent :id "w1:p1" :name "arch")))
                ((symbol-function 'agent-fleet-project-for-agent)
                 (lambda (_) "/repo"))
                ((symbol-function 'agent-fleet-dashboard-refresh)
                 (lambda (&optional from-server)
                   (when from-server (agent-fleet-list t))
                   (cl-incf refreshes)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "review (done)")))
        (call-interactively #'agent-fleet-dashboard-toggle-project-filter)
        (should (equal "/repo" agent-fleet-dashboard--project-filter))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'agent-fleet-dashboard-toggle-project-filter))
        (should-not agent-fleet-dashboard--project-filter)
        (call-interactively #'agent-fleet-dashboard-toggle-task-filter)
        (should (equal "task-1" agent-fleet-dashboard--task-filter))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'agent-fleet-dashboard-toggle-task-filter))
        (should-not agent-fleet-dashboard--task-filter)
        (should (= 4 refreshes))))))

(ert-deftest agent-fleet-interactive-dashboard-help ()
  "Dashboard help enters its transient through the interactive command."
  (let (prefix)
    (cl-letf (((symbol-function 'transient-setup)
               (lambda (command &rest _) (setq prefix command))))
      (call-interactively #'agent-fleet-dashboard-help))
    (should (eq 'agent-fleet-dashboard-help prefix))))

(ert-deftest agent-fleet-interactive-dashboard-row-actions ()
  "Every dashboard row command resolves point, reads input and delegates once."
  (let (calls)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--agent-at-point)
               (lambda () "w1:p1"))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Prompt" prompt) "do it" "new-name")))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'agent-fleet--find-agent)
               (lambda (_) (make-herdr-agent :id "w1:p1" :name "arch")))
              ((symbol-function 'agent-fleet-dashboard--after-row-change)
               (lambda () (push '(refresh) calls)))
              ((symbol-function 'agent-fleet-show-output)
               (lambda (target &rest _) (push (list 'inspect target) calls)))
              ((symbol-function 'agent-fleet-prompt)
               (lambda (target text) (push (list 'prompt target text) calls)))
              ((symbol-function 'agent-fleet-interrupt)
               (lambda (target) (push (list 'interrupt target) calls)))
              ((symbol-function 'agent-fleet-kill)
               (lambda (target) (push (list 'kill target) calls)))
              ((symbol-function 'agent-fleet-rename)
               (lambda (target name) (push (list 'rename target name) calls)))
              ((symbol-function 'agent-fleet-worktree-status)
               (lambda (target) (push (list 'worktree target) calls)))
              ((symbol-function 'agent-fleet-magit-diff)
               (lambda (target) (push (list 'diff target) calls)))
              ((symbol-function 'agent-fleet-magit-status)
               (lambda (target) (push (list 'magit target) calls)))
              ((symbol-function 'agent-fleet-attach)
               (lambda (target &optional takeover)
                 (push (list 'attach target takeover) calls)))
              ((symbol-function 'agent-fleet-start)
               (lambda (&rest _args)
                 (interactive)
                 (push (list 'new) calls)
                 'started)))
      (call-interactively #'agent-fleet-dashboard-inspect)
      (call-interactively #'agent-fleet-dashboard-prompt)
      (call-interactively #'agent-fleet-dashboard-interrupt)
      (call-interactively #'agent-fleet-dashboard-kill)
      (call-interactively #'agent-fleet-dashboard-rename)
      (call-interactively #'agent-fleet-dashboard-worktree)
      (call-interactively #'agent-fleet-dashboard-diff)
      (call-interactively #'agent-fleet-dashboard-magit)
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-fleet-dashboard-attach))
      (call-interactively #'agent-fleet-dashboard-new))
    (dolist (expected '((inspect "w1:p1")
                        (prompt "w1:p1" "do it")
                        (interrupt "w1:p1")
                        (kill "w1:p1")
                        (rename "w1:p1" "new-name")
                        (worktree "w1:p1")
                        (diff "w1:p1")
                        (magit "w1:p1")
                        (attach "w1:p1" (4))
                        (new)))
      (should (member expected calls)))
    ;; Kill and rename are the two mutating row actions.
    (should (= 2 (cl-count '(refresh) calls :test #'equal)))))


(provide 'agent-fleet-interactive-test)
;;; agent-fleet-interactive-test.el ends here
