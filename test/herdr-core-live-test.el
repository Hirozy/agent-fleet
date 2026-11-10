;;; herdr-core-live-test.el --- Isolated real-Core checks -*- lexical-binding: t; -*-
;; These tests never use the caller's default Core or its state directory.
(require 'ert)
(require 'agent-fleet-cleanup)
(require 'agent-fleet-test-git)
(require 'agent-fleet-start)
(require 'agent-fleet-attach)

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

(ert-deftest hc-live-rename-persists-and-preserves-terminal-identity ()
  (hc-live-isolated
    (let* ((record (herdr-core-request "terminal.run"
                    '(:argv ["sh" "-c" "sleep 60"] :name "original"
                      :no_parent t :labels (:fleet.role "agent"))))
           (address (plist-get record :address))
           (reference (agent-fleet-reference record))
           (agent-fleet--control-results nil))
      (hc-live-until (lambda () (herdr-core-terminal address)))
      (agent-fleet-rename reference "代码 Review")
      (hc-live-until (lambda () (equal (agent-fleet-name (herdr-core-terminal address)) "代码 Review")))
      (should-not (plist-get (car agent-fleet--control-results) :error))
      (herdr-core-disconnect)
      (herdr-core-connect)
      (let ((renamed (agent-fleet-resolve reference t)))
        (should (equal (agent-fleet-name renamed) "代码 Review"))
        (should (equal (plist-get renamed :name) "original"))
        (should (equal (plist-get renamed :pid) (plist-get record :pid)))
        (should (equal (plist-get renamed :state) "live"))
        (should (agent-fleet-managed-p renamed))))))

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
      (hc-live-until (lambda () (herdr-core-terminal address)))
      (let ((agent-fleet--control-results nil))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (agent-fleet-kill address))
        (hc-live-until (lambda () agent-fleet--control-results))
        (should-not (plist-get (car agent-fleet--control-results) :error))
        (should (string-match-p "Ended" (plist-get (car agent-fleet--control-results) :summary))))
      (hc-live-until (lambda () (equal "finished"
                                       (plist-get (herdr-core-terminal (plist-get child :address)) :state))))
      (should (equal "live" (plist-get (herdr-core-request
                                      "terminal.get" (list :terminal (plist-get independent :address))) :state)))
      (herdr-core-request "terminal.kill" (list :terminal (plist-get independent :address))))))

