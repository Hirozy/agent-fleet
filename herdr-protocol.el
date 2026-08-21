;;; herdr-protocol.el --- Wire transport for the Herdr socket API -*- lexical-binding: t; -*-

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

;; You should obtain a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Pure transport layer for the Herdr socket API.  Knows how to:
;;
;;   - discover the Herdr Unix socket,
;;   - frame newline-delimited JSON request/response messages,
;;   - send one-shot requests over a fresh connection and return the
;;     RESULT (synchronously or asynchronously),
;;   - hold one long-lived subscription connection and dispatch pushed
;;     events to a callback,
;;   - normalize server errors into structured Lisp conditions,
;;   - log to *herdr-log*.
;;
;; It knows nothing about workspaces, panes, agents, or orchestration:
;; that is `herdr-model.el', `herdr-events.el' and `herdr.el'.
;;
;; Connection model (verified against Herdr 0.8.2, protocol 20):
;;
;;   - Request connections are ONE-SHOT: open, send one request, read one
;;     response, the server closes.  Each request opens a fresh connection.
;;   - Subscription connections are LONG-LIVED: send events.subscribe, read
;;     the subscription_started ack, then the server pushes events forever.
;;
;; See docs/PROTOCOL.md for the authoritative protocol reference.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)


;;; --- Customization --------------------------------------------------

