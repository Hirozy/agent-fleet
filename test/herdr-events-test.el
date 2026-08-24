;;; herdr-events-test.el --- ERT tests for herdr-events.el -*- lexical-binding: t; -*-

;; Pure unit tests (no Herdr, no mock): subscription set computation,
;; rebuild detection, and event dispatch into the cache + hooks.

;;; Code:

(require 'ert)
(require 'herdr-model)
(require 'herdr-events)

(defun herdr-events-test--session ()
  "A session with two panes (one with an agent).
w1:p1 has a cached agent (established by the snapshot or a prior
`pane_agent_detected') — a status event only PATCHES an existing agent, it
never creates one (the per-pane `PaneAgentStatusChangedEvent' carries the
agent kind as a bare string, not an AgentInfo struct)."
  (let ((session (herdr-model--empty-session)))
    (puthash "w1:p1"
             (make-herdr-pane :id "w1:p1" :agent "claude" :agent-status "working")
             (herdr-session-panes session))
    (puthash "w1:p2"
             (make-herdr-pane :id "w1:p2" :agent nil :agent-status nil)
             (herdr-session-panes session))
    (puthash "w1:p1"
             (make-herdr-agent :id "w1:p1" :workspace-id "w1"
                              :agent "claude" :agent-status "working")
             (herdr-session-agents session))
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

(ert-deftest herdr-events-rebuild-needed-ignores-replay ()
  "A replayed pane-set event does not queue a resubscribe.
`apply-event' flags a replayed `pane_created' (a pane already cached or
remembered gone) :replayp.  Rebuilding the per-pane set for it would
resubscribe on every replayed create, and each resubscribe itself
replays — an infinite loop.  So `rebuild-needed-p' must return nil for a
:replayp descriptor even when the event kind normally triggers a
rebuild.  The same kind WITHOUT :replayp still triggers one."
  (should-not (herdr-events-rebuild-needed-p
               '(:event "pane_created" :what :pane-replayed :id "x" :replayp t)))
  (should (herdr-events-rebuild-needed-p
           '(:event "pane_created" :what :pane-updated :id "x")))
  ;; Parent closes also cascade pane removals and therefore rebuild.
  (should (herdr-events-rebuild-needed-p
           '(:event "tab_closed" :what :tab-closed :id "t1")))
  (should-not (herdr-events-rebuild-needed-p
               '(:event "workspace_closed" :what :workspace-closed
                 :id "w1" :replayp t))))

(ert-deftest herdr-events-dispatch-updates-cache-and-hook ()
  "Dispatch reconciles the cache and runs the catch-all hook."
  (let ((session (herdr-events-test--session))
        (herdr-event-hook nil)
        (fired nil))
    (herdr-model-set-cache session)
    (add-hook 'herdr-event-hook
              (lambda (d) (push (plist-get d :event) fired)))
    (unwind-protect
        (progn
          (herdr-events-dispatch "pane_agent_status_changed"
                                 '(:pane_id "w1:p1" :agent_status "done"
                                   :agent "claude"))
          (should (equal (herdr-agent-agent-status
                          (herdr-model-find-agent session "w1:p1"))
                         "done"))
          ;; identity preserved — the status event patches in place, it
          ;; does not replace the cached agent (the agent kind is a bare
          ;; string, not an AgentInfo struct to parse-and-replace):
          (should (equal (herdr-agent-id
                          (herdr-model-find-agent session "w1:p1"))
                         "w1:p1"))
          (should (member "pane_agent_status_changed" fired)))
      (herdr-model-clear-cache))))

(ert-deftest herdr-events-parent-close-fans-out-agent-exits ()
  "A workspace close emits one pane lifecycle descriptor per child agent."
  (let ((session (herdr-events-test--session))
        (herdr-event-pane-hook nil)
        exits)
    (herdr-model-set-cache session)
    (add-hook 'herdr-event-pane-hook
              (lambda (descriptor)
                (when (eq :pane-closed (plist-get descriptor :what))
                  (push descriptor exits))))
    (unwind-protect
        (progn
          (herdr-events-dispatch "workspace_closed" '(:workspace_id "w1"))
          (should (= 1 (length exits)))
          (should (equal "w1:p1" (plist-get (car exits) :id)))
          (should (plist-get (car exits) :agentp)))
      (herdr-model-clear-cache))))

(ert-deftest herdr-events-dispatch-no-cache ()
  "Dispatch with no cache is a no-op (returns nil, no hook)."
  (herdr-model-clear-cache)
  (should (null (herdr-events-dispatch "workspace_focused"
                                        '(:workspace_id "w1")))))

(ert-deftest herdr-events-dispatch-worktree-hook ()
  "A worktree event runs `herdr-event-worktree-hook' and reconciles the cache.
The hook is let-bound to nil so no lambdas leak across tests (the add-hook
acts on the dynamic binding, restored on exit)."
  (let ((session (herdr-events-test--session))
        (herdr-event-worktree-hook nil)
        (fired nil))
    (herdr-model-set-cache session)
    (add-hook 'herdr-event-worktree-hook
              (lambda (d) (push (plist-get d :what) fired)))
    (unwind-protect
        (progn
          (herdr-events-dispatch "worktree_created"
                                 '(:worktree (:path "/r/wt1"
                                              :open_workspace_id "wt1")
                                   :workspace (:workspace_id "wt1" :label "wt1")))
          (should (memq :worktree-created fired))
          (herdr-events-dispatch "worktree_removed"
                                 '(:worktree (:path "/r/wt1")
                                   :workspace_id "wt1" :forced :false))
          (should (memq :worktree-removed fired))
          ;; created then removed -> the worktree is gone from the cache.
          (should-not (herdr-model-find-worktree session "/r/wt1")))
      (herdr-model-clear-cache))))

(provide 'herdr-events-test)
;;; herdr-events-test.el ends here
