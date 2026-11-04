;;; herdr-core-live-test.el --- Isolated real-Core checks -*- lexical-binding: t; -*-
;; These tests never use the caller's default Core or its state directory.
(require 'ert)
(require 'agent-fleet-cleanup)

(defmacro hc-live-isolated (&rest body)
  "Run BODY against a fresh Core under a temporary directory."
  (declare (indent 0))
  `(let* ((root (make-temp-file "/tmp/fleet-core-test-" t))
          (process-environment (copy-sequence process-environment))
          (herdr-core-executable (or (getenv "FLEET_TEST_HC") (executable-find "hc")
                                     (expand-file-name "~/.local/bin/hc")))
          (herdr-core-session "test") (herdr-core-socket (expand-file-name "core.sock" root))
          (herdr-core--hello nil) (herdr-core--terminals (make-hash-table :test 'equal))
          (herdr-core--control nil) (herdr-core--events nil)
          (herdr-core--environment nil) (herdr-core--program nil)
          (herdr-core--desired nil) (herdr-core--retry nil) (herdr-core--attempts 0)
          (herdr-core--state 'disconnected) (herdr-core--seq -1)
          (herdr-core-changed-hook nil) (herdr-core-event-hook nil))
     (unless (file-executable-p herdr-core-executable)
       (ert-fail "Install hc or set FLEET_TEST_HC"))
     (setenv "XDG_CONFIG_HOME" (expand-file-name "config" root))
     (setenv "XDG_STATE_HOME" (expand-file-name "state" root))
     (setenv "XDG_RUNTIME_DIR" (expand-file-name "runtime" root))
     (make-directory (getenv "XDG_RUNTIME_DIR"))
     (setenv "HC_SOCKET" nil)
     (unwind-protect
         (progn (herdr-core-connect) ,@body)
       ;; Use the pinned CLI environment even if an assertion broke a transport.
       (setq herdr-core--desired nil)
       (let ((process-environment (herdr-core-environment)))
         (call-process herdr-core-executable nil nil nil "server" "stop"))
       (herdr-core-disconnect))))

(defun hc-live-until (predicate &optional seconds)
  "Service events until PREDICATE holds or SECONDS expire."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(ert-deftest hc-live-finished-history-and-reconnect ()
  (hc-live-isolated
    (let* ((result (herdr-core-request
                    "terminal.run"
                    '(:argv ["sh" "-c" "printf fleet-output; sleep 0.3"]
                      :no_parent t :labels (:fleet.role "agent"))))
           (address (plist-get result :address)))
      (let ((wait (herdr-core-request "terminal.wait" (list :terminal address :timeout 5) 10)))
        (should (eq (plist-get wait :ended) t))
        (should (equal (plist-get wait :reason) "exit")))
      (hc-live-until (lambda () (equal (plist-get (herdr-core-terminal address) :state) "finished")))
      (should (string-match-p "fleet-output"
                              (plist-get (herdr-core-request "terminal.read" (list :terminal address)) :text)))
      (herdr-core-disconnect)
      (herdr-core-connect)
      (should (equal (plist-get (herdr-core-terminal address) :state) "finished"))
      (with-temp-buffer
        (agent-fleet-cleanup-mode)
        (setq agent-fleet-cleanup--items (agent-fleet-cleanup--scan (agent-fleet-cleanup--records))
              agent-fleet-cleanup--core (herdr-core-id)
              agent-fleet-cleanup--state 'review)
        (agent-fleet-cleanup-execute)
        (should (eq (plist-get (car agent-fleet-cleanup--items) :status) 'removed)))
      (hc-live-until (lambda () (not (herdr-core-terminal address)))))))

(ert-deftest hc-live-rm-rejects-live-and-kill-cascades-only-dependent-child ()
  (hc-live-isolated
    (let* ((parent (herdr-core-request "terminal.run"
                                     '(:argv ["sh" "-c" "sleep 60"] :no_parent t
                                       :labels (:fleet.role "agent"))))
           (address (plist-get parent :address))
           (child (herdr-core-request "terminal.run"
                                    (list :argv ["sh" "-c" "sleep 60"] :parent address)))
           (independent (herdr-core-request "terminal.run"
                                           (list :argv ["sh" "-c" "sleep 60"]
                                                 :parent address :outlive_parent t))))
      (should-error (herdr-core-request "terminal.rm" (list :terminal address))
                    :type 'herdr-core-request-error)
      (herdr-core-request "terminal.kill" (list :terminal address))
      (hc-live-until (lambda () (equal "finished"
                                       (plist-get (herdr-core-terminal (plist-get child :address)) :state))))
      (should (equal "live" (plist-get (herdr-core-request
                                      "terminal.get" (list :terminal (plist-get independent :address))) :state)))
      (herdr-core-request "terminal.kill" (list :terminal (plist-get independent :address))))))

(ert-deftest hc-live-subscription-loss-recovers-snapshot ()
  (hc-live-isolated
    (let* ((herdr-core-reconnect-delay 0.05)
           (record (herdr-core-request "terminal.run" '(:argv ["sh" "-c" "sleep 60"] :no_parent t)))
           (address (plist-get record :address)))
      (delete-process herdr-core--events)
      (hc-live-until (lambda () (and (eq herdr-core--state 'connected)
                                     (herdr-core-terminal address))) 10)
      (herdr-core-request "terminal.kill" (list :terminal address)))))

(ert-deftest hc-live-reported-done-stays-live-and-send-waits-for-its-turn ()
  (hc-live-isolated
    (let* ((script (concat "printf '\\033]7501;state=idle:app=fleet-test\\007'; "
                           "while IFS= read -r line; do "
                           "printf '\\033]7501;state=working:app=fleet-test\\007'; "
                           "sleep 0.3; printf '%s\\n' \"$line\"; "
                           "printf '\\033]7501;state=done:app=fleet-test\\007'; done"))
           (record (herdr-core-request
                    "terminal.run" (list :argv (vector "sh" "-c" script)
                                          :no_parent t :labels '(:fleet.role "agent"))))
           (address (plist-get record :address)))
      (hc-live-until (lambda () (equal "idle" (agent-fleet-status (herdr-core-terminal address)))))
      (let* ((result (herdr-core-request
                      "terminal.send" (list :terminal address :text "fleet-message"
                                            :wait t :timeout 5) 15))
             (wait (plist-get result :wait)))
        (should (equal (plist-get wait :status) "done"))
        (should (eq (plist-get wait :ended) t)))
      (hc-live-until (lambda () (equal "done" (agent-fleet-status (herdr-core-terminal address)))))
      (should (equal (plist-get (herdr-core-terminal address) :state) "live"))
      (should-not (agent-fleet-cleanup--scan (agent-fleet-cleanup--records)))
      (herdr-core-request "terminal.kill" (list :terminal address)))))

(provide 'herdr-core-live-test)
