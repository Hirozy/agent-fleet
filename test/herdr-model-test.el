;;; herdr-model-test.el --- ERT tests for herdr-model.el -*- lexical-binding: t; -*-

;; Pure unit tests (no Herdr, no mock): snapshot parsing and event
;; reconciliation against the cache.

;;; Code:

(require 'ert)
(require 'herdr-model)

(defun herdr-model-test--snapshot ()
  "A canned snapshot plist for tests."
  '(:protocol 20 :version "0.8.2"
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


(defun herdr-model-test--snapshot-with (ws-id label pane-cwd)
  "A one-workspace/one-root-pane snapshot for label-derivation tests.
The workspace WS-ID has wire LABEL and a single root pane (`WS-ID:p1',
cwd PANE-CWD).  When LABEL = basename(PANE-CWD) the workspace has no
custom name (label auto-derived from cwd); otherwise the parse
post-pass freezes LABEL as `custom-name' (a pre-connect rename)."
  `(:protocol 20 :version "0.8.2"
    :focused_workspace_id ,ws-id :focused_tab_id ,(concat ws-id ":t1")
    :focused_pane_id ,(concat ws-id ":p1")
    :workspaces ((:workspace_id ,ws-id :label ,label :number 1
                  :focused t :active_tab_id ,(concat ws-id ":t1")
                  :tab_count 1 :pane_count 1 :agent_status "idle"))
    :tabs ((:tab_id ,(concat ws-id ":t1") :workspace_id ,ws-id
            :label "1" :number 1 :focused t :pane_count 1
            :agent_status "idle"))
    :panes ((:pane_id ,(concat ws-id ":p1") :workspace_id ,ws-id
             :tab_id ,(concat ws-id ":t1") :terminal_id "t1"
             :terminal_title ,label :terminal_title_stripped ,label
             :cwd ,pane-cwd :foreground_cwd ,pane-cwd
             :focused t :revision 0 :agent "claude" :agent_status "idle"))
    :agents ((:pane_id ,(concat ws-id ":p1") :workspace_id ,ws-id
              :tab_id ,(concat ws-id ":t1") :terminal_id "t1"
              :terminal_title ,label :terminal_title_stripped ,label
              :cwd ,pane-cwd :foreground_cwd ,pane-cwd
              :focused t :revision 0 :state_change_seq 0
              :agent "claude" :agent_status "idle"))
    :layouts ()))

(ert-deftest herdr-model-parse-snapshot-basic ()
  "Parsing a snapshot populates workspaces/tabs/panes/agents."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (should (= 1 (length (herdr-model-workspaces session))))
    (should (= 1 (length (herdr-model-tabs session))))
    (should (= 1 (length (herdr-model-panes session))))
    (should (= 1 (length (herdr-model-agents session))))
    (should (equal (herdr-session-focused-workspace-id session) "w1"))
    (should (equal (herdr-session-protocol session) 20))))

(ert-deftest herdr-model-parse-snapshot-tolerates-unknown-fields ()
  "Unknown fields in the snapshot are ignored, not stored."
  (let ((ws (car (herdr-model-workspaces
                  (herdr-model-parse-snapshot (herdr-model-test--snapshot))))))
    (should (equal (herdr-workspace-label ws) "demo"))))

(ert-deftest herdr-model-parse-snapshot-rejects-malformed-results ()
  "A missing collection is a protocol failure, not a valid empty session."
  (should-error (herdr-model-parse-snapshot nil) :type 'herdr-protocol-error)
  (should-error
   (herdr-model-parse-snapshot
    '(:protocol 20 :workspaces () :tabs () :panes ()))
   :type 'herdr-protocol-error))

(ert-deftest herdr-model-find-agent ()
  "find-agent returns the agent struct by pane id."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (let ((a (herdr-model-find-agent session "w1:p1")))
      (should (herdr-agent-p a))
      (should (equal (herdr-agent-agent a) "claude"))
      (should (equal (herdr-agent-agent-status a) "working")))))

(ert-deftest herdr-model-agent-status-race-creates-minimal-agent ()
  "A status event arriving before detection still populates the agent cache."
  (let ((session (herdr-model--empty-session)))
    (herdr-model--upsert-pane
     session '(:pane_id "w1:p9" :workspace_id "w1" :tab_id "w1:t1"
               :cwd "/repo" :agent nil :agent_status "idle"))
    (herdr-model-apply-event
     session "pane_agent_status_changed"
     '(:pane_id "w1:p9" :agent "codex" :agent_status "working"))
    (let ((agent (herdr-model-find-agent session "w1:p9")))
      (should agent)
      (should (equal "w1" (herdr-agent-workspace-id agent)))
      (should (equal "codex" (herdr-agent-agent agent)))
      (should (equal "working" (herdr-agent-agent-status agent))))))

(ert-deftest herdr-model-apply-event-workspace-focused ()
  "A workspace_focused event updates the id and focused flags."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model--upsert-workspace
     session '(:workspace_id "w2" :label "two" :focused :false))
    (herdr-model-apply-event session "workspace_focused"
                             '(:workspace_id "w2"))
    (should (equal (herdr-session-focused-workspace-id session) "w2"))
    (should (herdr-workspace-focused
             (herdr-model-find-workspace session "w2")))
    (should-not (herdr-workspace-focused
                 (herdr-model-find-workspace session "w1")))))

(ert-deftest herdr-model-focus-events-update-all-related-flags ()
  "Pane focus makes workspace/tab/pane and agent focus mutually consistent."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model--upsert-workspace
     session '(:workspace_id "w2" :label "two" :focused :false))
    (herdr-model--upsert-tab
     session '(:tab_id "w2:t1" :workspace_id "w2" :focused :false))
    (herdr-model--upsert-pane
     session '(:pane_id "w2:p1" :workspace_id "w2" :tab_id "w2:t1"
               :focused :false :agent "codex" :agent_status "idle"))
    (herdr-model--maybe-upsert-agent-from-pane
     session '(:pane_id "w2:p1" :workspace_id "w2" :tab_id "w2:t1"
               :focused :false :agent "codex" :agent_status "idle"))
    (herdr-model-apply-event session "pane_focused"
                             '(:pane_id "w2:p1" :workspace_id "w2"))
    (should (equal "w2" (herdr-session-focused-workspace-id session)))
    (should (equal "w2:t1" (herdr-session-focused-tab-id session)))
    (should (equal "w2:p1" (herdr-session-focused-pane-id session)))
    (should (herdr-pane-focused (herdr-model-find-pane session "w2:p1")))
    (should (herdr-agent-focused (herdr-model-find-agent session "w2:p1")))
    (should-not (herdr-pane-focused (herdr-model-find-pane session "w1:p1")))
    (should-not (herdr-agent-focused
                 (herdr-model-find-agent session "w1:p1")))))

(ert-deftest herdr-model-tab-close-cascades-pane-and-agent-removal ()
  "Closing a tab cannot leave child panes or agents in the cache."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (let ((descriptor
           (herdr-model-apply-event
            session "tab_closed" '(:tab_id "w1:t1" :workspace_id "w1"))))
      (should-not (plist-get descriptor :replayp))
      (should (= 1 (length (plist-get descriptor :closed-agents)))))
    (should-not (herdr-model-find-tab session "w1:t1"))
    (should-not (herdr-model-find-pane session "w1:p1"))
    (should-not (herdr-model-find-agent session "w1:p1"))
    (should (gethash "w1:p1" (herdr-session-gone-panes session)))
    (should-not (herdr-session-focused-tab-id session))
    (should-not (herdr-session-focused-pane-id session))
    (should (plist-get
             (herdr-model-apply-event
              session "tab_closed" '(:tab_id "w1:t1" :workspace_id "w1"))
             :replayp))))

(ert-deftest herdr-model-workspace-close-cascades-all-descendants ()
  "Closing a workspace clears every cached entity owned by it."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-apply-event session "workspace_closed"
                             '(:workspace_id "w1"))
    (should-not (herdr-model-find-workspace session "w1"))
    (should-not (herdr-model-find-tab session "w1:t1"))
    (should-not (herdr-model-find-pane session "w1:p1"))
    (should-not (herdr-model-find-agent session "w1:p1"))
    (should-not (herdr-session-focused-workspace-id session))
    (should-not (herdr-session-focused-tab-id session))
    (should-not (herdr-session-focused-pane-id session))))

(ert-deftest herdr-model-tab-rename-and-move-apply-payloads ()
  "Rename and move events mutate tab structs instead of only notifying."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-apply-event session "tab_renamed"
                             '(:tab_id "w1:t1" :workspace_id "w1"
                               :label "Review"))
    (should (equal "Review"
                   (herdr-tab-label
                    (herdr-model-find-tab session "w1:t1"))))
    (herdr-model-apply-event
     session "tab_moved"
     '(:tab_id "w1:t1" :workspace_id "w1" :insert_index 1
       :tabs ((:tab_id "w1:t1" :workspace_id "w1" :label "Review"
               :number 2 :focused t :pane_count 1
               :agent_status "working"))))
    (should (= 2 (herdr-tab-number
                  (herdr-model-find-tab session "w1:t1"))))))

(ert-deftest herdr-model-apply-event-agent-status ()
  "An agent_status_changed event patches the cached agent in place.
The per-pane `PaneAgentStatusChangedEvent' carries `agent' as a bare
Option<String> (the agent KIND/name), NOT an AgentInfo struct — so the
event must patch the already-cached agent's status/kind slots and leave
its identity (pane_id, workspace_id, cwd, …) intact.  The old code
called `herdr-model--parse-agent' on this string, building an all-nil
struct that wiped the cached identity (agent id → nil)."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-apply-event session "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "blocked"
                               :agent "claude"
                               :title "Claude Code"
                               :display_agent "Claude"))
    (let ((a (herdr-model-find-agent session "w1:p1")))
      ;; identity preserved — NOT wiped to nil by mis-parsing a string:
      (should (equal (herdr-agent-id a) "w1:p1"))
      (should (equal (herdr-agent-workspace-id a) "w1"))
      (should (equal (herdr-agent-cwd a) "/d"))
      ;; patched slots:
      (should (equal (herdr-agent-agent-status a) "blocked"))
      (should (equal (herdr-agent-agent a) "claude"))
      (should (equal (herdr-agent-title a) "Claude Code"))
      (should (equal (herdr-agent-display-agent a) "Claude")))
    (should (equal (herdr-pane-agent-status
                    (herdr-model-find-pane session "w1:p1"))
                   "blocked"))
    (should (equal (herdr-pane-agent
                   (herdr-model-find-pane session "w1:p1"))
                   "claude"))))

(ert-deftest herdr-model-apply-event-pane-created-then-closed ()
  "A created pane appears, and a closed pane (and its agent) disappears."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-apply-event session "pane_created"
                             '(:pane (:pane_id "w2:p1" :workspace_id "w2"
                                      :tab_id "w2:t1" :agent "codex"
                                      :agent_status "idle" :cwd "/x")))
    (should (= 2 (length (herdr-model-panes session))))
    (should (herdr-model-find-agent session "w2:p1"))
    (let ((descriptor
           (herdr-model-apply-event session "pane_closed"
                                    '(:pane_id "w2:p1"))))
      (should (plist-get descriptor :agentp))
      (should-not (plist-get descriptor :replayp)))
    (should (= 1 (length (herdr-model-panes session))))
    (should-not (herdr-model-find-agent session "w2:p1"))
    (should (gethash "w2:p1" (herdr-session-gone-panes session)))
    ;; The same close from a replay is idempotent and explicitly marked so
    ;; downstream lifecycle hooks do not fire twice.
    (let ((descriptor
           (herdr-model-apply-event session "pane_closed"
                                    '(:pane_id "w2:p1"))))
      (should (plist-get descriptor :replayp)))
    ;; A replayed creation can no longer resurrect the closed pane.
    (should (plist-get
             (herdr-model-apply-event
              session "pane_created"
              '(:pane (:pane_id "w2:p1" :workspace_id "w2"
                       :tab_id "w2:t1" :agent "codex")))
             :replayp))
    (should-not (herdr-model-find-pane session "w2:p1"))))

(ert-deftest herdr-model-pane-created-without-agent-preserves-cached-agent ()
  "A pane_created/pane_updated event with NO :agent key must not evict a
known agent.  Live Herdr replays `pane_created' events at connect time
that omit `:agent' (a partial PaneInfo); treating a missing field as
\"no agent\" made the focused agent vanish from the dashboard.  Only an
explicit `:agent' nil removes; a closed/exited pane removes; an absent
key is silent."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    ;; The snapshot agent w1:p1 is cached.
    (should (herdr-model-find-agent session "w1:p1"))
    ;; A pane_created for the SAME pane id with NO :agent key: must survive.
    (herdr-model-apply-event session "pane_created"
                             '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                                      :tab_id "w1:t1"
                                      :terminal_title "new title"
                                      :cwd "/d")))
    (should (herdr-model-find-agent session "w1:p1"))
    ;; Repeated such events (the connect-time replay) must still survive.
    (dotimes (_ 5)
      (herdr-model-apply-event session "pane_created"
                               '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                                        :tab_id "w1:t1"))))
    (should (herdr-model-find-agent session "w1:p1"))
    ;; An explicit `:agent' nil DOES remove (a genuine no-agent pane).
    (herdr-model-apply-event session "pane_updated"
                             '(:pane (:pane_id "w1:p1" :agent nil)))
    (should-not (herdr-model-find-agent session "w1:p1"))))

(ert-deftest herdr-model-pane-update-preserves-agentinfo-identity ()
  "PaneInfo updates/moves preserve fields available only on AgentInfo."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (herdr-model-upsert-agent-info
     '(:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
       :terminal_id "t1" :cwd "/d" :focused t :revision 3
       :agent "claude" :agent_status "idle" :name "architect"
       :state_change_seq 9 :interactive_ready t :launch_pending :false)
     session)
    (herdr-model-apply-event
     session "pane_updated"
     '(:pane (:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
              :terminal_id "t1" :cwd "/new" :focused t :revision 4
              :agent "claude" :agent_status "working")))
    (let ((agent (herdr-model-find-agent session "w1:p1")))
      (should (equal "architect" (herdr-agent-name agent)))
      (should (= 9 (herdr-agent-state-change-seq agent)))
      (should (herdr-agent-interactive-ready agent))
      (should (equal "/new" (herdr-agent-cwd agent))))
    ;; A cross-workspace move changes pane-id but the live alias must survive.
    (herdr-model-apply-event
     session "pane_moved"
     '(:previous_pane_id "w1:p1"
       :pane (:pane_id "w2:p2" :workspace_id "w2" :tab_id "w2:t1"
              :terminal_id "t1" :cwd "/new" :focused t :revision 5
              :agent "claude" :agent_status "working")))
    (should-not (herdr-model-find-agent session "w1:p1"))
    (should (gethash "w1:p1" (herdr-session-gone-panes session)))
    (should (equal "architect"
                   (herdr-agent-name
                    (herdr-model-find-agent session "w2:p2"))))
    (should (plist-get
             (herdr-model-apply-event
              session "pane_updated"
              '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                       :tab_id "w1:t1" :agent "claude")))
             :replayp))))

(ert-deftest herdr-model-pane-created-replay-guard-skips-cached ()
  "A replayed `pane_created' for an already-cached pane adds no pane.
The EventHub ring buffer is drained on every subscribe, so a
`pane_created' for a pane the snapshot already gave us is a stale replay,
not a new pane.  `apply-event' flags it :replayp (so no needless
resubscribe is queued) and skips the upsert — mirroring the
`workspace_created' replay guard.  A genuine new pane is still upserted
and NOT flagged."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    (should (= 1 (length (herdr-model-panes session))))
    ;; Replayed create for the cached pane w1:p1: flagged, no duplicate.
    (let ((d (herdr-model-apply-event session "pane_created"
                                      '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                                               :tab_id "w1:t1" :cwd "/d")))))
      (should (eq (plist-get d :what) :pane-replayed))
      (should (plist-get d :replayp))
      (should (= 1 (length (herdr-model-panes session)))))
    ;; A genuine new pane w2:p1: upserted, NOT flagged.
    (let ((d (herdr-model-apply-event session "pane_created"
                                      '(:pane (:pane_id "w2:p1" :workspace_id "w2"
                                               :tab_id "w2:t1" :agent "codex"
                                               :agent_status "idle" :cwd "/x")))))
      (should (eq (plist-get d :what) :pane-updated))
      (should-not (plist-get d :replayp))
      (should (= 2 (length (herdr-model-panes session))))
      (should (herdr-model-find-pane session "w2:p1")))))

(ert-deftest herdr-model-pane-created-replay-guard-skips-gone ()
  "A replayed `pane_created' for a gone pane is ignored forever.
Herdr never recycles a pane id, so once `herdr-model-mark-pane-gone'
records a pane as closed (dropped by `pane.list' reconciliation), a
future replayed `pane_created' for it must not re-insert the dead id —
re-inserting it would put a stale pane_id back into the per-pane
subscribe set and trigger the reject loop.  The guard flags it :replayp
and skips the upsert."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    ;; Bring up a real new pane, then mark it gone (as reconcile would).
    (herdr-model-apply-event session "pane_created"
                             '(:pane (:pane_id "w2:p1" :workspace_id "w2"
                                      :tab_id "w2:t1" :agent "codex"
                                      :agent_status "idle" :cwd "/x")))
    (should (herdr-model-find-pane session "w2:p1"))
    (herdr-model-mark-pane-gone "w2:p1" session)
    (should-not (herdr-model-find-pane session "w2:p1"))
    (should (gethash "w2:p1" (herdr-session-gone-panes session)))
    ;; A replayed create for the gone pane: flagged, not re-inserted.
    (let ((d (herdr-model-apply-event session "pane_created"
                                      '(:pane (:pane_id "w2:p1" :workspace_id "w2"
                                               :tab_id "w2:t1" :agent "codex"
                                               :agent_status "idle" :cwd "/x")))))
      (should (eq (plist-get d :what) :pane-replayed))
      (should (plist-get d :replayp))
      (should-not (herdr-model-find-pane session "w2:p1")))))

(ert-deftest herdr-model-workspace-created-replay-preserves-snapshot-label ()
  "Workspace labels are derived live, so a replayed
`workspace_created' for an already-cached workspace cannot stale the
display name: the snapshot is canonical and the creation is skipped, and — because
`herdr-workspace-label' prefers `custom-name' then root-pane cwd then
`cached-label' — neither a replayed creation nor a `workspace_updated'
overrides a frozen `custom-name'.  Only `workspace_renamed' changes the
custom name."
  (let ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot))))
    ;; Snapshot w1: label "demo", root pane cwd "/d" -> auto "d"; the
    ;; mismatch freezes custom-name "demo" (a pre-connect rename).
    (should (equal (herdr-workspace-custom-name
                    (herdr-model-find-workspace session "w1"))
                   "demo"))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "demo"))
    ;; A replayed workspace_created for w1 with a stale label is skipped.
    (herdr-model-apply-event session "workspace_created"
                             '(:workspace (:workspace_id "w1" :label "stale"
                                          :number 1 :focused t
                                          :active_tab_id "w1:t1"
                                          :tab_count 1 :pane_count 1
                                          :agent_status "working")))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "demo"))
    ;; Repeated replay (the connect-time storm) still survives.
    (dotimes (_ 5)
      (herdr-model-apply-event session "workspace_created"
                               '(:workspace (:workspace_id "w1" :label "stale"))))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "demo"))
    ;; A workspace_updated refreshes cached-label but does NOT override
    ;; custom-name, so the displayed label stays "demo".
    (herdr-model-apply-event session "workspace_updated"
                             '(:workspace (:workspace_id "w1" :label "renamed"
                                          :number 1 :focused t
                                          :active_tab_id "w1:t1"
                                          :tab_count 1 :pane_count 1
                                          :agent_status "working")))
    (should (equal (herdr-workspace-cached-label
                    (herdr-model-find-workspace session "w1"))
                   "renamed"))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "demo"))
    ;; A workspace_created for a genuinely NEW workspace still inserts.
    (herdr-model-apply-event session "workspace_created"
                             '(:workspace (:workspace_id "w2" :label "new-ws"
                                          :number 2 :focused :false
                                          :tab_count 0 :pane_count 0)))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w2"))
                   "new-ws"))
    ;; Only workspace_renamed changes the custom name.
    (herdr-model-apply-event session "workspace_renamed"
                             '(:workspace_id "w1" :label "renamed"))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "renamed"))))

(ert-deftest herdr-workspace-label-recomputes-on-cwd-change ()
  "The workspace label is derived live from the root-pane cwd, so a
`pane_updated' that changes the root pane's cwd changes the label with
NO workspace event arriving.  The server pushes cwd changes only as
`pane_updated' (never a workspace event), so a cached-label design goes
stale here; this distinguishes the live-derived-label behavior."
  (let ((session (herdr-model-parse-snapshot
                  (herdr-model-test--snapshot-with "w1" "proj-a" "/work/proj-a"))))
    (herdr-model-set-cache session)
    (unwind-protect
        (progn
          ;; label matches cwd basename -> no custom name -> auto-derived.
          (should-not (herdr-workspace-custom-name
                       (herdr-model-find-workspace session "w1")))
          (should (equal (herdr-workspace-label
                          (herdr-model-find-workspace session "w1"))
                         "proj-a"))
          ;; Root pane cd's elsewhere; only a pane_updated arrives.
          (herdr-model-apply-event session "pane_updated"
                                   '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                                            :tab_id "w1:t1" :cwd "/work/proj-b")))
          (should (equal (herdr-workspace-label
                          (herdr-model-find-workspace session "w1"))
                         "proj-b")))
      (herdr-model-clear-cache))))

(ert-deftest herdr-workspace-label-uses-root-pane-not-split ()
  "The label derives from the ROOT pane (smallest public pane number =
the first tab's root pane), not a split pane.  A split pane's cwd
change must not change the label; the root pane's cwd change must."
  (let ((session (herdr-model-parse-snapshot
                  `(:protocol 20 :version "0.8.2"
                    :focused_workspace_id "w1" :focused_tab_id "w1:t1"
                    :focused_pane_id "w1:p1"
                    :workspaces ((:workspace_id "w1" :label "root" :number 1
                                  :focused t :active_tab_id "w1:t1"
                                  :tab_count 1 :pane_count 2 :agent_status "idle"))
                    :tabs ((:tab_id "w1:t1" :workspace_id "w1" :label "1"
                            :number 1 :focused t :pane_count 2
                            :agent_status "idle"))
                    :panes ((:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
                             :terminal_id "t1" :terminal_title "root"
                             :terminal_title_stripped "root" :cwd "/work/root"
                             :foreground_cwd "/work/root" :focused t :revision 0
                             :agent "claude" :agent_status "idle")
                            (:pane_id "w1:p2" :workspace_id "w1" :tab_id "w1:t1"
                             :terminal_id "t2" :terminal_title "split"
                             :terminal_title_stripped "split" :cwd "/work/split"
                             :foreground_cwd "/work/split" :focused :false
                             :revision 0 :agent "claude" :agent_status "idle"))
                    :agents ()
                    :layouts ()))))
    (herdr-model-set-cache session)
    (unwind-protect
        (progn
          (should (equal (herdr-workspace-label
                          (herdr-model-find-workspace session "w1"))
                         "root"))
          ;; Changing the SPLIT pane's cwd leaves the label at the root pane's cwd.
          (herdr-model-apply-event session "pane_updated"
                                   '(:pane (:pane_id "w1:p2" :workspace_id "w1"
                                            :tab_id "w1:t1" :cwd "/work/other")))
          (should (equal (herdr-workspace-label
                          (herdr-model-find-workspace session "w1"))
                         "root"))
          ;; Changing the ROOT pane's cwd moves the label.
          (herdr-model-apply-event session "pane_updated"
                                   '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                                            :tab_id "w1:t1" :cwd "/work/changed")))
          (should (equal (herdr-workspace-label
                          (herdr-model-find-workspace session "w1"))
                         "changed")))
      (herdr-model-clear-cache))))

(ert-deftest herdr-workspace-label-prefers-custom-name ()
  "A custom name (frozen at snapshot via label/cwd mismatch) wins over
the cwd-derived name and survives root-pane cwd changes — the server's
`display_name_from' returns custom_name verbatim."
  (let ((session (herdr-model-parse-snapshot
                  (herdr-model-test--snapshot-with "w1" "my-name" "/work/repo"))))
    ;; label "my-name" != auto "repo" -> custom-name "my-name".
    (should (equal (herdr-workspace-custom-name
                    (herdr-model-find-workspace session "w1"))
                   "my-name"))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "my-name"))
    ;; Root pane cwd changes; custom-name still wins.
    (herdr-model-apply-event session "pane_updated"
                             '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                                      :tab_id "w1:t1" :cwd "/work/other")))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "my-name"))))

(ert-deftest herdr-workspace-rename-sets-custom-name ()
  "`workspace_renamed' sets the custom name, which then wins over the
cwd-derived label and survives later cwd changes."
  (let ((session (herdr-model-parse-snapshot
                  (herdr-model-test--snapshot-with "w1" "repo" "/work/repo"))))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "repo"))
    (should-not (herdr-workspace-custom-name
                 (herdr-model-find-workspace session "w1")))
    (herdr-model-apply-event session "workspace_renamed"
                             '(:workspace_id "w1" :label "renamed"))
    (should (equal (herdr-workspace-custom-name
                    (herdr-model-find-workspace session "w1"))
                   "renamed"))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "renamed"))
    ;; A later cwd change does not override the custom name.
    (herdr-model-apply-event session "pane_updated"
                             '(:pane (:pane_id "w1:p1" :workspace_id "w1"
                                      :tab_id "w1:t1" :cwd "/work/elsewhere")))
    (should (equal (herdr-workspace-label
                    (herdr-model-find-workspace session "w1"))
                   "renamed"))))

(ert-deftest herdr-model--decode-pane-number ()
  "Pane public numbers decode per the server's base-32 alphabet
\(src/workspace.rs:107).  Number 1 -> \"p1\"; numbers >31 go multi-char
\(32 -> \"p0\", 33 -> \"p11\").  Skipped letters (I/L/O/U) decode to nil."
  (should (= 1 (herdr-model--pane-public-number "w1:p1")))
  (should (= 9 (herdr-model--pane-public-number "w1:p9")))
  (should (= 10 (herdr-model--pane-public-number "w1:pA")))
  (should (= 32 (herdr-model--pane-public-number "w1:p0")))
  (should (= 33 (herdr-model--pane-public-number "w2:p11")))
  ;; I and O are not in the alphabet (skipped to avoid 1/I, 0/O confusion).
  (should-not (herdr-model--pane-public-number "w1:pI"))
  (should-not (herdr-model--pane-public-number "w1:pO")))

(ert-deftest herdr-model-apply-event-returns-descriptor ()
  "apply-event returns a descriptor plist with :event and :what."
  (let* ((session (herdr-model-parse-snapshot (herdr-model-test--snapshot)))
         (d (herdr-model-apply-event session "workspace_focused"
                                     '(:workspace_id "w9"))))
    (should (equal (plist-get d :event) "workspace_focused"))
    (should (eq (plist-get d :what) ':workspace-focused))))


;;; --- Worktrees --------------------------------------------

(defun herdr-model-test--worktree-data (path &optional ws-id)
  "A canned worktree_created/opened payload for a worktree at PATH.
WS-ID is the open workspace id (default \"wt1\")."
  `(:worktree (:path ,path :branch "feat" :is_bare :false
              :is_detached :false :is_prunable :false
              :is_linked_worktree t :label nil
              :open_workspace_id ,(or ws-id "wt1"))
    :workspace (:workspace_id ,(or ws-id "wt1") :label "wt1"
                :number 2 :focused t :active_tab_id "wt1:t1"
                :tab_count 1 :pane_count 1 :agent_status "idle")))

(ert-deftest herdr-model-apply-event-worktree-created-upserts ()
  "A worktree_created event upserts the worktree (keyed by path) + workspace."
  (let ((session (herdr-model--empty-session)))
    (herdr-model-apply-event session "worktree_created"
                             (herdr-model-test--worktree-data "/repo/wt-1"))
    (let ((wt (herdr-model-find-worktree session "/repo/wt-1")))
      (should (herdr-worktree-p wt))
      (should (equal "/repo/wt-1" (herdr-worktree-path wt)))
      (should (equal "feat" (herdr-worktree-branch wt)))
      (should (herdr-worktree-is-linked-worktree wt))
      (should-not (herdr-worktree-is-bare wt))
      (should-not (herdr-worktree-is-detached wt))
      (should (equal "wt1" (herdr-worktree-open-workspace-id wt))))
    ;; the hosting workspace is also upserted.
    (should (herdr-model-find-workspace session "wt1"))))

(ert-deftest herdr-model-apply-event-worktree-opened-upserts ()
  "A worktree_opened event upserts the worktree and reports :worktree-opened."
  (let ((session (herdr-model--empty-session)))
    (let ((d (herdr-model-apply-event session "worktree_opened"
                                      (herdr-model-test--worktree-data "/repo/wt-2"))))
      (should (eq (plist-get d :what) :worktree-opened))
      (should (equal "/repo/wt-2" (plist-get d :id))))
    (should (herdr-model-find-worktree session "/repo/wt-2"))))

(ert-deftest herdr-model-apply-event-worktree-removed-remhash ()
  "A worktree_removed event drops the worktree from the cache."
  (let ((session (herdr-model--empty-session)))
    (herdr-model-apply-event session "worktree_created"
                             (herdr-model-test--worktree-data "/repo/wt-1"))
    (should (herdr-model-find-worktree session "/repo/wt-1"))
    (let ((d (herdr-model-apply-event session "worktree_removed"
                                      '(:worktree (:path "/repo/wt-1")
                                        :workspace_id "wt1" :forced :false))))
      (should (eq (plist-get d :what) :worktree-removed))
      (should-not (plist-get d :forced)))
    (should-not (herdr-model-find-worktree session "/repo/wt-1"))))

(ert-deftest herdr-model-find-worktree-for-workspace ()
  "`find-worktree-for-workspace' resolves the worktree hosting a workspace."
  (let ((session (herdr-model--empty-session)))
    (herdr-model-apply-event session "worktree_created"
                             (herdr-model-test--worktree-data "/repo/a" "ws-a"))
    (herdr-model-apply-event session "worktree_created"
                             (herdr-model-test--worktree-data "/repo/b" "ws-b"))
    (should (equal "/repo/a"
                   (herdr-worktree-path
                    (herdr-model-find-worktree-for-workspace "ws-a" session))))
    (should (equal "/repo/b"
                   (herdr-worktree-path
                    (herdr-model-find-worktree-for-workspace "ws-b" session))))
    (should-not (herdr-model-find-worktree-for-workspace "ws-x" session))))

(ert-deftest herdr-model-upsert-worktree-public-and-remove ()
  "The public upsert (RPC race-closure) caches a WorktreeInfo; remove drops it.
Both read/write through the cache singleton, so this wraps in set-cache
(the pattern from the label-derivation tests)."
  (let ((session (herdr-model--empty-session)))
    (herdr-model-set-cache session)
    (unwind-protect
        (progn
          (let ((wt (herdr-model-upsert-worktree
                     '(:path "/repo/rpc" :branch "main"
                       :is_linked_worktree t :open_workspace_id "wt9"))))
            (should (herdr-worktree-p wt))
            (should (equal "/repo/rpc" (herdr-worktree-path wt))))
          ;; findable via the cache singleton (no explicit session).
          (should (equal "/repo/rpc"
                         (herdr-worktree-path
                          (herdr-model-find-worktree "/repo/rpc"))))
          ;; eager removal is reflected in the cache.
          (herdr-model-remove-worktree "/repo/rpc")
          (should-not (herdr-model-find-worktree "/repo/rpc")))
      (herdr-model-clear-cache))))

(provide 'herdr-model-test)
;;; herdr-model-test.el ends here
