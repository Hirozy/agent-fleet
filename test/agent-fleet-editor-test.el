;;; agent-fleet-editor-test.el --- External-editor bridge regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;;; Commentary:

;; These tests exercise the built-in Emacs server bridge without starting a
;; real server or contacting Herdr.  The presentation and server primitives
;; are mocked where necessary; the default suite must remain usable on a
;; terminal-only Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'server)
(require 'agent-fleet-display)
(require 'agent-fleet-attach)
(require 'agent-fleet-editor)

(defun agent-fleet-editor-test--origin-info (&optional buffer window)
  "Return an origin plist for BUFFER and WINDOW in the selected frame."
  (list :origin-frame (selected-frame)
        :origin-window (or window (selected-window))
        :origin-buffer (or buffer (current-buffer))))

(defun agent-fleet-editor-test--make-file-buffer ()
  "Return a cons of a temporary file name and its visited buffer."
  (let ((file (make-temp-file "agent-fleet-editor-test-" nil ".md")))
    (with-temp-file file
      (insert "draft\n"))
    (cons file (find-file-noselect file))))

(defun agent-fleet-editor-test--delete-file-buffer (file buffer)
  "Kill BUFFER and delete FILE when they are live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (set-buffer-modified-p nil))
    (kill-buffer buffer))
  (when (file-exists-p file)
    (delete-file file)))

(defun agent-fleet-editor-test--live-process ()
  "Start a harmless local process suitable for a server-process stub."
  (start-process "agent-fleet-editor-test-server" nil "cat"))

(defun agent-fleet-editor-test--stop-process (process)
  "Stop PROCESS when it is live."
  (when (process-live-p process)
    (delete-process process)))

(defun agent-fleet-editor-test--new-request
    (buffer window &optional presentation)
  "Build a minimal active request for BUFFER in WINDOW."
  (list :buffer buffer
        :pane-id "w1:p1"
        :origin-frame (window-frame window)
        :origin-window window
        :origin-buffer (window-buffer window)
        :presentation presentation
        :presentation-window (and presentation window)
        :presentation-created-p (eq presentation 'side-window)
        :finished nil))

(ert-deftest agent-fleet-editor-disabled-does-not-start-server ()
  "Disabling or loading the bridge does not load/start the server."
  (let ((starts 0)
        (was-loaded (featurep 'server))
        (agent-fleet-editor-bridge-mode nil))
    (cl-letf (((symbol-function 'server-start)
               (lambda (&rest _) (cl-incf starts))))
      (agent-fleet-editor-bridge-mode -1))
    (should (= starts 0))
    ;; This test file loads server for the remaining API tests, but the
    ;; assertion documents the no-side-effect boundary when it starts clean.
    (should (eq was-loaded (featurep 'server)))))

(ert-deftest agent-fleet-editor-reuses-local-server ()
  "A live server process is reused without calling server-start or renaming."
  (let* ((process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-name "editor-test-existing")
         (original-name server-name)
         (starts 0)
         (agent-fleet-editor-bridge-mode nil))
    (unwind-protect
        (cl-letf (((symbol-function 'server-start)
                   (lambda (&rest _) (cl-incf starts)))
                  ((symbol-function 'server-running-p)
                   (lambda (&optional _) (error "must not probe external server"))))
          (agent-fleet-editor-bridge-mode 1)
          (should agent-fleet-editor-bridge-mode)
          (should (= starts 0))
          (should (equal original-name server-name)))
      (agent-fleet-editor-bridge-mode -1)
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-auto-starts-local-server ()
  "Auto-start creates and verifies a live server process."
  (let ((server-process nil)
        (server-name "editor-test-auto")
        (starts 0)
        (process nil)
        (agent-fleet-editor-bridge-mode nil))
    (unwind-protect
        (cl-letf (((symbol-function 'server-running-p)
                   (lambda (&optional _) nil))
                  ((symbol-function 'server-start)
                   (lambda (&rest _)
                     (cl-incf starts)
                     (setq process (agent-fleet-editor-test--live-process))
                     (setq server-process process))))
          (agent-fleet-editor-bridge-mode 1)
          (should agent-fleet-editor-bridge-mode)
          (should (= starts 1))
          (should (process-live-p server-process)))
      (agent-fleet-editor-bridge-mode -1)
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-auto-start-disabled-errors ()
  "Without auto-start, an absent local server leaves the mode disabled."
  (let ((server-process nil)
        (agent-fleet-editor-auto-start-server nil)
        (agent-fleet-editor-bridge-mode nil)
        (starts 0))
    (cl-letf (((symbol-function 'server-running-p)
               (lambda (&optional _) nil))
              ((symbol-function 'server-start)
               (lambda (&rest _) (cl-incf starts))))
      (should-error (agent-fleet-editor-bridge-mode 1) :type 'user-error)
      (should-not agent-fleet-editor-bridge-mode)
      (should (= starts 0)))))

(ert-deftest agent-fleet-editor-auto-start-failure-disables-mode ()
  "A server-start error is translated to user-error and disables the mode."
  (let ((server-process nil)
        (agent-fleet-editor-bridge-mode nil))
    (cl-letf (((symbol-function 'server-running-p)
               (lambda (&optional _) nil))
              ((symbol-function 'server-start)
               (lambda (&rest _) (error "socket unavailable"))))
      (should-error (agent-fleet-editor-bridge-mode 1) :type 'user-error)
      (should-not agent-fleet-editor-bridge-mode))))

(ert-deftest agent-fleet-editor-rejects-external-server-name ()
  "A same-name server owned by another Emacs is not treated as local."
  (let ((server-process nil)
        (server-name "editor-test-external")
        (agent-fleet-editor-bridge-mode nil)
        (starts 0))
    (cl-letf (((symbol-function 'server-running-p)
               (lambda (&optional _) t))
              ((symbol-function 'server-start)
               (lambda (&rest _) (cl-incf starts))))
      (should-error (agent-fleet-editor-bridge-mode 1) :type 'user-error)
      (should-not agent-fleet-editor-bridge-mode)
      (should (= starts 0)))))

(ert-deftest agent-fleet-editor-arm-sends-exact-pane-and-key ()
  "Arming sends exactly Ctrl-G to the local attach pane and no Enter."
  (let* ((process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'before)
         (agent-fleet-editor-bridge-mode t)
         (agent-fleet-editor-route-timeout 60)
         (sent nil)
         (route nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-attach--current-pane-id)
                   (lambda () "w7:p9"))
                  ((symbol-function 'agent-fleet-send-keys)
                   (lambda (pane keys)
                     (push (list pane keys) sent))))
          (with-temp-buffer
            (setq route (agent-fleet-editor-arm-current-attach))
            (should (equal '("w7:p9" "ctrl+g") (car sent)))
            (should-not (member "enter" (mapcar #'cadr sent)))
            (should (eq server-window (plist-get route :dispatcher)))
            (agent-fleet-editor--clear-pending-route route)
            (should (eq server-window 'before))))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-send-failure-clears-route ()
  "A failed Ctrl-G send restores the previous server-window."
  (let* ((process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (agent-fleet-editor-route-timeout 60))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-attach--current-pane-id)
                   (lambda () "w1:p1"))
                  ((symbol-function 'agent-fleet-send-keys)
                   (lambda (&rest _) (error "send failed"))))
          (with-temp-buffer
            (should-error (agent-fleet-editor-arm-current-attach))
            (should-not agent-fleet-editor--pending-route)
            (should (eq server-window 'previous))))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-rejects-duplicate-route ()
  "A second pending route is rejected without replacing the first."
  (let* ((process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (agent-fleet-editor-route-timeout 60)
         (info (agent-fleet-editor-test--origin-info))
         (first nil))
    (unwind-protect
        (progn
          (setq first (agent-fleet-editor--arm-route "w1:p1" info))
          (should-error (agent-fleet-editor--arm-route "w1:p2" info)
                        :type 'user-error)
          (should (eq first agent-fleet-editor--pending-route))
          (agent-fleet-editor--clear-pending-route first)
          (should (eq server-window 'previous)))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-rejects-overlapping-active-request ()
  "A new C-g is rejected while an earlier editor client is still active."
  (let* ((process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (agent-fleet-editor--active-requests '((:finished nil))))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-attach--current-pane-id)
                   (lambda () "w1:p1")))
          (should-error (agent-fleet-editor-arm-current-attach)
                        :type 'user-error)
          (should-not agent-fleet-editor--pending-route)
          (should (eq server-window 'previous)))
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-route-timeout-restores-window ()
  "Route timeout restores the exact previous server-window value."
  (let* ((process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (info (agent-fleet-editor-test--origin-info))
         (route (agent-fleet-editor--arm-route "w1:p1" info)))
    (unwind-protect
        (progn
          (agent-fleet-editor--route-timeout route)
          (should-not agent-fleet-editor--pending-route)
          (should (eq server-window 'previous)))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-route-does-not-clobber-replacement ()
  "Cleanup leaves another component's replacement server-window untouched."
  (let* ((process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (route (agent-fleet-editor--arm-route
                 "w1:p1" (agent-fleet-editor-test--origin-info))))
    (unwind-protect
        (progn
          (setq server-window 'replacement)
          (agent-fleet-editor--clear-pending-route route)
          (should (eq server-window 'replacement)))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-sequential-routes-do-not-strand-waiting-client ()
  "A completed editor request leaves the bridge ready for the next request."
  (let* ((first-file-buffer (agent-fleet-editor-test--make-file-buffer))
         (first-file (car first-file-buffer))
         (first-buffer (cdr first-file-buffer))
         (second-file-buffer (agent-fleet-editor-test--make-file-buffer))
         (second-file (car second-file-buffer))
         (second-buffer (cdr second-file-buffer))
         (process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (agent-fleet-editor-route-timeout 60)
         (info (agent-fleet-editor-test--origin-info))
         (first-route nil)
         (second-route nil)
         (first-request nil)
         (second-request nil))
    (unwind-protect
        (progn
          (setq first-route (agent-fleet-editor--arm-route "w1:p1" info))
          (agent-fleet-editor--dispatch-server-buffer first-buffer first-route)
          (setq first-request (car agent-fleet-editor--active-requests))
          (should first-request)
          (agent-fleet-editor--finish-request first-request 'abort)
          (should-not agent-fleet-editor--active-requests)
          (setq second-route (agent-fleet-editor--arm-route "w1:p1" info))
          (agent-fleet-editor--dispatch-server-buffer second-buffer second-route)
          (setq second-request (car agent-fleet-editor--active-requests))
          (should second-request)
          (should-not (eq first-request second-request))
          (should (eq second-buffer (plist-get second-request :buffer)))
          (agent-fleet-editor--finish-request second-request 'abort)
          (should-not agent-fleet-editor--active-requests))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (when agent-fleet-editor--active-requests
        (ignore-errors
          (agent-fleet-editor--finish-request
           (car agent-fleet-editor--active-requests) 'abort)))
      (agent-fleet-editor-test--delete-file-buffer first-file first-buffer)
      (agent-fleet-editor-test--delete-file-buffer second-file second-buffer)
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-server-window-consume-and-open-side-window ()
  "A file visit consumes the route without replacing the attach buffer."
  (let* ((file-buffer (agent-fleet-editor-test--make-file-buffer))
         (file (car file-buffer))
         (buffer (cdr file-buffer))
         (origin-window (selected-window))
         (origin-buffer (window-buffer origin-window))
         (process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (route (agent-fleet-editor--arm-route
                 "w1:p1"
                 (agent-fleet-editor-test--origin-info origin-buffer
                                                        origin-window)))
         request
         side-window)
    (unwind-protect
        (progn
          (funcall (plist-get route :dispatcher) buffer)
          (should-not agent-fleet-editor--pending-route)
          (should (eq server-window 'previous))
          (should (eq (window-buffer origin-window) origin-buffer))
          (setq request agent-fleet-editor--request)
          (should request)
          (setq side-window (plist-get request :presentation-window))
          (should (window-live-p side-window))
          (should-not (eq side-window origin-window))
          (should (eq (window-buffer side-window) buffer))
          (should (eq (window-parameter side-window 'window-side) 'right))
          (should (eq (buffer-local-value 'agent-fleet-editor-buffer-mode
                                          buffer)
                      t))
          (agent-fleet-editor--finish-request request 'abort)
          (should-not (window-live-p side-window))
          (should (eq (window-buffer origin-window) origin-buffer))
          (should-not (buffer-local-value 'agent-fleet-editor-buffer-mode
                                          buffer)))
      (when (and request
                 (not (plist-get request :finished)))
        (ignore-errors (agent-fleet-editor--finish-request request 'abort)))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (when (window-live-p origin-window)
        (set-window-buffer origin-window origin-buffer))
      (agent-fleet-editor-test--delete-file-buffer file buffer)
      (agent-fleet-editor-test--stop-process process))))

(ert-deftest agent-fleet-editor-side-window-keeps-origin-visible ()
  "Side presentation keeps the attach buffer visible and owns a new window."
  (let* ((file-buffer (agent-fleet-editor-test--make-file-buffer))
         (file (car file-buffer))
         (buffer (cdr file-buffer))
         (origin-window (selected-window))
         (origin-buffer (window-buffer origin-window))
         (request (agent-fleet-editor-test--new-request buffer origin-window))
         side-window
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (progn
          (agent-fleet-editor--present-request request)
          (setq side-window (plist-get request :presentation-window))
          (should (window-live-p side-window))
          (should-not (eq side-window origin-window))
          (should (eq (window-buffer origin-window) origin-buffer))
          (should (eq (window-buffer side-window) buffer))
          (should (eq (window-parameter side-window 'window-side) 'right))
          (should (eq (window-parameter
                       side-window 'agent-fleet-editor-request)
                      request))
          (agent-fleet-editor--finish-request request 'abort)
          (should-not (window-live-p side-window))
          (should (eq (window-buffer origin-window) origin-buffer)))
      (agent-fleet-editor-test--delete-file-buffer file buffer))))

(ert-deftest agent-fleet-editor-side-window-refuses-existing-window-reuse ()
  "Presentation rolls back instead of replacing an existing window."
  (let* ((buffer (generate-new-buffer " *af-editor-no-reuse*"))
         (origin-window (selected-window))
         (request (agent-fleet-editor-test--new-request buffer origin-window))
         (restored nil))
    (unwind-protect
        (cl-letf (((symbol-function 'window-state-get)
                   (lambda (&rest _) 'saved-state))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) origin-window))
                  ((symbol-function 'window-state-put)
                   (lambda (state &rest _) (setq restored state))))
          (should-error
           (agent-fleet-editor--present-request request)
           :type 'user-error)
          (should (eq restored 'saved-state))
          (should-not (plist-get request :presentation)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-side-window-display-error-rolls-back ()
  "A display error restores the synchronous pre-display window state."
  (let* ((buffer (generate-new-buffer " *af-editor-display-error*"))
         (origin-window (selected-window))
         (request (agent-fleet-editor-test--new-request buffer origin-window))
         (restored nil))
    (unwind-protect
        (cl-letf (((symbol-function 'window-state-get)
                   (lambda (&rest _) 'saved-state))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) (error "display failed")))
                  ((symbol-function 'window-state-put)
                   (lambda (state &rest _) (setq restored state))))
          (should-error
           (agent-fleet-editor--present-request request)
           :type 'error)
          (should (eq restored 'saved-state))
          (should-not (plist-get request :presentation)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-side-window-server-kill-closes-window ()
  "Killing the server buffer during release still removes its side window."
  (let* ((buffer (generate-new-buffer " *af-editor-side-server-kill*"))
         (origin-window (selected-window))
         (origin-buffer (window-buffer origin-window))
         (request (agent-fleet-editor-test--new-request buffer origin-window))
         side-window
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local agent-fleet-editor--request request)
            (agent-fleet-editor-buffer-mode 1))
          (agent-fleet-editor--present-request request)
          (setq side-window (plist-get request :presentation-window))
          (cl-letf (((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (request-buffer &rest _)
                       (kill-buffer request-buffer))))
            (agent-fleet-editor--finish-request request 'abort))
          (should-not (buffer-live-p buffer))
          (should-not (window-live-p side-window))
          (should (eq (window-buffer origin-window) origin-buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-submit-orders-save-release-close ()
  "Submission saves, releases the client, then closes the presentation."
  (let* ((buffer (generate-new-buffer " *af-editor-submit*"))
         (window (selected-window))
         (origin (window-buffer window))
         (request (agent-fleet-editor-test--new-request buffer window))
         (events nil)
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (push 'save events)))
                    ((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (&rest _) (push 'release events)))
                    ((symbol-function 'agent-fleet-editor--close-presentation)
                     (lambda (&rest _) (push 'close events)))
                    ((symbol-function 'modify-frame-parameters)
                     (lambda (&rest _) nil)))
            (call-interactively #'agent-fleet-editor-submit))
          (should (equal '(save release close) (nreverse events)))
          (should (plist-get request :finished))
          (should-not agent-fleet-editor-buffer-mode))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (window-live-p window)
        (set-window-buffer window origin)))))

(ert-deftest agent-fleet-editor-abort-releases-successfully-without-saving ()
  "Abort releases the server client successfully and does not save."
  (let* ((buffer (generate-new-buffer " *af-editor-abort*"))
         (window (selected-window))
         (origin (window-buffer window))
         (request (agent-fleet-editor-test--new-request buffer window))
         (client-a 'client-a)
         (server-error-sent nil)
         (done nil)
         (saved nil)
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (setq-local server-buffer-clients (list client-a))
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'server-send-string)
                     (lambda (&rest _) (setq server-error-sent t)))
                    ((symbol-function 'server-buffer-done)
                     (lambda (buf &optional for-killing)
                       (setq done (list buf for-killing))))
                    ((symbol-function 'save-buffer)
                     (lambda (&rest _) (setq saved t)))
                    ((symbol-function 'modify-frame-parameters)
                     (lambda (&rest _) nil)))
            (call-interactively #'agent-fleet-editor-abort))
          (should-not saved)
          (should-not server-error-sent)
          (should (equal done (list buffer nil)))
          (should (plist-get request :finished))
          (should-not agent-fleet-editor-buffer-mode))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (window-live-p window)
        (set-window-buffer window origin)))))

(ert-deftest agent-fleet-editor-save-error-stays-active ()
  "A failed save does not commit or close the request."
  (let* ((buffer (generate-new-buffer " *af-editor-save-error*"))
         (window (selected-window))
         (request (agent-fleet-editor-test--new-request buffer window))
         (agent-fleet-editor--active-requests (list request))
         (close-called nil))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "read-only")))
                    ((symbol-function 'agent-fleet-editor--close-presentation)
                     (lambda (&rest _) (setq close-called t))))
            (should-error (agent-fleet-editor-submit) :type 'user-error))
          (should-not (plist-get request :finished))
          (should (memq request agent-fleet-editor--active-requests))
          (should-not close-called)
          (should agent-fleet-editor-buffer-mode))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (agent-fleet-editor--finish-request request 'abort))
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-direct-buffer-kill-cleans-up ()
  "Direct buffer cleanup aborts the request and disables its local mode."
  (let* ((buffer (generate-new-buffer " *af-editor-kill*"))
         (window (selected-window))
         (request (agent-fleet-editor-test--new-request buffer window))
         (events nil)
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (&rest _) (push 'release events)))
                    ((symbol-function 'agent-fleet-editor--close-presentation)
                     (lambda (&rest _) (push 'close events))))
            (agent-fleet-editor--buffer-killed))
          (should (plist-get request :finished))
          (should (equal '(close release) events))
          (should-not agent-fleet-editor-buffer-mode))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-origin-frame-close-releases-request ()
  "Deleting the origin frame releases its editor request exactly once."
  (let* ((buffer (generate-new-buffer " *af-editor-frame-close*"))
         (window (selected-window))
         (frame (window-frame window))
         (request (agent-fleet-editor-test--new-request buffer window
                                                        'side-window))
         (released 0)
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (&rest _) (cl-incf released))))
            (agent-fleet-editor--frame-deleted frame))
          (should (= released 1))
          (should (plist-get request :finished))
          (should-not agent-fleet-editor-buffer-mode))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-side-window-loss-aborts-request ()
  "Deleting or repurposing the editor side window releases its client."
  (let* ((buffer (generate-new-buffer " *af-editor-side-window-lost*"))
         (window (selected-window))
         (frame (window-frame window))
         (request (agent-fleet-editor-test--new-request buffer window
                                                        'side-window))
         (released 0)
         (agent-fleet-editor--active-requests (list request)))
    (setf (plist-get request :presentation-window) nil)
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (&rest _) (cl-incf released))))
            (agent-fleet-editor--window-state-changed frame))
          (should (= released 1))
          (should (plist-get request :finished))
          (should-not agent-fleet-editor--active-requests)
          (should-not agent-fleet-editor-buffer-mode))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-deletion-hooks-contain-cleanup-errors ()
  "Buffer and frame deletion hooks never propagate server cleanup errors."
  (let* ((buffer (generate-new-buffer " *af-editor-hook-errors*"))
         (window (selected-window))
         (frame (window-frame window))
         (request (agent-fleet-editor-test--new-request buffer window
                                                        'side-window))
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (&rest _) (error "server cleanup failed"))))
            (should-not (agent-fleet-editor--frame-deleted frame)))
          (should (plist-get request :finished))
          (should-not agent-fleet-editor--active-requests)
          (should-not agent-fleet-editor-buffer-mode)
          ;; A finished request is a no-op if the buffer hook subsequently
          ;; runs as part of the same deletion sequence.
          (should-not (agent-fleet-editor--buffer-killed)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-close-error-clears-presentation-state ()
  "A side-window close error cannot leave presentation ownership behind."
  (let* ((buffer (generate-new-buffer " *af-editor-close-error*"))
         (window (selected-window))
         (request (agent-fleet-editor-test--new-request buffer window
                                                        'side-window))
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (&rest _) nil))
                    ((symbol-function 'set-window-parameter)
                     (lambda (&rest _) nil))
                    ((symbol-function 'set-window-dedicated-p)
                     (lambda (&rest _) nil))
                    ((symbol-function 'delete-window)
                     (lambda (&rest _) (error "window close failed"))))
            (should-error (agent-fleet-editor--finish-request request 'abort)))
          (should (plist-get request :finished))
          (should-not (plist-get request :presentation))
          (should-not (plist-get request :presentation-window))
          (should-not (plist-get request :presentation-created-p))
          (should-not agent-fleet-editor--active-requests)
          (should-not agent-fleet-editor-buffer-mode))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-mode-disable-cleans-pending-and-active ()
  "Disabling the bridge restores pending routes and aborts active requests."
  (let* ((buffer (generate-new-buffer " *af-editor-disable*"))
         (window (selected-window))
         (process (agent-fleet-editor-test--live-process))
         (server-process process)
         (server-window 'previous)
         (agent-fleet-editor-bridge-mode t)
         (request (agent-fleet-editor-test--new-request buffer window))
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (agent-fleet-editor--arm-route
           "w1:p1" (agent-fleet-editor-test--origin-info))
          (agent-fleet-editor-bridge-mode -1)
          (should-not agent-fleet-editor--pending-route)
          (should (eq server-window 'previous))
          (should (plist-get request :finished))
          (should-not agent-fleet-editor--active-requests)
          (should-not agent-fleet-editor-buffer-mode))
      (when agent-fleet-editor--pending-route
        (agent-fleet-editor--clear-pending-route
         agent-fleet-editor--pending-route))
      (agent-fleet-editor-test--stop-process process)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-presentation-error-releases-request ()
  "A presentation error still releases the server request and active state."
  (let* ((buffer (generate-new-buffer " *af-editor-present-error*"))
         (window (selected-window))
         (released nil)
         (closed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-editor--present-in-side-window)
                   (lambda (&rest _) (error "side window failed")))
                  ((symbol-function 'agent-fleet-editor--release-server-buffer)
                   (lambda (&rest _) (setq released t)))
                  ((symbol-function 'agent-fleet-editor--close-presentation)
                   (lambda (&rest _) (setq closed t))))
          (should-error
           (agent-fleet-editor--start-request
            (list :pane-id "w1:p1"
                  :origin-frame (window-frame window)
                  :origin-window window
                  :origin-buffer (window-buffer window))
            buffer))
          (should released)
          (should closed)
          (should-not agent-fleet-editor--active-requests))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-finish-is-idempotent ()
  "Repeated finish calls do not repeat save/release/close."
  (let* ((buffer (generate-new-buffer " *af-editor-idempotent*"))
         (window (selected-window))
         (request (agent-fleet-editor-test--new-request buffer window))
         (events nil)
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (push 'save events)))
                    ((symbol-function 'agent-fleet-editor--release-server-buffer)
                     (lambda (&rest _) (push 'release events)))
                    ((symbol-function 'agent-fleet-editor--close-presentation)
                     (lambda (&rest _) (push 'close events))))
            (should (agent-fleet-editor--finish-request request 'submit))
            (should-not (agent-fleet-editor--finish-request request 'submit)))
          (should (equal '(save release close) (nreverse events))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-fleet-editor-server-done-clears-buffer-mode ()
  "A server completion through another command leaves no stale local mode."
  (let* ((buffer (generate-new-buffer " *af-editor-server-done*"))
         (window (selected-window))
         (request (agent-fleet-editor-test--new-request buffer window))
         (closed nil)
         (agent-fleet-editor--active-requests (list request)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local agent-fleet-editor--request request)
          (agent-fleet-editor-buffer-mode 1)
          (cl-letf (((symbol-function 'agent-fleet-editor--close-presentation)
                     (lambda (&rest _) (setq closed t))))
            (agent-fleet-editor--server-done))
          (should closed)
          (should (plist-get request :finished))
          (should-not agent-fleet-editor-buffer-mode)
          (should-not agent-fleet-editor--active-requests))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'agent-fleet-editor-test)
;;; agent-fleet-editor-test.el ends here
