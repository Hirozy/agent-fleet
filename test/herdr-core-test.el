;;; herdr-core-test.el --- Transport and snapshot regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'herdr-core)

(defmacro hc-test-model (&rest body)
  "Run BODY with an isolated model and no consumer hooks."
  (declare (indent 0))
  `(let ((herdr-core--terminals (make-hash-table :test 'equal))
         (herdr-core--hello '(:core (:id "test-core")))
         (herdr-core--seq -1)
         (herdr-core-changed-hook nil) (herdr-core-event-hook nil))
     ,@body))

(defun hc-test-record (address &optional state labels)
  "Return a record with ADDRESS, STATE and LABELS."
  (list :address address :created_ms 1 :state (or state "live")
        :cwd temporary-file-directory :labels labels))

(ert-deftest hc-snapshot-and-event-order ()
  (hc-test-model
    (let (seen)
      (setq herdr-core-event-hook
            (list (lambda (_event) (push (plist-get (herdr-core-terminal "t1") :state) seen))))
      (herdr-core--snapshot (list :seq 3 :terminals (list (hc-test-record "t1"))))
      (herdr-core--event '(:seq 4 :type "finished" :terminal "t1" :data (:exit_code 0)))
      (should (equal seen '("finished")))
      (herdr-core--event '(:seq 2 :type "created" :terminal "t1"
                          :data (:address "t1" :created_ms 1 :state "live")))
      (should (equal (plist-get (herdr-core-terminal "t1") :state) "finished")))))

(ert-deftest hc-invalid-snapshot-is-atomic ()
  (hc-test-model
    (herdr-core--snapshot (list :seq 1 :terminals (list (hc-test-record "t1"))))
    (should-error (herdr-core--snapshot '(:seq 10 :terminals ((:address "broken")))))
    (should (herdr-core-terminal "t1"))
    (should (= herdr-core--seq 1))))

(ert-deftest hc-hook-error-does-not-lose-lifecycle ()
  (hc-test-model
    (herdr-core--snapshot (list :seq 1 :terminals (list (hc-test-record "t1"))))
    (setq herdr-core-event-hook (list (lambda (_) (error "consumer failed"))))
    (herdr-core--event '(:seq 2 :type "removed" :terminal "t1" :data nil))
    (should-not (herdr-core-terminal "t1"))
    (should (= 2 herdr-core--seq))))

(ert-deftest hc-loss-is-not-completion ()
  (hc-test-model
    (herdr-core--snapshot (list :seq 1 :terminals (list (hc-test-record "t1"))))
    (herdr-core--event '(:seq 2 :type "lost" :terminal "t1"
                        :data (:reason "holder_lost" :finished_ms nil)))
    (should (equal (plist-get (herdr-core-terminal "t1") :state) "live"))
    (should-not (plist-get (herdr-core-terminal "t1") :finished_ms))))

(ert-deftest hc-snapshot-response-and-event-in-same-chunk ()
  (hc-test-model
    (let* ((process (make-pipe-process :name "hc-parser" :noquery t))
           (herdr-core--events process))
      (unwind-protect
          (progn
            (process-put process 'input "")
            (process-put process 'pending (make-hash-table :test 'equal))
            (puthash 1 (cons (lambda (result err)
                               (should-not err) (herdr-core--snapshot result)) nil)
                     (process-get process 'pending))
            (herdr-core--filter
             process "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"seq\":1,\"terminals\":[")
            (should (= herdr-core--seq -1))
            (herdr-core--filter
             process "{\"address\":\"t1\",\"created_ms\":1,\"state\":\"live\"}]}}\n{\"method\":\"event\",\"params\":{\"seq\":2,\"type\":\"removed\",\"terminal\":\"t1\",\"data\":{}}}\n")
            (should-not (herdr-core-terminal "t1"))
            (should (= herdr-core--seq 2)))
        (delete-process process)))))

(ert-deftest hc-missed-replaces-cache-and-rejects-earlier-events ()
  (hc-test-model
    (let* ((process (make-pipe-process :name "hc-missed" :noquery t))
           (herdr-core--events process))
      (unwind-protect
          (progn
            (herdr-core--snapshot (list :seq 2 :terminals (list (hc-test-record "t1"))))
            (herdr-core--message process '(:method "missed" :params (:seq 8 :terminals nil)))
            (herdr-core--event (list :seq 7 :type "created" :terminal "t1"
                                    :data (hc-test-record "t1")))
            (should-not (herdr-core-terminals)))
        (delete-process process)))))

(ert-deftest hc-timeout-and-late-reply-complete-once ()
  (let ((process (make-pipe-process :name "hc-timeout" :noquery t)) results)
    (unwind-protect
        (progn
          (process-put process 'pending (make-hash-table :test 'equal))
          (puthash 7 (cons (lambda (result err) (push (or err result) results)) nil)
                   (process-get process 'pending))
          (herdr-core--timeout process 7 "terminal.run")
          (herdr-core--complete process 7 '(:address "t1") nil)
          (should (= 1 (length results)))
          (should (eq (caar results) 'herdr-core-uncertain)))
      (delete-process process))))

(ert-deftest hc-disconnect-fails-pending-without-replay ()
  (let* ((process (make-pipe-process :name "hc-drop" :noquery t))
         (herdr-core--control process) (herdr-core--events nil)
         (herdr-core--desired nil) (herdr-core--retry nil)
         (herdr-core-changed-hook nil) result)
    (process-put process 'pending (make-hash-table :test 'equal))
    (puthash 1 (cons (lambda (_ err) (setq result err)) nil) (process-get process 'pending))
    (delete-process process)
    (herdr-core--sentinel process "closed")
    (should (eq (car result) 'herdr-core-uncertain))
    (should-not herdr-core--retry)))

(ert-deftest hc-pin-environment-is-local-and-stable ()
  (let* ((process-environment (copy-sequence process-environment))
         (herdr-core-executable "cat") (herdr-core-session "one")
         (herdr-core-socket "/tmp/one.sock") (herdr-core-auto-start t)
         (herdr-core--environment nil) (herdr-core--program nil))
    (setenv "HC_SOCKET" "/tmp/inherited.sock")
    (setenv "HC_TERMINAL_ID" "t99")
    (herdr-core--pin)
    (setq herdr-core-session "two" herdr-core-socket "/tmp/two.sock")
    (should (equal (getenv "HC_SOCKET") "/tmp/inherited.sock"))
    (let ((process-environment (herdr-core-environment)))
      (should (equal (getenv "HC_SOCKET") "/tmp/one.sock"))
      (should (equal (getenv "HC_SESSION") "one"))
      (should-not (getenv "HC_TERMINAL_ID")))))

(ert-deftest hc-explicit-no-autostart ()
  (let ((herdr-core-socket "/nonexistent/fleet-test.sock")
        (herdr-core-auto-start nil))
    (should-error (herdr-core--pin) :type 'user-error)))

(provide 'herdr-core-test)

(ert-deftest hc-turn-and-foreground-do-not-overwrite-terminal-identity ()
  (hc-test-model
    (let ((record (hc-test-record "t1")))
      (herdr-core--snapshot (list :seq 1 :terminals (list record)))
      (herdr-core--event '(:seq 2 :type "foreground" :terminal "t1"
                          :data (:pid 99 :cwd "/somewhere/else" :name "shell" :argv ("sh"))))
      (herdr-core--event '(:seq 3 :type "turn" :terminal "t1" :data (:turn 1 :state "done")))
      (let ((current (herdr-core-terminal "t1")))
        (should (equal (plist-get current :state) "live"))
        (should (equal (plist-get current :cwd) (plist-get record :cwd)))
        (should (= (plist-get current :turn) 1))
        (should (= (plist-get (plist-get current :foreground) :pid) 99))))))
