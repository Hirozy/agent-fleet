;;; agent-fleet-dashboard.el --- Agent overview -*- lexical-binding: t; -*-
;;; Commentary:
;; One event-driven view of Fleet members and Core connectivity.
;;; Code:
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'tabulated-list)
(defcustom agent-fleet-notify-on '("blocked" "error" "done")
  "Reported states announced in the echo area."
  :type '(repeat string) :group 'agent-fleet)
(defvar-local agent-fleet-dashboard--history nil)
(defvar-local agent-fleet-dashboard--project nil)
(defvar-local agent-fleet-dashboard--attention nil)
(defvar-local agent-fleet-dashboard--pending-focus nil)
(defconst agent-fleet-dashboard--columns
  [("Agent" 22 t) ("Type" 12 t) ("Project" 16 t) ("Role" 7 t)
   ("State" 22 t) ("Parent" 8 t) ("Address" 10 t)])

(defun agent-fleet-dashboard--state-cell (r)
  "Return a styled state cell for R."
  (let* ((work (agent-fleet-status r))
         (text (if (equal (plist-get r :state) "finished")
                   (format "finished (%s)" (or (plist-get r :exit_code) (plist-get r :reason) "—"))
                 (if (plist-get r :reason) (format "recovering: %s" (plist-get r :reason)) work))))
    (propertize text 'face (cond ((member work '("blocked" "error")) 'warning)
                                 ((equal work "done") 'success) (t 'default)))))

