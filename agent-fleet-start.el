;;; agent-fleet-start.el --- Advanced start form -*- lexical-binding: t; -*-
;;; Commentary:
;; One editable form for local agent launch options.
;;; Code:
(require 'agent-fleet)
(require 'wid-edit)
(require 'button)
(defvar-local agent-fleet--start-fields nil)
(defvar-local agent-fleet-start--result-marker nil)
(defvar-local agent-fleet-start--attach-after-start nil)
(defvar-local agent-fleet-start--attach-error nil)

(defface agent-fleet-start-heading
  '((t (:inherit bold :height 1.2)))
  "Title of the agent launch form."
  :group 'agent-fleet)

(defun agent-fleet-start--button (label command)
  "Insert a labeled action for COMMAND, usable by keyboard or mouse."
  (insert-text-button label 'follow-link t
                      'action (lambda (_button) (call-interactively command)))
  (insert "  "))

(defun agent-fleet-start--editable-p ()
  "Refuse to edit a request that has already been dispatched."
  (unless (memq agent-fleet-operation-state '(nil invalid))
    (user-error "Request already submitted; inspect its result first")))

(defun agent-fleet-start--set-command (command)
  "Select COMMAND in the editable form."
  (agent-fleet-start--editable-p)
  (widget-value-set (car agent-fleet--start-fields) command)
  (setq agent-fleet--last-command command)
  (goto-char (widget-field-start (car agent-fleet--start-fields))))

(defun agent-fleet-start--choose-command ()
  "Choose a command or Core template with completion."
  (interactive)
  (agent-fleet-start--editable-p)
  (herdr-core-connect)
  (agent-fleet--read-command)
  (agent-fleet-start--set-command agent-fleet--last-command))

(defun agent-fleet-start--choose-directory ()
  "Choose the working directory with normal directory completion."
  (interactive)
  (agent-fleet-start--editable-p)
  (let* ((field (nth 1 agent-fleet--start-fields))
         (directory (read-directory-name "Working directory: " (widget-value field) nil t)))
    (widget-value-set field directory)
    (goto-char (widget-field-start field))))

(defun agent-fleet-start--edit-rejected ()
  "Explicitly unlock a definitely rejected request, retaining its fields."
  (interactive)
  (unless (eq agent-fleet-operation-state 'rejected)
    (user-error "Only a definitely rejected request can be edited"))
  (setq agent-fleet-operation-state nil agent-fleet-operation-result nil
        agent-fleet-start--attach-after-start nil buffer-read-only nil)
  (agent-fleet-start--render-result)
  (goto-char (widget-field-start (car agent-fleet--start-fields))))

(defun agent-fleet-start--keymap (parent)
  "Copy widget PARENT and keep launch/close available inside its fields."
  (let ((map (copy-keymap parent)))
    (define-key map (kbd "C-c C-c") #'agent-fleet--start-form-submit)
    (define-key map (kbd "C-c C-k") #'agent-fleet-view-quit)
    (define-key map (kbd "C-c C-a") #'agent-fleet--start-form-attach)
    (define-key map (kbd "C-c C-p") #'agent-fleet-start--choose-command)
    (define-key map (kbd "C-c C-d") #'agent-fleet-start--choose-directory)
    (define-key map (kbd "C-c C-e") #'agent-fleet-start--edit-rejected)
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
      (setq-local default-directory cwd)
      (insert (propertize "New agent\n" 'face 'agent-fleet-start-heading)
              (propertize "Choose an agent and where it should work.\n\n" 'face 'shadow))
      (dolist (command agent-fleet-commands)
        (let ((choice command))
          (insert-text-button command 'follow-link t
                              'action (lambda (_button) (agent-fleet-start--set-command choice)))
          (insert "  ")))
      (agent-fleet-start--button "Choose command / template…" #'agent-fleet-start--choose-command)
      (insert "\n\n")
      (let ((field-map (agent-fleet-start--keymap widget-field-keymap))
            (text-map (agent-fleet-start--keymap
                       (widget-get (widget-convert 'text) :keymap))))
        (setq agent-fleet--start-fields
              (list (widget-create 'editable-field :keymap field-map
                                   :format "Agent command  %v\n"
                                   (or agent-fleet--last-command (car agent-fleet-commands) ""))
                    (prog1 (widget-create 'directory :keymap field-map :format "Directory      %v\n" cwd)
                      (agent-fleet-start--button "Browse directory…" #'agent-fleet-start--choose-directory)
                      (insert "\n\n" (propertize "Optional settings\n" 'face 'bold)
                              (propertize "Leave the name empty to use the Project or directory name.\n" 'face 'shadow)))
                    (widget-create 'editable-field :keymap field-map :format "Name           %v\n" "")
                    (progn
                      (insert (propertize "\nInitial task — Core templates only; otherwise send a prompt after launch.\n" 'face 'shadow))
                      (widget-create 'text :keymap text-map :format "%v\n" "")))))
      (goto-char (point-max))
      (insert "\n")
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
            ('invalid "Correct fields   C-c C-a start & attach   C-c C-c background   C-c C-k back")
            ('started "Started   C-c C-a attach   C-c C-k close")
            ('rejected "C-c C-e edit request   C-c C-k back")
            ('uncertain "Outcome unknown — inspect Dashboard   C-c C-k back")
            (_ "C-c C-a start & attach   C-c C-c background   C-c C-k back")))
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
         ('rejected (concat (herdr-core-error-message result) "\nEdit the request to correct it; nothing is retried automatically.\n"))
         ('uncertain (concat (error-message-string result)
                             "\nInspect the Dashboard before considering another launch.\n"))
         (_ "Start here and enter the terminal, or leave the agent running in the background.\n")))
      (when (and first (not (eq (plist-get first :sent) t)))
        (insert (propertize (format "Initial task was NOT sent: %s\n"
                                    (plist-get first :reason)) 'face 'warning)
                "The agent was started. Open Prompt to submit the task explicitly.\n"))
      (when agent-fleet-start--attach-error
        (insert (propertize (concat "Attach failed: " (error-message-string agent-fleet-start--attach-error)
                                    "\nThe agent is started; retry Attach when ready.\n") 'face 'warning)))
      (insert "\n")
      (pcase state
        ((or 'nil 'invalid)
         (agent-fleet-start--button "Start & attach" #'agent-fleet--start-form-attach)
         (agent-fleet-start--button "Start in background" #'agent-fleet--start-form-submit))
        ('started (agent-fleet-start--button "Attach" #'agent-fleet--start-form-attach))
        ('rejected (agent-fleet-start--button "Edit request" #'agent-fleet-start--edit-rejected)))
      (agent-fleet-start--button "Back" #'agent-fleet-view-quit)
      (insert "\n"))))

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
      (agent-fleet-start--render-result)
      (when (and (null err) agent-fleet-start--attach-after-start
                 (eq (window-buffer (selected-window)) buffer)
                 (or (not (display-graphic-p)) (frame-focus-state))
                 (not (and (plist-get record :first_message)
                           (not (eq (plist-get (plist-get record :first_message) :sent) t)))))
        (condition-case attach-error
            (agent-fleet--start-form-attach)
          ((error quit)
           (with-current-buffer buffer
             (setq agent-fleet-start--attach-error attach-error)
             (agent-fleet-start--render-result))))))))

(defun agent-fleet--start-form-attach ()
  "Start and attach, or attach to this form's already acknowledged agent."
  (interactive)
  (if (memq agent-fleet-operation-state '(nil invalid))
      (agent-fleet--start-form-submit t)
    (unless (and (eq agent-fleet-operation-state 'started) agent-fleet-target)
      (user-error "This form has no acknowledged agent to attach"))
    (agent-fleet-attach agent-fleet-target)))

(defun agent-fleet--start-form-submit (&optional attach)
  "Submit this start form once, retaining the eventual result in place."
  (interactive)
  (unless (memq agent-fleet-operation-state '(nil invalid))
    (user-error "Launch already requested; inspect Dashboard before starting again"))
  (pcase-let* ((`(,command ,cwd ,name ,task)
               (mapcar #'widget-value agent-fleet--start-fields))
              (choices (agent-fleet--commands))
              (argv (or (cdr (assoc command choices)) (split-string-and-unquote command))))
    (let ((buffer (current-buffer)))
      (condition-case err
          (progn
            (unless argv (user-error "Provide a command"))
            (unless (and (not (file-remote-p cwd)) (file-directory-p cwd))
              (user-error "Select an existing local working directory")))
        (user-error
         (setq agent-fleet-operation-state 'invalid agent-fleet-operation-result err)
         (agent-fleet-start--render-result)
         (signal (car err) (cdr err))))
      (setq agent-fleet-start--attach-after-start attach
            agent-fleet--last-command command
            agent-fleet-operation-state 'starting buffer-read-only t)
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
