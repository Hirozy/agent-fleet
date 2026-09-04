;;; agent-fleet-editor.el --- external-editor bridge for live attaches -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.1.0
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

;; Optional bridge for CLI agents that use $EDITOR to edit their current
;; prompt draft after C-g.  Agent Fleet does not implement an editor helper or
;; parse terminal output: it arms a one-shot route for the next Emacs server
;; file visit, sends C-g to the exact Herdr pane, and displays the file in a
;; newly created standalone graphical frame while keeping the recorded attach
;; frame and window unchanged.
;;
;; The bridge is deliberately opt-in.  Agent Fleet assigns EDITOR/VISUAL when
;; it provisions an ordinary agent pane; agents started in caller-owned panes
;; or `worktree.create' root panes inherit their existing environment.  The
;; route is a short-lived association between one attach buffer and the next
;; server file visit; it is not a general server multiplexer and cannot
;; disambiguate two simultaneous C-g requests.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function server-running-p "server" ())
(declare-function server-start "server" ())
(declare-function server-buffer-done "server" (buffer &optional for-killing))
(defvar server-window)
(defvar server-process)
(defvar server-name)
(defvar-local server-buffer-clients nil)

(declare-function agent-fleet-attach--current-pane-id
                  "agent-fleet-attach" ())
(declare-function agent-fleet-send-keys "agent-fleet" (agent keys))
(declare-function agent-fleet-display-origin-frame
                  "agent-fleet-display" (&optional frame))

(defgroup agent-fleet-editor nil
  "External-editor integration for Agent Fleet attach buffers."
  :group 'agent-fleet)

(defcustom agent-fleet-editor-auto-start-server t
  "Whether enabling the editor bridge may start an Emacs server.

When non-nil, `agent-fleet-editor-bridge-mode' calls `server-start' if this
Emacs does not own a running server.  When nil, enabling the mode signals a
clear error and leaves the mode disabled.  A server owned by this Emacs is
always reused and its `server-name' is never changed.  Disabling the bridge
never stops a server."
  :type 'boolean
  :group 'agent-fleet-editor)

(defcustom agent-fleet-editor-route-timeout 30.0
  "Seconds to keep a pending external-editor route alive.

The route is consumed by the first matching server file visit.  This is a
one-shot timer, not a polling loop; a non-positive value is treated as 0.1
seconds when arming a route."
  :type 'number
  :group 'agent-fleet-editor)

(defcustom agent-fleet-editor-frame-parameters
  '((name . "Agent Fleet Editor")
    (width . 100)
    (height . 35)
    (minibuffer . t))
  "Frame parameters for standalone external-editor frames.

The bridge always creates a top-level frame with `make-frame'; any configured
`parent-frame' parameter is ignored so that this presentation cannot become a
child frame."
  :type '(repeat (cons (symbol :tag "Parameter")
                       (sexp :tag "Value")))
  :group 'agent-fleet-editor)

(defconst agent-fleet-editor--header-line-hint
  "C-c C-c submit, C-c C-k abort"
  "The exact instruction shown in an active external-editor buffer.")

(defvar agent-fleet-editor--pending-route nil
  "The one pending external-editor route, or nil.")

(defvar agent-fleet-editor--active-requests nil
  "List of active external-editor request plists.

Each request owns one server buffer and one presentation.  This list exists
so disabling the global bridge can release every waiting editor client; the
buffer-local request value remains the source of truth for local hooks.")

(defvar-local agent-fleet-editor--request nil
  "The external-editor request owned by the current server buffer, or nil.")

(defvar agent-fleet-editor-bridge-mode nil
  "Non-nil when the Agent Fleet external-editor bridge is enabled.")

(defvar-keymap agent-fleet-editor-buffer-mode-map
  :doc "Keymap for an Agent Fleet external-editor server buffer."
  "C-c C-c" #'agent-fleet-editor-submit
  "C-c C-k" #'agent-fleet-editor-abort)

(define-minor-mode agent-fleet-editor-buffer-mode
  "Buffer-local mode for an external editor file opened by Agent Fleet.
`C-c C-c' saves and releases the waiting `emacsclient'; `C-c C-k' aborts
without saving.  The mode is installed only on server buffers routed from an
attach terminal."
  :init-value nil
  :lighter " Fleet-Edit"
  :keymap agent-fleet-editor-buffer-mode-map)

(defun agent-fleet-editor--local-server-live-p ()
  "Return non-nil when this Emacs owns a live server process.
`server-running-p' can report a server owned by another Emacs, so it is not
enough to decide whether `emacsclient' requests will arrive here."
  (and (boundp 'server-process)
       (processp server-process)
       (process-live-p server-process)))

(defun agent-fleet-editor--ensure-server ()
  "Load and ensure an Emacs server for the editor bridge.
Return non-nil when a server is running.  This function does not change
`server-name' and never starts a server unless the caller has enabled the
bridge with `agent-fleet-editor-auto-start-server'."
  (require 'server)
  (cond
   ((agent-fleet-editor--local-server-live-p) t)
   ((server-running-p)
    (user-error
     "An Emacs server named %s belongs to another Emacs; stop it or set a different server-name before enabling the bridge"
     server-name))
   ((not agent-fleet-editor-auto-start-server)
    (user-error
     "Agent Fleet editor bridge needs this Emacs's server; run M-x server-start first"))
   (t
    (condition-case err
        (progn
          (server-start)
          (if (agent-fleet-editor--local-server-live-p)
              t
            (user-error "This Emacs did not start a live server process")))
      (user-error (signal (car err) (cdr err)))
      (error
       (user-error "Could not start this Emacs's server: %s"
                   (error-message-string err)))))))

(defun agent-fleet-editor--origin-window (origin)
  "Return a usable window in ORIGIN, or nil.
Prefer the selected window when it already belongs to ORIGIN; otherwise use
the origin frame's selected window.  This keeps a route armed from an
auxiliary child from accidentally recording that child as the destination."
  (let ((selected (selected-window)))
    (cond
     ((and (window-live-p selected)
           (eq (window-frame selected) origin))
      selected)
     ((frame-live-p origin)
      (frame-selected-window origin)))))

(defun agent-fleet-editor--route-dispatcher (route)
  "Return the unique `server-window' dispatcher for ROUTE."
  (lambda (buffer)
    (agent-fleet-editor--dispatch-server-buffer buffer route)))

