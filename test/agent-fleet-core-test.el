;;; agent-fleet-core-test.el --- Fleet workflow safety -*- lexical-binding: t; -*-
(require 'ert)
(require 'herdr-core-test)
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'agent-fleet-start)
(require 'agent-fleet-dashboard)
(require 'agent-fleet-attach)
(require 'agent-fleet-cleanup)
(require 'agent-fleet-magit)

(defmacro fleet-test-model (records &rest body)
  "Install RECORDS and run BODY without opening a real connection."
  (declare (indent 1))
  `(hc-test-model
     (let ((herdr-core--state 'connected))
       (herdr-core--snapshot (list :seq 1 :terminals ,records))
       (cl-letf (((symbol-function 'herdr-core-connect) #'ignore))
         ,@body))))

(defun fleet-test-agent (address &optional state)
  "Return agent ADDRESS with STATE."
  (hc-test-record address state '(:fleet.role "agent")))

(ert-deftest fleet-unreported-agent-is-a-member ()
  (fleet-test-model (list (fleet-test-agent "t1") (hc-test-record "t2"))
    (should (= (length (agent-fleet-agents)) 1))
    (should (equal (agent-fleet-status (car (agent-fleet-agents))) "unreported"))))

(ert-deftest fleet-helper-relationship-does-not-invent-an-agent ()
  (fleet-test-model (list (fleet-test-agent "t1")
                          (append (hc-test-record "t2") '(:parent "t1")))
    (should (= 2 (length (agent-fleet-agents))))
    (should-not (agent-fleet-label (herdr-core-terminal "t2") "fleet.role"))))

(ert-deftest fleet-parent-cycle-terminates ()
  (fleet-test-model (list (append (hc-test-record "t1") '(:parent "t2"))
                          (append (hc-test-record "t2") '(:parent "t1")))
    (should-not (agent-fleet-agents))))

(ert-deftest fleet-stale-core-identity-rejected ()
  (fleet-test-model (list (fleet-test-agent "t1"))
    (let ((reference (agent-fleet-reference (herdr-core-terminal "t1"))))
      (setq herdr-core--hello '(:core (:id "replacement")))
      (should-error (agent-fleet-resolve reference) :type 'user-error))))

(ert-deftest fleet-kill-impact-excludes-independent-child-subtree ()
  (let ((records (list (append (fleet-test-agent "t2") '(:parent "t1" :die_with_parent t))
                       (append (fleet-test-agent "t3") '(:parent "t1" :die_with_parent :false))
                       (append (fleet-test-agent "t4") '(:parent "t3" :die_with_parent t)))))
    (should (equal (mapcar (lambda (r) (plist-get r :address))
                          (agent-fleet-kill-impact "t1" records)) '("t2")))))

(ert-deftest fleet-cleanup-done-is-not-finished ()
  (fleet-test-model (list (append (fleet-test-agent "t1") '(:status (:state "done"))))
    (should-not (agent-fleet-cleanup--scan (herdr-core-terminals)))))

(defmacro fleet-test-cleanup (records &rest body)
  "Mock inventories from mutable RECORDS and run cleanup BODY."
  (declare (indent 1))
  `(let ((inventory ,records) calls)
     (fleet-test-model inventory
       (with-temp-buffer
         (agent-fleet-cleanup-mode)
         (setq agent-fleet-cleanup--items (agent-fleet-cleanup--scan inventory)
               agent-fleet-cleanup--core (herdr-core-id)
               agent-fleet-cleanup--state 'review)
         (cl-letf (((symbol-function 'herdr-core-request)
                    (lambda (method &optional params _timeout)
                      (push method calls)
                      (pcase method
                        ("terminal.list" (list :terminals inventory))
                        ("terminal.rm"
                         (let ((address (plist-get params :terminal)))
                           (setq inventory (cl-remove address inventory
                                                     :key (lambda (r) (plist-get r :address))
                                                     :test #'equal))
                           (list :removed address)))
                        (_ (error "Forbidden operation: %s" method))))))
           ,@body)))))

(ert-deftest fleet-cleanup-removes-child-before-parent ()
  (fleet-test-cleanup (list (fleet-test-agent "t1" "finished")
                            (append (hc-test-record "t2" "finished") '(:parent "t1")))
    (agent-fleet-cleanup-execute)
    (should-not inventory)
    (should (cl-every (lambda (i) (eq (plist-get i :status) 'removed))
                      agent-fleet-cleanup--items))
    (should-not (member "terminal.kill" calls))
    (should-error (agent-fleet-cleanup-execute) :type 'user-error)))

(ert-deftest fleet-cleanup-retains-parent-of-live-child ()
  (fleet-test-cleanup (list (fleet-test-agent "t1" "finished")
                            (append (hc-test-record "t2") '(:parent "t1")))
    (agent-fleet-cleanup-execute)
    (should (= 2 (length inventory)))
    (should-not (member "terminal.rm" calls))
    (should (eq (plist-get (car agent-fleet-cleanup--items) :status) 'skipped))))

(ert-deftest fleet-cleanup-excluded-child-retains-parent ()
  (fleet-test-cleanup (list (fleet-test-agent "t1" "finished")
                            (append (hc-test-record "t2" "finished") '(:parent "t1")))
    (setf (plist-get (car agent-fleet-cleanup--items) :selected) nil)
    (agent-fleet-cleanup-execute)
    (should (= 2 (length inventory)))
    (should-not (member "terminal.rm" calls))))

(ert-deftest fleet-cleanup-revalidates-live-and-ownership ()
  (dolist (change '(:state :labels :created_ms))
    (fleet-test-cleanup (list (fleet-test-agent "t1" "finished"))
      (setf (car inventory)
            (plist-put (copy-tree (car inventory)) change
                       (pcase change (:state "live") (:labels nil) (_ 9))))
      (agent-fleet-cleanup-execute)
      (should-not (member "terminal.rm" calls)))))

(ert-deftest fleet-cleanup-no-extra-targets-after-review ()
  (fleet-test-cleanup (list (fleet-test-agent "t1" "finished"))
    (push (fleet-test-agent "t2" "finished") inventory)
    (agent-fleet-cleanup-execute)
    (should (equal (mapcar (lambda (r) (plist-get r :address)) inventory) '("t2")))))

(ert-deftest fleet-cleanup-unknown-ack-stops-dispatch ()
  (fleet-test-cleanup (list (fleet-test-agent "t1" "finished")
                            (fleet-test-agent "t2" "finished"))
    (let ((original (symbol-function 'herdr-core-request)))
      (cl-letf (((symbol-function 'herdr-core-request)
                 (lambda (method &optional params timeout)
                   (if (equal method "terminal.rm")
                       (progn (push method calls) '(:removed "wrong-id"))
                     (funcall original method params timeout)))))
        (agent-fleet-cleanup-execute)
        (should (= 1 (cl-count "terminal.rm" calls :test #'equal)))
        (should (eq (plist-get (car agent-fleet-cleanup--items) :status) 'uncertain))
        (should (eq (plist-get (cadr agent-fleet-cleanup--items) :status) 'pending))))))

(ert-deftest fleet-cleanup-stale-core-does-not-dispatch ()
  (fleet-test-cleanup (list (fleet-test-agent "t1" "finished"))
    (setq herdr-core--hello '(:core (:id "other")))
    (agent-fleet-cleanup-execute)
    (should-not calls)))

(ert-deftest fleet-cleanup-review-has-readable-faces-and-local-bindings ()
  (fleet-test-cleanup (list (fleet-test-agent "t1" "finished"))
    (agent-fleet-cleanup--render)
    (should (get-text-property 1 'face))
    (should (eq (key-binding (kbd "C-c C-c")) #'agent-fleet-cleanup-execute))
    (should buffer-read-only)))

(ert-deftest fleet-start-is-root-and-preserves-unsent-first-message ()
  (fleet-test-model nil
    (let (method params)
      (cl-letf (((symbol-function 'herdr-core-request-async)
                 (lambda (m p callback &optional _timeout)
                   (setq method m params p)
                   (funcall callback '(:address "t1" :first_message (:sent :false :reason "not_ready")) nil))))
        (agent-fleet-start '("claude") :cwd temporary-file-directory :name "example")
        (should (equal method "terminal.run"))
        (should (eq (plist-get params :no_parent) t))
        (should (eq (plist-get params :rm) :false))))))

(ert-deftest fleet-default-names-handle-hidden-directories-and-core-ids ()
  (fleet-test-model nil
    (cl-letf (((symbol-function 'agent-fleet-project-root-for-cwd) (lambda (_) nil)))
      (dolist (entry '((".emacs.d" . "emacs-d") ("___code" . "code")
                       ("---" . "agent") ("项目" . "agent")
                       ("t7" . "agent-t7") ("T1b" . "agent-t1b")
                       ("task" . "task") ("0code" . "0code")))
        (should (equal (agent-fleet--name (concat "/tmp/" (car entry))) (cdr entry)))))
    (cl-letf (((symbol-function 'agent-fleet-project-root-for-cwd)
               (lambda (_) "/project/.emacs.d")))
      (should (equal (agent-fleet--name "/project/.emacs.d/lisp") "emacs-d"))
      (should (equal (agent-fleet--name "/remote/t7" t) "agent-t7")))))

(ert-deftest fleet-default-name-truncation-and-collisions-stay-valid ()
  (let* ((path (concat "/tmp/t7" (make-string 22 ?a) "-tail"))
         (base (concat "agent-t7" (make-string 16 ?a))))
    (fleet-test-model (list (append (fleet-test-agent "t1") (list :name base))
                            (append (fleet-test-agent "t2") (list :name (concat base "-2"))))
      (let ((name (agent-fleet--name path t)))
        (should (equal name (concat base "-3")))
        (should (<= (length name) 32))))))

(ert-deftest fleet-prompt-retains-uncertain-draft-and-blocks-resend ()
  (fleet-test-model (list (fleet-test-agent "t1"))
    (with-temp-buffer
      (agent-fleet-prompt-mode)
      (setq agent-fleet-target (agent-fleet-reference (herdr-core-terminal "t1"))
            agent-fleet-operation-state 'draft)
      (insert "hello")
      (cl-letf (((symbol-function 'agent-fleet-resolve) (lambda (&rest _) (herdr-core-terminal "t1")))
                ((symbol-function 'herdr-core-request-async)
                 (lambda (_method _params callback &optional _timeout)
                   (funcall callback nil '(herdr-core-uncertain :reason timeout)))))
        (agent-fleet-prompt-submit)
        (should (equal (buffer-string) "hello"))
        (should (eq agent-fleet-operation-state 'uncertain))
        (should-error (agent-fleet-prompt-submit) :type 'user-error)))))

(ert-deftest fleet-absent-project-and-remote-path-stay-absent ()
  (let ((path (make-temp-file "fleet-no-project-" t)))
    (unwind-protect
        (progn
          (should-not (agent-fleet-project-root-for-cwd nil))
          (should-not (agent-fleet-project-root-for-cwd ""))
          (should-not (agent-fleet-project-root-for-cwd path))
          (should-not (agent-fleet-project-for-agent
                       (list :address "remote/t1" :cwd default-directory))))
      (delete-directory path))))

(ert-deftest fleet-linked-worktree-project-identity ()
  (skip-unless (executable-find "git"))
  (let* ((dir (make-temp-file "fleet-git-" t))
         (repo (expand-file-name "repo" dir)) (wt (expand-file-name "worktree" dir)))
    (make-directory repo)
    (unwind-protect
        (let ((default-directory repo))
          (should (= 0 (call-process "git" nil nil nil "init" "-q")))
          (should (= 0 (call-process "git" nil nil nil "-c" "user.name=Test"
                                    "-c" "user.email=test@example.invalid" "-c" "commit.gpgsign=false"
                                    "commit" "-q" "--allow-empty" "-m" "initial")))
          (should (= 0 (call-process "git" nil nil nil "worktree" "add" "-q" "-b" "worker" wt)))
          (should (equal (agent-fleet-project-root-for-cwd repo)
                         (agent-fleet-project-root-for-cwd wt))))
      (delete-directory dir t))))

(ert-deftest fleet-attach-replaces-dedicated-window-without-splitting ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *fleet-view*")) (window (selected-window)))
      (unwind-protect
          (progn
            (set-window-dedicated-p window t)
            (agent-fleet-attach--display buffer)
            (should (eq (window-buffer window) buffer))
            (should (= 1 (length (window-list))))
            (should (window-dedicated-p window)))
        (set-window-dedicated-p window nil)
        (kill-buffer buffer)))))

(ert-deftest fleet-child-view-failure-retains-child ()
  (let ((agent-fleet-dashboard--child 'child)
        (agent-fleet-dashboard--origin 'origin)
        (agent-fleet-dashboard--origin-window 'window) selected deleted)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'child))
              ((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'window-live-p) (lambda (_) t))
              ((symbol-function 'select-window) #'ignore)
              ((symbol-function 'select-frame-set-input-focus) (lambda (f) (push f selected)))
              ((symbol-function 'delete-frame) (lambda (f) (push f deleted))))
      (should-error (agent-fleet-dashboard--visit (lambda () (error "open failed"))))
      (should-not deleted)
      (should (eq (car selected) 'child))
      (dolist (result '(nil t ok 42 (:opened no)))
        (agent-fleet-dashboard--visit (lambda () result))
        (should-not deleted)
        (should (eq (car selected) 'child)))
      (agent-fleet-dashboard--visit (lambda () (agent-fleet-display-make-outcome t)))
      (should (equal deleted '(child))))))

(ert-deftest fleet-child-frame-capability-check ()
  (let ((emacs-version "28.2"))
    (should-not (agent-fleet-display-child-frame-available-p)))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
    (should-not (agent-fleet-display-child-frame-available-p))))

(ert-deftest fleet-child-centered-in-origin ()
  (let ((agent-fleet-display--centered-children nil) position)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'frame-pixel-width) (lambda (f) (if (eq f 'origin) 1200 800)))
              ((symbol-function 'frame-pixel-height) (lambda (f) (if (eq f 'origin) 900 500)))
              ((symbol-function 'set-frame-position) (lambda (_f x y) (setq position (list x y)))))
      (agent-fleet-display--center-child-frame 'child 'origin)
      (should (equal position '(200 200))))))

(ert-deftest fleet-start-form-pins-submit-state-to-its-buffer ()
  (let ((form (generate-new-buffer " *fleet-start-test*"))
        (dashboard (generate-new-buffer " *fleet-dash-test*")))
    (unwind-protect
        (with-current-buffer form
          (setq-local agent-fleet--start-fields '("claude" "/tmp" "" ""))
          (cl-letf (((symbol-function 'widget-value) #'identity)
                    ((symbol-function 'agent-fleet--commands) (lambda () '(("claude" "claude"))))
                    ((symbol-function 'agent-fleet-start)
                     (lambda (&rest _) (set-buffer dashboard))))
            (agent-fleet--start-form-submit)
            (with-current-buffer form
              (should (eq agent-fleet-operation-state 'starting))
              (should-error (agent-fleet--start-form-submit) :type 'user-error))
            (with-current-buffer dashboard (should-not agent-fleet-operation-state))))
      (kill-buffer form) (kill-buffer dashboard))))

(ert-deftest fleet-start-form-submit-and-close-work-inside-every-widget ()
  (save-window-excursion
    (let ((agent-fleet--last-command nil) (agent-fleet-commands '("true")))
      (dotimes (index 4)
        (let ((form (agent-fleet-start-form)) launched)
          (unwind-protect
              (with-current-buffer form
                (should (derived-mode-p 'agent-fleet-start-mode))
                (should (= (point) (widget-field-start (car agent-fleet--start-fields))))
                (goto-char (widget-field-start (nth index agent-fleet--start-fields)))
                (should (eq (key-binding (kbd "C-c C-k")) #'agent-fleet-view-quit))
                (cl-letf (((symbol-function 'agent-fleet--commands) (lambda () nil))
                          ((symbol-function 'agent-fleet-start)
                           (lambda (argv &rest _) (setq launched argv))))
                  (call-interactively (key-binding (kbd "C-c C-c")))
                  (should (equal launched '("true")))
                  (should (eq agent-fleet-operation-state 'starting))))
            (kill-buffer form)))))))

(ert-deftest fleet-start-form-retains-rejection-and-success-without-opening-dashboard ()
  (dolist (failure '(nil (herdr-core-request-error :error (:message "bad name"))))
    (fleet-test-model nil
      (save-window-excursion
        (let ((form (agent-fleet-start-form)) callback)
          (unwind-protect
              (with-current-buffer form
                (cl-letf (((symbol-function 'agent-fleet--commands) (lambda () nil))
                          ((symbol-function 'agent-fleet-start)
                           (lambda (_argv &rest options)
                             (should-not (plist-get options :display))
                             (setq callback (plist-get options :callback)))))
                  (agent-fleet--start-form-submit))
                (should (eq (current-buffer) form))
                (should buffer-read-only)
                (should-error (agent-fleet--start-form-submit) :type 'user-error)
                (let ((record (append (fleet-test-agent "t1")
                                      '(:first_message (:sent :false :reason "not_ready")))))
                  (funcall callback (unless failure record) failure)
                  (should (equal agent-fleet-operation-result (or failure record)))
                  (should (eq agent-fleet-operation-state (if failure 'rejected 'started)))
                  (should (string-match-p (if failure "bad name" "Initial task was NOT sent")
                                          (buffer-string)))
                  (when failure (should-not agent-fleet-target)))
                (should-error (agent-fleet--start-form-submit) :type 'user-error))
            (kill-buffer form)))))))

(ert-deftest fleet-start-form-unknown-or-malformed-result-never-allows-another-launch ()
  (dolist (error '(nil (herdr-core-uncertain :reason timeout)))
    (save-window-excursion
      (let ((form (agent-fleet-start-form)))
        (unwind-protect
            (with-current-buffer form
              (agent-fleet-start--finish form '(:address "t1") error)
              (should (eq agent-fleet-operation-state 'uncertain))
              (should (string-match-p "Outcome unknown" (buffer-string)))
              (should buffer-read-only)
              (should-error (agent-fleet--start-form-submit) :type 'user-error)
              (should-error (agent-fleet--start-form-attach) :type 'user-error))
          (kill-buffer form))))))

(ert-deftest fleet-start-form-preflight-error-can-be-corrected-before-dispatch ()
  (fleet-test-model nil
    (save-window-excursion
      (let ((form (agent-fleet-start-form)) (calls 0))
        (unwind-protect
            (with-current-buffer form
              (widget-value-set (nth 3 agent-fleet--start-fields) "Not a template task")
              (cl-letf (((symbol-function 'agent-fleet--commands) (lambda () nil))
                        ((symbol-function 'herdr-core-request) (lambda (&rest _) '(:templates nil)))
                        ((symbol-function 'herdr-core-request-async)
                         (lambda (_method _params callback &optional _timeout)
                           (cl-incf calls) (funcall callback (fleet-test-agent "t1") nil))))
                (should-error (agent-fleet--start-form-submit) :type 'user-error)
                (should (= calls 0))
                (should (eq agent-fleet-operation-state 'invalid))
                (should-not buffer-read-only)
                (widget-value-set (nth 3 agent-fleet--start-fields) "")
                (agent-fleet--start-form-submit)
                (should (= calls 1))
                (should (eq agent-fleet-operation-state 'started))))
          (kill-buffer form))))))

(ert-deftest fleet-start-form-validates-local-input-before-locking-and-tolerates-closed-buffer ()
  (save-window-excursion
    (let ((form (agent-fleet-start-form)))
      (unwind-protect
          (with-current-buffer form
            (cl-letf (((symbol-function 'agent-fleet--commands) (lambda () nil)))
              (widget-value-set (car agent-fleet--start-fields) "")
              (should-error (agent-fleet--start-form-submit) :type 'user-error)
              (should-not agent-fleet-operation-state)
              (should-not buffer-read-only)))
        (kill-buffer form))
      (should-not (agent-fleet-start--finish form (fleet-test-agent "t1") nil)))))

(ert-deftest fleet-common-commands-resolve-the-dashboard-row-and-attach-target ()
  (fleet-test-model (list (fleet-test-agent "t1"))
    (with-temp-buffer
      (agent-fleet-mode)
      (setq tabulated-list-entries '(("t1" ["one" "—" "agent" "idle" "—" "t1"])))
      (tabulated-list-print)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'agent-fleet-read-agent) (lambda (&rest _) (ert-fail "Asked again"))))
        (should (equal (agent-fleet-current-target)
                       (agent-fleet-reference (herdr-core-terminal "t1"))))
        (let ((inhibit-read-only t)) (erase-buffer))
        (should-error (agent-fleet-current-target) :type 'user-error)))
    (with-temp-buffer
      (setq agent-fleet-target (agent-fleet-reference (herdr-core-terminal "t1")))
      (cl-letf (((symbol-function 'agent-fleet-read-agent) (lambda (&rest _) (ert-fail "Asked again"))))
        (should (equal (eval (cadr (interactive-form #'agent-fleet-details)))
                       (list agent-fleet-target)))))))

(ert-deftest fleet-common-presentations-use-the-recorded-origin-handler ()
  (save-window-excursion
    (let ((view (generate-new-buffer " *fleet-origin-view*"))
          (origin (generate-new-buffer " *fleet-origin*")) routed)
      (unwind-protect
          (with-temp-buffer
            (setq agent-fleet-presentation-function
                  (lambda (thunk)
                    (setq routed t)
                    (with-current-buffer origin (funcall thunk))))
            (should (eq view (agent-fleet-present-buffer view)))
            (should routed)
            (setq routed nil)
            (cl-letf (((symbol-function 'agent-fleet-attach--open)
                       (lambda (target observe)
                         (should (eq (current-buffer) origin))
                         (should (equal target "t1"))
                         (should observe)
                         view)))
              (should (eq view (agent-fleet-observe "t1")))
              (should routed)))
        (kill-buffer view) (kill-buffer origin)))))

(ert-deftest fleet-dashboard-start-focus-survives-response-before-event ()
  (fleet-test-model nil
    (let ((buffer (get-buffer-create "*Agent Fleet*")))
      (unwind-protect
          (with-current-buffer buffer
            (agent-fleet-mode)
            (agent-fleet-dashboard-focus "t1")
            (should (equal agent-fleet-dashboard--pending-focus "t1"))
            (puthash "t1" (fleet-test-agent "t1") herdr-core--terminals)
            (agent-fleet-dashboard-refresh)
            (should (equal (tabulated-list-get-id) "t1"))
            (should-not agent-fleet-dashboard--pending-focus))
        (kill-buffer buffer)))))

(ert-deftest fleet-dashboard-hiding-or-removing-selected-record-keeps-a-usable-row ()
  (fleet-test-model (list (fleet-test-agent "t1") (fleet-test-agent "t2" "finished"))
    (let ((buffer (get-buffer-create "*Agent Fleet*")))
      (unwind-protect
          (with-current-buffer buffer
            (agent-fleet-mode)
            (setq agent-fleet-dashboard--history t)
            (agent-fleet-dashboard-refresh)
            (agent-fleet-dashboard-focus "t2")
            (agent-fleet-dashboard-history)
            (should (equal (tabulated-list-get-id) "t1"))
            (should-not agent-fleet-dashboard--pending-focus)
            (agent-fleet-dashboard-focus "t2")
            (should (equal (tabulated-list-get-id) "t1"))
            (should-not agent-fleet-dashboard--pending-focus)
            (puthash "t3" (fleet-test-agent "t3") herdr-core--terminals)
            (remhash "t1" herdr-core--terminals)
            (agent-fleet-dashboard-refresh)
            (should (equal (tabulated-list-get-id) "t3"))
            (should-not agent-fleet-dashboard--pending-focus))
        (kill-buffer buffer)))))

(ert-deftest fleet-dashboard-empty-state-and-hidden-pending-launch-are-explicit ()
  (fleet-test-model (list (fleet-test-agent "t1"))
    (let ((buffer (get-buffer-create "*Agent Fleet*")))
      (unwind-protect
          (with-current-buffer buffer
            (agent-fleet-mode)
            (agent-fleet-dashboard-refresh)
            (agent-fleet-dashboard-focus "t2")
            (should (equal (tabulated-list-get-id) "t1"))
            (setq agent-fleet-dashboard--attention t)
            (puthash "t2" (fleet-test-agent "t2") herdr-core--terminals)
            (agent-fleet-dashboard-refresh)
            (should-not agent-fleet-dashboard--pending-focus)
            (should (string-match-p "No agents match" (buffer-string)))
            (should (string-match-p "0/2" header-line-format))
            (agent-fleet-dashboard-attention)
            (should (tabulated-list-get-id))
            (should-not (string-match-p "No agents match" (buffer-string))))
        (kill-buffer buffer)))))

(ert-deftest fleet-public-commands-autoload-in-a-fresh-emacs ()
  (let ((script (make-temp-file "fleet-autoload-" nil ".el"))
        (directory default-directory))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "(load \"agent-fleet-autoloads\")\n"
                    "(dolist (command '(agent-fleet agent-fleet-start agent-fleet-start-for-project "
                    "agent-fleet-start-form agent-fleet-adopt agent-fleet-prompt "
                    "agent-fleet-show-output agent-fleet-attach agent-fleet-cleanup "
                    "agent-fleet-start-worktree agent-fleet-start-batch agent-fleet-observe "
                    "agent-fleet-start-remote agent-fleet-send-file "
                    "agent-fleet-magit-status agent-fleet-details herdr-core-connect)) "
                    "(unless (commandp command) (error \"Missing autoload: %s\" command)))\n"
                    "(autoload-do-load (symbol-function 'agent-fleet-command-map) 'agent-fleet-command-map)\n"
                    "(unless (keymapp (symbol-function 'agent-fleet-command-map)) (error \"Missing map\"))\n"
                    "(require 'agent-fleet-attach)\n"
                    "(unless (eq (lookup-key agent-fleet-attach-mode-map (kbd \"C-c a\")) agent-fleet-command-map) (error \"Attach map diverged\"))\n"
                    "(dolist (symbol '(herdr-connect consult-agent-fleet-mode agent-fleet-attach-command-map)) "
                    "(when (fboundp symbol) (error \"Obsolete autoload: %s\" symbol)))"))
          (should (= 0 (call-process (expand-file-name invocation-name invocation-directory)
                                    nil nil nil "-Q" "--batch" "-L" directory "-l" script))))
      (delete-file script))))

(provide 'agent-fleet-core-test)
