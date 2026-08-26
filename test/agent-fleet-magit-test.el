;;; agent-fleet-magit-test.el --- ERT tests for agent-fleet-magit.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests: Magit root resolution, the availability guard, and the
;; status/diff commands' wiring (Magit stubbed — it need not be installed),
;; plus the worktree-cleanup batch command.  Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l agent-fleet-magit -l agent-fleet-worktree -l herdr-mock-server \
;;         -l test/agent-fleet-test -l test/agent-fleet-magit-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr)
(require 'herdr-model)
(require 'agent-fleet)
(require 'agent-fleet-magit)
(require 'agent-fleet-worktree)
(require 'herdr-mock-server)
(require 'agent-fleet-test)            ; harness: with-agent-fleet-mock, --pump


;;; --- Helpers --------------------------------------------------------

(defun agent-fleet-magit-test--make-git-repo ()
  "Create an empty temp git repo and return its directory path.
`git init' is enough for `vc-root-dir'/`project-try-vc' to resolve a root
\(mirrors `agent-fleet-project-test--make-git-repo')."
  (let ((dir (make-temp-file "af-magit-" t)))
    (call-process "git" nil nil nil "init" "--quiet" dir)
    dir))


;;; --- Root resolution (the testable core) ----------------------------

(ert-deftest agent-fleet-magit-root-prefers-cwd-root ()
  "An agent whose cwd is a git repo resolves to that repo's root.
For a worktree agent the cwd is inside the worktree, so this returns the
worktree root; here a plain repo cwd returns the repo root."
  (let ((repo (agent-fleet-magit-test--make-git-repo)))
    (unwind-protect
        (let* ((agent (make-herdr-agent :id "x" :cwd repo))
               (root (agent-fleet-magit--root-for-agent agent)))
          (should root)
          (should (file-equal-p repo root)))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-magit-root-keeps-linked-worktree-checkout ()
  "Magit opens the linked checkout, not its primary repository."
  (let* ((parent (make-temp-file "af-magit-linked-" t))
         (repo (expand-file-name "main" parent))
         (linked (expand-file-name "linked" parent))
         (subdir (expand-file-name "src" linked)))
    (unwind-protect
        (progn
          (make-directory repo)
          (should (= 0 (call-process "git" nil nil nil "-C" repo "init"
                                     "--quiet")))
          (should (= 0 (call-process "git" nil nil nil "-C" repo "config"
                                     "user.email" "test@example.invalid")))
          (should (= 0 (call-process "git" nil nil nil "-C" repo "config"
                                     "user.name" "Agent Fleet Test")))
          ;; Never inherit a developer's global commit-signing policy.  A
          ;; headless test cannot answer a GPG/pinentry prompt.
          (should (= 0 (call-process "git" nil nil nil "-C" repo "config"
                                     "commit.gpgSign" "false")))
          (with-temp-file (expand-file-name "README" repo)
            (insert "test\n"))
          (should (= 0 (call-process "git" nil nil nil "-C" repo "add" ".")))
          (should (= 0 (call-process "git" nil nil nil "-C" repo "commit"
                                     "--quiet" "-m" "init")))
          (should (= 0 (call-process "git" nil nil nil "-C" repo "worktree"
                                     "add" "--quiet" "-b" "linked-test"
                                     linked)))
          (make-directory subdir)
          (let ((agent (make-herdr-agent :id "x" :cwd subdir)))
            (should (file-equal-p
                     linked (agent-fleet-magit--root-for-agent agent)))
            ;; Project grouping deliberately still identifies the primary
            ;; repository; Magit checkout resolution has different semantics.
            (should (file-equal-p
                     repo (agent-fleet-project-root-for-cwd subdir)))))
      (when (file-directory-p repo)
        (ignore-errors
          (call-process "git" nil nil nil "-C" repo "worktree" "remove"
                        "--force" linked)))
      (when (file-exists-p parent) (delete-directory parent t)))))

(ert-deftest agent-fleet-magit-root-worktree-fallback ()
  "An agent with no usable cwd but a cached worktree falls back to the
worktree path.  A non-existent
worktree path yields nil."
  (let* ((real-dir (make-temp-file "af-magit-wt-" t))
         (session (herdr-model--empty-session))
         (agent (make-herdr-agent :id "w1:p1" :workspace-id "w1" :cwd nil))
         (agent2 (make-herdr-agent :id "w2:p1" :workspace-id "w2" :cwd nil)))
    (puthash real-dir
             (make-herdr-worktree :path real-dir :open-workspace-id "w1")
             (herdr-session-worktrees session))
    (puthash "/no/such/dir"
             (make-herdr-worktree :path "/no/such/dir" :open-workspace-id "w2")
             (herdr-session-worktrees session))
    (herdr-model-set-cache session)
    (unwind-protect
        (progn
          (should (equal real-dir (agent-fleet-magit--root-for-agent agent)))
          (should-not (agent-fleet-magit--root-for-agent agent2)))
      (herdr-model-clear-cache)
      (when (file-exists-p real-dir) (delete-directory real-dir t)))))

(ert-deftest agent-fleet-magit-root-non-repo-returns-nil ()
  "An agent whose cwd is not a git repo (and has no worktree) has no root."
  (let ((dir (make-temp-file "af-magit-nogit-" t)))
    (unwind-protect
        (should-not (agent-fleet-magit--root-for-agent
                     (make-herdr-agent :id "x" :cwd dir)))
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-magit-root-nil-agent ()
  "A nil/unresolvable target yields nil, never an error."
  (should-not (agent-fleet-magit--root-for-agent nil))
  (should-not (agent-fleet-magit--root-for-agent "no-such-agent")))


;;; --- Availability guard ---------------------------------------------

(ert-deftest agent-fleet-magit-status-errors-when-magit-absent ()
  "When Magit is not installed, `agent-fleet-magit-status' `user-error's
clearly (Magit is an optional dependency).  The guard fires
before agent resolution, so any target triggers it."
  (skip-unless (not (featurep 'magit)))
  (should-error (agent-fleet-magit-status (make-herdr-agent :id "x"))
                :type 'user-error))

(ert-deftest agent-fleet-magit-diff-errors-when-magit-absent ()
  "Likewise `agent-fleet-magit-diff' `user-error's without Magit."
  (skip-unless (not (featurep 'magit)))
  (should-error (agent-fleet-magit-diff (make-herdr-agent :id "x"))
                :type 'user-error))


;;; --- Command wiring (Magit stubbed) ---------------------------------

(ert-deftest agent-fleet-magit-status-calls-magit-status-with-root ()
  "`agent-fleet-magit-status' opens `magit-status' on the agent's resolved
root.  `--available-p' is stubbed to t and `magit-status' to a capture
lambda, so this runs without Magit installed."
  (let ((repo (agent-fleet-magit-test--make-git-repo))
        captured)
    (unwind-protect
        (let* ((agent (make-herdr-agent :id "x" :cwd repo))
               (root (agent-fleet-project-root-for-cwd repo)))
          (cl-letf (((symbol-function 'agent-fleet-magit--available-p)
                     (lambda () t))
                    ((symbol-function 'magit-status)
                     (lambda (dir) (push dir captured))))
            (agent-fleet-magit-status agent))
          (should (= 1 (length captured)))
          (should (file-equal-p root (car captured))))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-magit-diff-calls-magit-diff-working-tree ()
  "`agent-fleet-magit-diff' calls `magit-diff-working-tree' with
`default-directory' bound to the agent's root.  Magit stubbed."
  (let ((repo (agent-fleet-magit-test--make-git-repo))
        captured)
    (unwind-protect
        (let* ((agent (make-herdr-agent :id "x" :cwd repo))
               (root (agent-fleet-project-root-for-cwd repo)))
          (cl-letf (((symbol-function 'agent-fleet-magit--available-p)
                     (lambda () t))
                    ((symbol-function 'magit-diff-working-tree)
                     (lambda (&rest _) (push default-directory captured))))
            (agent-fleet-magit-diff agent))
          (should (= 1 (length captured)))
          (should (file-equal-p root (car captured))))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-magit-status-no-root-messages ()
  "An agent with no accessible git root messages and returns nil (no error)
even when Magit is available."
  (let ((dir (make-temp-file "af-magit-nogit-" t))
        (msg nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-magit--available-p)
                   (lambda () t))
                  ((symbol-function 'message)
                   (lambda (format &rest args) (setq msg (apply #'format format args)))))
          (should-not (agent-fleet-magit-status
                       (make-herdr-agent :id "x" :cwd dir)))
          (should (string-match-p "no accessible git root" msg)))
      (when (file-exists-p dir) (delete-directory dir t)))))


;;; --- Worktree cleanup (delete finished worktrees) ----------------

(ert-deftest agent-fleet-worktree-cleanup-removes-done-agent-worktrees ()
  "`worktree-cleanup' removes the worktrees of `done' agents (issuing
`worktree.remove' for the done agent's workspace) and leaves non-done
agents alone.  NO-CONFIRM skips the y-or-n prompt."
  (with-agent-fleet-mock path server
    (let ((done-agent (agent-fleet-start 'claude :name "done-a"
                                         :worktree t :cwd "/tmp/repo1"))
          (live-agent (agent-fleet-start 'claude :name "live-a"
                                         :worktree t :cwd "/tmp/repo2")))
      (agent-fleet-test--pump)
      ;; drive the done-agent to `done' (status-only event patches the cache)
      (herdr-mock-push-event server "pane_agent_status_changed"
        `(:pane_id ,(herdr-agent-id done-agent) :agent_status "done"))
      (agent-fleet-test--pump)
      (should (eq 'done (agent-fleet-status done-agent)))
      (let* ((done-ws (herdr-agent-workspace-id done-agent))
             (live-ws (herdr-agent-workspace-id live-agent))
             (done-path (herdr-worktree-path
                         (agent-fleet--worktree-for-agent done-agent))))
        (agent-fleet-worktree-cleanup t)   ; no-confirm
        ;; worktree.remove targeted the done agent's workspace
        (should (equal done-ws
                       (plist-get (agent-fleet-test--last-request
                                   server "worktree.remove")
                                  :workspace_id)))
        ;; done worktree gone from the cache; live worktree survives
        (should-not (herdr-model-find-worktree done-path))
        (should (herdr-model-find-worktree-for-workspace live-ws))))))

(ert-deftest agent-fleet-worktree-cleanup-nothing-done ()
  "With no `done' agents, cleanup messages and removes nothing."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "live-a"
                                    :worktree t :cwd "/tmp/repo")))
      (agent-fleet-test--pump)
      (should (eq 0 (agent-fleet-worktree-cleanup t)))
      (should-not (agent-fleet-test--saw-request-p server "worktree.remove"))
      ;; the live agent's worktree is untouched
      (should (agent-fleet--worktree-for-agent agent)))))

(provide 'agent-fleet-magit-test)
;;; agent-fleet-magit-test.el ends here
