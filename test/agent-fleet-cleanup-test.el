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

(defmacro agent-fleet-cleanup-test--with-server (&rest body)
  "Run BODY against strict, mutable RPC fixtures, never a real Herdr server."
  (declare (indent 0))
  `(let ((snapshot (copy-tree (agent-fleet-cleanup-test--snapshot)))
         (worktrees nil) (requests nil) (failures nil) (ack '(:type "ok"))
         (worktree-query nil)
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
                      (if (equal method "worktree.remove")
                          (progn
                            (setq worktrees (cl-remove id worktrees
                                                       :key (lambda (w) (plist-get w :open_workspace_id))
                                                       :test #'equal))
                            (list :type "worktree_removed" :workspace_id id :path (concat "/tmp/" id)))
                        ack)))
                   (t (ert-fail (format "Unexpected RPC %s" method)))))))
       ,@body)))

(defun agent-fleet-cleanup-test--writes (requests)
  "Return destructive REQUESTS in issue order."
  (reverse (cl-remove-if-not
            (lambda (r) (member (car r) '("pane.close" "tab.close" "workspace.close" "worktree.remove")))
            requests)))

(ert-deftest agent-fleet-cleanup-runtime-preview-is-read-only ()
  (agent-fleet-cleanup-test--with-server
   (let ((report (agent-fleet-cleanup)))
     (should (= 4 (length (plist-get report :candidates))))
     (should-not (plist-get report :closed))
     (should-not (agent-fleet-cleanup-test--writes requests))
     (should (string-match-p "shell/other processes"
                             (plist-get (car (last (plist-get report :candidates))) :label))))))

(ert-deftest agent-fleet-cleanup-runtime-reclaims-whole-workspace-including-last-tab ()
  (agent-fleet-cleanup-test--with-server
   (should (equal '("w1" "w2")
                  (plist-get (agent-fleet-cleanup :targets '("p1" "p2" "p3" "p4")
                                                  :no-confirm t) :closed)))
   (should (equal '(("workspace.close" (workspace_id . "w1"))
                    ("workspace.close" (workspace_id . "w2")))
                  (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-runtime-preserves-unselected-neighbors ()
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup :targets '("p1" "p2") :no-confirm t)
   (should (equal '(("tab.close" (tab_id . "a"))) (agent-fleet-cleanup-test--writes requests))))
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup :targets '("p1") :no-confirm t)
   (should (equal '(("pane.close" (pane_id . "p1"))) (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-runtime-protects-agent-states-and-pending ()
  (dolist (state '("working" "idle" "blocked" "unknown"))
    (agent-fleet-cleanup-test--with-server
     (setf (plist-get (car (plist-get snapshot :agents)) :agent_status) state)
     (should-error (agent-fleet-cleanup :targets '("p1") :no-confirm t) :type 'user-error)
     (should-not (agent-fleet-cleanup-test--writes requests))))
  (agent-fleet-cleanup-test--with-server
   (setf (plist-get snapshot :agents)
         (cons (append (car (plist-get snapshot :agents)) '(:launch_pending t))
               (cdr (plist-get snapshot :agents))))
   (should-error (agent-fleet-cleanup :targets '("p1") :no-confirm t) :type 'user-error)))

(ert-deftest agent-fleet-cleanup-runtime-never-closes-worktree-resources ()
  (dolist (source '(list snapshot cache))
    (agent-fleet-cleanup-test--with-server
     (pcase source
       ('list (setq worktrees '((:path "/tmp/wt" :open_workspace_id "w1"))))
       ('snapshot (setf (plist-get snapshot :workspaces)
                        '((:workspace_id "w1" :tab_count 2 :worktree (:path "/tmp/wt"))
                          (:workspace_id "w2" :tab_count 1))))
       ('cache
        (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
        (herdr-model-upsert-worktree '(:path "/tmp/wt" :open_workspace_id "w1"))))
     (should-error (agent-fleet-cleanup :targets '("p1") :no-confirm t) :type 'user-error)
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-runtime-rechecks-state-linkage-and-connection ()
  (dolist (change '(state worktree connection))
    (agent-fleet-cleanup-test--with-server
     (setq before-snapshot
           (lambda ()
             (when (= snapshot-count 2)
               (pcase change
                 ('state (setf (plist-get (car (plist-get snapshot :agents)) :agent_status) "working"))
                 ('worktree
                  (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
                  (herdr-model-upsert-worktree '(:path "/tmp/wt" :open_workspace_id "w1")))
                 ('connection (setq herdr--conn (make-herdr--connection)))))))
     (should (plist-get (agent-fleet-cleanup :targets '("p1") :no-confirm t) :failed))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-runtime-new-pane-vetoes-container-close ()
  (agent-fleet-cleanup-test--with-server
   (setq before-snapshot
         (lambda ()
           (when (= snapshot-count 2)
             (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
             (puthash "new" (make-herdr-pane :id "new" :workspace-id "w1" :tab-id "a")
                      (herdr-session-panes herdr-model--cache)))))
   (should (plist-get (agent-fleet-cleanup :targets '("p1" "p2" "p3") :no-confirm t) :failed))
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-runtime-new-agent-vetoes-old-snapshot ()
  (agent-fleet-cleanup-test--with-server
   (setq before-snapshot
         (lambda ()
           (when (= snapshot-count 2)
             (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
             (setf (herdr-agent-agent-status (herdr-model-find-agent "p1")) "working"))))
   (should (plist-get (agent-fleet-cleanup :targets '("p1") :no-confirm t) :failed))
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-runtime-membership-change-and-missing-pane-veto ()
  (dolist (change '(move disappear))
    (agent-fleet-cleanup-test--with-server
     (setq before-snapshot
           (lambda ()
             (when (= snapshot-count 2)
               (if (eq change 'move)
                   (setf (plist-get (car (plist-get snapshot :panes)) :terminal_id) "replacement")
                 (setf (plist-get snapshot :panes) (cdr (plist-get snapshot :panes)))))))
     (should (plist-get (agent-fleet-cleanup :targets '("p1") :no-confirm t) :failed))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-runtime-failure-and-missing-ack ()
  (agent-fleet-cleanup-test--with-server
   (setq failures '("w1"))
   (let ((report (agent-fleet-cleanup :targets '("p1" "p2" "p3" "p4") :no-confirm t)))
     (should (equal '("w2") (plist-get report :closed)))
     (should (equal "w1" (caar (plist-get report :failed))))))
  (agent-fleet-cleanup-test--with-server
   (setq ack nil)
   (let ((report (agent-fleet-cleanup :targets '("p4") :no-confirm t)))
     (should-not (plist-get report :closed))
     (should (eq 'herdr-protocol-error (cadr (car (plist-get report :failed))))))))

(ert-deftest agent-fleet-cleanup-runtime-incomplete-snapshot-is-not-empty ()
  (agent-fleet-cleanup-test--with-server
   (setf (plist-get snapshot :panes) nil)
   (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t)
                 :type 'herdr-protocol-error)
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-interactive-selection-confirmation-and-empty ()
  (dolist (selection '(nil ("p4")))
    (agent-fleet-cleanup-test--with-server
     (let (asked)
       (cl-letf (((symbol-function 'agent-fleet-cleanup--read-filter) (lambda () nil))
                 ((symbol-function 'completing-read-multiple) (lambda (&rest _) selection))
                 ((symbol-function 'yes-or-no-p) (lambda (_) (setq asked t) nil)))
         (let ((current-prefix-arg '(4)))
           (call-interactively #'agent-fleet-cleanup)))
       (should (eq (not (null selection)) (not (null asked))))
       (should-not (agent-fleet-cleanup-test--writes requests))))))

(ert-deftest agent-fleet-cleanup-worktree-selection-does-not-call-runtime-close ()
  (agent-fleet-cleanup-test--with-server
   (setq worktrees '((:path "/tmp/w1" :open_workspace_id "w1" :is_linked_worktree t)))
   (let ((report (agent-fleet-cleanup-worktrees :targets '("w1") :no-confirm t)))
     (should (equal '("w1") (plist-get report :closed)))
     (should (equal '("worktree.remove") (mapcar #'car (agent-fleet-cleanup-test--writes requests))))
     (should (eq :false (alist-get "force" (cdar (agent-fleet-cleanup-test--writes requests))
                                   nil nil #'equal))))))

(ert-deftest agent-fleet-cleanup-worktree-protects-mixed-and-missing-task-members ()
  (dolist (state '("working" "missing"))
    (agent-fleet-cleanup-test--with-server
     (setq worktrees '((:path "/tmp/w1" :open_workspace_id "w1" :is_linked_worktree t)))
     (setq agent-fleet--tasks
           (list (make-agent-fleet-task :id "task" :agents (list "p1" state)
                                        :workspaces '(("p1" . "w1")) :finished-at 1)))
     (should-error (agent-fleet-cleanup-worktrees :task "task" :targets '("w1") :no-confirm t)
                   :type 'user-error)
     (should (agent-fleet-task-find "task"))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-worktree-task-partial-failure-retry ()
  (agent-fleet-cleanup-test--with-server
   (setq worktrees '((:path "/tmp/w1" :open_workspace_id "w1" :is_linked_worktree t)
                     (:path "/tmp/w2" :open_workspace_id "w2" :is_linked_worktree t)))
   ;; Make p4 a known done task agent too.
   (setf (plist-get snapshot :agents)
         (append (plist-get snapshot :agents)
                 '((:pane_id "p4" :workspace_id "w2" :tab_id "c" :agent "codex" :agent_status "done"))))
   (let ((task (make-agent-fleet-task :id "task" :agents '("p1" "p4")
                                      :workspaces '(("p1" . "w1") ("p4" . "w2")))))
     (setq agent-fleet--tasks (list task) failures '("w2"))
     (puthash "p1" "task" agent-fleet--agent-tasks)
     (puthash "p4" "task" agent-fleet--agent-tasks)
     (let ((report (agent-fleet-cleanup-worktrees :task task :targets '("w1" "w2") :no-confirm t)))
       (should (equal '("w1") (plist-get report :closed)))
       (should (equal '("p4") (agent-fleet-task-agents task)))
       (should-not (gethash "p1" agent-fleet--agent-tasks))
       (should (gethash "p4" agent-fleet--agent-tasks)))
     (setq failures nil)
     (should (equal '("w2") (plist-get (agent-fleet-cleanup-worktrees
					:task task :targets '("w2") :no-confirm t) :closed)))
     (should-not agent-fleet--tasks))))

(ert-deftest agent-fleet-cleanup-task-is-filter-not-deletion-engine ()
  (agent-fleet-cleanup-test--with-server
   (setq agent-fleet--tasks (list (make-agent-fleet-task
                                   :id "one" :agents '("p1") :workspaces '(("p1" . "w1")))))
   (let ((report (agent-fleet-cleanup :task "one")))
     (should (equal '("p1") (mapcar (lambda (c) (plist-get c :id)) (plist-get report :candidates)))))
   (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-project-filter-reuses-public-query ()
  (agent-fleet-cleanup-test--with-server
   (let (queried)
     (cl-letf (((symbol-function 'agent-fleet-project-agents)
                (lambda (project)
                  (setq queried project)
                  (list (herdr-model-find-agent "p2"))))
               ((symbol-function 'agent-fleet-project-root-for-cwd)
                (lambda (_) "/project")))
       (let ((report (agent-fleet-cleanup :project "/project")))
         (should (equal "/project" queried))
         (should (equal '("p2" "p4")
                        (mapcar (lambda (c) (plist-get c :id)) (plist-get report :candidates)))))))))

(ert-deftest agent-fleet-cleanup-worktree-list-fails-closed ()
  (dolist (result '(nil (:type "worktree_list") (:type "ok" :worktrees nil)
			(:type "worktree_list" :worktrees ((:path nil)))
			(:type "worktree_list" :worktrees (42))
			(:type "worktree_list" :worktrees
                               ((:path "/a" :open_workspace_id "w")
				(:path "/b" :open_workspace_id "w")))))
    (should-error (herdr-model-parse-worktree-list result) :type 'herdr-protocol-error)))

(ert-deftest agent-fleet-cleanup-model-preserves-worktree-linkage ()
  (let* ((raw (agent-fleet-cleanup-test--snapshot))
         (herdr-model--cache (herdr-model-parse-cleanup-snapshot raw)))
    (herdr-model-upsert-workspace
     '(:workspace_id "w1" :worktree (:path "/tmp/linked")))
    (should (herdr-workspace-worktree (herdr-model-find-workspace "w1")))
    (herdr-model-upsert-workspace '(:workspace_id "w1" :worktree nil))
    (should-not (herdr-workspace-worktree (herdr-model-find-workspace "w1")))))

(ert-deftest agent-fleet-cleanup-worktree-path-change-vetoes-removal ()
  (agent-fleet-cleanup-test--with-server
   (setq worktrees '((:path "/tmp/w1" :open_workspace_id "w1" :is_linked_worktree t)))
   (cl-letf (((symbol-function 'yes-or-no-p)
              (lambda (_)
                (setq worktrees '((:path "/tmp/replaced" :open_workspace_id "w1"
					 :is_linked_worktree t)))
                t)))
     (should (plist-get (agent-fleet-cleanup-worktrees :targets '("w1")) :failed))
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-worktree-always-confirms-interactive-selection ()
  (agent-fleet-cleanup-test--with-server
   (setq worktrees '((:path "/tmp/w1" :open_workspace_id "w1" :is_linked_worktree t)))
   (let (asked)
     (cl-letf (((symbol-function 'completing-read-multiple) (lambda (&rest _) '("w1")))
               ((symbol-function 'yes-or-no-p) (lambda (_) (setq asked t) nil)))
       (should (plist-get (agent-fleet-cleanup-worktrees :select t :no-confirm t) :cancelled))
       (should asked)
       (should-not (agent-fleet-cleanup-test--writes requests))))))

(ert-deftest agent-fleet-cleanup-runtime-refuses-new-group-scope ()
  (agent-fleet-cleanup-test--with-server
   (setq failures '("w1"))
   (let ((report (agent-fleet-cleanup :targets '("p1" "p2" "p3") :no-confirm t)))
     (should (plist-get report :failed))
     ;; No retry with close_group or an alternate destructive operation.
     (should (equal '(("workspace.close" (workspace_id . "w1")))
                    (agent-fleet-cleanup-test--writes requests))))))

(ert-deftest agent-fleet-cleanup-repeat-reads-authoritative-state ()
  (agent-fleet-cleanup-test--with-server
   (agent-fleet-cleanup :targets '("p4") :no-confirm t)
   (setf (plist-get snapshot :workspaces) (butlast (plist-get snapshot :workspaces))
         (plist-get snapshot :tabs) (butlast (plist-get snapshot :tabs))
         (plist-get snapshot :panes) (butlast (plist-get snapshot :panes)))
   (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t) :type 'user-error)
   (should (= 1 (length (agent-fleet-cleanup-test--writes requests))))))

(ert-deftest agent-fleet-cleanup-missing-task-member-vetoes-stale-snapshot ()
  (agent-fleet-cleanup-test--with-server
    (setq agent-fleet--tasks (list (make-agent-fleet-task
                                   :id "one" :agents '("p1" "p2")
                                   :workspaces '(("p1" . "w1") ("p2" . "w1")))))
    (setq before-snapshot
          (lambda ()
            (when (= snapshot-count 2)
              (setq herdr-model--cache (herdr-model-parse-cleanup-snapshot snapshot))
              (herdr-model-mark-pane-gone "p2"))))
    (should (plist-get (agent-fleet-cleanup :targets '("p1") :no-confirm t) :failed))
    (should-not (agent-fleet-cleanup-test--writes requests))))

(ert-deftest agent-fleet-cleanup-non-git-workspaces-remain-cleanable ()
  (agent-fleet-cleanup-test--with-server
   (setq worktree-query
         (lambda (_ws)
           (signal 'herdr-request-error
                   '(:method "worktree.list" :code "not_git_worktree"))))
   (should (equal '("w2")
                  (plist-get (agent-fleet-cleanup :targets '("p4") :no-confirm t)
                             :closed)))
   (should (equal "session.snapshot" (caar (last requests))))))

(ert-deftest agent-fleet-cleanup-queries-every-repository-explicitly ()
  (agent-fleet-cleanup-test--with-server
   (setq worktree-query
         (lambda (ws)
           (list :type "worktree_list"
                 :worktrees (list (list :path (concat "/repo/" ws)
                                        :is_linked_worktree t :open_workspace_id ws)))))
   (should (= 2 (length (plist-get (agent-fleet-cleanup-worktrees) :candidates))))
   (should-not (plist-get (agent-fleet-cleanup) :candidates))))

(ert-deftest agent-fleet-cleanup-non-git-does-not-erase-positive-linkage ()
  (agent-fleet-cleanup-test--with-server
   (setq worktree-query
         (lambda (_ws) (signal 'herdr-request-error '(:code "not_git_worktree"))))
   (setf (plist-get (car (plist-get snapshot :workspaces)) :worktree) '(:path "/linked"))
   (should (equal '("p4") (mapcar (lambda (c) (plist-get c :id))
                                 (plist-get (agent-fleet-cleanup) :candidates))))))

(ert-deftest agent-fleet-cleanup-mixed-git-and-non-git-workspaces ()
  (agent-fleet-cleanup-test--with-server
   (setq worktree-query
         (lambda (ws)
           (if (equal ws "w2")
               (signal 'herdr-request-error '(:code "not_git_worktree"))
             '(:type "worktree_list"
               :worktrees ((:path "/repo/wt" :is_linked_worktree t
                            :open_workspace_id "w1"))))))
   (should (equal '("p4") (mapcar (lambda (c) (plist-get c :id))
                                 (plist-get (agent-fleet-cleanup) :candidates))))
   (should (equal '("w1") (mapcar (lambda (c) (plist-get c :id))
                                 (plist-get (agent-fleet-cleanup-worktrees) :candidates))))))

(ert-deftest agent-fleet-cleanup-unexpected-worktree-errors-remain-fatal ()
  (dolist (code '("workspace_not_found" "worktree_list_failed" "permission_denied"))
    (agent-fleet-cleanup-test--with-server
     (setq worktree-query
           (lambda (_ws) (signal 'herdr-request-error (list :code code))))
     (should-error (agent-fleet-cleanup :targets '("p4") :no-confirm t)
                   :type 'herdr-request-error)
     (should-not (agent-fleet-cleanup-test--writes requests)))))

(ert-deftest agent-fleet-cleanup-deduplicates-shared-repository-lists ()
  (agent-fleet-cleanup-test--with-server
   (setq worktrees '((:path "/repo/wt" :is_linked_worktree t :open_workspace_id "w1")))
   (should (= 1 (length (plist-get (agent-fleet-cleanup-worktrees) :candidates))))))

(provide 'agent-fleet-cleanup-test)
;;; agent-fleet-cleanup-test.el ends here
