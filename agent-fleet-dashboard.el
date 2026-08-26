;;; agent-fleet-dashboard.el --- Live agent dashboard over Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (transient "0.7.2"))

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

;; The supervisor dashboard.  A `tabulated-list-mode'
;; buffer named *Agent Fleet* that lists every Herdr-managed agent with its
;; project, name, kind, state, and current task, and refreshes itself
;; live from the hook bus.
;;
;; Design rules honored:
;;     event-driven; NO timer polling.  The buffer rebuilds only when an
;;        `agent-fleet-agent-{started,status-changed,exited}-hook' fires.
;;     columns Project / Agent / Kind / State / Task; row keys
;;        o s i x r g P T w d m a N h q (`a' = live attach;
;;        `N' = new agent; `o' = inspect output; `h' = transient command help;
;;        `q' closes the display container; `p'/`n'/`j'/`k' navigate rows up/down).
;;     one face per status; blocked is the most prominent.
;;     optional notifications on working→blocked / working→done, gated by
;;        `agent-fleet-notify-on'.
;;     prefix map `agent-fleet-command-map'; NO global key binding — the
;;        user opts in (e.g. (global-set-key (kbd "C-c a") agent-fleet-command-map)).
;;
;; This is a view layer only: it reuses the control commands
;; (`agent-fleet-prompt', `-interrupt', `-kill', `-rename', `-show-output',
;; `-list') and the model accessors, and adds no wire protocol.
;;
;; Task column + filter:
;;   - for an agent in a parallel task, the Task column shows the task title
;;     (the group label clustering its siblings); otherwise the pane's
;;     terminal title (the best live signal of current activity).
;;   - `T' narrows the list to one task's agents — the aggregate-status view;
;;     the task title + live aggregate state then show in the mode line.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'agent-fleet-worktree)
(require 'agent-fleet-magit)
(require 'agent-fleet-parallel)
(require 'agent-fleet-attach)
(require 'herdr-model)

(declare-function evil-define-key* "evil-core"
                  (state keymap key def &rest bindings))


;;; --- Customization --------------------------------------------------

(defcustom agent-fleet-notify-on '(blocked done)
  "Statuses that trigger an agent-fleet notification.
Each is a symbol; the default notifies on `blocked' and `done'.
Set to nil to disable notifications entirely."
  :type '(set (const blocked) (const done))
  :group 'agent-fleet)

(defcustom agent-fleet-dashboard-buffer-name "*Agent Fleet*"
  "Name of the agent-fleet dashboard buffer."
  :type 'string
  :group 'agent-fleet)

(defconst agent-fleet-dashboard-child-frame-minimum-emacs-version "29.1"
  "Minimum Emacs version supported by the child-frame dashboard.

The package itself requires this Emacs version, but the explicit feature
gate keeps child-frame creation safe when the file is loaded outside the
package manager or the package requirement changes independently later.")

(defcustom agent-fleet-dashboard-display 'buffer
  "How the `agent-fleet' command displays its dashboard.

This variable is the sole specifier of how `M-x agent-fleet' presents the
dashboard; the one-shot `agent-fleet-dashboard-open-buffer',
`-open-child-frame', and `-open-frame' commands override it per
invocation.

`buffer' uses an ordinary Emacs window.  `child-frame' uses Emacs's native
child-frame support when the selected frame is graphical, the running Emacs
is at least `agent-fleet-dashboard-child-frame-minimum-emacs-version', and
`display-buffer-in-child-frame' is available.  `frame' uses a standalone
graphical frame.  Unsupported graphical modes fall back to `buffer'."
  :type '(choice (const :tag "Regular buffer" buffer)
                 (const :tag "Native child frame" child-frame)
                 (const :tag "Standalone frame" frame))
  :group 'agent-fleet)

(defvar agent-fleet-dashboard--child-frame-parameters
  '((width . 0.48)
    (height . 0.55)
    (left . 0.5)
    (top . 0.5)
    (keep-ratio . t)
    (undecorated . t)
    (minibuffer . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (child-frame-border-width . 1)
    (no-other-frame . t))
  "Frame parameters for the native child-frame dashboard.

An internal default, not a user setting: `parent-frame' and agent-fleet's
private lifecycle parameters are merged on top of it at display time.")

(defvar agent-fleet-dashboard--frame-parameters
  '((name . "Agent Fleet")
    (width . 92)
    (height . 26)
    (minibuffer . t))
  "Frame parameters for the standalone dashboard frame.

An internal default, not a user setting: agent-fleet's private lifecycle
parameters are merged on top of it at display time.")

(defvar agent-fleet-dashboard--standalone-frame nil
  "Live standalone dashboard frame, or nil.")


;;; --- Faces --------------------------------------------

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
STATUS is one of idle/working/blocked/done/unknown; nil
or an unrecognized value maps to the unknown face."
  (pcase status
    ('blocked  'agent-fleet-blocked-face)
    ('working  'agent-fleet-working-face)
    ('done     'agent-fleet-done-face)
    ('idle     'agent-fleet-idle-face)
    (_         'agent-fleet-unknown-face)))


;;; --- Column helpers -------------------------------------------------

(defun agent-fleet-dashboard--project-label (agent)
  "Return the Project label for AGENT.
Delegates to `agent-fleet-project-label': the canonical
project-root basename via `project.el', falling back to the cwd basename,
then \"—\".  Matching is by canonical cwd, not workspace label."
  (agent-fleet-project-label agent))

(defun agent-fleet-dashboard--kind-label (agent)
  "Return a capitalized Kind label for AGENT, or \"—\"."
  (let ((kind (herdr-agent-agent agent)))
    (if (and kind (not (string-empty-p kind)))
        (capitalize kind)
      "—")))

(defun agent-fleet-dashboard--task-label (agent agent-label)
  "Return the Task column label for AGENT.
For an agent in a parallel task, shows the task title — the group
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
agents whose project root equals this are shown; nil means show all.")

(defvar-local agent-fleet-dashboard--task-filter nil
  "When non-nil, a task id to narrow the dashboard.
Set by `agent-fleet-dashboard-toggle-task-filter' (the `T' key).  Only
agents whose task id equals this are shown; nil means show all.  This is
the aggregate-status view: filter to one task, see its agents' states.")

(defvar-local agent-fleet-dashboard--task-banner nil
  "Mode-line segment string for the active task filter.
nil when no task filter is active; otherwise `Parallel task: {title} —
{state}', refreshed live from `agent-fleet-dashboard-refresh' so the
aggregate state tracks each status event (event-driven, no polling).
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
hooks fire."
  (interactive (list t))
  (when from-server
    (agent-fleet--ensure-connected)
    (agent-fleet-list t))
  (agent-fleet-dashboard--set-entries)
  (agent-fleet-dashboard--update-task-banner)
  (tabulated-list-print t))


;;; --- Row actions --------------------------------------

(defun agent-fleet-dashboard--agent-at-point ()
  "Return the pane id of the agent at point, or signal an error."
  (or (tabulated-list-get-id)
      (user-error "No agent on this line")))

(defun agent-fleet-dashboard--origin-frame (&optional frame)
  "Return FRAME's live non-dashboard origin frame, or nil.

For child frames, the native parent is the origin.  Standalone dashboards
store the frame from which they were opened."
  (let* ((frame (or frame (selected-frame)))
         (origin (or (frame-parameter
                      frame 'agent-fleet-dashboard-origin-frame)
                     (frame-parent frame))))
    (and (frame-live-p origin) origin)))

(defun agent-fleet-dashboard--select-origin-frame ()
  "Select the current dashboard's origin frame when it is live."
  (when-let* ((origin (agent-fleet-dashboard--origin-frame)))
    (unless (eq origin (selected-frame))
      (select-frame-set-input-focus origin)))
  (selected-frame))

(defun agent-fleet-dashboard--visit-external-interface
    (thunk &optional display-action)
  "Run THUNK from the dashboard's origin frame.

When called from a dashboard whose backend auto-closes (the native
child-frame backend), close that container after THUNK returns a
non-nil result, which indicates that the requested external interface
was opened.  If THUNK errors or returns nil, keep the container and
restore its focus.  DISPLAY-ACTION, when non-nil, temporarily becomes
`display-buffer-overriding-action'; attach uses this to replace the
parent's current window.  Ordinary and standalone dashboards keep
their existing lifecycle behavior."
  (let* ((dashboard-frame (selected-frame))
         (auto-close-p (agent-fleet-dashboard--auto-close-p
                        dashboard-frame)))
    (agent-fleet-dashboard--select-origin-frame)
    (condition-case err
        (let ((result
               (if display-action
                   (let ((display-buffer-overriding-action display-action))
                     (funcall thunk))
                 (funcall thunk))))
          (cond
           ((and auto-close-p result (frame-live-p dashboard-frame))
            (agent-fleet-dashboard--close-container dashboard-frame))
           ((and auto-close-p (frame-live-p dashboard-frame))
            (select-frame-set-input-focus dashboard-frame)))
          result)
      (error
       (when (and auto-close-p (frame-live-p dashboard-frame))
         (select-frame-set-input-focus dashboard-frame))
       (signal (car err) (cdr err))))))

;;; --- Project filter -----------------------------------

(defun agent-fleet-dashboard-toggle-project-filter (&optional arg)
  "Narrow the dashboard to the project of the agent at point, or clear it.
With no active filter and no prefix ARG, set the filter to the canonical
project root of the agent at point.  With an active filter, or a prefix ARG,
clear it.  Refreshes after either change."
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

;;; --- Task filter --------------------------------------

(defun agent-fleet-dashboard-toggle-task-filter (&optional arg)
  "Narrow the dashboard to one parallel task's agents, or clear it.
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
  "Set the task-filter mode-line segment from the live aggregate state.
When `agent-fleet-dashboard--task-filter' names a live task, set the banner
to `Parallel task: {title} — {state}'; otherwise clear it (nil).  Called
from `agent-fleet-dashboard-refresh', so the aggregate state stays live
with each status event — event-driven, no timer polling.  The state
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
  (if-let* ((buffer (get-buffer agent-fleet-dashboard-buffer-name)))
      (with-current-buffer buffer
        (agent-fleet-dashboard-refresh))
    (agent-fleet-dashboard-refresh)))

(defun agent-fleet-dashboard-inspect ()
  "Show the agent at point's output as a read snapshot."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point)))
    (agent-fleet-dashboard--visit-external-interface
     (lambda () (agent-fleet-show-output pane-id)))))

(defun agent-fleet-dashboard-prompt ()
  "Prompt the agent at point."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point)))
    (let ((text (read-string "Prompt: ")))
      (unless (string-empty-p text)
        (agent-fleet-prompt pane-id text)))))

(defun agent-fleet-dashboard-interrupt ()
  "Send Ctrl-C to the agent at point."
  (interactive)
  (agent-fleet-interrupt (agent-fleet-dashboard--agent-at-point)))

(defun agent-fleet-dashboard-kill ()
  "Kill the agent at point by closing its pane."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point)))
    (when (y-or-n-p (format "Kill agent %s? " pane-id))
      (agent-fleet-kill pane-id)
      (agent-fleet-dashboard--after-row-change))))

(defun agent-fleet-dashboard-rename ()
  "Rename the agent at point."
  (interactive)
  (let* ((pane-id (agent-fleet-dashboard--agent-at-point))
         (cur (let ((a (agent-fleet--find-agent pane-id)))
                (or (and a (herdr-agent-display-name a)) pane-id))))
    (let ((name (read-string "New name: " cur)))
      (unless (or (null name) (string-empty-p name))
        (agent-fleet-rename pane-id name)
        (agent-fleet-dashboard--after-row-change)))))

(defun agent-fleet-dashboard-worktree ()
  "Show the worktree status for the agent at point.
Displays the worktree path/branch/repo/metadata read-only (no
pane output).  Delegates to `agent-fleet-worktree-status'."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point)))
    (agent-fleet-dashboard--visit-external-interface
     (lambda () (agent-fleet-worktree-status pane-id)))))

(defun agent-fleet-dashboard-diff ()
  "Show the working-tree diff for the agent at point.
Delegates to `agent-fleet-magit-diff' (Magit optional)."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point)))
    (agent-fleet-dashboard--visit-external-interface
     (lambda () (agent-fleet-magit-diff pane-id)))))

(defun agent-fleet-dashboard-magit ()
  "Open Magit status for the agent at point.
Delegates to `agent-fleet-magit-status' (Magit optional)."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point)))
    (agent-fleet-dashboard--visit-external-interface
     (lambda () (agent-fleet-magit-status pane-id)))))

(defun agent-fleet-dashboard-attach ()
  "Attach live to the agent at point's terminal.
Spawns `herdr agent attach' inside the chosen Emacs terminal backend
(eat/ghostel/vterm) and pops the buffer so the agent's real PTY/TUI can be
driven without leaving Emacs.  Unlike `o' (a read-only read-snapshot),
this is a live interactive session: the buffer is transient (not persisted
or mirrored); killing the process detaches and the agent is
preserved.  A prefix arg passes `--takeover' to the attach CLI.
From a child dashboard, replace the parent frame's current window with the
attach buffer and delete the child after attach succeeds.  Delegates to
`agent-fleet-attach' (terminal backends optional)."
  (interactive)
  (let ((pane-id (agent-fleet-dashboard--agent-at-point))
        (takeover current-prefix-arg))
    ;; `agent-fleet-attach' displays its buffer in the selected window
    ;; (same-window); the visitor first selects the origin frame so that
    ;; window is the parent's, then closes a child dashboard only after
    ;; the attach opened successfully.
    (agent-fleet-dashboard--visit-external-interface
     (lambda () (agent-fleet-attach pane-id takeover)))))

