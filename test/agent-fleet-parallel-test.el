;;; agent-fleet-parallel-test.el --- ERT tests for agent-fleet-parallel.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Phase 7 tests: `agent-fleet-parallel' spawns N isolated worktree
;; agents and prompts each; the task model tracks aggregate state live
;; (§38: not a race — done only when ALL agents finish); `task-wait'
;; pumps events (§25); `task-cleanup' removes worktrees (§71).  All
;; against the mock server (no real Herdr).
;; Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l agent-fleet-parallel -l herdr-mock-server \
;;         -l test/agent-fleet-parallel-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr)
(require 'herdr-model)
(require 'agent-fleet)
(require 'agent-fleet-parallel)
(require 'herdr-mock-server)
(require 'agent-fleet-test)            ; harness: with-agent-fleet-mock, --pump


;;; --- Helpers --------------------------------------------------------

(defun agent-fleet-parallel-test--prompt-working-only (params)
  "Mock agent.prompt that transitions to `working' and STAYS there.
The default mock goes idle->working->done in one step, which hides the
§38 behavior (one agent done while another runs).  This variant leaves
the agent `working' so a test can finish agents one at a time."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (info (herdr-mock--agent-find server target)))
    (if (null info)
        (list 'error "not_found" (format "no agent for target %S" target))
      (let ((pane-id (plist-get info :pane_id)))
        (herdr-mock--push-status server pane-id "working")
        `(:type "agent_prompted"
          :agent ,(herdr-mock--agent-get server pane-id))))))

