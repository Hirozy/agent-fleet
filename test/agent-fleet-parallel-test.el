;;; agent-fleet-parallel-test.el --- ERT tests for agent-fleet-parallel.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests: `agent-fleet-parallel' spawns N isolated worktree
;; agents and prompts each; the task model tracks aggregate state live
;; (not a race — done only when ALL agents finish); `task-wait'
;; pumps events; `task-cleanup' removes worktrees.  All
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
important behavior where one agent is done while another still runs.  This
variant leaves
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


;;; --- Parallel spawn + prompt -------------------------------------

(ert-deftest agent-fleet-parallel-spawns-isolated-worktree-agents ()
  "`agent-fleet-parallel' spawns N worktree agents, prompts each, returns a task.
Each spec yields its own worktree.create + agent.start + agent.prompt; the
agents get distinct worktrees; the returned task is `running' before any
status event lands (agents are cached `idle' from the eager start upsert,
and the prompt's status events stay queued until a pump)."
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
  "Each agent.prompt carries its spec's own prompt text (alist form)."
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

(ert-deftest agent-fleet-parallel-default-title-reuses-task-id ()
  "Generating a default title consumes exactly one task id."
  (with-agent-fleet-mock path server
    (let ((agent-fleet--task-id-counter 0)
          (agent-fleet--tasks nil)
          (agent-fleet--agent-tasks (make-hash-table :test 'equal)))
      (let ((task (agent-fleet-parallel '((claude . "review")) :cwd "/tmp")))
        (should (equal "task-1" (agent-fleet-task-id task)))
        (should (equal "task-1" (agent-fleet-task-title task)))
        (should (equal "review" (agent-fleet-task-prompt task)))
        (should (equal (list task) (agent-fleet-task-list)))))))

(ert-deftest agent-fleet-parallel-prompt-failure-retains-started-agent ()
  "A failed prompt never orphans the already-started agent/worktree."
  (with-agent-fleet-mock path server
    (let ((handlers
           (mapcar
            (lambda (cell)
              (if (equal (car cell) "agent.prompt")
                  (cons "agent.prompt"
                        (lambda (_params)
                          (list 'error "prompt_failed" "submit failed")))
                cell))
            (herdr-mock-default-agent-handlers))))
      (herdr-mock-set-handlers server handlers)
      (let ((task (agent-fleet-parallel
                   '((claude . "review")) :title "prompt-failure"
                   :cwd "/tmp")))
        (should (agent-fleet-task-p task))
        (should (= 1 (length (agent-fleet-task-agents task))))
        (let ((pid (car (agent-fleet-task-agents task))))
          (should (herdr-model-find-agent pid))
          (should (agent-fleet-task-for-agent pid)))))))

(ert-deftest agent-fleet-parallel-stamps-completion-before-task-registration ()
  "An agent finishing during prompt acknowledgement still stamps the task."
  (with-agent-fleet-mock path server
    (cl-letf (((symbol-function 'agent-fleet-prompt)
               (lambda (agent _text)
                 ;; Simulate the final status event landing before
                 ;; `agent-fleet-parallel' has installed pane->task metadata.
                 (setf (herdr-agent-agent-status agent) "done")
                 '(:agent_status "done"))))
      (let ((task (agent-fleet-parallel
                   '((claude . "fast")) :title "fast" :cwd "/tmp")))
        (should (eq 'done (agent-fleet-task-state task)))
        (should (agent-fleet-task-finished-at task))))))

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


;;; --- Aggregate state ------------------------------------------

(ert-deftest agent-fleet-parallel-agents-run-concurrently ()
  "One agent finishing does NOT make the task done.
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
      ;; agent 0 done alone -> still running.
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
blocked (not all done) => blocked; else running.  Drives the
full state machine over three agents."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel-test--use-working-prompt server)
    (let* ((task (agent-fleet-parallel
                  '((claude . "do A") (codex . "do B") (pi-agent . "do C"))
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
      ;; two of three done, one working -> still running.
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

(ert-deftest agent-fleet-task-missing-agent-is-failed-not-done ()
  "A crashed, killed, or disconnected agent cannot complete its task."
  (let ((agent-fleet--tasks nil)
        (agent-fleet--agent-tasks (make-hash-table :test 'equal)))
    (with-agent-fleet-mock path server
      (agent-fleet-parallel-test--use-working-prompt server)
      (let* ((task (agent-fleet-parallel
                    '((claude . "do A")) :title "rev" :cwd "/tmp"))
             (pid (car (agent-fleet-task-agents task))))
        (agent-fleet-test--pump)
        (should (eq 'running (agent-fleet-task-state task)))
        (herdr-model-remove-agent pid)
        (should (eq 'failed (agent-fleet-task-state task)))
        (should (equal `((,pid . failed))
                       (agent-fleet-task-agents-state task)))
        ;; Default settled-state wait includes failed and returns immediately.
        (should (eq task (agent-fleet-task-wait task nil :timeout-ms 100)))
        (should-not (agent-fleet-task-finished-at task))))))

(ert-deftest agent-fleet-task-pane-move-migrates-member-identity ()
  "A moved task agent keeps its task membership and cleanup workspace."
  (let* ((session (herdr-model--empty-session))
         (task (make-agent-fleet-task
                :id "task-move" :title "move" :prompt "review"
                :agents '("w1:p1") :workspaces '(("w1:p1" . "w1"))
                :started-at 1.0))
         (agent-fleet--tasks (list task))
         (agent-fleet--agent-tasks (make-hash-table :test 'equal))
         (agent-fleet-task-changed-hook nil)
         (herdr-event-hook nil)
         (herdr-event-pane-hook '(agent-fleet-parallel--on-pane-event))
         changed removed)
    (herdr-model-set-cache session)
    (herdr-model-upsert-agent-info
     '(:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
       :agent "codex" :agent_status "working")
     session)
    (puthash "w1:p1" "task-move" agent-fleet--agent-tasks)
    (add-hook 'agent-fleet-task-changed-hook
              (lambda (seen) (push seen changed)))
    (unwind-protect
        (progn
          (herdr-events-dispatch
           "pane_moved"
           '(:previous_pane_id "w1:p1"
             :pane (:pane_id "w2:p2" :workspace_id "w2" :tab_id "w2:t1"
                    :agent "codex" :agent_status "working")))
          (should-not (herdr-model-find-agent session "w1:p1"))
          (should (herdr-model-find-agent session "w2:p2"))
          (should (equal '("w2:p2") (agent-fleet-task-agents task)))
          (should (equal '(("w2:p2" . "w1"))
                         (agent-fleet-task-workspaces task)))
          (should-not (gethash "w1:p1" agent-fleet--agent-tasks))
          (should (eq task (agent-fleet-task-for-agent "w2:p2")))
          (should (eq 'running (agent-fleet-task-state task)))
          (should (equal (list task) changed))
          ;; Cleanup must use the original worktree workspace (w1), not the
          ;; agent's current post-move workspace (w2).
          (cl-letf (((symbol-function 'agent-fleet-worktree-remove)
                     (lambda (workspace-id &optional _force)
                       (push workspace-id removed))))
            (should (= 1 (agent-fleet-task-cleanup task t)))
            (should (equal '("w1") removed))))
      (herdr-model-clear-cache))))


;;; --- Task wait ------------------------------------------------

(ert-deftest agent-fleet-task-wait-blocks-until-done ()
  "`task-wait' pumps `accept-process-output' and returns once the task is
`done'.  The done events are queued before the call; the wait's
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
blocks (a blocked agent ends the `settled' wait without killing the
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


;;; --- Cleanup -----------------------------------------------------

(ert-deftest agent-fleet-task-cleanup-removes-worktrees ()
  "`task-cleanup' removes each agent's worktree via worktree.remove and
drops the task from the registry.  A `done' task cleans without
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

(ert-deftest agent-fleet-task-cleanup-survives-missing-agent-cache ()
  "Task metadata retains workspace ids after exited agents are evicted."
  (with-agent-fleet-mock path server
    (agent-fleet-parallel-test--use-working-prompt server)
    (let* ((task (agent-fleet-parallel '((claude . "do A"))
                                       :title "missing" :cwd "/tmp"))
           (pid (car (agent-fleet-task-agents task))))
      (should (cdr (assoc pid (agent-fleet-task-workspaces task))))
      (herdr-model-remove-agent pid)
      (should (eq 'failed (agent-fleet-task-state task)))
      (should (= 1 (agent-fleet-task-cleanup task t)))
      (should (= 1 (agent-fleet-parallel-test--count
                    server "worktree.remove"))))))

(ert-deftest agent-fleet-task-cleanup-retains-failed-members-for-retry ()
  "Partial cleanup keeps failed worktree metadata and drops only successes."
  (let* ((task (make-agent-fleet-task
                :id "task-partial" :title "partial" :prompt "review"
                :agents '("w1:p1" "w2:p1")
                :workspaces '(("w1:p1" . "w1") ("w2:p1" . "w2"))
                :started-at 1.0 :finished-at 2.0))
         (agent-fleet--tasks (list task))
         (agent-fleet--agent-tasks (make-hash-table :test 'equal))
         calls)
    (puthash "w1:p1" "task-partial" agent-fleet--agent-tasks)
    (puthash "w2:p1" "task-partial" agent-fleet--agent-tasks)
    (cl-letf (((symbol-function 'agent-fleet--find-agent) (lambda (_) nil))
              ((symbol-function 'agent-fleet-worktree-remove)
               (lambda (workspace-id &optional _force)
                 (push workspace-id calls)
                 (when (equal workspace-id "w2")
                   (error "dirty worktree")))))
      (should (= 1 (agent-fleet-task-cleanup task t)))
      (should (equal '("w1" "w2") (sort calls #'string<)))
      (should (eq task (agent-fleet-task-find "task-partial")))
      (should (equal '("w2:p1") (agent-fleet-task-agents task)))
      (should (equal '(("w2:p1" . "w2"))
                     (agent-fleet-task-workspaces task)))
      (should-not (gethash "w1:p1" agent-fleet--agent-tasks))
      (should (equal "task-partial"
                     (gethash "w2:p1" agent-fleet--agent-tasks))))))


(provide 'agent-fleet-parallel-test)
;;; agent-fleet-parallel-test.el ends here
