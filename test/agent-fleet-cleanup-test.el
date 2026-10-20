;;; agent-fleet-cleanup-test.el --- Cleanup safety tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-fleet-cleanup)
(require 'agent-fleet-worktree)
(require 'agent-fleet-parallel)

(defun agent-fleet-cleanup-test--snapshot ()
  "Return two ordinary workspaces, including a split tab and a shell."
  (list :workspaces '((:workspace_id "w1" :tab_count 2)
                      (:workspace_id "w2" :tab_count 1))
        :tabs '((:tab_id "a" :workspace_id "w1" :pane_count 2)
                (:tab_id "b" :workspace_id "w1" :pane_count 1)
                (:tab_id "c" :workspace_id "w2" :pane_count 1))
        :panes (cl-loop for id in '("p1" "p2" "p3" "p4")
                        for tab in '("a" "a" "b" "c")
                        collect (list :pane_id id :tab_id tab :terminal_id (concat "term-" id)
                                      :workspace_id (if (equal id "p4") "w2" "w1")
                                      :cwd "/tmp" :agent (unless (equal id "p4") "codex")
                                      :agent_status "done"))
        :agents (cl-loop for id in '("p1" "p2" "p3")
                         for tab in '("a" "a" "b")
                         collect (list :pane_id id :tab_id tab :workspace_id "w1"
                                       :agent "codex" :agent_status "done"))))

