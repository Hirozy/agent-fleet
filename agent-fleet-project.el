;;; agent-fleet-project.el --- Project identity and context -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Canonical Git common-root identity; absent Projects remain absent.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'agent-fleet)
(defcustom agent-fleet-project-backend 'project
  "Source for project detection: built-in `project' or `projectile'.
The default `project' uses `project-current'/`project-root' with a
`vc-root-dir' fallback.  The `projectile' backend uses
`projectile-project-root', which does its own fallback.  Either way the
git worktree normalization (`agent-fleet-project--git-common-root') runs
first, so git repos resolve identically under either backend — this only
affects how non-git or non-standard-git projects are detected.
Projectile is an optional dependency; the `projectile' backend loads it on
demand and signals a `user-error' if it is absent."
  :type '(choice (const :tag "Built-in project.el" project)
                 (const :tag "Projectile" projectile))
  :group 'agent-fleet)

;; Projectile is optional: declare the entry point so the byte-compiler does
;; not warn, without forcing a top-level `require' (mirrors the magit idiom).
(declare-function projectile-project-root "projectile" (&optional dir))

(defun agent-fleet-project--ensure-projectile ()
  "Load Projectile or signal a `user-error' that it is not installed.
Used by the project-resolution dispatch when
`agent-fleet-project-backend' is `projectile'."
  (unless (require 'projectile nil t)
    (user-error "agent-fleet-project-backend is `projectile' \
but Projectile is not installed")))


;;; --- Project root resolution ----------------------------------------

(defun agent-fleet-project--git-common-root (dir)
  "Return the primary checkout root shared by Git worktree DIR, or nil.
For a normal checkout, `git rev-parse --git-common-dir' yields ROOT/.git;
for a linked worktree it yields that same directory in the primary checkout.
Mapping both to ROOT makes all worktrees of one repository share the project
identity.  Non-standard separate git-dir layouts fall
back to `project.el' rather than guessing."
  (when (and (executable-find "git") (file-directory-p dir))
    (let ((default-directory (file-name-as-directory (file-truename dir))))
      (with-temp-buffer
        (when (eq 0 (process-file "git" nil t nil
                                  "rev-parse" "--path-format=absolute"
                                  "--git-common-dir"))
          (let* ((raw (string-trim (buffer-string)))
                 (common (and (not (string-empty-p raw))
                              (file-truename
                               (expand-file-name raw default-directory)))))
            (when (and common
                       (string= (file-name-nondirectory
                                 (directory-file-name common))
                                ".git"))
              (directory-file-name
               (file-truename (file-name-directory
                               (directory-file-name common)))))))))))

(defun agent-fleet-project--backend-root-for-cwd (dir)
  "Return the project root for DIR per `agent-fleet-project-backend', or nil.
Runs AFTER the shared git-worktree normalization, so it is only reached for
dirs the git pass left unresolved.  `project' (default) uses
`project-current'/`project-root' with a `vc-root-dir' fallback;
`projectile' uses `projectile-project-root', which does its own fallback.
Returns a `file-truename'-canonicalized directory or nil."
  (let ((default-directory (file-truename dir)))
    (pcase agent-fleet-project-backend
      ('projectile
       (agent-fleet-project--ensure-projectile)
       (when-let* ((root (projectile-project-root (file-truename dir))))
         (directory-file-name (file-truename root))))
      (_
       (let ((proj (project-current)))
         (cond
          (proj (directory-file-name (file-truename (project-root proj))))
          (t
           ;; VC fallback for repos not yet known to project.el.
           (let ((root (vc-root-dir)))
             (and root (not (string-empty-p root))
                  (directory-file-name (file-truename root)))))))))))

(defun agent-fleet-project-root-for-cwd (dir)
  "Return the canonical project root for DIR, or nil.
Resolves via the shared git-worktree normalization first
(`agent-fleet-project--git-common-root'), then the configured
`agent-fleet-project-backend' (`project' uses `project-current'/`project-root'
with a `vc-root-dir' fallback; `projectile' uses `projectile-project-root').
The result is `file-truename'-canonicalized so symlinked cwd variants of one
repo all match.
Nil-safe: nil, empty, or non-existent DIR returns nil — an empty cwd would
otherwise expand to `default-directory' (via `file-directory-p') and leak the
caller's project as the agent's."
  (when (and (stringp dir) (not (string-empty-p dir)) (file-directory-p dir))
    (or (agent-fleet-project--git-common-root (file-truename dir))
        (agent-fleet-project--backend-root-for-cwd dir))))