(defun agent-fleet-parallel-test--use-working-prompt (server)
  "Replace SERVER's agent.prompt handler with the working-only variant.
Builds a FRESH handlers alist (via `mapcar'/`cons') rather than mutating
the alist returned by `herdr-mock-default-agent-handlers': that alist's
constant cons cells are shared across calls (Emacs backquote folds the
constant sub-structure), so `setf' on it would leak the override to every
later server."
  (let ((handlers (mapcar (lambda (cell)
                            (if (equal (car cell) "agent.prompt")
                                (cons "agent.prompt"
                                      #'agent-fleet-parallel-test--prompt-working-only)
                              cell))
                          (herdr-mock-default-agent-handlers))))
    (herdr-mock-set-handlers server handlers)))

(defun agent-fleet-parallel-test--count (server method)
  "Return the number of requests to METHOD recorded on SERVER."
  (cl-count method (herdr-mock-received server)
            :key #'cadr :test #'equal))


;;; --- Parallel spawn + prompt (§72) ----------------------------------

(ert-deftest agent-fleet-parallel-spawns-isolated-worktree-agents ()
  "`agent-fleet-parallel' spawns N worktree agents, prompts each, returns a task.
Each spec yields its own worktree.create + agent.start + agent.prompt; the
agents get distinct worktrees; the returned task is `running' before any
status event lands (agents are cached `idle' from the eager start upsert,
and the prompt's status events stay queued until a pump — §72)."
  (with-agent-fleet-mock path server
    ;; Working-only prompt: the default mock goes idle->working->done in one
    ;; step, and `herdr-request''s pump drains those done events during the
    ;; spawn itself — so the task would already be `done' here.  The
    ;; working-only variant keeps agents non-terminal so `running' is
    ;; deterministic (working or idle both aggregate to `running').
    (agent-fleet-parallel-test--use-working-prompt server)
    (let ((task (agent-fleet-parallel
                 '((claude . "do A") (codex . "do B"))
                 :title "rev" :cwd "/tmp")))
      (should (agent-fleet-task-p task))
      (should (equal "rev" (agent-fleet-task-title task)))
      (should (= 2 (length (agent-fleet-task-agents task))))
      ;; 2x worktree.create, agent.start, agent.prompt.
      (should (= 2 (agent-fleet-parallel-test--count server "worktree.create")))
      (should (= 2 (agent-fleet-parallel-test--count server "agent.start")))
      (should (= 2 (agent-fleet-parallel-test--count server "agent.prompt")))
      ;; distinct worktrees (distinct paths) for the two agents.
      (let* ((pids (agent-fleet-task-agents task))
             (paths (mapcar
                     (lambda (pid)
                       (let* ((a (agent-fleet--find-agent pid))
                              (ws-id (herdr-agent-workspace-id a))
                              (wt (herdr-model-find-worktree-for-workspace ws-id)))
                         (and wt (herdr-worktree-path wt))))
                     pids)))
        (should (= 2 (length (delete-dups paths))))
        ;; each agent maps back to this task.
        (dolist (pid pids)
          (should (equal (agent-fleet-task-id task)
                         (agent-fleet-task-id
                          (agent-fleet-task-for-agent pid))))))
      ;; running before any status event is pumped.
      (should (eq 'running (agent-fleet-task-state task))))))

(ert-deftest agent-fleet-parallel-distinct-prompts ()
  "Each agent.prompt carries its spec's own prompt text (§72 alist form)."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel
     '((claude . "analyze architecture") (codex . "analyze tests"))
     :title "rev" :cwd "/tmp")
    (let ((texts (delq nil
                       (mapcar (lambda (req)
                                 (and (equal (cadr req) "agent.prompt")
                                      (plist-get (caddr req) :text)))
                               (herdr-mock-received server)))))
      (should (= 2 (length texts)))
      (should (member "analyze architecture" texts))
      (should (member "analyze tests" texts)))))

(ert-deftest agent-fleet-parallel-requires-cwd ()
  "`agent-fleet-parallel' without :cwd (and no project root) signals
provisioning-failed at the `parallel-cwd' step; no RPC is issued."
  (with-agent-fleet-mock path server
    (let ((default-directory (make-temp-file "af-no-cwd-" t)))
      (unwind-protect
          (progn
            (should-error (agent-fleet-parallel
                           '((claude . "do"))
                           :title "rev")
                          :type 'agent-fleet-provisioning-failed)
            (should-not (agent-fleet-test--saw-request-p server "worktree.create")))
        (delete-directory default-directory t)))))


;;; --- Aggregate state (§38/§72) --------------------------------------

(ert-deftest agent-fleet-parallel-agents-run-concurrently ()
  "One agent finishing does NOT make the task done (PLAN.md §38: not a race).
Both done only then yields `done'.  Uses a working-only prompt so agents
stay `working' until an explicit done event."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel-test--use-working-prompt server)
    (let* ((task (agent-fleet-parallel
                  '((claude . "do A") (codex . "do B"))
                  :title "rev" :cwd "/tmp"))
           (pids (agent-fleet-task-agents task)))
      (agent-fleet-test--pump)
      ;; both working -> running.
      (should (eq 'working (agent-fleet-status (nth 0 pids))))
      (should (eq 'working (agent-fleet-status (nth 1 pids))))
      (should (eq 'running (agent-fleet-task-state task)))
      ;; agent 0 done alone -> still running (§38).
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 0 pids) :agent_status "done"))
      (agent-fleet-test--pump)
      (should (eq 'done (agent-fleet-status (nth 0 pids))))
      (should (eq 'working (agent-fleet-status (nth 1 pids))))
      (should (eq 'running (agent-fleet-task-state task)))
      (should-not (agent-fleet-task-finished-at task))
      ;; agent 1 done -> done; finished-at stamped when `done' is first reached.
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 1 pids) :agent_status "done"))
      (agent-fleet-test--pump)
      (should (eq 'done (agent-fleet-task-state task)))
      (should (agent-fleet-task-finished-at task)))))

(ert-deftest agent-fleet-task-state-aggregate ()
  "`task-state' aggregates per-agent statuses live: all done => done; any
blocked (not all done) => blocked; else running (§38/§72).  Drives the
full state machine over three agents."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel-test--use-working-prompt server)
    (let* ((task (agent-fleet-parallel
                  '((claude . "do A") (codex . "do B") (pi . "do C"))
                  :title "rev" :cwd "/tmp"))
           (pids (agent-fleet-task-agents task)))
      (agent-fleet-test--pump)
      (should (eq 'running (agent-fleet-task-state task)))      ; all working
      ;; one blocked -> blocked.
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 0 pids) :agent_status "blocked"))
      (agent-fleet-test--pump)
      (should (eq 'blocked (agent-fleet-task-state task)))
      ;; blocked -> working -> back to running.
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 0 pids) :agent_status "working"))
      (agent-fleet-test--pump)
      (should (eq 'running (agent-fleet-task-state task)))
      ;; two of three done, one working -> still running (§38).
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 0 pids) :agent_status "done"))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 1 pids) :agent_status "done"))
      (agent-fleet-test--pump)
      (should (eq 'running (agent-fleet-task-state task)))
      ;; all three done -> done.
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 2 pids) :agent_status "done"))
      (agent-fleet-test--pump)
      (should (eq 'done (agent-fleet-task-state task))))))


;;; --- Task wait (§38/§25) --------------------------------------------

(ert-deftest agent-fleet-task-wait-blocks-until-done ()
  "`task-wait' pumps `accept-process-output' and returns once the task is
`done' (§38/§25).  The done events are queued before the call; the wait's
own event-driven pump drains them and resolves — no busy polling."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel-test--use-working-prompt server)
    (let* ((task (agent-fleet-parallel
                  '((claude . "do A") (codex . "do B"))
                  :title "rev" :cwd "/tmp"))
           (pids (agent-fleet-task-agents task)))
      (agent-fleet-test--pump)
      (should (eq 'running (agent-fleet-task-state task)))
      ;; queue both done events WITHOUT pumping; the wait must drain them.
      (dolist (pid pids)
        (herdr-mock-push-event server "pane_agent_status_changed"
                               `(:pane_id ,pid :agent_status "done")))
      (let ((res (agent-fleet-task-wait task '(done) :timeout-ms 3000)))
        (should (eq res task))
        (should (eq 'done (agent-fleet-task-state task)))
        (should (agent-fleet-task-finished-at task))))))

(ert-deftest agent-fleet-task-wait-returns-on-blocked ()
  "`task-wait' with the default until=(done blocked) returns when any agent
blocks (§38: a blocked agent ends the `settled' wait without killing the
others).  The unblocked agent is left working."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel-test--use-working-prompt server)
    (let* ((task (agent-fleet-parallel
                  '((claude . "do A") (codex . "do B"))
                  :title "rev" :cwd "/tmp"))
           (pids (agent-fleet-task-agents task)))
      (agent-fleet-test--pump)
      (should (eq 'running (agent-fleet-task-state task)))
      ;; one agent blocked (queued); the wait's pump drains it -> blocked.
      (herdr-mock-push-event server "pane_agent_status_changed"
                             `(:pane_id ,(nth 0 pids) :agent_status "blocked"))
      (let ((res (agent-fleet-task-wait task)))
        (should (eq res task))
        (should (eq 'blocked (agent-fleet-task-state task)))
        (should (eq 'working (agent-fleet-status (nth 1 pids))))
        (should-not (agent-fleet-task-finished-at task))))))


;;; --- Cleanup (§71) --------------------------------------------------

(ert-deftest agent-fleet-task-cleanup-removes-worktrees ()
  "`task-cleanup' removes each agent's worktree via worktree.remove and
drops the task from the registry (§71).  A `done' task cleans without
prompting."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel-test--use-working-prompt server)
    (let* ((task (agent-fleet-parallel
                  '((claude . "do A") (codex . "do B"))
                  :title "rev" :cwd "/tmp"))
           (pids (agent-fleet-task-agents task))
           (task-id (agent-fleet-task-id task)))
      ;; finish the task so cleanup proceeds without a confirm prompt.
      (dolist (pid pids)
        (herdr-mock-push-event server "pane_agent_status_changed"
                               `(:pane_id ,pid :agent_status "done")))
      (agent-fleet-test--pump)
      (should (eq 'done (agent-fleet-task-state task)))
      (let ((removed (agent-fleet-task-cleanup task)))
        (should (= 2 removed))
        (should (= 2 (agent-fleet-parallel-test--count server "worktree.remove"))))
      ;; task dropped from the registry; agents no longer map to it.
      (should-not (agent-fleet-task-find task-id))
      (dolist (pid pids)
        (should-not (agent-fleet-task-for-agent pid))))))


(provide 'agent-fleet-parallel-test)
;;; agent-fleet-parallel-test.el ends here
