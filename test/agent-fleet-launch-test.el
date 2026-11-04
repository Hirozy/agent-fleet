;;; agent-fleet-launch-test.el --- Launch and remote identity regressions -*- lexical-binding: t; -*-
(require 'agent-fleet-core-test)
(require 'agent-fleet-worktree)
(require 'agent-fleet-batch)
(require 'agent-fleet-remote)

(defmacro fleet-test-git (&rest body)
  "Run BODY in disposable REPO, with DIR and WT paths available."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "fleet-launch-" t))
          (repo (expand-file-name "repo" dir)) (wt (expand-file-name "worker" dir)))
     (make-directory repo)
     (ignore wt)
     (unwind-protect
         (progn
           (agent-fleet-worktree--git repo "init" "-q")
           (agent-fleet-worktree--git repo "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
                                     "-c" "commit.gpgsign=false" "commit" "-q" "--allow-empty" "-m" "initial")
           ,@body)
       (delete-directory dir t))))

(ert-deftest fleet-worktree-records-immutable-base-and-canonical-project ()
  (fleet-test-git
    (let* ((base (agent-fleet-worktree--git repo "rev-parse" "HEAD"))
           (options (agent-fleet-worktree-prepare repo wt "worker")))
      (should (equal base (plist-get (plist-get options :labels) :fleet.review-base)))
      (should (equal (file-truename repo) (agent-fleet-project-root-for-cwd wt)))
      (should (equal base (agent-fleet-worktree--git wt "rev-parse" "HEAD")))
      (should-error (agent-fleet-worktree-prepare repo wt "second") :type 'user-error)
      (should (file-directory-p wt)))))

(ert-deftest fleet-worktree-rejects-bad-base-before-creating-checkout ()
  (fleet-test-git
    (should-error (agent-fleet-worktree-prepare repo wt "worker" "--help"))
    (should-not (file-exists-p wt))))

(ert-deftest fleet-worktree-launch-failure-preserves-checkout ()
  (fleet-test-git
    (cl-letf (((symbol-function 'herdr-core-connect) #'ignore)
              ((symbol-function 'agent-fleet-start) (lambda (&rest _) (error "Launch rejected"))))
      (should-error (agent-fleet-start-worktree '("missing") repo wt "worker")))
    (should (file-directory-p wt))
    (should (equal "worker" (agent-fleet-worktree--git wt "branch" "--show-current")))))

(ert-deftest fleet-batch-out-of-order-outcomes-stay-with-their-members ()
  (fleet-test-model nil
    (save-window-excursion
      (let ((buffer (agent-fleet-start-batch
                     '((:argv ("a") :cwd "/tmp") (:argv ("b") :cwd "/tmp")
                       (:argv ("c") :cwd "/tmp")))) callbacks)
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'agent-fleet-start)
                         (lambda (_argv &rest options)
                           (push (plist-get options :callback) callbacks))))
                (agent-fleet-batch-execute)
                (should-error (agent-fleet-batch-execute) :type 'user-error))
              ;; Reply in the opposite order from submission.
              (funcall (nth 0 callbacks) nil '(herdr-core-uncertain :reason timeout))
              (funcall (nth 1 callbacks) nil '(herdr-core-request-error :error (:message "rejected")))
              (funcall (nth 2 callbacks) '(:address "t1") nil)
              (should (equal (mapcar (lambda (e) (plist-get e :state)) agent-fleet-batch--entries)
                             '(started failed uncertain))))
          (kill-buffer buffer))))))

(ert-deftest fleet-batch-core-change-dispatches-nothing ()
  (fleet-test-model nil
    (with-temp-buffer
      (agent-fleet-batch-mode)
      (setq agent-fleet-batch--core "another-core")
      (cl-letf (((symbol-function 'agent-fleet-start) (lambda (&rest _) (ert-fail "Dispatched"))))
        (should-error (agent-fleet-batch-execute) :type 'user-error)))))

(ert-deftest fleet-remote-reference-survives-route-rename-but-not-replacement ()
  (fleet-test-model (list (fleet-test-agent "old/t1"))
    (let ((machines '((:name "old" :id "remote-id" :state "connected"))))
      (cl-letf (((symbol-function 'herdr-core-machines) (lambda () machines)))
        (let ((ref (agent-fleet-reference (herdr-core-terminal "old/t1"))))
          (setq machines '((:name "new" :id "remote-id" :state "connected")))
          (herdr-core--snapshot (list :seq 2 :terminals (list (fleet-test-agent "new/t1"))))
          (should (equal "new/t1" (plist-get (agent-fleet-resolve ref) :address)))
          (setq machines '((:name "new" :id "replacement" :state "connected")))
          (should-error (agent-fleet-resolve ref) :type 'user-error))))))

(ert-deftest fleet-remote-reference-rejects-disconnected-machine ()
  (cl-letf (((symbol-function 'herdr-core-machines)
             (lambda () '((:id "r" :name "remote" :state "unreachable")))))
    (should-error (herdr-core-machine "r") :type 'user-error)))

(ert-deftest fleet-cleanup-remote-route-rebinding-never-removes-replacement ()
  (let ((machines '((:name "remote" :id "original" :state "connected"))))
    (cl-letf (((symbol-function 'herdr-core-machines) (lambda () machines)))
      (fleet-test-cleanup (list (fleet-test-agent "remote/t1" "finished"))
        (setq machines '((:name "remote" :id "replacement" :state "connected")))
        (agent-fleet-cleanup-execute)
        (should-not (member "terminal.rm" calls))
        (should (eq 'failed (plist-get (car agent-fleet-cleanup--items) :status)))))))

(ert-deftest fleet-file-transfer-rechecks-identity-before-writing ()
  (fleet-test-model (list (fleet-test-agent "t1"))
    (let ((file (make-temp-file "fleet-transfer-" nil nil "bytes")) (calls 0))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-fleet-resolve)
                     (lambda (&rest _)
                       (if (= (cl-incf calls) 1) (herdr-core-terminal "t1")
                         (user-error "Identity changed"))))
                    ((symbol-function 'herdr-core-request) (lambda (&rest _) (ert-fail "Wrote file"))))
            (should-error (agent-fleet-send-file "t1" file) :type 'user-error)
            (should (= calls 2)))
        (delete-file file)))))

(ert-deftest fleet-file-transfer-requires-complete-acknowledgement ()
  (fleet-test-model (list (fleet-test-agent "t1"))
    (let ((file (make-temp-file "fleet-transfer-" nil nil "bytes")))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-fleet-resolve) (lambda (&rest _) (herdr-core-terminal "t1")))
                    ((symbol-function 'herdr-core-request) (lambda (&rest _) '(:path "/artifact" :bytes 1)))
                    ((symbol-function 'agent-fleet-prompt) (lambda (&rest _) (ert-fail "Claimed transfer"))))
            (should-error (agent-fleet-send-file "t1" file) :type 'herdr-core-uncertain))
        (delete-file file)))))

(ert-deftest fleet-remote-review-refuses-truncated-output ()
  (cl-letf (((symbol-function 'herdr-core-machine) (lambda (&rest _) '(:name "remote")))
            ((symbol-function 'herdr-core-request)
             (lambda (&rest _) '(:code 0 :stdout "" :stderr "" :truncated t))))
    (should-error (agent-fleet-remote-exec "id" "/repo" '("git" "diff")))))

(ert-deftest fleet-remote-project-mapping-is-explicit-and-checkout-relative ()
  (fleet-test-git
    (let* ((file (expand-file-name "src/file.el" repo))
           (record '(:address "remote/t1" :cwd "/remote/worktree/src"
                     :labels (:fleet.machine "r" :fleet.project "/remote/repo"
                              :fleet.checkout-root "/remote/worktree")))
           (agent-fleet-remote-projects (list (list :machine "r" :remote "/remote/repo" :local repo))))
      (make-directory (file-name-directory file))
      (with-temp-file file (insert "context"))
      (should (equal (file-truename repo) (agent-fleet-project-for-agent record)))
      (should (equal "/remote/worktree/src/file.el" (agent-fleet-remote-context-path record file)))
      (should-not (agent-fleet-remote-context-path record "/tmp/outside"))
      (let ((agent-fleet-remote-projects nil))
        (should (equal '(remote "r" "/remote/repo") (agent-fleet-project-for-agent record)))
        (should-not (agent-fleet-remote-context-path record file))))))

(ert-deftest fleet-remote-start-never-stats-remote-cwd-locally ()
  (fleet-test-model nil
    (let (params)
      (cl-letf (((symbol-function 'agent-fleet-remote-start-options)
                 (lambda (_machine _cwd) '(:on "remote" :labels (:fleet.machine "r"))))
                ((symbol-function 'file-directory-p) (lambda (_) (ert-fail "Local stat")))
                ((symbol-function 'file-truename) (lambda (_) (ert-fail "Local truename")))
                ((symbol-function 'herdr-core-request-async)
                 (lambda (_method p _callback &optional _timeout) (setq params p))))
        (agent-fleet-start '("sh") :cwd "/remote/absent" :machine "r")
        (should (equal "remote" (plist-get params :on)))
        (should (equal "/remote/absent" (plist-get params :cwd)))))))

(ert-deftest fleet-observe-and-interactive-viewers-are-separate ()
  (let ((viewer (generate-new-buffer " *viewer*")) (observer (generate-new-buffer " *observer*")))
    (unwind-protect
        (progn
          (dolist (buffer (list viewer observer))
            (with-current-buffer buffer
              (agent-fleet-attach-mode 1)
              (setq agent-fleet-target '(:fleet-identity ("core" "t1" 1))
                    agent-fleet-observe-p (eq buffer observer))))
          (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
            (should (eq viewer (agent-fleet-attach--live-buffer '(:fleet-identity ("core" "t1" 1)))))
            (should (eq observer (agent-fleet-attach--live-buffer '(:fleet-identity ("core" "t1" 1)) t)))))
      (kill-buffer viewer) (kill-buffer observer))))

(provide 'agent-fleet-launch-test)
