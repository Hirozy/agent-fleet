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

(defconst agent-fleet-interactive-test--public-commands
  '((herdr-connect . agent-fleet-interactive-herdr-lifecycle)
    (herdr-disconnect . agent-fleet-interactive-herdr-lifecycle)
    (herdr-doctor . agent-fleet-interactive-doctors)
    (agent-fleet-start . agent-fleet-interactive-start)
    (agent-fleet-prompt . agent-fleet-interactive-prompt-family)
    (agent-fleet-prompt-and-wait . agent-fleet-interactive-prompt-family)
    (agent-fleet-wait . agent-fleet-interactive-wait-and-input)
    (agent-fleet-send-keys . agent-fleet-interactive-wait-and-input)
    (agent-fleet-interrupt . agent-fleet-interactive-wait-and-input)
    (agent-fleet-rename . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-kill . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-switch . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-list . agent-fleet-interactive-rename-kill-switch-list)
    (agent-fleet-show-output-in-buffer . agent-fleet-interactive-output-viewer)
    (agent-fleet-show-output-in-child-frame . agent-fleet-interactive-aux-child-frame)
    (agent-fleet-doctor . agent-fleet-interactive-doctors)
    (agent-fleet-start-for-project . agent-fleet-interactive-project-start)
    (agent-fleet-worktree-list . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-open . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-remove . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-status-in-buffer . agent-fleet-interactive-worktrees)
    (agent-fleet-worktree-status-in-child-frame . agent-fleet-interactive-aux-child-frame)
    (agent-fleet-worktree-cleanup . agent-fleet-interactive-worktrees)
    (agent-fleet-magit-status-in-buffer . agent-fleet-interactive-magit)
    (agent-fleet-magit-status-in-child-frame . agent-fleet-interactive-aux-child-frame)
    (agent-fleet-magit-diff-in-buffer . agent-fleet-interactive-magit)
    (agent-fleet-magit-diff-in-child-frame . agent-fleet-interactive-aux-child-frame)
    (agent-fleet-parallel . agent-fleet-interactive-parallel)
    (agent-fleet-task-wait . agent-fleet-interactive-task-commands)
    (agent-fleet-task-cleanup . agent-fleet-interactive-task-commands)
    (agent-fleet-attach . agent-fleet-interactive-attach)
    (agent-fleet . agent-fleet-interactive-dashboard-entry-and-mode)
    (agent-fleet-dashboard-open-buffer . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard-open-child-frame . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard-open-frame . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard-aux-quit . agent-fleet-interactive-aux-child-frame))
  "Public commands: standalone M-x entry points with autoload and docs.")

(defconst agent-fleet-interactive-test--context-commands
  '((agent-fleet-attach-prompt . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-prompt-in-child-frame . agent-fleet-interactive-attach-compose)
    (agent-fleet-attach--compose-submit . agent-fleet-interactive-attach-compose)
    (agent-fleet-attach--compose-abort . agent-fleet-interactive-attach-compose)
    (agent-fleet-attach-send-keys . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-interrupt . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-kill . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-rename . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-inspect-in-child-frame . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-inspect-in-buffer . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-worktree-in-child-frame . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-worktree-in-buffer . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-magit-in-child-frame . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-magit-in-buffer . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-diff-in-child-frame . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-diff-in-buffer . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-dashboard--quit . agent-fleet-interactive-dashboard-display-backends)
    (agent-fleet-dashboard--refresh . agent-fleet-interactive-dashboard-refresh-and-filters)
    (agent-fleet-dashboard--toggle-project-filter . agent-fleet-interactive-dashboard-refresh-and-filters)
    (agent-fleet-dashboard--toggle-task-filter . agent-fleet-interactive-dashboard-refresh-and-filters)
    (agent-fleet-dashboard--inspect . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--prompt . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--interrupt . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--kill . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--rename . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--worktree . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--diff . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--magit . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--attach . agent-fleet-interactive-dashboard-row-actions)
    (agent-fleet-dashboard--new . agent-fleet-interactive-dashboard-row-actions))
  "Context commands: dashboard row actions and attach-buffer wrappers.")

