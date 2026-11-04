;;; agent-fleet-batch.el --- Review and launch several agents -*- lexical-binding: t; -*-
;;; Commentary:
;; This buffer records launch outcomes, not an independent agent lifecycle.
;;; Code:
(require 'agent-fleet-worktree)
(defvar-local agent-fleet-batch--entries nil)
(defvar-local agent-fleet-batch--core nil)
(defvar-local agent-fleet-batch--id nil)
(defvar-local agent-fleet-batch--submitted nil)
(defvar agent-fleet-batch-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map agent-fleet-review-mode-map)
    (define-key map (kbd "C-c C-c") #'agent-fleet-batch-execute) map))
(define-derived-mode agent-fleet-batch-mode agent-fleet-review-mode "Fleet Launches"
  "Review launches and their individual acknowledgements.")

(defun agent-fleet-batch--render ()
  "Render the launch report without losing outcomes."
  (let ((inhibit-read-only t) (position (point)))
    (erase-buffer)
    (insert (propertize "Agent launches\n\n" 'face 'bold))
    (insert (if agent-fleet-batch--submitted
                "Requested once. Started programs and created checkouts are retained.\n\n"
              "C-c C-c launches these members once. q closes without launching.\n\n"))
    (dolist (entry agent-fleet-batch--entries)
      (let* ((spec (plist-get entry :spec)) (state (plist-get entry :state)))
        (insert (propertize (format "%s  %s\n" (plist-get spec :name) state)
                            'face (pcase state ('started 'success)
                                          ((or 'failed 'uncertain) 'warning) (_ 'bold))))
        (insert (format "  Command: %S\n  Directory: %s\n"
                        (plist-get spec :argv) (plist-get spec :cwd)))
        (when-let* ((worktree (plist-get spec :worktree)))
          (insert (format "  New worktree: %s   branch: %s   base: %s\n"
                          (plist-get worktree :directory) (plist-get worktree :branch)
                          (or (plist-get worktree :base) "HEAD"))))
        (when-let* ((detail (plist-get entry :detail))) (insert (format "  %s\n" detail)))
        (insert "\n")))
    (goto-char (min position (point-max)))))

(defun agent-fleet-batch--interactive ()
  "Read a command, count and individual launch directories."
  (let* ((current-prefix-arg nil)
         (start (agent-fleet--start-interactive))
         (argv (car start)) (cwd (plist-get (cdr start) :cwd))
         (count (read-number "Number of agents: " 2))
         (worktrees (y-or-n-p "Create a separate Git worktree for each agent? ")) specs)
    (unless (and (integerp count) (> count 0) (<= count 100))
      (user-error "Choose between 1 and 100 agents"))
    (dotimes (i count)
      (push (if worktrees
                (list :argv argv :cwd cwd
                      :worktree (list :branch (read-string (format "Agent %d new branch: " (1+ i)))
                                      :directory (read-directory-name "New worktree directory: " cwd nil nil)))
              (list :argv argv :cwd (read-directory-name
                                     (format "Agent %d directory: " (1+ i)) cwd nil t))) specs))
    (list (nreverse specs))))

;;;###autoload
(defun agent-fleet-start-batch (specs)
  "Review SPECS before launching with C-c C-c.
Each spec has :argv, :cwd and optional :name, :task and :worktree.
A :worktree plist has :directory, :branch and optional :base; :cwd is its
source repository.  Core labels group members; there is no Task lifecycle."
  (interactive (agent-fleet-batch--interactive))
  (herdr-core-connect)
  (unless specs (user-error "Provide at least one launch"))
  (let ((buffer (generate-new-buffer "*Fleet Launches*"))
        (id (substring (md5 (format "%s-%s-%s" (herdr-core-id) (float-time) (random))) 0 12)))
    (with-current-buffer buffer
      (agent-fleet-batch-mode)
      (setq agent-fleet-batch--core (herdr-core-id) agent-fleet-batch--id id
            agent-fleet-batch--entries
            (cl-loop for spec in specs for i from 1
                     collect (list :spec (plist-put (copy-tree spec) :name
                                                     (or (plist-get spec :name)
                                                         (format "batch-%s-%d" id i)))
                                   :state 'pending :detail nil)))
      (agent-fleet-batch--render))
    (agent-fleet-present-buffer buffer)))

(defun agent-fleet-batch-execute ()
  "Request every reviewed launch once, preserving individual outcomes."
  (interactive)
  (unless (and (derived-mode-p 'agent-fleet-batch-mode) (not agent-fleet-batch--submitted))
    (user-error "This launch review has already been submitted"))
  (herdr-core-connect)
  (unless (equal agent-fleet-batch--core (herdr-core-id))
    (user-error "Core changed; create a new launch review"))
  (setq agent-fleet-batch--submitted t)
  (let ((buffer (current-buffer)) (core agent-fleet-batch--core)
        (id agent-fleet-batch--id))
    (dolist (entry agent-fleet-batch--entries)
      (let* ((entry entry) (spec (plist-get entry :spec)) (cwd (plist-get spec :cwd))
             (labels (list :fleet.batch id)))
        (condition-case err
            (progn
              (unless (and (eq herdr-core--state 'connected) (equal core (herdr-core-id)))
                (error "Connection changed; launch not dispatched"))
              (when-let* ((wt (plist-get spec :worktree)))
                (let ((options (agent-fleet-worktree-prepare
                                cwd (plist-get wt :directory) (plist-get wt :branch)
                                (plist-get wt :base))))
                  (setq cwd (plist-get options :cwd)
                        labels (append labels (plist-get options :labels)))
                  (setf (plist-get entry :detail) (format "Checkout retained: %s" cwd))))
              (setf (plist-get entry :state) 'starting)
              (agent-fleet-start
               (plist-get spec :argv) :cwd cwd :name (plist-get spec :name)
               :task (plist-get spec :task) :labels labels
               :callback
               (lambda (record error)
                 (setf (plist-get entry :state)
                       (cond ((eq (car error) 'herdr-core-uncertain) 'uncertain)
                             (error 'failed) (t 'started))
                       (plist-get entry :detail)
                       (format "%s; checkout: %s" (if error (error-message-string error)
                                                    (format "%s; first message: %S"
                                                            (plist-get record :address)
                                                            (plist-get record :first_message))) cwd))
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer (agent-fleet-batch--render))))))
          (error (setf (plist-get entry :state) 'failed
                       (plist-get entry :detail) (format "%s; checkout: %s"
                                                        (error-message-string err) cwd)))))))
  (agent-fleet-batch--render))

(provide 'agent-fleet-batch)
;;; agent-fleet-batch.el ends here