(defun agent-fleet-project--canonical-root (dir)
  "Return the canonical Project identity for explicit root DIR, or nil.
Unlike `agent-fleet-project-root-for-cwd', DIR is already a project root and
must not be re-discovered through the current buffer.  It still goes through
the shared Git common-root normalization so a `project.el' struct rooted at a
linked worktree matches agents in the primary checkout and sibling worktrees.
Non-Git roots retain their explicit `file-truename' identity."
  (when (and (stringp dir) (not (string-empty-p dir))
             (file-directory-p dir))
    (let ((truename (file-truename dir)))
      (or (agent-fleet-project--git-common-root truename)
          (directory-file-name truename)))))


(defun agent-fleet-project-for-agent (record)
  "Return the local Project of RECORD, never interpreting remote paths locally."
  (unless (string-match-p "/" (plist-get record :address))
    (agent-fleet-project-root-for-cwd (plist-get record :cwd))))

(defun agent-fleet-project-label (record)
  "Return RECORD's Project label, or an em dash."
  (if-let* ((root (agent-fleet-project-for-agent record)))
      (file-name-nondirectory (directory-file-name root)) "—"))

(defun agent-fleet-project-agents (&optional root)
  "Return live members in canonical Project ROOT, defaulting to the current one."
  (let ((root (if root (agent-fleet-project--canonical-root root)
                (agent-fleet-project-root-for-cwd default-directory))))
    (and root (cl-remove-if-not
               (lambda (r) (equal root (agent-fleet-project-for-agent r)))
               (agent-fleet-agents)))))

;;;###autoload
(defun agent-fleet-start-for-project ()
  "Choose a command and start it in the current Project."
  (interactive)
  (let ((root (agent-fleet-project-root-for-cwd default-directory)))
    (unless root (user-error "No Project in the current directory"))
    (let* ((choices (agent-fleet--commands))
           (choice (completing-read "Template or command: " choices nil nil)))
      (agent-fleet-start (or (cdr (assoc choice choices)) (split-string-and-unquote choice))
                         :cwd root :display (called-interactively-p 'interactive)))))

;;;###autoload
(defun agent-fleet-prompt-dwim ()
  "Compose a prompt containing a bounded reference to the current code context."
  (interactive)
  (herdr-core-connect)
  (let* ((file buffer-file-name)
         (start (and (use-region-p) (region-beginning)))
         (end (and start (region-end)))
         (context (concat
                   (if file (format "File: %s\n" file) "")
                   (if start (format "Lines: %d-%d\n"
                                     (line-number-at-pos start)
                                     (line-number-at-pos (max start (1- end)))) "")
                   (if (and start (<= (- end start) 4000))
                       (concat "\n" (buffer-substring-no-properties start end) "\n") "")
                   "\n"))
         (same (agent-fleet-project-agents))
         (target (if same
                     (let* ((choices (mapcar (lambda (r)
                                              (cons (format "%s [%s]" (agent-fleet-name r)
                                                            (plist-get r :address))
                                                    (plist-get r :address))) same)))
                       (cdr (assoc (completing-read "Same-Project agent: " choices nil t) choices)))
                   (message "No same-Project agent; showing all Fleet agents")
                   (agent-fleet-read-agent))))
    (agent-fleet-prompt target context)))
(provide 'agent-fleet-project)
;;; agent-fleet-project.el ends here