(defun agent-fleet-dashboard-new ()
  "Start a new agent from the dashboard.
Delegates to `agent-fleet-start' (interactive: prompts for kind and
name, picks a workspace when none is focused, and auto-attaches the
new agent's terminal).  From a child dashboard, the attach lands in
the parent frame and the child closes on success, like `a' (attach).
Unlike the row actions, this does not act on the agent at point."
  (interactive)
  (agent-fleet-dashboard--visit-external-interface
   (lambda () (call-interactively #'agent-fleet-start))))


;;; --- Command help ---------------------------------------------------

(transient-define-prefix agent-fleet-dashboard-help ()
  "Show and dispatch commands for the agent-fleet dashboard."
  [["Session"
    ("N" "New agent" agent-fleet-dashboard-new)
    ("a" "Attach terminal" agent-fleet-dashboard-attach)
    ("q" "Close dashboard" agent-fleet-dashboard-quit)]
   ["Agent"
    ("o"   "Inspect output" agent-fleet-dashboard-inspect)
    ("s"   "Prompt" agent-fleet-dashboard-prompt)
    ("i"   "Interrupt" agent-fleet-dashboard-interrupt)
    ("x"   "Kill" agent-fleet-dashboard-kill)
    ("r"   "Rename" agent-fleet-dashboard-rename)]
   ["View / Filter"
    ("g" "Refresh from server" agent-fleet-dashboard-refresh)
    ("P" "Toggle project filter" agent-fleet-dashboard-toggle-project-filter)
    ("T" "Toggle task filter" agent-fleet-dashboard-toggle-task-filter)]
   ["Worktree / Git"
    ("w" "Worktree status" agent-fleet-dashboard-worktree)
    ("d" "Working-tree diff" agent-fleet-dashboard-diff)
    ("m" "Magit status" agent-fleet-dashboard-magit)]])

(defconst agent-fleet-dashboard--bindings
  '(("o"   . agent-fleet-dashboard-inspect)
    ("s"   . agent-fleet-dashboard-prompt)
    ("i"   . agent-fleet-dashboard-interrupt)
    ("x"   . agent-fleet-dashboard-kill)
    ("r"   . agent-fleet-dashboard-rename)
    ("g"   . agent-fleet-dashboard-refresh)
    ("P"   . agent-fleet-dashboard-toggle-project-filter)
    ("T"   . agent-fleet-dashboard-toggle-task-filter)
    ("w"   . agent-fleet-dashboard-worktree)
    ("d"   . agent-fleet-dashboard-diff)
    ("m"   . agent-fleet-dashboard-magit)
    ("a"   . agent-fleet-dashboard-attach)
    ("N"   . agent-fleet-dashboard-new)
    ("h"   . agent-fleet-dashboard-help)
    ("q"   . agent-fleet-dashboard-quit))
  "Documented action key bindings for `agent-fleet-mode'.")

(defconst agent-fleet-dashboard--retired-bindings
  '("RET")
  "Former dashboard bindings that must be removed when the map is reloaded.
`agent-fleet-mode-map' is defined with `defvar', so an Emacs session that
loads a newer agent-fleet keeps the old map object.  Listing removed keys
here prevents obsolete commands from surviving that in-place upgrade.")

(defconst agent-fleet-dashboard--navigation-keys
  '(("p" . previous-line)
    ("k" . previous-line)
    ("n" . next-line)
    ("j" . next-line))
  "Reserved up/down row-navigation keys for `agent-fleet-mode'.")

(defvaralias 'agent-fleet-dashboard-mode-map 'agent-fleet-mode-map
  "Compatibility alias for the dashboard mode map's former name.")

(defvar agent-fleet-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map)
  "Keymap for `agent-fleet-mode'.")

(defun agent-fleet-dashboard--install-key-bindings ()
  "Install dashboard bindings in the active mode map and optional Evil maps.
This function intentionally runs outside the map's `defvar' initializer so
reloading agent-fleet updates an already-created `agent-fleet-mode-map'.
It also removes `agent-fleet-dashboard--retired-bindings' left by older
versions of that map."
  (let ((keys (append agent-fleet-dashboard--bindings
                      agent-fleet-dashboard--navigation-keys)))
    (dolist (key agent-fleet-dashboard--retired-bindings)
      (define-key agent-fleet-mode-map (kbd key) nil))
    (dolist (binding keys)
      (define-key agent-fleet-mode-map (kbd (car binding)) (cdr binding)))
    ;; Evil's state maps take precedence over an ordinary major-mode map.  The
    ;; dashboard inherits motion state from `special-mode' in common setups, so
    ;; mirror its commands into the two non-insert states when Evil is present.
    (when (fboundp 'evil-define-key*)
      (apply #'evil-define-key* '(normal motion) agent-fleet-mode-map
             (append
              (mapcan (lambda (binding)
                        (list (kbd (car binding)) (cdr binding)))
                      keys)
              (mapcan (lambda (key) (list (kbd key) nil))
                      agent-fleet-dashboard--retired-bindings))))))

(agent-fleet-dashboard--install-key-bindings)

(with-eval-after-load 'evil
  (agent-fleet-dashboard--install-key-bindings))


;;; --- Mode -----------------------------------------------------------

(define-derived-mode agent-fleet-mode tabulated-list-mode "Agent Fleet"
  "Major mode for the agent-fleet supervisor dashboard.
Shows every Herdr-managed agent as a row with Project/Agent/Kind/State/Task
columns and refreshes live from the event bus — no timer polling.
The Project column is a real `project.el' mapping; `P'
narrows the list to the project of the agent at point.  `T'
narrows the list to one parallel task's agents and shows that task's title
+ live aggregate state in the mode line.

\\{agent-fleet-mode-map}"
  (setq tabulated-list-format
        `[("Project" 12 t)
          ("Agent"   18 t)
          ("Kind"    8  t)
          ("State"   10 nil)
          ("Task"    30 nil)])
  (setq tabulated-list-padding 2)
  ;; Entries are pre-sorted by status priority (blocked first); the
  ;; State column is non-sortable to avoid fighting that ordering.
  (setq tabulated-list-sort-key nil)
  ;; Surface the active task filter's aggregate state in the mode line,
  ;; NOT the header line — `tabulated-list-init-header'
  ;; owns header-line-format for the column headers.
  (setq mode-line-format
        (append mode-line-format '(agent-fleet-dashboard--task-banner)))
  (add-hook 'tabulated-list-revert-hook #'agent-fleet-dashboard--set-entries nil t)
  (tabulated-list-init-header))


;;; --- Entry command --------------------------------------------------

(defun agent-fleet-dashboard-child-frame-available-p (&optional parent-frame)
  "Return non-nil when a child dashboard can use PARENT-FRAME.

Availability requires Emacs
`agent-fleet-dashboard-child-frame-minimum-emacs-version' or newer, a
graphical parent frame, and the native `display-buffer-in-child-frame'
action function.  PARENT-FRAME defaults to the selected frame."
  (and (version<= agent-fleet-dashboard-child-frame-minimum-emacs-version
                  emacs-version)
       (fboundp 'display-buffer-in-child-frame)
       (display-graphic-p (or parent-frame (selected-frame)))))

(defun agent-fleet-dashboard--child-frame-unavailable-reason
    (&optional parent-frame)
  "Explain why a child dashboard cannot use PARENT-FRAME, or return nil."
  (cond
   ((version< emacs-version
              agent-fleet-dashboard-child-frame-minimum-emacs-version)
    (format "native child frames require Emacs %s or newer (running %s)"
            agent-fleet-dashboard-child-frame-minimum-emacs-version
            emacs-version))
   ((not (fboundp 'display-buffer-in-child-frame))
    "this Emacs lacks display-buffer-in-child-frame")
   ((not (display-graphic-p (or parent-frame (selected-frame))))
    "native child frames require a graphical Emacs frame")))

(defun agent-fleet-dashboard--merge-frame-parameters (base overrides)
  "Return a copy of frame parameter alist BASE updated by OVERRIDES."
  (let ((parameters (copy-tree base)))
    (dolist (entry overrides)
      (setq parameters (assq-delete-all (car entry) parameters))
      (push (cons (car entry) (cdr entry)) parameters))
    parameters))

(defun agent-fleet-dashboard--prepare-buffer ()
  "Create, initialize and refresh the shared dashboard buffer.
Refresh FROM SERVER (`agent.list') so the buffer opens on Herdr's
authoritative state, not a possibly-stale cache.  A cache can lag between
connects: `pane.agent_status_changed' is per-pane and is NOT replayed on
reconnect, so a status transition missed during a subscription gap leaves
the cache stale until the next server fetch.  The `g' action does the same
fetch on demand; this just also does it on open.  A failed fetch signals
and is caught upstream, leaving the prior cache intact."
  (let ((buffer (get-buffer-create agent-fleet-dashboard-buffer-name)))
    (with-current-buffer buffer
      ;; Preserve buffer-local project/task filters when reopening a live
      ;; dashboard.  Calling the major mode again would erase them.
      (unless (derived-mode-p 'agent-fleet-mode)
        (agent-fleet-mode))
      (agent-fleet-dashboard-refresh t))
    buffer))

(defun agent-fleet-dashboard--display-in-buffer (buffer)
  "Display dashboard BUFFER in an ordinary Emacs window."
  (pop-to-buffer buffer)
  buffer)

(defun agent-fleet-dashboard--fallback-to-buffer (buffer reason)
  "Display dashboard BUFFER normally and report fallback REASON."
  (message "agent-fleet: %s; using a regular buffer" reason)
  (agent-fleet-dashboard--display-in-buffer buffer))

(defun agent-fleet-dashboard--child-parent-frame (&optional frame)
  "Return the parent to use for a child dashboard opened from FRAME.

Reopening from an existing agent-fleet dashboard whose backend is
parented (the native child-frame backend) uses that dashboard's native
parent instead of creating recursively nested child frames.  A frame
whose backend is not parented (a standalone dashboard or an ordinary
frame) is its own parent."
  (let ((frame (or frame (selected-frame))))
    (if (agent-fleet-dashboard--backend-property
         (frame-parameter frame 'agent-fleet-dashboard-display) :parented)
        (or (frame-parent frame)
            (frame-parameter frame 'agent-fleet-dashboard-origin-frame)
            frame)
      frame)))

(defun agent-fleet-dashboard--display-in-child-frame (buffer)
  "Display dashboard BUFFER in a native child frame, or fall back safely."
  (let* ((parent (agent-fleet-dashboard--child-parent-frame))
         (reason (agent-fleet-dashboard--child-frame-unavailable-reason
                  parent)))
    (if reason
        (agent-fleet-dashboard--fallback-to-buffer buffer reason)
      (let* ((private `((parent-frame . ,parent)
                        (agent-fleet-dashboard-display . child-frame)
                        (agent-fleet-dashboard-origin-frame . ,parent)))
             (parameters
              (agent-fleet-dashboard--merge-frame-parameters
               agent-fleet-dashboard--child-frame-parameters private)))
        (condition-case err
            (if-let* ((window
                      (display-buffer
                       buffer
                       `((display-buffer-in-child-frame)
                         (child-frame-parameters . ,parameters)))))
                (let ((child (window-frame window)))
                  ;; Reused child frames also receive current lifecycle data.
                  (modify-frame-parameters child private)
                  (select-frame-set-input-focus child)
                  (agent-fleet-dashboard--center-child-frame child parent)
                  buffer)
              (agent-fleet-dashboard--fallback-to-buffer
               buffer "Emacs could not create a child frame"))
          (error
           (agent-fleet-dashboard--fallback-to-buffer
            buffer (format "child-frame creation failed: %s"
                           (error-message-string err)))))))))

(defvar agent-fleet-dashboard--centered-children nil
  "Alist (CHILD-FRAME . PARENT-FRAME) for centered child dashboards.
Used by the parent-resize hook to re-center a child after its parent is
resized, since fractional `left'/`top' position parameters are not
reliably applied on every build.")

(defun agent-fleet-dashboard--center-child-frame (frame parent)
  "Center child FRAME within PARENT in pixels.
The fractional `left'/`top' parameters should center a child frame per
the Emacs manual, but some builds (notably macOS) do not apply them at
creation.  Compute the center in pixels and call `set-frame-position'
explicitly so the dashboard is reliably centered within its parent."
  (when (and (frame-live-p frame)
             (frame-live-p parent)
             (display-graphic-p parent))
    (let* ((pw (frame-pixel-width parent))
           (ph (frame-pixel-height parent))
           (cw (frame-pixel-width frame))
           (ch (frame-pixel-height frame))
           (left (max 0 (/ (- pw cw) 2)))
           (top  (max 0 (/ (- ph ch) 2))))
      (set-frame-position frame left top)
      (setf (alist-get frame agent-fleet-dashboard--centered-children) parent))))

(defun agent-fleet-dashboard--recenter-on-parent-resize (frame)
  "Re-center child dashboards whose parent is FRAME after it resizes."
  (when (and (display-graphic-p frame)
             agent-fleet-dashboard--centered-children)
    (dolist (cell agent-fleet-dashboard--centered-children)
      (let ((child (car cell))
            (parent (cdr cell)))
        (when (and (eq parent frame)
                   (frame-live-p child)
                   (eq (frame-parameter child 'agent-fleet-dashboard-display)
                       'child-frame))
          (agent-fleet-dashboard--center-child-frame child parent))))))

(defun agent-fleet-dashboard--forget-centered-child (frame)
  "Drop FRAME from the centered-children tracking when it is deleted."
  (setq agent-fleet-dashboard--centered-children
        (assq-delete-all frame agent-fleet-dashboard--centered-children)))

(defun agent-fleet-dashboard--setup-frame-hooks ()
  "Install child-frame lifecycle callbacks as ordinary, idempotent hooks.
`remove-function' first undoes the erroneous function-composition form used
by an older release.  It leaves a proper hook list unchanged, so this also
repairs an already-running Emacs before `add-hook' installs the callbacks in
the normal representation."
  (remove-function (default-value 'window-size-change-functions)
                   #'agent-fleet-dashboard--recenter-on-parent-resize)
  (remove-function (default-value 'delete-frame-functions)
                   #'agent-fleet-dashboard--forget-centered-child)
  (add-hook 'window-size-change-functions
            #'agent-fleet-dashboard--recenter-on-parent-resize)
  (add-hook 'delete-frame-functions
            #'agent-fleet-dashboard--forget-centered-child))

(agent-fleet-dashboard--setup-frame-hooks)

(defun agent-fleet-dashboard--display-in-frame (buffer)
  "Display dashboard BUFFER in a reusable standalone graphical frame."
  (if (not (display-graphic-p (selected-frame)))
      (agent-fleet-dashboard--fallback-to-buffer
       buffer "a standalone dashboard requires a graphical Emacs frame")
    (let* ((selected (selected-frame))
           (origin (or (frame-parameter
                        selected 'agent-fleet-dashboard-origin-frame)
                       selected))
           (private `((agent-fleet-dashboard-display . frame)
                      (agent-fleet-dashboard-origin-frame . ,origin)))
           (parameters
            (agent-fleet-dashboard--merge-frame-parameters
             agent-fleet-dashboard--frame-parameters private)))
      (condition-case err
          (let ((frame
                 (if (frame-live-p agent-fleet-dashboard--standalone-frame)
                     agent-fleet-dashboard--standalone-frame
                   (setq agent-fleet-dashboard--standalone-frame
                         (make-frame parameters)))))
            (modify-frame-parameters frame private)
            (set-window-buffer (frame-selected-window frame) buffer)
            (select-frame-set-input-focus frame)
            buffer)
        (error
         (setq agent-fleet-dashboard--standalone-frame nil)
         (agent-fleet-dashboard--fallback-to-buffer
          buffer (format "standalone frame creation failed: %s"
                         (error-message-string err))))))))

