;;; agent-fleet-dashboard-test.el --- ERT tests for agent-fleet-dashboard.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Phase 3 tests: dashboard rendering, event-driven refresh, faces,
;; column fallbacks, and notification gating.
;; Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l agent-fleet-dashboard -l herdr-mock-server \
;;         -l test/agent-fleet-dashboard-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'herdr)
(require 'agent-fleet)
(require 'agent-fleet-dashboard)
(require 'agent-fleet-parallel)
(require 'herdr-mock-server)
(require 'agent-fleet-test)            ; harness: with-agent-fleet-mock, --pump


;;; --- Helpers --------------------------------------------------------

(defun agent-fleet-dashboard-test--cell (pane-id col)
  "Return column COL (0-based) for PANE-ID in the dashboard, or nil.
Columns: 0 Project, 1 Agent, 2 Kind, 3 State, 4 Task."
  (when-let ((buf (get-buffer "*Agent Fleet*")))
    (with-current-buffer buf
      (let ((entry (assoc pane-id tabulated-list-entries)))
        (and entry (aref (cadr entry) col))))))

(defmacro with-dashboard-fresh (&rest body)
  "Run BODY with a fresh *Agent Fleet* buffer (any old one killed first)."
  (declare (indent 0))
  `(progn
     (when (get-buffer "*Agent Fleet*") (kill-buffer "*Agent Fleet*"))
     ,@body))


;;; --- Rendering + event-driven refresh -------------------------------

(ert-deftest agent-fleet-dashboard-opens-and-lists-agents ()
  "`M-x agent-fleet' opens the dashboard with the cached agent."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (with-current-buffer "*Agent Fleet*"
        (should (eq major-mode 'agent-fleet-mode)))
      (should (equal "w1:p1"
                     (car (assoc "w1:p1"
                                 (with-current-buffer "*Agent Fleet*"
                                   tabulated-list-entries)))))
      (should (equal "demo"    (agent-fleet-dashboard-test--cell "w1:p1" 1))) ; Agent
      (should (equal "Claude"  (agent-fleet-dashboard-test--cell "w1:p1" 2))) ; Kind
      (should (equal "WORKING" (agent-fleet-dashboard-test--cell "w1:p1" 3)))))) ; State

(ert-deftest agent-fleet-dashboard-updates-on-status-event ()
  "A pushed status event updates the State cell live (no `g' needed)."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (equal "WORKING" (agent-fleet-dashboard-test--cell "w1:p1" 3)))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "blocked"))
      (agent-fleet-test--pump)
      (let ((cell (agent-fleet-dashboard-test--cell "w1:p1" 3)))
        (should (equal "BLOCKED" cell))
        (should (eq 'agent-fleet-blocked-face
                    (get-text-property 0 'face cell)))))))

(ert-deftest agent-fleet-dashboard-adds-row-on-started ()
  "A `pane_agent_detected' event adds a new row without `g'.
The faithful detection payload carries only the agent kind (NO status:
`final_status' is set only when `released' is true — src/app/actions.rs).
So the row appears with Kind from the detection and State from a
following `pane.agent_status_changed' (dotted per-pane kind, §7.3) event."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (= 1 (length (with-current-buffer "*Agent Fleet*"
                             tabulated-list-entries))))
      (herdr-mock-push-event server "pane_agent_detected"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :released :false))
      (agent-fleet-test--pump)
      (should (= 2 (length (with-current-buffer "*Agent Fleet*"
                             tabulated-list-entries))))
      (should (equal "Codex" (agent-fleet-dashboard-test--cell "w1:p2" 2)))
      ;; the status lands via the per-pane status event, not the detection
      (herdr-mock-push-event server "pane.agent_status_changed"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :agent_status "idle"))
      (agent-fleet-test--pump)
      (should (equal "IDLE"  (agent-fleet-dashboard-test--cell "w1:p2" 3))))))

(ert-deftest agent-fleet-dashboard-removes-row-on-exit ()
  "A `pane_closed' event removes the agent's row without `g'."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (agent-fleet-dashboard-test--cell "w1:p1" 3))
      (herdr-mock-push-event server "pane_closed" '(:pane_id "w1:p1"))
      (agent-fleet-test--pump)
      (should-not (agent-fleet-dashboard-test--cell "w1:p1" 3)))))

(ert-deftest agent-fleet-dashboard-refresh-from-server ()
  "`g' (from-server refresh) repopulates a dropped agent from `agent.list'."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (agent-fleet-dashboard-test--cell "w1:p1" 3))
      ;; Drop it from the LOCAL cache only (no event, no server state change).
      (remhash "w1:p1" (herdr-session-agents (herdr-model-cache)))
      (with-current-buffer "*Agent Fleet*"
        (agent-fleet-dashboard-refresh))            ; local reprint -> gone
      (should-not (agent-fleet-dashboard-test--cell "w1:p1" 3))
      (with-current-buffer "*Agent Fleet*"
        (agent-fleet-dashboard-refresh t))          ; g: re-fetch from server
      (agent-fleet-test--pump)
      (should (agent-fleet-dashboard-test--cell "w1:p1" 3)))))

(ert-deftest agent-fleet-dashboard-blocked-sorts-first ()
  "Blocked agents sort above working agents (PLAN.md §28: most prominent)."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      ;; add a second, blocked agent; the existing w1:p1 is WORKING.
      ;; the detection establishes the agent; the dotted per-pane status
      ;; event sets it blocked (§7.3: detection carries no status).
      (herdr-mock-push-event server "pane_agent_detected"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :released :false))
      (agent-fleet-test--pump)
      (herdr-mock-push-event server "pane.agent_status_changed"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :agent_status "blocked"))
      (agent-fleet-test--pump)
      (let ((ids (mapcar #'car
                         (with-current-buffer "*Agent Fleet*"
                           tabulated-list-entries))))
        (should (equal "w1:p2" (car ids)))))))      ; blocked first


;;; --- Faces (PLAN.md §28) --------------------------------------------

(ert-deftest agent-fleet-dashboard-state-face ()
  "Each status symbol maps to its face; nil/unknown map to the unknown face."
  (should (eq 'agent-fleet-blocked-face
              (agent-fleet-dashboard--face-for-status 'blocked)))
  (should (eq 'agent-fleet-working-face
              (agent-fleet-dashboard--face-for-status 'working)))
  (should (eq 'agent-fleet-done-face
              (agent-fleet-dashboard--face-for-status 'done)))
  (should (eq 'agent-fleet-idle-face
              (agent-fleet-dashboard--face-for-status 'idle)))
  (should (eq 'agent-fleet-unknown-face
              (agent-fleet-dashboard--face-for-status 'unknown)))
  (should (eq 'agent-fleet-unknown-face
              (agent-fleet-dashboard--face-for-status nil)))
  (should (eq 'agent-fleet-unknown-face
              (agent-fleet-dashboard--face-for-status 'bogus)))
  ;; State cell carries the face on its text.
  (let ((cell (agent-fleet-dashboard--state-cell
               (make-herdr-agent :agent-status "blocked"))))
    (should (equal "BLOCKED" cell))
    (should (eq 'agent-fleet-blocked-face (get-text-property 0 'face cell))))
  (let ((cell (agent-fleet-dashboard--state-cell (make-herdr-agent))))
    (should (equal "UNKNOWN" cell))
    (should (eq 'agent-fleet-unknown-face (get-text-property 0 'face cell)))))


;;; --- Column fallbacks (provisional, PLAN.md §27/§69) ----------------

(ert-deftest agent-fleet-dashboard-columns ()
  "Project/Kind/Task/State helpers fall back gracefully."
  ;; Project: workspace label (live cache) -> cwd basename -> "—".
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (equal "demo"                 ; workspace w1 label
                     (agent-fleet-dashboard--project-label
                      (herdr-find-agent "w1:p1"))))))
  (should (equal "—"
                 (agent-fleet-dashboard--project-label
                  (make-herdr-agent :workspace-id nil :cwd nil))))
  (should (equal "—"
                 (agent-fleet-dashboard--project-label
                  (make-herdr-agent :workspace-id nil :cwd ""))))
  (should (equal "proj"
                 (agent-fleet-dashboard--project-label
                  (make-herdr-agent :workspace-id nil :cwd "/home/me/proj"))))
  ;; Kind: capitalize or "—".
  (should (equal "Claude" (agent-fleet-dashboard--kind-label
                           (make-herdr-agent :agent "claude"))))
  (should (equal "—"      (agent-fleet-dashboard--kind-label
                           (make-herdr-agent :agent nil))))
  ;; Task: terminal title unless it duplicates the Agent label, else "—".
  (should (equal "building"
                 (agent-fleet-dashboard--task-label
                  (make-herdr-agent :name "arch"
                                    :terminal-title-stripped "building")
                  "arch")))
  (should (equal "—"
                 (agent-fleet-dashboard--task-label
                  (make-herdr-agent :name "arch"
                                    :terminal-title-stripped "arch")
                  "arch")))
  (should (equal "—"
                 (agent-fleet-dashboard--task-label
                  (make-herdr-agent) "arch"))))


;;; --- Notifications (PLAN.md §29) ------------------------------------

(ert-deftest agent-fleet-dashboard-notify-gated ()
  "Notifications fire only for statuses in `agent-fleet-notify-on'."
  (let ((agent-fleet-notify-on '(blocked)))
    (should (equal "agent-fleet: demo → blocked"
                   (agent-fleet-dashboard--notify-message
                    '(:status "blocked" :name "demo"))))
    ;; done is not in the set -> nil (no notification).
    (should (null (agent-fleet-dashboard--notify-message
                   '(:status "done" :name "demo"))))
    ;; name falls back to pane-id, then "agent".
    (should (equal "agent-fleet: w1:p1 → blocked"
                   (agent-fleet-dashboard--notify-message
                    '(:status "blocked" :pane-id "w1:p1"))))
    (should (equal "agent-fleet: agent → blocked"
                   (agent-fleet-dashboard--notify-message
                    '(:status "blocked")))))
  ;; default set includes done.
  (let ((agent-fleet-notify-on '(blocked done)))
    (should (equal "agent-fleet: demo → done"
                   (agent-fleet-dashboard--notify-message
                    '(:status "done" :name "demo")))))
  ;; disabled entirely.
  (let ((agent-fleet-notify-on nil))
    (should (null (agent-fleet-dashboard--notify-message
                   '(:status "blocked" :name "demo"))))))


;;; --- Command map (PLAN.md §53) --------------------------------------

(ert-deftest agent-fleet-command-map-has-no-global-binding ()
  "The package must not bind a global key (PLAN.md §53)."
  ;; Loading the feature should not have installed any C-c a binding.
  (should-not (where-is-internal 'agent-fleet global-map)))

(ert-deftest agent-fleet-command-map-keys ()
  "The prefix map binds the documented commands (PLAN.md §53)."
  (should (eq (lookup-key agent-fleet-command-map "a") #'agent-fleet))
  (should (eq (lookup-key agent-fleet-command-map "s") #'agent-fleet-start))
  (should (eq (lookup-key agent-fleet-command-map "p") #'agent-fleet-prompt))
  (should (eq (lookup-key agent-fleet-command-map "o") #'agent-fleet-read))
  (should (eq (lookup-key agent-fleet-command-map "i") #'agent-fleet-interrupt)))


;;; --- Row keys (PLAN.md §27) -----------------------------------------

(ert-deftest agent-fleet-dashboard-row-keys-d-and-m ()
  "The dashboard binds `d' to the diff command and `m' to the magit command
\(Phase 6), not the old `--not-yet' stubs."
  (should (eq #'agent-fleet-dashboard-diff
              (lookup-key agent-fleet-dashboard-mode-map "d")))
  (should (eq #'agent-fleet-dashboard-magit
              (lookup-key agent-fleet-dashboard-mode-map "m"))))


;;; --- Task column + T filter (Phase 7, §72) ---------------------------

(ert-deftest agent-fleet-dashboard-row-keys-t-and-p ()
  "`T' narrows to a task (Phase 7, §72); `P' narrows to a project (§69)."
  (should (eq #'agent-fleet-dashboard-toggle-task-filter
              (lookup-key agent-fleet-dashboard-mode-map "T")))
  (should (eq #'agent-fleet-dashboard-toggle-project-filter
              (lookup-key agent-fleet-dashboard-mode-map "P"))))

(ert-deftest agent-fleet-dashboard-task-filter-and-column ()
  "The Task column shows a task agent's task title; the `T' filter narrows
to that task's agents and the mode-line banner shows the live aggregate
state (§72)."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (let* ((task (agent-fleet-parallel
                    '((claude . "do A") (codex . "do B"))
                    :title "rev" :cwd "/tmp"))
             (pids (agent-fleet-task-agents task)))
        (agent-fleet)
        (agent-fleet-test--pump)
        ;; the task agents' Task column shows the task title (the group
        ;; label), not the pane's terminal title.
        (should (equal "rev" (agent-fleet-dashboard-test--cell (nth 0 pids) 4)))
        (should (equal "rev" (agent-fleet-dashboard-test--cell (nth 1 pids) 4)))
        ;; the pre-existing snapshot agent is present while unfiltered.
        (should (agent-fleet-dashboard-test--cell "w1:p1" 3))
        ;; narrow to the task.
        (with-current-buffer "*Agent Fleet*"
          (setq agent-fleet-dashboard--task-filter (agent-fleet-task-id task))
          (agent-fleet-dashboard-refresh))
        (let ((ids (mapcar #'car
                           (with-current-buffer "*Agent Fleet*"
                             tabulated-list-entries))))
          (should (member (nth 0 pids) ids))
          (should (member (nth 1 pids) ids))
          (should-not (member "w1:p1" ids)))
        ;; the mode-line banner shows the title + live aggregate state.
        (with-current-buffer "*Agent Fleet*"
          (should (string-match-p "rev" (or agent-fleet-dashboard--task-banner "")))
          (should (string-match-p "done" agent-fleet-dashboard--task-banner)))))))


(provide 'agent-fleet-dashboard-test)
;;; agent-fleet-dashboard-test.el ends here
