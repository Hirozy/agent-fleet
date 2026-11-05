;;; agent-fleet-dashboard.el --- Agent overview -*- lexical-binding: t; -*-
;;; Commentary:
;; One event-driven view of Fleet members and Core connectivity.
;;; Code:
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'tabulated-list)
(require 'hl-line)
(require 'transient)
(require 'button)
(defcustom agent-fleet-notify-on '("blocked" "error" "done")
  "Reported states announced in the echo area."
  :type '(repeat string) :group 'agent-fleet)
(defvar-local agent-fleet-dashboard--history nil)
(defvar-local agent-fleet-dashboard--project nil)
(defvar-local agent-fleet-dashboard--attention nil)
(defvar-local agent-fleet-dashboard--pending-focus nil)
(defvar-local agent-fleet-dashboard--summary "")
(defvar-local agent-fleet-dashboard--projects nil)
(defvar-local agent-fleet-dashboard--last-project nil)
(defvar-local agent-fleet-dashboard--focus-project nil)
(defvar-local agent-fleet-dashboard--selected-id nil)
(defconst agent-fleet-dashboard--columns
  [("Agent" 22 nil) ("Type" 10 nil) ("State" 22 nil) ("Address" 10 nil)
   ("Role" 7 nil) ("Parent" 8 nil)])

(defun agent-fleet-dashboard--state-cell (r)
  "Return a styled state cell for R."
  (let* ((work (agent-fleet-status r))
         (text (if (equal (plist-get r :state) "finished")
                   (format "finished (%s)" (or (plist-get r :exit_code) (plist-get r :reason) "—"))
                 (if (plist-get r :reason) (format "recovering: %s" (plist-get r :reason)) work))))
    (propertize text 'face (cond ((member work '("blocked" "error")) 'warning)
                                 ((equal work "done") 'success) (t 'default)))))

(defun agent-fleet-dashboard--group-label (project)
  "Return an unambiguous heading for canonical PROJECT."
  (cond ((null project) "— No Project")
        ((stringp project) project)
        (t (format "%s (remote %s)" (nth 2 project) (nth 1 project)))))

(defun agent-fleet-dashboard--priority (record)
  "Return a presentation priority for RECORD without changing its status."
  (if (equal (plist-get record :state) "finished") 5
    (or (cl-position (agent-fleet-status record) '("blocked" "error" "working" "idle" "done")
                     :test #'equal) 6)))

(defun agent-fleet-dashboard--less-p (a b)
  "Sort records A and B by Project, work status, name and address."
  (let ((pa (gethash (plist-get a :address) agent-fleet-dashboard--projects))
        (pb (gethash (plist-get b :address) agent-fleet-dashboard--projects)))
    (if (equal pa pb)
        (let ((sa (agent-fleet-dashboard--priority a)) (sb (agent-fleet-dashboard--priority b)))
          (if (/= sa sb) (< sa sb)
            (if (equal (agent-fleet-name a) (agent-fleet-name b))
                (string< (plist-get a :address) (plist-get b :address))
              (string< (agent-fleet-name a) (agent-fleet-name b)))))
      (cond ((and pa (equal pa agent-fleet-dashboard--focus-project)) t)
            ((and pb (equal pb agent-fleet-dashboard--focus-project)) nil)
            ((null pa) nil) ((null pb) t)
            (t (string< (prin1-to-string pa) (prin1-to-string pb)))))))

(defun agent-fleet-dashboard--print-entry (id columns)
  "Print a Project heading when needed, then the agent ID and COLUMNS."
  (let ((project (gethash id agent-fleet-dashboard--projects)))
    (unless (equal project agent-fleet-dashboard--last-project)
      (insert (propertize (concat "\n" (agent-fleet-dashboard--group-label project) "\n")
                          'face 'font-lock-keyword-face))
      (setq agent-fleet-dashboard--last-project project))
    (tabulated-list-print-entry id columns)))

(defun agent-fleet-dashboard-refresh ()
  "Render the current cache without polling Core."
  (interactive)
  (when-let* ((buffer (get-buffer "*Agent Fleet*")))
    (with-current-buffer buffer
      (unless (equal (mapcar #'car (append tabulated-list-format nil))
                     (mapcar #'car (append agent-fleet-dashboard--columns nil)))
        (setq tabulated-list-format (copy-tree agent-fleet-dashboard--columns t))
        (tabulated-list-init-header))
      (let ((id (tabulated-list-get-id))
            (pending agent-fleet-dashboard--pending-focus)
            (members (agent-fleet-agents agent-fleet-dashboard--history)))
        (setq agent-fleet-dashboard--projects (make-hash-table :test 'equal))
        (dolist (record members)
          (puthash (plist-get record :address) (agent-fleet-project-for-agent record)
                   agent-fleet-dashboard--projects))
        (setq members (sort members #'agent-fleet-dashboard--less-p))
        (setq tabulated-list-entries
              (mapcar
               (lambda (r)
                 (list (plist-get r :address)
                       (vector (agent-fleet-name r)
                               (agent-fleet-type r)
                               (agent-fleet-dashboard--state-cell r)
                               (plist-get r :address)
                               (if (equal (agent-fleet-label r "fleet.role") "agent") "agent" "helper")
                               (or (plist-get r :parent) "—"))))
               (cl-remove-if-not
                (lambda (r)
                  (and (or (not agent-fleet-dashboard--project)
                           (equal agent-fleet-dashboard--project (agent-fleet-project-for-agent r)))
                       (or (not agent-fleet-dashboard--attention)
                           (member (agent-fleet-status r) '("blocked" "error")))))
                members)))
        (setq agent-fleet-dashboard--summary
              (format "Core: %s   %s %d/%d%s   h commands   Project: %s"
                      herdr-core--state (if agent-fleet-dashboard--history "All records" "Live")
                      (length tabulated-list-entries) (length members)
                      (if agent-fleet-dashboard--attention "   Attention only" "")
                      (if agent-fleet-dashboard--project
                          (propertize
                           (truncate-string-to-width
                            (agent-fleet-project--display-name agent-fleet-dashboard--project) 20 nil nil "…")
                           'help-echo (agent-fleet-dashboard--group-label agent-fleet-dashboard--project))
                        "All")))
        (setq agent-fleet-dashboard--last-project :unprinted
              tabulated-list-sort-key nil)
        (tabulated-list-print t)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-min))
            (insert (propertize "Agent Fleet" 'face 'bold) "    ")
            (dolist (action '(("New agent [N]" . agent-fleet-dashboard-start)
                              ("Commands [h]" . agent-fleet-dashboard-help)))
              (let ((command (cdr action)))
                (insert-text-button (car action) 'follow-link t
                                    'action (lambda (_button)
                                              (agent-fleet-dashboard--goto agent-fleet-dashboard--selected-id)
                                              (call-interactively command)))
                (insert "   ")))
            (insert (propertize "\nRET / a attach   s prompt   n/p move   q back\n" 'face 'shadow))))
        (let ((focused (agent-fleet-dashboard--goto pending)))
          (when (or focused (and pending (herdr-core-terminal pending)))
            (setq agent-fleet-dashboard--pending-focus nil))
          (unless (or focused (agent-fleet-dashboard--goto id) (tabulated-list-get-id))
            (unless (agent-fleet-dashboard--goto (caar tabulated-list-entries))
              (goto-char (point-min)))))
        (unless tabulated-list-entries
          (let ((inhibit-read-only t))
            (insert (propertize
                     (if (or agent-fleet-dashboard--project agent-fleet-dashboard--attention)
                         (concat "No agents match the current filters. "
                                 (when agent-fleet-dashboard--project "P clears the Project filter. ")
                                 (when agent-fleet-dashboard--attention "! clears the attention filter. ")
                                 "H toggles history.\n")
                       "No Fleet agents in this view. Press N to start an agent, or H to toggle history.\n")
                     'face 'shadow))
            (goto-char (point-min)))))
      (agent-fleet-dashboard--remember-selection)
      (set-buffer-modified-p nil)
      (when (bound-and-true-p hl-line-mode) (hl-line-highlight)))))

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

(defun agent-fleet-dashboard--remember-selection ()
  "Keep the last selected row available when clicking a toolbar action."
  (when-let* ((id (tabulated-list-get-id)))
    (setq agent-fleet-dashboard--selected-id id)))

(defun agent-fleet-dashboard-focus (address)
  "Move an existing Dashboard to ADDRESS without stealing focus."
  (when-let* ((buffer (get-buffer "*Agent Fleet*")))
    (with-current-buffer buffer
      (setq agent-fleet-dashboard--pending-focus
            (unless (or (agent-fleet-dashboard--goto address) (herdr-core-terminal address))
              address)))))

(defun agent-fleet-dashboard--target ()
  "Return a pinned target for the current row."
  (if (and (eq transient-current-command 'agent-fleet-dashboard-help)
           transient-current-prefix)
      (or (plist-get (oref transient-current-prefix scope) :target)
          (user-error "No agent was selected when the menu opened"))
    (let ((id (tabulated-list-get-id)))
      (unless id (user-error "No agent on this row"))
      (agent-fleet-reference (agent-fleet-resolve id)))))

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
(defun agent-fleet-dashboard-start ()
  "Open a launch form using the selected local agent's working directory."
  (interactive)
  (let* ((record (when (tabulated-list-get-id)
                   (agent-fleet-resolve (agent-fleet-dashboard--target))))
         (cwd (and record (not (string-match-p "/" (plist-get record :address)))
                   (plist-get record :cwd)))
         (default-directory (if (and cwd (not (file-remote-p cwd)) (file-directory-p cwd))
                                (file-name-as-directory cwd) default-directory)))
    (agent-fleet-dashboard--visit #'agent-fleet-start-form)))
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

(defun agent-fleet-dashboard--move (direction)
  "Move DIRECTION rows, skipping Project headings and blank lines."
  (let ((start (point)) found)
    (while (and (not found) (= 0 (forward-line direction)))
      (when (tabulated-list-get-id) (setq found t)))
    (unless found (goto-char start))))

;;;###autoload
(defun agent-fleet-dashboard-next ()
  "Select the next agent row."
  (interactive)
  (agent-fleet-dashboard--move 1))

;;;###autoload
(defun agent-fleet-dashboard-previous ()
  "Select the previous agent row."
  (interactive)
  (agent-fleet-dashboard--move -1))

;;;###autoload (autoload 'agent-fleet-dashboard-help "agent-fleet-dashboard" nil t)
(transient-define-prefix agent-fleet-dashboard-help ()
  "Show commands for the current Dashboard."
  [["Session"
    ("N" "New agent" agent-fleet-dashboard-start)
    ("a" "Attach" agent-fleet-dashboard-attach)
    ("v" "Observe" agent-fleet-dashboard-observe)
    ("q" "Return from Dashboard" agent-fleet-dashboard-quit)]
   ["Agent"
    ("s" "Prompt" agent-fleet-dashboard-prompt)
    ("o" "Output" agent-fleet-dashboard-output)
    ("I" "Details" agent-fleet-dashboard-details)
    ("i" "Interrupt" agent-fleet-dashboard-interrupt)
    ("x" "End program" agent-fleet-dashboard-kill)]
   ["Review / View"
    ("m" "Magit status" agent-fleet-dashboard-magit)
    ("d" "Diff" agent-fleet-dashboard-diff)
    ("c" "Cleanup review" agent-fleet-dashboard-cleanup)
    ("P" "Project filter" agent-fleet-dashboard-project)
    ("!" "Attention filter" agent-fleet-dashboard-attention)
    ("H" "Finished history" agent-fleet-dashboard-history)
    ("g" "Refresh" agent-fleet-dashboard-refresh)]]
  (interactive)
  (unless (derived-mode-p 'agent-fleet-mode) (user-error "Open Dashboard first"))
  (transient-setup 'agent-fleet-dashboard-help nil nil
                   :scope (list :target (when (tabulated-list-get-id)
                                          (agent-fleet-dashboard--target)))))

(defvar agent-fleet-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map))
;; Reinstall on reload as well: older maps bound navigation keys to actions.
(dolist (pair '(("a" . agent-fleet-dashboard-attach) ("RET" . agent-fleet-dashboard-attach)
                ("v" . agent-fleet-dashboard-observe) ("s" . agent-fleet-dashboard-prompt)
                ("o" . agent-fleet-dashboard-output) ("I" . agent-fleet-dashboard-details)
                ("m" . agent-fleet-dashboard-magit) ("d" . agent-fleet-dashboard-diff)
                ("c" . agent-fleet-dashboard-cleanup) ("N" . agent-fleet-dashboard-start)
                ("x" . agent-fleet-dashboard-kill) ("i" . agent-fleet-dashboard-interrupt)
                ("h" . agent-fleet-dashboard-help) ("H" . agent-fleet-dashboard-history)
                ("P" . agent-fleet-dashboard-project) ("!" . agent-fleet-dashboard-attention)
                ("g" . agent-fleet-dashboard-refresh) ("q" . agent-fleet-dashboard-quit)
                ("C-g" . agent-fleet-dashboard-quit) ("<escape>" . agent-fleet-dashboard-quit)
                ("n" . agent-fleet-dashboard-next) ("j" . agent-fleet-dashboard-next)
                ("<down>" . agent-fleet-dashboard-next) ("C-n" . agent-fleet-dashboard-next)
                ("p" . agent-fleet-dashboard-previous) ("k" . agent-fleet-dashboard-previous)
                ("<up>" . agent-fleet-dashboard-previous) ("C-p" . agent-fleet-dashboard-previous)))
  (define-key agent-fleet-mode-map (kbd (car pair)) (cdr pair)))
(agent-fleet-protect-keymap agent-fleet-mode-map)
(define-derived-mode agent-fleet-mode tabulated-list-mode "Agent Fleet"
  "Live agent overview."
  (setq-local agent-fleet-target-function #'agent-fleet-dashboard--target)
  (setq-local agent-fleet-presentation-function #'agent-fleet-dashboard--visit)
  (setq tabulated-list-format (copy-tree agent-fleet-dashboard--columns t))
  (setq tabulated-list-padding 1
        agent-fleet-dashboard--projects (make-hash-table :test 'equal)
        agent-fleet-dashboard--last-project :unprinted
        tabulated-list-printer #'agent-fleet-dashboard--print-entry
        mode-line-process '(:eval (concat "  " agent-fleet-dashboard--summary)))
  (tabulated-list-init-header)
  (add-hook 'post-command-hook #'agent-fleet-dashboard--remember-selection nil t)
  (hl-line-mode 1))

;;;###autoload
(defun agent-fleet ()
  "Open Dashboard in the current window, retaining its previous view."
  (interactive)
  (herdr-core-connect)
  (let ((buffer (get-buffer-create "*Agent Fleet*"))
        (child (and (frame-parameter nil 'agent-fleet-auxiliary-frame) (selected-frame)))
        (previous (current-buffer))
        (origin-directory default-directory)
        (project (unless (derived-mode-p 'agent-fleet-mode)
                   (if agent-fleet-target
                       (condition-case nil
                           (agent-fleet-project-for-agent (agent-fleet-resolve agent-fleet-target))
                         (error nil))
                     (agent-fleet-project-root-for-cwd default-directory)))))

    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-fleet-mode) (agent-fleet-mode))
      (unless (eq previous buffer)
        (setq agent-fleet-dashboard--focus-project project
              default-directory origin-directory)))
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
