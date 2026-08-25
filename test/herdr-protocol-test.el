;;; herdr-protocol-test.el --- ERT tests for herdr-protocol.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests run against a fake server (herdr-mock-server.el); no real Herdr
;; is required.  Run with:
;;   emacs -batch -L . -L test -l ert -l herdr-protocol -l herdr-mock-server \
;;         -l test/herdr-protocol-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'herdr)
(require 'herdr-protocol)
(require 'herdr-mock-server)

(defconst herdr-protocol-test--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the protocol test and its fixtures.")

(defmacro with-herdr-mock (path-var server-var &rest body)
  "Run BODY with a fresh mock server, PATH-VAR and SERVER-VAR bound.
Dynamically binds `herdr-socket-path' to the mock socket, and ensures
the server is stopped and any live herdr connection is torn down."
  (declare (indent 2))
  `(let* ((,path-var (make-temp-name "/tmp/herdrmock-"))
          (,server-var (herdr-mock-start ,path-var))
          (herdr-socket-path ,path-var)
          (herdr--conn herdr--conn))
     (unwind-protect
         (progn ,@body)
       (when (and (boundp 'herdr--conn) herdr--conn)
         (ignore-errors (herdr-disconnect)))
       (herdr-mock-stop ,server-var)
       (setq herdr-socket-path nil))))


;;; --- Framing: JSON encode/decode ---------------------------------

(ert-deftest herdr-protocol-log-level-orders-severity-correctly ()
  "`warn' records error/warn but never debug/trace payloads."
  (let ((herdr-log-level 'warn)
        (herdr-log-buffer " *herdr-log-level-test*"))
    (unwind-protect
        (progn
          (herdr--log 'error "error-entry")
          (herdr--log 'warn "warn-entry")
          (herdr--log 'info "info-entry")
          (herdr--log 'trace "secret-trace-entry")
          (let ((text (with-current-buffer herdr-log-buffer
                        (buffer-string))))
            (should (string-match-p "error-entry" text))
            (should (string-match-p "warn-entry" text))
            (should-not (string-match-p "info-entry" text))
            (should-not (string-match-p "secret-trace-entry" text))))
      (when (get-buffer herdr-log-buffer)
        (kill-buffer herdr-log-buffer)))))

(ert-deftest herdr-protocol-encode-empty-params ()
  "Empty params encode as {} not null."
  (let ((frame (herdr-protocol--encode-request "r1" "ping" nil)))
    (should (string-match-p "\"method\":\"ping\"" frame))
    (should (string-match-p "\"params\":{}" frame))
    (should-not (string-match-p "\"params\":null" frame))))

(ert-deftest herdr-protocol-encode-nested-params ()
  "Nested params (subscriptions array of objects) encode correctly."
  (let* ((params `(("subscriptions" . [ (("type" . "workspace.created"))
                                        (("type" . "pane.focused")) ])))
         (frame (herdr-protocol--encode-request "r2" "events.subscribe" params)))
    (should (string-match-p "\"subscriptions\":\\[" frame))
    (should (string-match-p "\"type\":\"workspace.created\"" frame))
    (should (string-match-p "\"type\":\"pane.focused\"" frame))))

(ert-deftest herdr-protocol-decode-tolerant ()
  "Decoding tolerates unknown fields and yields a plist."
  (let ((msg (herdr-protocol--decode
              "{\"id\":\"r1\",\"result\":{\"type\":\"pong\",\"protocol\":19,\"weird\":[1,2]},\"unknown\":true}")))
    (should (and (listp msg) (keywordp (car msg))))
    (should (equal (plist-get msg :id) "r1"))
    (should (equal (plist-get (plist-get msg :result) :protocol) 19))
    (should (equal (plist-get msg :unknown) t))))

(ert-deftest herdr-protocol-decode-error-frame ()
  "An error frame decodes to a plist with :error."
  (let ((msg (herdr-protocol--decode
              "{\"id\":\"r1\",\"error\":{\"code\":\"invalid_request\",\"message\":\"x\"}}")))
    (should (equal (plist-get (plist-get msg :error) :code) "invalid_request"))
    (should (equal (plist-get (plist-get msg :error) :message) "x"))))

(ert-deftest herdr-protocol-empty-socket-settings-are-not-paths ()
  "Empty custom/environment socket values fall through to discovery."
  (let ((herdr-socket-path "")
        (process-environment (copy-sequence process-environment)))
    (setenv "HERDR_SOCKET_PATH" "")
    (cl-letf (((symbol-function 'herdr-protocol--socket-path-from-status)
               (lambda () "/tmp/herdr-discovered.sock")))
      (should (equal "/tmp/herdr-discovered.sock"
                     (herdr-protocol-socket-path))))))

(ert-deftest herdr-protocol-version-check-rejects-missing-and-old ()
  "A malformed pong without a protocol is not accepted as compatible.
`herdr-required-protocol-version' is a fixed constant, not a setting."
  (should-error (herdr--check-protocol nil) :type 'herdr-protocol-error)
  (should-error (herdr--check-protocol "20") :type 'herdr-protocol-error)
  (should-error (herdr--check-protocol 18) :type 'herdr-protocol-error)
  (should-not (herdr--check-protocol 19))
  (should-not (herdr--check-protocol 20)))

(ert-deftest herdr-schema-fixture-pins-critical-request-response-shapes ()
  "The checked-in schema guards fields that mocks previously got wrong."
  (let* ((fixture (expand-file-name "fixtures/schema.json"
                                    herdr-protocol-test--directory))
         (schema (with-temp-buffer
                   (insert-file-contents fixture)
                   (json-parse-buffer :object-type 'alist :array-type 'list
                                      :null-object nil :false-object :false)))
         (get (lambda (key object)
                (alist-get (if (stringp key) (intern key) key) object)))
         (schemas (funcall get "schemas" schema))
         (request (funcall get "request" schemas))
         (defs (funcall get "$defs" request))
         (start (funcall get "AgentStartParams" defs))
         (required (funcall get "required" start))
         (properties (funcall get "properties" start))
         (success (funcall get "success_response" schemas))
         (success-defs (funcall get "$defs" success))
         (response-result (funcall get "ResponseResult" success-defs))
         (variants (funcall get "oneOf" response-result))
         (tab-created
          (cl-find-if
           (lambda (variant)
             (let* ((props (funcall get "properties" variant))
                    (type (funcall get "type" props)))
               (equal "tab_created" (funcall get "const" type))))
           variants))
         (workspace-created
          (cl-find-if
           (lambda (variant)
             (let* ((props (funcall get "properties" variant))
                    (type (funcall get "type" props)))
               (equal "workspace_created" (funcall get "const" type))))
           variants)))
    (should (>= (funcall get "protocol" schema)
                herdr-required-protocol-version))
    (dolist (field '("name" "kind" "pane_id"))
      (should (member field required)))
    (should-not (member "args" required))
    (should (assoc 'args properties))
    (should tab-created)
    (should (member "root_pane" (funcall get "required" tab-created)))
    (should workspace-created)
    (should (member "root_pane"
                    (funcall get "required" workspace-created)))))


;;; --- One-shot request/response via mock ---------------------------

(ert-deftest herdr-protocol-ping ()
  "ping returns a pong plist with protocol 20."
  (with-herdr-mock path srv
    (let ((pong (herdr-protocol-ping :timeout 2.0)))
      (should (equal (plist-get pong :type) "pong"))
      (should (equal (plist-get pong :protocol) 20)))))

(ert-deftest herdr-protocol-snapshot ()
  "session.snapshot returns a snapshot with the canned shape."
  (with-herdr-mock path srv
    (let* ((res (herdr-protocol-request "session.snapshot" nil :timeout 2.0))
           (snap (plist-get res :snapshot)))
      (should (plist-get snap :workspaces))
      (should (equal (plist-get snap :focused_workspace_id) "w1")))))

(ert-deftest herdr-connect-honors-explicit-socket-path ()
  "The SOCKET-PATH argument drives bootstrap and later fleet RPCs."
  (let* ((path (make-temp-name "/tmp/herdr-explicit-"))
         (srv (herdr-mock-start path))
         (herdr-socket-path nil)
         (herdr--conn herdr--conn))
    (unwind-protect
        (progn
          (herdr-connect path)
          (should (herdr-connected-p))
          (should (equal path (herdr--connection-socket-path herdr--conn)))
          ;; This call goes through `herdr-request', which must reuse the
          ;; connection path rather than rediscovering a default socket.
          (should (equal "pong" (plist-get (herdr-request "ping") :type))))
      (ignore-errors (herdr-disconnect))
      (herdr-mock-stop srv))))

(ert-deftest herdr-protocol-server-error-becomes-condition ()
  "A server error response signals herdr-request-error with :code."
  (with-herdr-mock path srv
    (herdr-mock-set-handlers
     srv '(("test.fail" . (lambda (_params)
                            (list 'error "nope" "it broke")))))
    (let ((err (should-error (herdr-protocol-request "test.fail" nil :timeout 2.0)
                             :type 'herdr-request-error)))
      (should (equal (plist-get (cdr err) :code) "nope"))
      (should (equal (plist-get (cdr err) :message) "it broke")))))

(ert-deftest herdr-protocol-unknown-method-errors ()
  "An unhandled method is reported as a not_found request error."
  (with-herdr-mock path srv
    (herdr-mock-set-handlers srv nil)
    (let ((err (should-error (herdr-protocol-request "test.unknown" nil :timeout 2.0)
                             :type 'herdr-request-error)))
      (should (equal (plist-get (cdr err) :code) "not_found")))))

(ert-deftest herdr-protocol-request-timeout ()
  "A silent handler produces a timeout error."
  (with-herdr-mock path srv
    (herdr-mock-set-handlers srv '(("test.slow" . herdr-mock--silent)))
    (should-error (herdr-protocol-request "test.slow" nil :timeout 0.5)
                  :type 'herdr-timeout-error)))


;;; --- Async request path ------------------------------------------

(ert-deftest herdr-protocol-async-success ()
  "An async request delivers the result to the callback exactly once."
  (with-herdr-mock path srv
    (let ((calls 0) result)
      (herdr-protocol-request-async "ping" nil
        (lambda (r &optional _err)
          (cl-incf calls)
          (setq result r))
        :timeout 2.0)
      (herdr-protocol-test--drain 1.0)
      (should (= calls 1))
      (should (equal (plist-get result :type) "pong"))
      (should (equal (plist-get result :protocol) 20)))))

(ert-deftest herdr-protocol-async-server-error ()
  "An async server error delivers (error ERRDATA) with :type/:code once."
  (with-herdr-mock path srv
    (herdr-mock-set-handlers
     srv '(("test.fail" . (lambda (_p) (list 'error "nope" "bad")))))
    (let ((calls 0) errdata)
      (herdr-protocol-request-async "test.fail" nil
        (lambda (r &optional err)
          (cl-incf calls)
          (when (eq r 'error)
            (setq errdata err)))
        :timeout 2.0)
      (herdr-protocol-test--drain 1.0)
      (should (= calls 1))
      (should (eq (plist-get errdata :type) 'request))
      (should (equal (plist-get errdata :code) "nope"))
      (should (equal (plist-get errdata :message) "bad")))))

(ert-deftest herdr-protocol-async-connection-refused ()
  "A bad socket reports a connection error without leaking its buffer."
  (let ((herdr-socket-path "/tmp/herdr-definitely-does-not-exist-sock")
        (calls 0) errdata ret
        (before (buffer-list)))
    (setq ret (herdr-protocol-request-async "ping" nil
                (lambda (r &optional err)
                  (cl-incf calls)
                  (when (eq r 'error)
                    (setq errdata err)))
                :timeout 2.0))
    (should (null ret))                  ; make-socket failed -> nil
    (should (= calls 1))
    (should (eq (plist-get errdata :type) 'connection))
    (should-not
     (cl-find-if
      (lambda (buffer)
        (and (not (memq buffer before))
             (string-match-p "herdr-req-async" (buffer-name buffer))))
      (buffer-list)))))


;;; --- Partial-frame reassembly (direct filter test) ----------------

(ert-deftest herdr-protocol-req-filter-buffers-partial-frames ()
  "The request filter buffers bytes until the terminating newline."
  (let ((state (list :pending "" :response nil :error nil :id "x"
                     :method "test" :callback nil :delivered nil
                     :timer nil :proc nil)))
    (herdr-protocol--req-filter nil "{\"id\":\"x\",\"result\":7" state)
    (should-not (plist-get state :response))
    (should (equal (plist-get state :pending) "{\"id\":\"x\",\"result\":7"))
    (herdr-protocol--req-filter nil "}\n" state)
    (should (plist-get state :response))
    (should (equal (plist-get (plist-get state :response) :result) 7))
    (should (equal (plist-get state :pending) ""))))


;;; --- Subscription stream -----------------------------------------

(ert-deftest herdr-protocol-subscribe-receives-pushed-events ()
  "events.subscribe acks, then pushed events reach the callback."
  (with-herdr-mock path srv
    (let (events err)
      (herdr-mock-set-pending-events
       srv '(("workspace_focused" . (:workspace_id "w9"))))
      (let ((proc (herdr-protocol-subscribe
                   '((("type" . "workspace.focused")))
                   (lambda (ev data) (push (cons ev data) events))
                   (lambda (e) (setq err e)))))
        (herdr-protocol-test--drain 1.0)
        (should events)
        (should (equal (car (car events)) "workspace_focused"))
        ;; push a second event manually
        (herdr-mock-push-event srv "pane_focused" '(:pane_id "w9:p1"))
        (herdr-protocol-test--drain 1.0)
        (should (>= (length events) 2))
        (should-not err)
        (herdr-protocol-unsubscribe proc)))))

(ert-deftest herdr-protocol-subscription-alive-p ()
  "A live subscription is reported alive; after unsubscribe, not."
  (with-herdr-mock path srv
    (let ((proc (herdr-protocol-subscribe
                 '((("type" . "workspace.created")))
                 (lambda (_ _))
                 (lambda (_)))))
      (should (herdr-protocol-subscription-alive-p proc))
      (herdr-protocol-test--drain 0.2)
      (should (herdr-protocol-subscription-started-p proc))
      (herdr-protocol-unsubscribe proc)
      (should-not (herdr-protocol-subscription-alive-p proc))
      (should-not (herdr-protocol-subscription-started-p proc)))))

(ert-deftest herdr-protocol-rejected-subscription-releases-buffer ()
  "A rejected subscription closes its process and process buffer."
  (with-herdr-mock path srv
    (let (err)
      (let* ((proc (herdr-protocol-subscribe
                    '((
                       ("type" . "pane.agent_status_changed")
                       ("pane_id" . "missing:p1")))
                    (lambda (_event _data))
                    (lambda (e) (setq err e))))
             (buffer (process-buffer proc)))
        (herdr-protocol-test--drain 0.5)
        (should (eq (plist-get err :type) 'rejected))
        (should-not (process-live-p proc))
        (should-not (buffer-live-p buffer))))))

(ert-deftest herdr-protocol-subscription-rejects-wrong-success-envelope ()
  "Only `subscription_started', not an arbitrary success, marks a stream live."
  (let ((state (list :pending "" :started nil :error nil :id "el:1"
                     :event-callback #'ignore :error-callback nil
                     :closing nil :dead nil :proc nil)))
    (herdr-protocol--handle-sub-line
     "{\"id\":\"el:1\",\"result\":{\"type\":\"ok\"}}" state)
    (should-not (plist-get state :started))
    (should (equal "invalid_subscription_ack"
                   (plist-get (plist-get state :error) :code)))))


;;; --- Reconnect ----------------------------------------------------

(ert-deftest herdr-reconnect-after-subscription-loss ()
  "When the subscription connection drops, the client reconnects."
  (with-herdr-mock path srv
    (let ((herdr-reconnect-delay 0.1)
          (herdr-reconnect-max-delay 0.2)
          (herdr-reconnect-max-attempts 5))
      (herdr-connect)
      (should (herdr-connected-p))
      ;; let the mock finish processing the subscribe before we drop it
      (herdr-protocol-test--drain 0.5)
      ;; simulate connection loss: kill the client subscription process.
      ;; The sentinel fires synchronously during delete-process, marking
      ;; us disconnected (the reconnect timer hasn't fired yet).
      (let* ((proc (herdr--connection-subscription-proc herdr--conn))
             (buffer (process-buffer proc)))
        (should (processp proc))
        (delete-process proc)
        (should-not (buffer-live-p buffer)))
      (should-not (herdr-connected-p))
      ;; allow the reconnect timer + snapshot + resubscribe to land
      (let ((deadline (+ (float-time) 4.0)))
        (while (and (not (herdr-connected-p))
                    (< (float-time) deadline))
          (herdr-protocol-test--drain 0.1)))
      (should (herdr-connected-p)))))

(ert-deftest herdr-synced-hook-fires-on-connect ()
  "The synced hook fires during `herdr-connect' after the cache is set.
It fires synchronously (before `herdr-connect' returns t), so no event
pump is needed."
  (with-herdr-mock path srv
    (let (fired)
      (let ((herdr-synced-hook nil))
        (add-hook 'herdr-synced-hook (lambda (_) (push t fired)))
        (herdr-connect)
        (should (equal '(t) fired))
        (should (herdr-model-cache))))))

(ert-deftest herdr-synced-hook-fires-on-reconnect ()
  "The synced hook fires again on `herdr--reconnect' after the cache reset.
It fires once on the initial connect and once more after the reconnect's
snapshot replaces the cache."
  (with-herdr-mock path srv
    (let ((herdr-reconnect-delay 0.1)
          (herdr-reconnect-max-delay 0.2)
          (herdr-reconnect-max-attempts 5)
          (herdr-synced-hook nil)
          fired)
      (add-hook 'herdr-synced-hook (lambda (_) (push t fired)))
      (herdr-connect)
      (should (equal '(t) fired))            ; fired once on connect
      (setq fired nil)
      (herdr-protocol-test--drain 0.5)       ; let the subscribe settle
      ;; simulate connection loss (mirrors herdr-reconnect-after-subscription-loss)
      (let* ((proc (herdr--connection-subscription-proc herdr--conn))
             (buffer (process-buffer proc)))
        (delete-process proc)
        (should-not (buffer-live-p buffer)))
      (let ((deadline (+ (float-time) 4.0)))
        (while (and (not (herdr-connected-p))
                    (< (float-time) deadline))
          (herdr-protocol-test--drain 0.1)))
      (should (herdr-connected-p))
      (should (equal '(t) fired)))))         ; fired once on reconnect

(ert-deftest herdr-connect-does-not-succeed-without-subscription ()
  "Bootstrap fails atomically when the subscription socket cannot start."
  (let ((herdr--conn nil)
        (herdr-model--cache nil))
    (cl-letf (((symbol-function 'herdr-protocol-socket-path)
               (lambda () "/tmp/herdr-test.sock"))
              ((symbol-function 'herdr-protocol-ping)
               (lambda (&rest _) '(:protocol 20 :version "mock")))
              ((symbol-function 'herdr-protocol-request)
               (lambda (&rest _)
                 '(:protocol 20 :version "mock" :workspaces () :tabs ()
                   :panes () :agents ())))
              ((symbol-function 'herdr-protocol-subscribe)
               (lambda (&rest _) nil)))
      (should-error (herdr-connect) :type 'herdr-connection-error)
      (should-not herdr--conn)
      (should-not (herdr-model-cache)))))

(ert-deftest herdr-resubscribe-allows-an-event-driven-replacement ()
  "Pane-set rebuild waits for the current stream, not only the original one."
  (let* ((conn (make-herdr--connection :connected t))
         (herdr--conn conn)
         (herdr--resubscribe-pending t)
         (herdr--resubscribe-timer 'placeholder)
         awaited)
    (cl-letf (((symbol-function 'herdr-protocol-subscription-alive-p)
               (lambda (_) nil))
              ((symbol-function 'herdr--reconcile-panes) #'ignore)
              ((symbol-function 'herdr--start-subscription)
               (lambda (_conn) 'original-stream))
              ((symbol-function 'herdr--await-current-subscription)
               (lambda (seen-conn original)
                 (setq awaited (list seen-conn original))
                 t)))
      (herdr--resubscribe)
      (should (equal (list conn 'original-stream) awaited))
      (should (herdr--connection-connected conn)))))


(ert-deftest herdr-replay-stale-pane-does-not-break-connection ()
  "A replayed `pane_created' for a closed pane must not leave us disconnected.
The EventHub ring buffer replays on every subscribe; a `pane_created' for
a pane whose matching `pane_closed' aged out of the bounded ring re-inserts
the dead id into the cache.  The per-pane subscribe set then includes the
stale id, and real Herdr rejects the WHOLE batch (`pane_get(...)?' →
pane_not_found) → `on-subscription-lost' → reconnect → replay → loop,
leaving `herdr-connected-p' nil (the reported bug).  The fix: `pane.list'
reconciliation before each resubscribe drops stale ids, and the
`gone-panes' replay guard stops the re-insert on the next replay — so the
connection stays live without a reconnect."
  (with-herdr-mock path srv
    (herdr-mock-set-agent-handlers srv)
    ;; A replayed create for a pane the snapshot does NOT report (its close
    ;; aged out of the ring): the bug condition.  The mock rejects any
    ;; per-pane subscribe referencing a pane it does not report as live,
    ;; mirroring real Herdr's `pane_get(...)?' batch rejection.
    (herdr-mock-set-pending-events srv
      '(("pane_created" . (:pane (:pane_id "w1:p2" :workspace_id "w1"
                                   :tab_id "w1:t1" :agent "codex"
                                   :agent_status "idle" :cwd "/x")))))
    (let ((herdr-reconnect-delay 0.1)
          (herdr-reconnect-max-delay 0.2)
          (herdr-reconnect-max-attempts 3))
      (herdr-connect)
      ;; Let the replay land, the rebuild fire, the reconcile + resubscribe
      ;; settle.  Without the fix this loops on stale-pane rejection until
      ;; max-attempts gives up (herdr--conn nil); with it, the reconcile
      ;; drops the stale id before the resubscribe and the connection holds.
      (herdr-protocol-test--drain 3.0)
      (should (herdr-connected-p))
      ;; The stale pane was dropped by reconciliation and remembered gone
      ;; (so a further replayed create for it is ignored, not re-inserted).
      (should-not (herdr-model-find-pane "w1:p2"))
      (should (gethash "w1:p2"
                       (herdr-session-gone-panes (herdr-model-cache)))))))


;;; --- Helpers ------------------------------------------------------

(defun herdr-protocol-test--drain (seconds)
  "Pump process output for up to SECONDS (split into small slices)."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05 nil))))

(provide 'herdr-protocol-test)
;;; herdr-protocol-test.el ends here
