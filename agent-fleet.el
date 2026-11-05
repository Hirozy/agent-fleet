;;; agent-fleet.el --- Coding agents through herdr-core -*- lexical-binding: t; -*-
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Identity, selection and agent operations shared by all Fleet interfaces.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pp)
(require 'herdr-core)
(require 'agent-fleet-display)
(defgroup agent-fleet nil "Coding agents in Emacs." :group 'tools)
(defcustom agent-fleet-commands '("claude" "codex" "pi")
  "Commands offered alongside Core templates." :type '(repeat string) :group 'agent-fleet)
(defvar agent-fleet--last-command nil)
(defvar-local agent-fleet-target nil "Pinned identity for this view.")
(defvar-local agent-fleet-target-function nil
  "Optional function resolving the target at point in a Fleet view.")
(defvar-local agent-fleet-presentation-function nil
  "Optional function calling a presentation thunk at this view's origin.")
(defvar-local agent-fleet-operation-state nil)
(defvar-local agent-fleet-operation-result nil)
(declare-function agent-fleet-project-root-for-cwd "agent-fleet-project" (cwd))
(declare-function agent-fleet-dashboard-focus "agent-fleet-dashboard" (address))
(autoload 'agent-fleet "agent-fleet-dashboard" nil t)
(autoload 'agent-fleet-attach "agent-fleet-attach" nil t)
(autoload 'agent-fleet-cleanup "agent-fleet-cleanup" nil t)
(autoload 'agent-fleet-start-for-project "agent-fleet-project" nil t)
(autoload 'agent-fleet-prompt-dwim "agent-fleet-project" nil t)
(autoload 'agent-fleet-magit-status "agent-fleet-magit" nil t)
(autoload 'agent-fleet-magit-diff "agent-fleet-magit" nil t)
(autoload 'agent-fleet-start-form "agent-fleet-start" nil t)
(autoload 'agent-fleet-start-minibuffer "agent-fleet-start" nil t)
(autoload 'agent-fleet-start-worktree "agent-fleet-worktree" nil t)
(autoload 'agent-fleet-start-batch "agent-fleet-batch" nil t)
(autoload 'agent-fleet-observe "agent-fleet-attach" nil t)
(autoload 'agent-fleet-details "agent-fleet-details" nil t)
(autoload 'agent-fleet-start-remote "agent-fleet-remote" nil t)
(autoload 'agent-fleet-send-file "agent-fleet-remote" nil t)
(declare-function agent-fleet-remote-start-options "agent-fleet-remote" (machine cwd))
(declare-function evil-make-overriding-map "evil-core" (keymap &optional state copy))

(defun agent-fleet-protect-keymap (map)
  "Keep MAP's Fleet commands accessible when optional Evil is active."
  (with-eval-after-load 'evil
    (evil-make-overriding-map map)))

(defun agent-fleet-call-with-presentation (function)
  "Call presentation FUNCTION through the current view's origin handler."
  (cond ((agent-fleet-display-window-active-p)
         (agent-fleet-display-window-call function))
        (agent-fleet-presentation-function
         (funcall agent-fleet-presentation-function function))
        (t (funcall function))))

(defun agent-fleet-label (terminal key)
  "Read label KEY from TERMINAL."
  (plist-get (plist-get terminal :labels) (intern (concat ":" key))))

(defun agent-fleet-managed-p (terminal &optional seen)
  "Return whether TERMINAL belongs to Fleet, following parents through SEEN."
  (let ((address (plist-get terminal :address)))
    (unless (member address seen)
      (or (equal (agent-fleet-label terminal "fleet.role") "agent")
          (when-let* ((parent (herdr-core-terminal (plist-get terminal :parent))))
            (agent-fleet-managed-p parent (cons address seen)))))))

(defun agent-fleet-agents (&optional all)
  "Return Fleet members, including finished records when ALL."
  (cl-remove-if-not
   (lambda (r) (and (agent-fleet-managed-p r)
                    (or all (equal (plist-get r :state) "live"))))
   (herdr-core-terminals)))

(defun agent-fleet-name (terminal)
  "Return TERMINAL's display name."
  (or (agent-fleet-label terminal "fleet.name")
      (plist-get terminal :name) (plist-get terminal :address)))

(defun agent-fleet-status (terminal)
  "Return TERMINAL's reported work status without guessing."
  (or (plist-get (plist-get terminal :status) :state) "unreported"))

(defun agent-fleet-type (terminal)
  "Return TERMINAL's reported app or launch executable name.
This does not infer work status.
Use only path text, including for remote commands; never resolve it locally."
  (let ((app (plist-get (plist-get terminal :status) :app))
        (command (car (append (plist-get terminal :argv) nil))))
    (cond ((and (stringp app) (not (string-blank-p app))) app)
          ((and (stringp command) (not (string-blank-p command)))
           (or (car (last (split-string command "/" t))) "—"))
          (t "—"))))

(defun agent-fleet-reference (terminal)
  "Pin TERMINAL to its Core identity and creation time."
  (list :fleet-identity (herdr-core-identity terminal)))

(defun agent-fleet-resolve (target &optional fresh)
  "Resolve TARGET, checking pinned identity; FRESH queries Core."
  (herdr-core-connect)
  (let* ((identity (and (listp target) (plist-get target :fleet-identity)))
         (address (if identity (herdr-core-identity-address identity) target))
         (cached (and (stringp address) (herdr-core-terminal address))))
    (unless cached (user-error "Terminal unavailable: %s" address))
    (when (and identity (not (equal identity (herdr-core-identity cached))))
      (user-error "Terminal identity changed; reopen this view"))
    (if (not fresh) cached
      (let ((record (herdr-core-request "terminal.get" (list :terminal address))))
        (unless (and (herdr-core--valid-terminal-p record)
                     (equal (herdr-core-identity cached) (herdr-core-identity record)))
          (user-error "Terminal identity changed during operation"))
        record))))

(defun agent-fleet--read-target (records prompt)
  "Select from RECORDS with PROMPT, retaining identity from before selection."
  (let ((choices
         (mapcar
          (lambda (r)
            (let ((pinned (condition-case err
                              (list :reference (agent-fleet-reference r))
                            (error (list :error err)))))
              (cons (format "%s [%s]  %s / %s%s"
                            (agent-fleet-name r) (plist-get r :address)
                            (plist-get r :state) (agent-fleet-status r)
                            (if (plist-get pinned :error) " (unavailable)" ""))
                    pinned))) records)))
    (unless choices (user-error "No terminals available"))
    (let ((selected (cdr (assoc (completing-read prompt choices nil t) choices))))
      (unless selected (user-error "Select a terminal"))
      (when-let* ((err (plist-get selected :error))) (signal (car err) (cdr err)))
      (plist-get selected :reference))))

(defun agent-fleet-read-agent (&optional prompt all)
  "Read a pinned agent identity with PROMPT; include history when ALL."
  (herdr-core-connect)
  (let ((records (agent-fleet-agents all)))
    (unless records (user-error "No Fleet agents; start one or use agent-fleet-adopt"))
    (agent-fleet--read-target records (or prompt "Agent: "))))

(defun agent-fleet-current-target (&optional all)
  "Return this view's target, or ask for an agent, including history with ALL."
  (or agent-fleet-target
      (and agent-fleet-target-function (funcall agent-fleet-target-function))
      (agent-fleet-read-agent nil all)))

(defun agent-fleet--name (cwd &optional remote)
  "Generate a Core-compatible unique name from CWD."
  (require 'agent-fleet-project)
  (let* ((case-fold-search nil)
         (root (or (and (not remote) (agent-fleet-project-root-for-cwd cwd)) cwd))
         (base (replace-regexp-in-string
                "[^a-z0-9_-]+" "-"
                (downcase (file-name-nondirectory (directory-file-name root)))))
         (base (replace-regexp-in-string "\\`[^a-z0-9]+" "" base))
         (base (if (string-empty-p base) "agent" (substring base 0 (min 24 (length base)))))
         ;; Guard after truncation, which can itself leave an ID-shaped name.
         (base (if (string-match-p "\\`t[0-9][a-z0-9]*\\'" base)
                   (concat "agent-" (substring base 0 (min 18 (length base)))) base))
         (names (mapcar (lambda (r) (plist-get r :name)) (herdr-core-terminals)))
         (name base) (n 1))
    (while (member name names)
      (let ((suffix (format "-%d" (cl-incf n))))
        (setq name (concat (substring base 0 (min (length base) (- 32 (length suffix)))) suffix))))
    name))

(defun agent-fleet--commands ()
  "Return choices pairing labels with literal argv lists."
  (append
   (mapcar (lambda (template)
             (cons (concat "template: " (plist-get template :name))
                   (list (plist-get template :name))))
           (plist-get (herdr-core-request "templates.list") :templates))
   (mapcar (lambda (command) (cons command (split-string-and-unquote command)))
           agent-fleet-commands)))

(defun agent-fleet--read-command ()
  "Read a template or literal command, retaining spaces in its arguments."
  (let ((choices (agent-fleet--commands))
        (minibuffer-local-completion-map (copy-keymap minibuffer-local-completion-map)))
    ;; Space normally requests word completion in this minibuffer map.
    (define-key minibuffer-local-completion-map (kbd "SPC") #'self-insert-command)
    (let* ((choice (completing-read "Template or command: " choices nil nil nil nil
                                    (or agent-fleet--last-command (car agent-fleet-commands)
                                        (caar choices))))
           (argv (or (cdr (assoc choice choices)) (split-string-and-unquote choice))))
      (unless argv (user-error "Provide a command"))
      (setq agent-fleet--last-command choice)
      argv)))

(defun agent-fleet--start-interactive ()
  "Read ordinary start options."
  (herdr-core-connect)
  (require 'agent-fleet-project)
  (if current-prefix-arg (list nil :configure t)
    (let* ((argv (agent-fleet--read-command))
           (cwd (read-directory-name "Working directory: "
                                     (or (agent-fleet-project-root-for-cwd default-directory)
                                         default-directory) nil t)))
      (list argv :cwd cwd))))

;;;###autoload
(cl-defun agent-fleet-start (argv &key (cwd default-directory) name task configure display
                                labels callback machine)
  "Start agent ARGV in CWD, optionally named NAME.
TASK is an initial task for a Core template; CONFIGURE opens a start form.
DISPLAY opens the Dashboard, as interactive calls do.
LABELS adds string-valued Core labels; Fleet ownership cannot be overridden.
CALLBACK receives (RECORD ERROR) once the launch request completes.
MACHINE is a permanent remote Core ID; CWD then names a directory there.
Return an asynchronous request ID.  An unsent first message never kills
a successfully started terminal."
  (interactive (agent-fleet--start-interactive))
  (if configure (agent-fleet-start-form)
    (herdr-core-connect)
    (unless (and argv (cl-every #'stringp argv)) (user-error "Provide a command"))
    (unless (or machine (and (not (file-remote-p cwd)) (file-directory-p cwd)))
      (user-error "Select an existing local working directory"))
    (when (and task machine)
      (user-error "Remote template tasks must be explicit template argv"))
    (when (and task
               (not (member (car argv)
                            (mapcar (lambda (r) (plist-get r :name))
                                    (plist-get (herdr-core-request "templates.list") :templates)))))
      (user-error "Initial task requires a Core template"))
    (let* ((remote (when machine
                     (require 'agent-fleet-remote)
                     (agent-fleet-remote-start-options machine cwd)))
           (cwd (if machine cwd (file-truename cwd)))
           (name (or name (agent-fleet--name (or (plist-get remote :name-base) cwd) machine)))
           (labels (append (plist-get remote :labels) labels))
           (params (list :argv (vconcat argv (and task (list task))) :cwd cwd :name name
                         :no_parent t :wait :false :keep :false :rm :false
                         :labels (plist-put (copy-sequence labels) :fleet.role "agent"))))
      (when remote (setq params (plist-put params :on (plist-get remote :on))))
      (when (or display (called-interactively-p 'interactive)) (agent-fleet))
      (message "Starting %s…" name)
      (herdr-core-request-async
       "terminal.run" params
       (lambda (record err)
         (when (and (null err) (not (herdr-core--valid-terminal-p record)))
           (setq err (list 'herdr-core-uncertain :reason 'invalid-launch-response :response record)))
         (if err (message "Start %s: %s (not retried)" name (herdr-core-error-message err))
           (let ((first (plist-get record :first_message)))
             (message "Started %s [%s]%s" name (plist-get record :address)
                      (if (and first (not (eq (plist-get first :sent) t)))
                          (format "; first task NOT sent: %s" (plist-get first :reason)) "")))
           (when (fboundp 'agent-fleet-dashboard-focus)
             (agent-fleet-dashboard-focus (plist-get record :address))))
         (when callback (funcall callback record err))) 90))))

;;;###autoload
(defun agent-fleet-adopt (target)
  "Explicitly include terminal TARGET as a Fleet agent.
TARGET may be an address or a pinned identity; interactive selection pins it."
  (interactive
   (progn (herdr-core-connect)
          (list (agent-fleet--read-target (herdr-core-terminals) "Include terminal: "))))
  (let ((record (agent-fleet-resolve target t)))
    (herdr-core-request "terminal.label"
                       (list :terminal (plist-get record :address) :labels '(:fleet.role "agent")))))

(defun agent-fleet-present-buffer (buffer)
  "Present BUFFER without resizing an attached terminal."
  (agent-fleet-call-with-presentation
   (lambda ()
     (let ((origin (agent-fleet-display-origin-frame)))
       (cond
        ((agent-fleet-display-window-active-p)
         (agent-fleet-display-window-open buffer))
        ((and (bound-and-true-p agent-fleet-attach-mode)
              (agent-fleet-display-child-frame-available-p origin))
           (agent-fleet-display-aux-run-at-origin
            origin (lambda () (switch-to-buffer buffer)
                     (agent-fleet-display-make-outcome t buffer buffer))))
        (t (switch-to-buffer buffer nil t)))
       buffer))))

(defvar agent-fleet-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'agent-fleet-view-quit)
    (define-key map (kbd "C-g") #'agent-fleet-view-quit) map))
(agent-fleet-protect-keymap agent-fleet-review-mode-map)
(define-derived-mode agent-fleet-review-mode special-mode "Fleet Review"
  "Read-only Fleet output and review."
  (setq-local truncate-lines nil))

(defun agent-fleet-view-quit ()
  "Close a view, preserving its origin and terminal client."
  (interactive)
  (cond ((agent-fleet-display-window-quit))
        ((frame-parameter nil 'agent-fleet-auxiliary-frame)
         (agent-fleet-display-close-auxiliary-frame (selected-frame)))
        (t (quit-window))))

(defun agent-fleet-view-buffer (mode reference name)
  "Reuse a MODE view pinned to REFERENCE, or create a buffer named NAME."
  (or (cl-find-if (lambda (buffer)
                    (with-current-buffer buffer
                      (and (derived-mode-p mode) (equal agent-fleet-target reference))))
                  (buffer-list))
      (generate-new-buffer name)))

(define-derived-mode agent-fleet-output-mode agent-fleet-review-mode "Fleet Output"
  "Read a refreshable, identity-pinned output snapshot."
  (setq-local revert-buffer-function #'agent-fleet--output-revert
              header-line-format "g refresh snapshot   q / C-g close"))

(defun agent-fleet--output-render (record result)
  "Replace this snapshot with RECORD's output RESULT, retaining point."
  (let ((inhibit-read-only t) (point-before (point)))
    (erase-buffer)
    (insert (propertize (concat (agent-fleet-name record) "\n") 'face 'bold))
    (insert (format "Snapshot: %s%s\n\n" (plist-get result :how)
                    (if (eq (plist-get result :complete) t) "" " (incomplete)")))
    (insert (or (plist-get result :text) ""))
    (goto-char (min point-before (point-max)))
    (set-buffer-modified-p nil)))

(defun agent-fleet--output-revert (&optional _ignore-auto _noconfirm)
  "Refresh this view's pinned target; preserve the snapshot on failure."
  (let* ((record (agent-fleet-resolve agent-fleet-target t))
         (result (herdr-core-request "terminal.read"
                                    (list :terminal (plist-get record :address) :lines 200))))
    (agent-fleet--output-render record result)))

;;;###autoload
(defun agent-fleet-show-output (target)
  "Read a finite output snapshot for TARGET."
  (interactive (list (agent-fleet-current-target)))
  (let* ((record (agent-fleet-resolve target t))
         (result (herdr-core-request "terminal.read"
                                    (list :terminal (plist-get record :address) :lines 200)))
         (reference (agent-fleet-reference record))
         (buffer (agent-fleet-view-buffer 'agent-fleet-output-mode reference
                                          (format "*Fleet Output: %s*" (plist-get record :address)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-fleet-output-mode) (agent-fleet-output-mode))
      (agent-fleet--output-render record result)
      (setq-local agent-fleet-target reference))
    (agent-fleet-present-buffer buffer)))

(defvar agent-fleet-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'agent-fleet-prompt-submit)
    (define-key map (kbd "C-c C-k") #'agent-fleet-view-quit) map))
(defvar-local agent-fleet-prompt--status-overlay nil)
(defvar-local agent-fleet-prompt--recipient nil)
(define-derived-mode agent-fleet-prompt-mode text-mode "Fleet Prompt"
  "Compose an explicit agent message."
  (setq-local truncate-lines nil
              header-line-format "C-c C-c send   C-c C-k close"))

(defun agent-fleet-prompt--render-status ()
  "Display status separately from the exact text of this draft."
  (let* ((state agent-fleet-operation-state)
         (result agent-fleet-operation-result)
         (title (pcase state ('sent "Submitted") ('sending "Sending")
                       ('rejected "Rejected") ('uncertain "Outcome unknown") (_ "Draft")))
         (face (pcase state ('sent 'success) ('rejected 'error)
                      ('uncertain 'warning) (_ 'font-lock-keyword-face)))
         (detail
          (pcase state
            ('sending "Waiting for Core. Closing this view does not cancel delivery.")
            ('sent (format "Core acknowledged turn %s. Work completion is not confirmed."
                           (plist-get result :turn)))
            ('rejected (concat (herdr-core-error-message result)
                               "\nDraft retained. Inspect the target before creating another prompt."))
            ('uncertain (concat (herdr-core-error-message result)
                                "\nDelivery may have happened. Inspect the agent before sending again.")))))
    (setq header-line-format
          (if (eq state 'draft) "C-c C-c send   C-c C-k close"
            (concat title "   C-c C-k close")))
    (unless (overlayp agent-fleet-prompt--status-overlay)
      (setq agent-fleet-prompt--status-overlay (make-overlay (point-min) (point-min))))
    (overlay-put agent-fleet-prompt--status-overlay 'before-string
                 (concat (propertize (concat "To: " (or agent-fleet-prompt--recipient "agent") "\n\n")
                                     'face 'bold)
                         (propertize (concat title "\n") 'face face)
                         (when detail (concat detail "\n\nPrompt text\n"))
                         "\n"))))

(defun agent-fleet-prompt--finish (buffer result err)
  "Retain RESULT or ERR in prompt BUFFER without changing its text or focus."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (null err) (not (herdr-core--valid-send-result-p result)))
        (setq err (list 'herdr-core-uncertain :reason 'invalid-send-response :response result)))
      (setq agent-fleet-operation-result (or err result)
            agent-fleet-operation-state
            (cond ((null err) 'sent)
                  ((eq (car err) 'herdr-core-request-error) 'rejected)
                  (t 'uncertain))
            buffer-read-only t)
      (agent-fleet-prompt--render-status))))

;;;###autoload
(defun agent-fleet-prompt (target &optional initial-text)
  "Compose a message to TARGET, optionally containing INITIAL-TEXT."
  (interactive (list (agent-fleet-current-target)))
  (let* ((record (agent-fleet-resolve target))
         (buffer (generate-new-buffer (format "*Fleet Prompt: %s*" (agent-fleet-name record)))))
    (with-current-buffer buffer
      (agent-fleet-prompt-mode)
      (setq-local agent-fleet-target (agent-fleet-reference record))
      (setq-local agent-fleet-operation-state 'draft)
      (setq-local agent-fleet-prompt--recipient
                  (format "%s [%s]" (agent-fleet-name record) (plist-get record :address)))
      (insert (or initial-text ""))
      (agent-fleet-prompt--render-status))
    (agent-fleet-present-buffer buffer)))

(defun agent-fleet-prompt-submit ()
  "Submit this draft once, retaining uncertain outcomes for inspection."
  (interactive)
  (unless (eq agent-fleet-operation-state 'draft)
    (user-error "Draft is %s; create a new prompt to send again" agent-fleet-operation-state))
  (let* ((record (agent-fleet-resolve agent-fleet-target t))
         (text (buffer-substring-no-properties (point-min) (point-max)))
         (buffer (current-buffer)))
    (when (string-empty-p (string-trim text)) (user-error "Empty prompt"))
    (setq agent-fleet-operation-state 'sending buffer-read-only t)
    (agent-fleet-prompt--render-status)
    (condition-case err
        (herdr-core-request-async
         "terminal.send" (list :terminal (plist-get record :address) :text text :force :false)
         (lambda (result err) (agent-fleet-prompt--finish buffer result err)) 210)
      ((error quit)
       (when (and (buffer-live-p buffer)
                  (eq (buffer-local-value 'agent-fleet-operation-state buffer) 'sending))
         (agent-fleet-prompt--finish buffer nil err))
       (signal (car err) (cdr err))))))

(defvar agent-fleet--control-results nil
  "The latest 30 control outcomes, including original responses and errors.")

(defun agent-fleet--control-summary (action record result)
  "Summarize ACTION's RESULT for RECORD, or return nil for an invalid reply."
  (when (listp result)
    (pcase action
      ('end
       (when (and (herdr-core--valid-terminal-p result)
                  (equal (plist-get result :address) (plist-get record :address))
                  (equal (plist-get result :created_ms) (plist-get record :created_ms)))
         (if (equal (plist-get result :state) "finished")
             (format "Ended%s"
                     (if (integerp (plist-get result :exit_code))
                         (format " (exit code %s)" (plist-get result :exit_code)) ""))
           "End requested; Core still reports live")))
      ('interrupt
       (when (and (stringp (plist-get result :key))
                  (stringp (plist-get result :outcome)))
         (format "Interrupt: %s"
                 (pcase (plist-get result :outcome)
                   ("stopped" "work stopped") ("exited" "program exited")
                   ("still_working" "still working")
                   ("unknown" "stop key sent; effect unknown")
                   (other (format "Core reported %s" other))))))
      ('wait
       (when (and (equal (plist-get result :terminal) (plist-get record :address))
                  (memq (plist-get result :ended) '(t :false))
                  (stringp (plist-get result :reason)))
         (format "Wait: %s%s"
                 (pcase (plist-get result :reason)
                   ("timeout" "timed out") ("not_started" "work did not start")
                   ("exit" "program exited") ("message" "message received")
                   ("output" "output matched") ("status" "status reported")
                   (other (format "Core reported %s" other)))
                 (if (stringp (plist-get result :status))
                     (format " (%s)" (plist-get result :status)) "")))))))

(defun agent-fleet--remember-control-result (action reference result err summary)
  "Retain ACTION's original RESULT and ERR with REFERENCE and SUMMARY."
  (push (list :time (current-time-string) :action action :target reference
              :summary summary :response result :error err)
        agent-fleet--control-results)
  (when (> (length agent-fleet--control-results) 30)
    (setcdr (nthcdr 29 agent-fleet--control-results) nil)))

(defun agent-fleet--control-finish (action record reference result err)
  "Report and retain a control outcome without moving focus or retrying."
  (let ((summary (and (null err) (agent-fleet--control-summary action record result))))
    (unless (or err summary)
      (setq err (list 'herdr-core-uncertain :reason 'invalid-control-response
                      :response result)))
    (when err
      (setq summary
            (format "%s %s: %s (not retried; M-x agent-fleet-control-results)"
                    (capitalize (symbol-name action))
                    (if (eq (car-safe err) 'herdr-core-request-error) "rejected" "outcome unknown")
                    (if (eq (car-safe err) 'herdr-core-uncertain)
                        (format "%s" (or (plist-get (cdr err) :reason) "connection lost"))
                      (herdr-core-error-message err)))))
    (setq summary (format "%s [%s] — %s" (agent-fleet-name record)
                          (plist-get record :address) summary))
    (agent-fleet--remember-control-result action reference result err summary)
    (message "%s" summary)))

(defun agent-fleet--control-request (action record &optional timeout)
  "Dispatch ACTION once for RECORD, retaining its result; use TIMEOUT seconds."
  (let ((reference (agent-fleet-reference record))
        (params (list :terminal (plist-get record :address))) completed)
    (when (eq action 'wait) (setq params (append params '(:timeout 180))))
    (condition-case err
        (herdr-core-request-async
         (pcase action ('end "terminal.kill") ('interrupt "terminal.interrupt")
                ('wait "terminal.wait"))
         params
         (lambda (result err)
           (unless completed
             (setq completed t)
             (agent-fleet--control-finish action record reference result err))) timeout)
      ((error quit)
       (unless completed
         (setq completed t)
         (agent-fleet--control-finish action record reference nil err))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun agent-fleet-control-results ()
  "Review recent launch and control outcomes with original diagnostics."
  (interactive)
  (let ((buffer (get-buffer-create "*Fleet Control Results*")))
    (with-current-buffer buffer
      (agent-fleet-review-mode)
      (setq-local header-line-format "Recent control results   q / C-g return")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Recent control results\n\n" 'face 'bold))
        (unless agent-fleet--control-results (insert "No control results in this Emacs session.\n"))
        (dolist (entry agent-fleet--control-results)
          (insert (propertize (concat (plist-get entry :summary) "\n")
                              'face (if (plist-get entry :error) 'warning 'bold))
                  (plist-get entry :time) "\n"
                  (pp-to-string (list :target (plist-get entry :target)
                                      :response (plist-get entry :response)
                                      :error (plist-get entry :error))) "\n"))
        (goto-char (point-min))))
    (agent-fleet-present-buffer buffer)))

;;;###autoload
(defun agent-fleet-wait (target)
  "Wait asynchronously for TARGET, reporting Core's actual reason."
  (interactive (list (agent-fleet-current-target)))
  (agent-fleet--control-request 'wait (agent-fleet-resolve target t) 190))

;;;###autoload
(defun agent-fleet-interrupt (target)
  "Request interruption of TARGET's current work."
  (interactive (list (agent-fleet-current-target)))
  (agent-fleet--control-request 'interrupt (agent-fleet-resolve target t)))

(defun agent-fleet-kill-impact (address terminals)
  "Return live descendants that die with ADDRESS in TERMINALS."
  (let ((seen (list address)) (queue (list address)) result)
    (while queue
      (let ((parent (pop queue)))
        (dolist (record terminals)
          (when (and (equal parent (plist-get record :parent))
                     (eq t (plist-get record :die_with_parent))
                     (equal "live" (plist-get record :state))
                     (not (member (plist-get record :address) seen)))
            (push (plist-get record :address) seen)
            (push (plist-get record :address) queue)
            (push record result)))))
    result))

;;;###autoload
(defun agent-fleet-kill (target)
  "End TARGET after reviewing the current descendant impact."
  (interactive (list (agent-fleet-current-target)))
  (let* ((record (agent-fleet-resolve target t))
         (reference (agent-fleet-reference record))
         (address (plist-get record :address))
         (terminals (plist-get (herdr-core-request "terminal.list" '(:all t)) :terminals))
         (impact (agent-fleet-kill-impact address terminals)))
    (unless (equal (plist-get record :state) "live") (user-error "Already finished"))
    (when (yes-or-no-p
           (format "End %s [%s]%s? Core also ends dependent descendants, including any created meanwhile. "
                   (agent-fleet-name record) address
                   (if impact (format " and %s" (mapconcat #'agent-fleet-name impact ", ")) "")))
      (agent-fleet--control-request 'end (agent-fleet-resolve reference t)))))

;;;###autoload (autoload 'agent-fleet-command-map "agent-fleet" nil t 'keymap)
(defvar agent-fleet-command-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("a" . agent-fleet) ("n" . agent-fleet-start)
                       ("N" . agent-fleet-start-for-project) ("p" . agent-fleet-prompt)
                       ("P" . agent-fleet-prompt-dwim) ("RET" . agent-fleet-attach)
                       ("o" . agent-fleet-show-output) ("i" . agent-fleet-details)
                       ("c" . agent-fleet-cleanup) ("k" . agent-fleet-kill)
                       ("s" . agent-fleet-interrupt) ("m" . agent-fleet-magit-status)
                       ("d" . agent-fleet-magit-diff) ("+" . agent-fleet-adopt)))
      (define-key map (kbd (car binding)) (cdr binding)))
    (define-key map (kbd "w") #'agent-fleet-start-worktree)
    (define-key map (kbd "b") #'agent-fleet-start-batch)
    (define-key map (kbd "v") #'agent-fleet-observe)
    (define-key map (kbd "r") #'agent-fleet-start-remote)
    (define-key map (kbd "f") #'agent-fleet-send-file)
    map))
(fset 'agent-fleet-command-map agent-fleet-command-map)
(provide 'agent-fleet)
;;; agent-fleet.el ends here
