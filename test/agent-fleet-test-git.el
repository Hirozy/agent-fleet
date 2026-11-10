;;; agent-fleet-test-git.el --- Disposable Git fixtures -*- lexical-binding: t; -*-
;;; Code:
(require 'subr-x)

(defun fleet-test-git-command (directory &rest args)
  "Run Git ARGS in test DIRECTORY, returning trimmed output."
  (let ((default-directory (file-name-as-directory directory)))
    (with-temp-buffer
      (unless (eq 0 (apply #'process-file "git" nil t nil args))
        (error "Git fixture: %s" (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defmacro fleet-test-git (&rest body)
  "Run BODY in disposable REPO, with DIR and WT paths available."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "fleet-launch-" t))
          (repo (expand-file-name "repo" dir)) (wt (expand-file-name "worker" dir)))
     (make-directory repo)
     (ignore wt)
     (unwind-protect
         (progn
           (fleet-test-git-command repo "init" "-q")
           (fleet-test-git-command repo "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
                                   "-c" "commit.gpgsign=false" "commit" "-q" "--allow-empty" "-m" "initial")
           ,@body)
       (delete-directory dir t))))

(provide 'agent-fleet-test-git)
;;; agent-fleet-test-git.el ends here
