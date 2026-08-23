;;; agent-fleet-dashboard.el --- Live agent dashboard over Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The supervisor dashboard (PLAN.md Phase 3, §68).  A `tabulated-list-mode'
;; buffer named *Agent Fleet* that lists every Herdr-managed agent with its
;; project, name, kind, state, and current task, and refreshes itself
;; live from the Phase 2 hook bus.
;;
;; Design rules honored (PLAN.md):
;;   §25  event-driven; NO timer polling.  The buffer rebuilds only when an
;;        `agent-fleet-agent-{started,status-changed,exited}-hook' fires.
;;   §27  columns Project / Agent / Kind / State / Task; row keys
;;        RET p o i k r g P T w d m a (`a' = live attach, Phase 8/§73).
;;   §28  one face per status; blocked is the most prominent.
;;   §29  optional notifications on working→blocked / working→done, gated by
;;        `agent-fleet-notify-on'.
;;   §53  prefix map `agent-fleet-command-map'; NO global key binding — the
;;        user opts in (e.g. (global-set-key (kbd "C-c a") agent-fleet-command-map)).
;;
;; This is a view layer only: it reuses the Phase 2 control commands
;; (`agent-fleet-prompt', `-interrupt', `-kill', `-rename', `-show-output',
;; `-list') and the Phase 1 model accessors, and adds no wire protocol.
;;
;; Task column + filter (Phase 7, §72):
;;   - for an agent in a parallel task, the Task column shows the task title
;;     (the group label clustering its siblings); otherwise the pane's
;;     terminal title (the best live signal of current activity).
;;   - `T' narrows the list to one task's agents — the aggregate-status view;
;;     the task title + live aggregate state then show in the mode line.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'agent-fleet-worktree)
(require 'agent-fleet-magit)
(require 'agent-fleet-parallel)
(require 'agent-fleet-attach)
(require 'herdr-model)


;;; --- Customization --------------------------------------------------

(defcustom agent-fleet-notify-on '(blocked done)
  "Statuses that trigger an agent-fleet notification (PLAN.md §29).
Each is a symbol; the default notifies on `blocked' and `done'.
Set to nil to disable notifications entirely."
  :type '(set (const blocked) (const done))
  :group 'agent-fleet)

(defcustom agent-fleet-dashboard-buffer-name "*Agent Fleet*"
  "Name of the agent-fleet dashboard buffer."
  :type 'string
  :group 'agent-fleet)


;;; --- Faces (PLAN.md §28) --------------------------------------------

;; One face per Herdr AgentStatus (idle/working/blocked/done/unknown).
;; `blocked' is the most prominent: it means a human is needed.

(defface agent-fleet-blocked-face
  '((((class color) (min-colors 88))
     :weight bold :foreground "#ffffff" :background "#cc3333")
    (t :weight bold :inverse-video t))
  "Face for agents in the `blocked' state (needs human attention)."
  :group 'agent-fleet)

(defface agent-fleet-working-face
  '((((class color) (min-colors 88))
     :weight bold :foreground "#1a7f37")
    (t :weight bold))
  "Face for agents in the `working' state."
  :group 'agent-fleet)

(defface agent-fleet-done-face
  '((((class color) (min-colors 88))
     :foreground "#1a7f37")
    (t :slant italic))
  "Face for agents in the `done' state."
  :group 'agent-fleet)

(defface agent-fleet-idle-face
  '((((class color) (min-colors 88))
     :inherit shadow)
    (t :inherit shadow))
  "Face for agents in the `idle' state."
  :group 'agent-fleet)

(defface agent-fleet-unknown-face
  '((((class color) (min-colors 88))
     :weight bold :foreground "#8a6d00")
    (t :weight bold))
  "Face for agents whose state is unknown."
  :group 'agent-fleet)

(defun agent-fleet-dashboard--face-for-status (status)
  "Return the status face symbol for STATUS (a symbol or nil).
STATUS is one of idle/working/blocked/done/unknown (PLAN.md §12); nil
or an unrecognized value maps to the unknown face."
  (pcase status
    ('blocked  'agent-fleet-blocked-face)
    ('working  'agent-fleet-working-face)
    ('done     'agent-fleet-done-face)
    ('idle     'agent-fleet-idle-face)
    (_         'agent-fleet-unknown-face)))


;;; --- Column helpers -------------------------------------------------

(defun agent-fleet-dashboard--project-label (agent)
  "Return the Project label for AGENT (PLAN.md §27/§69).
Delegates to `agent-fleet-project-label' (Phase 4): the canonical
project-root basename via `project.el', falling back to the cwd basename,
then \"—\".  Matching is by canonical cwd, not workspace label (§32)."
  (agent-fleet-project-label agent))

(defun agent-fleet-dashboard--kind-label (agent)
  "Return a capitalized Kind label for AGENT, or \"—\"."
  (let ((kind (herdr-agent-agent agent)))
    (if (and kind (not (string-empty-p kind)))
        (capitalize kind)
      "—")))

(defun agent-fleet-dashboard--task-label (agent agent-label)
  "Return the Task column label for AGENT (PLAN.md §27).
For an agent in a parallel task (Phase 7), shows the task title — the group
label that clusters its sibling agents.  Otherwise uses the pane's stripped
terminal title (the best live signal of current activity) unless it
duplicates AGENT-LABEL, in which case \"—\"."
  (if-let* ((task (agent-fleet-task-for-agent (herdr-agent-id agent))))
      (agent-fleet-task-title task)
    (let ((title (herdr-agent-terminal-title-stripped agent)))
      (if (and title (not (string-empty-p title))
               (not (string= title agent-label)))
          title
        "—"))))

(defun agent-fleet-dashboard--state-cell (agent)
  "Return the State column string for AGENT, propertized with its face."
  (let* ((status (agent-fleet-status agent))
         (label (if status (upcase (symbol-name status)) "UNKNOWN"))
         (face (agent-fleet-dashboard--face-for-status status)))
    (propertize label 'face face)))

(defun agent-fleet-dashboard--status-priority (status)
  "Sort priority for STATUS (lower sorts first).
Blocked first (needs attention), then working, idle, done, unknown."
  (pcase status
    ('blocked 0)
    ('working 1)
    ('idle 2)
    ('done 3)
    (_ 4)))

(defun agent-fleet-dashboard--entry (agent)
  "Build one `tabulated-list-entries' row for AGENT.
Returns (PANE-ID . [Project Agent Kind State Task])."
  (let* ((pane-id (herdr-agent-id agent))
         (label (or (herdr-agent-display-name agent) pane-id))
         (project (agent-fleet-dashboard--project-label agent))
         (kind (agent-fleet-dashboard--kind-label agent))
         (state (agent-fleet-dashboard--state-cell agent))
         (task (agent-fleet-dashboard--task-label agent label)))
    (list pane-id
          (vector project label kind state task))))

(defvar-local agent-fleet-dashboard--project-filter nil
  "When non-nil, a canonical project root string to narrow the dashboard to.
Set by `agent-fleet-dashboard-toggle-project-filter' (the `P' key).  Only
agents whose project root equals this are shown; nil means show all
(PLAN.md §69: project-scoped dashboard).")

(defvar-local agent-fleet-dashboard--task-filter nil
  "When non-nil, a task id to narrow the dashboard to (Phase 7, §72).
Set by `agent-fleet-dashboard-toggle-task-filter' (the `T' key).  Only
agents whose task id equals this are shown; nil means show all.  This is
the §72 aggregate-status view: filter to one task, see its agents' states.")

(defvar-local agent-fleet-dashboard--task-banner nil
  "Mode-line segment string for the active task filter (Phase 7, §72).
nil when no task filter is active; otherwise `Parallel task: {title} —
{state}', refreshed live from `agent-fleet-dashboard-refresh' so the
aggregate state tracks each status event (§25: event-driven, no polling).
Shown in the mode line rather than the header line so the tabulated-list
column headers (set by `tabulated-list-init-header') are preserved.")

(defun agent-fleet-dashboard--entries ()
  "Return all dashboard rows, sorted by status priority then agent label.
When `agent-fleet-dashboard--project-filter' is set (the `P' key), narrow
to agents in that project; when `--task-filter' is set (the `T' key),
narrow to agents in that task.  Returns nil when not connected (nil-safe)."
  (let* ((agents (herdr-agents))
         (pfilter agent-fleet-dashboard--project-filter)
         (tfilter agent-fleet-dashboard--task-filter)
         (visible (cl-remove-if-not
                   (lambda (a)
                     (let ((pid (herdr-agent-id a)))
                       (and (or (null pfilter)
                                (let ((r (agent-fleet-project-for-agent a)))
                                  (and r (string= r pfilter))))
                            (or (null tfilter)
                                (when-let* ((task (agent-fleet-task-for-agent pid)))
                                  (equal (agent-fleet-task-id task) tfilter))))))
                   agents)))
    (mapcar #'agent-fleet-dashboard--entry
            (sort (copy-sequence visible)
                  (lambda (a b)
                    (let ((pa (agent-fleet-dashboard--status-priority
                               (agent-fleet-status a)))
                          (pb (agent-fleet-dashboard--status-priority
                               (agent-fleet-status b))))
                      (or (< pa pb)
                          (and (= pa pb)
                               (string< (or (herdr-agent-display-name a) "")
                                        (or (herdr-agent-display-name b) ""))))))))))


;;; --- Refresh --------------------------------------------------------

(defun agent-fleet-dashboard--set-entries ()
  "Populate `tabulated-list-entries' from the cache (no server fetch)."
  (setq tabulated-list-entries (agent-fleet-dashboard--entries)))

(defun agent-fleet-dashboard-refresh (&optional from-server)
  "Rebuild the *Agent Fleet* buffer from the cache.
With non-nil FROM-SERVER (the `g' action), first refresh the cache from
`agent.list' so the buffer reflects agents Herdr has not notified about.
The event-driven path calls this without FROM-SERVER: the cache is
already post-event because `herdr-model-apply-event' mutates before the
hooks fire (PLAN.md §25)."
  (interactive "P")
  (when from-server
    (agent-fleet-list t))
  (agent-fleet-dashboard--set-entries)
  (agent-fleet-dashboard--update-task-banner)
  (tabulated-list-print t))


;;; --- Row actions (PLAN.md §27) --------------------------------------

(defun agent-fleet-dashboard--agent-at-point ()
  "Return the pane id of the agent at point, or signal an error."
  (or (tabulated-list-get-id)
      (user-error "No agent on this line")))

;;; --- Project filter (PLAN.md §69) -----------------------------------

(defun agent-fleet-dashboard-toggle-project-filter (&optional arg)
  "Narrow the dashboard to the project of the agent at point, or clear it.
With no active filter and no prefix ARG, set the filter to the canonical
project root of the agent at point (PLAN.md §69: project-scoped
dashboard).  With an active filter, or a prefix ARG, clear it.  Refreshes
after either change."
  (interactive "P")
  (if (or arg agent-fleet-dashboard--project-filter)
      (progn
        (setq agent-fleet-dashboard--project-filter nil)
        (agent-fleet-dashboard-refresh)
        (message "agent-fleet: project filter cleared"))
    (let* ((pane-id (tabulated-list-get-id))
           (agent (and pane-id (agent-fleet--find-agent pane-id)))
           (root (and agent (agent-fleet-project-for-agent agent))))
      (if root
          (progn
            (setq agent-fleet-dashboard--project-filter root)
            (agent-fleet-dashboard-refresh)
            (message "agent-fleet: filtered to %s"
                     (file-name-nondirectory (directory-file-name root))))
        (user-error "No project for agent at point")))))

;;; --- Task filter (Phase 7, §72) --------------------------------------

(defun agent-fleet-dashboard-toggle-task-filter (&optional arg)
  "Narrow the dashboard to one parallel task's agents, or clear it (§72).
With no active filter and no prefix ARG, prompt for a task and narrow the
list to its agents — the aggregate-status view (one task's agents with
their live per-agent states).  With an active filter, or a prefix ARG,
clear it.  Refreshes after either change; the task title + aggregate state
then show in the mode line via `agent-fleet-dashboard--task-banner'."
  (interactive "P")
  (if (or arg agent-fleet-dashboard--task-filter)
      (progn
        (setq agent-fleet-dashboard--task-filter nil)
        (agent-fleet-dashboard-refresh)
        (message "agent-fleet: task filter cleared"))
    (let* ((choices (mapcar (lambda (task)
                              (cons (format "%s (%s)"
                                            (agent-fleet-task-title task)
                                            (agent-fleet-task-state task))
                                    (agent-fleet-task-id task)))
                            (agent-fleet-task-list))))
      (if (null choices)
          (user-error "No tasks to filter by")
        (let* ((sel (completing-read "Filter to task: " choices nil t))
               (task-id (cdr (assoc sel choices))))
          (setq agent-fleet-dashboard--task-filter task-id)
          (agent-fleet-dashboard-refresh)
          (message "agent-fleet: filtered to %s" sel))))))

(defun agent-fleet-dashboard--update-task-banner ()
  "Set the task-filter mode-line segment from the live aggregate state (§72).
When `agent-fleet-dashboard--task-filter' names a live task, set the banner
to `Parallel task: {title} — {state}'; otherwise clear it (nil).  Called
from `agent-fleet-dashboard-refresh', so the aggregate state stays live
with each status event — event-driven, no timer polling (§25).  The state
is computed fresh each time by `agent-fleet-task-state'."
  (setq agent-fleet-dashboard--task-banner
        (when-let* ((task (and agent-fleet-dashboard--task-filter
                               (agent-fleet-task-find
                                agent-fleet-dashboard--task-filter))))
          (format " Parallel task: %s — %s "
                  (agent-fleet-task-title task)
                  (agent-fleet-task-state task))))
  (force-mode-line-update))

(defun agent-fleet-dashboard--after-row-change ()
  "Refresh the dashboard after a mutating row action.
Some actions (rename) update the cache without firing a status hook; a
local reprint reflects them immediately.  Kill's exited-hook handles its
own refresh, but reprinting is harmless and gives instant feedback."
  (agent-fleet-dashboard-refresh))

(defun agent-fleet-dashboard-inspect ()
  "Show the agent at point's output as a read snapshot (PLAN.md §23)."
  (interactive)
  (agent-fleet-show-output (agent-fleet-dashboard--agent-at-point)))

(defun agent-fleet-dashboard-prompt ()
  "Prompt the agent at point (PLAN.md §18)."
  (interactive)
  (let* ((pane-id (agent-fleet-dashboard--agent-at-point))
         (text (read-string "Prompt: ")))
    (unless (string-empty-p text)
      (agent-fleet-prompt pane-id text))))

(defun agent-fleet-dashboard-interrupt ()
  "Send Ctrl-C to the agent at point (PLAN.md §21)."
  (interactive)
  (agent-fleet-interrupt (agent-fleet-dashboard--agent-at-point)))

(defun agent-fleet-dashboard-kill ()
  "Kill the agent at point by closing its pane (PLAN.md §27 `k')."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point)))
    (when (y-or-n-p (format "Kill agent %s? " pane-id))
      (agent-fleet-kill pane-id)
      (agent-fleet-dashboard--after-row-change))))

(defun agent-fleet-dashboard-rename ()
  "Rename the agent at point (PLAN.md §27 `r')."
  (interactive)
  (let* ((pane-id (agent-fleet-dashboard--agent-at-point))
         (cur (let ((a (agent-fleet--find-agent pane-id)))
                (or (and a (herdr-agent-display-name a)) pane-id)))
         (name (read-string "New name: " cur)))
    (unless (or (null name) (string-empty-p name))
      (agent-fleet-rename pane-id name)
      (agent-fleet-dashboard--after-row-change))))

(defun agent-fleet-dashboard-worktree ()
  "Show the worktree status for the agent at point (PLAN.md §34 `w').
Displays the worktree path/branch/repo/metadata read-only (§46/§23: no
pane output).  Delegates to `agent-fleet-worktree-status'."
  (interactive)
  (agent-fleet-worktree-status (agent-fleet-dashboard--agent-at-point)))

(defun agent-fleet-dashboard-diff ()
  "Show the working-tree diff for the agent at point (PLAN.md §71 `d').
Delegates to `agent-fleet-magit-diff' (Magit optional, PLAN §55)."
  (interactive)
  (agent-fleet-magit-diff (agent-fleet-dashboard--agent-at-point)))

(defun agent-fleet-dashboard-magit ()
  "Open Magit status for the agent at point (PLAN.md §36/§71 `m').
Delegates to `agent-fleet-magit-status' (Magit optional, PLAN §55)."
  (interactive)
  (agent-fleet-magit-status (agent-fleet-dashboard--agent-at-point)))

(defun agent-fleet-dashboard-attach ()
  "Attach live to the agent at point's terminal (PLAN.md §73 `a').
Spawns `herdr agent attach' inside the chosen Emacs terminal backend
(eat/ghostel/vterm) and pops the buffer so the agent's real PTY/TUI can be
driven without leaving Emacs.  Unlike `o' (a read-only read-snapshot, §23),
this is a live interactive session: the buffer is transient (not persisted
or mirrored, §46/§23); killing the process detaches and the agent is
preserved (§79).  A prefix arg passes `--takeover' to the attach CLI.
Delegates to `agent-fleet-attach' (terminal backends optional, PLAN §45)."
  (interactive)
  (agent-fleet-attach (agent-fleet-dashboard--agent-at-point)
                      current-prefix-arg))

(defvar agent-fleet-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-fleet-dashboard-inspect)
    (define-key map (kbd "o")   #'agent-fleet-dashboard-inspect)
    (define-key map (kbd "p")   #'agent-fleet-dashboard-prompt)
    (define-key map (kbd "i")   #'agent-fleet-dashboard-interrupt)
    (define-key map (kbd "k")   #'agent-fleet-dashboard-kill)
    (define-key map (kbd "r")   #'agent-fleet-dashboard-rename)
    (define-key map (kbd "g")   #'agent-fleet-dashboard-refresh)
    (define-key map (kbd "P")   #'agent-fleet-dashboard-toggle-project-filter)
    (define-key map (kbd "T")   #'agent-fleet-dashboard-toggle-task-filter)
    (define-key map (kbd "w")   #'agent-fleet-dashboard-worktree)
    (define-key map (kbd "d")   #'agent-fleet-dashboard-diff)
    (define-key map (kbd "m")   #'agent-fleet-dashboard-magit)
    (define-key map (kbd "a")   #'agent-fleet-dashboard-attach)
    map)
  "Keymap for `agent-fleet-mode' (PLAN.md §27 row keys).")


;;; --- Mode -----------------------------------------------------------

(define-derived-mode agent-fleet-mode tabulated-list-mode "Agent Fleet"
  "Major mode for the agent-fleet supervisor dashboard (PLAN.md Phase 3/§68).
Shows every Herdr-managed agent as a row with Project/Agent/Kind/State/Task
columns and refreshes live from the event bus — no timer polling (§25).
The Project column is a real `project.el' mapping (Phase 4, §69); `P'
narrows the list to the project of the agent at point.  `T' (Phase 7, §72)
narrows the list to one parallel task's agents and shows that task's title
+ live aggregate state in the mode line.

\\{agent-fleet-dashboard-mode-map}"
  (setq tabulated-list-format
        `[("Project" 12 t)
          ("Agent"   18 t)
          ("Kind"    8  t)
          ("State"   10 nil)
          ("Task"    30 nil)])
  (setq tabulated-list-padding 2)
  ;; Entries are pre-sorted by status priority (§28: blocked first); the
  ;; State column is non-sortable to avoid fighting that ordering.
  (setq tabulated-list-sort-key nil)
  ;; Surface the active task filter's aggregate state in the mode line
  ;; (Phase 7, §72), NOT the header line — `tabulated-list-init-header'
  ;; owns header-line-format for the column headers.
  (setq mode-line-format
        (append mode-line-format '(agent-fleet-dashboard--task-banner)))
  (add-hook 'tabulated-list-revert-hook #'agent-fleet-dashboard--set-entries nil t)
  (tabulated-list-init-header))


;;; --- Entry command --------------------------------------------------

;;;###autoload
(defun agent-fleet ()
  "Open the agent-fleet dashboard (PLAN.md Phase 3, §27/§68).
Lists every Herdr-managed agent with its state and refreshes live from
the event bus.  Connect first with `M-x herdr-connect'."
  (interactive)
  (let ((buf (get-buffer-create agent-fleet-dashboard-buffer-name)))
    (with-current-buffer buf
      (agent-fleet-mode)
      (agent-fleet-dashboard-refresh))
    (pop-to-buffer buf)
    buf))


;;; --- Event-driven refresh (PLAN.md §25) -----------------------------

(defun agent-fleet-dashboard--on-event (_descriptor)
  "Refresh the dashboard buffer in response to an agent-fleet hook event.
No-op unless the *Agent Fleet* buffer is live and in `agent-fleet-mode'.
Called from `agent-fleet-agent-{started,status-changed,exited}-hook';
the cache is already post-event at this point, so no server fetch is
needed.  Never uses a timer (PLAN.md §25)."
  (when-let* ((buf (get-buffer agent-fleet-dashboard-buffer-name)))
    (with-current-buffer buf
      (when (derived-mode-p 'agent-fleet-mode)
        (agent-fleet-dashboard-refresh)))))


;;; --- Notifications (PLAN.md §29) ------------------------------------

(defun agent-fleet-dashboard--notify-message (descriptor)
  "Return a notification string for DESCRIPTOR, or nil if not gated on.
Gated by `agent-fleet-notify-on' (a list of status symbols).  DESCRIPTOR
is the enriched hook plist (:pane-id :name :kind :status ...).  Pure so
the gating logic is testable without intercepting `message'."
  (let* ((status (plist-get descriptor :status))
         (sym (and status (intern status))))
    (when (memq sym agent-fleet-notify-on)
      (let ((name (or (plist-get descriptor :name)
                      (plist-get descriptor :pane-id)
                      "agent")))
        (format "agent-fleet: %s → %s" name status)))))

(defun agent-fleet-dashboard--notify (descriptor)
  "Notify on a blocked/done transition when gated by `agent-fleet-notify-on'.
Emits `message' and, when available, a desktop notification."
  (when-let ((msg (agent-fleet-dashboard--notify-message descriptor)))
    (message "%s" msg)
    (when (fboundp 'notifications-notify)
      (ignore-errors
        (notifications-notify :title "agent-fleet" :body msg)))))


;;; --- Setup ----------------------------------------------------------

(defun agent-fleet-dashboard--setup ()
  "Install the dashboard's hook callbacks, idempotently.
Wires event-driven refresh into the three agent lifecycle hooks and
notifications into the blocked/done hooks.  Safe to call repeatedly."
  (unless (memq #'agent-fleet-dashboard--on-event
                agent-fleet-agent-status-changed-hook)
    (add-hook 'agent-fleet-agent-status-changed-hook
              #'agent-fleet-dashboard--on-event))
  (unless (memq #'agent-fleet-dashboard--on-event
                agent-fleet-agent-started-hook)
    (add-hook 'agent-fleet-agent-started-hook
              #'agent-fleet-dashboard--on-event))
  (unless (memq #'agent-fleet-dashboard--on-event
                agent-fleet-agent-exited-hook)
    (add-hook 'agent-fleet-agent-exited-hook
              #'agent-fleet-dashboard--on-event))
  (unless (memq #'agent-fleet-dashboard--notify
                agent-fleet-agent-blocked-hook)
    (add-hook 'agent-fleet-agent-blocked-hook
              #'agent-fleet-dashboard--notify))
  (unless (memq #'agent-fleet-dashboard--notify
                agent-fleet-agent-done-hook)
    (add-hook 'agent-fleet-agent-done-hook
              #'agent-fleet-dashboard--notify)))

(agent-fleet-dashboard--setup)


;;; --- Command map (PLAN.md §53) --------------------------------------

;;;###autoload
(defvar-keymap agent-fleet-command-map
  :doc "Prefix map for agent-fleet commands (PLAN.md §53).
Bind it yourself, e.g. (global-set-key (kbd \"C-c a\") agent-fleet-command-map).
The package binds NO global keys."
  "a" #'agent-fleet
  "s" #'agent-fleet-start
  "p" #'agent-fleet-prompt
  "o" #'agent-fleet-show-output
  "i" #'agent-fleet-interrupt)


(provide 'agent-fleet-dashboard)
;;; agent-fleet-dashboard.el ends here
