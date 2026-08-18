;;; herdr-integration-test.el --- Live Herdr integration tests -*- lexical-binding: t; -*-

;; These tests connect to a REAL Herdr server.  They are skipped unless
;; the environment variable HERDR_TEST_LIVE=1 is set, so CI without a
;; Herdr install still runs the unit suite.
;;
;; Run live:
;;   HERDR_TEST_LIVE=1 emacs -batch -L . -L test -l ert \
;;       -l herdr -l test/herdr-integration-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'herdr)

(defun herdr-integration-test--livep ()
  "Return non-nil if live integration tests should run."
  (equal (getenv "HERDR_TEST_LIVE") "1"))

(ert-deftest herdr-live-ping ()
  "Live: ping returns a pong with protocol 19."
  (skip-unless (herdr-integration-test--livep))
  (let ((pong (herdr-protocol-ping :timeout 5.0)))
    (should (equal (plist-get pong :type) "pong"))
    (should (equal (plist-get pong :protocol) 19))))

(ert-deftest herdr-live-snapshot ()
  "Live: session.snapshot returns a snapshot with the expected keys."
  (skip-unless (herdr-integration-test--livep))
  (let* ((res (herdr-protocol-request "session.snapshot" nil :timeout 5.0))
         (snap (plist-get res :snapshot)))
    (should (plist-get snap :workspaces))
    (should (plist-get snap :focused_workspace_id))))

(ert-deftest herdr-live-connect-and-cache ()
  "Live: herdr-connect populates the cache and stays connected."
  (skip-unless (herdr-integration-test--livep))
  (unwind-protect
      (progn
        (herdr-connect)
        (should (herdr-connected-p))
        (should (herdr-session))
        (should (herdr-workspaces))
        ;; the focused workspace should be findable
        (should (herdr-focused-workspace)))
    (ignore-errors (herdr-disconnect))))

(ert-deftest herdr-live-subscribe-receives-focus-event ()
  "Live: a workspace.focus trigger produces a pushed focus event."
  (skip-unless (herdr-integration-test--livep))
  (let (events)
    (unwind-protect
        (progn
          (herdr-connect)
          (sit-for 0.5)
          (add-hook 'herdr-event-hook
                    (lambda (d)
                      (when (member (plist-get d :event)
                                    '("workspace_focused" "pane_focused"))
                        (push (plist-get d :event) events))))
          ;; re-focus the current workspace (non-disruptive)
          (when-let* ((ws (herdr-focused-workspace)))
            (herdr-request "workspace.focus"
                            `(("workspace_id" . ,(herdr-workspace-id ws)))))
          (sit-for 1.5)
          (should events))
      (ignore-errors (herdr-disconnect)))))

(provide 'herdr-integration-test)
;;; herdr-integration-test.el ends here
