;;; agent-fleet.el --- Multi-agent supervisor over Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.2.0
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

;; The agent-facing supervisor layer (PLAN.md Phase 2, §67).  Built on
;; the Phase 1 Herdr client (`herdr.el'): it provisions panes, starts CLI
;; agents (Claude / Codex / Pi / ...), drives them through Herdr's
;; `agent.*' RPCs, reads their output, and exposes an event-driven hook
;; bus for status transitions — without ever bringing the agents' PTY/TUI
;; into Emacs.
;;
;; Design rules honored (PLAN.md):
;;   §12  agent statuses come straight from Herdr (idle/working/blocked/
;;        done/unknown); this layer adds NO status parsing of its own.
;;   §18  prompts go through `agent.prompt', not pane.send-text + RET.
;;   §19  prompt+wait is a single atomic `agent.prompt' with a `wait'
;;        field, to avoid the separate prompt/wait race.
;;   §20  three input tiers: agent.prompt (L1), agent.send_keys (L2),
;;        pane.send_input (L3 escape hatch).
;;   §21  interrupt = agent.send_keys "ctrl+c"; NOT "cancel".
;;   §23  output is a read-snapshot, not a continuously mirrored terminal.
;;   §25  event-driven; no polling timers.
;;   §26  Herdr events are bridged into agent-fleet-*-hook variables.
;;
;; Requiring this package entry point also loads the dashboard and feature
;; modules at the end of the file.  Optional runtime integrations
;; (Magit/Eat/Ghostel/vterm) remain lazily probed by their own modules.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr)
(require 'herdr-model)
(require 'herdr-events)


;;; --- Customization --------------------------------------------------

(defgroup agent-fleet nil
  "Multi-agent supervisor over the Herdr terminal workspace server."
  :group 'processes
  :link '(url-link "https://herdr.dev"))

(defvar agent-fleet--auto-connect-timer nil
  "Pending idle timer for an automatic Herdr connection, or nil.")

(defvar agent-fleet--connect-in-progress nil
  "Non-nil while agent-fleet is establishing a Herdr connection.")

(defun agent-fleet--set-auto-connect (symbol value)
  "Set SYMBOL to VALUE and reconfigure automatic connection startup.
This is the custom setter for `agent-fleet-auto-connect'."
  (set-default symbol value)
  ;; During the first `defcustom' evaluation the setup function has not
  ;; been defined yet.  It is called explicitly once the package is loaded.
  (when (fboundp 'agent-fleet--configure-auto-connect)
    (agent-fleet--configure-auto-connect)))

(defcustom agent-fleet-auto-connect 'on-demand
  "When agent-fleet should connect to Herdr automatically.
`on-demand' connects before the first dashboard or control operation.
`after-init' additionally pre-connects from an idle timer after Emacs
initialization; a later command retries on demand if pre-connection failed.
Nil preserves manual-only behavior and requires `herdr-connect'.

Automatic connection never starts the Herdr server itself."
  :type '(choice (const :tag "Manually only" nil)
                 (const :tag "When first needed" on-demand)
                 (const :tag "After Emacs initialization" after-init))
  :set #'agent-fleet--set-auto-connect
  :group 'agent-fleet)

(defcustom agent-fleet-auto-connect-delay 1.0
  "Idle seconds before an `after-init' automatic Herdr connection.
This affects only `agent-fleet-auto-connect' set to `after-init'."
  :type 'number
  :group 'agent-fleet)

(defcustom agent-fleet-agent-executables
  '((claude "claude" "Claude Code")
    (codex "codex" "Codex")
    (pi "pi" "Pi"))
  "Known agent kinds and the CLI executables they use.
Each entry is (KIND-SYMBOL EXECUTABLE DISPLAY-NAME).  Used by
`agent-fleet-doctor' and to provide a default `kind' completion table."
  :type '(repeat (list (symbol :tag "Kind")
                       (string :tag "Executable")
                       (string :tag "Display name")))
  :group 'agent-fleet)

(defcustom agent-fleet-default-read-source 'recent_unwrapped
  "Default `agent.read' source.
`recent_unwrapped' ignores soft wrapping and is best for log/agent
output (PLAN.md §22).  One of: visible, recent, recent_unwrapped,
detection."
  :type '(choice (const visible) (const recent)
                 (const recent_unwrapped) (const detection))
  :group 'agent-fleet)

(defcustom agent-fleet-default-read-lines 120
  "Default line count for `agent-fleet-read' and `agent-fleet-show-output'."
  :type 'integer
  :group 'agent-fleet)

(defcustom agent-fleet-default-read-format 'text
  "Default `agent.read' format: `text' (ANSI stripped) or `ansi'."
  :type '(choice (const text) (const ansi))
  :group 'agent-fleet)

(defcustom agent-fleet-start-timeout-ms 30000
  "Startup timeout (ms) passed to `agent.start'.
Herdr requires this to be greater than 3000 and at most 300000."
  :type 'integer
  :group 'agent-fleet)

(defcustom agent-fleet-wait-timeout-ms 120000
  "Default timeout (ms) for `agent-fleet-wait' and `agent-fleet-prompt-and-wait'."
  :type 'integer
  :group 'agent-fleet)

(defcustom agent-fleet-default-wait-until '(done blocked)
  "Default statuses `agent-fleet-wait' / `-prompt-and-wait' wait for.
A list of status symbols.  `done' = finished; `blocked' = needs input."
  :type '(repeat (choice (const idle) (const working)
                         (const blocked) (const done) (const unknown)))
  :group 'agent-fleet)

(defcustom agent-fleet-output-buffer-prefix "*Agent Output: "
  "Prefix for `agent-fleet-show-output' buffer names.
The buffer is named PREFIX<name>*."
  :type 'string
  :group 'agent-fleet)

(defconst agent-fleet--request-timeout-slack 5.0
  "Extra seconds allowed beyond a Herdr server-side timeout.
Long-running RPCs such as `agent.start' and `agent.wait' carry their own
`timeout_ms'.  The socket request must remain alive for at least that long;
this small allowance covers framing and scheduling around the server wait.")


;;; --- Errors ---------------------------------------------------------

(define-error 'agent-fleet-error "agent-fleet error" 'herdr-error)
(define-error 'agent-fleet-not-connected
  "agent-fleet: not connected to Herdr" 'agent-fleet-error)
(define-error 'agent-fleet-target-not-found
  "agent-fleet: agent not found" 'agent-fleet-error)
(define-error 'agent-fleet-provisioning-failed
  "agent-fleet: pane provisioning failed" 'agent-fleet-error)

(defun agent-fleet--connect-now ()
  "Establish a Herdr connection once and return non-nil when live.
Concurrent/re-entrant attempts are coalesced.  Errors from `herdr-connect'
are allowed to propagate to the caller."
  (cond
   ((herdr-connected-p) t)
   (agent-fleet--connect-in-progress nil)
   (t
    (let ((agent-fleet--connect-in-progress t))
      (herdr-connect)
      (herdr-connected-p)))))

(defun agent-fleet--ensure-connected ()
  "Ensure Herdr is live according to `agent-fleet-auto-connect'.
Return t when connected.  In automatic modes, make one immediate connection
attempt before signalling `agent-fleet-not-connected'."
  (cond
   ((herdr-connected-p) t)
   ((null agent-fleet-auto-connect)
    (signal 'agent-fleet-not-connected
            (list :hint "run M-x herdr-connect, or enable agent-fleet-auto-connect")))
   (agent-fleet--connect-in-progress
    (signal 'agent-fleet-not-connected
            (list :hint "a Herdr connection is already in progress; retry shortly")))
   (t
    (let ((cause (condition-case err
                     (progn (agent-fleet--connect-now) nil)
                   (error err))))
      (if (herdr-connected-p)
          t
        (signal 'agent-fleet-not-connected
                (list :cause cause
                      :hint (concat "ensure the Herdr server is running, then retry; "
                                    "see M-x agent-fleet-doctor"))))))))

(defun agent-fleet--auto-connect-now ()
  "Try the configured startup connection without disrupting Emacs startup."
  (setq agent-fleet--auto-connect-timer nil)
  (when (and (eq agent-fleet-auto-connect 'after-init)
             (not (herdr-connected-p))
             (not agent-fleet--connect-in-progress))
    (condition-case err
        (agent-fleet--connect-now)
      (error
       (message "agent-fleet: Herdr pre-connection failed: %s"
                (error-message-string err))
       nil))))

(defun agent-fleet--schedule-auto-connect ()
  "Schedule one idle Herdr connection for `after-init' mode."
  (remove-hook 'after-init-hook #'agent-fleet--schedule-auto-connect)
  (when (and (eq agent-fleet-auto-connect 'after-init)
             (not (herdr-connected-p))
             (not (timerp agent-fleet--auto-connect-timer)))
    (setq agent-fleet--auto-connect-timer
          (run-with-idle-timer agent-fleet-auto-connect-delay nil
                               #'agent-fleet--auto-connect-now))))

(defun agent-fleet--configure-auto-connect ()
  "Install or remove startup behavior for `agent-fleet-auto-connect'."
  (remove-hook 'after-init-hook #'agent-fleet--schedule-auto-connect)
  (when (timerp agent-fleet--auto-connect-timer)
    (cancel-timer agent-fleet--auto-connect-timer))
  (setq agent-fleet--auto-connect-timer nil)
  (when (eq agent-fleet-auto-connect 'after-init)
    (if after-init-time
        (agent-fleet--schedule-auto-connect)
      (add-hook 'after-init-hook #'agent-fleet--schedule-auto-connect))))


;;; --- Target resolution ----------------------------------------------

;; `agent.*' RPCs take a `target' string that Herdr resolves as either an
;; agent name or a pane id.  We prefer the pane id (stable across renames)
;; when we can resolve it from the cache; otherwise we pass the string
;; through and let Herdr resolve it.  `pane.*' RPCs need a real pane id.

(defun agent-fleet--find-agent (agent)
  "Resolve AGENT to a cached `herdr-agent' struct, or nil.
AGENT may be a struct, a name string, a pane-id string, or a symbol."
  (cond
   ((herdr-agent-p agent) agent)
   ((stringp agent)
    (or (herdr-model-find-agent-by-name agent)
        (herdr-model-find-agent agent)))      ; by pane id
   ((symbolp agent)
    (herdr-model-find-agent-by-name (symbol-name agent)))
   (t nil)))

(defun agent-fleet--resolve-target (agent)
  "Resolve AGENT to a `target' string for `agent.*' RPCs.
Prefers the pane id (stable across renames); falls back to the name or
the string itself.  Never signals: an unresolvable string is passed
through so Herdr can report the error."
  (let ((struct (agent-fleet--find-agent agent)))
    (cond
     ((herdr-agent-p struct) (herdr-agent-id struct))
     ((stringp agent) agent)
     ((symbolp agent) (symbol-name agent))
     (t (signal 'agent-fleet-target-not-found (list :agent agent))))))

(defun agent-fleet--resolve-pane-id (agent)
  "Resolve AGENT to a pane id string (for `pane.*' RPCs).
Signals `agent-fleet-target-not-found' if AGENT cannot be resolved to a
pane id."
  (let ((struct (agent-fleet--find-agent agent)))
    (cond
     ((herdr-agent-p struct) (herdr-agent-id struct))
     ((stringp agent)
      (let ((cached (herdr-model-find-agent agent))) ; by pane id
        (if cached (herdr-agent-id cached)
          ;; Uncached string (a name Herdr knows but we don't): ask Herdr
          ;; to resolve name -> pane id, falling back to treating the
          ;; string itself as a pane id.
          (or (plist-get
               (agent-fleet--unwrap-agent
                (ignore-errors
                  (herdr-request "agent.get" `(("target" . ,agent)))))
               :pane_id)
              agent))))
     ((symbolp agent) (agent-fleet--resolve-pane-id (symbol-name agent)))
     (t (signal 'agent-fleet-target-not-found (list :agent agent))))))

(defun agent-fleet--normalize-until (until)
  "Convert UNTIL to a list of status strings.
UNTIL may be a symbol, a string, or a list of either."
  (cond
   ((null until) nil)
   ((consp until)
    (delq nil (mapcar (lambda (s)
                        (cond ((symbolp s) (symbol-name s))
                              ((stringp s) s)
                              (t nil)))
                      until)))
   ((symbolp until) (list (symbol-name until)))
   ((stringp until) (list until))
   (t nil)))

(defun agent-fleet--transport-timeout (timeout-ms)
  "Return a socket timeout in seconds for server TIMEOUT-MS.
The result exceeds the server-side deadline by
`agent-fleet--request-timeout-slack', preventing the protocol layer's
short default timeout from cutting off legitimate agent waits."
  (+ (/ timeout-ms 1000.0) agent-fleet--request-timeout-slack))

(defun agent-fleet-status (agent)
  "Return AGENT's current cached status as a symbol, or nil.
One of idle/working/blocked/done/unknown (PLAN.md §12), read straight
from the Herdr-mirrored cache."
  (let ((a (agent-fleet--find-agent agent)))
    (and a (let ((s (herdr-agent-agent-status a)))
             (and s (intern s))))))


;;; --- Pane provisioning (for agent.start) ----------------------------

(defun agent-fleet--extract-pane-id (result)
  "Extract a pane id from a pane.split / tab.create / pane.current RESULT.
  Tolerant of several result shapes: top-level :pane_id, nested :pane or
:root_pane, a :panes list (last entry), or a :tab envelope."
  (cond
   ((null result) nil)
   ((plist-get result :pane_id) (plist-get result :pane_id))
   ((plist-get result :pane)
    (plist-get (plist-get result :pane) :pane_id))
   ((plist-get result :root_pane)
    (plist-get (plist-get result :root_pane) :pane_id))
   ((plist-get result :panes)
    (let ((panes (plist-get result :panes)))
      (and panes (plist-get (car (last (if (listp panes) panes
                                            (append panes nil))))
                            :pane_id))))
   ((plist-get result :tab)
    (plist-get (plist-get result :tab) :pane_id))
   (t nil)))

(defun agent-fleet--unwrap-agent (result)
  "Return the AgentInfo plist from a Herdr agent-RPC RESULT.
Live Herdr wraps agent results in a typed envelope whose payload is
under `:agent' (`:type \"agent_info\"', `agent_started',
`agent_prompted'); a bare result carries `:pane_id' directly (as in
`session.snapshot' agent entries).  Returns nil if RESULT has neither
\(e.g. a bare `ok' ack)."
  (cond
   ((null result) nil)
   ((plist-member result :pane_id) result)          ; bare AgentInfo
   ((plist-member result :agent) (plist-get result :agent))
   (t nil)))

(defun agent-fleet--unwrap-read (result)
  "Return the PaneReadResult from an `agent.read' RESULT.
Live Herdr wraps it as `:type \"pane_read\"/:read'; a bare result
carries `:text' directly.  Falls back to RESULT itself."
  (cond
   ((null result) nil)
   ((plist-member result :read) (plist-get result :read))
   (t result)))

(defun agent-fleet--create-workspace-provisioning (cwd &optional focus)
  "Create a workspace and return its workspace/root-pane provisioning data.
The live `workspace_created' result contains `:workspace', `:tab', and
`:root_pane'.  Reusing that root pane avoids immediately creating a redundant
second tab.  Returns `(:workspace-id WS :pane-id PANE)' or signals."
  (let* ((params (if cwd
                     `(("focus" . ,(if focus t :false)) ("cwd" . ,cwd))
                   `(("focus" . ,(if focus t :false)))))
         (res (herdr-request "workspace.create" params))
         (workspace (or (plist-get res :workspace)
                        (and (plist-get res :workspace_id) res)))
         (root-pane (or (plist-get res :root_pane)
                        (plist-get res :pane)))
         (workspace-id (plist-get workspace :workspace_id))
         (pane-id (plist-get root-pane :pane_id)))
    (unless workspace-id
      (signal 'agent-fleet-provisioning-failed
              (list :step 'workspace-create :result res)))
    (herdr-model-upsert-workspace workspace)
    (when (and root-pane (herdr-model-cache))
      (herdr-model--upsert-pane (herdr-model-cache) root-pane))
    `(:workspace-id ,workspace-id :pane-id ,pane-id)))

(defun agent-fleet--create-workspace (cwd)
  "Create a Herdr workspace (with CWD if given) and return its id."
  (plist-get (agent-fleet--create-workspace-provisioning cwd) :workspace-id))

(defun agent-fleet--resolve-workspace-id (&optional workspace cwd)
  "Return a workspace id to start an agent in.
WORKSPACE wins if given; else the focused workspace; else a new one
(created with CWD if given)."
  (cond
   (workspace workspace)
   ((herdr-focused-workspace) (herdr-workspace-id (herdr-focused-workspace)))
   (t (agent-fleet--create-workspace cwd))))

(defun agent-fleet--provision-pane (workspace-id cwd focus)
  "Provision an empty interactive shell pane in WORKSPACE-ID.
Splits the focused pane (PLAN.md §16: agent.start needs an interactive
shell pane); if there is no pane to split, creates a fresh tab.  Returns
the new pane id.  Signals `agent-fleet-provisioning-failed'."
  (let* ((focused (herdr-focused-pane))
         ;; The globally focused pane may belong to another project.  Split a
         ;; pane only when it is in the requested workspace; otherwise choose
         ;; another pane from that workspace, or create a tab there.
         (target (or (and focused
                          (equal workspace-id
                                 (herdr-pane-workspace-id focused))
                          focused)
                     (cl-find workspace-id (herdr-panes)
                              :test #'equal
                              :key #'herdr-pane-workspace-id))))
    (if (and target (herdr-pane-id target))
        ;; Split a pane in the target workspace to get a fresh shell prompt.
        (let* ((params `(("direction" . "right")
                         ("workspace_id" . ,workspace-id)
                         ("target_pane_id" . ,(herdr-pane-id target))
                         ("focus" . ,(if focus t :false))
                         ,@(and cwd `(("cwd" . ,cwd)))))
               (res (herdr-request "pane.split" params)))
          (or (agent-fleet--extract-pane-id res)
              ;; Some servers return only a layout; the new pane was
              ;; focused, so pane.current gives its id.
              (agent-fleet--extract-pane-id
               (ignore-errors
                 (herdr-request "pane.current" nil)))
              (signal 'agent-fleet-provisioning-failed
                      (list :step 'pane-split :result res))))
      ;; No pane to split: a fresh tab creates a fresh pane.
      (let* ((params `(("workspace_id" . ,workspace-id)
                       ("focus" . ,(if focus t :false))
                       ,@(and cwd `(("cwd" . ,cwd)))))
             (res (herdr-request "tab.create" params)))
        (or (agent-fleet--extract-pane-id res)
            (agent-fleet--extract-pane-id
             (ignore-errors
               (herdr-request "pane.current" nil)))
            (signal 'agent-fleet-provisioning-failed
                    (list :step 'tab-create :result res)))))))

(cl-defun agent-fleet--provision-worktree (cwd &key branch base focus)
  "Create a Herdr worktree at CWD and return its workspace + root pane.
Calls `worktree.create', which provisions a workspace, a tab, and a root
pane (a shell at the worktree cwd) in one step, so `agent.start' can
target the root pane directly — no separate `pane.split' (PLAN.md §34).
Optional BRANCH/BASE override the default branch selection (nil lets
Herdr decide); FOCUS focuses the new workspace in the Herdr UI.  The
returned worktree and workspace are upserted into the cache immediately,
closing the race before the pushed `worktree_created' event lands (same
reason `agent-fleet-start' upserts the agent).  Returns
\`(:workspace-id WS :pane-id PANE :worktree WT)', or signals
`agent-fleet-provisioning-failed' (step `worktree-create') if the
response lacks a workspace or root pane."
  (let* ((params `(("cwd" . ,cwd)
                   ("focus" . ,(if focus t :false))
                   ,@(and branch `(("branch" . ,branch)))
                   ,@(and base `(("base" . ,base)))))
         (res (herdr-request "worktree.create" params))
         (ws (plist-get res :workspace))
         (pane (plist-get res :root_pane))
         (wt (plist-get res :worktree)))
    (unless (and ws pane (plist-get pane :pane_id))
      (signal 'agent-fleet-provisioning-failed
              (list :step 'worktree-create :result res)))
    (herdr-model-upsert-workspace ws)
    (when wt (herdr-model-upsert-worktree wt))
    `(:workspace-id ,(plist-get ws :workspace_id)
      :pane-id ,(plist-get pane :pane_id)
      :worktree ,wt)))


;;; --- Start ----------------------------------------------------------

(defvar agent-fleet--name-counter 0
  "Monotonic source of default agent names (per Emacs session).")

(defun agent-fleet--fresh-name (kind)
  "Generate a unique default name for an agent of KIND."
  (cl-incf agent-fleet--name-counter)
  (let ((base (if (symbolp kind) (symbol-name kind)
                (or kind "agent"))))
    (format "%s-%d" base agent-fleet--name-counter)))

;;;###autoload
(cl-defun agent-fleet-start (kind &key name cwd workspace pane args
                                     (timeout-ms agent-fleet-start-timeout-ms)
                                     focus worktree branch base)
  "Start a CLI agent of KIND (a symbol like `claude') in a Herdr pane.
Provisions an empty interactive shell pane (splitting the focused pane,
or creating a tab if there is none), then calls `agent.start'.  The
cache is updated immediately from the result and again via the
`pane.agent_detected' event.

With `:worktree t', instead of splitting a pane in an existing workspace,
Herdr creates a git worktree (a separate checkout of the repo at CWD) and
provisions a fresh workspace + root pane there, so the agent works in
isolation (PLAN.md §34).  CWD is required in this mode (a worktree needs a
source repo); BRANCH/BASE optionally override Herdr's default branch.

Keyword args:
  :name        agent name (unique across live agents); auto-generated if nil
  :cwd         working directory for the new pane (required with :worktree)
  :workspace   workspace id to start in (default: focused or created)
  :pane        reuse an existing pane id instead of provisioning one
  :args        list of extra CLI arg strings passed to the agent
  :timeout-ms  startup timeout (Herdr requires > 3000)
  :focus       non-nil to focus the new pane in the Herdr UI
  :worktree    non-nil to start in a fresh git worktree at :cwd (Phase 5)
  :branch      worktree branch override (with :worktree; nil = let Herdr decide)
  :base        worktree base ref override (with :worktree)

Returns the `herdr-agent' struct for the started agent.  Signals an
`agent-fleet-error' (or a `herdr-error') on failure."
  (interactive
   (let* ((kinds (mapcar #'car agent-fleet-agent-executables))
          (kind (intern (completing-read "Agent kind: " kinds nil t)))
          (nm (read-string "Name (empty for auto): ")))
     (list kind :name (and (not (string-empty-p nm)) nm))))
  (agent-fleet--ensure-connected)
  (let ((candidate (if (symbolp kind) (symbol-name kind) kind)))
    (unless (and kind (stringp candidate) (not (string-empty-p candidate)))
      (signal 'agent-fleet-error (list :hint "agent kind must be non-empty"))))
  (unless (and (integerp timeout-ms) (> timeout-ms 3000)
               (<= timeout-ms 300000))
    (signal 'agent-fleet-error
            (list :hint "agent.start timeout_ms must be 3001..300000"
                  :timeout-ms timeout-ms)))
  (unless (or (null args)
              (and (listp args) (cl-every #'stringp args)))
    (signal 'agent-fleet-error
            (list :hint "agent args must be a list of strings" :args args)))
  (let* ((agent-name (or name (agent-fleet--fresh-name kind)))
         (kind-str (if (symbolp kind) (symbol-name kind) kind))
         ;; `:worktree t' provisions an isolated workspace + root pane via
         ;; `worktree.create' (Phase 5), skipping the normal workspace/pane
         ;; resolution.  CWD is required: a worktree needs a source repo.
         (wt-result (when worktree
                      (unless cwd
                        (signal 'agent-fleet-provisioning-failed
                                (list :step 'worktree-cwd)))
                      (agent-fleet--provision-worktree
                       cwd :branch branch :base base :focus focus)))
         (created-workspace
          (when (and (null wt-result) (null pane) (null workspace)
                     (null (herdr-focused-workspace)))
            (agent-fleet--create-workspace-provisioning cwd focus)))
         (ws-id (or (and wt-result (plist-get wt-result :workspace-id))
                    (plist-get created-workspace :workspace-id)
                    workspace
                    ;; An explicit pane is already a complete target.  Do
                    ;; not create an unrelated workspace merely because the
                    ;; cache has no focused workspace.
                    (and (null pane) (herdr-focused-workspace)
                         (herdr-workspace-id (herdr-focused-workspace)))
                    (and (null pane) (agent-fleet--create-workspace cwd))))
         (pane-id (or (and wt-result (plist-get wt-result :pane-id))
                      (plist-get created-workspace :pane-id)
                      pane
                      (agent-fleet--provision-pane ws-id cwd focus)))
         (params `(("name" . ,agent-name)
                   ("kind" . ,kind-str)
                   ("pane_id" . ,pane-id)
                   ("timeout_ms" . ,timeout-ms)
                   ,@(and args `(("args" . ,(vconcat args)))))))
    (herdr--log 'info "starting agent %s (%s) in %s" agent-name kind-str pane-id)
    (let ((completed nil))
      (unwind-protect
          (let* ((result (herdr-request
                          "agent.start" params
                          :timeout (agent-fleet--transport-timeout timeout-ms)))
                 ;; `agent.start' returns an AgentInfo (live:
                 ;; `agent_started' -> :agent).  Unwrap it; if no info came
                 ;; back (e.g. a bare ack), fetch authoritative info.
                 (info (or (agent-fleet--unwrap-agent result)
                           (ignore-errors
                             (agent-fleet--unwrap-agent
                              (herdr-request
                               "agent.get" `(("target" . ,pane-id))))))))
            (when info (herdr-model-upsert-agent-info info))
            (let ((agent (herdr-model-find-agent pane-id)))
              (unless agent
                (signal 'agent-fleet-provisioning-failed
                        (list :pane-id pane-id :result result)))
              ;; Fire the started hook from the authoritative result.  The
              ;; later screen-detection event sees the cached agent and is
              ;; marked replay, so the hook is delivered exactly once.
              (run-hook-with-args 'agent-fleet-agent-started-hook
                                  (agent-fleet--enrich-descriptor nil pane-id))
              (setq completed t)
              agent))
        (unless completed
          ;; Provisioning belongs to this call, so a failed agent.start must
          ;; not leave an empty pane or isolated worktree behind.  Explicit
          ;; caller-owned panes are never closed.  Cleanup errors are kept
          ;; secondary to the original failure.
          (cond
           (created-workspace
            (ignore-errors
              (herdr-request "workspace.close"
                             `(("workspace_id" . ,ws-id))))
            (when (herdr-model-cache)
              (herdr-model--remove-workspace-cascade
               (herdr-model-cache) ws-id)))
           ((and pane-id (or wt-result (null pane)))
            (ignore-errors
              (herdr-request "pane.close" `(("pane_id" . ,pane-id))))))
          (when wt-result
            (ignore-errors
              (herdr-request
               "worktree.remove"
               `(("workspace_id" . ,ws-id) ("force" . :false))))
            (when-let* ((worktree-info (plist-get wt-result :worktree))
                        (path (plist-get worktree-info :path)))
              (herdr-model-remove-worktree path))))))))


;;; --- Prompt / Wait / Read ------------------------------------------

;;;###autoload
(defun agent-fleet-prompt (agent text)
  "Send TEXT to AGENT via `agent.prompt' (no wait).
AGENT is a name, pane id, symbol, or `herdr-agent' struct.  Returns the
agent's AgentInfo plist (the `agent_prompted' result, unwrapped from its
envelope).  The agent may keep working after this returns; use
`agent-fleet-wait' or the status hooks to observe completion.
See PLAN.md §18."
  (interactive
   (list (agent-fleet--read-agent-name "Prompt agent")
         (read-string "Prompt: ")))
  (agent-fleet--ensure-connected)
  (agent-fleet--unwrap-agent
   (herdr-request "agent.prompt"
                  `(("target" . ,(agent-fleet--resolve-target agent))
                    ("text" . ,text)))))

;;;###autoload
(cl-defun agent-fleet-prompt-and-wait (agent text &key
                                                (until agent-fleet-default-wait-until)
                                                (timeout-ms agent-fleet-wait-timeout-ms))
  "Atomically submit TEXT and wait for AGENT to reach a status.
Uses a single `agent.prompt' request with a `wait' field, so submit+wait
is server-side atomic — avoiding the race where the agent finishes
between a separate prompt and wait (PLAN.md §19).  UNTIL is a status
symbol or list (default `agent-fleet-default-wait-until').  Returns the
agent's AgentInfo plist (unwrapped); its `:agent_status' is the wait
outcome."
  (interactive
   (list (agent-fleet--read-agent-name "Prompt and wait for agent")
         (read-string "Prompt: ")))
  (agent-fleet--ensure-connected)
  (let ((target (agent-fleet--resolve-target agent))
        (until-list (agent-fleet--normalize-until until)))
    (agent-fleet--unwrap-agent
     (herdr-request "agent.prompt"
                    `(("target" . ,target)
                      ("text" . ,text)
                      ("wait" . (("until" . ,(vconcat until-list))
                                 ("timeout_ms" . ,timeout-ms))))
                    :timeout (agent-fleet--transport-timeout timeout-ms)))))

;;;###autoload
(cl-defun agent-fleet-read (agent &key
                                    (source agent-fleet-default-read-source)
                                    (lines agent-fleet-default-read-lines)
                                    (format agent-fleet-default-read-format)
                                    (strip-ansi (eq format 'text)))
  "Read AGENT's terminal output via `agent.read'.
Returns a PaneReadResult plist: (:pane_id :workspace_id :tab_id :source
:format :text :revision :truncated), unwrapped from the `pane_read'
envelope.  Defaults to `recent_unwrapped' output (ignores soft wrapping;
best for logs — PLAN.md §22).  Interactively, display the snapshot in the
read-only output buffer rather than discarding the returned plist."
  (interactive (list (agent-fleet--read-agent-name "Read output for agent")))
  (if (called-interactively-p 'interactive)
      (agent-fleet-show-output agent lines source)
    (agent-fleet--ensure-connected)
    (agent-fleet--unwrap-read
     (herdr-request "agent.read"
                    `(("target" . ,(agent-fleet--resolve-target agent))
                      ("source" . ,(if (symbolp source) (symbol-name source) source))
                      ("lines" . ,lines)
                      ("format" . ,(if (symbolp format) (symbol-name format) format))
                      ("strip_ansi" . ,(if strip-ansi t :false)))))))

;;;###autoload
(cl-defun agent-fleet-wait (agent &optional until &key
                                     (timeout-ms agent-fleet-wait-timeout-ms))
  "Wait for AGENT to reach one of the UNTIL statuses via `agent.wait'.
UNTIL is a status symbol or list (default `agent-fleet-default-wait-until').
This is a single blocking RPC, NOT polling (PLAN.md §25): Emacs stays
responsive because the protocol layer pumps `accept-process-output' during
the wait, which also keeps the live cache in step.  Returns the agent's
AgentInfo plist (unwrapped); its `:agent_status' is the outcome."
  (interactive (list (agent-fleet--read-agent-name "Wait for agent")))
  (agent-fleet--ensure-connected)
  (let ((target (agent-fleet--resolve-target agent))
        (until-list (agent-fleet--normalize-until
                     (or until agent-fleet-default-wait-until))))
    (agent-fleet--unwrap-agent
     (herdr-request "agent.wait"
                    `(("target" . ,target)
                      ("until" . ,(vconcat until-list))
                      ("timeout_ms" . ,timeout-ms))
                    :timeout (agent-fleet--transport-timeout timeout-ms)))))


;;; --- Keys / Interrupt ----------------------------------------------

;;;###autoload
(defun agent-fleet-send-keys (agent keys)
  "Send KEYS to AGENT via `agent.send_keys' (Level 2 input, PLAN.md §20).
KEYS is a single key-notation string (\"ctrl+c\", \"enter\", \"esc\",
\"shift+tab\", \"f1\", ...) or a list of them.  Returns the agent's
AgentInfo plist if the server returned one, else the raw ack."
  (interactive
   (list (agent-fleet--read-agent-name "Send keys to agent")
         (read-string "Keys (for example ctrl+c or enter): ")))
  (agent-fleet--ensure-connected)
  (let ((key-list (if (stringp keys) (list keys)
                    (delq nil keys))))
    (let ((res (herdr-request "agent.send_keys"
                              `(("target" . ,(agent-fleet--resolve-target agent))
                                ("keys" . ,(vconcat key-list))))))
      ;; The live result shape is not verified; tolerate either an
      ;; `agent_info' envelope (unwrap) or a bare `ok' ack (return as-is).
      (or (agent-fleet--unwrap-agent res) res))))

;;;###autoload
(defun agent-fleet-interrupt (agent)
  "Interrupt AGENT by sending Ctrl-C via `agent.send_keys'.
This is `interrupt', not `cancel': different CLIs attach different
semantics to Ctrl-C, so we expose the key directly (PLAN.md §21).
Returns the agent's AgentInfo plist if the server returned one, else the
raw ack."
  (interactive (list (agent-fleet--read-agent-name "Interrupt agent")))
  (agent-fleet--ensure-connected)
  (let ((res (herdr-request "agent.send_keys"
                            `(("target" . ,(agent-fleet--resolve-target agent))
                              ("keys" . ,(vector "ctrl+c"))))))
    (or (agent-fleet--unwrap-agent res) res)))


;;; --- Rename / Kill / Switch / List / Get ---------------------------

;;;###autoload
(defun agent-fleet-rename (agent name)
  "Rename AGENT to NAME (a string) via `agent.rename'.
Refreshes the cached agent so `agent-fleet-list' reflects the new name.
Returns the renamed agent's AgentInfo plist (unwrapped)."
  (interactive
   (let* ((target (agent-fleet--read-agent-name "Rename agent"))
          (cached (agent-fleet--find-agent target))
          (current (and cached (herdr-agent-display-name cached))))
     (list target (read-string "New name: " current))))
  (agent-fleet--ensure-connected)
  (unless (stringp name)
    (signal 'agent-fleet-error
            (list :hint "rename requires a string name")))
  (let ((target (agent-fleet--resolve-target agent)))
    (let ((res (herdr-request "agent.rename"
                              `(("target" . ,target) ("name" . ,name)))))
      ;; Refresh the cached struct from the authoritative info (the rename
      ;; event may lag); unwrap the `agent_info' envelope.
      (ignore-errors
        (herdr-model-upsert-agent-info
         (agent-fleet--unwrap-agent
          (herdr-request "agent.get" `(("target" . ,target))))))
      (agent-fleet--unwrap-agent res))))

;;;###autoload
(defun agent-fleet-kill (agent)
  "Kill AGENT by closing its pane via `pane.close'.
The agent process is terminated with the pane.  The cache is updated
eagerly (the `pane_closed' event also removes it).  Returns the result."
  (interactive
   (let ((target (agent-fleet--read-agent-name "Kill agent")))
     (unless (y-or-n-p (format "Kill agent %s? " target))
       (user-error "Canceled"))
     (list target)))
  (agent-fleet--ensure-connected)
  (let* ((pane-id (agent-fleet--resolve-pane-id agent))
         (res (herdr-request "pane.close" `(("pane_id" . ,pane-id)))))
    ;; Eager cache removal; the `pane_closed' event also removes it and
    ;; fires `agent-fleet-agent-exited-hook' (PLAN §25-26).  We do not
    ;; fire the hook here, so each exit notifies exactly once.
    (herdr-model-remove-agent pane-id)
    res))

;;;###autoload
(defun agent-fleet-switch (agent)
  "Focus AGENT's pane in the Herdr UI via `agent.focus'.
Returns the focused agent's AgentInfo plist (unwrapped)."
  (interactive (list (agent-fleet--read-agent-name "Focus agent")))
  (agent-fleet--ensure-connected)
  (agent-fleet--unwrap-agent
   (herdr-request "agent.focus" `(("target" . ,(agent-fleet--resolve-target agent))))))

(defun agent-fleet--agent-list-from-result (result)
  "Normalize an `agent.list' RESULT into a list of AgentInfo plists.
Live Herdr returns `(:type \"agent_list\" :agents [...])'; also tolerates
a bare array or a single AgentInfo plist.  The `:agents' check comes
before the bare-single-AgentInfo check because the envelope's car is
`:type' (a keyword)."
  (cond
   ((null result) nil)
   ((plist-member result :agents)              ; envelope: (:type "agent_list" :agents ...)
    (let ((a (plist-get result :agents)))
      (cond ((listp a) a) ((vectorp a) (append a nil)) (t nil))))
   ((vectorp result) (append result nil))
   ((not (listp result)) nil)
   ((keywordp (car result)) (list result))     ; bare single AgentInfo
   (t result)))

(defun agent-fleet--list-label (agent)
  "Return a one-line label for AGENT as Herdr's sidebar shows it.
`{display-name} · {kind}' — the display name (workspace identity, or an
explicit name when assigned) plus the agent kind, which disambiguates
agents sharing one workspace (e.g. a Claude and a Codex in the same
project).  Falls back to the display name alone when the kind is nil."
  (let ((name (herdr-agent-display-name agent))
        (kind (herdr-agent-agent agent)))
    (if (and kind (not (string-empty-p kind)))
        (format "%s · %s" name kind)
      name)))

;;;###autoload
(defun agent-fleet-list (&optional refresh)
  "Return the cached agent structs as a list.
With non-nil REFRESH, first refresh the cache from `agent.list'.  The
cache is normally kept live by events, so REFRESH is only needed after
operations Herdr does not notify about (PLAN.md §25).
An interactive call, or a REFRESH call, tries the configured automatic
connection first.  It still returns nil rather than signalling when the
server is unavailable, so cache inspection remains safe while offline.
When called interactively, also message the count or connection state."
  (interactive "P")
  (when (or refresh (called-interactively-p 'any))
    (ignore-errors (agent-fleet--ensure-connected)))
  (when refresh
    (ignore-errors
      (let ((infos (agent-fleet--agent-list-from-result
                    (herdr-request "agent.list" nil))))
        ;; agent.list is authoritative, not a stream of deltas.  Replacing
        ;; the table removes agents whose close event was missed while Emacs
        ;; was suspended or disconnected; merely upserting retained ghosts
        ;; in the dashboard forever.
        (when-let* ((session (herdr-model-cache)))
          (clrhash (herdr-session-agents session)))
        (dolist (info infos)
          (herdr-model-upsert-agent-info info)))))
  (let ((agents (herdr-agents)))
    (when (called-interactively-p 'any)
      (cond
       ((null (herdr-model-cache))
        (message "Not connected to Herdr; a control command will connect on demand"))
       (agents
        (message "%d agent(s): %s"
                 (length agents)
                 (mapconcat #'agent-fleet--list-label agents ", ")))
       (t
        (message "No agents"))))
    agents))

;;;###autoload
(defun agent-fleet-get (agent)
  "Fetch AGENT's authoritative AgentInfo via `agent.get' and cache it.
Returns the `herdr-agent' struct, or nil if the server returned no info.
Unwraps the `agent_info' envelope before caching."
  (agent-fleet--ensure-connected)
  (let* ((target (agent-fleet--resolve-target agent))
         (info (agent-fleet--unwrap-agent
                (herdr-request "agent.get" `(("target" . ,target))))))
    (when info
      (herdr-model-upsert-agent-info info))
    (and info (herdr-model-find-agent (plist-get info :pane_id)))))


;;; --- Output viewer (read snapshot, PLAN.md §23) --------------------

(defun agent-fleet--read-agent-name (prompt)
  "Read an agent pane id from the minibuffer, completing over cached agents.
Candidates are `herdr-agent-display-name' labels (the workspace identity,
falling back to the cwd basename, terminal title, or pane id when the
agent has no name), disambiguated with the pane id in brackets when two
agents share a label.  Returns the pane id so it round-trips through
`agent-fleet--find-agent'."
  (let* ((agents (herdr-agents))
         (counts (let ((h (make-hash-table :test 'equal)))
                   (dolist (a agents)
                     (let ((l (herdr-agent-display-name a)))
                       (puthash l (1+ (gethash l h 0)) h)))
                   h))
         (alist (mapcar (lambda (a)
                          (let ((label (herdr-agent-display-name a)))
                            (cons (if (> (gethash label counts 0) 1)
                                      (format "%s  [%s]" label (herdr-agent-id a))
                                    label)
                                  (herdr-agent-id a))))
                        agents))
         (default (and alist (caar alist))))
    (unless alist
      (user-error "No agents are available"))
    (cdr (assoc (completing-read (if default
                                     (format "%s (default %s): " prompt default)
                                   (concat prompt ": "))
                                 alist nil t nil nil default)
                alist))))

;;;###autoload
(defun agent-fleet-show-output (agent &optional lines source)
  "Read AGENT's recent output and display it in a read-only buffer.
Opens `*Agent Output: <name>*' with the text from `agent.read'.  This is
a read-snapshot view, NOT a continuously mirrored terminal (PLAN.md §23).
With a prefix arg, prompt for the line count."
  (interactive
   (list (agent-fleet--read-agent-name "Show output for agent")
         (and current-prefix-arg
              (read-number "Lines: " agent-fleet-default-read-lines))))
  (agent-fleet--ensure-connected)
  (let* ((struct (or (agent-fleet--find-agent agent)
                     (signal 'agent-fleet-target-not-found
                             (list :agent agent))))
         (name (herdr-agent-display-name struct))
         (res (agent-fleet-read agent
                                :lines (or lines agent-fleet-default-read-lines)
                                :source (or source agent-fleet-default-read-source)))
         (text (or (plist-get res :text) ""))
         (buf-name (concat agent-fleet-output-buffer-prefix name "*")))
    (with-current-buffer (get-buffer-create buf-name)
      (read-only-mode -1)
      (erase-buffer)
      (insert text)
      (goto-char (point-min))
      (read-only-mode 1)
      (set-buffer-modified-p nil))
    (display-buffer buf-name)
    res))


;;; --- Hook bus (PLAN.md §26) ----------------------------------------

;; These bridge the Phase 1 `herdr-event-*-hook' variables into the
;; agent-fleet-facing hook set.  Each receives a descriptor plist
;; (:event :what :id :status :name :kind ...).

(defvar agent-fleet-agent-started-hook nil
  "Hook run when an agent is started or detected.
Receives a descriptor plist (:pane-id :name :kind :status ...).")

(defvar agent-fleet-agent-status-changed-hook nil
  "Hook run on every agent status transition.  Receives the descriptor.")

(defvar agent-fleet-agent-blocked-hook nil
  "Hook run when an agent becomes blocked.  Receives the descriptor.")

(defvar agent-fleet-agent-done-hook nil
  "Hook run when an agent becomes done.  Receives the descriptor.")

(defvar agent-fleet-agent-exited-hook nil
  "Hook run when an agent's pane is closed or exited.  Receives the descriptor.")

(defun agent-fleet--enrich-descriptor (descriptor pane-id)
  "Surface PANE-ID as :pane-id and add :name/:kind from the cache.
The raw model descriptor carries the entity id under :id; agent-fleet
hooks document :pane-id as the public key, so we always add it.  :name
\(via `herdr-agent-display-name', the workspace identity, falling back to
the cwd basename / terminal title when the agent has no name) and :kind
are filled when the agent is still cached (an exited agent may already
have been removed eagerly)."
  (let ((agent (or (plist-get descriptor :agent)
                   (and pane-id (herdr-model-find-agent pane-id)))))
    (append descriptor
            `(:pane-id ,pane-id
              ,@(when agent
                  `(:name ,(herdr-agent-display-name agent)
                    :kind ,(herdr-agent-agent agent)))))))

(defun agent-fleet--on-agent-status (descriptor)
  "Bridge `herdr-event-agent-status-hook' to the agent-fleet hooks."
  (let* ((pane-id (plist-get descriptor :id))
         (status (plist-get descriptor :status))
         (enriched (agent-fleet--enrich-descriptor descriptor pane-id)))
    (run-hook-with-args 'agent-fleet-agent-status-changed-hook enriched)
    (pcase status
      ("blocked" (run-hook-with-args 'agent-fleet-agent-blocked-hook enriched))
      ("done"    (run-hook-with-args 'agent-fleet-agent-done-hook enriched))
      (_ nil))))

(defun agent-fleet--on-pane-event (descriptor)
  "Bridge pane events to agent-fleet hooks (started / exited).
A `pane_agent_detected' for a pane that is ALREADY cached (e.g. an
agent started via `agent.start', whose result was upserted before the
async detection event arrives) or marked gone carries `:replayp'; the
started hook was already fired by `agent-fleet-start' (or the pane is
dead), so skip it to notify exactly once.  A first-time screen
detection (no `:replayp') — an agent NOT started via the RPC, e.g. a
TUI-spawned agent — fires the started hook here, its only signal."
  (pcase (plist-get descriptor :what)
    (:agent-detected
     (unless (plist-get descriptor :replayp)
       (run-hook-with-args 'agent-fleet-agent-started-hook
                           (agent-fleet--enrich-descriptor
                            descriptor (plist-get descriptor :id)))))
    (:pane-closed
     (when (and (plist-get descriptor :agentp)
                (not (plist-get descriptor :replayp)))
       (run-hook-with-args 'agent-fleet-agent-exited-hook
                           (agent-fleet--enrich-descriptor
                            descriptor (plist-get descriptor :id)))))
    (_ nil)))

(defun agent-fleet--setup-hooks ()
  "Install the agent-fleet bridge on the Herdr event hooks (idempotent)."
  (unless (memq #'agent-fleet--on-agent-status herdr-event-agent-status-hook)
    (add-hook 'herdr-event-agent-status-hook #'agent-fleet--on-agent-status))
  (unless (memq #'agent-fleet--on-pane-event herdr-event-pane-hook)
    (add-hook 'herdr-event-pane-hook #'agent-fleet--on-pane-event)))

(agent-fleet--setup-hooks)
(agent-fleet--configure-auto-connect)


;;; --- Doctor ---------------------------------------------------------

(defun agent-fleet--doctor-agent-checks ()
  "Return doctor check triples for agent CLIs and Herdr manifests."
  (let (checks)
    (dolist (entry agent-fleet-agent-executables)
      (let* ((exe (cadr entry))
             (label (format "%s executable" (caddr entry)))
             (found (executable-find exe)))
        (push (herdr--doctor-check
               label (and found t)
               (if found (format "on PATH (%s)" exe)
                 (format "not on PATH (%s)" exe)))
              checks)))
    (let ((detail "") (ok nil))
      (condition-case err
          (let* ((res (ignore-errors (herdr-request "server.agent_manifests" nil)))
                 (raw (and (listp res) (plist-get res :manifests)))
                 (manifests (cond
                             ((vectorp raw) (append raw nil))
                             ((listp raw) raw)
                             ((vectorp res) (append res nil))
                             ((and (listp res)
                                   (not (keywordp (car res)))) res)
                             (t nil))))
            (setq ok (and res t))
            (setq detail (if manifests
                             (mapconcat
                              (lambda (m) (or (plist-get m :agent) "?"))
                              manifests ", ")
                           (if res "none loaded" "no response"))))
        (error
         (setq detail (error-message-string err))))
      (push (herdr--doctor-check
             "Agent manifests (Herdr)" ok
             (if ok detail (format "unreachable: %s" detail)))
            checks))
    (nreverse checks)))

;;;###autoload
(defun agent-fleet-doctor ()
  "Check the Herdr + agent environment and show a report.
Runs the `herdr-doctor' checks plus agent CLI executables and the Herdr
agent manifests.  See PLAN.md §14."
  (interactive)
  (herdr--doctor-render
   (append (herdr--doctor-checks) (agent-fleet--doctor-agent-checks))
   "*agent-fleet-doctor*" "Agent Fleet Doctor"))


(provide 'agent-fleet)

;; Loading the package: requiring `agent-fleet' (the package's main file)
;; also brings in the dashboard and every feature module, so a bare
;; `(use-package agent-fleet)' or `(require 'agent-fleet)' makes ALL
;; commands available -- `agent-fleet-attach', `agent-fleet-parallel',
;; `agent-fleet-worktree-*', `agent-fleet-magit-*', `agent-fleet-start-for-
;; project', and the `agent-fleet' dashboard.  Without this, requiring only
;; the base control plane leaves the feature modules unloaded and their
;; commands void (PLAN §45 layers are separate files).  This require sits
;; AFTER `provide' so the one-way require chain (each feature module
;; requires `agent-fleet') does not re-enter this file -- `agent-fleet' is
;; already on `features' when the dashboard requires it.  Optional deps
;; (magit/eat/ghostel/vterm) are still guarded inside each module
;; (`declare-function' + `--available-p'); nothing here hard-requires them.
(defun agent-fleet--load-feature-modules ()
  "Load the dashboard and feature modules, leaving no false feature on error.
`agent-fleet' must be provided first to break the intentional one-way load
cycle: the dashboard's feature modules require the already-defined control
plane.  If a required dependency or module then fails, remove that early
feature marker before re-signalling.  A later `(require \='agent-fleet)' can
therefore retry the load instead of silently accepting a half-loaded package."
  (condition-case err
      (require 'agent-fleet-dashboard)
    (error
     (setq features (delq 'agent-fleet features))
     (signal (car err) (cdr err)))))

(agent-fleet--load-feature-modules)

;;; agent-fleet.el ends here
