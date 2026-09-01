;;; agent-fleet-project-test.el --- ERT tests for agent-fleet-project.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests: project.el root resolution (canonical cwd), the
;; project label/column, project-scoped agent queries, start-for-project,
;; and the dashboard `P' project filter.
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

(defun agent-fleet-project-test--add-linked-worktree (repo)
  "Create and return a detached linked worktree for REPO.
REPO receives one empty commit so Git has a revision to attach to the
worktree.  The caller owns cleanup of the returned directory and REPO."
  (let ((worktree (make-temp-name
                   (expand-file-name "af-linked-" temporary-file-directory))))
    (should (eq 0 (process-file
                   "git" nil nil nil "-C" repo
                   "-c" "user.name=Agent Fleet Test"
                   "-c" "user.email=agent-fleet@example.invalid"
                   "-c" "commit.gpgSign=false"
                   "commit" "--quiet" "--allow-empty" "-m" "initial")))
    (should (eq 0 (process-file "git" nil nil nil "-C" repo
                                "worktree" "add" "--quiet" "--detach"
                                worktree "HEAD")))
    worktree))

(defun agent-fleet-project-test--goto-row (pane-id)
  "Move point to the dashboard row for PANE-ID; return non-nil if found.
The dashboard is in `*Agent Fleet*'.  Robust to sort order."
  (with-current-buffer "*Agent Fleet*"
    (goto-char (point-min))
    (cl-loop until (eobp)
             when (equal (tabulated-list-get-id) pane-id)
             return t
             do (forward-line 1))))


;;; --- Root resolution ------------------------------

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
          ;; a subdir resolves to the REPO root, not the subdir (canonical cwd)
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


;;; --- Project label (dashboard column) --------------------------

(ert-deftest agent-fleet-project-label ()
  "Label = project-root basename, else \"—\".
A non-repo cwd is NOT labeled by its basename — an arbitrary directory
is not a Project identity."
  (let ((repo (agent-fleet-project-test--make-git-repo)))
    (unwind-protect
        (progn
          ;; git-repo agent: root basename
          (should (equal (file-name-nondirectory (directory-file-name repo))
                         (agent-fleet-project-label
                          (make-herdr-agent :cwd repo))))
          ;; non-repo cwd: "—" (not the cwd basename)
          (let ((d (make-temp-file "af-cwd-demo" t)))
            (unwind-protect
                (should (equal "—"
                               (agent-fleet-project-label
                                (make-herdr-agent :cwd d))))
              (when (file-exists-p d) (delete-directory d t))))
          ;; nil cwd
          (should (equal "—" (agent-fleet-project-label (make-herdr-agent)))))
      (when (file-exists-p repo) (delete-directory repo t)))))


;;; --- Project-scoped queries (match by canonical cwd) -----------

