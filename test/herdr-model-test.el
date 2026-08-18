;;; herdr-model-test.el --- ERT tests for herdr-model.el -*- lexical-binding: t; -*-

;; Pure unit tests (no Herdr, no mock): snapshot parsing and event
;; reconciliation against the cache.

;;; Code:

(require 'ert)
(require 'herdr-model)

(defun herdr-model-test--snapshot ()
  "A canned snapshot plist for tests."
  '(:protocol 19 :version "0.8.0"
    :focused_workspace_id "w1" :focused_tab_id "w1:t1"
    :focused_pane_id "w1:p1"
    :workspaces ((:workspace_id "w1" :label "demo" :number 1
                  :focused t :active_tab_id "w1:t1" :tab_count 1
                  :pane_count 1 :agent_status "working"
                  :unknown_field "ignored"))
    :tabs ((:tab_id "w1:t1" :workspace_id "w1" :label "1"
            :number 1 :focused t :pane_count 1 :agent_status "working"))
    :panes ((:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
             :terminal_id "t1" :terminal_title "demo"
             :terminal_title_stripped "demo"
             :cwd "/d" :foreground_cwd "/d"
             :focused t :revision 3 :agent "claude"
             :agent_status "working"
             :agent_session (:agent "claude" :kind "id"
                              :source "herdr:claude" :value "s1")))
    :agents ((:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
              :terminal_id "t1" :terminal_title "demo"
              :terminal_title_stripped "demo"
              :cwd "/d" :foreground_cwd "/d"
              :focused t :revision 3 :state_change_seq 3
              :agent "claude" :agent_status "working"
              :agent_session (:agent "claude" :kind "id"
                              :source "herdr:claude" :value "s1")))
    :layouts ()))

(ert-deftest herdr-model-parse-snapshot-basic ()
  "Parsing a snapshot populates workspaces/tabs/panes/agents."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (should (= 1 (length (herdr-model-workspaces session))))
    (should (= 1 (length (herdr-model-tabs session))))
    (should (= 1 (length (herdr-model-panes session))))
    (should (= 1 (length (herdr-model-agents session))))
    (should (equal (herdr-session-focused-workspace-id session) "w1"))
    (should (equal (herdr-session-protocol session) 19))))

(ert-deftest herdr-model-parse-snapshot-tolerates-unknown-fields ()
  "Unknown fields in the snapshot are ignored, not stored."
  (let ((ws (car (herdr-model-workspaces
                  (herdr-model-parse-snapshot (herdr-model-test--snapshot))))))
    (should (equal (herdr-workspace-label ws) "demo"))))

(ert-deftest herdr-model-find-agent ()
  "find-agent returns the agent struct by pane id."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (let ((a (herdr-model-find-agent session "w1:p1")))
      (should (herdr-agent-p a))
      (should (equal (herdr-agent-agent a) "claude"))
      (should (equal (herdr-agent-agent-status a) "working")))))

(ert-deftest herdr-model-apply-event-workspace-focused ()
  "A workspace_focused event updates the focused workspace id."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-apply-event session "workspace_focused"
                             '(:workspace_id "w2"))
    (should (equal (herdr-session-focused-workspace-id session) "w2"))))

(ert-deftest herdr-model-apply-event-agent-status ()
  "An agent_status_changed event updates the agent status."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-apply-event session "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "blocked"
                               :agent (:pane_id "w1:p1" :agent "claude"
                                       :agent_status "blocked")))
    (should (equal (herdr-agent-agent-status
                    (herdr-model-find-agent session "w1:p1"))
                   "blocked"))
    (should (equal (herdr-pane-agent-status
                    (herdr-model-find-pane session "w1:p1"))
                   "blocked"))))

(ert-deftest herdr-model-apply-event-pane-created-then-closed ()
  "A created pane appears, and a closed pane (and its agent) disappears."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-apply-event session "pane_created"
                             '(:pane (:pane_id "w2:p1" :workspace_id "w2"
                                      :tab_id "w2:t1" :agent "codex"
                                      :agent_status "idle" :cwd "/x")))
    (should (= 2 (length (herdr-model-panes session))))
    (should (herdr-model-find-agent session "w2:p1"))
    (herdr-model-apply-event session "pane_closed"
                             '(:pane_id "w2:p1"))
    (should (= 1 (length (herdr-model-panes session))))
    (should-not (herdr-model-find-agent session "w2:p1"))))

(ert-deftest herdr-model-apply-event-returns-descriptor ()
  "apply-event returns a descriptor plist with :event and :what."
  (let* ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot)))
         (d (herdr-model-apply-event session "workspace_focused"
                                     '(:workspace_id "w9"))))
    (should (equal (plist-get d :event) "workspace_focused"))
    (should (eq (plist-get d :what) ':workspace-focused))))

(provide 'herdr-model-test)
;;; herdr-model-test.el ends here
