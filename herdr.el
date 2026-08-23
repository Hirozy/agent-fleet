;;; herdr.el --- Emacs client for the Herdr socket API -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, terminals
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

;; You should have a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Top-level Herdr client: orchestrates connection, the long-lived
;; subscription stream, the local cache, and reconnection.  Built on
;; three pure layers:
;;
;;   herdr-protocol.el   wire transport (one-shot requests + subscription)
;;   herdr-model.el      snapshot/event cache
;;   herdr-events.el     subscription logic + local event bus
;;
;; The connection flow mirrors docs/PROTOCOL.md §9:
;;
;;   discover socket -> ping (check protocol) -> session.snapshot
;;       -> replace cache -> events.subscribe -> live
;;
;; On subscription loss: mark disconnected, schedule reconnect with
;; exponential backoff; on reconnect, ping -> snapshot (wholesale
;; cache replace) -> re-subscribe with a recomputed per-pane set.
;; Events are never replayed; the snapshot is the canonical resync.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-protocol)
(require 'herdr-model)
(require 'herdr-events)


;;; --- Customization --------------------------------------------------

(defcustom herdr-required-protocol-version 19
  "Minimum Herdr protocol version the client requires.
The server's protocol (from `ping') must be at least this.  A server
with a HIGHER protocol is accepted (the client tolerates unknown
fields).  Set to nil to skip the check.  The client is verified against
Herdr 0.8.2 (protocol 20); the permissive default (19) also accepts the
earlier 0.8.0 baseline."
  :type '(choice (const :tag "No minimum" nil)
                 (integer :tag "Minimum protocol"))
  :group 'herdr)

(defcustom herdr-reconnect-max-attempts 12
  "Maximum reconnection attempts before giving up.
A server that never recovers after this many attempts is left
disconnected until the user reconnects manually."
  :type 'integer
  :group 'herdr)

(defcustom herdr-reconnect-delay 2.0
  "Base delay (seconds) between reconnection attempts.
The actual delay grows exponentially up to `herdr-reconnect-max-delay'."
  :type 'number
  :group 'herdr)

(defcustom herdr-reconnect-max-delay 60.0
  "Cap (seconds) on the reconnection backoff delay."
  :type 'number
  :group 'herdr)


;;; --- Connection state ---------------------------------------------

(cl-defstruct herdr--connection
  "Live Herdr connection state."
  socket-path protocol version capabilities
  subscription-proc
  connected
  reconnect-timer
  (reconnect-attempts 0))

(defvar herdr--conn nil
  "Current `herdr--connection', or nil when fully disconnected.")

(defun herdr-connection ()
  "Return the live connection struct, or nil."
  herdr--conn)


;;; --- Connection lifecycle -----------------------------------------

;;;###autoload
(defun herdr-connect (&optional socket-path)
  "Connect to a Herdr server and start mirroring its state.
SOCKET-PATH overrides the discovered socket (see `herdr-socket-path').
Performs: ping (protocol check) -> session.snapshot -> cache ->
events.subscribe.  Returns t on success; signals a `herdr-error'
condition on failure.  Reconnecting an already-live connection first
disconnects."
  (interactive)
  (when herdr--conn
    ;; Always tear down any prior connection (even a half-connected one
    ;; with a pending reconnect timer) before building a new one.
    (herdr-disconnect))
  (let ((path (or socket-path (herdr-protocol-socket-path))))
    ;; Every transport primitive discovers its socket through the dynamically
    ;; scoped `herdr-socket-path'.  Bind the resolved override for the complete
    ;; bootstrap, then persist it on CONN for requests and reconnects.
    (let* ((herdr-socket-path path)
           (pong (herdr-protocol-ping))
           (proto (plist-get pong :protocol))
           (caps (plist-get pong :capabilities))
           (ver (plist-get pong :version)))
      (herdr--check-protocol proto)
      (let* ((snap (herdr-protocol-request "session.snapshot" nil))
             (session (herdr-model-parse-snapshot snap)))
        (herdr-model-set-cache session)
        (let ((conn (make-herdr--connection
                     :socket-path path :protocol proto
                     :version ver :capabilities caps
                     :connected t :reconnect-attempts 0)))
          (setq herdr--conn conn)
          (herdr--start-subscription conn)
          (herdr--log 'info "connected to Herdr %s (protocol %s)" ver proto)
          t)))))

(defun herdr--check-protocol (server-protocol)
  "Signal `herdr-protocol-error' if SERVER-PROTOCOL is too old."
  (when (and herdr-required-protocol-version server-protocol)
    (when (< server-protocol herdr-required-protocol-version)
      (signal 'herdr-protocol-error
              (list :server server-protocol
                    :required herdr-required-protocol-version)))))

(defun herdr--start-subscription (conn)
  "Open the long-lived subscription stream for CONN.
Unsubscribes any previously-live subscription on CONN first (so a
reconnect never leaves a second live stream pushing duplicate events).
Returns the new subscription process (which may be nil if the socket
could not be opened)."
  (let ((old (herdr--connection-subscription-proc conn)))
    (when (herdr-protocol-subscription-alive-p old)
      (herdr-protocol-unsubscribe old)))
  (let ((herdr-socket-path (or (herdr--connection-socket-path conn)
                               herdr-socket-path))
        (subs (herdr-events-subscriptions-for (herdr-model-cache))))
    (let ((proc (herdr-protocol-subscribe
                 subs
                 #'herdr--on-event
                 #'herdr--on-subscription-lost)))
      (setf (herdr--connection-subscription-proc conn) proc)
      proc)))

(defun herdr--reconcile-panes ()
  "Drop cached panes the server no longer reports, marking them gone.
Fetches `pane.list' (ground truth) and, for every pane id in the cache
absent from the result, calls `herdr-model-mark-pane-gone' — removing it
and recording it in `gone-panes' so a `pane_created' replayed later from
the EventHub ring buffer (whose matching close aged out of the bounded
ring) is ignored instead of re-inserted.

This keeps stale pane ids out of the per-pane subscribe set: real Herdr
rejects the ENTIRE subscribe batch when one per-pane subscription
references a missing pane (`pane_get(...)?' in subscriptions.rs
propagates `pane_not_found').  Without it, a single stale id re-inserted
by replay would reject the resubscribe, drop `connected', and reconnect
— and the reconnect's subscribe replays and re-inserts it again, looping.

RPC failures are swallowed: the caller subscribes with the cache as-is,
and if a stale id still rejects the batch, the subscription-loss path
schedules a reconnect that retries with a fresh snapshot."
  (ignore-errors
    (let ((herdr-socket-path
           (or (and herdr--conn
                    (herdr--connection-socket-path herdr--conn))
               herdr-socket-path))
          (live (make-hash-table :test 'equal)))
      (dolist (pn (plist-get (herdr-protocol-request "pane.list" nil) :panes))
        (when-let* ((id (plist-get pn :pane_id)))
          (puthash id t live)))
      (when-let* ((session (herdr-model-cache)))
        (let (stale)
          (maphash (lambda (pid _pn)
                     (unless (gethash pid live)
                       (push pid stale)))
                   (herdr-session-panes session))
          (dolist (pid stale)
            (herdr--log 'debug "reconcile: pane %s gone on server; dropping" pid)
            (herdr-model-mark-pane-gone pid session)))))))

(defvar herdr--resubscribe-pending nil
  "Non-nil while a deferred resubscribe is queued, to coalesce bursts.")

(defvar herdr--resubscribe-timer nil
  "The pending deferred-resubscribe timer, so `herdr-disconnect' can cancel it.")

(defun herdr--on-event (kind data)
  "Event callback for the fleet subscription: dispatch + maybe resubscribe."
  (let ((descriptor (herdr-events-dispatch kind data)))
    (when (herdr-events-rebuild-needed-p descriptor)
      ;; Defer + coalesce: a burst of pane-set changes triggers a single
      ;; teardown/resubscribe rather than one per event.
      (unless herdr--resubscribe-pending
        (setq herdr--resubscribe-pending t)
        (setq herdr--resubscribe-timer
              (run-at-time 0 nil #'herdr--resubscribe))))))

(defun herdr--resubscribe ()
  "Tear down and re-establish the subscription with a fresh per-pane set.
First reconciles the cache against `pane.list' (ground truth) so a stale
pane id — a `pane_created' replayed from the EventHub ring buffer whose
matching close aged out — is dropped and remembered gone, never reaching
the per-pane subscribe batch (one stale id rejects the whole batch on
real Herdr)."
  (setq herdr--resubscribe-pending nil)
  (setq herdr--resubscribe-timer nil)
  (let ((conn herdr--conn))
    (when (and conn (herdr--connection-connected conn))
      (let ((old (herdr--connection-subscription-proc conn)))
        (when (herdr-protocol-subscription-alive-p old)
          (herdr-protocol-unsubscribe old)))
      (herdr--reconcile-panes)
      (herdr--log 'debug "resubscribing (pane set changed)")
      ;; Reuse the connection helper so an explicit socket override remains
      ;; in force after pane-set changes as well as after full reconnects.
      (let ((proc (herdr--start-subscription conn)))
        (setf (herdr--connection-subscription-proc conn) proc)))))

(defun herdr--on-subscription-lost (errdata)
  "Error callback: mark disconnected and schedule a reconnect.
ERRDATA is the plist from `herdr-protocol-subscribe'.
Idempotent: a no-op if we are already disconnected (e.g. the close
sentinel firing after the send-failed/rejected path already reported),
preventing duplicate reconnect timers."
  (let ((conn herdr--conn))
    (when (and conn (herdr--connection-connected conn))
      (setf (herdr--connection-connected conn) nil)
      (setf (herdr--connection-subscription-proc conn) nil)
      (herdr--log 'warn "subscription lost: %S" errdata)
      (herdr--schedule-reconnect))))

(defun herdr--schedule-reconnect ()
  "Schedule a reconnect attempt with exponential backoff.
Cancels any previously-pending reconnect timer first (idempotent under
double error-callbacks), so one loss never schedules two timers."
  (let ((conn herdr--conn))
    (when conn
      (when-let* ((old (herdr--connection-reconnect-timer conn)))
        (cancel-timer old)
        (setf (herdr--connection-reconnect-timer conn) nil))
      (let ((n (1+ (herdr--connection-reconnect-attempts conn))))
        (setf (herdr--connection-reconnect-attempts conn) n)
        (let ((max herdr-reconnect-max-attempts))
          (if (> n max)
              (progn
                (herdr--log 'error "giving up after %d reconnect attempts" n)
                (setq herdr--conn nil)
                ;; Drop the stale cache so herdr-session returns nil as
                ;; documented rather than reporting dead state.
                (herdr-model-clear-cache))
            (let* ((base herdr-reconnect-delay)
                   (raw (* base (expt 2 (1- n))))
                   (delay (min raw herdr-reconnect-max-delay)))
              (herdr--log 'info "reconnect attempt %d in %.1fs" n delay)
              (setf (herdr--connection-reconnect-timer conn)
                    (run-at-time delay nil #'herdr--reconnect)))))))))

(defun herdr--reconnect ()
  "Attempt to re-establish the connection (ping -> snapshot -> resubscribe).
On success marks connected and resets the backoff; on any failure
(including a subscribe that did not produce a live process) schedules
another attempt WITHOUT resetting the backoff, so a persistently-failing
server still reaches `herdr-reconnect-max-attempts' and gives up."
  (let ((conn herdr--conn))
    (when conn
      (condition-case err
          (let ((herdr-socket-path
                 (or (herdr--connection-socket-path conn)
                     herdr-socket-path)))
            (let ((pong (herdr-protocol-ping)))
              (herdr--check-protocol (plist-get pong :protocol))
              (setf (herdr--connection-protocol conn) (plist-get pong :protocol))
              (setf (herdr--connection-version conn) (plist-get pong :version))
              (setf (herdr--connection-capabilities conn)
                    (plist-get pong :capabilities)))
            (let* ((snap (herdr-protocol-request "session.snapshot" nil))
                   (session (herdr-model-parse-snapshot snap)))
              (herdr-model-set-cache session))
            (let ((proc (herdr--start-subscription conn)))
              (if (herdr-protocol-subscription-alive-p proc)
                  (progn
                    (setf (herdr--connection-connected conn) t)
                    (setf (herdr--connection-reconnect-attempts conn) 0)
                    (setf (herdr--connection-reconnect-timer conn) nil)
                    (herdr--log 'info "reconnected to Herdr")
                    t)
                ;; ping+snapshot worked but the subscription did not land;
                ;; do not advertise connected, do not reset the backoff.
                (herdr--log 'warn "reconnect: subscription not live")
                (herdr--schedule-reconnect))))
        (error
         (herdr--log 'warn "reconnect failed: %s" (error-message-string err))
         (herdr--schedule-reconnect))))))

;;;###autoload
(defun herdr-disconnect ()
  "Disconnect from Herdr: close the subscription stream and drop the cache."
  (interactive)
  (let ((conn herdr--conn))
    (when conn
      (when-let* ((timer (herdr--connection-reconnect-timer conn)))
        (cancel-timer timer))
      (when-let* ((proc (herdr--connection-subscription-proc conn)))
        (herdr-protocol-unsubscribe proc))
      (setf (herdr--connection-connected conn) nil)))
  ;; Cancel any deferred resubscribe so it cannot fire after teardown
  ;; (e.g. into the next test's connection) and leak a subscription.
  (when herdr--resubscribe-timer
    (cancel-timer herdr--resubscribe-timer)
    (setq herdr--resubscribe-timer nil))
  (setq herdr--resubscribe-pending nil)
  (setq herdr--conn nil)
  (herdr-model-clear-cache)
  (herdr--log 'info "disconnected")
  t)

(defun herdr-connected-p ()
  "Return non-nil if there is a live Herdr connection with a subscription."
  (and herdr--conn
       (herdr--connection-connected herdr--conn)
       (herdr-protocol-subscription-alive-p
        (herdr--connection-subscription-proc herdr--conn))
       t))


;;; --- RPC passthrough ----------------------------------------------

;;;###autoload
(cl-defun herdr-request (method &optional params &key (timeout herdr-protocol-request-timeout))
  "Send a one-shot Herdr request and return RESULT.
This does not require an active `herdr-connect' session: it opens a
fresh connection to the socket, sends METHOD with PARAMS, and returns
the result.  Signals `herdr-error' conditions on failure."
  (let ((herdr-socket-path
         (or (and herdr--conn
                  (herdr--connection-socket-path herdr--conn))
             herdr-socket-path)))
    (herdr-protocol-request method params :timeout timeout)))

;;;###autoload
(cl-defun herdr-request-async (method params callback &key (timeout herdr-protocol-request-timeout))
  "Send a one-shot Herdr request asynchronously.
CALLBACK is called as (CALLBACK RESULT) on success or
\(CALLBACK error ERRDATA) on failure."
  (let ((herdr-socket-path
         (or (and herdr--conn
                  (herdr--connection-socket-path herdr--conn))
             herdr-socket-path)))
    (herdr-protocol-request-async method params callback :timeout timeout)))

(defun herdr-ping ()
  "Ping Herdr and return the pong result plist."
  (let ((herdr-socket-path
         (or (and herdr--conn
                  (herdr--connection-socket-path herdr--conn))
             herdr-socket-path)))
    (herdr-protocol-ping)))

(defun herdr-snapshot ()
  "Request a fresh `session.snapshot' and return the result plist.
Note: this returns the raw result; it does NOT replace the live cache.
Use `herdr-connect' to (re)bootstrap the cache from a snapshot."
  (herdr-request "session.snapshot" nil))

;;;###autoload
(defun herdr-subscribe (subscriptions event-callback &optional error-callback)
  "Open an ADDITIONAL long-lived subscription connection.
This is separate from the fleet-managed subscription opened by
`herdr-connect'; use it for ad-hoc observation.  Returns the process.
Manage its lifetime with `herdr-protocol-unsubscribe'."
  (let ((herdr-socket-path
         (or (and herdr--conn
                  (herdr--connection-socket-path herdr--conn))
             herdr-socket-path)))
    (herdr-protocol-subscribe subscriptions event-callback error-callback)))


;;; --- Cache accessors (delegating to herdr-model) ------------------

;;;###autoload
(defun herdr-session ()
  "Return the cached `herdr-session', or nil if disconnected."
  (herdr-model-cache))

;;;###autoload
(defun herdr-workspaces ()
  "Return the cached workspace structs as a list."
  (herdr-model-workspaces))

;;;###autoload
(defun herdr-panes ()
  "Return the cached pane structs as a list."
  (herdr-model-panes))

;;;###autoload
(defun herdr-tabs ()
  "Return the cached tab structs as a list."
  (herdr-model-tabs))

;;;###autoload
(defun herdr-agents ()
  "Return the cached agent structs as a list."
  (herdr-model-agents))

;;;###autoload
(defun herdr-find-agent (pane-id)
  "Return the cached agent struct with PANE-ID, or nil."
  (herdr-model-find-agent pane-id))

;;;###autoload
(defun herdr-find-workspace (workspace-id)
  "Return the cached workspace struct with WORKSPACE-ID, or nil."
  (herdr-model-find-workspace workspace-id))

;;;###autoload
(defun herdr-find-pane (pane-id)
  "Return the cached pane struct with PANE-ID, or nil."
  (herdr-model-find-pane pane-id))

(defun herdr-focused-workspace ()
  "Return the cached focused workspace struct, or nil."
  (herdr-model-focused-workspace))

(defun herdr-focused-pane ()
  "Return the cached focused pane struct, or nil."
  (herdr-model-focused-pane))


;;; --- Doctor --------------------------------------------------------

(defun herdr--doctor-checks ()
  "Return the list of (LABEL OK DETAIL) doctor check triples.
Verifies Emacs version, the Herdr executable and server, protocol
compatibility, the socket, schema availability, the subscription
stream, and optional features (Magit, Eat).  Does NOT inspect agents or
integrations; `agent-fleet-doctor' appends those."
  (let ((checks nil))
    (push (herdr--doctor-check
           "Emacs version"
           (version<= "29.1" emacs-version)
           emacs-version)
          checks)
    (push (herdr--doctor-check
           "Herdr executable"
           (executable-find "herdr")
           (or (executable-find "herdr") "not on PATH"))
          checks)
    (let ((server-ok nil) (server-detail ""))
      (condition-case err
          (let ((pong (herdr-protocol-ping)))
            (setq server-ok t)
            (setq server-detail
                  (format "v%s protocol %s"
                          (plist-get pong :version)
                          (plist-get pong :protocol))))
        (error
         (setq server-detail (error-message-string err))))
      (push (herdr--doctor-check "Herdr server" server-ok server-detail)
            checks))
    (let* ((pong (ignore-errors (herdr-protocol-ping)))
           (proto (plist-get pong :protocol))
           (ok (or (null herdr-required-protocol-version)
                   (and proto (>= proto herdr-required-protocol-version)))))
      (push (herdr--doctor-check
             "Protocol"
             ok
             (format "server %s / required %s"
                     proto herdr-required-protocol-version))
            checks))
    (let ((path (condition-case nil
                   (herdr-protocol-socket-path)
                 (error nil))))
      (push (herdr--doctor-check
             "Socket path"
             (and path (file-exists-p path))
             (or path "not found"))
            checks))
    (push (herdr--doctor-check
           "Schema"
           (herdr--schema-available-p)
           (if (herdr--schema-available-p) "available via `herdr api schema'" "unavailable"))
           checks)
    (push (herdr--doctor-check
           "Events"
           (condition-case nil
               (let* ((proc (herdr-protocol-subscribe
                             '((("type" . "workspace.created")))
                             (lambda (_ _))))
                      (ok (and (processp proc) (process-live-p proc))))
                 ;; Drain the subscription_started ack before closing,
                 ;; so the server has actually confirmed the subscription
                 ;; (and is not left writing to a peer that stopped
                 ;; reading, which can wedge `accept-process-output').
                 (when ok (accept-process-output proc 0.1))
                 (when proc (herdr-protocol-unsubscribe proc))
                 ok)
             (error nil))
           "subscription stream")
          checks)
    (dolist (feat '((magit . "Magit") (eat . "Eat")))
      (push (herdr--doctor-check
             (format "%s (optional)" (cdr feat))
             (featurep (car feat))
             (if (featurep (car feat)) "available" "not installed"))
            checks))
    (nreverse checks)))

(defun herdr--doctor-render (checks buffer-name title)
  "Render CHECKS to BUFFER-NAME and display it.
TITLE is the report heading.  Returns the number of failing checks."
  (with-current-buffer (get-buffer-create buffer-name)
    (read-only-mode -1)
    (erase-buffer)
    (insert title "\n\n")
    (dolist (c checks)
      (insert (format "%-22s %s  %s\n"
                      (car c)
                      (if (cadr c) "OK  " "FAIL")
                      (caddr c))))
    (goto-char (point-min))
    (read-only-mode 1))
  (display-buffer buffer-name)
  (let ((fails (cl-remove-if #'cadr checks)))
    (if fails
        (message "%s: %d check(s) failed" title (length fails))
      (message "%s: all checks passed" title))
    (length fails)))

;;;###autoload
(defun herdr-doctor ()
  "Check the Herdr environment and show a report.
Verifies Emacs version, the Herdr executable and server, protocol
compatibility, the socket, schema availability, and optional
features (Magit, Eat).  Does NOT inspect agents or integrations beyond
what `ping' reports; see `agent-fleet-doctor' for the full agent
diagnostic (Phase 2)."
  (interactive)
  (herdr--doctor-render (herdr--doctor-checks)
                        "*herdr-doctor*" "Herdr Doctor"))

(defun herdr--doctor-check (label ok detail)
  "Build a doctor check triple (LABEL OK DETAIL)."
  (list label ok detail))

(defun herdr--schema-available-p ()
  "Return non-nil if the Herdr schema is obtainable."
  (and (executable-find "herdr")
       (with-temp-buffer
         (let ((code (call-process "herdr" nil t nil
                                   "api" "schema" "--json")))
           (and (numberp code) (= code 0)
                (goto-char (point-min))
                (looking-at-p "{"))))))


(provide 'herdr)
;;; herdr.el ends here