;;; --- Backend registry -----------------------------------------------

(defvar agent-fleet-dashboard--backends
  (list
   (list 'buffer
         :display #'agent-fleet-dashboard--display-in-buffer
         :container nil :auto-close nil :parented nil :close nil)
   (list 'child-frame
         :display #'agent-fleet-dashboard--display-in-child-frame
         :container t :auto-close t :parented t :close #'delete-frame)
   (list 'frame
         :display #'agent-fleet-dashboard--display-in-frame
         :container t :auto-close nil :parented nil :close #'delete-frame))
  "Registry of dashboard display backends.

Each entry is (SYMBOL . PLIST) where PLIST keys are:
  :display     function called with the dashboard buffer;
  :container   non-nil when the backend owns a frame that `q' must
               delete rather than `quit-window';
  :auto-close  non-nil when an external action that opens successfully
               should close the dashboard container (the child-frame
               lifecycle); standalone frames are reusable and stay open;
  :parented    non-nil when the backend creates a frame with a
               `parent-frame'; reopening from such a dashboard reuses
               its parent instead of nesting a child under a child;
  :close       function called with the container frame to dispose of
               it, or nil to fall back to `delete-frame'.

Adding a backend is one entry here plus its `:display' function and a
choice in `agent-fleet-dashboard-display'; the lifecycle code below
needs no further edits.")

(defun agent-fleet-dashboard--backend-plist (symbol)
  "Return the metadata plist for backend SYMBOL, or nil if unregistered."
  (cdr (assq symbol agent-fleet-dashboard--backends)))

(defun agent-fleet-dashboard--backend-property (symbol property)
  "Return backend SYMBOL's metadata PROPERTY, or nil if unknown."
  (plist-get (agent-fleet-dashboard--backend-plist symbol) property))

(defun agent-fleet-dashboard--display-backend (symbol)
  "Return the display function for backend SYMBOL, or nil."
  (agent-fleet-dashboard--backend-property symbol :display))

(defun agent-fleet-dashboard--container-p (&optional frame)
  "Return non-nil if FRAME's backend owns a deletable display container.
FRAME defaults to the selected frame; an unregistered display is nil."
  (agent-fleet-dashboard--backend-property
   (frame-parameter (or frame (selected-frame))
                    'agent-fleet-dashboard-display)
   :container))

(defun agent-fleet-dashboard--auto-close-p (&optional frame)
  "Return non-nil if FRAME's backend closes after a successful external action.
FRAME defaults to the selected frame."
  (agent-fleet-dashboard--backend-property
   (frame-parameter (or frame (selected-frame))
                    'agent-fleet-dashboard-display)
   :auto-close))

(defun agent-fleet-dashboard--close-container (frame)
  "Close the dashboard display container FRAME via its backend's path.
Built-in backends delete the frame directly.  This helper is the single
seam through which a container is disposed of, so callers never invoke
`delete-frame' on a dashboard frame themselves."
  (let ((close (agent-fleet-dashboard--backend-property
                (frame-parameter frame 'agent-fleet-dashboard-display) :close)))
    (if close
        (funcall close frame)
      (delete-frame frame))))

(defun agent-fleet-dashboard--display (buffer display)
  "Display dashboard BUFFER using backend DISPLAY.
The backend is looked up in `agent-fleet-dashboard--backends'; an
unknown symbol is a programming error, not a fallback case (fallbacks
happen inside each backend's own display function)."
  (if-let* ((fn (agent-fleet-dashboard--display-backend display)))
      (funcall fn buffer)
    (user-error "Unknown agent-fleet dashboard display backend: %S"
                display)))

(defun agent-fleet-dashboard--open (display)
  "Connect, prepare and open the dashboard using DISPLAY backend."
  (agent-fleet--ensure-connected)
  (let ((buffer (agent-fleet-dashboard--prepare-buffer)))
    (agent-fleet-dashboard--display buffer display)
    buffer))

;;;###autoload
(defun agent-fleet ()
  "Open the agent-fleet dashboard.

The display form is `agent-fleet-dashboard-display' and only that
variable selects how this command presents the dashboard; for a one-shot
override use `agent-fleet-dashboard-open-buffer', `-open-child-frame', or
`-open-frame'.  The dashboard lists every Herdr-managed agent, reconciles
the list from `agent.list' on open, refreshes from the event bus, and
connects according to `agent-fleet-auto-connect'."
  (interactive)
  (agent-fleet-dashboard--open agent-fleet-dashboard-display))

;;;###autoload
(defun agent-fleet-dashboard-open-buffer ()
  "Open the agent-fleet dashboard in an ordinary Emacs window."
  (interactive)
  (agent-fleet-dashboard--open 'buffer))

;;;###autoload
(defun agent-fleet-dashboard-open-child-frame ()
  "Open the agent-fleet dashboard in a native child frame when supported.

The feature requires Emacs
`agent-fleet-dashboard-child-frame-minimum-emacs-version' or newer, a
graphical selected frame, and native child-frame display support.  It falls
back to an ordinary buffer when any requirement is not met."
  (interactive)
  (agent-fleet-dashboard--open 'child-frame))

;;;###autoload
(defun agent-fleet-dashboard-open-frame ()
  "Open the agent-fleet dashboard in a standalone graphical frame."
  (interactive)
  (agent-fleet-dashboard--open 'frame))

(defun agent-fleet-dashboard-quit ()
  "Close the dashboard's current display container.

Delete an agent-fleet child or standalone frame.  In an ordinary window,
use `quit-window'.  The shared dashboard buffer, Herdr connection and all
agents remain alive."
  (interactive)
  (let ((frame (selected-frame)))
    (if (agent-fleet-dashboard--container-p frame)
        (progn
          (when (eq frame agent-fleet-dashboard--standalone-frame)
            (setq agent-fleet-dashboard--standalone-frame nil))
          (agent-fleet-dashboard--close-container frame))
      (quit-window))))


;;; --- Event-driven refresh -----------------------------

(defun agent-fleet-dashboard--on-event (_descriptor)
  "Refresh the dashboard buffer in response to an agent-fleet hook event.
No-op unless the *Agent Fleet* buffer is live and in `agent-fleet-mode'.
Called from `agent-fleet-agent-{started,status-changed,exited}-hook';
the cache is already post-event at this point, so no server fetch is
needed.  Never uses a timer."
  (when-let* ((buf (get-buffer agent-fleet-dashboard-buffer-name)))
    (with-current-buffer buf
      (when (derived-mode-p 'agent-fleet-mode)
        (agent-fleet-dashboard-refresh)))))


;;; --- Notifications ------------------------------------

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
  (when-let* ((msg (agent-fleet-dashboard--notify-message descriptor)))
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
  (unless (memq #'agent-fleet-dashboard--on-event
                agent-fleet-task-changed-hook)
    (add-hook 'agent-fleet-task-changed-hook
              #'agent-fleet-dashboard--on-event))
  (unless (memq #'agent-fleet-dashboard--on-event
                agent-fleet-synced-hook)
    (add-hook 'agent-fleet-synced-hook
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


;;; --- Command map --------------------------------------

;;;###autoload
(defvar-keymap agent-fleet-command-map
  :doc "Prefix map for agent-fleet commands.
Bind it yourself, e.g. (global-set-key (kbd \"C-c a\") agent-fleet-command-map).
The package binds NO global keys."
  "a" #'agent-fleet
  "s" #'agent-fleet-start
  "p" #'agent-fleet-prompt
  "o" #'agent-fleet-show-output
  "i" #'agent-fleet-interrupt)


(provide 'agent-fleet-dashboard)
;;; agent-fleet-dashboard.el ends here
