;;; agent-fleet.el --- Coding agents through herdr-core -*- lexical-binding: t; -*-
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Identity, selection and agent operations shared by all Fleet interfaces.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
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
(autoload 'agent-fleet-start-worktree "agent-fleet-worktree" nil t)
(autoload 'agent-fleet-start-batch "agent-fleet-batch" nil t)
(autoload 'agent-fleet-observe "agent-fleet-attach" nil t)
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
  (if agent-fleet-presentation-function
      (funcall agent-fleet-presentation-function function)
    (funcall function)))

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

(defun agent-fleet-read-agent (&optional prompt all)
  "Read an address with PROMPT; include history when ALL."
  (herdr-core-connect)
  (let ((choices (mapcar
                  (lambda (r) (cons (format "%s [%s]  %s / %s"
                                            (agent-fleet-name r) (plist-get r :address)
                                            (plist-get r :state) (agent-fleet-status r))
                                    (plist-get r :address)))
                  (agent-fleet-agents all))))
    (unless choices (user-error "No Fleet agents; start one or use agent-fleet-adopt"))
    (cdr (assoc (completing-read (or prompt "Agent: ") choices nil t) choices))))

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

(defun agent-fleet--start-interactive ()
  "Read ordinary start options."
  (herdr-core-connect)
  (require 'agent-fleet-project)
  (if current-prefix-arg (list nil :configure t)
    (let* ((choices (agent-fleet--commands))
           (choice (completing-read "Template or command: " choices nil nil nil nil
                                    agent-fleet--last-command))
           (cwd (read-directory-name "Working directory: "
                                     (or (agent-fleet-project-root-for-cwd default-directory)
                                         default-directory) nil t)))
      (setq agent-fleet--last-command choice)
      (list (or (cdr (assoc choice choices)) (split-string-and-unquote choice)) :cwd cwd))))

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
         (if err (message "Start %s: %s (not retried)" name (error-message-string err))
           (let ((first (plist-get record :first_message)))
             (message "Started %s [%s]%s" name (plist-get record :address)
                      (if (and first (not (eq (plist-get first :sent) t)))
                          (format "; first task NOT sent: %s" (plist-get first :reason)) "")))
           (when (fboundp 'agent-fleet-dashboard-focus)
             (agent-fleet-dashboard-focus (plist-get record :address))))
         (when callback (funcall callback record err))) 90))))

;;;###autoload
(defun agent-fleet-adopt (address)
  "Explicitly include external terminal ADDRESS as a Fleet agent."
  (interactive
   (progn (herdr-core-connect)
          (list (completing-read "Include terminal: "
                                 (mapcar (lambda (r) (plist-get r :address))
                                         (herdr-core-terminals)) nil t))))
  (let ((record (agent-fleet-resolve address t)))
    (herdr-core-request "terminal.label"
                       (list :terminal (plist-get record :address) :labels '(:fleet.role "agent")))))

(defun agent-fleet-present-buffer (buffer)
  "Present BUFFER without resizing an attached terminal."
  (agent-fleet-call-with-presentation
   (lambda ()
     (let ((origin (agent-fleet-display-origin-frame)))
       (if (and (bound-and-true-p agent-fleet-attach-mode)
                (agent-fleet-display-child-frame-available-p origin))
           (agent-fleet-display-aux-run-at-origin
            origin (lambda () (switch-to-buffer buffer)
                     (agent-fleet-display-make-outcome t buffer buffer)))
         (switch-to-buffer buffer))
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
  (if (frame-parameter nil 'agent-fleet-auxiliary-frame)
      (agent-fleet-display-close-auxiliary-frame (selected-frame))
    (quit-window)))

;;;###autoload
(defun agent-fleet-show-output (target)
  "Read a finite output snapshot for TARGET."
  (interactive (list (agent-fleet-current-target)))
  (let* ((record (agent-fleet-resolve target t))
         (result (herdr-core-request "terminal.read"
                                    (list :terminal (plist-get record :address) :lines 200)))
         (buffer (get-buffer-create (format "*Fleet Output: %s*" (plist-get record :address)))))
    (with-current-buffer buffer
      (agent-fleet-review-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (concat (agent-fleet-name record) "\n") 'face 'bold))
        (insert (format "Snapshot: %s%s\n\n" (plist-get result :how)
                        (if (eq (plist-get result :complete) t) "" " (incomplete)")))
        (insert (or (plist-get result :text) "")))
      (setq-local agent-fleet-target (agent-fleet-reference record)))
    (agent-fleet-present-buffer buffer)))

(defvar agent-fleet-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'agent-fleet-prompt-submit)
    (define-key map (kbd "C-c C-k") #'agent-fleet-view-quit) map))
(define-derived-mode agent-fleet-prompt-mode text-mode "Fleet Prompt"
  "Compose an explicit agent message."
  (setq-local header-line-format "C-c C-c send   C-c C-k close"))

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
      (insert (or initial-text "")))
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
    (setq agent-fleet-operation-state 'sending buffer-read-only t
          header-line-format "Sending… (closing this buffer does not cancel delivery)")
    (herdr-core-request-async
     "terminal.send" (list :terminal (plist-get record :address) :text text :force :false)
     (lambda (result err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq agent-fleet-operation-result (or err result)
                 agent-fleet-operation-state
                 (cond ((null err) 'sent)
                       ((eq (car err) 'herdr-core-request-error) 'rejected)
                       (t 'uncertain)))
           (setq header-line-format
                 (format "%s — %s" agent-fleet-operation-state
                         (if err (error-message-string err)
                           "submitted; this does not mean the turn is done")))))) 210)))

;;;###autoload
(defun agent-fleet-wait (target)
  "Wait asynchronously for TARGET, reporting Core's actual reason."
  (interactive (list (agent-fleet-current-target)))
  (let ((record (agent-fleet-resolve target t)))
    (herdr-core-request-async
     "terminal.wait" (list :terminal (plist-get record :address) :timeout 180)
     (lambda (result err) (message "Agent wait: %s" (or err result))) 190)))

;;;###autoload
(defun agent-fleet-interrupt (target)
  "Request interruption of TARGET's current work."
  (interactive (list (agent-fleet-current-target)))
  (let ((record (agent-fleet-resolve target t)))
    (herdr-core-request-async
     "terminal.interrupt" (list :terminal (plist-get record :address))
     (lambda (result err) (message "Agent interrupt: %s" (or err result))))))

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
      (agent-fleet-resolve reference t)
      (herdr-core-request-async
       "terminal.kill" (list :terminal address)
       (lambda (result err) (message "Agent end: %s" (or err result)))))))

;;;###autoload
(defun agent-fleet-details (target)
  "Show TARGET's identity, state and Core parent relationship."
  (interactive (list (agent-fleet-current-target t)))
  (let* ((record (agent-fleet-resolve target t))
         (buffer (get-buffer-create "*Fleet Details*")))
    (with-current-buffer buffer
      (agent-fleet-review-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (concat (agent-fleet-name record) "\n\n") 'face 'bold))
        (dolist (key '(:address :template :cwd :state :status :parent :die_with_parent
                      :keep :reason :first_message :labels))
          (insert (propertize (format "%s: " key) 'face 'font-lock-keyword-face)
                  (format "%S\n" (plist-get record key)))))
      (setq-local agent-fleet-target (agent-fleet-reference record)))
    (agent-fleet-present-buffer buffer)))

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
