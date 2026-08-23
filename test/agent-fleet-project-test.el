;;; agent-fleet-project-test.el --- ERT tests for agent-fleet-project.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Phase 4 tests: project.el root resolution (canonical cwd, §32), the
;; project label/column, project-scoped agent queries, start-for-project,
;; and the dashboard `P' project filter (§69).
;; Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l agent-fleet-project -l agent-fleet-dashboard \
;;         -l herdr-mock-server -l test/agent-fleet-project-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'herdr)
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'agent-fleet-dashboard)
(require 'herdr-mock-server)
(require 'agent-fleet-test)            ; harness: with-agent-fleet-mock, --pump


;;; --- Helpers --------------------------------------------------------

(defun agent-fleet-project-test--make-git-repo ()
  "Create an empty temp git repo and return its directory path.
`git init' is enough for `vc-root-dir'/`project-try-vc' to resolve a root
(no commit needed); cleaned up by the caller via `delete-directory' t."
  (let ((dir (make-temp-file "af-proj-" t)))
    (call-process "git" nil nil nil "init" "--quiet" dir)
    dir))

(defun agent-fleet-project-test--goto-row (pane-id)
  "Move point to the dashboard row for PANE-ID; return non-nil if found.
The dashboard is in `*Agent Fleet*'.  Robust to sort order."
  (with-current-buffer "*Agent Fleet*"
    (goto-char (point-min))
    (cl-loop until (eobp)
             when (equal (tabulated-list-get-id) pane-id)
             return t
             do (forward-line 1))))


;;; --- Root resolution (PLAN.md §31/§32) ------------------------------

(ert-deftest agent-fleet-project-root-for-cwd-git ()
  "A git repo's cwd resolves to its canonical root; a subdir to the repo root."
  (let ((repo (agent-fleet-project-test--make-git-repo))
        (sub nil))
    (unwind-protect
        (progn
          (setq sub (expand-file-name "sub" repo))
          (make-directory sub)
          (should (agent-fleet-project-root-for-cwd repo))
          (should (file-equal-p repo (agent-fleet-project-root-for-cwd repo)))
          ;; a subdir resolves to the REPO root, not the subdir (§32: canonical cwd)
          (should (file-equal-p repo (agent-fleet-project-root-for-cwd sub))))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-project-root-groups-linked-worktrees ()
  "A linked worktree and its source checkout resolve to one project root."
  (let ((repo (agent-fleet-project-test--make-git-repo))
        (worktree (make-temp-name (expand-file-name "af-linked-" temporary-file-directory))))
    (unwind-protect
        (progn
          (should (eq 0 (process-file
                         "git" nil nil nil "-C" repo
                         "-c" "user.name=Agent Fleet Test"
                         "-c" "user.email=agent-fleet@example.invalid"
                         "-c" "commit.gpgSign=false"
                         "commit" "--quiet" "--allow-empty" "-m" "initial")))
          (should (eq 0 (process-file "git" nil nil nil "-C" repo
                                     "worktree" "add" "--quiet" "--detach"
                                     worktree "HEAD")))
          (should (file-equal-p
                   (agent-fleet-project-root-for-cwd repo)
                   (agent-fleet-project-root-for-cwd worktree))))
      (when (file-exists-p worktree) (delete-directory worktree t))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-project-root-for-cwd-non-git ()
  "A plain temp dir with no .git has no project root."
  (let ((dir (make-temp-file "af-nogit-" t)))
    (unwind-protect
        (should-not (agent-fleet-project-root-for-cwd dir))
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-project-root-for-cwd-nil ()
  "nil / non-existent dirs resolve to nil (nil-safe)."
  (should-not (agent-fleet-project-root-for-cwd nil))
  (should-not (agent-fleet-project-root-for-cwd "/nonexistent/agent-fleet/xyz")))


;;; --- Project label (dashboard column, §69) --------------------------

(ert-deftest agent-fleet-project-label ()
  "Label = project-root basename, else cwd basename, else \"—\"."
  (let ((repo (agent-fleet-project-test--make-git-repo)))
    (unwind-protect
        (progn
          ;; git-repo agent: root basename
          (should (equal (file-name-nondirectory (directory-file-name repo))
                         (agent-fleet-project-label
                          (make-herdr-agent :cwd repo))))
          ;; non-repo cwd: cwd basename (fallback chain, backward compatible)
          (let* ((d (make-temp-file "af-cwd-demo" t))
                 (base (file-name-nondirectory (directory-file-name d))))
            (unwind-protect
                (should (equal base
                               (agent-fleet-project-label
                                (make-herdr-agent :cwd d))))
              (when (file-exists-p d) (delete-directory d t))))
          ;; nil cwd
          (should (equal "—" (agent-fleet-project-label (make-herdr-agent)))))
      (when (file-exists-p repo) (delete-directory repo t)))))


;;; --- Project-scoped queries (§32: match by canonical cwd) -----------

(ert-deftest agent-fleet-project-agents-filter ()
  "`agent-fleet-project-agents' returns only agents in the given project.
Two agents in repo-a, one in repo-b; the canned w1:p1 (/tmp/demo, no
project) is excluded from both.  Matching is by cwd, so worktree agents
of one repo would all match (§32)."
  (let ((repo-a (agent-fleet-project-test--make-git-repo))
        (repo-b (agent-fleet-project-test--make-git-repo)))
    (unwind-protect
        (with-agent-fleet-mock path server
          (herdr-mock-create-pane server
            `(:pane_id "w1:p2" :workspace_id "w1" :agent "claude"
              :agent_status "idle" :cwd ,repo-a
              :terminal_id "term_p2" :tab_id "w1:t1"
              :focused nil :revision 0))
          (herdr-mock-create-pane server
            `(:pane_id "w1:p3" :workspace_id "w1" :agent "codex"
              :agent_status "idle" :cwd ,repo-a
              :terminal_id "term_p3" :tab_id "w1:t1"
              :focused nil :revision 0))
          (herdr-mock-create-pane server
            `(:pane_id "w1:p4" :workspace_id "w1" :agent "codex"
              :agent_status "idle" :cwd ,repo-b
              :terminal_id "term_p4" :tab_id "w1:t1"
              :focused nil :revision 0))
          (agent-fleet-test--pump)
          (let ((a (agent-fleet-project-agents repo-a))
                (b (agent-fleet-project-agents repo-b)))
            (should (= 2 (length a)))
            (should (= 1 (length b)))
            (should (cl-some (lambda (ag) (equal "w1:p2" (herdr-agent-id ag))) a))
            (should (cl-some (lambda (ag) (equal "w1:p3" (herdr-agent-id ag))) a))
            (should (cl-some (lambda (ag) (equal "w1:p4" (herdr-agent-id ag))) b))))
      (when (file-exists-p repo-a) (delete-directory repo-a t))
      (when (file-exists-p repo-b) (delete-directory repo-b t)))))

(ert-deftest agent-fleet-project-workspace-for-root ()
  "`--workspace-for-root' finds the workspace hosting a project's agent."
  (let ((repo (agent-fleet-project-test--make-git-repo)))
    (unwind-protect
        (with-agent-fleet-mock path server
          (herdr-mock-create-pane server
            `(:pane_id "w1:p2" :workspace_id "w2" :agent "claude"
              :agent_status "idle" :cwd ,repo
              :terminal_id "term_p2" :tab_id "w2:t1"
              :focused nil :revision 0))
          (agent-fleet-test--pump)
          (should (equal "w2" (agent-fleet--workspace-for-root
                                (agent-fleet-project-root-for-cwd repo))))
          ;; no agent in some other repo -> nil
          (should-not (agent-fleet--workspace-for-root "/nonexistent/repo")))
      (when (file-exists-p repo) (delete-directory repo t)))))


;;; --- Start for project (§69) ----------------------------------------

(ert-deftest agent-fleet-start-for-project ()
  "Start an agent for a project: it starts at the project root and is
project-associated.  Reuses the focused workspace when no project agent
exists yet (§31: one project ↔ one workspace), so no workspace.create."
  (let ((repo (agent-fleet-project-test--make-git-repo)))
    (unwind-protect
        (with-agent-fleet-mock path server
          (let ((agent (agent-fleet-start-for-project 'claude :project repo)))
            (should (herdr-agent-p agent))
            ;; the agent started at the project root (pane.split honored cwd)
            (should (file-equal-p repo (herdr-agent-cwd agent)))
            ;; and is project-associated by canonical cwd
            (should (agent-fleet-project-for-agent agent))
            (should (file-equal-p repo (agent-fleet-project-for-agent agent)))
            ;; agent.start was issued; workspace.create was not (focused reused)
            (should (agent-fleet-test--saw-request-p server "agent.start"))
            (should-not (agent-fleet-test--saw-request-p server "workspace.create"))))
      (when (file-exists-p repo) (delete-directory repo t)))))


;;; --- Dashboard: real Project column + P filter (§69) ----------------

(ert-deftest agent-fleet-dashboard-project-column-real ()
  "The Project column shows the project-root basename for a repo agent."
  (let ((repo (agent-fleet-project-test--make-git-repo)))
    (unwind-protect
        (with-agent-fleet-mock path server
          (herdr-mock-create-pane server
            `(:pane_id "w1:p2" :workspace_id "w1" :agent "claude"
              :agent_status "idle" :cwd ,repo
              :terminal_id "term_p2" :tab_id "w1:t1"
              :focused nil :revision 0))
          (agent-fleet-test--pump)
          (when (get-buffer "*Agent Fleet*") (kill-buffer "*Agent Fleet*"))
          (agent-fleet)
          (agent-fleet-test--pump)
          (with-current-buffer "*Agent Fleet*"
            (let ((entry (assoc "w1:p2" tabulated-list-entries)))
              (should entry)
              ;; Project cell (col 0) = repo basename
              (should (equal (file-name-nondirectory (directory-file-name repo))
                             (aref (cadr entry) 0))))))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-dashboard-project-filter ()
  "`P' narrows the dashboard to the at-point agent's project; re-press clears."
  (let ((repo-a (agent-fleet-project-test--make-git-repo))
        (repo-b (agent-fleet-project-test--make-git-repo)))
    (unwind-protect
        (with-agent-fleet-mock path server
          (herdr-mock-create-pane server
            `(:pane_id "w1:p2" :workspace_id "w1" :agent "claude"
              :agent_status "idle" :cwd ,repo-a
              :terminal_id "term_p2" :tab_id "w1:t1"
              :focused nil :revision 0))
          (herdr-mock-create-pane server
            `(:pane_id "w1:p3" :workspace_id "w1" :agent "codex"
              :agent_status "idle" :cwd ,repo-b
              :terminal_id "term_p3" :tab_id "w1:t1"
              :focused nil :revision 0))
          (agent-fleet-test--pump)
          (when (get-buffer "*Agent Fleet*") (kill-buffer "*Agent Fleet*"))
          (agent-fleet)
          (agent-fleet-test--pump)
          ;; canned w1:p1 (/tmp/demo, no project) + p2(repo-a) + p3(repo-b)
          (should (= 3 (length (with-current-buffer "*Agent Fleet*"
                                 tabulated-list-entries))))
          ;; filter to repo-a (the project of the agent at point w1:p2)
          (with-current-buffer "*Agent Fleet*"
            (should (agent-fleet-project-test--goto-row "w1:p2"))
            (agent-fleet-dashboard-toggle-project-filter))
          (agent-fleet-test--pump)
          ;; only repo-a agents remain: w1:p2 (w1:p1 has no project, p3 is repo-b)
          (should (= 1 (length (with-current-buffer "*Agent Fleet*"
                                 tabulated-list-entries))))
          (should (with-current-buffer "*Agent Fleet*"
                    (assoc "w1:p2" tabulated-list-entries)))
          ;; re-press (filter active) clears it
          (with-current-buffer "*Agent Fleet*"
            (agent-fleet-dashboard-toggle-project-filter))
          (agent-fleet-test--pump)
          (should (= 3 (length (with-current-buffer "*Agent Fleet*"
                                 tabulated-list-entries)))))
      (when (file-exists-p repo-a) (delete-directory repo-a t))
      (when (file-exists-p repo-b) (delete-directory repo-b t)))))


(provide 'agent-fleet-project-test)
;;; agent-fleet-project-test.el ends here
