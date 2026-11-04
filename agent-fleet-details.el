;;; agent-fleet-details.el --- Agent details and review actions -*- lexical-binding: t; -*-
;;; Commentary:
;; Refreshable snapshots pinned to one Core terminal identity.
;;; Code:
(require 'agent-fleet)
(require 'agent-fleet-project)

(defvar-local agent-fleet-details-record nil "Last successfully displayed Core record.")
(defvar agent-fleet-details-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map agent-fleet-review-mode-map)
    (dolist (binding '(("RET" . agent-fleet-attach) ("v" . agent-fleet-observe)
                       ("p" . agent-fleet-prompt) ("o" . agent-fleet-show-output)
                       ("m" . agent-fleet-magit-status) ("d" . agent-fleet-magit-diff)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map))
(define-derived-mode agent-fleet-details-mode agent-fleet-review-mode "Fleet Details"
  "Review one agent; refresh with g and use its local action keys."
  (setq-local revert-buffer-function #'agent-fleet-details--revert
              header-line-format
              '(:eval (format "Core: %s   g refresh   RET attach   p prompt   o output   m Magit   q close"
                              herdr-core--state))))

(defun agent-fleet-details--field (label value &optional face)
  "Insert a readable LABEL and VALUE, optionally styled with FACE."
  (insert (propertize (format "  %-20s" label) 'face 'font-lock-keyword-face)
          (propertize (format "%s" (or value "—")) 'face (or face 'default)) "\n"))

(defun agent-fleet-details--section (title)
  "Begin a section with TITLE."
  (insert "\n" (propertize (concat title "\n") 'face 'bold)))

(defun agent-fleet-details--render (record)
  "Display RECORD without changing this view's identity or selection."
  ;; Resolve the optional Project backend before replacing a good snapshot.
  (let ((project (agent-fleet-project-for-agent record))
        (status (agent-fleet-status record))
        (parent (plist-get record :parent))
        (position (point))
        (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "%s  [%s]\n" (agent-fleet-name record) (plist-get record :address))
                        'face 'bold)
            (propertize (format-time-string "Snapshot refreshed %Y-%m-%d %H:%M:%S\n") 'face 'shadow))
    (agent-fleet-details--section "State")
    (agent-fleet-details--field "Runtime" (plist-get record :state))
    (agent-fleet-details--field "Reported work" status
                               (cond ((member status '("blocked" "error")) 'warning)
                                     ((equal status "done") 'success)
                                     ((equal status "unreported") 'shadow)))
    (when-let* ((reason (plist-get record :reason)))
      (agent-fleet-details--field "Reason" reason))
    (when-let* ((code (plist-get record :exit_code)))
      (agent-fleet-details--field "Exit code" code (if (zerop code) 'default 'warning)))
    (cl-loop for (key value) on (plist-get record :status) by #'cddr
             unless (eq key :state)
             do (agent-fleet-details--field (substring (symbol-name key) 1) value))
    (agent-fleet-details--section "Program and location")
    (agent-fleet-details--field "Type" (agent-fleet-type record))
    (let ((app (plist-get (plist-get record :status) :app)))
      (agent-fleet-details--field "Type source"
                                 (cond ((and (stringp app) (not (string-blank-p app))) "Reported app")
                                       ((equal (agent-fleet-type record) "—") "Unavailable")
                                       (t "Launch command"))))
    (agent-fleet-details--field "Command" (when-let* ((argv (plist-get record :argv)))
                                            (mapconcat #'shell-quote-argument argv " ")))
    (when-let* ((template (plist-get record :template)))
      (agent-fleet-details--field "Template" template))
    (agent-fleet-details--field "Project" (if (or (null project) (stringp project)) project
                                            (format "%s (remote)" (nth 2 project))))
    (agent-fleet-details--field "Directory" (plist-get record :cwd))
    (agent-fleet-details--section "Relationships and recovery")
    (agent-fleet-details--field "Parent" (or parent "— (independent)"))
    (when parent
      (agent-fleet-details--field "Ends with parent" (if (eq (plist-get record :die_with_parent) t) "Yes" "No")))
    (agent-fleet-details--field "On program loss" (if (eq (plist-get record :keep) t)
                                                "Replace with a shell" "No replacement"))
    (when-let* ((first (plist-get record :first_message)))
      (agent-fleet-details--section "Initial task")
      (agent-fleet-details--field "Submission" (pcase (plist-get first :sent)
                                                ('t "Sent") (':false "Not sent") (_ "Unreported")))
      (when-let* ((reason (plist-get first :reason)))
        (agent-fleet-details--field "Reason" reason 'warning)))
    (when-let* ((labels (plist-get record :labels)))
      (agent-fleet-details--section "Labels")
      (cl-loop for (key value) on labels by #'cddr
               do (agent-fleet-details--field (substring (symbol-name key) 1) value)))
    (setq agent-fleet-details-record record)
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

(defun agent-fleet-details--revert (&optional _ignore-auto _noconfirm)
  "Refresh this view's verified target, retaining the snapshot on failure."
  (agent-fleet-details--render (agent-fleet-resolve agent-fleet-target t)))

;;;###autoload
(defun agent-fleet-details (target)
  "Review TARGET's state, location and relationships in its own detail view."
  (interactive (list (agent-fleet-current-target t)))
  (let* ((record (agent-fleet-resolve target t))
         (reference (agent-fleet-reference record))
         (buffer (agent-fleet-view-buffer 'agent-fleet-details-mode reference
                                          (format "*Fleet Details: %s*" (plist-get record :address)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-fleet-details-mode) (agent-fleet-details-mode))
      (agent-fleet-details--render record)
      (setq-local agent-fleet-target reference))
    (agent-fleet-present-buffer buffer)))

(provide 'agent-fleet-details)
;;; agent-fleet-details.el ends here