(defconst agent-fleet-interactive-test--mode-commands
  '((agent-fleet-mode . agent-fleet-interactive-dashboard-entry-and-mode)
    (agent-fleet-attach-mode . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-attach-menu . agent-fleet-interactive-attach-current-agent)
    (agent-fleet-dashboard-help . agent-fleet-interactive-dashboard-help))
  "Mode and transient prefix commands.")

(defconst agent-fleet-interactive-test--optional-commands
  '(consult-agent-fleet-mode)
  "Optional integration commands.  Statically checked only: their tests
require optional dependencies (consult) and are not part of `make test'.")

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
                "\\`\\(?:agent-fleet\\|consult-agent-fleet\\|herdr\\).*\\.el\\'"))
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
  "Every package command is registered and classified in the inventory.
The scanner parses source files (including optional integrations), so a
newly added command must be registered in one of the four categories or
the bidirectional check fails.  Core commands (public, context, mode)
must be `commandp', point to a bound ERT test, and have a literal
`call-interactively' in that test.  Optional commands are statically
checked only — their tests require optional dependencies and are not
part of `make test'.  The category counts are reported in the test
message for quick auditing."
  (let* ((actual (agent-fleet-interactive-test--commands))
         (core (append agent-fleet-interactive-test--public-commands
                       agent-fleet-interactive-test--context-commands
                       agent-fleet-interactive-test--mode-commands))
         (optional agent-fleet-interactive-test--optional-commands)
         (registered (sort (append (mapcar #'car core) optional)
                           (lambda (a b) (string< (symbol-name a)
                                                 (symbol-name b)))))
         (test-calls (agent-fleet-interactive-test--test-calls)))
    (should (equal actual registered))
    (dolist (entry core)
      (should (commandp (car entry)))
      (should (ert-test-boundp (cdr entry)))
      (should (memq (car entry) (alist-get (cdr entry) test-calls))))
    ;; Optional commands: static declaration only (consult may be absent).
    (dolist (cmd optional)
      (should (memq cmd actual)))
    (message "inventory: public=%d context=%d mode=%d optional=%d"
             (length agent-fleet-interactive-test--public-commands)
             (length agent-fleet-interactive-test--context-commands)
             (length agent-fleet-interactive-test--mode-commands)
             (length optional))))


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
  "Interactive start reads kind/workspace/name and provisions with them.
The name prompt is prefilled with a workspace-derived suggestion
\(`<label>-<serial>'), and the workspace picked interactively is the one
used for provisioning — the body does not prompt a second time."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        (agent-fleet--name-counter 0)
        (agent-fleet-agent-started-hook nil)
        name-init provisioned-ws captured)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (cond
                  ((string-match-p "Agent kind" prompt) "codex")
                  ((string-match-p "workspace" prompt) "w1 (demo)")
                  (t (error "unexpected completing-read: %s" prompt)))))
              ((symbol-function 'read-string)
               (lambda (_prompt &optional initial-input &rest _)
                 (setq name-init initial-input)
                 "reviewer"))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet--provision-pane)
               (lambda (ws-id &rest _)
                 (setq provisioned-ws ws-id)
                 "w1:p2"))
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
    (should (equal "demo-1" name-init))
    (should (equal "w1" provisioned-ws))
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

(ert-deftest agent-fleet-interactive-wait-and-input ()
  "Wait/send-keys/interrupt consume minibuffer input and dispatch correctly.
`agent-fleet-read' is deliberately absent: it is a pure Lisp data API with
no interactive form (asserted in
`agent-fleet-interactive-obsolete-view-aliases')."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        calls)
    (cl-letf (((symbol-function 'agent-fleet--read-agent-name)
               (lambda (_) "w1:p1"))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Keys" prompt) "enter" "unused")))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _)
                 (push (list method params) calls)
                 '(:type "agent_info"
                   :agent (:pane_id "w1:p1" :agent_status "done")))))
      (call-interactively #'agent-fleet-wait)
      (call-interactively #'agent-fleet-send-keys)
      (call-interactively #'agent-fleet-interrupt))
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
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil))
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
      (when (get-buffer "*Agent Fleet List*")
        (kill-buffer "*Agent Fleet List*"))
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
            (call-interactively #'agent-fleet-show-output-in-buffer))
          (should (equal "w1:p1" (car captured)))
          (should (= 7 (plist-get (cdr captured) :lines)))
          (with-current-buffer buf-name
            (should buffer-read-only)
            (should (equal "interactive output" (buffer-string)))))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))

