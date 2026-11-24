;;; agent-fleet-dashboard.el --- Agent overview -*- lexical-binding: t; -*-
;;; Commentary:
;; One event-driven view of Fleet members and Core connectivity.
;;; Code:
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'tabulated-list)
(require 'hl-line)
(require 'transient)
(defcustom agent-fleet-notify-on '("blocked" "error" "done")
  "Reported states announced in the echo area."
  :type '(repeat string) :group 'agent-fleet)
(defvar-local agent-fleet-dashboard--history nil)
(defvar-local agent-fleet-dashboard--all-local nil)
(defvar-local agent-fleet-dashboard--owner nil)
(defvar-local agent-fleet-dashboard--project nil)
(defvar-local agent-fleet-dashboard--attention nil)
(defvar-local agent-fleet-dashboard--pending-focus nil)
(defvar-local agent-fleet-dashboard--summary "")
(defvar-local agent-fleet-dashboard--projects nil)
(defvar-local agent-fleet-dashboard--last-project nil)
(defvar-local agent-fleet-dashboard--focus-project nil)
(defvar-local agent-fleet-dashboard--project-labels nil)
(defvar-local agent-fleet-dashboard--notes nil)
(defvar-local agent-fleet-dashboard--checkout-headings nil)
(defvar-local agent-fleet-dashboard--group-counts nil)
(defvar-local agent-fleet-dashboard--layout-width nil)
(defconst agent-fleet-dashboard--columns
  [("Agent" 32 nil) ("Type" 14 nil) ("Status" 18 nil) ("ID" 6 nil)])
(defvar-local agent-fleet-dashboard--full-format nil)

(defun agent-fleet-dashboard--available-width ()
  "Return the narrowest visible Dashboard width, or the opening window's width."
  (let ((windows (get-buffer-window-list (current-buffer) nil 'visible)))
    (if windows (apply #'min (mapcar #'window-body-width windows))
      (window-body-width (if (window-live-p agent-fleet-dashboard--owner)
                             agent-fleet-dashboard--owner (selected-window))))))

(defun agent-fleet-dashboard--fit-columns ()
  "Hide the ID column before shortening agent names."
  (let* ((width (agent-fleet-dashboard--available-width))
         (format (or agent-fleet-dashboard--full-format
                     (setq agent-fleet-dashboard--full-format
                           (copy-tree agent-fleet-dashboard--columns t))))
         (type-width (cadr (aref format 1)))
         (status-width (cadr (aref format 2)))
         (id-width (cadr (aref format 3)))
         (longest-name (length "Agent"))
         (longest-status (length "Status")))
    (dolist (entry tabulated-list-entries)
      (setq longest-name (max longest-name (string-width (aref (cadr entry) 0)))
            longest-status (max longest-status (string-width (aref (cadr entry) 2)))
            id-width (max id-width (string-width (aref (cadr entry) 3)))))
    (let* ((room (- width tabulated-list-padding type-width))
           (wide-room (- room status-width id-width 3))
           (wide (>= wide-room longest-name))
           (name-width (max 1 (min (max 32 longest-name)
                                   (if wide wide-room
                                     (- room (min longest-status status-width) 2))))))
      (setq agent-fleet-dashboard--layout-width width)
      (unless (and (= (length tabulated-list-format) (if wide 4 3))
                   (= (cadr (aref tabulated-list-format 0)) name-width))
        (setf (cadr (aref format 0)) name-width)
        (setq tabulated-list-format (if wide format (seq-take format 3)))
        (tabulated-list-init-header)))))

(defun agent-fleet-dashboard--resize (window)
  "Refit Dashboard text after WINDOW changes size, without changing its layout."
  (with-current-buffer (window-buffer window)
    (when (and (derived-mode-p 'agent-fleet-mode)
               (not (equal agent-fleet-dashboard--layout-width
                           (agent-fleet-dashboard--available-width))))
      (agent-fleet-dashboard-refresh))))

(defun agent-fleet-dashboard--state-cell (record)
  "Style RECORD's runtime outcome or current work status for Dashboard."
  (let ((reason (plist-get record :reason))
        (code (plist-get record :exit_code)))
    (cond
     ((equal (plist-get record :state) "finished")
      (let ((label (format "finished (%s)" (or code reason "—"))))
        (if (and (integerp code) (/= code 0))
            (propertize (concat "× " label) 'face 'error)
          (propertize label 'face 'shadow))))
     (reason (propertize (format "! recovering: %s" reason) 'face 'warning))
     (t (pcase (agent-fleet-status record)
          ("blocked" (propertize "! blocked" 'face '(bold warning)))
          ("error"   (propertize "× error" 'face '(bold error)))
          ("working" (propertize "▶ working" 'face 'font-lock-keyword-face))
          ("done"    (propertize "✓ done" 'face 'success))
          ("idle"    (propertize "○ idle" 'face 'shadow))
          ("unreported" (propertize "unreported" 'face 'shadow))
          (other other))))))

(defun agent-fleet-dashboard--group-label (project)
  "Return an unambiguous heading for canonical PROJECT."
  (or (and agent-fleet-dashboard--project-labels
           (gethash project agent-fleet-dashboard--project-labels))
      (if project (agent-fleet-project--display-name project) "— No Project")))

(defun agent-fleet-dashboard--priority (record)
  "Return a presentation priority for RECORD without changing its status."
  (if (equal (plist-get record :state) "finished") 5
    (or (cl-position (agent-fleet-status record) '("blocked" "error" "working" "idle" "done")
                     :test #'equal) 6)))

(defun agent-fleet-dashboard--less-p (a b contexts)
  "Order A and B by Project, checkout, status, name and address using CONTEXTS."
  (let* ((ia (plist-get a :address)) (ib (plist-get b :address))
         (pa (gethash ia agent-fleet-dashboard--projects))
         (pb (gethash ib agent-fleet-dashboard--projects))
         (ca (plist-get (gethash ia contexts) :checkout)) (cb (plist-get (gethash ib contexts) :checkout)))
    (cond
     ((not (equal pa pb))
      (cond ((null pa) nil) ((null pb) t)
            ((equal pa agent-fleet-dashboard--focus-project) t)
            ((equal pb agent-fleet-dashboard--focus-project) nil)
            (t (string< pa pb))))
     ((not (equal ca cb))
      (cond ((equal ca pa) t) ((equal cb pb) nil) (t (string< ca cb))))
     ((/= (agent-fleet-dashboard--priority a) (agent-fleet-dashboard--priority b))
      (< (agent-fleet-dashboard--priority a) (agent-fleet-dashboard--priority b)))
     ((equal (agent-fleet-name a) (agent-fleet-name b)) (string< ia ib))
     (t (string< (agent-fleet-name a) (agent-fleet-name b))))))

(defun agent-fleet-dashboard--print-entry (id columns)
  "Print a Project heading when needed, then the agent ID and COLUMNS."
  (let ((project (gethash id agent-fleet-dashboard--projects)))
    (unless (equal project agent-fleet-dashboard--last-project)
      (let ((count (gethash project agent-fleet-dashboard--group-counts 0)))
        (unless (bobp) (insert "\n"))
        (insert (propertize (agent-fleet-dashboard--group-label project)
                            'face '(bold font-lock-keyword-face)
                            'help-echo (agent-fleet-project--full-label project))
                (propertize (format " · %d %s%s" count
                                    (if agent-fleet-dashboard--all-local "terminal" "agent")
                                    (if (= count 1) "" "s")) 'face 'shadow))
        (when project
          (let ((remaining (- (agent-fleet-dashboard--available-width) (current-column) 2)))
            (if (>= remaining 16) (insert "  ")
              (insert "\n  ")
              (setq remaining (- (agent-fleet-dashboard--available-width) 2)))
            (insert (agent-fleet-project--path-label project (max 1 remaining)))))
        (insert "\n"))
      (setq agent-fleet-dashboard--last-project project))
    (when-let* ((heading (gethash id agent-fleet-dashboard--checkout-headings)))
      (insert "  " heading "\n"))
    (tabulated-list-print-entry id columns)
    (when-let* ((note (and agent-fleet-dashboard--notes
                          (gethash id agent-fleet-dashboard--notes))))
      (let ((begin (point)))
        (insert "    " note "\n")
        (add-text-properties begin (point) (list 'tabulated-list-id id 'tabulated-list-entry columns))))))

(defun agent-fleet-dashboard--entries (members)
  "Build agent rows and headings from the visible subset of MEMBERS."
  (let ((contexts (make-hash-table :test 'equal))
        (by-project (make-hash-table :test 'equal))
        (width (agent-fleet-dashboard--available-width))
        visible entries last-checkout)
    (setq agent-fleet-dashboard--projects (make-hash-table :test 'equal)
          agent-fleet-dashboard--group-counts (make-hash-table :test 'equal)
          agent-fleet-dashboard--checkout-headings (make-hash-table :test 'equal)
          agent-fleet-dashboard--notes (make-hash-table :test 'equal))
    (dolist (r members)
      (let* ((id (plist-get r :address)) (context (agent-fleet-project--agent-context r))
             (project (plist-get context :root)))
        (puthash id project agent-fleet-dashboard--projects)
        (when (and (or (null agent-fleet-dashboard--project) (equal project agent-fleet-dashboard--project))
                   (or (null agent-fleet-dashboard--attention) (member (agent-fleet-status r) '("blocked" "error"))))
          (push r visible)
          (puthash id context contexts)
          (cl-incf (gethash project agent-fleet-dashboard--group-counts 0))
          (when project
            (let ((checkout (plist-get context :checkout)))
              (when (and checkout (not (equal checkout project)))
                (cl-pushnew checkout (gethash project by-project) :test #'equal)))))))
    (setq agent-fleet-dashboard--project-labels
          (agent-fleet-project--short-labels (hash-table-values agent-fleet-dashboard--projects)))
    (maphash (lambda (project paths)
               (puthash project (agent-fleet-project--short-labels paths) by-project))
             by-project)
    (dolist (r (sort visible (lambda (a b) (agent-fleet-dashboard--less-p a b contexts))))
      (let* ((id (plist-get r :address)) (project (gethash id agent-fleet-dashboard--projects))
             (context (gethash id contexts)) (checkout (plist-get context :checkout))
             (labels (gethash project by-project))
             (label (and labels (gethash checkout labels))) (indent (if label "  " ""))
             (external (and agent-fleet-dashboard--all-local (not (agent-fleet-managed-p r))))
             (relationship (when-let* ((parent (plist-get r :parent)))
                             (propertize (format "%s %s"
                                                 (if (or external (equal (agent-fleet-label r "fleet.role") "agent"))
                                                     "Parent:" "Helper of") parent)
                                         'face 'shadow)))
             (directory (agent-fleet-project--directory-note
                         r context (max 1 (- width 4 (length indent)
                                             (if relationship (+ 5 (string-width relationship)) 0))))))
        (when (and label (not (equal last-checkout checkout)))
          (let* ((title (truncate-string-to-width label (max 1 (- width 2)) nil nil "…"))
                 (remaining (- width 2 (string-width title) 2)))
            (puthash id (concat (propertize title 'face 'font-lock-type-face 'help-echo checkout)
                                (when (> remaining 1)
                                  (concat "  " (agent-fleet-project--path-label checkout remaining))))
                     agent-fleet-dashboard--checkout-headings)))
        (setq last-checkout checkout)
        (when (or directory relationship)
          (puthash id (concat indent (string-join (delq nil (list directory relationship)) "  ·  "))
                   agent-fleet-dashboard--notes))
        (push (list (propertize id 'agent-fleet-reference (agent-fleet-reference r))
                    (vector (concat indent (when external (propertize "+ " 'face 'font-lock-keyword-face))
                                    (agent-fleet-name r))
                            (agent-fleet-type r) (agent-fleet-dashboard--state-cell r) id)) entries)))
    (nreverse entries)))

(defun agent-fleet-dashboard-refresh (&optional rediscover)
  "Render the current cache without polling Core.
REDISCOVER, set by interactive refresh, also refreshes Project discovery."
  (interactive (list t))
  (when rediscover (agent-fleet-project--clear-cache))
  (if (derived-mode-p 'agent-fleet-mode)
      (agent-fleet-dashboard--render)
    (agent-fleet-dashboard--refresh-all)))

(defun agent-fleet-dashboard--render ()
  "Render the current Dashboard's filters and selection."
  (let* ((window (and (window-live-p agent-fleet-dashboard--owner)
                      (eq (window-buffer agent-fleet-dashboard--owner) (current-buffer))
                      agent-fleet-dashboard--owner))
         (id (tabulated-list-get-id (if window (window-point window) (point))))
         (pending agent-fleet-dashboard--pending-focus)
         (members (agent-fleet-agents agent-fleet-dashboard--history agent-fleet-dashboard--all-local)))
    (setq tabulated-list-entries (agent-fleet-dashboard--entries members))
    (agent-fleet-dashboard--fit-columns)
    (setq agent-fleet-dashboard--summary
          (format "Core %s  %s%s %d/%d%s  Project: %s  h help"
                  herdr-core--state (if agent-fleet-dashboard--all-local "All local terminals  " "")
                  (if agent-fleet-dashboard--history "All records" "Live")
                  (length tabulated-list-entries) (length members)
                  (if agent-fleet-dashboard--attention "   Attention only" "")
                  (if agent-fleet-dashboard--project
                      (propertize
                       (truncate-string-to-width
                        (agent-fleet-dashboard--group-label agent-fleet-dashboard--project) 30 nil nil "…")
                       'help-echo (agent-fleet-project--full-label agent-fleet-dashboard--project))
                    "All")))
    (setq agent-fleet-dashboard--last-project :unprinted
          tabulated-list-sort-key nil)
    (tabulated-list-print t)
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
                             (when agent-fleet-dashboard--project "/ clears the Project filter. ")
                             (when agent-fleet-dashboard--attention "! clears the attention filter. ")
                             "H toggles history.\n")
                   (if agent-fleet-dashboard--all-local
                       "No local terminals in this view. N starts an agent. H toggles history.\n"
                     "No Fleet agents in this view. A shows all local terminals. N starts an agent. H toggles history.\n"))
                 'face 'shadow))
        (goto-char (point-min))))
    (when window (set-window-point window (point))))
  (set-buffer-modified-p nil)
  (when (bound-and-true-p hl-line-mode) (hl-line-highlight)))

(defun agent-fleet-dashboard--buffers ()
  "Return the existing Dashboard views."
  (seq-filter (lambda (buffer) (eq (buffer-local-value 'major-mode buffer) 'agent-fleet-mode))
              (buffer-list)))

(defun agent-fleet-dashboard--refresh-all ()
  "Apply a Core update to every Dashboard, including hidden review origins."
  (dolist (buffer (agent-fleet-dashboard--buffers))
    (with-current-buffer buffer (agent-fleet-dashboard--render))))

(defun agent-fleet-dashboard--for-window (window &optional create)
  "Find WINDOW's Dashboard, creating or recycling a view when CREATE is set."
  (let ((buffers (agent-fleet-dashboard--buffers)))
    (or (seq-find (lambda (b) (eq window (buffer-local-value 'agent-fleet-dashboard--owner b)))
                  buffers)
        (when create
          (let ((buffer (or (seq-find
                             (lambda (b)
                               (and (not (window-live-p (buffer-local-value 'agent-fleet-dashboard--owner b)))
                                    (not (get-buffer-window b t))))
                             buffers)
                            (generate-new-buffer "*Agent Fleet*"))))
            (with-current-buffer buffer
              (agent-fleet-mode)
              (setq agent-fleet-dashboard--owner window))
            buffer)))))

(defun agent-fleet-dashboard--goto (address)
  "Select visible ADDRESS, returning non-nil; leave point alone if absent."
  (when address
    (when-let* ((position (save-excursion
                           (goto-char (point-min))
                           (while (and (not (eobp)) (not (equal (tabulated-list-get-id) address)))
                             (forward-line 1))
                           (and (not (eobp)) (point)))))
      (goto-char position)
      (when (and (window-live-p agent-fleet-dashboard--owner)
                 (eq (window-buffer agent-fleet-dashboard--owner) (current-buffer)))
        (set-window-point agent-fleet-dashboard--owner position))
      t)))

(defun agent-fleet-dashboard-focus (address &optional window)
  "Move the Dashboard for WINDOW to ADDRESS without stealing focus."
  (when-let* ((buffer (if (and (null window) (derived-mode-p 'agent-fleet-mode))
                          (current-buffer)
                        (agent-fleet-dashboard--for-window (or window (selected-window))))))
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
    (or (agent-fleet-dashboard--row-reference) (user-error "No agent on this row"))))

(defun agent-fleet-dashboard--row-reference ()
  "Return the terminal identity captured when the current row was rendered."
  (when-let* ((id (tabulated-list-get-id)))
    (get-text-property 0 'agent-fleet-reference id)))

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
(defun agent-fleet-dashboard-start (&optional configure)
  "Start through minibuffer prompts, using the selected local directory.
With CONFIGURE, also ask for optional launch settings."
  (interactive "P")
  (let* ((record (when (tabulated-list-get-id)
                   (agent-fleet-resolve (agent-fleet-dashboard--target))))
         (cwd (and record (plist-get record :cwd)))
         (default-directory (if (and cwd (not (file-remote-p cwd)) (file-directory-p cwd))
                                (file-name-as-directory cwd) default-directory)))
    (agent-fleet-start-minibuffer configure)))
(defun agent-fleet-dashboard-kill () "End the current row explicitly."
  (interactive) (agent-fleet-kill (agent-fleet-dashboard--target)))
(defun agent-fleet-dashboard-interrupt () "Interrupt the current row."
  (interactive) (agent-fleet-interrupt (agent-fleet-dashboard--target)))

(defun agent-fleet-dashboard-history ()
  "Toggle finished records."
  (interactive)
  (setq agent-fleet-dashboard--history (not agent-fleet-dashboard--history))
  (agent-fleet-dashboard-refresh))

;;;###autoload
(defun agent-fleet-dashboard-all-local ()
  "Toggle all local Core terminals in this Dashboard."
  (interactive)
  (unless (derived-mode-p 'agent-fleet-mode) (user-error "Open Dashboard first"))
  (setq agent-fleet-dashboard--all-local (not agent-fleet-dashboard--all-local))
  (agent-fleet-dashboard-refresh))

;;;###autoload
(defun agent-fleet-dashboard-adopt ()
  "Include the selected terminal in all-local view, or open the usual picker."
  (interactive)
  (if (not agent-fleet-dashboard--all-local)
      (call-interactively #'agent-fleet-adopt)
    (let* ((target (agent-fleet-dashboard--target))
           (record (agent-fleet-resolve target)))
      (if (agent-fleet-managed-p record)
          (message "%s is already in Fleet" (agent-fleet-name record))
        (agent-fleet-adopt target)
        (message "Included %s [%s] in Fleet" (agent-fleet-name record) (plist-get record :address))))))

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

(defun agent-fleet-dashboard--search-label (record)
  "Format RECORD with the full fields searchable from Dashboard."
  (let* ((id (plist-get record :address))
         (project (gethash id agent-fleet-dashboard--projects)))
    (string-join (delq nil (list (format "%s [%s]" (agent-fleet-name record) id)
                                 (agent-fleet-type record)
                                 (agent-fleet-dashboard--group-label project)
                                 (when-let* ((cwd (plist-get record :cwd)))
                                   (propertize cwd 'face 'shadow))))
                 "  ")))

;;;###autoload
(defun agent-fleet-dashboard-search ()
  "Find an agent in the current Dashboard view and move to its row."
  (interactive)
  (unless (derived-mode-p 'agent-fleet-mode) (user-error "Open Dashboard first"))
  (let ((records (cl-loop for (id) in tabulated-list-entries
                          for record = (herdr-core-terminal id)
                          when record collect record))
        (completion-styles (cons 'substring completion-styles)))
    (unless records (user-error "No agents in this view"))
    (let* ((target (agent-fleet--read-target records "Find agent: "
                                             #'agent-fleet-dashboard--search-label))
           (id (plist-get (agent-fleet-resolve target) :address)))
      (unless (agent-fleet-dashboard--goto id)
        (user-error "Agent %s is no longer in this view" id)))))

(defun agent-fleet-dashboard-quit ()
  "Return to the buffer and position from before Dashboard opened."
  (interactive)
  (agent-fleet-view-quit))

(defun agent-fleet-dashboard--move (direction)
  "Move DIRECTION agents, skipping headings and directory annotations."
  (let ((start (point)) (id (tabulated-list-get-id)) found)
    (while (and (not found) (= 0 (forward-line direction)))
      (when (and (tabulated-list-get-id) (not (equal id (tabulated-list-get-id))))
        (setq found (tabulated-list-get-id))))
    (if found (agent-fleet-dashboard--goto found) (goto-char start))
    ;; Only explicit navigation changes a menu's pinned target.  Cache refreshes
    ;; may move the row but must never redirect the pending user action.
    (when (and (eq transient-current-command 'agent-fleet-dashboard-help)
               transient-current-prefix)
      (oset transient-current-prefix scope
            (list :target (agent-fleet-dashboard--row-reference))))))

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
  :transient-non-suffix 'transient--do-exit
  [["View"
    ("A" "All local terminals" agent-fleet-dashboard-all-local)
    ("C-s" "Find agent" agent-fleet-dashboard-search)
    ("n" "Next agent" agent-fleet-dashboard-next :transient t)
    ("p" "Previous agent" agent-fleet-dashboard-previous :transient t)
    ("/" "Project filter" agent-fleet-dashboard-project)
    ("!" "Attention filter" agent-fleet-dashboard-attention)
    ("H" "Finished history" agent-fleet-dashboard-history)
    ("g" "Refresh" agent-fleet-dashboard-refresh)
    ("q" "Return from Dashboard" agent-fleet-dashboard-quit)]]
  (interactive)
  (unless (derived-mode-p 'agent-fleet-mode) (user-error "Open Dashboard first"))
  (transient-setup 'agent-fleet-dashboard-help nil nil
                   :scope (list :target (when (tabulated-list-get-id)
                                          (agent-fleet-dashboard--target)))))

(dolist (group (reverse agent-fleet--action-groups))
  (transient-insert-suffix 'agent-fleet-dashboard-help '(0 0)
    (vconcat (list (car group))
             (mapcar (lambda (action)
                       (list (car action) (or (nth 4 action) (cadr action))
                             (or (nth 3 action) (nth 2 action))))
                     (cdr group)))))

(defvar agent-fleet-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map))
;; Direct actions and the menu share the same definitions and target semantics.
(dolist (group agent-fleet--action-groups)
  (dolist (action (cdr group))
    (define-key agent-fleet-mode-map (kbd (car action)) (or (nth 3 action) (nth 2 action)))))
(dolist (pair '(("C-s" . agent-fleet-dashboard-search)
                ("A" . agent-fleet-dashboard-all-local)
                ("/" . agent-fleet-dashboard-project) ("!" . agent-fleet-dashboard-attention)
                ("H" . agent-fleet-dashboard-history)))
  (define-key agent-fleet-mode-map (kbd (car pair)) (cdr pair)))
(dolist (pair '(("a" . agent-fleet-dashboard-attach) ("RET" . agent-fleet-dashboard-attach)
                ("h" . agent-fleet-dashboard-help)
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
  (setq-local truncate-string-ellipsis "…")
  (setq agent-fleet-dashboard--full-format (copy-tree agent-fleet-dashboard--columns t)
        tabulated-list-format agent-fleet-dashboard--full-format)
  (setq tabulated-list-padding 2
        agent-fleet-dashboard--projects (make-hash-table :test 'equal)
        agent-fleet-dashboard--checkout-headings (make-hash-table :test 'equal)
        agent-fleet-dashboard--group-counts (make-hash-table :test 'equal)
        agent-fleet-dashboard--last-project :unprinted
        tabulated-list-printer #'agent-fleet-dashboard--print-entry
        mode-line-process '(:eval (concat "  " agent-fleet-dashboard--summary)))
  (tabulated-list-init-header)
  (add-hook 'window-size-change-functions #'agent-fleet-dashboard--resize nil t)
  (hl-line-mode 1))

;;;###autoload
(defun agent-fleet ()
  "Open Dashboard in the current window, retaining its previous view."
  (interactive)
  (herdr-core-connect)
  (let* ((child (and (frame-parameter nil 'agent-fleet-auxiliary-frame) (selected-frame)))
         (window (if child (frame-selected-window (agent-fleet-display-origin-frame child))
                   (selected-window)))
         (buffer (agent-fleet-dashboard--for-window window t))
         (previous (current-buffer))
         (origin-directory default-directory)
         (project (unless (derived-mode-p 'agent-fleet-mode)
                    (if agent-fleet-target
                        (condition-case nil
                            (agent-fleet-project-for-agent (agent-fleet-resolve agent-fleet-target))
                          (error nil))
                      (agent-fleet-project-root-for-cwd default-directory)))))

    (with-current-buffer buffer
      (setq agent-fleet-dashboard--all-local nil)
      (unless (eq previous buffer)
        (setq agent-fleet-dashboard--focus-project project
              default-directory origin-directory))
      (agent-fleet-dashboard-refresh))
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
(remove-hook 'herdr-core-changed-hook #'agent-fleet-dashboard-refresh)
(add-hook 'herdr-core-changed-hook #'agent-fleet-dashboard--refresh-all)
(add-hook 'herdr-core-event-hook #'agent-fleet-dashboard--notify)
(provide 'agent-fleet-dashboard)
;;; agent-fleet-dashboard.el ends here
