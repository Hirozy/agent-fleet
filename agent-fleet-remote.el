;;; agent-fleet-remote.el --- Agent workflows on Core machines -*- lexical-binding: t; -*-
;;; Commentary:
;; Machines are provisioned with hc.  Fleet uses permanent IDs for identity,
;; explicit path mappings for context, and Core RPCs for remote code review.
;;; Code:
(require 'agent-fleet-project)
(require 'diff-mode)
(defcustom agent-fleet-remote-projects nil
  "Explicit local counterparts of remote Projects.
Each entry is (:machine CORE-ID :remote CANONICAL-ROOT :local LOCAL-ROOT).
Paths are not synchronized.  Remote POSIX paths never go to local file APIs."
  :type '(repeat plist) :group 'agent-fleet)

(defun agent-fleet-remote--read-machine ()
  "Choose a connected machine, returning its permanent ID."
  (let ((choices (cl-loop for m in (herdr-core-machines)
                          when (equal (plist-get m :state) "connected")
                          collect (cons (format "%s [%s]" (plist-get m :name) (plist-get m :id))
                                        (plist-get m :id)))))
    (unless choices (user-error "No connected machines; configure one with hc machine add"))
    (cdr (assoc (completing-read "Machine: " choices nil t) choices))))

(defun agent-fleet-remote-exec (machine cwd argv)
  "Run read-only command ARGV in CWD on permanent MACHINE ID.
Return raw ExecResult; a nonzero exit remains available to the caller."
  (let* ((route (plist-get (herdr-core-machine machine) :name))
         (result (herdr-core-request "machine.exec"
                                     (list :on route :cwd cwd :argv (vconcat argv) :timeout 15) 20)))
    (unless (and (stringp (plist-get result :stdout)) (stringp (plist-get result :stderr)))
      (error "Invalid machine.exec response"))
    (when (or (eq (plist-get result :timed_out) t) (eq (plist-get result :truncated) t))
      (error "Remote command timed out or output was truncated; review with hc"))
    result))

(defun agent-fleet-remote--text (result key)
  "Decode UTF-8 output KEY in RESULT."
  (decode-coding-string (base64-decode-string (plist-get result key)) 'utf-8))

(defun agent-fleet-remote--git (machine cwd &rest args)
  "Return successful Git ARGS output at MACHINE/CWD, or nil for nonzero exit."
  (let ((result (agent-fleet-remote-exec machine cwd (append '("git" "--no-pager") args))))
    (when (eq (plist-get result :code) 0)
      (string-trim-right (agent-fleet-remote--text result :stdout)))))

(defun agent-fleet-remote-start-options (machine cwd)
  "Resolve MACHINE and CWD to launch options and verified Project metadata.
Only POSIX absolute remote paths are accepted.
Git discovery never runs locally."
  (unless (and (stringp cwd) (string-prefix-p "/" cwd) (not (file-remote-p cwd)))
    (user-error "Use an absolute POSIX directory on the remote machine"))
  (let* ((common (agent-fleet-remote--git machine cwd "rev-parse" "--path-format=absolute" "--git-common-dir"))
         (project (and common (string-suffix-p "/.git" common) (substring common 0 -5)))
         (checkout (and common (agent-fleet-remote--git machine cwd "rev-parse" "--show-toplevel")))
         (base (and common (agent-fleet-remote--git machine cwd "rev-parse" "--verify" "HEAD^{commit}")))
         (labels (list :fleet.machine machine)))
    (when project (setq labels (plist-put labels :fleet.project project)))
    (when checkout (setq labels (plist-put labels :fleet.checkout-root checkout)))
    (when base (setq labels (plist-put labels :fleet.review-base base)))
    (list :on (plist-get (herdr-core-machine machine) :name) :labels labels
          :name-base (or project cwd))))

;;;###autoload
(defun agent-fleet-start-remote (machine argv cwd)
  "Start ARGV in CWD on permanent MACHINE ID, using an existing Core route."
  (interactive (list (agent-fleet-remote--read-machine)
                     (split-string-and-unquote (read-string "Remote command or template: "))
                     (read-string "Remote absolute directory: ")))
  (agent-fleet-start argv :cwd cwd :machine machine :display (called-interactively-p 'interactive)))

(defun agent-fleet-remote-project (record)
  "Return RECORD's verified launch Project label or its mapped local counterpart."
  (let* ((machine (agent-fleet-label record "fleet.machine"))
         (root (agent-fleet-label record "fleet.project"))
         (mapping (cl-find-if (lambda (entry) (and (equal machine (plist-get entry :machine))
                                                   (equal root (plist-get entry :remote))))
                              agent-fleet-remote-projects)))
    (when (and machine root)
      (or (and mapping (agent-fleet-project--canonical-root (plist-get mapping :local)))
          (list 'remote machine root)))))

(defun agent-fleet-remote-context-path (record file)
  "Map local FILE into RECORD's actual remote checkout, or return nil.
The explicit Project mapping authorizes correspondence, not file transfer."
  (let* ((project (agent-fleet-remote-project record))
         (local (and (stringp project) (file-truename file)))
         (relative (and local (file-in-directory-p local project)
                        (file-relative-name local (file-name-as-directory project)))))
    (when relative
      (when-let* ((checkout (agent-fleet-label record "fleet.checkout-root")))
        (concat (file-name-as-directory checkout) relative)))))

;;;###autoload
(defun agent-fleet-send-file (target file)
  "Transfer FILE beside live TARGET and open an unsent prompt with its path.
The Core artifact is removed with its terminal history; no checkout is written."
  (interactive (list (agent-fleet-current-target) (read-file-name "Send file: " nil nil t)))
  (let* ((record (agent-fleet-resolve target t))
         (reference (agent-fleet-reference record)) data bytes)
    (unless (equal (plist-get record :state) "live") (user-error "Choose a live agent"))
    (unless (and (not (file-remote-p file)) (file-regular-p file)
                 (<= (file-attribute-size (file-attributes file)) (* 8 1024 1024)))
      (user-error "Choose a local regular file of at most 8 MiB"))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil 0 (1+ (* 8 1024 1024)))
      (when (> (buffer-size) (* 8 1024 1024)) (user-error "File grew beyond 8 MiB"))
      (setq bytes (buffer-size) data (base64-encode-string (buffer-string) t)))
    (setq record (agent-fleet-resolve reference t))
    (let* ((result (herdr-core-request "terminal.put"
                                     (list :terminal (plist-get record :address)
                                           :name (file-name-nondirectory file) :data data)))
           (path (plist-get result :path)))
      (unless (and (stringp path) (not (string-empty-p path))
                   (equal bytes (plist-get result :bytes)))
        (signal 'herdr-core-uncertain '(:reason invalid-file-acknowledgement)))
      (agent-fleet-prompt reference (format "Attached file: %s\n\n" path)))))

(define-derived-mode agent-fleet-remote-review-mode diff-mode "Fleet Remote Review"
  "Read-only status and diff fetched from the agent's actual remote checkout."
  (setq buffer-read-only t)
  (local-set-key (kbd "q") #'agent-fleet-view-quit)
  (local-set-key (kbd "C-g") #'agent-fleet-view-quit))

(defun agent-fleet-remote-review (target)
  "Show a finite status and diff snapshot of TARGET's remote checkout."
  (let* ((record (agent-fleet-resolve target t))
         (reference (agent-fleet-reference record))
         (key (nth 1 (plist-get reference :fleet-identity)))
         (machine (car key)) (cwd (plist-get record :cwd))
         (base (or (agent-fleet-label record "fleet.review-base") "HEAD"))
         (status (agent-fleet-remote--git machine cwd "status" "--short")))
    (unless status (user-error "Remote directory is not an accessible Git checkout"))
    (unless (or (equal base "HEAD") (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" base))
      (user-error "Invalid remote review base"))
    (let ((diff (agent-fleet-remote--git machine cwd "diff" "--no-ext-diff" "--no-textconv" base "--")))
      (unless diff (user-error "Remote review base is unavailable"))
      (let ((buffer (generate-new-buffer "*Fleet Remote Review*")))
        (with-current-buffer buffer
          (insert (format "Remote checkout: %s\nReview base: %s\n\n%s\n\n%s"
                          cwd base status diff))
          (agent-fleet-remote-review-mode)
          (setq-local agent-fleet-target reference)
          (setq-local header-line-format "Snapshot · tracked changes since base; untracked files listed only · q close"))
        (agent-fleet-present-buffer buffer)))))

(provide 'agent-fleet-remote)
;;; agent-fleet-remote.el ends here