(ert-deftest agent-fleet-interactive-obsolete-view-aliases ()
  "The unsuffixed view names are obsolete aliases of the buffer variants.
Each alias still dispatches to its `-in-buffer' replacement and carries
obsolete information naming it; `agent-fleet-read' is a pure Lisp API and
no longer a command at all."
  (dolist (pair '((agent-fleet-show-output
                   . agent-fleet-show-output-in-buffer)
                  (agent-fleet-worktree-status
                   . agent-fleet-worktree-status-in-buffer)
                  (agent-fleet-magit-status
                   . agent-fleet-magit-status-in-buffer)
                  (agent-fleet-magit-diff
                   . agent-fleet-magit-diff-in-buffer)))
    (should (eq (symbol-function (car pair)) (cdr pair)))
    (should (commandp (car pair)))
    (let ((info (get (car pair) 'byte-obsolete-info)))
      (should (eq (car info) (cdr pair)))))
  (should-not (commandp 'agent-fleet-read)))


(ert-deftest agent-fleet-interactive-list-buffer ()
  "List shows the cached agents in a read-only tabulated table.
Mirrors `agent-fleet-interactive-output-viewer': `pop-to-buffer' is stubbed
so no window opens in batch, but the `get-buffer-create'd buffer is live
for content/mode assertions.  `tabulated-list-mode' derives from
`special-mode', so the buffer is read-only and `q' quits.  The canned
session holds one agent (w1:p1/`arch'/claude/`working' in workspace `w1'),
so the table shows one row whose cells include those fields."
  (let* ((herdr-model--cache (agent-fleet-interactive-test--session))
         (buf-name "*Agent Fleet List*"))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                  ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
          (call-interactively #'agent-fleet-list)
          (with-current-buffer buf-name
            (should buffer-read-only)
            (should (derived-mode-p 'special-mode))
            (should (eq 'quit-window
                        (lookup-key (current-local-map) (kbd "q"))))
            (let ((s (buffer-string)))
              (should (string-match-p "arch" s))
              (should (string-match-p "claude" s))
              (should (string-match-p "working" s))
              (should (string-match-p "w1" s)))))
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
        fetches requests displayed
        (wt-buf agent-fleet-worktree-buffer-name))
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'read-directory-name) (lambda (&rest _) "/repo"))
              ((symbol-function 'agent-fleet--read-agent-name) (lambda (_) "w1:p1"))
              ((symbol-function 'agent-fleet-worktree--fetch)
               (lambda (&optional cwd)
                 (push cwd fetches)
                 (cons (list (herdr-model-find-worktree-for-workspace "w1"))
                       '(:repo_name "repo"))))
              ((symbol-function 'pop-to-buffer)
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
      (call-interactively #'agent-fleet-worktree-status-in-buffer))
    (should (member nil fetches))
    (should (member "/repo" fetches))
    (should (member "worktree.open" (mapcar #'car requests)))
    (should displayed)
    (when (get-buffer wt-buf) (kill-buffer wt-buf)))
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
      (call-interactively #'agent-fleet-magit-status-in-buffer)
      (call-interactively #'agent-fleet-magit-diff-in-buffer))
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

(ert-deftest agent-fleet-interactive-attach-current-agent ()
  "Every attach-buffer current-agent command acts on this buffer pane id.
The leaf commands skip `agent-fleet--read-agent-name' and dispatch the base
action with the buffer-local pane id; the minor mode toggles on and the menu
enters its transient.  Lowercase leaves drive the child-frame presentation
and uppercase leaves the buffer presentation, but both resolve the same
buffer-local pane id; the inspect pair honors its prefix line count."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        calls)
    (with-temp-buffer
      (setq-local agent-fleet-attach-pane-id "w1:p1")
      (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                ((symbol-function 'agent-fleet--find-agent)
                 (lambda (_target)
                   (make-herdr-agent :id "w1:p1" :name "arch")))
                ((symbol-function 'read-string)
                 (lambda (prompt &rest _)
                   (cond ((string-prefix-p "Prompt" prompt) "do it")
                         ((string-prefix-p "New name" prompt) "new-name")
                         ((string-prefix-p "Keys" prompt) "enter")
                         (t ""))))
                ((symbol-function 'read-number) (lambda (&rest _) 7))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'agent-fleet-show-output-in-child-frame)
                 (lambda (target &optional lines &rest _)
                   (push (list 'inspect-cf target lines) calls)))
                ((symbol-function 'agent-fleet-show-output-in-buffer)
                 (lambda (target &optional lines &rest _)
                   (push (list 'inspect-buf target lines) calls)))
                ((symbol-function 'agent-fleet-magit-status-in-child-frame)
                 (lambda (target) (push (list 'magit-cf target) calls)))
                ((symbol-function 'agent-fleet-magit-status-in-buffer)
                 (lambda (target) (push (list 'magit-buf target) calls)))
                ((symbol-function 'agent-fleet-magit-diff-in-child-frame)
                 (lambda (target) (push (list 'diff-cf target) calls)))
                ((symbol-function 'agent-fleet-magit-diff-in-buffer)
                 (lambda (target) (push (list 'diff-buf target) calls)))
                ((symbol-function 'agent-fleet-worktree-status-in-child-frame)
                 (lambda (target) (push (list 'worktree-cf target) calls)))
                ((symbol-function 'agent-fleet-worktree-status-in-buffer)
                 (lambda (target) (push (list 'worktree-buf target) calls)))
                ((symbol-function 'agent-fleet-prompt)
                 (lambda (target text) (push (list 'prompt target text) calls)))
                ((symbol-function 'agent-fleet-send-keys)
                 (lambda (target keys) (push (list 'keys target keys) calls)))
                ((symbol-function 'agent-fleet-interrupt)
                 (lambda (target) (push (list 'interrupt target) calls)))
                ((symbol-function 'agent-fleet-kill)
                 (lambda (target) (push (list 'kill target) calls)))
                ((symbol-function 'agent-fleet-rename)
                 (lambda (target name) (push (list 'rename target name) calls)))
                ((symbol-function 'transient-setup)
                 (lambda (command &rest _) (push (list 'menu command) calls))))
        ;; Explicit presentation leaves; a prefix on the inspect pair
        ;; exercises the `read-number' line-count path.
        (call-interactively #'agent-fleet-attach-inspect-in-child-frame)
        (call-interactively #'agent-fleet-attach-inspect-in-buffer)
        (let ((current-prefix-arg '(4)))
          (call-interactively #'agent-fleet-attach-inspect-in-child-frame)
          (call-interactively #'agent-fleet-attach-inspect-in-buffer))
        (call-interactively #'agent-fleet-attach-prompt)
        (call-interactively #'agent-fleet-attach-send-keys)
        (call-interactively #'agent-fleet-attach-interrupt)
        (call-interactively #'agent-fleet-attach-kill)
        (call-interactively #'agent-fleet-attach-rename)
        (call-interactively #'agent-fleet-attach-worktree-in-child-frame)
        (call-interactively #'agent-fleet-attach-worktree-in-buffer)
        (call-interactively #'agent-fleet-attach-magit-in-child-frame)
        (call-interactively #'agent-fleet-attach-magit-in-buffer)
        (call-interactively #'agent-fleet-attach-diff-in-child-frame)
        (call-interactively #'agent-fleet-attach-diff-in-buffer)
        (call-interactively #'agent-fleet-attach-menu)
        (call-interactively #'agent-fleet-attach-mode))
      (dolist (expected '((inspect-cf "w1:p1" nil)
                          (inspect-buf "w1:p1" nil)
                          (inspect-cf "w1:p1" 7)
                          (inspect-buf "w1:p1" 7)
                          (prompt "w1:p1" "do it")
                          (keys "w1:p1" "enter")
                          (interrupt "w1:p1")
                          (kill "w1:p1")
                          (rename "w1:p1" "new-name")
                          (diff-cf "w1:p1")
                          (diff-buf "w1:p1")
                          (magit-cf "w1:p1")
                          (magit-buf "w1:p1")
                          (worktree-cf "w1:p1")
                          (worktree-buf "w1:p1")
                          (menu agent-fleet-attach-menu)))
        (should (member expected calls)))
      (should (eq t (buffer-local-value 'agent-fleet-attach-mode
                                        (current-buffer)))))))


(ert-deftest agent-fleet-interactive-attach-compose ()
  "C-g in an attach buffer opens a compose child frame; submit sends the
prompt via `agent.prompt' and closes; abort closes without sending.
The compose buffer carries the pane id buffer-locally so the submit
key routes the prompt to the right agent.  `--aux-run' and `--aux-close'
are stubbed so the lifecycle runs in batch."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        calls aux-closed)
    (with-temp-buffer
      (setq-local agent-fleet-attach-pane-id "w1:p1")
      (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                ((symbol-function 'agent-fleet-prompt)
                 (lambda (target text) (push (list 'prompt target text) calls)))
                ((symbol-function 'set-window-buffer) #'ignore)
                ((symbol-function 'agent-fleet-display--aux-run)
                 (lambda (thunk) (funcall thunk)))
                ((symbol-function 'agent-fleet-display--aux-close)
                 (lambda (_frame) (push 'closed aux-closed))))
        ;; Opening the compose frame creates the buffer with the pane id.
        (call-interactively #'agent-fleet-attach-prompt-in-child-frame)
        (should (get-buffer "*agent-fleet-compose*"))
        (with-current-buffer "*agent-fleet-compose*"
          (should (equal agent-fleet-attach--compose-pane-id "w1:p1"))
          (insert "fix the bug"))
        ;; Submit sends the text and closes the frame.
        (with-current-buffer "*agent-fleet-compose*"
          (call-interactively #'agent-fleet-attach--compose-submit))
        (should (member '(prompt "w1:p1" "fix the bug") calls))
        (should aux-closed)
        ;; Re-open, abort: no prompt is sent.
        (setq calls nil aux-closed nil)
        (call-interactively #'agent-fleet-attach-prompt-in-child-frame)
        (with-current-buffer "*agent-fleet-compose*"
          (insert "discarded")
          (call-interactively #'agent-fleet-attach--compose-abort))
        (should-not calls)
        (should aux-closed)))))


(ert-deftest agent-fleet-interactive-aux-child-frame ()
  "The `-in-child-frame' commands open one reusable aux child; quit closes it.
The four presentation commands route through `--aux-run', which creates a
single auxiliary child frame for the origin and reuses it on repeated opens
(rather than nesting or silently falling back to a buffer).  `agent-fleet-dashboard-aux-quit'
deletes the child and restores focus to the origin.  Frame primitives are
stubbed so the lifecycle runs in batch."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session))
        (agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (current-frame 'origin)
        display-actions setwb magit-calls deleted)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                  ((symbol-function 'agent-fleet--read-agent-name)
                   (lambda (_) "w1:p1"))
                  ((symbol-function 'agent-fleet-read)
                   (lambda (&rest _) '(:text "child-frame output")))
                  ((symbol-function 'agent-fleet-worktree--fetch)
                   (lambda (&optional _cwd)
                     (cons (list (herdr-model-find-worktree-for-workspace "w1"))
                           '(:repo_name "repo"))))
                  ((symbol-function 'agent-fleet-magit--available-p) (lambda () t))
                  ((symbol-function 'agent-fleet-magit--root-for-agent)
                   (lambda (_) "/tmp"))
                  ((symbol-function 'magit-status)
                   (lambda (root) (push (list 'status root) magit-calls) t))
                  ((symbol-function 'magit-diff-working-tree)
                   (lambda (&rest _) (push (list 'diff) magit-calls) t))
                  ((symbol-function 'selected-frame) (lambda () current-frame))
                  ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                  ((symbol-function 'frame-parameter)
                   (lambda (frame parameter)
                     (cond
                      ((and (eq frame 'aux-child)
                            (eq parameter 'agent-fleet-auxiliary-origin-frame))
                       'origin)
                      ((and (eq frame 'aux-child)
                            (eq parameter 'agent-fleet-auxiliary-frame))
                       t)
                      (t nil))))
                  ((symbol-function 'frame-parent) (lambda (&rest _) nil))
                  ((symbol-function 'frame-live-p)
                   (lambda (frame) (memq frame '(origin aux-child))))
                  ((symbol-function 'display-buffer)
                   (lambda (_buffer &optional action &rest _)
                     (when (consp action)
                       (push (caar action) display-actions))
                     'aux-window))
                  ((symbol-function 'window-frame) (lambda (&rest _) 'aux-child))
                  ((symbol-function 'window-list) (lambda (&rest _) nil))
                  ((symbol-function 'modify-frame-parameters) #'ignore)
                  ((symbol-function 'select-frame-set-input-focus)
                   (lambda (frame) (setq current-frame frame)))
                  ((symbol-function 'agent-fleet-display--center-child-frame)
                   #'ignore)
                  ((symbol-function 'set-window-buffer)
                   (lambda (&rest args) (push args setwb)))
                  ((symbol-function 'delete-frame)
                   (lambda (frame &optional _force) (setq deleted frame)))
                  ((symbol-function 'quit-window) #'ignore))
          ;; First command creates the aux child; the next three reuse it.
          (call-interactively #'agent-fleet-show-output-in-child-frame)
          (call-interactively #'agent-fleet-worktree-status-in-child-frame)
          (call-interactively #'agent-fleet-magit-status-in-child-frame)
          (call-interactively #'agent-fleet-magit-diff-in-child-frame)
          (call-interactively #'agent-fleet-dashboard-aux-quit)
          (should (member 'display-buffer-in-child-frame display-actions))
          (should (= 1 (length display-actions)))
          (should (= 2 (length setwb)))
          (should (member '(status "/tmp") magit-calls))
          (should (member '(diff) magit-calls))
          (should (eq 'aux-child deleted))
          (should (eq 'origin current-frame))
          (should-not (gethash 'origin agent-fleet-display--aux-frames)))
      (dolist (buf (list " *agent-fleet-aux*"
                         "*Agent Output: arch*"
                         agent-fleet-worktree-buffer-name))
        (when (get-buffer buf) (kill-buffer buf))))))


(ert-deftest agent-fleet-agent-candidates-lists-kind-task-workspace ()
  "Candidates carry the identity plus kind, task, and workspace.
The fields mirror the dashboard, and the alist shape (label . pane-id) is
what a future `consult-agent-fleet' package would feed to `consult--read'
with a `consult--lookup-cdr' lookup."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session)))
    ;; Fixture agent: name "arch", kind "claude", workspace label "demo",
    ;; no terminal title and no parallel task -> task is "—".
    (let ((entry (car (agent-fleet-agent-candidates))))
      (should (equal "arch" (plist-get entry :name)))
      (should (equal "arch" (plist-get entry :label)))
      (should (equal "Claude" (plist-get entry :kind)))
      (should (equal "demo" (plist-get entry :workspace)))
      (should (equal "—" (plist-get entry :task)))
      (should (equal "w1:p1" (plist-get entry :pane-id)))
      (should (equal "Claude · — · demo"
                     (agent-fleet-agent-candidate-suffix entry))))
    ;; A parallel task title wins for the task field.
    (let ((agent-fleet--tasks
           (list (make-agent-fleet-task :id "tk" :title "fix bug")))
          (agent-fleet--agent-tasks
           (let ((h (make-hash-table :test 'equal)))
             (puthash "w1:p1" "tk" h) h)))
      (let ((entry (car (agent-fleet-agent-candidates))))
        (should (equal "fix bug" (plist-get entry :task)))
        (should (equal "Claude · fix bug · demo"
                       (agent-fleet-agent-candidate-suffix entry)))))))

(ert-deftest agent-fleet-agent-candidates-disambiguate-shared-names ()
  "Two agents sharing a display name are disambiguated by pane id."
  (let ((herdr-model--cache (agent-fleet-interactive-test--session)))
    (puthash "w1:p2"
             (make-herdr-agent :id "w1:p2" :workspace-id "w1"
                               :name "arch" :agent "codex")
             (herdr-session-agents herdr-model--cache))
    (let ((entries (agent-fleet-agent-candidates)))
      (should (= 2 (length entries)))
      (let ((e1 (cl-find "w1:p1" entries
                         :key (lambda (e) (plist-get e :pane-id)) :test #'equal))
            (e2 (cl-find "w1:p2" entries
                         :key (lambda (e) (plist-get e :pane-id)) :test #'equal)))
        (should (equal "arch  [w1:p1]" (plist-get e1 :label)))
        (should (equal "arch  [w1:p2]" (plist-get e2 :label)))
        (should (equal "Claude" (plist-get e1 :kind)))
        (should (equal "Codex" (plist-get e2 :kind)))
        (should (equal "demo" (plist-get e2 :workspace)))))))


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
      (call-interactively #'agent-fleet-dashboard--quit))
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
        (call-interactively #'agent-fleet-dashboard--refresh))
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
                ((symbol-function 'agent-fleet-dashboard--refresh)
                 (lambda (&optional from-server)
                   (when from-server (agent-fleet-list t))
                   (cl-incf refreshes)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "review (done)")))
        (call-interactively #'agent-fleet-dashboard--toggle-project-filter)
        (should (equal "/repo" agent-fleet-dashboard--project-filter))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'agent-fleet-dashboard--toggle-project-filter))
        (should-not agent-fleet-dashboard--project-filter)
        (call-interactively #'agent-fleet-dashboard--toggle-task-filter)
        (should (equal "task-1" agent-fleet-dashboard--task-filter))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'agent-fleet-dashboard--toggle-task-filter))
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
              ((symbol-function 'agent-fleet-show-output-in-buffer)
               (lambda (target &rest _) (push (list 'inspect target) calls)))
              ((symbol-function 'agent-fleet-prompt)
               (lambda (target text) (push (list 'prompt target text) calls)))
              ((symbol-function 'agent-fleet-interrupt)
               (lambda (target) (push (list 'interrupt target) calls)))
              ((symbol-function 'agent-fleet-kill)
               (lambda (target) (push (list 'kill target) calls)))
              ((symbol-function 'agent-fleet-rename)
               (lambda (target name) (push (list 'rename target name) calls)))
              ((symbol-function 'agent-fleet-worktree-status-in-buffer)
               (lambda (target) (push (list 'worktree target) calls)))
              ((symbol-function 'agent-fleet-magit--diff-outcome)
               (lambda (target)
                 (push (list 'diff target) calls)
                 (agent-fleet-display--make-outcome t 'diff)))
              ((symbol-function 'agent-fleet-magit--status-outcome)
               (lambda (target)
                 (push (list 'magit target) calls)
                 (agent-fleet-display--make-outcome t 'magit)))
              ((symbol-function 'agent-fleet-attach)
               (lambda (target &optional takeover)
                 (push (list 'attach target takeover) calls)))
              ((symbol-function 'agent-fleet-start)
               (lambda (&rest _args)
                 (interactive)
                 (push (list 'new) calls)
                 'started)))
      (call-interactively #'agent-fleet-dashboard--inspect)
      (call-interactively #'agent-fleet-dashboard--prompt)
      (call-interactively #'agent-fleet-dashboard--interrupt)
      (call-interactively #'agent-fleet-dashboard--kill)
      (call-interactively #'agent-fleet-dashboard--rename)
      (call-interactively #'agent-fleet-dashboard--worktree)
      (call-interactively #'agent-fleet-dashboard--diff)
      (call-interactively #'agent-fleet-dashboard--magit)
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-fleet-dashboard--attach))
      (call-interactively #'agent-fleet-dashboard--new))
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
