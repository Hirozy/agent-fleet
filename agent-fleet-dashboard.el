;;; agent-fleet-dashboard.el --- Agent overview -*- lexical-binding: t; -*-
;;; Commentary:
;; One event-driven view of Fleet members and Core connectivity.
;;; Code:
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'tabulated-list)
(defcustom agent-fleet-dashboard-display 'buffer
  "Dashboard presentation, with a buffer fallback on unsupported runtimes."
  :type '(choice (const buffer) (const child-frame)) :group 'agent-fleet)
(defcustom agent-fleet-notify-on '("blocked" "error" "done")
  "Reported states announced in the echo area."
  :type '(repeat string) :group 'agent-fleet)
(defvar-local agent-fleet-dashboard--history nil)
(defvar-local agent-fleet-dashboard--project nil)
(defvar-local agent-fleet-dashboard--attention nil)
(defvar-local agent-fleet-dashboard--pending-focus nil)
(defvar agent-fleet-dashboard--child nil)
(defvar agent-fleet-dashboard--origin nil)
(defvar agent-fleet-dashboard--origin-window nil)

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
      (let ((id (or agent-fleet-dashboard--pending-focus (tabulated-list-get-id))))
        (setq tabulated-list-entries
              (mapcar
               (lambda (r)
                 (list (plist-get r :address)
                       (vector (agent-fleet-name r)
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
                (agent-fleet-agents agent-fleet-dashboard--history))))
        (setq header-line-format
              (format "Core: %s   %s   Project: %s   RET attach  p prompt  o output  c cleanup"
                      herdr-core--state (if agent-fleet-dashboard--history "All records" "Live")
                      (or agent-fleet-dashboard--project "All")))
        (tabulated-list-print t)
        (when id (agent-fleet-dashboard-focus id))))))

(defun agent-fleet-dashboard-focus (address)
  "Move an existing Dashboard to ADDRESS without stealing focus."
  (when-let* ((buffer (get-buffer "*Agent Fleet*")))
    (with-current-buffer buffer
      (goto-char (point-min))
      (while (and (not (eobp)) (not (equal (tabulated-list-get-id) address)))
        (forward-line 1))
      (setq agent-fleet-dashboard--pending-focus
            (unless (equal (tabulated-list-get-id) address) address)))))

(defun agent-fleet-dashboard--target ()
  "Return a pinned target for the current row."
  (let ((id (tabulated-list-get-id)))
    (unless id (user-error "No agent on this row"))
    (agent-fleet-reference (agent-fleet-resolve id))))

(defun agent-fleet-dashboard--visit (function &optional target)
  "Run FUNCTION for TARGET at the origin; close the child only on success."
  (let* ((child (and (eq (selected-frame) agent-fleet-dashboard--child)
                     agent-fleet-dashboard--child))
         (origin agent-fleet-dashboard--origin)
         (window agent-fleet-dashboard--origin-window))
    (when child
      (unless (and (frame-live-p origin) (window-live-p window))
        (user-error "Dashboard origin is no longer available"))
      (select-frame-set-input-focus origin)
      (select-window window))
    (condition-case err
        (let ((result (if target (funcall function target) (funcall function))))
          (if (and child (agent-fleet-display--outcome-opened-p result))
              (progn (delete-frame child) (setq agent-fleet-dashboard--child nil))
            (when child (select-frame-set-input-focus child)))
          result)
      ((error quit)
       (when (and child (frame-live-p child)) (select-frame-set-input-focus child))
       (signal (car err) (cdr err))))))

(defun agent-fleet-dashboard-attach () "Attach to the current row."
  (interactive) (agent-fleet-dashboard--visit #'agent-fleet-attach (agent-fleet-dashboard--target)))
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
  "Close the Dashboard, retaining its origin."
  (interactive)
  (if (eq (selected-frame) agent-fleet-dashboard--child)
      (let ((origin agent-fleet-dashboard--origin))
        (delete-frame agent-fleet-dashboard--child)
        (setq agent-fleet-dashboard--child nil)
        (when (frame-live-p origin) (select-frame-set-input-focus origin)))
    (quit-window)))

(defvar agent-fleet-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (dolist (pair '(("RET" . agent-fleet-dashboard-attach) ("p" . agent-fleet-dashboard-prompt)
                    ("o" . agent-fleet-dashboard-output) ("i" . agent-fleet-dashboard-details)
                    ("m" . agent-fleet-dashboard-magit) ("d" . agent-fleet-dashboard-diff)
                    ("c" . agent-fleet-dashboard-cleanup) ("n" . agent-fleet-dashboard-start)
                    ("k" . agent-fleet-dashboard-kill) ("s" . agent-fleet-dashboard-interrupt)
                    ("h" . agent-fleet-dashboard-history) ("P" . agent-fleet-dashboard-project)
                    ("!" . agent-fleet-dashboard-attention) ("g" . agent-fleet-dashboard-refresh)
                    ("q" . agent-fleet-dashboard-quit) ("C-g" . agent-fleet-dashboard-quit)))
      (define-key map (kbd (car pair)) (cdr pair))) map))
(define-derived-mode agent-fleet-mode tabulated-list-mode "Agent Fleet"
  "Live agent overview."
  (setq tabulated-list-format [("Agent" 24 t) ("Project" 18 t) ("Role" 8 t)
                              ("State" 24 t) ("Parent" 10 t) ("Address" 14 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-fleet ()
  "Open the Core-backed Agent Fleet Dashboard."
  (interactive)
  (herdr-core-connect)
  (let* ((origin (agent-fleet-display-origin-frame))
         (window (cond
                  ((eq (selected-frame) agent-fleet-dashboard--child)
                   agent-fleet-dashboard--origin-window)
                  ((eq (selected-frame) origin) (selected-window))
                  (t (frame-selected-window origin))))
         (buffer (get-buffer-create "*Agent Fleet*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-fleet-mode) (agent-fleet-mode)))
    (agent-fleet-dashboard-refresh)
    (if (and (eq agent-fleet-dashboard-display 'child-frame)
             (agent-fleet-display-child-frame-available-p origin))
        (progn
          (unless (and (frame-live-p agent-fleet-dashboard--child)
                       (eq (frame-parent agent-fleet-dashboard--child) origin))
            (when (frame-live-p agent-fleet-dashboard--child)
              (delete-frame agent-fleet-dashboard--child))
            (setq agent-fleet-dashboard--child
                  (make-frame `((parent-frame . ,origin) (minibuffer . nil)
                                (width . 110) (height . 26) (undecorated . t)
                                (menu-bar-lines . 0) (tool-bar-lines . 0)
                                (agent-fleet-dashboard-display . child-frame)))))
          (setq agent-fleet-dashboard--origin origin
                agent-fleet-dashboard--origin-window window)
          (set-window-buffer (frame-root-window agent-fleet-dashboard--child) buffer)
          (agent-fleet-display--center-child-frame agent-fleet-dashboard--child origin)
          (select-frame-set-input-focus agent-fleet-dashboard--child))
      (when (eq agent-fleet-dashboard-display 'child-frame)
        (message "Child frames unavailable; opening Dashboard buffer"))
      (agent-fleet-present-buffer buffer))
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
