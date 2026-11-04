;;; agent-fleet-start.el --- Advanced start form -*- lexical-binding: t; -*-
;;; Commentary:
;; One editable form for local agent launch options.
;;; Code:
(require 'agent-fleet)
(require 'wid-edit)
(defvar-local agent-fleet--start-fields nil)

;;;###autoload
(defun agent-fleet-start-form ()
  "Open a single form for command, directory, name and initial template task."
  (interactive)
  (let ((buffer (generate-new-buffer "*Fleet Start*"))
        (cwd default-directory))
    (with-current-buffer buffer
      (insert (propertize "Start Agent\n\n" 'face 'bold)
              "C-c C-c starts; C-c C-k closes. Initial task requires a template.\n\n")
      (setq-local agent-fleet--start-fields
                  (list (widget-create 'editable-field :format "Command or template: %v\n" "claude")
                        (widget-create 'directory :format "Directory: %v\n" cwd)
                        (widget-create 'editable-field :format "Name (optional): %v\n" "")
                        (widget-create 'text :format "Initial task:\n%v\n" "")))
      (use-local-map (copy-keymap widget-keymap))
      (local-set-key (kbd "C-c C-c") #'agent-fleet--start-form-submit)
      (local-set-key (kbd "C-c C-k") #'agent-fleet-view-quit)
      (widget-setup))
    (agent-fleet-present-buffer buffer)))

(defun agent-fleet--start-form-submit ()
  "Submit this start form once."
  (interactive)
  (when agent-fleet-operation-state
    (user-error "Launch already requested; inspect Dashboard before starting again"))
  (pcase-let* ((`(,command ,cwd ,name ,task)
               (mapcar #'widget-value agent-fleet--start-fields))
              (choices (agent-fleet--commands))
              (argv (or (cdr (assoc command choices)) (split-string-and-unquote command))))
    (let ((buffer (current-buffer)))
      (agent-fleet-start argv :cwd cwd :name (unless (string-empty-p name) name)
                         :task (unless (string-empty-p task) task) :display t)
      (with-current-buffer buffer
        (setq agent-fleet-operation-state 'requested
              header-line-format "Launch requested — inspect Dashboard for its result")))))
(provide 'agent-fleet-start)
;;; agent-fleet-start.el ends here
