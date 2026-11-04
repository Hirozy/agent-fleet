;;; agent-fleet-start.el --- Advanced start form -*- lexical-binding: t; -*-
;;; Commentary:
;; One editable form for local agent launch options.
;;; Code:
(require 'agent-fleet)
(require 'wid-edit)
(defvar-local agent-fleet--start-fields nil)
(defvar-local agent-fleet-start--result-marker nil)

(defun agent-fleet-start--keymap (parent)
  "Copy widget PARENT and keep launch/close available inside its fields."
  (let ((map (copy-keymap parent)))
    (define-key map (kbd "C-c C-c") #'agent-fleet--start-form-submit)
    (define-key map (kbd "C-c C-k") #'agent-fleet-view-quit)
    (define-key map (kbd "C-c C-a") #'agent-fleet--start-form-attach)
    map))

(defvar agent-fleet-start-mode-map (agent-fleet-start--keymap widget-keymap))
(define-derived-mode agent-fleet-start-mode fundamental-mode "Fleet Start"
  "Edit an explicit agent launch form.")

;;;###autoload
(defun agent-fleet-start-form ()
  "Open a single form for command, directory, name and initial template task."
  (interactive)
  (let ((buffer (generate-new-buffer "*Fleet Start*"))
        (cwd default-directory))
    (with-current-buffer buffer
      (agent-fleet-start-mode)
      (insert (propertize "Start Agent\n\n" 'face 'bold)
              "C-c C-c starts; C-c C-k closes. Initial task requires a template.\n\n")
      (let ((field-map (agent-fleet-start--keymap widget-field-keymap))
            (text-map (agent-fleet-start--keymap
                       (widget-get (widget-convert 'text) :keymap))))
        (setq agent-fleet--start-fields
              (list (widget-create 'editable-field :keymap field-map
                                   :format "Command or template: %v\n"
                                   (or agent-fleet--last-command (car agent-fleet-commands) ""))
                    (widget-create 'directory :keymap field-map :format "Directory: %v\n" cwd)
                    (widget-create 'editable-field :keymap field-map :format "Name (optional): %v\n" "")
                    (widget-create 'text :keymap text-map :format "Initial task:\n%v\n" ""))))
      (goto-char (point-max))
      (insert "\n\n")
      (setq agent-fleet-start--result-marker (copy-marker (point)))
      (widget-setup)
      (agent-fleet-start--render-result)
      (goto-char (widget-field-start (car agent-fleet--start-fields))))
    (agent-fleet-present-buffer buffer)))

(defun agent-fleet-start--render-result ()
  "Render this form's launch acknowledgement without replacing its fields."
  (let* ((state agent-fleet-operation-state)
         (result agent-fleet-operation-result)
         (first (and (eq state 'started) (plist-get result :first_message)))
         (inhibit-read-only t)
         (inhibit-modification-hooks t))
    (setq header-line-format
          (pcase state
            ('starting "Starting…   C-c C-k closes without cancelling the request")
            ('invalid "Correct the fields, then C-c C-c start   C-c C-k close")
            ('started "Started   C-c C-a attach   C-c C-k close")
            ((or 'rejected 'uncertain) "Launch result below — not retried   C-c C-k close")
            (_ "C-c C-c start   C-c C-k close")))
    (save-excursion
      (unless (markerp agent-fleet-start--result-marker)
        (setq agent-fleet-start--result-marker (copy-marker (point-max))))
      (goto-char agent-fleet-start--result-marker)
      (delete-region (point) (point-max))
      (insert (propertize (format "%s\n" (pcase state
                                           ('starting "Starting") ('started "Started") ('invalid "Invalid input")
                                           ('rejected "Rejected") ('uncertain "Outcome unknown")
                                           (_ "Ready")))
                          'face (pcase state ('started 'success) ((or 'invalid 'rejected) 'error)
                                       ('uncertain 'warning) (_ 'bold))))
      (insert
       (pcase state
         ('starting "Waiting for Core. This form cannot submit twice.\n")
         ('invalid (concat (error-message-string result) "\nCorrect the fields before submitting.\n"))
         ('started (format "%s [%s]\nC-c C-a attaches to this agent.\n"
                           (agent-fleet-name result) (plist-get result :address)))
         ('rejected (concat (herdr-core-error-message result) "\nOpen a new start form to correct the request.\n"))
         ('uncertain (concat (error-message-string result)
                             "\nInspect the Dashboard before considering another launch.\n"))
         (_ "Review the fields, then press C-c C-c to start.\n")))
      (when (and first (not (eq (plist-get first :sent) t)))
        (insert (propertize (format "Initial task was NOT sent: %s\n"
                                    (plist-get first :reason)) 'face 'warning)
                "The agent was started. Open Prompt to submit the task explicitly.\n")))))

(defun agent-fleet-start--finish (buffer record err)
  "Retain RECORD or ERR in launch BUFFER without taking focus."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (null err) (not (herdr-core--valid-terminal-p record)))
        (setq err (list 'herdr-core-uncertain :reason 'invalid-launch-response :response record)))
      (setq agent-fleet-operation-result (or err record)
            agent-fleet-operation-state
            (cond ((null err) 'started)
                  ((eq (car err) 'herdr-core-request-error) 'rejected)
                  (t 'uncertain))
            buffer-read-only t)
      (unless err (setq agent-fleet-target (agent-fleet-reference record)))
      (agent-fleet-start--render-result))))

(defun agent-fleet--start-form-attach ()
  "Attach to this form's acknowledged agent, without launching again."
  (interactive)
  (unless (and (eq agent-fleet-operation-state 'started) agent-fleet-target)
    (user-error "This form has no acknowledged agent to attach"))
  (agent-fleet-attach agent-fleet-target))

(defun agent-fleet--start-form-submit ()
  "Submit this start form once, retaining the eventual result in place."
  (interactive)
  (unless (memq agent-fleet-operation-state '(nil invalid))
    (user-error "Launch already requested; inspect Dashboard before starting again"))
  (pcase-let* ((`(,command ,cwd ,name ,task)
               (mapcar #'widget-value agent-fleet--start-fields))
              (choices (agent-fleet--commands))
              (argv (or (cdr (assoc command choices)) (split-string-and-unquote command))))
    (let ((buffer (current-buffer)))
      (unless argv (user-error "Provide a command"))
      (unless (and (not (file-remote-p cwd)) (file-directory-p cwd))
        (user-error "Select an existing local working directory"))
      (setq agent-fleet-operation-state 'starting buffer-read-only t)
      (agent-fleet-start--render-result)
      (condition-case err
          (agent-fleet-start
           argv :cwd cwd :name (unless (string-empty-p name) name)
           :task (unless (string-empty-p task) task)
           :callback (lambda (record error) (agent-fleet-start--finish buffer record error)))
        ((error quit)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (eq agent-fleet-operation-state 'starting)
               (if (eq (car err) 'user-error)
                   ;; `agent-fleet-start' raises user-error only during local
                   ;; preflight; Core rejections arrive through its callback.
                   (progn (setq agent-fleet-operation-state 'invalid
                                agent-fleet-operation-result err buffer-read-only nil)
                          (agent-fleet-start--render-result))
                 (agent-fleet-start--finish buffer nil err)))))
         (signal (car err) (cdr err)))))))
(provide 'agent-fleet-start)
;;; agent-fleet-start.el ends here
