;;; agent-fleet-worktree-test.el --- ERT tests for agent-fleet-worktree.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests: the `:worktree t' start flow (worktree.create then
;; agent.start on the root pane), worktree list/remove/status — all
;; against the mock server (no real Herdr).
;; Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l agent-fleet-worktree -l herdr-mock-server \
;;         -l test/agent-fleet-worktree-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'herdr)
(require 'agent-fleet)
(require 'agent-fleet-worktree)
(require 'herdr-mock-server)
(require 'agent-fleet-test)            ; harness: with-agent-fleet-mock, --pump


;;; --- :worktree t start flow ----------------------------------------

(ert-deftest agent-fleet-start-worktree-issues-create-then-agent-start ()
  "`:worktree t' provisions via worktree.create (which returns a root pane),
then agent.start targets that root pane — no pane.split/workspace.create.
The worktree + workspace are eagerly cached, and the agent's workspace
matches the worktree's `open_workspace_id' (so `w' status resolves)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "wt-agent"
                                    :worktree t :cwd "/tmp/myrepo")))
      (should (herdr-agent-p agent))
      ;; worktree.create was called with the source cwd; no split/workspace.create.
      (let ((create-params (agent-fleet-test--last-request server "worktree.create")))
        (should create-params)
        (should (equal "/tmp/myrepo" (plist-get create-params :cwd)))
        (should (eq :false (plist-get create-params :focus))))
      (should-not (agent-fleet-test--saw-request-p server "pane.split"))
      (should-not (agent-fleet-test--saw-request-p server "workspace.create"))
      ;; agent.start targets the root pane returned by worktree.create.
      (let ((start-params (agent-fleet-test--last-request server "agent.start")))
        (should (equal "wt-agent" (plist-get start-params :name)))
        (should (equal (herdr-agent-id agent) (plist-get start-params :pane_id))))
      ;; the worktree is eagerly cached for the agent's workspace.
      (let* ((ws-id (herdr-agent-workspace-id agent))
             (wt (herdr-model-find-worktree-for-workspace ws-id)))
        (should wt)
        (should (equal ws-id (herdr-worktree-open-workspace-id wt)))
        (should (string-prefix-p "/tmp/myrepo" (herdr-worktree-path wt)))))))

(ert-deftest agent-fleet-start-worktree-forwards-branch-and-base ()
  "`:branch'/`:base' are forwarded to worktree.create params."
  (with-agent-fleet-mock path server
    (agent-fleet-start 'claude :name "wt-br" :worktree t :cwd "/tmp/repo"
                       :branch "feature-x" :base "main")
    (let ((p (agent-fleet-test--last-request server "worktree.create")))
      (should (equal "feature-x" (plist-get p :branch)))
      (should (equal "main" (plist-get p :base))))))

(ert-deftest agent-fleet-start-worktree-requires-cwd ()
  "`:worktree t' without :cwd signals provisioning-failed (a worktree needs
a source repo).  No RPC is issued."
  (with-agent-fleet-mock path server
    (should-error (agent-fleet-start 'claude :name "x" :worktree t)
                  :type 'agent-fleet-provisioning-failed)
    (should-not (agent-fleet-test--saw-request-p server "worktree.create"))))

(ert-deftest agent-fleet-start-failure-rolls-back-provisioned-worktree ()
  "A failed agent.start closes its pane and removes its fresh worktree."
  (with-agent-fleet-mock path server
    (let ((handlers
           (mapcar
            (lambda (cell)
              (if (equal (car cell) "agent.start")
                  (cons "agent.start"
                        (lambda (_params)
                          (list 'error "start_failed" "cannot launch")))
                cell))
            (herdr-mock-default-agent-handlers))))
      (herdr-mock-set-handlers server handlers)
      (should-error
       (agent-fleet-start 'claude :name "broken" :worktree t
                          :cwd "/tmp/repo")
       :type 'herdr-request-error)
      (should (agent-fleet-test--saw-request-p server "pane.close"))
      (should (agent-fleet-test--saw-request-p server "worktree.remove"))
      (should-not (herdr-model-worktrees)))))


;;; --- list / remove / status ----------------------------------------

(ert-deftest agent-fleet-worktree-list-populates-cache ()
  "`worktree-list' calls worktree.list and upserts each result, so a
worktree dropped from the cache is restored."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "wt-agent"
                                    :worktree t :cwd "/tmp/myrepo")))
      (agent-fleet-test--pump)
      (let* ((ws-id (herdr-agent-workspace-id agent))
             (wt (herdr-model-find-worktree-for-workspace ws-id))
             (path (herdr-worktree-path wt)))
        ;; drop it from the cache; worktree-list must repopulate.
        (herdr-model-remove-worktree path)
        (should-not (herdr-model-find-worktree path))
        (let ((structs (agent-fleet-worktree-list)))
          (should (agent-fleet-test--saw-request-p server "worktree.list"))
          (should (cl-some (lambda (s) (equal (herdr-worktree-path s) path))
                           structs)))
        (should (herdr-model-find-worktree path))))))