(defun agent-fleet-editor--restore-server-window (route)
  "Restore ROUTE's previous `server-window' if it is still installed.
If another component replaced the dispatcher while ROUTE was pending, leave
that newer value alone."
  (let ((dispatcher (plist-get route :dispatcher)))
    (when (and (boundp 'server-window)
               (eq server-window dispatcher))
      (setq server-window (plist-get route :previous-server-window)))))

(defun agent-fleet-editor--cancel-route-timer (route)
  "Cancel ROUTE's one-shot timer, if it is still live."
  (when-let* ((timer (plist-get route :timer)))
    (when (timerp timer)
      (cancel-timer timer))
    (setf (plist-get route :timer) nil)))

(defun agent-fleet-editor--clear-pending-route (route &optional message)
  "Clear pending ROUTE and restore `server-window'.
Only the currently pending route can clear the global route.  MESSAGE, when
non-nil, is displayed after cleanup."
  (when (eq route agent-fleet-editor--pending-route)
    (agent-fleet-editor--cancel-route-timer route)
    (agent-fleet-editor--restore-server-window route)
    (setq agent-fleet-editor--pending-route nil)
    (when message
      (message "agent-fleet: %s" message))))

(defun agent-fleet-editor--route-timeout (route)
  "Expire pending ROUTE after its one-shot timeout."
  (when (eq route agent-fleet-editor--pending-route)
    (agent-fleet-editor--clear-pending-route route
                                              "editor request timed out")))

(defun agent-fleet-editor--record-origin ()
  "Return a route origin plist for the selected attach buffer."
  (require 'agent-fleet-display)
  (let* ((origin (agent-fleet-display-origin-frame (selected-frame)))
         (window (agent-fleet-editor--origin-window origin)))
    (list :origin-frame origin
          :origin-window window
          :origin-buffer (and (window-live-p window)
                              (window-buffer window)))))

(defun agent-fleet-editor--arm-route (pane-id origin-info)
  "Arm a one-shot editor route for PANE-ID and ORIGIN-INFO.
ORIGIN-INFO is a plist produced by `agent-fleet-editor--record-origin'.
The route installs a temporary `server-window' function and returns the
route.  Signal `user-error' when another route is pending.  This is an
internal helper; use `agent-fleet-editor-arm-current-attach' interactively."
  (require 'server)
  (unless (and agent-fleet-editor-bridge-mode
               (agent-fleet-editor--local-server-live-p))
    (user-error "Agent Fleet editor bridge is not enabled with this Emacs's running server"))
  (when agent-fleet-editor--pending-route
    (user-error "An external-editor request is already pending"))
  (let* ((route (append (list :pane-id pane-id
                              :previous-server-window server-window
                              :dispatcher nil
                              :timer nil)
                        origin-info))
         (dispatcher (agent-fleet-editor--route-dispatcher route)))
    (setf (plist-get route :dispatcher) dispatcher)
    (setq server-window dispatcher)
    (setf (plist-get route :timer)
          (run-at-time (max 0.1 agent-fleet-editor-route-timeout)
                       nil #'agent-fleet-editor--route-timeout route))
    (setq agent-fleet-editor--pending-route route)
    route))

(defun agent-fleet-editor-arm-current-attach ()
  "Arm the editor bridge and send C-g to the current attach pane.
The pane id is read from the attach buffer's stable local identity.  No
Enter or other terminal key is injected.  If the Herdr send fails, the route
is removed and the prior `server-window' value is restored."
  (interactive)
  (unless agent-fleet-editor-bridge-mode
    (user-error "Agent Fleet editor bridge is not enabled"))
  (when agent-fleet-editor--active-requests
    (user-error "Finish the current external-editor request before starting another"))
  (let* ((pane-id (agent-fleet-attach--current-pane-id))
         (origin-info (agent-fleet-editor--record-origin))
         (route (agent-fleet-editor--arm-route pane-id origin-info)))
    (condition-case err
        (progn
          ;; Use the shared control-plane API and stable pane id.  This sends
          ;; exactly Ctrl-G to Herdr; it does not synthesize Enter.
          (agent-fleet-send-keys pane-id "ctrl+g")
          (message "agent-fleet: waiting for external editor request"))
      (error
       (agent-fleet-editor--clear-pending-route
        route "could not send Ctrl-G; editor route cleared")
       (signal (car err) (cdr err))))
    route))

(defun agent-fleet-editor--call-server-window (spec buffer)
  "Display BUFFER using the prior server-window SPEC.
This mirrors the useful cases of Emacs's server dispatcher for an unrelated
visit that arrives while a route is pending."
  (cond
   ((functionp spec) (funcall spec buffer))
   ((window-live-p spec)
    (set-window-buffer spec buffer)
    (select-window spec))
   ((frame-live-p spec)
    (select-frame-set-input-focus spec)
    (set-window-buffer (frame-selected-window spec) buffer))
   (t
    (switch-to-buffer buffer))))

(defun agent-fleet-editor--install-header-line (request buffer)
  "Install the editor hint in BUFFER and save its previous local state.
The previous value is restored by `agent-fleet-editor--restore-header-line',
including the distinction between an inherited and a buffer-local value."
  (with-current-buffer buffer
    (setf (plist-get request :header-line-local-p)
          (local-variable-p 'header-line-format buffer)
          (plist-get request :header-line-format)
          (and (local-variable-p 'header-line-format buffer)
               header-line-format)
          (plist-get request :header-line-saved-p) t)
    (setq-local header-line-format agent-fleet-editor--header-line-hint)))

(defun agent-fleet-editor--restore-header-line (request buffer)
  "Restore the header-line state saved for REQUEST in BUFFER.
This operation is idempotent and is safe when BUFFER has already been
killed."
  (when (plist-get request :header-line-saved-p)
    (unwind-protect
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (if (plist-get request :header-line-local-p)
                (setq-local header-line-format
                            (plist-get request :header-line-format))
              (kill-local-variable 'header-line-format))))
      (setf (plist-get request :header-line-saved-p) nil))))

(defun agent-fleet-editor--remove-request-hooks (buffer)
  "Remove editor lifecycle hooks from BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (remove-hook 'kill-buffer-hook #'agent-fleet-editor--buffer-killed t)
      (remove-hook 'server-done-hook #'agent-fleet-editor--server-done t)
      (when (bound-and-true-p agent-fleet-editor-buffer-mode)
        (agent-fleet-editor-buffer-mode -1))
      (setq-local agent-fleet-editor--request nil))))

(defun agent-fleet-editor--release-server-buffer (buffer &optional for-killing)
  "Release BUFFER's waiting server client successfully.
Use the supported `server-buffer-done' API so both submit and abort complete
the invoking `emacsclient' with a successful exit status.  The caller decides
whether to save BUFFER before releasing it."
  (when (and (buffer-live-p buffer)
             (boundp 'server-buffer-clients))
    (with-current-buffer buffer
      (when server-buffer-clients
        (server-buffer-done buffer for-killing)))))

(defun agent-fleet-editor--focus-origin (request)
  "Return focus to REQUEST's recorded origin when it is still usable."
  (let ((origin-window (plist-get request :origin-window))
        (origin-frame (plist-get request :origin-frame)))
    (cond
     ((window-live-p origin-window)
      (select-frame-set-input-focus (window-frame origin-window))
      (select-window origin-window))
     ((frame-live-p origin-frame)
      (select-frame-set-input-focus origin-frame)))))

(defun agent-fleet-editor--close-presentation
    (request &optional deleting-origin deleting-presentation)
  "Close REQUEST's standalone editor frame and restore the origin focus.
DELETING-ORIGIN means the recorded origin frame is already being deleted, so
focus cannot be restored there.  DELETING-PRESENTATION means the editor frame
is already in its own deletion hook and must not be deleted recursively.
Regardless of either flag, the request's presentation fields are cleared in
an `unwind-protect' so cleanup remains idempotent."
  (unwind-protect
      (pcase (plist-get request :presentation)
        ('frame
         (let ((frame (plist-get request :presentation-frame)))
           (when (and (not deleting-presentation)
                      (frame-live-p frame)
                      (plist-get request :presentation-created-p))
             (delete-frame frame)))))
    ;; Focus restoration is best-effort cleanup.  In particular, a failed
    ;; `delete-frame' must not prevent the request from dropping ownership or
    ;; from trying to return the user to the attach frame.
    (unless deleting-origin
      (ignore-errors (agent-fleet-editor--focus-origin request)))
    (setf (plist-get request :presentation) nil
          (plist-get request :presentation-frame) nil
          (plist-get request :presentation-window) nil
          (plist-get request :presentation-created-p) nil)))

(defun agent-fleet-editor--unregister-request (request &optional _deleting-frame)
  "Remove REQUEST from the active request list."
  (setq agent-fleet-editor--active-requests
        (delq request agent-fleet-editor--active-requests)))

(defun agent-fleet-editor--finish-request
    (request status &optional from-killing deleting-origin deleting-presentation)
  "Finish REQUEST with STATUS, returning non-nil on the first finish.
STATUS is `submit' or `abort'.  Submission saves first; a save error leaves
the request and presentation active so the user can retry.  Once marked
finished, release happens before presentation cleanup.  DELETING-ORIGIN and
DELETING-PRESENTATION identify a frame whose deletion hook is performing the
cleanup, preventing an attempt to focus or delete that frame recursively."
  (unless (plist-get request :finished)
    (let ((buffer (plist-get request :buffer)))
      (when (eq status 'submit)
        (condition-case err
            (with-current-buffer buffer
              (save-buffer))
          (error
           (user-error "Could not save external-editor file: %s"
                       (error-message-string err)))))
      ;; Commit to finishing before touching either external server state or
      ;; presentation state.  Even if one cleanup operation signals, the
      ;; request cannot be retried or stranded as an active route.
      (setf (plist-get request :finished) t)
      (agent-fleet-editor--unregister-request request deleting-origin)
      (agent-fleet-editor--restore-header-line request buffer)
      (agent-fleet-editor--remove-request-hooks buffer)
      ;; Keep this ordering: save, release emacsclient, then close/restore the
      ;; Agent Fleet presentation.  A direct kill uses FOR-KILLING so the
      ;; server API does not recursively try to kill the buffer again.
      (let (cleanup-error)
        (condition-case err
            (agent-fleet-editor--release-server-buffer
             buffer from-killing)
          (error (setq cleanup-error err)))
        (condition-case err
            (agent-fleet-editor--close-presentation
             request deleting-origin deleting-presentation)
          (error (unless cleanup-error (setq cleanup-error err))))
        (when cleanup-error
          (signal (car cleanup-error) (cdr cleanup-error))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request nil)))
      t)))

(defun agent-fleet-editor-submit ()
  "Save and finish the current Agent Fleet external-editor request.
Bound to C-c C-c in `agent-fleet-editor-buffer-mode'."
  (interactive)
  (let ((request agent-fleet-editor--request))
    (unless request
      (user-error "This buffer is not an Agent Fleet editor request"))
    (agent-fleet-editor--finish-request request 'submit)))

(defun agent-fleet-editor-abort ()
  "Abort the current external-editor request without saving new edits.
Bound to C-c C-k in `agent-fleet-editor-buffer-mode'."
  (interactive)
  (let ((request agent-fleet-editor--request))
    (unless request
      (user-error "This buffer is not an Agent Fleet editor request"))
    (agent-fleet-editor--finish-request request 'abort)))

(defun agent-fleet-editor--buffer-killed ()
  "Abort an editor request when its server buffer is killed directly."
  (when agent-fleet-editor--request
    (condition-case err
        (agent-fleet-editor--finish-request agent-fleet-editor--request
                                            'abort t)
      (error
       (message "agent-fleet: editor cleanup during buffer deletion failed: %s"
                (error-message-string err)))))
  nil)

(defun agent-fleet-editor--server-done ()
  "Clean an editor request completed through another server command."
  (when (and agent-fleet-editor--request
             (not (plist-get agent-fleet-editor--request :finished)))
    (let ((request agent-fleet-editor--request))
      (setf (plist-get request :finished) t)
      (agent-fleet-editor--unregister-request request)
      (agent-fleet-editor--restore-header-line request (current-buffer))
      (agent-fleet-editor--remove-request-hooks (current-buffer))
      ;; The server already released the waiting client before this hook.
      (condition-case err
          (agent-fleet-editor--close-presentation request)
        (error
         (message "agent-fleet: editor presentation cleanup failed: %s"
                  (error-message-string err)))))))

(defun agent-fleet-editor--frame-deleted (frame)
  "Abort active editor requests when their origin or editor FRAME is deleted.
The active request owns the presentation frame, so no separate frame registry
is needed."
  (dolist (request (copy-sequence agent-fleet-editor--active-requests))
    (when (and (listp request)
               (not (plist-get request :finished))
               (or (eq frame (plist-get request :origin-frame))
                   (eq frame (plist-get request :presentation-frame))))
      (let ((deleting-origin (eq frame (plist-get request :origin-frame)))
            (deleting-presentation
             (eq frame (plist-get request :presentation-frame))))
        (condition-case err
            (agent-fleet-editor--finish-request
             request 'abort nil deleting-origin deleting-presentation)
          (error
           (message "agent-fleet: editor cleanup during frame deletion failed: %s"
                    (error-message-string err)))))))
  nil)

(defun agent-fleet-editor--window-state-changed (frame)
  "Abort requests whose standalone editor frame or window was lost."
  (dolist (request (copy-sequence agent-fleet-editor--active-requests))
    (when (and (eq (plist-get request :presentation) 'frame)
               (eq frame (plist-get request :presentation-frame))
               (not (plist-get request :finished)))
      (let ((window (plist-get request :presentation-window))
            (buffer (plist-get request :buffer)))
        (unless (and (frame-live-p frame)
                     (window-live-p window)
                     (eq (window-frame window) frame)
                     (eq (window-buffer window) buffer))
          (condition-case err
              (agent-fleet-editor--finish-request request 'abort)
            (error
             (message
              "agent-fleet: editor cleanup after frame/window loss failed: %s"
              (error-message-string err))))))))
  nil)

(defun agent-fleet-editor--present-in-frame (request)
  "Present REQUEST in a newly created standalone graphical frame.
The frame is created from the recorded origin display and never receives a
`parent-frame' parameter, so it is an independent operating-system frame.
All operations that can fail happen before the request takes ownership of the
frame; a failed presentation therefore deletes the newly created frame before
signalling a diagnostic."
  (let* ((origin (plist-get request :origin-frame))
         (buffer (plist-get request :buffer))
         frame)
    (unless (frame-live-p origin)
      (user-error "The attach frame no longer exists"))
    (unless (display-graphic-p origin)
      (user-error
       "Cannot open the external editor frame: the attach frame is not graphical"))
    (condition-case err
        (let (window)
          (setq frame
                (with-selected-frame origin
                  (make-frame
                   (assq-delete-all
                    'parent-frame
                    (copy-tree agent-fleet-editor-frame-parameters)))))
          (unless (frame-live-p frame)
            (error "make-frame returned no live frame"))
          (setq window (frame-selected-window frame))
          (unless (window-live-p window)
            (error "the new frame has no live selected window"))
          (with-selected-frame frame
            (set-window-buffer window buffer)
            (set-window-dedicated-p window t)
            (select-window window))
          (select-frame-set-input-focus frame)
          (ignore-errors (raise-frame frame))
          (setf (plist-get request :presentation) 'frame
                (plist-get request :presentation-frame) frame
                (plist-get request :presentation-window) window
                (plist-get request :presentation-created-p) t))
      (error
       ;; The request does not own FRAME until the final `setf' above, so a
       ;; presentation failure can clean it up without invoking request
       ;; lifecycle hooks recursively.
       (when (frame-live-p frame)
         (ignore-errors (delete-frame frame)))
       (ignore-errors (agent-fleet-editor--focus-origin request))
       (user-error "Could not open the external editor frame: %s"
                   (error-message-string err))))))

(defun agent-fleet-editor--present-request (request)
  "Present REQUEST in a standalone frame without changing its attach window."
  (agent-fleet-editor--present-in-frame request))

(defun agent-fleet-editor--start-request (route buffer)
  "Create and present a request from ROUTE and server BUFFER."
  (let ((request (append (list :buffer buffer
                               :pane-id (plist-get route :pane-id)
                               :origin-frame (plist-get route :origin-frame)
                               :origin-window (plist-get route :origin-window)
                               :origin-buffer (plist-get route :origin-buffer)
                               :presentation nil
                               :presentation-frame nil
                               :presentation-window nil
                               :presentation-created-p nil
                               :header-line-local-p nil
                               :header-line-format nil
                               :header-line-saved-p nil
                               :finished nil)
                         route)))
    (push request agent-fleet-editor--active-requests)
    (with-current-buffer buffer
      (agent-fleet-editor--install-header-line request buffer)
      (setq-local agent-fleet-editor--request request)
      ;; Keep the server's own kill hook ahead of this cleanup hook.  If it
      ;; already releases the buffer, this hook remains idempotent.
      (add-hook 'kill-buffer-hook #'agent-fleet-editor--buffer-killed t t)
      (add-hook 'server-done-hook #'agent-fleet-editor--server-done t t)
      (agent-fleet-editor-buffer-mode 1))
    (condition-case err
        (agent-fleet-editor--present-request request)
      (error
       (agent-fleet-editor--finish-request request 'abort)
       (signal (car err) (cdr err))))
    request))

(defun agent-fleet-editor--dispatch-server-buffer (buffer route)
  "Dispatch server BUFFER through pending ROUTE, or preserve normal display."
  (if (and (eq route agent-fleet-editor--pending-route)
           (buffer-live-p buffer)
           (buffer-file-name buffer))
      (progn
        (agent-fleet-editor--clear-pending-route route)
        (condition-case err
            (agent-fleet-editor--start-request route buffer)
          (error
           ;; `server-window' is called from inside server's switch routine;
           ;; never leave the external client waiting because presentation
           ;; failed.  The request cleanup already released its client.
           (message "agent-fleet: external editor presentation failed: %s"
                    (error-message-string err)))))
    ;; An unrelated server buffer (or a malformed non-file visit) retains the
    ;; normal server-window behavior and does not consume this route.
    (agent-fleet-editor--call-server-window
     (plist-get route :previous-server-window) buffer)))

(defun agent-fleet-editor--disable ()
  "Release pending and active editor routes when the bridge is disabled."
  (when-let* ((route agent-fleet-editor--pending-route))
    (agent-fleet-editor--clear-pending-route route "editor bridge disabled"))
  (dolist (request (copy-sequence agent-fleet-editor--active-requests))
    (ignore-errors (agent-fleet-editor--finish-request request 'abort))))

;;;###autoload
(define-minor-mode agent-fleet-editor-bridge-mode
  "Enable the opt-in Agent Fleet external-editor bridge.

When enabled, `C-g' in an attach buffer sends Ctrl-G to the exact Herdr pane
and routes the next `$EDITOR' server file visit into an Agent Fleet editor
view.  The mode lazily loads and, when configured, starts Emacs's built-in
server.  Disabling it never stops that server."
  :global t
  :init-value nil
  :lighter " Fleet-Editor"
  :group 'agent-fleet-editor
  (if agent-fleet-editor-bridge-mode
      (condition-case err
          (agent-fleet-editor--ensure-server)
        (error
         (setq agent-fleet-editor-bridge-mode nil)
         (user-error "Cannot enable Agent Fleet editor bridge: %s"
                     (error-message-string err))))
    (agent-fleet-editor--disable)))

(add-hook 'delete-frame-functions #'agent-fleet-editor--frame-deleted)
(add-hook 'window-state-change-functions
          #'agent-fleet-editor--window-state-changed)

(provide 'agent-fleet-editor)
;;; agent-fleet-editor.el ends here