(ert-deftest hc-live-fleet-control-feedback ()
  (hc-live-isolated
    (let* ((record (herdr-core-request "terminal.run"
                                     '(:argv ["sh" "-c" "sleep 60"] :no_parent t
                                       :labels (:fleet.role "agent"))))
           (address (plist-get record :address))
           (agent-fleet--control-results nil))
      (hc-live-until (lambda () (herdr-core-terminal address)))
      (agent-fleet-interrupt address)
      (hc-live-until (lambda () agent-fleet--control-results) 15)
      (should-not (plist-get (car agent-fleet--control-results) :error))
      (should (string-match-p "Interrupt:" (plist-get (car agent-fleet--control-results) :summary)))
      ;; Interrupt may leave this non-reporting shell live; end only if necessary.
      (when (equal "live" (plist-get (herdr-core-request "terminal.get" (list :terminal address)) :state))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (agent-fleet-kill address))
        (hc-live-until (lambda () (= 2 (length agent-fleet--control-results))))
        (should-not (plist-get (car agent-fleet--control-results) :error))
        (should (string-match-p "Ended" (plist-get (car agent-fleet--control-results) :summary)))))))

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
      (should (equal "fleet-test" (agent-fleet-type (herdr-core-terminal address))))
      (let* ((result (herdr-core-request
                      "terminal.send" (list :terminal address :text "fleet-message"
                                            :wait t :timeout 5) 15))
             (wait (plist-get result :wait)))
        (should (equal (plist-get wait :status) "done"))
        (should (eq (plist-get wait :ended) t)))
      (hc-live-until (lambda () (equal "done" (agent-fleet-status (herdr-core-terminal address)))))
      (let ((buffer (cl-letf (((symbol-function 'agent-fleet-present-buffer)
                             (lambda (buffer &rest _) buffer)))
                      (agent-fleet-prompt address "second-fleet-message"))))
        (unwind-protect
            (with-current-buffer buffer
              (agent-fleet-prompt-submit)
              (hc-live-until (lambda () (eq agent-fleet-operation-state 'sent)))
              (should (herdr-core--valid-send-result-p agent-fleet-operation-result))
              (should (equal (buffer-string) "second-fleet-message")))
          (kill-buffer buffer)))
      (should (equal (plist-get (herdr-core-terminal address) :state) "live"))
      (should-not (agent-fleet-cleanup--scan (agent-fleet-cleanup--records)))
      (herdr-core-request "terminal.kill" (list :terminal address)))))

(ert-deftest hc-live-local-file-attachment-retains-unsent-prompt ()
  (hc-live-isolated
    (let* ((record (herdr-core-request "terminal.run"
                                      (list :argv ["sh" "-c" "sleep 60"] :cwd root
                                            :no_parent t :labels '(:fleet.role "agent"))))
           (address (plist-get record :address))
           (file (expand-file-name "context.txt" root)) draft)
      (hc-live-until (lambda () (herdr-core-terminal address)))
      (with-temp-file file (insert "fleet-context"))
      (unwind-protect
          (progn
            (setq draft (agent-fleet-send-file (agent-fleet-reference record) file))
            (with-current-buffer draft
              (should (eq agent-fleet-operation-state 'draft))
              (goto-char (point-min))
              (should (looking-at "Attached file: \\(.*\\)$"))
              (let ((artifact (match-string 1)))
                (with-temp-buffer
                  (insert-file-contents artifact)
                  (should (equal (buffer-string) "fleet-context"))))))
        (when (buffer-live-p draft) (kill-buffer draft))))))

(ert-deftest hc-live-generated-names-are-accepted-by-core ()
  (hc-live-isolated
    (dolist (directory (list ".emacs.d" "---" "项目" "t7" "t1b"
                             (concat "t7" (make-string 22 ?a) "-tail")
                             (make-string 80 ?a)))
      (let* ((cwd (expand-file-name directory root)) result failure completed)
        (make-directory cwd)
        (agent-fleet-start '("true") :cwd cwd
                           :callback (lambda (r e) (setq result r failure e completed t)))
        (hc-live-until (lambda () completed))
        (should-not failure)
        (let ((record (herdr-core-request "terminal.get"
                                          (list :terminal (plist-get result :address)))))
          (should (<= (length (plist-get record :name)) 32))
          (when (equal directory ".emacs.d")
            (should (equal (plist-get record :name) "emacs-d"))))))))

(ert-deftest hc-live-start-form-retains-core-rejection-and-success ()
  (hc-live-isolated
    (save-window-excursion
      (let ((default-directory (file-name-as-directory root))
            (agent-fleet-commands '("true")) (agent-fleet--last-command nil))
        (dolist (name '("-invalid" "valid-form"))
          (let ((form (agent-fleet-start-form)))
            (unwind-protect
                (with-current-buffer form
                  (widget-value-set (nth 2 agent-fleet--start-fields) name)
                  (agent-fleet--start-form-submit)
                  (hc-live-until (lambda () (not (eq agent-fleet-operation-state 'starting))))
                  (should (eq agent-fleet-operation-state
                              (if (equal name "-invalid") 'rejected 'started)))
                  (should (eq (window-buffer) form))
                  (should-error (agent-fleet--start-form-submit) :type 'user-error)
                  (if (equal name "-invalid")
                      (should-not (herdr-core-terminals))
                    (should agent-fleet-target)
                    (should (string-match-p "valid-form" (buffer-string)))))
              (kill-buffer form))))))))

(ert-deftest hc-live-project-start-uses-linked-checkout ()
  (hc-live-isolated
    (let* ((repo (expand-file-name "repo" root))
           (worktree (expand-file-name "feature" root))
           (subdir (expand-file-name "frontend" worktree)))
      (make-directory repo)
      (fleet-test-git-command repo "init" "-q")
      (fleet-test-git-command repo "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
                                "-c" "commit.gpgsign=false" "commit" "-q" "--allow-empty" "-m" "initial")
      (fleet-test-git-command repo "worktree" "add" "-b" "feature" worktree)
      (make-directory subdir)
      (let ((default-directory (file-name-as-directory subdir)))
        (cl-letf (((symbol-function 'agent-fleet--read-command) (lambda () '("sh" "-c" "sleep 60"))))
          (agent-fleet-start-for-project)))
      (hc-live-until (lambda () (agent-fleet-agents)))
      (let ((record (car (agent-fleet-agents))))
        (should (equal (directory-file-name (plist-get record :cwd)) (file-truename worktree)))
        (should (equal (agent-fleet-project-for-agent record) (file-truename repo)))))))

(provide 'herdr-core-live-test)
