;;; herdr-events-test.el --- ERT tests for herdr-events.el -*- lexical-binding: t; -*-

;; Pure unit tests (no Herdr, no mock): subscription set computation,
;; rebuild detection, and event dispatch into the cache + hooks.

;;; Code:

(require 'ert)
(require 'herdr-model)
(require 'herdr-events)

(defun herdr-events-test--session ()
  "A session with two panes (one with an agent)."
  (let ((session (herdr-model--empty-session)))
    (puthash "w1:p1"
             (make-herdr-pane :id "w1:p1" :agent "claude" :agent-status "working")
             (herdr-session-panes session))
    (puthash "w1:p2"
             (make-herdr-pane :id "w1:p2" :agent nil :agent-status nil)
             (herdr-session-panes session))
    session))

(ert-deftest herdr-events-default-subscriptions ()
  "The default subscription set covers all global event types."
  (let ((subs (herdr-events-default-subscriptions)))
    (should (seq-find (lambda (s) (equal (cdr (assoc "type" s))
                                         "workspace.created"))
                      subs))
    (should (seq-find (lambda (s) (equal (cdr (assoc "type" s))
                                         "pane.agent_detected"))
                      subs))
    (should (seq-find (lambda (s) (equal (cdr (assoc "type" s))
                                         "layout.updated"))
                      subs))))

(ert-deftest herdr-events-pane-subscriptions ()
  "One per-pane agent_status subscription per current pane."
  (let ((subs (herdr-events-pane-subscriptions (herdr-events-test--session))))
    (should (= 2 (length subs)))
    (should (seq-find (lambda (s)
                        (and (equal (cdr (assoc "type" s))
                                    "pane.agent_status_changed")
                             (equal (cdr (assoc "pane_id" s)) "w1:p1")))
                      subs))
    (should (seq-find (lambda (s)
                        (and (equal (cdr (assoc "type" s))
                                    "pane.agent_status_changed")
                             (equal (cdr (assoc "pane_id" s)) "w1:p2")))
                      subs))))

(ert-deftest herdr-events-rebuild-needed ()
  "Rebuild is needed for pane-set changes, not for status/output."
  (should (herdr-events-rebuild-needed-p
           '(:event "pane_created" :what :pane-updated :id "x")))
  (should (herdr-events-rebuild-needed-p
           '(:event "pane_closed" :what :pane-closed :id "x")))
  (should (herdr-events-rebuild-needed-p
           '(:event "pane_moved" :what :pane-updated :id "x")))
  (should-not (herdr-events-rebuild-needed-p
               '(:event "pane_output_changed" :what :pane-output :id "x")))
  (should-not (herdr-events-rebuild-needed-p
               '(:event "pane_agent_status_changed" :what :agent-status :id "x")))
  (should-not (herdr-events-rebuild-needed-p nil)))

(ert-deftest herdr-events-dispatch-updates-cache-and-hook ()
  "Dispatch reconciles the cache and runs the catch-all hook."
  (let ((session (herdr-events-test--session))
        (fired nil))
    (herdr-model-set-cache session)
    (add-hook 'herdr-event-hook
              (lambda (d) (push (plist-get d :event) fired)))
    (unwind-protect
        (progn
          (herdr-events-dispatch "pane_agent_status_changed"
                                 '(:pane_id "w1:p1" :agent_status "done"
                                   :agent (:pane_id "w1:p1" :agent "claude"
                                           :agent_status "done")))
          (should (equal (herdr-agent-agent-status
                          (herdr-model-find-agent session "w1:p1"))
                         "done"))
          (should (member "pane_agent_status_changed" fired)))
      (remove-hook 'herdr-event-hook
                   (lambda (d) (push (plist-get d :event) fired)))
      (herdr-model-clear-cache))))

(ert-deftest herdr-events-dispatch-no-cache ()
  "Dispatch with no cache is a no-op (returns nil, no hook)."
  (herdr-model-clear-cache)
  (should (null (herdr-events-dispatch "workspace_focused"
                                        '(:workspace_id "w1")))))

(provide 'herdr-events-test)
;;; herdr-events-test.el ends here
