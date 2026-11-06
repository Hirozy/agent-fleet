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
    (dolist (binding '(("n" . agent-fleet-batch-next) ("p" . agent-fleet-batch-previous)
                       ("RET" . agent-fleet-attach) ("i" . agent-fleet-details)
                       ("o" . agent-fleet-show-output) ("v" . agent-fleet-observe)
                       ("s" . agent-fleet-prompt)))
      (define-key map (kbd (car binding)) (cdr binding)))
    (define-key map (kbd "C-c C-c") #'agent-fleet-batch-execute) map))
(define-derived-mode agent-fleet-batch-mode agent-fleet-review-mode "Fleet Launches"
  "Review launches and their individual acknowledgements."
  (setq-local agent-fleet-target-function #'agent-fleet-batch--target))

(defun agent-fleet-batch--target ()
  "Return the acknowledged identity of the launch at point."
  (let ((entry (get-text-property (point) 'fleet-batch-entry)))
    (unless (and entry (eq (plist-get entry :state) 'started)
                 (herdr-core--valid-terminal-p (plist-get entry :record)))
      (user-error "Select a successfully started member"))
    (herdr-core-connect)
    (unless (equal agent-fleet-batch--core (herdr-core-id))
      (user-error "Core changed; this report belongs to another connection"))
    (agent-fleet-reference (plist-get entry :record))))

(defun agent-fleet-batch--render ()
  "Render the launch report without losing outcomes."
  (let ((inhibit-read-only t)
        (current-entry (get-text-property (point) 'fleet-batch-entry)))
    (erase-buffer)
    (insert (propertize "Agent launches\n\n" 'face 'bold))
    (insert (if agent-fleet-batch--submitted
                "Requested once. Started programs and created checkouts are retained.\n\n"
              "C-c C-c launches these members once. q closes without launching.\n\n"))
    (insert (mapconcat
             (lambda (state)
               (format "%d %s" (cl-count state agent-fleet-batch--entries
                                          :key (lambda (entry) (plist-get entry :state)))
                       (if (eq state 'not-attempted) "not attempted" state)))
             (cl-remove-if-not
              (lambda (state) (cl-find state agent-fleet-batch--entries
                                       :key (lambda (entry) (plist-get entry :state))))
              '(pending starting started failed uncertain not-attempted)) "  ·  ") "\n\n")
    (dolist (entry agent-fleet-batch--entries)
      (let* ((spec (plist-get entry :spec)) (state (plist-get entry :state)) (begin (point)))
        (insert (propertize (format "%s  %s\n" (plist-get spec :name) state)
                            'face (pcase state ('started 'success)
                                          ((or 'failed 'uncertain) 'warning) (_ 'bold))))
        (insert (format "  Command: %s\n  Directory: %s\n"
                        (mapconcat #'shell-quote-argument (plist-get spec :argv) " ") (plist-get spec :cwd)))
        (when-let* ((task (plist-get spec :task)))
          (insert (propertize "  Initial task:\n" 'face 'font-lock-keyword-face)
                  (replace-regexp-in-string "^" "    " task) "\n"))
        (when-let* ((worktree (plist-get spec :worktree)))
          (insert (format "  New worktree: %s   branch: %s   base: %s\n"
                          (plist-get worktree :directory) (plist-get worktree :branch)
                          (or (plist-get worktree :base) "HEAD"))))
        (when-let* ((checkout (plist-get entry :checkout)))
          (insert (format "  Checkout retained: %s\n" checkout)))
        (when-let* ((detail (plist-get entry :detail))) (insert (format "  %s\n" detail)))
        (insert "\n")
        (add-text-properties begin (point) (list 'fleet-batch-entry entry))))
    (setq header-line-format
          (if agent-fleet-batch--submitted
              "n/p members   RET attach   i details   o output   s prompt   q close"
            "n/p members   C-c C-c launch once   q cancel"))
    (goto-char (or (and current-entry
                        (text-property-any (point-min) (point-max) 'fleet-batch-entry current-entry))
                   (text-property-not-all (point-min) (point-max) 'fleet-batch-entry nil)
                   (point-min)))
    (set-buffer-modified-p nil)))

(defun agent-fleet-batch--move (direction)
  "Move DIRECTION members, keeping point on a launch rather than its metadata."
  (let* ((entry (get-text-property (point) 'fleet-batch-entry))
         (index (and entry (cl-position entry agent-fleet-batch--entries :test #'eq)))
         (next (if index (+ index direction)
                 (if (> direction 0) 0 (1- (length agent-fleet-batch--entries)))))
         (target (nth (max 0 (min next (1- (length agent-fleet-batch--entries))))
                      agent-fleet-batch--entries)))
    (when target
      (goto-char (text-property-any (point-min) (point-max) 'fleet-batch-entry target)))))

;;;###autoload
(defun agent-fleet-batch-next ()
  "Move to the next batch member."
  (interactive)
  (agent-fleet-batch--move 1))

;;;###autoload
(defun agent-fleet-batch-previous ()
  "Move to the previous batch member."
  (interactive)
  (agent-fleet-batch--move -1))

(defun agent-fleet-batch--finish (buffer entry record err)
  "Retain ENTRY's RECORD or ERR and update BUFFER without changing focus."
  (when (and (null err) (not (herdr-core--valid-terminal-p record)))
    (setq err (list 'herdr-core-uncertain :reason 'invalid-launch-response :response record)))
  (setf (plist-get entry :record) record
        (plist-get entry :error) err
        (plist-get entry :state) (cond ((null err) 'started)
                                      ((eq (car err) 'herdr-core-request-error) 'failed)
                                      (t 'uncertain))
        (plist-get entry :detail)
        (if err (herdr-core-error-message err)
          (concat (format "Started [%s]" (plist-get record :address))
                  (when-let* ((first (plist-get record :first_message)))
                    (unless (eq (plist-get first :sent) t)
                      (format "\n  Initial task was NOT sent: %s" (plist-get first :reason)))))))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (agent-fleet-batch--render))))

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
            ;; Preallocate fields so plist updates mutate the shared entry.
            (cl-loop for spec in specs for i from 1
                     collect (list :spec (plist-put (copy-tree spec) :name
                                                     (or (plist-get spec :name)
                                                         (format "batch-%s-%d" id i)))
                                   :state 'pending :detail nil :record nil :error nil :checkout nil)))
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
        (id agent-fleet-batch--id) stop)
    (unwind-protect
        (dolist (entry agent-fleet-batch--entries)
          (when (cl-some (lambda (member) (eq (plist-get member :state) 'uncertain))
                        agent-fleet-batch--entries)
            (setq stop t))
          (unless stop
            (let* ((entry entry) (spec (plist-get entry :spec)) (cwd (plist-get spec :cwd))
                   (labels (list :fleet.batch id)) dispatching)
              (condition-case err
                  (progn
                    (unless (and (eq herdr-core--state 'connected) (equal core (herdr-core-id)))
                      (setq stop t)
                      (error "Connection changed; launch not dispatched"))
                    (when-let* ((wt (plist-get spec :worktree)))
                      (let ((options (agent-fleet-worktree-prepare
                                      cwd (plist-get wt :directory) (plist-get wt :branch)
                                      (plist-get wt :base))))
                        (setq cwd (plist-get options :cwd)
                              labels (append labels (plist-get options :labels)))
                        (setf (plist-get entry :checkout) cwd)))
                    (setf (plist-get entry :state) 'starting)
                    (setq dispatching t)
                    (agent-fleet-start
                     (plist-get spec :argv) :cwd cwd :name (plist-get spec :name)
                     :task (plist-get spec :task) :labels labels
                     :callback (lambda (record err) (agent-fleet-batch--finish buffer entry record err))))
                ((error quit)
                 (when (memq (plist-get entry :state) '(pending starting))
                   (setf (plist-get entry :state)
                         (if (and dispatching (not (eq (car err) 'user-error))) 'uncertain 'failed)
                         (plist-get entry :error) err
                         (plist-get entry :detail) (herdr-core-error-message err)))
                 (when (eq (car err) 'quit) (signal (car err) (cdr err))))))))
      (dolist (entry agent-fleet-batch--entries)
        (when (eq (plist-get entry :state) 'pending)
          (setf (plist-get entry :state) 'not-attempted
                (plist-get entry :detail) "Not dispatched after interruption, connection change or uncertain outcome")))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (agent-fleet-batch--render))))))

(provide 'agent-fleet-batch)
;;; agent-fleet-batch.el ends here