(defgroup herdr nil
  "Emacs client for the Herdr terminal workspace server."
  :group 'processes
  :link '(url-link "https://herdr.dev"))

(defcustom herdr-socket-path nil
  "Path to the Herdr Unix socket.
If nil, it is discovered from the `HERDR_SOCKET_PATH' environment
variable, then the `herdr status' command, then the default
`~/.config/herdr/herdr.sock'."
  :type '(choice (const :tag "Auto-discover" nil)
                 (file :tag "Socket path"))
  :group 'herdr)

(defcustom herdr-protocol-request-timeout 5.0
  "Default timeout in seconds for a synchronous Herdr request."
  :type 'number
  :group 'herdr)

(defcustom herdr-protocol-ping-timeout 3.0
  "Timeout in seconds for a Herdr `ping'."
  :type 'number
  :group 'herdr)

(defcustom herdr-log-level 'warn
  "Logging verbosity for the Herdr client.
Levels, in increasing verbosity: error, warn, info, debug, trace.
Only messages at or below this level are written to *herdr-log*.
Trace records complete JSON frames; never enable it casually, as
terminal output may contain secrets."
  :type '(choice (const error) (const warn) (const info)
                 (const debug) (const trace))
  :group 'herdr)

(defcustom herdr-log-buffer "*herdr-log*"
  "Name of the Herdr log buffer."
  :type 'string
  :group 'herdr)


;;; --- Error types ----------------------------------------------------

(define-error 'herdr-error "Herdr error")
(define-error 'herdr-connection-error "Herdr connection error" 'herdr-error)
(define-error 'herdr-protocol-error "Herdr protocol error" 'herdr-error)
(define-error 'herdr-request-error "Herdr request error" 'herdr-error)
(define-error 'herdr-timeout-error "Herdr request timed out" 'herdr-error)

(defconst herdr-protocol--log-levels
  '((error . 0) (warn . 1) (info . 2) (debug . 3) (trace . 4)))

(defun herdr-protocol--level>= (a b)
  "Return non-nil if log level A is at least as verbose as B."
  (>= (or (alist-get a herdr-protocol--log-levels) 0)
      (or (alist-get b herdr-protocol--log-levels) 0)))

(defun herdr--log (level format-string &rest args)
  "Write a log entry at LEVEL (a symbol) to *herdr-log*.
FORMAT-STRING and ARGS are as for `format'."
  (when (herdr-protocol--level>= level herdr-log-level)
    (let ((inhibit-read-only t)
          (msg (format "[%s] %s\n" (upcase (symbol-name level))
                        (apply #'format format-string args))))
      (with-current-buffer (get-buffer-create herdr-log-buffer)
        (goto-char (point-max))
        (insert msg)))))


;;; --- JSON framing ---------------------------------------------------

;; Encoding convention (verified unambiguous against Emacs 30 json.el):
;;   - JSON objects  => alists with STRING keys, e.g. (("k" . v))
;;   - JSON arrays   => vectors,            e.g. [a b c]
;;   - empty object  => an empty hash-table (NOT nil, which encodes as null)
;; `json-encode' recurses into nested alists/vectors cleanly.  An empty
;; list () would encode as null, so empty params use an empty hash-table.
;;
;; Decoding uses `json-read-from-string' with `json-object-type' 'plist,
;; which tolerates unknown fields (they become extra plist entries).

(defvar herdr-protocol--id-counter 0
  "Monotonic request id source.")

(defun herdr-protocol--next-id ()
  "Return a fresh request id string."
  (cl-incf herdr-protocol--id-counter)
  (format "el:%d" herdr-protocol--id-counter))

(defun herdr-protocol--plist-to-alist (plist)
  "Convert PLIST with keyword keys into an alist with string keys."
  (let (alist)
    (while plist
      (let* ((k (car plist))
             (v (cadr plist))
             (key (cond
                   ((keywordp k) (substring (symbol-name k) 1))
                   ((symbolp k) (symbol-name k))
                   (t k))))
        (push (cons key v) alist))
      (setq plist (cddr plist)))
    (nreverse alist)))

(defun herdr-protocol--json-object-for (params)
  "Return a Lisp value that `json-encode' renders as a JSON object for PARAMS.
nil/empty -> an empty hash-table (renders as \"{}\").  Accepts alists
with string keys, plists with keyword keys, and hash-tables."
  (cond
   ((null params) (make-hash-table :test 'equal))
   ((hash-table-p params) params)
   ((and (listp params) (proper-list-p params))
    (let ((fst (car-safe params)))
      (cond
       ((and (consp fst) (or (stringp (car fst)) (symbolp (car fst))))
        params)                        ; alist (("k" . v) ...)
       ((keywordp fst)
        (herdr-protocol--plist-to-alist params)) ; plist (:k v ...)
       (t params))))
   (t params)))

(defun herdr-protocol--encode-request (id method params)
  "Encode a request frame as a JSON string terminated by a newline.
PARAMS is normalized to a JSON object; nil/empty becomes \"{}\".
Boolean values use t/`:false' (bound to `json-false' so they encode as
true/false, not as the strings \"true\"/\"false\")."
  (let ((json-object-type 'alist)
        (json-array-type 'vector)
        (json-false :false))
    (concat
     (json-encode
      `(("id" . ,id) ("method" . ,method)
        ("params" . ,(herdr-protocol--json-object-for params))))
     "\n")))

(defun herdr-protocol--decode (string)
  "Decode one JSON line STRING into a plist, tolerating unknown fields.
Returns nil if STRING is empty or unparseable."
  (when (and string (not (string-empty-p string)))
    (let ((json-object-type 'plist)
          (json-array-type 'list)
          (json-false :false)
          (json-null nil))
      (condition-case err
          (json-read-from-string string)
        (error
         (herdr--log 'error "json decode failed: %s :: %s"
                     (error-message-string err) string)
         nil)))))


;;; --- Socket discovery ----------------------------------------------

(defun herdr-protocol-socket-path ()
  "Return the Herdr Unix socket path, discovering it if necessary.
Order: `herdr-socket-path' user var, `HERDR_SOCKET_PATH' env,
`herdr status' socket line, default `~/.config/herdr/herdr.sock'.
Signals `herdr-connection-error' if no usable socket is found."
  (or herdr-socket-path
      (getenv "HERDR_SOCKET_PATH")
      (herdr-protocol--socket-path-from-status)
      (let ((default (expand-file-name "~/.config/herdr/herdr.sock")))
        (if (file-exists-p default)
            default
          (signal 'herdr-connection-error
                  (list :reason "no-socket"
                        :hint "set `herdr-socket-path' or run `herdr'"))))))

(defun herdr-protocol--socket-path-from-status ()
  "Parse the `socket:' line from `herdr status'.  Return nil if unavailable."
  (when (executable-find "herdr")
    (with-temp-buffer
      (let ((code (call-process "herdr" nil t nil "status")))
        (when (and (numberp code) (= code 0))
          (goto-char (point-min))
          (when (re-search-forward
                 "^[[:space:]]*socket:[[:space:]]*\\(.+\\)$" nil t)
            (let ((path (string-trim (match-string 1))))
              (and (not (string-empty-p path))
                   (file-exists-p path)
                   path))))))))


;;; --- Connection primitives -----------------------------------------

(defun herdr-protocol--make-socket (name)
  "Open a client Unix socket to Herdr at the discovered path.
Returns the process object.  Signals `herdr-connection-error' on
immediate connect failure."
  (let ((path (herdr-protocol-socket-path))
        (buf (generate-new-buffer (format " *%s*" name))))
    (condition-case err
        (make-network-process
         :name name
         :buffer buf
         :family 'local
         :service path
         :noquery t)
      (file-error
       (let ((data (list :reason 'connect-refused :path path
                         :detail (error-message-string err))))
         (herdr--log 'error "connect failed: %S" data)
         (signal 'herdr-connection-error data))))))

(defun herdr-protocol--close-socket (proc)
  "Delete PROC and kill its process buffer (if any).
Emacs does not auto-kill a process's buffer on `delete-process', so
without this one-shot requests and closed subscriptions would leak a
buffer per connection over a long-running session."
  (when (processp proc)
    (let ((buf (process-buffer proc)))
      (when (process-live-p proc)
        (delete-process proc))
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf)))))


;;; --- One-shot requests ----------------------------------------------

;; A one-shot request is a small state machine in a plist.  The process
;; filter accumulates bytes until a newline, decodes the single response
;; frame, and stores it; the sentinel reports connection failure.  The
;; synchronous entry point pumps `accept-process-output' until the
;; response arrives or the deadline expires.  The same state machine
;; drives the async path: when a :callback is present, the filter /
;; sentinel / timer each hand off to a single, delivery-guarded sink.

(defun herdr-protocol--req-filter (_proc string state)
  "Process filter for a one-shot request: buffer bytes, decode the line."
  (let ((pending (concat (plist-get state :pending) string)))
    (if (string-search "\n" pending)
        (let* ((nl (string-search "\n" pending))
               (line (substring pending 0 nl)))
          (plist-put state :pending (substring pending (1+ nl)))
          (herdr--log 'trace "resp frame: %s" line)
          (let ((msg (herdr-protocol--decode line)))
            (if msg
                (plist-put state :response msg)
              (plist-put state :error
                         (list :reason 'decode-error :line line))))
          (herdr-protocol--maybe-async-deliver state))
      (plist-put state :pending pending))))

(defun herdr-protocol--req-sentinel (proc event state)
  "Sentinel for a one-shot request: report failure if no response yet."
  (pcase (process-status proc)
    ((or 'open 'connect 'listen 'stop) nil)
    (_
     (unless (plist-get state :response)
       (let ((have-pending
              (not (string-empty-p (plist-get state :pending)))))
         (plist-put state :error
                    (list :reason 'closed :event event
                          :partial have-pending)))))))

(defun herdr-protocol--pump (state proc timeout)
  "Pump `accept-process-output' until STATE resolves or TIMEOUT expires."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (plist-get state :response))
                (not (plist-get state :error))
                (< (float-time) deadline)
                (memq (process-status proc) '(open connect run)))
      (accept-process-output proc 0.05 nil)))
  ;; Connect that never opened -> connection error.
  (when (and (not (plist-get state :response))
             (not (plist-get state :error))
             (not (memq (process-status proc) '(open connect run))))
    (plist-put state :error (list :reason 'closed :event "no-connection")))
  ;; Genuine timeout.
  (when (and (not (plist-get state :response))
             (not (plist-get state :error)))
    (plist-put state :error (list :reason 'timeout))))

(defun herdr-protocol--finish-request (state method)
  "Extract RESULT from STATE or signal the appropriate error."
  (let ((resp (plist-get state :response))
        (err (plist-get state :error)))
    (cond
     (err
      (pcase (plist-get err :reason)
        ('timeout (signal 'herdr-timeout-error (list :method method)))
        (_ (signal 'herdr-connection-error
                   (list :method method :detail err)))))
     ((null resp)
      (signal 'herdr-protocol-error (list :method method :reason 'no-response)))
     ((plist-get resp :error)
      (let ((e (plist-get resp :error)))
        (signal 'herdr-request-error
                (list :method method
                      :code (plist-get e :code)
                      :message (plist-get e :message)))))
     (t (plist-get resp :result)))))

(cl-defun herdr-protocol-request (method &optional params &key (timeout herdr-protocol-request-timeout))
  "Send a one-shot Herdr request and return RESULT synchronously.
METHOD is the dotted method name (e.g. \"session.snapshot\").
PARAMS is an alist/plist/hash-table of parameters, or nil.
Signals one of `herdr-connection-error', `herdr-timeout-error',
`herdr-protocol-error', or `herdr-request-error' (which carries
the server's error CODE)."
  (let* ((id (herdr-protocol--next-id))
         (payload (herdr-protocol--encode-request id method params))
         (state (list :pending "" :response nil :error nil :id id
                      :method method :callback nil :delivered nil
                      :timer nil :proc nil))
         proc)
    (herdr--log 'debug "req %s %s" id method)
    (herdr--log 'trace "req frame: %s" (string-trim-right payload "\n"))
    (condition-case conn-err
        (setq proc (herdr-protocol--make-socket "herdr-req"))
      (herdr-connection-error
       (signal 'herdr-connection-error
               (list :method method :detail (cdr conn-err)))))
    (plist-put state :proc proc)
    (unwind-protect
        (progn
          (set-process-filter proc
            (lambda (p s) (herdr-protocol--req-filter p s state)))
          (set-process-sentinel proc
            (lambda (p e) (herdr-protocol--req-sentinel p e state)))
          (condition-case nil
              (process-send-string proc payload)
            (file-error
             (plist-put state :error (list :reason 'send-failed))))
          (herdr-protocol--pump state proc timeout)
          (herdr-protocol--finish-request state method))
      (herdr-protocol--close-socket proc))))

(cl-defun herdr-protocol-request-async (method params callback &key (timeout herdr-protocol-request-timeout))
  "Send a one-shot Herdr request asynchronously.
CALLBACK is called as (CALLBACK RESULT) on success or
(CALLBACK \\='error ERRDATA) on failure.  ERRDATA is a plist with
:type (connection/timeout/request), :method, and where applicable
:code and :message (server errors) or :detail.  Returns the process
object, or nil if the connection could not be opened (CALLBACK is
still invoked with an :connection error in that case)."
  (let* ((id (herdr-protocol--next-id))
         (payload (herdr-protocol--encode-request id method params))
         (state (list :pending "" :response nil :error nil :id id
                      :method method :callback callback
                      :delivered nil :timer nil :proc nil))
         proc)
    (herdr--log 'debug "req-async %s %s" id method)
    (condition-case conn-err
        (setq proc (herdr-protocol--make-socket "herdr-req-async"))
      (herdr-connection-error
       (funcall callback 'error
                (list :type 'connection :method method
                      :detail (cdr conn-err)))
       (cl-return-from herdr-protocol-request-async nil)))
    (plist-put state :proc proc)
    (set-process-filter proc
      (lambda (p s) (herdr-protocol--req-filter p s state)))
    (set-process-sentinel proc
      (lambda (p e)
        (herdr-protocol--req-sentinel p e state)
        (herdr-protocol--maybe-async-deliver state)))
    (condition-case nil
        (process-send-string proc payload)
      (file-error
       (plist-put state :error (list :reason 'send-failed))
       (herdr-protocol--maybe-async-deliver state)))
    (plist-put state :timer
               (run-at-time
                timeout nil
                (lambda ()
                  (unless (plist-get state :delivered)
                    (unless (or (plist-get state :response)
                                (plist-get state :error))
                      (plist-put state :error (list :reason 'timeout)))
                    (herdr-protocol--deliver-async state)))))
    proc))

(defun herdr-protocol--maybe-async-deliver (state)
  "Deliver the async callback if STATE is resolved and not yet delivered."
  (when (and (plist-get state :callback)
             (not (plist-get state :delivered))
             (or (plist-get state :response)
                 (plist-get state :error)))
    (herdr-protocol--deliver-async state)))

(defun herdr-protocol--deliver-async (state)
  "Deliver the async callback exactly once for STATE, then clean up."
  (plist-put state :delivered t)
  (let ((resp (plist-get state :response))
        (err (plist-get state :error))
        (cb (plist-get state :callback)))
    (when-let* ((timer (plist-get state :timer)))
      (cancel-timer timer)
      (plist-put state :timer nil))
    (herdr-protocol--close-socket (plist-get state :proc))
    (cond
     (err
      (let ((type (pcase (plist-get err :reason)
                    ('timeout 'timeout)
                    (_ 'connection))))
        (funcall cb 'error
                 (list :type type :method (plist-get state :method)
                       :detail err))))
     ((and resp (plist-get resp :error))
      (let ((e (plist-get resp :error)))
        (funcall cb 'error
                 (list :type 'request :method (plist-get state :method)
                       :code (plist-get e :code)
                       :message (plist-get e :message)))))
     (t (funcall cb (and resp (plist-get resp :result)))))))


;;; --- Ping ----------------------------------------------------------

(cl-defun herdr-protocol-ping (&key (timeout herdr-protocol-ping-timeout))
  "Ping Herdr and return the pong result plist.
The result looks like (:type \"pong\" :version <ver> :protocol <n>
:capabilities ...), where <ver>/<n> are the server's reported version and
protocol (verified against Herdr 0.8.2, protocol 20).  Signals
`herdr-request-error' or connection errors."
  (herdr-protocol-request "ping" nil :timeout timeout))

(defun herdr-protocol-protocol-version ()
  "Return the server's protocol version integer, or nil if unreachable."
  (ignore-errors
    (plist-get (herdr-protocol-ping) :protocol)))


;;; --- Subscriptions -------------------------------------------------

(cl-defun herdr-protocol-subscribe (subscriptions event-callback &optional error-callback)
  "Open a long-lived Herdr subscription connection.
SUBSCRIPTIONS is a list of subscription objects (alists with a \"type\"
key, e.g. ((\"type\" . \"workspace.created\"))).  EVENT-CALLBACK is
called for each pushed event as (EVENT-CALLBACK EVENT DATA), where EVENT
is the underscored kind string and DATA is the decoded event plist.
ERROR-CALLBACK, if given, is called as (ERROR-CALLBACK ERRDATA) when the
connection is lost or the subscribe is rejected; ERRDATA has :type
(closed/rejected).  Returns the process object, or nil if the
connection could not be opened (ERROR-CALLBACK is still invoked)."
  (let* ((id (herdr-protocol--next-id))
         (payload (herdr-protocol--encode-request
                   id "events.subscribe"
                   `(("subscriptions" . ,(vconcat subscriptions)))))
         (state (list :pending "" :started nil :error nil :id id
                      :event-callback event-callback
                      :error-callback error-callback
                      :closing nil :dead nil))
         proc)
    (herdr--log 'debug "subscribe %s (%d subs)" id (length subscriptions))
    (herdr--log 'trace "subscribe frame: %s" (string-trim-right payload "\n"))
    (condition-case conn-err
        (setq proc (herdr-protocol--make-socket "herdr-sub"))
      (herdr-connection-error
       (when error-callback
         (funcall error-callback
                  (list :type 'closed :reason 'connect-failed
                        :detail (cdr conn-err))))
       (cl-return-from herdr-protocol-subscribe nil)))
    (herdr-protocol--put-process-state proc state)
    (set-process-filter proc
      (lambda (p s) (herdr-protocol--sub-filter p s state)))
    (set-process-sentinel proc
      (lambda (p e) (herdr-protocol--sub-sentinel p e state)))
    (condition-case nil
        (process-send-string proc payload)
      (file-error
       ;; Mark dead so the close sentinel does not re-fire the callback;
       ;; clean up the process+buffer and return nil so callers observe
       ;; the failure rather than storing a dead process.
       (plist-put state :dead t)
       (plist-put state :error (list :type 'closed :reason 'send-failed))
       (when error-callback
         (funcall error-callback (plist-get state :error)))
       (herdr-protocol--close-socket proc)
       (cl-return-from herdr-protocol-subscribe nil)))
    proc))

(defun herdr-protocol--sub-filter (_proc string state)
  "Process filter for the subscription connection: line-buffer and dispatch."
  (plist-put state :pending (concat (plist-get state :pending) string))
  (let (lines)
    (while (string-search "\n" (plist-get state :pending))
      (let* ((pending (plist-get state :pending))
             (nl (string-search "\n" pending)))
        (push (substring pending 0 nl) lines)
        (plist-put state :pending (substring pending (1+ nl)))))
    (dolist (line (nreverse lines))
      (unless (string-empty-p line)
        (herdr-protocol--handle-sub-line line state)))))

(defun herdr-protocol--handle-sub-line (line state)
  "Decode one subscription line and dispatch it according to STATE."
  (herdr--log 'trace "sub frame: %s" line)
  (let ((msg (herdr-protocol--decode line)))
    (cond
     ((null msg)
      (herdr--log 'error "sub decode failed: %s" line))
     ;; A pushed event: top-level has :event (and :data), no :id.
     ((plist-member msg :event)
      (let* ((raw (plist-get msg :event))
             ;; The server has TWO push envelope shapes.  GLOBAL events
             ;; (`EventEnvelope') carry an UNDERSCORED `event' (`EventKind'
             ;; uses rename_all="snake_case", e.g. "pane_created"); PER-PANE
             ;; subscription events (`SubscriptionEventEnvelope') carry a
             ;; DOTTED `event' (`SubscriptionEventKind' uses explicit dotted
             ;; renames, e.g. "pane.agent_status_changed").  This callback's
             ;; contract (and the model's pcase arms) speak the underscored
             ;; form, so normalize dotted->underscored here — a no-op for
             ;; global events (they contain no dots) and the fix that lets a
             ;; per-pane status push actually match the
             ;; `pane_agent_status_changed' arm instead of falling through to
             ;; `:unknown'.
             (ev (and (stringp raw)
                      (replace-regexp-in-string "\\." "_" raw)))
             (data (plist-get msg :data)))
        (herdr--log 'debug "event %s" ev)
        (when-let* ((cb (plist-get state :event-callback)))
          (funcall cb ev data))))
     ;; The subscribe ack: has :result (ok) or :error (rejected) and :id.
     ((plist-get msg :error)
      (let ((e (plist-get msg :error)))
        ;; Mark dead so the close sentinel does not re-fire the callback.
        (plist-put state :dead t)
        (plist-put state :error
                   (list :type 'rejected :code (plist-get e :code)
                         :message (plist-get e :message)))
        (herdr--log 'error "subscribe rejected: %s / %s"
                    (plist-get e :code) (plist-get e :message))
        (when-let* ((cb (plist-get state :error-callback)))
          (funcall cb (plist-get state :error)))))
     ((plist-get msg :result)
      (plist-put state :started t)
      (herdr--log 'info "subscription started"))
     (t
      (herdr--log 'warn "unrecognized sub frame: %s" line)))))

(defun herdr-protocol--sub-sentinel (proc event state)
  "Sentinel for the subscription connection: report loss unless user-closed."
  (when (and (not (plist-get state :closing))
             (not (plist-get state :dead))
             (not (memq (process-status proc) '(open connect listen))))
    (plist-put state :dead t)
    (herdr--log 'warn "subscription closed: %s" event)
    (when-let* ((cb (plist-get state :error-callback)))
      (funcall cb (list :type 'closed :event event)))))

(defun herdr-protocol-unsubscribe (proc)
  "Close a subscription connection opened by `herdr-protocol-subscribe'.
Does not invoke the error callback (this is a user-initiated close)."
  (when-let* ((state (herdr-protocol--get-process-state proc)))
    (plist-put state :closing t))
  (herdr-protocol--close-socket proc))

(defun herdr-protocol-subscription-alive-p (proc)
  "Return non-nil if PROC is a live subscription connection."
  (and proc (processp proc) (memq (process-status proc) '(open connect))))


;;; --- Process state bookkeeping -------------------------------------

;; Attach the per-connection state plist to the process object so the
;; filter/sentinel closures (which receive only the process) can recover it.

(defun herdr-protocol--put-process-state (proc state)
  "Associate STATE with PROC."
  (process-put proc 'herdr-state state))

(defun herdr-protocol--get-process-state (proc)
  "Return the state plist associated with PROC, or nil."
  (and (processp proc) (process-get proc 'herdr-state)))


(provide 'herdr-protocol)
;;; herdr-protocol.el ends here