(defun agent-fleet-cleanup-test--apply-close (snapshot method id)
  "Apply a mock close to SNAPSHOT, including cascaded container removal."
  (let* ((panes (plist-get snapshot :panes))
         (removed (cl-remove-if-not
                   (lambda (p)
                     (equal id (plist-get p (pcase method
                                             ("workspace.close" :workspace_id)
                                             ("tab.close" :tab_id)
                                             (_ :pane_id))))) panes))
         (ids (mapcar (lambda (p) (plist-get p :pane_id)) removed)))
    (should removed)
    (setf (plist-get snapshot :panes) (cl-set-difference panes removed)
          (plist-get snapshot :agents)
          (cl-remove-if (lambda (a) (member (plist-get a :pane_id) ids))
                        (plist-get snapshot :agents)))
    (dolist (tab (plist-get snapshot :tabs))
      (setf (plist-get tab :pane_count)
            (cl-count (plist-get tab :tab_id) (plist-get snapshot :panes)
                      :key (lambda (p) (plist-get p :tab_id)) :test #'equal)))
    (setf (plist-get snapshot :tabs)
          (cl-remove-if (lambda (tab) (= 0 (plist-get tab :pane_count)))
                        (plist-get snapshot :tabs)))
    (dolist (ws (plist-get snapshot :workspaces))
      (setf (plist-get ws :tab_count)
            (cl-count (plist-get ws :workspace_id) (plist-get snapshot :tabs)
                      :key (lambda (tab) (plist-get tab :workspace_id)) :test #'equal)))
    (setf (plist-get snapshot :workspaces)
          (cl-remove-if (lambda (ws) (= 0 (plist-get ws :tab_count)))
                        (plist-get snapshot :workspaces)))))

(defmacro agent-fleet-cleanup-test--with-server (&rest body)
  "Run BODY against strict, mutable RPC fixtures, never a real Herdr server."
  (declare (indent 0))
  `(let ((agent-fleet-cleanup-review-buffer-name
          (make-temp-name "*agent-fleet-cleanup-test-review-"))
         (snapshot (copy-tree (agent-fleet-cleanup-test--snapshot)))
         (worktrees nil) (requests nil) (failures nil) (ack '(:type "ok"))
         (worktree-query nil) (close-quit-id nil)
         (snapshot-count 0) (before-snapshot nil)
         (herdr-model--cache nil)
         (agent-fleet--tasks nil)
         (agent-fleet--agent-tasks (make-hash-table :test 'equal))
         (herdr--conn (make-herdr--connection :socket-path "/tmp/cleanup-test")))
     (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
               ((symbol-function 'herdr-connected-p) (lambda () t))
               ((symbol-function 'herdr-request)
                (lambda (method &optional params &rest _)
                  (push (cons method params) requests)
                  (cond
                   ((equal method "worktree.list")
                    (let ((ws (alist-get 'workspace_id params)))
                      (should ws)
                      (if worktree-query (funcall worktree-query ws)
                        (list :type "worktree_list" :worktrees (copy-tree worktrees)))))
                   ((equal method "session.snapshot")
                    (cl-incf snapshot-count)
                    (when before-snapshot (funcall before-snapshot))
                    (copy-tree snapshot))
                   ((member method '("pane.close" "tab.close" "workspace.close" "worktree.remove"))
                    (let* ((key (pcase method ("pane.close" 'pane_id)
                                       ("tab.close" 'tab_id) (_ 'workspace_id)))
                           (id (or (alist-get key params)
                                   (alist-get (symbol-name key) params nil nil #'equal))))
                      (when (member id failures)
                        (signal 'herdr-request-error (list :code "protected" :target id)))
                      (when (and close-quit-id (equal close-quit-id id))
                        (signal 'quit nil))
                      (if (equal method "worktree.remove")
                          (progn
                            (setq worktrees (cl-remove id worktrees
                                                       :key (lambda (w) (plist-get w :open_workspace_id))
                                                       :test #'equal))
                            (list :type "worktree_removed" :workspace_id id :path (concat "/tmp/" id)))
                        (agent-fleet-cleanup-test--apply-close snapshot method id)
                        ack)))
                   (t (ert-fail (format "Unexpected RPC %s" method)))))))
       ,@body)))

(defun agent-fleet-cleanup-test--writes (requests)
  "Return destructive REQUESTS in issue order."
  (reverse (cl-remove-if-not
            (lambda (r) (member (car r) '("pane.close" "tab.close" "workspace.close" "worktree.remove")))
            requests)))

(defun agent-fleet-cleanup-test--shells (snapshot)
  "Remove all agent evidence from the mock SNAPSHOT."
  (setf (plist-get snapshot :agents) nil)
  (dolist (pane (plist-get snapshot :panes))
    (setf (plist-get pane :agent) nil
          (plist-get pane :agent_status) nil))
  snapshot)

(defmacro agent-fleet-cleanup-test--with-ui (&rest body)
  "Run BODY with safe confirmation and buffer-display stubs."
  (declare (indent 0))
  `(let ((confirmations nil) (confirm-answer t)
         (origin (current-buffer)) (window (selected-window)))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt)
                  (should-not use-short-answers)
                  (push prompt confirmations)
                  (if (eq confirm-answer 'quit) (signal 'quit nil) confirm-answer)))
               ((symbol-function 'completing-read)
                (lambda (&rest _) (ert-fail "Unexpected completion menu"))))
       ,@body
       (should (eq origin (current-buffer)))
       (should (eq window (selected-window))))))

(ert-deftest agent-fleet-cleanup-interactive-one-review-buffer ()
  (agent-fleet-cleanup-test--with-server
   (let ((origin (get-buffer-create "*agent-fleet-cleanup-test-origin*"))
         (window (selected-window)))
     (switch-to-buffer origin)
     (call-interactively #'agent-fleet-cleanup)
     (should (equal agent-fleet-cleanup-review-buffer-name (buffer-name)))
     (should (eq window (selected-window)))
     (should (equal 'review agent-fleet-cleanup--review-state))
     (should buffer-read-only)
     (dolist (text '("Workspace w2" "p4" "3 agent" "Protected / skipped"
                     "Agent-associated workspace" "C-c C-c" "q / C-g"))
       (should (string-match-p text (buffer-string))))
     (should-not (agent-fleet-cleanup-test--writes requests))
     (should (eq #'agent-fleet-cleanup-review-execute
                 (lookup-key agent-fleet-cleanup-review-mode-map (kbd "C-c C-c"))))
     (should (eq #'agent-fleet-cleanup-review-quit
                 (lookup-key agent-fleet-cleanup-review-mode-map (kbd "q"))))
     (agent-fleet-cleanup-review-quit)
     (should (eq origin (current-buffer)))
     (should (eq window (selected-window)))
     (should-not (agent-fleet-cleanup-test--writes requests))
     (kill-buffer origin))))

(ert-deftest agent-fleet-cleanup-review-c-c-c-executes-once-and-shows-results ()
  (agent-fleet-cleanup-test--with-server
   (call-interactively #'agent-fleet-cleanup)
   (should (eq 'review agent-fleet-cleanup--review-state))
   (call-interactively #'agent-fleet-cleanup-review-execute)
   (should (eq 'complete agent-fleet-cleanup--review-state))
   (should (string-match-p "1 closed; 3 agent(s) preserved"
                           (buffer-string)))
   (should (equal '(("workspace.close" (workspace_id . "w2")))
                  (agent-fleet-cleanup-test--writes requests)))
   (should (equal '("p1" "p2" "p3")
                  (mapcar (lambda (a) (plist-get a :pane_id))
                          (plist-get snapshot :agents))))
   (should-error (agent-fleet-cleanup-review-execute) :type 'user-error)
   (kill-buffer (current-buffer))))

(ert-deftest agent-fleet-cleanup-review-q-and-c-g-cancel-without-effects ()
  (dolist (key '("q" "C-g"))
    (agent-fleet-cleanup-test--with-server
     (let ((origin (get-buffer-create "*agent-fleet-cleanup-test-origin*"))
           (window (selected-window)))
       (switch-to-buffer origin)
       (call-interactively #'agent-fleet-cleanup)
       (let ((review-buffer (current-buffer)))
       (if (equal key "q")
           (call-interactively #'agent-fleet-cleanup-review-quit)
         (execute-kbd-macro (kbd key)))
       (should (eq origin (current-buffer)))
       (should (eq window (selected-window)))
       (should-not (agent-fleet-cleanup-test--writes requests))
       (should-not (buffer-live-p review-buffer)))
       (kill-buffer origin)))))

(ert-deftest agent-fleet-cleanup-no-candidates-opens-no-buffer ()
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup-test--shells snapshot)
   (setf (plist-get (car (last (plist-get snapshot :panes))) :agent) "codex"
         (plist-get (car (last (plist-get snapshot :panes))) :agent_status) "done"
         (plist-get snapshot :agents)
         (list '(:pane_id "p4" :tab_id "c" :workspace_id "w2"
                 :agent "codex" :agent_status "done")))
   (setq worktrees '((:path "/tmp/wt1" :open_workspace_id "w1" :is_linked_worktree t)
                     (:path "/tmp/wt2" :open_workspace_id "w2" :is_linked_worktree t)))
   (call-interactively #'agent-fleet-cleanup)
   (should-not (get-buffer agent-fleet-cleanup-review-buffer-name))
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-review-rechecks-before-execution ()
  (agent-fleet-cleanup-test--with-server
   (call-interactively #'agent-fleet-cleanup)
   (setq before-snapshot
         (lambda ()
           (when (= snapshot-count 2)
             (setf (plist-get (car (last (plist-get snapshot :panes))) :agent) "codex"
                   (plist-get (car (last (plist-get snapshot :panes))) :agent_status) "done")
             (push '(:pane_id "p4" :tab_id "c" :workspace_id "w2"
                     :agent "codex" :agent_status "done") (plist-get snapshot :agents)))))
   (execute-kbd-macro (kbd "C-c C-c"))
   (should (eq 'complete agent-fleet-cleanup--review-state))
   (should (string-match-p "skipped" (buffer-string)))
   (should-not (agent-fleet-cleanup-test--writes requests))
   (kill-buffer (current-buffer))))

(ert-deftest agent-fleet-cleanup-review-already-open-does-not-replace-targets ()
  (agent-fleet-cleanup-test--with-server
   (call-interactively #'agent-fleet-cleanup)
   (let ((contents (buffer-string)))
     (with-temp-buffer
       (should-error (call-interactively #'agent-fleet-cleanup) :type 'user-error))
     (should (eq 'review agent-fleet-cleanup--review-state))
     (should (equal contents (buffer-string))))
   (should-not (agent-fleet-cleanup-test--writes requests))
   (kill-buffer (current-buffer))))

(ert-deftest agent-fleet-cleanup-quit-before-next-close-keeps-partial-results ()
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup-test--shells snapshot)
   (let ((origin (get-buffer-create " *cleanup-origin-partial*"))
         (query worktree-query))
     (switch-to-buffer origin)
     (call-interactively #'agent-fleet-cleanup)
     ;; Interrupt the second operation's fresh preflight, after the first
     ;; close has been acknowledged.
     (setq worktree-query
           (lambda (ws)
             (when (= 1 (length (agent-fleet-cleanup-test--writes requests)))
               (signal 'quit nil))
             (if query (funcall query ws)
               (list :type "worktree_list" :worktrees (copy-tree worktrees)))))
     (agent-fleet-cleanup-review-execute)
     (should (eq 'interrupted agent-fleet-cleanup--review-state))
     (should (equal '("w1") (plist-get agent-fleet-cleanup--review-report :closed)))
     (should (equal '("w2") (plist-get agent-fleet-cleanup--review-report :pending)))
     (should-not (plist-get agent-fleet-cleanup--review-report :uncertain))
     (should (string-match-p "Closed: w1" (buffer-string)))
     (should (string-match-p "Not attempted: w2" (buffer-string)))
     (should (buffer-live-p origin))
     (should (equal '(("workspace.close" (workspace_id . "w1")))
                    (agent-fleet-cleanup-test--writes requests)))
     (should-error (agent-fleet-cleanup-review-execute) :type 'user-error)
     (kill-buffer (current-buffer))
     (kill-buffer origin))))

(ert-deftest agent-fleet-cleanup-quit-during-close-marks-outcome-uncertain ()
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup-test--shells snapshot)
   (let ((origin (get-buffer-create " *cleanup-origin-uncertain*")))
     (switch-to-buffer origin)
     (call-interactively #'agent-fleet-cleanup)
     (setq close-quit-id "w1")
     (agent-fleet-cleanup-review-execute)
     (should (eq 'interrupted agent-fleet-cleanup--review-state))
     (should (equal '("w1") (plist-get agent-fleet-cleanup--review-report :uncertain)))
     (should (equal '("w2") (plist-get agent-fleet-cleanup--review-report :pending)))
     (should (equal '("workspace.close")
                    (mapcar #'car (agent-fleet-cleanup-test--writes requests))))
     (should (buffer-live-p origin))
     (kill-buffer (current-buffer))
     (kill-buffer origin))))

(ert-deftest agent-fleet-cleanup-unexpected-execute-error-leaves-interrupted-view ()
  (agent-fleet-cleanup-test--with-server
   (let ((origin (get-buffer-create " *cleanup-origin-error*")))
     (switch-to-buffer origin)
     (call-interactively #'agent-fleet-cleanup)
     (cl-letf (((symbol-function 'agent-fleet-cleanup--execute)
                (lambda (&rest _) (error "injected execution failure")))
               ((symbol-function 'agent-fleet-cleanup--result-message) #'ignore))
       (agent-fleet-cleanup-review-execute))
     (should (eq 'interrupted agent-fleet-cleanup--review-state))
     (should (string-match-p "Cleanup interrupted" (buffer-string)))
     (should (string-match-p "injected execution failure" (buffer-string)))
     (should (buffer-live-p origin))
     (should-error (agent-fleet-cleanup-review-execute) :type 'user-error)
     (kill-buffer (current-buffer))
     (kill-buffer origin))))

(ert-deftest agent-fleet-cleanup-origin-survives-quit-completion-and-rescan ()
  (agent-fleet-cleanup-test--with-server
   (let ((origin (get-buffer-create " *cleanup-origin-rescan*")))
     (switch-to-buffer origin)
     (call-interactively #'agent-fleet-cleanup)
     (agent-fleet-cleanup-review-quit)
     (should (buffer-live-p origin))
     (should (eq origin (current-buffer)))
     (call-interactively #'agent-fleet-cleanup)
     (agent-fleet-cleanup-review-execute)
     (should (buffer-live-p origin))
     ;; Starting a fresh review from the completed result buffer must retain
     ;; the original origin buffer for its eventual quit.
     (setq snapshot (copy-tree (agent-fleet-cleanup-test--snapshot)))
     (call-interactively #'agent-fleet-cleanup)
     (should (eq 'review agent-fleet-cleanup--review-state))
     (should (buffer-live-p origin))
     (agent-fleet-cleanup-review-quit)
     (should (buffer-live-p origin))
     (should (eq origin (current-buffer)))
     (kill-buffer origin))))

(ert-deftest agent-fleet-cleanup-incident-all-agents-never-closes-last-workspace ()
  (agent-fleet-cleanup-test--with-server
   (setf (plist-get snapshot :workspaces) (list (car (plist-get snapshot :workspaces)))
         (plist-get snapshot :tabs) (butlast (plist-get snapshot :tabs))
         (plist-get snapshot :panes) (butlast (plist-get snapshot :panes)))
   (agent-fleet-cleanup-test--with-ui
    (call-interactively #'agent-fleet-cleanup)
    (should-not confirmations))
   (should-not (get-buffer agent-fleet-cleanup-review-buffer-name))
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-no-confirm-never-bypasses-review ()
  (dolist (prefix '(nil t))
    (agent-fleet-cleanup-test--with-server
     (if prefix
         (let ((current-prefix-arg '(4))) (call-interactively #'agent-fleet-cleanup))
       (agent-fleet-cleanup :select t :no-confirm t))
     (should (eq 'review agent-fleet-cleanup--review-state))
     (should-not (agent-fleet-cleanup-test--writes requests))
     (kill-buffer (current-buffer)))))

(ert-deftest agent-fleet-cleanup-read-only-report-protects-done-agents ()
  (agent-fleet-cleanup-test--with-server
   (let ((report (agent-fleet-cleanup)))
     (should (= 3 (plist-get report :preserved-agents)))
     (should (equal '("p4") (mapcar (lambda (c) (plist-get c :id))
                                    (plist-get report :candidates))))
     (should (assoc "w1" (plist-get report :protected)))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-all-agent-states-protect-sibling-shells ()
  (dolist (state '("done" "working" "blocked" "idle" "unknown" nil))
    (agent-fleet-cleanup-test--with-server
     (setf (plist-get snapshot :agents) (list (car (plist-get snapshot :agents)))
           (plist-get (car (plist-get snapshot :agents)) :agent_status) state
           (plist-get (car (plist-get snapshot :panes)) :agent_status) state)
     (dolist (pane (cdr (plist-get snapshot :panes))) (setf (plist-get pane :agent) nil))
     (dolist (id '("p1" "p2" "p3"))
       (should-error (agent-fleet-cleanup :targets (list id) :no-confirm t) :type 'user-error))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-positive-agent-evidence-in-every-source ()
  (dolist (source '(snapshot-pane snapshot-session live-pane live-agent live-session))
    (agent-fleet-cleanup-test--with-server
     (agent-fleet-cleanup-test--shells snapshot)
     (if (memq source '(snapshot-pane snapshot-session))
         (setf (plist-get (car (plist-get snapshot :panes))
                          (if (eq source 'snapshot-pane) :agent :agent_session))
               (if (eq source 'snapshot-pane) "codex" '(:agent "codex" :value "session")))
       (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
       (pcase source
         ('live-pane (setf (herdr-pane-agent (herdr-model-find-pane "p1")) "codex"))
         ('live-session
          (setf (herdr-pane-agent-session (herdr-model-find-pane "p1"))
                (make-herdr-agent-session :value "session")))
         ('live-agent
          (puthash "p1" (make-herdr-agent :id "p1" :workspace-id "w1" :agent-status "done")
                   (herdr-session-agents herdr-model--cache)))))
     (should-error (agent-fleet-cleanup :targets '("p2") :no-confirm t) :type 'user-error)
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-task-ownership-protects-missing-and-empty-members ()
  (dolist (members '(("missing") nil))
    (agent-fleet-cleanup-test--with-server
     (setq agent-fleet--tasks
           (list (make-agent-fleet-task :id "task" :agents members
                                        :workspaces '(("missing" . "w2")))))
     (let ((before (copy-tree (agent-fleet-task-workspaces (car agent-fleet--tasks)))))
       (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'user-error)
       (should (equal before (agent-fleet-task-workspaces (car agent-fleet--tasks)))))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-task-pane-membership-protects-without-agent-row ()
  (agent-fleet-cleanup-test--with-server
   (setq agent-fleet--tasks (list (make-agent-fleet-task :id "task" :agents '("p4"))))
   (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'user-error)))

(ert-deftest agent-fleet-cleanup-worktrees-never-delete-or-close-runtime ()
  (dolist (link '(t nil :null "false"))
    (agent-fleet-cleanup-test--with-server
     (setq worktrees (list (list :path "/tmp/worktree" :open_workspace_id "w2"
                                 :is_linked_worktree link)))
     (should (assoc "/tmp/worktree" (plist-get (agent-fleet-cleanup) :protected)))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-unowned-worktree-is-preserved ()
  (agent-fleet-cleanup-test--with-server
   (setq worktrees '((:path "/tmp/unowned" :is_linked_worktree t)))
   (agent-fleet-cleanup :targets '("p4") :no-confirm t)
   (should (equal '(("workspace.close" (workspace_id . "w2")))
                  (agent-fleet-cleanup-test--writes requests))))
  (agent-fleet-cleanup-test--with-server
   (should-error (agent-fleet-cleanup :targets '("unknown") :no-confirm t) :type 'user-error)
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-primary-checkout-allows-agent-free-runtime ()
  (dolist (source '(list snapshot cache))
    (agent-fleet-cleanup-test--with-server
     (let ((info '(:path "/tmp/repo" :open_workspace_id "w2" :is_linked_worktree :false)))
       (pcase source
         ('list (setq worktrees (list info)))
         ('snapshot (setf (plist-get (cadr (plist-get snapshot :workspaces)) :worktree) info))
         ('cache
          (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
          (herdr-model-upsert-worktree info))))
     (agent-fleet-cleanup :targets '("p4") :no-confirm t)
     (should (equal '(("workspace.close" (workspace_id . "w2")))
                    (agent-fleet-cleanup-test--writes requests))))))

(ert-deftest agent-fleet-cleanup-unknown-cache-linkage-vetoes-primary-list ()
  (agent-fleet-cleanup-test--with-server
   (setq worktrees '((:path "/tmp/repo" :open_workspace_id "w2" :is_linked_worktree :false))
         herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
   (herdr-model-upsert-worktree '(:path "/tmp/unknown" :open_workspace_id "w2"))
   (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'user-error)))

(ert-deftest agent-fleet-cleanup-recheck-protects-agent-appearing-after-review ()
  (dolist (source '(snapshot cache))
    (agent-fleet-cleanup-test--with-server
     (call-interactively #'agent-fleet-cleanup)
     (setq before-snapshot
           (lambda ()
             (when (= snapshot-count 2)
               (if (eq source 'snapshot)
                   (setf (plist-get (car (last (plist-get snapshot :panes))) :agent) "codex")
                 (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
                 (setf (herdr-pane-agent (herdr-model-find-pane "p4")) "codex")))))
     (agent-fleet-cleanup-review-execute)
     (should (string-match-p "skipped" (buffer-string)))
     (should-not (agent-fleet-cleanup-test--writes requests))
     (kill-buffer (current-buffer)))))

(ert-deftest agent-fleet-cleanup-recheck-sibling-agent-vetoes-lisp-subset ()
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup-test--shells snapshot)
   (setq before-snapshot
         (lambda ()
           (when (= snapshot-count 2)
             (setf (plist-get (cadr (plist-get snapshot :panes)) :agent) "codex"))))
   (should (plist-get (agent-fleet-cleanup :targets '("p1") :no-confirm t) :skipped))
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-recheck-identity-membership-linkage-and-connection ()
  (dolist (change '(identity count linkage connection task))
    (agent-fleet-cleanup-test--with-server
     (call-interactively #'agent-fleet-cleanup)
     (setq before-snapshot
           (lambda ()
             (when (= snapshot-count 2)
               (pcase change
                 ('identity (setf (plist-get (car (last (plist-get snapshot :panes))) :terminal_id) "new"))
                 ('count (setf (plist-get (car (last (plist-get snapshot :tabs))) :pane_count) 2))
                 ('linkage (setq worktrees '((:path "/tmp/wt" :open_workspace_id "w2"
                                               :is_linked_worktree t))))
                 ('connection (setq herdr--conn (make-herdr--connection)))
                 ('task (setq agent-fleet--tasks
                              (list (make-agent-fleet-task :id "new" :agents '("p4")))))))))
     (agent-fleet-cleanup-review-execute)
     (should (string-match-p "skipped\\|failed" (buffer-string)))
     (should-not (cl-find "w2" (agent-fleet-cleanup-test--writes requests)
                          :key (lambda (request)
                                (alist-get 'workspace_id (cdr request)))
                          :test #'equal))
     (kill-buffer (current-buffer)))))

(ert-deftest agent-fleet-cleanup-lisp-subsets-preserve-neighbors ()
  (dolist (case '((("p1") ("pane.close" (pane_id . "p1")))
                  (("p1" "p2") ("tab.close" (tab_id . "a")))
                  (("p1" "p2" "p3") ("workspace.close" (workspace_id . "w1")))))
    (agent-fleet-cleanup-test--with-server
     (agent-fleet-cleanup-test--shells snapshot)
     (agent-fleet-cleanup :targets (car case) :no-confirm t)
     (should (equal (list (cadr case)) (agent-fleet-cleanup-test--writes requests))))))

(ert-deftest agent-fleet-cleanup-failure-does-not-retry-with-broader-scope ()
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup-test--shells snapshot)
   (setq failures '("w1"))
   (let ((report (agent-fleet-cleanup :targets '("p1" "p2" "p3" "p4") :no-confirm t)))
     (should (equal '("w2") (plist-get report :closed)))
     (should (equal "w1" (caar (plist-get report :failed)))))
   (should (equal '(("workspace.close" (workspace_id . "w1"))
                    ("workspace.close" (workspace_id . "w2")))
                  (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-missing-ack-is-not-success ()
  (agent-fleet-cleanup-test--with-server
   (setq ack nil)
   (let ((report (agent-fleet-cleanup :targets '("p4") :no-confirm t)))
     (should-not (plist-get report :closed))
     (should (plist-get report :failed)))))

(ert-deftest agent-fleet-cleanup-incomplete-topology-fails-closed ()
  (dolist (change '(missing duplicate count))
    (agent-fleet-cleanup-test--with-server
     (pcase change
       ('missing (setq snapshot '(:workspaces nil)))
       ('duplicate (push (car (plist-get snapshot :panes)) (plist-get snapshot :panes)))
       ('count (setf (plist-get (car (plist-get snapshot :tabs)) :pane_count) 100)))
     (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t)
                   :type 'herdr-protocol-error)
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-uncertain-terminal-identity-and-tombstones-protected ()
  (dolist (source '(missing gone))
    (agent-fleet-cleanup-test--with-server
     (if (eq source 'missing)
         (setf (plist-get (car (last (plist-get snapshot :panes))) :terminal_id) nil)
       (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
       (puthash "p4" t (herdr-session-gone-panes herdr-model--cache)))
     (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'user-error)
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-worktree-queries-are-explicit-and-non-git-safe ()
  (agent-fleet-cleanup-test--with-server
   (setq worktree-query
         (lambda (_ws) (signal 'herdr-request-error '(:code "not_git_worktree"))))
   (agent-fleet-cleanup :targets '("p4") :no-confirm t)
   (should (cl-every (lambda (r) (alist-get 'workspace_id (cdr r)))
                     (cl-remove-if-not (lambda (r) (equal "worktree.list" (car r))) requests))))
  (agent-fleet-cleanup-test--with-server
   (setq worktree-query (lambda (_ws) (signal 'herdr-request-error '(:code "other"))))
   (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'herdr-request-error)
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-worktree-list-validation ()
  (dolist (response '(nil (:type "worktree_list")
                         (:type "worktree_list" :worktrees ((:path "")))))
    (agent-fleet-cleanup-test--with-server
     (setq worktree-query (lambda (_ws) response))
     (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t)
                   :type 'herdr-protocol-error)
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-project-filter-uses-public-query ()
  (agent-fleet-cleanup-test--with-server
   (let (queried)
     (cl-letf (((symbol-function 'agent-fleet-project-root-for-cwd) (lambda (_) "/project"))
               ((symbol-function 'agent-fleet-project-agents) (lambda (_) (setq queried t) nil)))
       (agent-fleet-cleanup :project "/project"))
     (should queried)
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-unknown-agent-membership-after-snapshot-vetoes-all ()
  (dolist (owner '(nil "" "w2"))
    (agent-fleet-cleanup-test--with-server
     (setq before-snapshot
           (lambda ()
             (when (= snapshot-count 2)
               (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
               (puthash "new" (make-herdr-agent :id "new" :workspace-id owner :agent-status "done")
                        (herdr-session-agents herdr-model--cache)))))
     (should (plist-get (agent-fleet-cleanup :targets '("p4") :no-confirm t) :skipped))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-pane-only-conflicting-membership-vetoes-siblings ()
  (dolist (owner '(nil "" "other-workspace"))
    (dolist (evidence '(agent session))
      (agent-fleet-cleanup-test--with-server
       (agent-fleet-cleanup-test--shells snapshot)
       (setq before-snapshot
             (lambda ()
               (when (= snapshot-count 2)
                 (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
                 (let ((p (herdr-model-find-pane "p2")))
                   (setf (herdr-pane-workspace-id p) owner)
                   (if (eq evidence 'agent)
                       (setf (herdr-pane-agent p) "codex")
                     (setf (herdr-pane-agent-session p)
                           (make-herdr-agent-session :value "session")))))))
       (should (plist-get (agent-fleet-cleanup :targets '("p1") :no-confirm t) :skipped))
       (should-not (agent-fleet-cleanup-test--writes requests))))))

(ert-deftest agent-fleet-cleanup-unmapped-missing-task-member-fails-closed ()
  (agent-fleet-cleanup-test--with-server
   (setq agent-fleet--tasks (list (make-agent-fleet-task :id "unknown" :agents '("missing"))))
   (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'user-error)
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-every-cached-linkage-can-veto ()
  (agent-fleet-cleanup-test--with-server
   (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
   (herdr-model-upsert-worktree
    '(:path "/tmp/primary" :open_workspace_id "w2" :is_linked_worktree :false))
   (herdr-model-upsert-worktree
    '(:path "/tmp/linked" :open_workspace_id "w2" :is_linked_worktree t))
   (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'user-error)
   (should-not (agent-fleet-cleanup-test--writes requests))))

(provide 'agent-fleet-cleanup-test)
;;; agent-fleet-cleanup-test.el ends here