(defun agent-fleet-dashboard-refresh ()
  "Render the current cache without polling Core."
  (interactive)
  (when-let* ((buffer (get-buffer "*Agent Fleet*")))
    (with-current-buffer buffer
      (unless (assoc "Type" (append tabulated-list-format nil))
        (setq tabulated-list-format (copy-tree agent-fleet-dashboard--columns t))
        (tabulated-list-init-header))
      (let ((id (tabulated-list-get-id))
            (pending agent-fleet-dashboard--pending-focus)
            (members (agent-fleet-agents agent-fleet-dashboard--history)))
        (setq tabulated-list-entries
              (mapcar
               (lambda (r)
                 (list (plist-get r :address)
                       (vector (agent-fleet-name r)
                               (agent-fleet-type r)
                               (agent-fleet-project-label r)
                               (if (equal (agent-fleet-label r "fleet.role") "agent") "agent" "helper")
                               (agent-fleet-dashboard--state-cell r)
                               (or (plist-get r :parent) "—")
                               (plist-get r :address))))
               (cl-remove-if-not
                (lambda (r)
                  (and (or (not agent-fleet-dashboard--project)
                           (equal agent-fleet-dashboard--project (agent-fleet-project-for-agent r)))
                       (or (not agent-fleet-dashboard--attention)
                           (member (agent-fleet-status r) '("blocked" "error")))))
                members)))
        (setq header-line-format
              (format "Core: %s   %s %d/%d   Project: %s%s   RET attach  p prompt  o output  c cleanup"
                      herdr-core--state (if agent-fleet-dashboard--history "All records" "Live")
                      (length tabulated-list-entries) (length members)
                      (or agent-fleet-dashboard--project "All")
                      (if agent-fleet-dashboard--attention "   Attention only" "")))
        (tabulated-list-print t)
        (let ((focused (agent-fleet-dashboard--goto pending)))
          (when (or focused (and pending (herdr-core-terminal pending)))
            (setq agent-fleet-dashboard--pending-focus nil))
          (unless (or focused (agent-fleet-dashboard--goto id) (tabulated-list-get-id))
            (goto-char (point-min))))
        (unless tabulated-list-entries
          (let ((inhibit-read-only t))
            (insert (propertize
                     (if (or agent-fleet-dashboard--project agent-fleet-dashboard--attention)
                         (concat "No agents match the current filters. "
                                 (when agent-fleet-dashboard--project "P clears the Project filter. ")
                                 (when agent-fleet-dashboard--attention "! clears the attention filter. ")
                                 "h toggles history.\n")
                       "No Fleet agents in this view. Press n to start an agent, or h to toggle history.\n")
                     'face 'shadow))
            (goto-char (point-min))))))))

(defun agent-fleet-dashboard--goto (address)
  "Select visible ADDRESS, returning non-nil; leave point alone if absent."
  (when address
    (when-let* ((position (save-excursion
                           (goto-char (point-min))
                           (while (and (not (eobp)) (not (equal (tabulated-list-get-id) address)))
                             (forward-line 1))
                           (and (not (eobp)) (point)))))
      (goto-char position)
      t)))

(defun agent-fleet-dashboard-focus (address)
  "Move an existing Dashboard to ADDRESS without stealing focus."
  (when-let* ((buffer (get-buffer "*Agent Fleet*")))
    (with-current-buffer buffer
      (setq agent-fleet-dashboard--pending-focus
            (unless (or (agent-fleet-dashboard--goto address) (herdr-core-terminal address))
              address)))))

(defun agent-fleet-dashboard--target ()
  "Return a pinned target for the current row."
  (let ((id (tabulated-list-get-id)))
    (unless id (user-error "No agent on this row"))
    (agent-fleet-reference (agent-fleet-resolve id))))

(defun agent-fleet-dashboard--visit (function &optional target)
  "Open FUNCTION for TARGET in the current review window."
  (let ((open (lambda () (if target (funcall function target) (funcall function)))))
    (if (agent-fleet-display-window-active-p)
        (agent-fleet-display-window-call open)
      (funcall open))))

(defun agent-fleet-dashboard-attach () "Attach to the current row."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-attach (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-observe () "Observe the current row without taking input."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-observe (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-prompt () "Compose for the current row."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-prompt (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-output () "Inspect the current row."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-show-output (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-details () "Describe the current row."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-details (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-magit () "Review the current row."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-magit-status (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-diff () "Diff the current row."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-magit-diff (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-cleanup () "Review eligible history."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-cleanup))
(defun agent-fleet-dashboard-start () "Open the start form."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-start-form))
(defun agent-fleet-dashboard-kill () "End the current row explicitly."
  (interactive) (agent-fleet-kill (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-interrupt () "Interrupt the current row."
  (interactive) (agent-fleet-interrupt (agent-fleet-dashboard--target)))

(defun agent-fleet-dashboard-history ()
  "Toggle finished records."
  (interactive)
  (setq agent-fleet-dashboard--history (not agent-fleet-dashboard--history))
  (agent-fleet-dashboard-refresh))
(defun agent-fleet-dashboard-project ()
  "Toggle the current row's Project filter."
  (interactive)
  (setq agent-fleet-dashboard--project
        (unless agent-fleet-dashboard--project
          (or (agent-fleet-project-for-agent (agent-fleet-resolve (agent-fleet-dashboard--target)))
              (user-error "This agent has no Project"))))
  (agent-fleet-dashboard-refresh))
(defun agent-fleet-dashboard-attention ()
  "Toggle members needing attention."
  (interactive)
  (setq agent-fleet-dashboard--attention (not agent-fleet-dashboard--attention))
  (agent-fleet-dashboard-refresh))
(defun agent-fleet-dashboard-quit ()
  "Return to the buffer and position from before Dashboard opened."
  (interactive)
  (agent-fleet-view-quit))

(defvar agent-fleet-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (dolist (pair '(("RET" . agent-fleet-dashboard-attach) ("v" . agent-fleet-dashboard-observe)
                    ("p" . agent-fleet-dashboard-prompt)
                    ("o" . agent-fleet-dashboard-output) ("i" . agent-fleet-dashboard-details)
                    ("m" . agent-fleet-dashboard-magit) ("d" . agent-fleet-dashboard-diff)
                    ("c" . agent-fleet-dashboard-cleanup) ("n" . agent-fleet-dashboard-start)
                    ("k" . agent-fleet-dashboard-kill) ("s" . agent-fleet-dashboard-interrupt)
                    ("h" . agent-fleet-dashboard-history) ("P" . agent-fleet-dashboard-project)
                    ("!" . agent-fleet-dashboard-attention) ("g" . agent-fleet-dashboard-refresh)
                    ("q" . agent-fleet-dashboard-quit) ("C-g" . agent-fleet-dashboard-quit)))
      (define-key map (kbd (car pair)) (cdr pair))) map))
(agent-fleet-protect-keymap agent-fleet-mode-map)
(define-derived-mode agent-fleet-mode tabulated-list-mode "Agent Fleet"
  "Live agent overview."
  (setq-local agent-fleet-target-function #'agent-fleet-dashboard--target)
  (setq-local agent-fleet-presentation-function #'agent-fleet-dashboard--visit)
  (setq tabulated-list-format (copy-tree agent-fleet-dashboard--columns t))
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-fleet ()
  "Open Dashboard in the current window, retaining its previous view."
  (interactive)
  (herdr-core-connect)
  (let ((buffer (get-buffer-create "*Agent Fleet*"))
        (child (and (frame-parameter nil 'agent-fleet-auxiliary-frame) (selected-frame)))
        (previous (current-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-fleet-mode) (agent-fleet-mode)))
    (agent-fleet-dashboard-refresh)
    (when child
      (select-frame-set-input-focus (agent-fleet-display-origin-frame child))
      (agent-fleet-display-window-open previous))
    (agent-fleet-display-window-open buffer)
    (when child (agent-fleet-display-close-auxiliary-frame child))
    buffer))

(defun agent-fleet-dashboard--notify (event)
  "Announce applied status EVENT without inferring work from output."
  (when (equal (plist-get event :type) "status")
    (when-let* ((record (herdr-core-terminal (plist-get event :terminal)))
                ((agent-fleet-managed-p record))
                ((member (agent-fleet-status record) agent-fleet-notify-on)))
      (message "%s: %s" (agent-fleet-name record) (agent-fleet-status record)))))
(add-hook 'herdr-core-changed-hook #'agent-fleet-dashboard-refresh)
(add-hook 'herdr-core-event-hook #'agent-fleet-dashboard--notify)
(provide 'agent-fleet-dashboard)
;;; agent-fleet-dashboard.el ends here