(ert-deftest agent-fleet-worktree-list-removes-stale-unscoped-cache ()
  "An unscoped worktree.list replaces, rather than only extends, the cache."
  (with-agent-fleet-mock path server
    (herdr-model-upsert-worktree
     '(:path "/tmp/gone-worktree" :branch "gone"
       :open_workspace_id "gone"))
    (should (herdr-model-find-worktree "/tmp/gone-worktree"))
    (agent-fleet-worktree-list)
    (should-not (herdr-model-find-worktree "/tmp/gone-worktree"))))

(ert-deftest agent-fleet-worktree-remove-cleans-up ()
  "`worktree-remove' calls worktree.remove with the workspace id and drops
the worktree from the cache eagerly (the event also removes it)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "wt-agent"
                                    :worktree t :cwd "/tmp/myrepo")))
      (agent-fleet-test--pump)
      (let* ((ws-id (herdr-agent-workspace-id agent))
             (path (herdr-worktree-path
                    (herdr-model-find-worktree-for-workspace ws-id))))
        (should path)
        (let ((res (agent-fleet-worktree-remove ws-id)))
          (should (equal ws-id (plist-get res :workspace_id)))
          (should (equal path (plist-get res :path))))
        (let ((p (agent-fleet-test--last-request server "worktree.remove")))
          (should (equal ws-id (plist-get p :workspace_id)))
          (should (eq :false (plist-get p :force))))
        ;; eagerly removed from the cache.
        (should-not (herdr-model-find-worktree path))))))

(ert-deftest agent-fleet-worktree-remove-force-param ()
  "`worktree-remove' with FORCE forwards `force=true'."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "wt-agent"
                                    :worktree t :cwd "/tmp/myrepo")))
      (agent-fleet-test--pump)
      (let ((ws-id (herdr-agent-workspace-id agent)))
        (agent-fleet-worktree-remove ws-id t)
        (let ((p (agent-fleet-test--last-request server "worktree.remove")))
          (should (eq t (plist-get p :force))))))))

(ert-deftest agent-fleet-worktree-status-in-buffer-finds-worktree ()
  "`worktree-status' resolves the agent's workspace worktree, displays it
read-only, and returns the struct.  Metadata only (no pane output)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "wt-agent"
                                    :worktree t :cwd "/tmp/myrepo")))
      (agent-fleet-test--pump)
      (let* ((ws-id (herdr-agent-workspace-id agent))
             (buf-name "*Agent Fleet Worktree*")
             (wt nil))
        (unwind-protect
            (progn
              (setq wt (agent-fleet-worktree-status-in-buffer agent))
              (should (herdr-worktree-p wt))
              (should (equal ws-id (herdr-worktree-open-workspace-id wt)))
              (should (get-buffer buf-name))
              (with-current-buffer buf-name
                (should buffer-read-only)
                (should (eq 'quit-window
                            (lookup-key (current-local-map) (kbd "q"))))
                (should (string-match-p (herdr-worktree-path wt)
                                        (buffer-string)))
                ;; repo source is present (from the worktree.list refresh).
                (should (string-match-p "Repo" (buffer-string)))))
          (when (get-buffer buf-name)
            (kill-buffer buf-name)))))))

(ert-deftest agent-fleet-worktree-status-in-buffer-no-worktree-messages ()
  "`worktree-status' for an agent with no worktree returns nil and messages,
rather than erroring."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "plain"))) ; no :worktree
      (agent-fleet-test--pump)
      (should-not (agent-fleet-worktree-status-in-buffer agent)))))

(provide 'agent-fleet-worktree-test)
;;; agent-fleet-worktree-test.el ends here
