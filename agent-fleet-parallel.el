;;; agent-fleet-parallel.el --- parallel multi-agent orchestration -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.7.0
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The parallel-orchestration layer (PLAN.md Phase 7, §37/§38/§72).  Spawns N
;; isolated worktree agents, sends each its own prompt, and tracks their
;; aggregate status live from the event bus — the package's core value (§37).
;;
;;   (agent-fleet-parallel
;;    '((claude . "Analyze architecture")
;;      (codex  . "Analyze implementation")
;;      (pi     . "Analyze tests"))
;;    :title "auth-refactor" :cwd "~/src/myapp")
;;
;; Requirements honored (PLAN.md):
;;   §38  NOT a race: no agent is killed when the first one finishes.  The
;;        task is `done' only when ALL agents are done.
;;   §40  NO result extraction.  Agents are persistent interactive workers,
;;        not RPC functions; `agent.read' is terminal state, never a
;;        structured final answer.  `task-wait' returns the task model only.
;;   §25  no timer polling.  `task-wait' pumps `accept-process-output'
;;        (event-driven I/O, like `agent-fleet-wait'); aggregate status is
;;        driven by the status-changed hook, never a timer.
;;   §72  separate worktrees, independent names, parallel prompt, aggregate
;;        status.
;;
;; Parallel execution is free: `agent-fleet-prompt' blocks only on the submit
;; *ack*, not on agent completion, so N serial prompts yield N agents working
;; concurrently.  This layer adds the task model + aggregate tracking on top
;; of the Phase 2/5 primitives (`agent-fleet-start :worktree t',
;; `agent-fleet-prompt', the status hook bus).  It adds no wire protocol.
;;
;; Task ≠ Herdr agent (§41): an agent can run many tasks; this is fleet-side
;; metadata, kept in a registry here, not on the Herdr-mirrored agent struct.
;;
;; The package entry point loads this feature module through the dashboard
;; after providing `agent-fleet', so its control/project/worktree requires do
;; not create a load cycle.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'agent-fleet-worktree)


;;; --- Task model (§41) -----------------------------------------------

;; Deviation from the §41 sketch: no `state' slot.  cl-defstruct would
;; generate an `agent-fleet-task-state' accessor that clashes with the
;; live-compute function below; a stored slot would also go stale the moment
;; an agent's status changed between hook fires.  Instead `agent-fleet-task-
;; state' always computes from the live cache, and `finished-at' is stamped
;; by the status hook when the task first reaches `done'.
(cl-defstruct agent-fleet-task
  "A parallel task: N isolated agents working on one logical job (PLAN §41).
AGENTS is a list of pane-id strings.  PROMPT is the shared task description
(each agent may have received a distinct prompt text; this is the label).
STARTED-AT / FINISHED-AT are float seconds (nil until the task is done).
WORKSPACES maps pane ids to their created workspace ids, so cleanup still
works after a closed pane has disappeared from the live agent cache."
  id title prompt agents workspaces started-at finished-at)


;;; --- Registry (fleet-side metadata) ---------------------------------

(defvar agent-fleet--tasks nil
  "List of live `agent-fleet-task' structs (fleet-side, not Herdr-cached).")

(defvar agent-fleet--agent-tasks
  (make-hash-table :test 'equal)
  "Hash pane-id -> task-id, so an agent's task resolves without scanning.
Populated by `agent-fleet-parallel'; cleared by `agent-fleet-task-cleanup'.")

(defvar agent-fleet--task-id-counter 0
  "Monotonic counter for `task-N' ids (mirrors `agent-fleet--name-counter').")

(defvar agent-fleet-task-changed-hook nil
  "Hook run after task registry membership changes.
Each function receives the affected `agent-fleet-task'.  This lets views
refresh the Task column immediately after creation/cleanup without polling or
misrepresenting a metadata change as an agent status transition.")

(defun agent-fleet--fresh-task-id ()
  "Return a fresh task id string `task-N'."
  (format "task-%d" (cl-incf agent-fleet--task-id-counter)))

(defun agent-fleet-task-find (id)
  "Return the `agent-fleet-task' with id ID, or nil."
  (cl-find id agent-fleet--tasks :key #'agent-fleet-task-id :test #'equal))

(defun agent-fleet-task-list ()
  "Return the list of live tasks (newest last)."
  agent-fleet--tasks)

(defun agent-fleet-task-for-agent (pane-id)
  "Return the task struct for agent PANE-ID, or nil."
  (when-let* ((task-id (gethash pane-id agent-fleet--agent-tasks)))
    (agent-fleet-task-find task-id)))


;;; --- Aggregate state (live, §72) ------------------------------------

(defun agent-fleet-task-state (task)
  "Return TASK's aggregate state: `done', `failed', `blocked', or `running'.
`done' requires every agent to report Herdr's authoritative done state.  A
missing agent is `failed', not successful: it may have crashed, been killed,
or disappeared while the client was disconnected.  Once FINISHED-AT records a
real all-done transition, later pane cleanup does not retroactively fail the
completed task.  Per §38 one agent finishing never completes the whole task."
  (if (agent-fleet-task-finished-at task)
      'done
    (let* ((agents (agent-fleet-task-agents task))
           (total (length agents))
           (done 0) (blocked nil) (missing nil))
      (dolist (pid agents)
        (let ((s (agent-fleet-status pid)))
          (cond
           ((eq s 'done) (cl-incf done))
           ((null s) (setq missing t))
           ((eq s 'blocked) (setq blocked t)))))
      (cond
       ((and (> total 0) (>= done total)) 'done)
       (missing 'failed)
       (blocked 'blocked)
       (t 'running)))))

(defun agent-fleet-task-agents-state (task)
  "Return an alist (pane-id . status-symbol) for TASK's agents, for display.
Reads the live cache; an exited/missing agent shows as `failed'."
  (mapcar (lambda (pid)
            (cons pid (or (agent-fleet-status pid) 'failed)))
          (agent-fleet-task-agents task)))


;;; --- Parallel spawn + prompt (§72) ----------------------------------

;;;###autoload
(cl-defun agent-fleet-parallel (specs &key title cwd branch base focus)
  "Spawn N isolated worktree agents and prompt each in parallel (PLAN §72).
SPECS is an alist (kind . prompt) — each agent gets its own prompt.  KIND is
a symbol or string (`claude'/`codex'/`pi'/...).  Each agent is started in its
own git worktree (`:worktree t', Phase 5) with an independent name, then
prompted.  Parallel EXECUTION is automatic: `agent-fleet-prompt' blocks only
on the submit ack, so the N agents work concurrently after this returns.

TITLE defaults to `task-N'; CWD defaults to the current project root (a
worktree needs a source repo) and is required — signals
`agent-fleet-provisioning-failed' (step `parallel-cwd') if neither yields a
directory.  BRANCH/BASE are forwarded to each `worktree.create' (nil lets
Herdr decide); FOCUS focuses each new workspace.

Returns the `agent-fleet-task' struct (state `running').  The task's
aggregate state is tracked live by the status-changed hook; call
`agent-fleet-task-wait' to block until it settles, or watch the dashboard
`T' filter.  Per §38 no agent is killed on first `done'.  A per-agent spawn
failure is caught and reported; the task records the agents that did launch."
  (interactive
   (let* ((title (read-string "Task title: "))
          (kinds (completing-read-multiple
                  "Agent kinds (RET to finish): "
                  '("claude" "codex" "pi") nil t))
          (prompt (read-string "Prompt (sent to all): "))
          (cwd (or (agent-fleet-project-root-for-cwd default-directory)
                   (read-directory-name "Source repo (cwd): "))))
     (list (mapcar (lambda (k) (cons (intern k) prompt)) kinds)
           :title title :cwd cwd)))
  (agent-fleet--ensure-connected)
  (unless specs
    (signal 'agent-fleet-error (list :hint "parallel needs at least one spec")))
  (let ((repo (or cwd (agent-fleet-project-root-for-cwd default-directory))))
    (unless (and repo (file-directory-p repo))
      (signal 'agent-fleet-provisioning-failed
              (list :step 'parallel-cwd :cwd repo)))
    (let ((task-id (agent-fleet--fresh-task-id))
          (started (float-time))
          spawned workspace-map failures)
      (let ((task-title (or title task-id)))
      ;; Spawn + prompt each agent.  A failure in one does not abort the rest.
      (dolist (spec specs)
        (let* ((kind (car spec))
               (text (cdr spec))
               (name (agent-fleet--fresh-name kind)))
          (condition-case err
              (let* ((agent (agent-fleet-start
                             kind :worktree t :cwd repo :name name
                             :branch branch :base base :focus focus))
                     (pane-id (herdr-agent-id agent)))
                ;; Record a successfully started agent before prompting it.
                ;; If the prompt RPC fails, the live agent/worktree still
                ;; exists and must remain visible to task status + cleanup.
                (push pane-id spawned)
                (push (cons pane-id (herdr-agent-workspace-id agent))
                      workspace-map)
                (condition-case prompt-err
                    (agent-fleet-prompt agent text)
                  (error (push (cons name prompt-err) failures))))
            (error
             (push (cons name err) failures)))))
      (unless spawned
        (signal 'agent-fleet-provisioning-failed
                (list :step 'parallel-spawn :failures failures)))
      (let ((task (make-agent-fleet-task
                   :id task-id :title task-title
                   :prompt (let ((prompts (delete-dups
                                           (mapcar #'cdr specs))))
                             (if (= (length prompts) 1)
                                 (car prompts)
                               "parallel task"))
                   :agents (nreverse spawned)
                   :workspaces (nreverse workspace-map)
                   :started-at started)))
        ;; Match `agent-fleet-task-list''s documented oldest-to-newest order.
        (setq agent-fleet--tasks (append agent-fleet--tasks (list task)))
        (dolist (pid (agent-fleet-task-agents task))
          (puthash pid task-id agent-fleet--agent-tasks))
        ;; Status events can arrive while the serial start/prompt acknowledgments
        ;; are still being collected, before the pane->task map exists.  Record
        ;; an already-complete task now so later pane cleanup cannot turn it into
        ;; a spurious `failed' task merely because that final hook was missed.
        (when (eq 'done (agent-fleet-task-state task))
          (setf (agent-fleet-task-finished-at task) (float-time)))
        (run-hook-with-args 'agent-fleet-task-changed-hook task)
        (when failures
          (message "agent-fleet: task %s started, %d agent(s) failed: %s"
                   task-title (length failures)
                   (mapconcat #'car failures ", ")))
        task)))))


;;; --- Wait (§38/§25) --------------------------------------------------

(defun agent-fleet-parallel--normalize-until (until)
  "Normalize UNTIL to status SYMBOLS (default `(done blocked failed)').
Unlike `agent-fleet--normalize-until' (which stringifies for the wire
`until' param of `agent.wait'), this keeps SYMBOLS: `agent-fleet-task-state'
returns a symbol and the wait loop compares with `memq', so a string list
would never match (a symbol is never `eq' to a string).  Accepts a symbol,
a string, or a list of either."
  (let ((u (or until '(done blocked failed))))
    (cond
     ((null u) nil)
     ((consp u) (delq nil (mapcar (lambda (s)
                                    (cond ((symbolp s) s)
                                          ((stringp s) (intern s))))
                                  u)))
     ((symbolp u) (list u))
     ((stringp u) (list (intern u)))
     (t nil))))

;;;###autoload
(cl-defun agent-fleet-task-wait (task &optional until
                                       &key (timeout-ms agent-fleet-wait-timeout-ms))
  "Block until TASK reaches an aggregate terminal state (PLAN §38/§72).
UNTIL is `done' (all agents done) or `(done blocked failed)' (settled = all
done, any blocked, or an agent disappeared); that settled set is the default.
TIMEOUT-MS bounds the wait (default `agent-fleet-wait-timeout-ms').

Waits in PARALLEL (wall-clock = slowest agent, not the sum): the loop pumps
`accept-process-output' — event-driven I/O, NOT timer polling (§25, same
pattern as `agent-fleet-wait') — so the live cache updates via status events
and `agent-fleet-task-state' reads fresh each iteration.  Per §38 a single
agent finishing early does NOT end the wait (it ends only when the task as a
whole reaches an `until' state).

Returns TASK (its state is now terminal, or whatever it reached at timeout).
NO result extraction (§40): returns task metadata only, never agent output — use
`agent-fleet-read' separately to inspect a finished agent."
  (interactive
   (list (or (agent-fleet-task-for-agent
              (agent-fleet--read-agent-name "Wait for task of agent"))
             (user-error "No task for agent at point"))))
  (let* ((until-syms (agent-fleet-parallel--normalize-until until))
         (deadline (+ (float-time) (/ timeout-ms 1000.0))))
    (while (and (not (memq (agent-fleet-task-state task) until-syms))
                (< (float-time) deadline))
      ;; Event-driven I/O pump (§25): drain pending process events so the
      ;; cache + hooks advance; nil proc = any process.  Short slice so the
      ;; state check re-runs promptly.
      (accept-process-output nil 0.05))
    task))


;;; --- Cleanup (§71 delete finished worktrees) ------------------------

;;;###autoload
(defun agent-fleet-task-cleanup (task &optional no-confirm)
  "Remove the worktrees of TASK's agents (PLAN §71), then drop the task.
Delegates per-agent to `agent-fleet-worktree-remove' (Phase 5: issues
`worktree.remove' + eager cache removal).  By default only finished (`done')
tasks are cleaned; a non-`done' task prompts to confirm removing live agents'
worktrees.  NO-CONFIRM (prefix arg) skips every prompt.  Returns the number
of worktrees removed."
  (interactive
   (let* ((choices (mapcar (lambda (task)
                             (cons (format "%s (%s)"
                                           (agent-fleet-task-title task)
                                           (agent-fleet-task-state task))
                                   (agent-fleet-task-id task)))
                           (agent-fleet-task-list)))
          (sel (if choices
                   (completing-read "Cleanup task: " choices nil t)
                 (user-error "No tasks to clean up"))))
     (list (agent-fleet-task-find (cdr (assoc sel choices)))
           current-prefix-arg)))
  (let* ((agents (agent-fleet-task-agents task))
         (finished-p (eq 'done (agent-fleet-task-state task))))
    (when (or no-confirm
              finished-p
              (y-or-n-p (format "Task %s is %s; remove its %d worktree(s) anyway? "
                                (agent-fleet-task-title task)
                                (agent-fleet-task-state task)
                                (length agents))))
      (let* ((resolved
              (mapcar
               (lambda (pid)
                 (let ((agent (agent-fleet--find-agent pid)))
                   (cons pid
                         (or (and agent (herdr-agent-workspace-id agent))
                             (cdr (assoc pid
                                         (agent-fleet-task-workspaces task)))))))
               agents))
             (seen-workspaces (make-hash-table :test 'equal))
             removed-workspaces failed-workspaces)
        (dolist (entry resolved)
          (let ((ws-id (cdr entry)))
            (when (and ws-id (not (gethash ws-id seen-workspaces)))
              (puthash ws-id t seen-workspaces)
              (condition-case _err
                  (progn
                    (agent-fleet-worktree-remove ws-id)
                    (push ws-id removed-workspaces))
                (error (push ws-id failed-workspaces))))))
        ;; Forget only members whose worktree was actually removed.  Failed or
        ;; unresolved members retain their task/workspace metadata so cleanup
        ;; can be retried after the user resolves dirty-worktree conflicts.
        (let* ((retained
                (cl-remove-if
                 (lambda (entry) (member (cdr entry) removed-workspaces))
                 resolved))
               (retained-pids (mapcar #'car retained)))
          (dolist (entry resolved)
            (unless (member (car entry) retained-pids)
              (remhash (car entry) agent-fleet--agent-tasks)))
          (if retained
              (setf (agent-fleet-task-agents task) retained-pids
                    (agent-fleet-task-workspaces task) retained)
            (setq agent-fleet--tasks (delq task agent-fleet--tasks)))
          (run-hook-with-args 'agent-fleet-task-changed-hook task)
          (message "agent-fleet: removed %d/%d worktree(s) for task %s%s"
                   (length removed-workspaces)
                   (hash-table-count seen-workspaces)
                   (agent-fleet-task-title task)
                   (if (or failed-workspaces retained)
                       "; failed members retained for retry"
                     ""))
          (length removed-workspaces))))))


;;; --- Live status tracking (hook) ------------------------------------

(defun agent-fleet-parallel--on-status (descriptor)
  "Stamp a task's `finished-at' when it transitions to `done'.
Looked up by the descriptor's `:pane-id' (an agent-fleet status-changed or
exited event).  No-op for agents not in a task, or for tasks already stamped.
The aggregate state itself is always computed live by `agent-fleet-task-
state'; this only records when `done' is first reached."
  (when-let* ((pid (plist-get descriptor :pane-id))
              (task (agent-fleet-task-for-agent pid)))
    (when (and (null (agent-fleet-task-finished-at task))
               (eq 'done (agent-fleet-task-state task)))
      (setf (agent-fleet-task-finished-at task) (float-time)))))

(defun agent-fleet-parallel--setup ()
  "Install the task status hook, idempotently.
Registered before the dashboard hook (this file loads via the dashboard's
`require', which runs before the dashboard's own `--setup') so `finished-at'
is stamped before the dashboard refreshes.  Safe to call repeatedly."
  (unless (memq #'agent-fleet-parallel--on-status
                agent-fleet-agent-status-changed-hook)
    (add-hook 'agent-fleet-agent-status-changed-hook
              #'agent-fleet-parallel--on-status))
  (unless (memq #'agent-fleet-parallel--on-status
                agent-fleet-agent-exited-hook)
    (add-hook 'agent-fleet-agent-exited-hook
              #'agent-fleet-parallel--on-status)))

(agent-fleet-parallel--setup)

(provide 'agent-fleet-parallel)
;;; agent-fleet-parallel.el ends here
