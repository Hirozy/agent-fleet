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

(defun herdr-integration-test--pump (secs)
  "Drain Herdr socket output for SECS via `accept-process-output'.
Pushed events arrive asynchronously on the subscription/request sockets;
in batch ERT `sit-for' does not reliably drain them, so live tests that
wait for a pushed event pump explicitly (mirrors the mock harness's
`agent-fleet-test--pump')."
  (let ((end (+ (float-time) secs)))
    (while (< (float-time) end)
      (accept-process-output nil 0.05))))

(ert-deftest herdr-live-ping ()
  "Live: ping returns a pong whose protocol meets the client minimum.
The server's protocol is whatever the live install reports (it rises over
time); the client accepts any protocol >= `herdr-required-protocol-version',
so this asserts the floor, not an exact version."
  (skip-unless (herdr-integration-test--livep))
  (let ((pong (herdr-protocol-ping :timeout 5.0)))
    (should (equal (plist-get pong :type) "pong"))
    (should (>= (plist-get pong :protocol) herdr-required-protocol-version))))

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
  "Live: focusing a workspace produces a pushed focus event on the bus.
Re-focusing the ALREADY-focused workspace is a server no-op (it emits
nothing), so this focuses a different workspace and then restores the
original focus.  Skips when fewer than two workspaces are live (no focus
change can be generated)."
  (skip-unless (herdr-integration-test--livep))
  (let (events original-focus other)
    (unwind-protect
        (progn
          (herdr-connect)
          (herdr-integration-test--pump 0.5)
          (add-hook 'herdr-event-hook
                    (lambda (d)
                      (when (member (plist-get d :event)
                                    '("workspace_focused" "pane_focused"))
                        (push (plist-get d :event) events))))
          ;; Pick a workspace that is NOT already focused — re-focusing the
          ;; current one is a server no-op and emits no event.
          (setq original-focus (herdr-workspace-id (herdr-focused-workspace)))
          (setq other (car (delq original-focus
                                 (mapcar #'herdr-workspace-id (herdr-workspaces)))))
          (skip-unless other)        ; need >=2 workspaces to force a change
          (herdr-request "workspace.focus"
                          `(("workspace_id" . ,other)))
          (herdr-integration-test--pump 1.5)
          (should events))
      (ignore-errors
        (when (and original-focus other)
          (herdr-request "workspace.focus"
                          `(("workspace_id" . ,original-focus))))
        (herdr-disconnect)))))

(provide 'herdr-integration-test)
;;; herdr-integration-test.el ends here