(ert-deftest agent-fleet-project-agents-filter ()
  "`agent-fleet-project-agents' returns only agents in the given project.
Two agents in repo-a, one in repo-b; the canned w1:p1 (/tmp/demo, no
project) is excluded from both.  Matching is by cwd, so worktree agents
of one repo would all match."
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

(ert-deftest agent-fleet-project-agents-normalizes-linked-worktree-root ()
  "An explicit linked-worktree root matches agents in the source checkout.
The project query must normalize a project.el/explicit root with the same
Git common-root rule used for each agent cwd."
  (let* ((repo (agent-fleet-project-test--make-git-repo))
         (worktree nil))
    (unwind-protect
        (progn
          (setq worktree
                (agent-fleet-project-test--add-linked-worktree repo))
          (with-agent-fleet-mock path server
            (herdr-mock-create-pane
             server `(:pane_id "w1:p2" :workspace_id "w1" :agent "claude"
                       :agent_status "idle" :name "source"
                       :cwd ,repo :terminal_id "term_p2" :tab_id "w1:t1"
                       :focused nil :revision 0))
            (herdr-mock-create-pane
             server `(:pane_id "w1:p3" :workspace_id "w2" :agent "codex"
                       :agent_status "idle" :name "linked"
                       :cwd ,worktree :terminal_id "term_p3" :tab_id "w1:t1"
                       :focused nil :revision 0))
            (agent-fleet-test--pump)
            (let ((agents (agent-fleet-project-agents worktree)))
              (should (= 2 (length agents)))
              (should (equal '("w1:p2" "w1:p3")
                             (sort (mapcar #'herdr-agent-id agents)
                                   #'string<))))))
      (when (and worktree (file-exists-p worktree))
        (delete-directory worktree t))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-prompt-dwim-prefers-and-disambiguates-linked-agents ()
  "Prompt DWIM offers both same-Project linked-worktree agents distinctly.
The completion collection is built from public candidate descriptors, so two
agents with the same name can still be selected independently."
  (let* ((repo (agent-fleet-project-test--make-git-repo))
         (worktree nil)
         choices)
    (unwind-protect
        (progn
          (setq worktree
                (agent-fleet-project-test--add-linked-worktree repo))
          (with-agent-fleet-mock path server
            (herdr-mock-create-pane
             server `(:pane_id "w1:p2" :workspace_id "w1" :agent "claude"
                       :agent_status "idle" :name "same"
                       :cwd ,repo :terminal_id "term_p2" :tab_id "w1:t1"
                       :focused nil :revision 0))
            (herdr-mock-create-pane
             server `(:pane_id "w1:p3" :workspace_id "w2" :agent "codex"
                       :agent_status "idle" :name "same"
                       :cwd ,worktree :terminal_id "term_p3" :tab_id "w1:t1"
                       :focused nil :revision 0))
            (agent-fleet-test--pump)
            (cl-letf (((symbol-function 'agent-fleet-project-current)
                       (lambda () worktree))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _)
                         (setq choices collection)
                         ;; Select the second disambiguated candidate.  The
                         ;; real `completing-read' returns its display string,
                         ;; not the alist cons cell.
                         (car (cadr collection)))))
              (should (equal "w1:p3"
                             (agent-fleet-prompt-dwim--read-agent))))
            (should (= 2 (length choices)))
            (should-not (equal (car choices) (cadr choices)))
            (should (string-match-p "w1:p2" (car (car choices))))
            (should (string-match-p "w1:p3" (car (cadr choices))))))
      (when (and worktree (file-exists-p worktree))
        (delete-directory worktree t))
      (when (file-exists-p repo) (delete-directory repo t)))))

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


;;; --- Start for project -------------------------------------------

(ert-deftest agent-fleet-start-for-project ()
  "Start an agent for a project: it starts at the project root and is
project-associated.  Reuses the focused workspace when no project agent
exists yet (one project ↔ one workspace), so no workspace.create."
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


;;; --- Dashboard: real Project column + P filter -------------------

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
            (agent-fleet-dashboard--toggle-project-filter))
          (agent-fleet-test--pump)
          ;; only repo-a agents remain: w1:p2 (w1:p1 has no project, p3 is repo-b)
          (should (= 1 (length (with-current-buffer "*Agent Fleet*"
                                 tabulated-list-entries))))
          (should (with-current-buffer "*Agent Fleet*"
                    (assoc "w1:p2" tabulated-list-entries)))
          ;; re-press (filter active) clears it
          (with-current-buffer "*Agent Fleet*"
            (agent-fleet-dashboard--toggle-project-filter))
          (agent-fleet-test--pump)
          (should (= 3 (length (with-current-buffer "*Agent Fleet*"
                                 tabulated-list-entries)))))
      (when (file-exists-p repo-a) (delete-directory repo-a t))
      (when (file-exists-p repo-b) (delete-directory repo-b t)))))


;;; --- Project backend (opt-in Projectile) ----------------------------

(ert-deftest agent-fleet-project-root-for-cwd-projectile-backend-dispatches ()
  "With backend `projectile', root-for-cwd returns the Projectile root.
A plain temp dir has no .git, so the git pass is skipped and the backend
branch is exercised."
  (let ((dir (make-temp-file "af-proj-" t))
        (agent-fleet-project-backend 'projectile))
    (unwind-protect
        (cl-letf* (((symbol-function 'agent-fleet-project--ensure-projectile) #'ignore)
                   ((symbol-function 'projectile-project-root)
                    (lambda (&optional _d) (file-truename dir))))
          (should (file-equal-p dir (agent-fleet-project-root-for-cwd dir))))
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-project-root-for-cwd-git-short-circuits-under-projectile ()
  "A git repo resolves via the git pass even under the `projectile' backend;
Projectile is never consulted."
  (let ((repo (agent-fleet-project-test--make-git-repo))
        (agent-fleet-project-backend 'projectile))
    (unwind-protect
        (cl-letf (((symbol-function 'projectile-project-root)
                   (lambda (&rest _)
                     (error "projectile-project-root must not run for git"))))
          (should (file-equal-p repo (agent-fleet-project-root-for-cwd repo))))
      (when (file-exists-p repo) (delete-directory repo t)))))

(ert-deftest agent-fleet-project-root-for-cwd-projectile-absent-signals ()
  "Under the `projectile' backend, a missing Projectile signals `user-error'.
`require' is stubbed to return nil only for `projectile', so this does not
depend on whether Projectile happens to be installed on the test host."
  (let ((dir (make-temp-file "af-proj-" t))
        (agent-fleet-project-backend 'projectile)
        (orig-require (symbol-function 'require)))
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &optional filename noerror)
                     (if (eq feature 'projectile)
                         nil
                       (funcall orig-require feature filename noerror)))))
          (should-error (agent-fleet-project-root-for-cwd dir) :type 'user-error))
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-project-current-dispatches ()
  "`agent-fleet-project-current' dispatches on `agent-fleet-project-backend'.
`projectile' returns `projectile-project-root'; `project' returns
`(project-current)'."
  (let ((agent-fleet-project-backend 'projectile))
    (cl-letf* (((symbol-function 'agent-fleet-project--ensure-projectile) #'ignore)
               ((symbol-function 'projectile-project-root)
                (lambda (&optional _d) "/stub/projectile-root")))
      (should (equal "/stub/projectile-root" (agent-fleet-project-current))))
    (let ((agent-fleet-project-backend 'project))
      (cl-letf (((symbol-function 'project-current)
                 (lambda (&rest _) 'fake-project)))
        (should (eq 'fake-project (agent-fleet-project-current)))))))


;;; --- Prompt DWIM context builder ----------------------------------

(defun agent-fleet-project-test--with-context-buffer (file-dir file-name
                                                       content point-pos
                                                           &optional mark-pos)
  "Return a temp buffer visiting FILE-DIR/FILE-NAME with CONTENT.
POINT-POS sets point; MARK-POS (when non-nil) activates the region
between it and POINT-POS.  The buffer is not selected for display."
  (let* ((dir (file-name-as-directory file-dir))
         (path (expand-file-name file-name dir))
         (buf (find-file-noselect path)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (min point-pos (point-max)))
        (when mark-pos
          (set-mark (min mark-pos (point-max)))
          (setq deactivate-mark nil))))
    buf))

(ert-deftest agent-fleet-prompt-dwim-context-file-only ()
  "File path with no region and no symbol at point."
  (let* ((dir (make-temp-file "af-dwim" t))
         (buf (agent-fleet-project-test--with-context-buffer
               dir "src.el" "line one\nline two" 1)))
    (unwind-protect
        (with-current-buffer buf
          ;; No symbol at point (point is on 'l' of "line"), no region.
          (let ((text (agent-fleet-prompt-dwim--context dir)))
            (should (string-prefix-p (file-truename (buffer-file-name buf)) text))))
      (kill-buffer buf)
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-prompt-dwim-context-relative-path ()
  "File path is relative to the project root when under it."
  (let* ((dir (make-temp-file "af-dwim" t))
         (root (file-truename dir))
         (buf (agent-fleet-project-test--with-context-buffer
               dir "src.el" "x" 1)))
    (unwind-protect
        (with-current-buffer buf
          (should (string-prefix-p "src.el" (agent-fleet-prompt-dwim--context root))))
      (kill-buffer buf)
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-prompt-dwim-context-region-and-text ()
  "Small region: line range + selected text, without an outside symbol."
  (let* ((dir (make-temp-file "af-dwim" t))
         (root (file-truename dir))
         (content "alpha\nbeta\ngamma\n")
         (buf (agent-fleet-project-test--with-context-buffer
               dir "src.el" content 2 1))
         (transient-mark-mode t))
    ;; Point at the start of "beta" (pos 7), mark at 'a' (pos 1) — the
    ;; exclusive endpoint is the next line start, so the selection is line 1
    ;; only and must not attach metadata for the unselected "beta" symbol.
    (unwind-protect
        (with-current-buffer buf
          (goto-char 7)            ; start of "beta", outside the selection
          (set-mark 1)
          (setq mark-active t)
          (setq deactivate-mark nil)
          (let ((text (agent-fleet-prompt-dwim--context root)))
            (should (string-prefix-p "src.el:1" text))
            (should-not (string-match-p "(symbol: beta)" text))
            ;; The verbatim region text is appended after a blank line.
            (should (string-match-p "\n\nalpha" text))))
      (kill-buffer buf)
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-prompt-dwim-context-large-region-omits-text ()
  "A region above the size limit keeps the line range but drops the text."
  (let* ((dir (make-temp-file "af-dwim" t))
         (root (file-truename dir))
         (big (make-string (* 2 agent-fleet-prompt-dwim-max-region-chars) ?x))
         (content (format "line\n%s\n" big))
         (buf (agent-fleet-project-test--with-context-buffer
               dir "src.el" content 1 1))
         (agent-fleet-prompt-dwim-max-region-chars
          agent-fleet-prompt-dwim-max-region-chars)
         (transient-mark-mode t))
    (unwind-protect
        (with-current-buffer buf
          ;; Select the entire buffer as a region.
          (goto-char (point-max))
          (set-mark (point-min))
          (setq mark-active t)
          (setq deactivate-mark nil)
          (let ((text (agent-fleet-prompt-dwim--context root)))
            (should (string-prefix-p "src.el:1-" text))
            ;; No verbatim text appended (the big string is not present).
            (should-not (string-match-p (regexp-quote big) text))))
      (kill-buffer buf)
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest agent-fleet-prompt-dwim-context-no-file ()
  "A buffer with no file: symbol-only context (or empty)."
  (with-temp-buffer
    (insert "(defun foo ()")
    (goto-char 8)                  ; on 'foo'
    (let ((text (agent-fleet-prompt-dwim--context nil)))
      (should (string-match-p "(symbol: foo)" text)))))

(provide 'agent-fleet-project-test)
;;; agent-fleet-project-test.el ends here
