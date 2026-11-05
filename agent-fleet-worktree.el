;;; agent-fleet-worktree.el --- Launch in a local Git checkout -*- lexical-binding: t; -*-
;;; Commentary:
;; Git owns worktrees.  Fleet records the starting commit for review, and never
;; removes a checkout or branch, including when the subsequent launch fails.
;;; Code:
(require 'agent-fleet-project)

(defun agent-fleet-worktree--git (directory &rest args)
  "Run Git ARGS in DIRECTORY, returning trimmed output or an error."
  (let ((default-directory (file-name-as-directory directory)))
    (with-temp-buffer
      (unless (eq 0 (apply #'process-file "git" nil t nil args))
        (error "Git: %s" (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun agent-fleet-worktree-prepare (repository directory branch &optional base)
  "Create DIRECTORY from REPOSITORY on new BRANCH at BASE (default HEAD).
Return start options containing :cwd and :labels.  Never remove existing files,
branches, or a created checkout after a later failure."
  (unless (and (stringp repository) (not (file-remote-p repository))
               (file-directory-p repository) (stringp directory)
               (not (file-remote-p directory)))
    (user-error "Worktree creation requires local directories"))
  (setq repository (file-truename repository)
        directory (expand-file-name directory repository))
  (when (or (file-exists-p directory) (file-symlink-p directory))
    (user-error "Worktree destination already exists: %s" directory))
  (unless (and (stringp branch) (not (string-empty-p branch)))
    (user-error "Provide a new branch name"))
  (agent-fleet-worktree--git repository "check-ref-format" "--branch" branch)
  (let* ((commit (agent-fleet-worktree--git
                  repository "rev-parse" "--verify" "--end-of-options"
                  (concat (or base "HEAD") "^{commit}")))
         (project (agent-fleet-project-root-for-cwd repository)))
    (agent-fleet-worktree--git repository "worktree" "add" "-b" branch "--" directory commit)
    (list :cwd (file-truename directory)
          :labels (append (list :fleet.review-base commit)
                          (and project (list :fleet.project project))))))

;;;###autoload
(cl-defun agent-fleet-start-worktree (argv repository directory branch &key base name task callback)
  "Create a local worktree, then start ARGV there.
REPOSITORY supplies new BRANCH and DIRECTORY; BASE defaults to HEAD.
NAME, TASK and CALLBACK have the meanings used by `agent-fleet-start'."
  (interactive
   (let* ((current-prefix-arg nil)
          (start (agent-fleet--start-interactive))
          (repository (plist-get (cdr start) :cwd))
          (branch (read-string "New branch: "))
          (directory (read-directory-name "New worktree directory: "
                                           (file-name-directory (directory-file-name repository))
                                           nil nil)))
     (list (car start) repository directory branch)))
  (herdr-core-connect)
  (unless (and argv (cl-every #'stringp argv)) (user-error "Provide a command"))
  (let* ((options (agent-fleet-worktree-prepare repository directory branch base))
         (cwd (plist-get options :cwd)))
    (message "Created %s; this checkout is retained even if launch fails" cwd)
    (condition-case err
        (agent-fleet-start
         argv :cwd cwd :labels (plist-get options :labels) :name name :task task
         :display (called-interactively-p 'interactive)
         :callback (lambda (record error)
                     (when error (message "Launch failed; checkout retained at %s: %s"
                                          cwd (herdr-core-error-message error)))
                     (when callback (funcall callback record error))))
      (error (message "Checkout retained at %s" cwd) (signal (car err) (cdr err))))))

(provide 'agent-fleet-worktree)
;;; agent-fleet-worktree.el ends here
