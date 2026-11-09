;;; agent-fleet-project.el --- Project identity and context -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Canonical Git common-root identity; absent Projects remain absent.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'agent-fleet)
(declare-function agent-fleet-remote-project "agent-fleet-remote" (record))
(declare-function agent-fleet-remote-context-path "agent-fleet-remote" (record file))
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
(defvar agent-fleet-project--cache (make-hash-table :test 'equal))
(defconst agent-fleet-project--cache-seconds 30
  "Maximum age of a directory's project discovery result.")

(defun agent-fleet-project--clear-cache ()
  "Discard cached directory discovery, including negative results."
  (clrhash agent-fleet-project--cache))

(defun agent-fleet-project--ensure-projectile ()
  "Load Projectile or signal a `user-error' that it is not installed.
Used by the project-resolution dispatch when
`agent-fleet-project-backend' is `projectile'."
  (unless (require 'projectile nil t)
    (user-error "agent-fleet-project-backend is `projectile' \
but Projectile is not installed")))


;;; --- Project root resolution ----------------------------------------

(defun agent-fleet-project--git-primary-root (common)
  "Resolve COMMON's primary checkout, including a submodule's Git directory."
  (if (equal (file-name-nondirectory common) ".git")
      (directory-file-name (file-name-directory common))
    ;; Submodules store their repository in the superproject's .git/modules.
    ;; core.worktree is relative to that Git directory, not the agent's cwd.
    (with-temp-buffer
      (when (eq 0 (process-file "git" nil t nil (concat "--git-dir=" common)
                                "config" "--path" "--get" "core.worktree"))
        (let* ((configured (string-trim (buffer-string)))
               (root (and (not (string-empty-p configured))
                          (expand-file-name configured common))))
          (when (and root (not (file-remote-p root)) (file-directory-p root))
            (directory-file-name (file-truename root))))))))

(defun agent-fleet-project--git-context (dir)
  "Discover the shared repository identity and actual checkout for DIR.
Keep non-standard common-dir layouts unresolved rather than guessing."
  (when (and (not (file-remote-p dir)) (executable-find "git") (file-directory-p dir))
    (let ((default-directory (file-name-as-directory (file-truename dir))))
      (with-temp-buffer
        (when (eq 0 (process-file "git" nil t nil
                                  "rev-parse" "--path-format=absolute"
                                  "--git-common-dir" "--show-toplevel"))
          (let ((lines (split-string (string-trim (buffer-string)) "\n" t)))
            (when (= (length lines) 2)
              (let ((common (directory-file-name (file-truename (car lines))))
                    (checkout (directory-file-name (file-truename (cadr lines)))))
                (list :root (agent-fleet-project--git-primary-root common)
                      :checkout checkout)))))))))

(defun agent-fleet-project--git-common-root (dir)
  "Return the primary checkout root shared by Git worktree DIR, or nil."
  (plist-get (agent-fleet-project--git-context dir) :root))

(defun agent-fleet-project--backend-root-for-cwd (dir)
  "Return the project root for DIR per `agent-fleet-project-backend', or nil.
Runs AFTER the shared git-worktree normalization, so it is only reached for
dirs the git pass left unresolved.  `project' (default) uses
`project-current'/`project-root' with a `vc-root-dir' fallback;
`projectile' uses `projectile-project-root', which does its own fallback.
Returns a `file-truename'-canonicalized directory or nil."
  (let ((default-directory (file-name-as-directory (file-truename dir))))
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

(defun agent-fleet-project--context (dir &optional refresh)
  "Resolve local DIR into project identity, checkout and availability.
Cache discovery for 30 seconds; REFRESH bypasses the cache.  Missing or
remote directories never inherit the current buffer's project."
  (cond
   ((or (not (stringp dir)) (string-empty-p dir)) '(:state unknown))
   ((file-remote-p dir) '(:state remote))
   ((not (and (file-directory-p dir) (file-accessible-directory-p dir)))
    (remhash (list agent-fleet-project-backend
                   (directory-file-name (or (ignore-errors (file-truename dir)) (expand-file-name dir))))
             agent-fleet-project--cache)
    '(:state unavailable))
   (t
    (condition-case nil
        (let* ((canonical (directory-file-name (file-truename dir)))
               (key (list agent-fleet-project-backend canonical))
               (cached (gethash key agent-fleet-project--cache))
               (now (float-time)))
          (if (and (not refresh) cached (< now (plist-get cached :expires))) cached
            (let* ((git (agent-fleet-project--git-context canonical))
                   (root (or (plist-get git :root)
                             (agent-fleet-project--backend-root-for-cwd canonical)))
                   (context (list :state (if root 'project 'none)
                                  :root root :checkout (or (plist-get git :checkout) root)
                                  :directory canonical :expires (+ now agent-fleet-project--cache-seconds))))
              (when (>= (hash-table-count agent-fleet-project--cache) 512)
                (agent-fleet-project--clear-cache))
              (puthash key context agent-fleet-project--cache))))
      (file-error '(:state unavailable))))))

(defun agent-fleet-project-root-for-cwd (dir)
  "Return DIR's canonical Project identity, shared across linked worktrees.
This identity is for grouping; use `agent-fleet-project-checkout-for-cwd'
when choosing an execution directory."
  (plist-get (agent-fleet-project--context dir) :root))

(defun agent-fleet-project-checkout-for-cwd (dir &optional refresh)
  "Return DIR's actual checkout or non-Git project root.
REFRESH forces discovery before an explicit project launch."
  (plist-get (agent-fleet-project--context dir refresh) :checkout))

(defun agent-fleet-project--canonical-root (dir)
  "Return the canonical Project identity for explicit root DIR, or nil.
Unlike `agent-fleet-project-root-for-cwd', DIR is already a project root and
must not be re-discovered through the current buffer.  It still goes through
the shared Git common-root normalization so a `project.el' struct rooted at a
linked worktree matches agents in the primary checkout and sibling worktrees.
Non-Git roots retain their explicit `file-truename' identity."
  (when (and (stringp dir) (not (string-empty-p dir))
             (not (file-remote-p dir)) (file-directory-p dir))
    (let ((truename (file-truename dir)))
      (or (agent-fleet-project--git-common-root truename)
          (directory-file-name truename)))))


(defun agent-fleet-project-for-agent (record)
  "Return the local Project of RECORD, never interpreting remote paths locally."
  (if (string-match-p "/" (plist-get record :address))
      (progn (require 'agent-fleet-remote) (agent-fleet-remote-project record))
    (agent-fleet-project-root-for-cwd (plist-get record :cwd))))

(defun agent-fleet-project--display-name (root)
  "Return a short label for canonical ROOT, without filesystem access."
  (if root
      (if (stringp root)
          (let ((name (file-name-nondirectory (directory-file-name root))))
            (if (string-empty-p name) root name))
        (concat (file-name-nondirectory (directory-file-name (nth 2 root))) " (remote)")) "—"))

(defun agent-fleet-project--full-label (root)
  "Describe ROOT completely, without resolving paths."
  (cond ((null root) "— No Project") ((stringp root) root)
        (t (format "%s (remote %s)" (nth 2 root) (nth 1 root)))))

(defun agent-fleet-project--short-labels (roots)
  "Return distinct short labels for canonical ROOTS, without filesystem I/O."
  (let ((roots (delete-dups (copy-sequence roots)))
        (labels (make-hash-table :test 'equal)))
    (dolist (root roots)
      (let* ((path (if (stringp root) root (nth 2 root)))
             (parts (and path (split-string path "/" t)))
             (depth 1)
             (label (if root (agent-fleet-project--display-name root) "— No Project")))
        (while (and root
                    (cl-some (lambda (other)
                               (and (not (equal root other))
                                    (equal label
                                           (let* ((other-path (if (stringp other) other (nth 2 other)))
                                                  (other-parts (and other-path (split-string other-path "/" t))))
                                             (if (null other) "— No Project"
                                               (concat (mapconcat #'identity (last other-parts depth) "/")
                                                       (unless (stringp other) " (remote)"))))))) roots))
          (if (>= depth (length parts))
              (setq label (agent-fleet-project--full-label root) depth (1+ depth))
            (setq depth (1+ depth)
                  label (concat (mapconcat #'identity (last parts depth) "/")
                                (unless (stringp root) " (remote)")))))
        (puthash root label labels)))
    labels))

(defun agent-fleet-project--path-label (path &optional width remote)
  "Display directory PATH within WIDTH columns, keeping its trailing components.
Keep the full path in a tooltip.  REMOTE paths are never abbreviated locally."
  (let* ((text (if remote path (abbreviate-file-name path)))
         (text (if (string-suffix-p "/" text) text (concat text "/"))))
    (when (and width (> (string-width text) width))
      (let ((start 0) (remaining (string-width text)))
        (while (and (< start (length text)) (> remaining (max 0 (1- width))))
          (setq remaining (- remaining (char-width (aref text start)))
                start (1+ start)))
        (setq text (concat "…" (substring text start)))))
    (propertize text 'face 'shadow 'help-echo path)))

(defun agent-fleet-project--directory-note (record root &optional width)
  "Return meaningful working-directory context for RECORD under ROOT.
Return nil for the ordinary project root.  Keep full paths in tooltips.
Fit the note within WIDTH columns when provided."
  (let* ((cwd (plist-get record :cwd))
         (remote (or (string-match-p "/" (plist-get record :address))
                     (and cwd (file-remote-p cwd))))
         (context (unless remote (agent-fleet-project--context cwd)))
         (directory (plist-get context :directory))
         (checkout (plist-get context :checkout))
         (unavailable (eq (plist-get context :state) 'unavailable))
         (prefix (cond (remote "Remote: ") (unavailable "Directory unavailable: ")
                       ((and root checkout (not (equal checkout root))) "Worktree: ")
                       (t ""))))
    (cond
     ((or (not (stringp cwd)) (string-empty-p cwd))
      (propertize "Directory not reported" 'face 'shadow))
     ((and (not remote) root (equal root directory)) nil)
     (t
      (let* ((path (if (and (not remote) root directory (string-empty-p prefix))
                       (concat "./" (file-relative-name directory (file-name-as-directory root)))
                     cwd))
             (text (concat prefix (agent-fleet-project--path-label
                                   path (and width (max 1 (- width (length prefix)))) remote))))
        (propertize text 'help-echo cwd 'face (if unavailable 'warning 'shadow)))))))

(defun agent-fleet-project-agents (&optional root)
  "Return live members in canonical Project ROOT, defaulting to the current one."
  (let ((root (if root (if (listp root) root (agent-fleet-project--canonical-root root))
                (agent-fleet-project-root-for-cwd default-directory))))
    (and root (cl-remove-if-not
               (lambda (r) (equal root (agent-fleet-project-for-agent r)))
               (agent-fleet-agents)))))

;;;###autoload
(defun agent-fleet-start-for-project ()
  "Choose a command and start it in the current Project.
Interactive calls attach after a successful launch."
  (interactive)
  (let ((root (agent-fleet-project-checkout-for-cwd default-directory t)))
    (unless root (user-error "No Project in the current directory"))
    (herdr-core-connect)
    (if (called-interactively-p 'any)
        (let ((default-directory (file-name-as-directory root)))
          (agent-fleet-start-minibuffer current-prefix-arg))
      (agent-fleet-start (agent-fleet--read-command) :cwd root))))

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
         (pinned (or agent-fleet-target
                     (and agent-fleet-target-function (funcall agent-fleet-target-function))))
         (same (unless pinned (agent-fleet-project-agents)))
         (target (cond (pinned pinned)
                       (same (agent-fleet--read-target same "Same-Project agent: "))
                       (t (message "No same-Project agent; showing all Fleet agents")
                          (agent-fleet-read-agent)))))
    (let ((record (agent-fleet-resolve target)))
      (when (and file (string-match-p "/" (plist-get record :address)))
        (require 'agent-fleet-remote)
        (setq context (concat
                       (if-let* ((path (agent-fleet-remote-context-path record file)))
                           (format "Remote file: %s\n" path)
                         "Local source reference; no remote path mapping or file transfer.\n")
                       context))))
    (agent-fleet-prompt target context)))
(provide 'agent-fleet-project)
;;; agent-fleet-project.el ends here
