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


;;; --- One-shot request/response via mock ---------------------------

(ert-deftest herdr-protocol-ping ()
  "ping returns a pong plist with protocol 19."
  (with-herdr-mock path srv
    (let ((pong (herdr-protocol-ping :timeout 2.0)))
      (should (equal (plist-get pong :type) "pong"))
      (should (equal (plist-get pong :protocol) 19)))))

(ert-deftest herdr-protocol-snapshot ()
  "session.snapshot returns a snapshot with the canned shape."
  (with-herdr-mock path srv
    (let* ((res (herdr-protocol-request "session.snapshot" nil :timeout 2.0))
           (snap (plist-get res :snapshot)))
      (should (plist-get snap :workspaces))
      (should (equal (plist-get snap :focused_workspace_id) "w1")))))

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
      (herdr-protocol-unsubscribe proc)
      (should-not (herdr-protocol-subscription-alive-p proc)))))


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
      (let ((proc (herdr--connection-subscription-proc herdr--conn)))
        (should (processp proc))
        (delete-process proc))
      (should-not (herdr-connected-p))
      ;; allow the reconnect timer + snapshot + resubscribe to land
      (let ((deadline (+ (float-time) 4.0)))
        (while (and (not (herdr-connected-p))
                    (< (float-time) deadline))
          (herdr-protocol-test--drain 0.1)))
      (should (herdr-connected-p)))))


;;; --- Helpers ------------------------------------------------------

(defun herdr-protocol-test--drain (seconds)
  "Pump process output for up to SECONDS (split into small slices)."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05 nil))))

(provide 'herdr-protocol-test)
;;; herdr-protocol-test.el ends here
