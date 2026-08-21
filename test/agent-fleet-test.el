;;; agent-fleet-test.el --- ERT tests for agent-fleet.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Phase 2 tests: start/prompt/read/wait/send-keys/interrupt/rename/
;; kill/switch/list/get/show-output, the hook bus, target resolution,
;; and the doctor — all against the mock server (no real Herdr).
;;
;; Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l herdr-mock-server -l test/agent-fleet-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'herdr)
(require 'herdr-model)
(require 'herdr-events)
(require 'agent-fleet)
(require 'herdr-mock-server)


;;; --- Test harness ---------------------------------------------------

(defun agent-fleet-test--pump (&optional n)
  "Pump the event loop N (default 8) times so async I/O lands."
  (dotimes (_ (or n 8))
    (accept-process-output nil 0.05)))

(defmacro with-agent-fleet-mock (path-var server-var &rest body)
  "Run BODY with a mock Herdr (agent handlers installed) and a live connection.
PATH-VAR and SERVER-VAR are bound to the socket path and mock server.
The connection is torn down and the server stopped on exit."
  (declare (indent 2))
  `(let* ((,path-var (make-temp-name "/tmp/agentfleet-"))
          (,server-var (herdr-mock-start ,path-var))
          (herdr-socket-path ,path-var)
          (herdr--conn herdr--conn)
          (agent-fleet--name-counter 0))
     (herdr-mock-set-agent-handlers ,server-var)
     (unwind-protect
         (progn
           (herdr-connect)
           (agent-fleet-test--pump)
           ,@body)
       (ignore-errors (herdr-disconnect))
       (herdr-mock-stop ,server-var)
       (setq herdr-socket-path nil))))

(defun agent-fleet-test--last-request (server method)
  "Return the params of the last request to METHOD on SERVER, or nil.
Note: a request whose params are nil (e.g. `agent.list') returns nil
here even though it was made; use `agent-fleet-test--saw-request-p' to
check mere occurrence."
  (let (found)
    (dolist (req (herdr-mock-received server))
      (when (equal (cadr req) method)
        (setq found (caddr req))))
    found))

(defun agent-fleet-test--saw-request-p (server method)
  "Return non-nil if a request to METHOD was recorded on SERVER."
  (cl-some (lambda (req) (equal (cadr req) method))
           (herdr-mock-received server)))


;;; --- Start ----------------------------------------------------------

(ert-deftest agent-fleet-start-provisions-and-caches ()
  "start provisions a pane, calls agent.start, caches the agent, fires the hook."
  (with-agent-fleet-mock path server
    (let ((agent-fleet-agent-started-hook nil)
          (fired nil))
      (add-hook 'agent-fleet-agent-started-hook
                (lambda (d) (push d fired)))
      (let* ((agent (agent-fleet-start 'claude :name "arch"))
             (pid (herdr-agent-id agent)))
        (should (herdr-agent-p agent))
        (should (equal "arch" (herdr-agent-name agent)))
        (should (equal "claude" (herdr-agent-agent agent)))
        (should (string-prefix-p "w1:pmock" pid))
        ;; cache has the agent
        (should (herdr-model-find-agent pid))
        ;; pane.split then agent.start were both called
        (should (agent-fleet-test--last-request server "pane.split"))
        (let ((start-params (agent-fleet-test--last-request server "agent.start")))
          (should (equal "arch" (plist-get start-params :name)))
          (should (equal "claude" (plist-get start-params :kind)))
          (should (equal pid (plist-get start-params :pane_id))))
        ;; started hook fires from the authoritative agent.start result
        ;; (the detected event arrives async in live Herdr; see
        ;; `agent-fleet-start'); no pump needed, but settle the cache.
        (agent-fleet-test--pump)
        (should (= 1 (length fired)))
        (should (equal "arch" (plist-get (car fired) :name)))
        (should (equal pid (plist-get (car fired) :pane-id)))))))

(ert-deftest agent-fleet-start-detected-replay-does-not-refire ()
  "A `pane_agent_detected' for an already-started agent does not refire.
Live Herdr emits `pane_agent_detected' asynchronously (from its
screen-scrape loop) after `agent.start' returns — by then the agent is
cached, so the detection takes the cached (replay) branch and the
started hook (already fired by `agent-fleet-start') is NOT re-run.
This teeth-checks the `:replayp' skip in `agent-fleet--on-pane-event':
without it the hook would fire twice."
  (with-agent-fleet-mock path server
    (let ((agent-fleet-agent-started-hook nil)
          (fired nil))
      (add-hook 'agent-fleet-agent-started-hook
                (lambda (d) (push d fired)))
      (let* ((agent (agent-fleet-start 'claude :name "arch"))
             (pid (herdr-agent-id agent)))
        (agent-fleet-test--pump)
        ;; the async detection arrives for the now-cached pane
        (herdr-mock-push-event server "pane_agent_detected"
                               `(:pane_id ,pid :workspace_id "w1"
                                 :agent "claude" :released :false))
        (agent-fleet-test--pump)
        (should (equal 1 (length fired)))
        (should (equal "arch" (plist-get (car fired) :name)))))))

(ert-deftest agent-fleet-start-with-explicit-pane ()
  "start with :pane reuses that pane (no provisioning)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'codex :name "bot" :pane "w1:p9")))
      (should (equal "w1:p9" (herdr-agent-id agent)))
      (should (equal "codex" (herdr-agent-agent agent)))
      (should-not (agent-fleet-test--last-request server "pane.split"))
      (let ((start-params (agent-fleet-test--last-request server "agent.start")))
        (should (equal "w1:p9" (plist-get start-params :pane_id)))))))

(ert-deftest agent-fleet-start-auto-name ()
  "start without :name generates a unique name."
  (with-agent-fleet-mock path server
    (let ((a1 (agent-fleet-start 'claude))
          (a2 (agent-fleet-start 'claude)))
      (should (herdr-agent-name a1))
      (should (herdr-agent-name a2))
      (should-not (equal (herdr-agent-name a1) (herdr-agent-name a2))))))


;;; --- Prompt / Wait / Read ------------------------------------------

(ert-deftest agent-fleet-prompt-sends-target-and-text ()
  "prompt sends agent.prompt with the resolved target and text.
Returns the unwrapped AgentInfo (the `agent_prompted' envelope payload)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((res (agent-fleet-prompt agent "do it")))
        ;; unwrapped AgentInfo, not a bare (:ok t) ack
        (should (equal (herdr-agent-id agent) (plist-get res :pane_id)))
        (should (equal "arch" (plist-get res :name))))
      (let ((p (agent-fleet-test--last-request server "agent.prompt")))
        (should (equal (herdr-agent-id agent) (plist-get p :target)))
        (should (equal "do it" (plist-get p :text)))
        (should-not (plist-get p :wait))))))

(ert-deftest agent-fleet-prompt-and-wait-atomic ()
  "prompt-and-wait sends a single agent.prompt with a `wait' field."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((res (agent-fleet-prompt-and-wait agent "go" :until '(done blocked))))
        ;; unwrapped AgentInfo; the wait outcome is :agent_status
        (should (equal "done" (plist-get res :agent_status)))
        (let ((p (agent-fleet-test--last-request server "agent.prompt")))
          (should (plist-get p :wait))
          (should (equal '("done" "blocked")
                         (plist-get (plist-get p :wait) :until))))))))

(ert-deftest agent-fleet-read-returns-snapshot ()
  "read returns a PaneReadResult with text and metadata."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((res (agent-fleet-read agent :lines 3)))
        (should (equal (herdr-agent-id agent) (plist-get res :pane_id)))
        (should (stringp (plist-get res :text)))
        (should (equal "recent_unwrapped" (plist-get res :source)))
        (should (equal "text" (plist-get res :format)))))))

(ert-deftest agent-fleet-read-encodes-boolean-strip-ansi ()
  "read encodes strip_ansi as a JSON boolean, not a string."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (agent-fleet-read agent)
      (let ((p (agent-fleet-test--last-request server "agent.read")))
        ;; text format defaults to strip_ansi = true (t)
        (should (eq t (plist-get p :strip_ansi))))
      ;; ansi format -> strip_ansi false
      (let ((agent-fleet-default-read-format 'ansi))
        (agent-fleet-read agent)
        (let ((p (agent-fleet-test--last-request server "agent.read")))
          (should (eq :false (plist-get p :strip_ansi))))))))

(ert-deftest agent-fleet-wait-single-rpc ()
  "wait is a single agent.wait RPC (no polling)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((res (agent-fleet-wait agent '(done))))
        ;; unwrapped AgentInfo; the outcome is :agent_status
        (should (equal "done" (plist-get res :agent_status)))
        (let ((p (agent-fleet-test--last-request server "agent.wait")))
          (should (equal '("done") (plist-get p :until))))))))


;;; --- Keys / Interrupt ----------------------------------------------

(ert-deftest agent-fleet-send-keys-single-and-list ()
  "send-keys accepts a single string or a list; both encode as an array."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (agent-fleet-send-keys agent "enter")
      (let ((p1 (agent-fleet-test--last-request server "agent.send_keys")))
        (should (equal '("enter") (plist-get p1 :keys))))
      (agent-fleet-send-keys agent '("ctrl+c" "enter"))
      (let ((p2 (agent-fleet-test--last-request server "agent.send_keys")))
        (should (equal '("ctrl+c" "enter") (plist-get p2 :keys)))))))

(ert-deftest agent-fleet-interrupt-sends-ctrl-c ()
  "interrupt sends exactly [\"ctrl+c\"].
Returns the unwrapped AgentInfo (tolerant of a bare ack on real servers)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((res (agent-fleet-interrupt agent)))
        (should res)
        ;; mock returns an agent_info envelope -> unwrapped AgentInfo
        (should (equal (herdr-agent-id agent) (plist-get res :pane_id))))
      (let ((p (agent-fleet-test--last-request server "agent.send_keys")))
        (should (equal '("ctrl+c") (plist-get p :keys)))))))


;;; --- Rename / Kill / Switch ----------------------------------------

(ert-deftest agent-fleet-rename-updates-cache ()
  "rename updates the cached agent name."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (agent-fleet-rename agent "arch2")
      (should (equal "arch2"
                     (herdr-agent-name (herdr-model-find-agent
                                        (herdr-agent-id agent))))))))

(ert-deftest agent-fleet-kill-removes-and-fires-exited-hook ()
  "kill closes the pane, removes the agent from the cache, fires exited-hook."
  (with-agent-fleet-mock path server
    (let ((agent-fleet-agent-exited-hook nil)
          (fired nil)
          (agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (add-hook 'agent-fleet-agent-exited-hook
                (lambda (d) (push d fired)))
      (let ((pid (herdr-agent-id agent)))
        (should (equal '(:ok t) (agent-fleet-kill agent)))
        (should-not (herdr-model-find-agent pid))
        (should (agent-fleet-test--last-request server "pane.close"))
        ;; exited-hook fires via the event bus (pane_closed)
        (agent-fleet-test--pump)
        (should (= 1 (length fired)))
        (should (equal pid (plist-get (car fired) :pane-id)))))))

(ert-deftest agent-fleet-switch-sends-focus ()
  "switch calls agent.focus with the resolved target."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (agent-fleet-switch agent)
      (let ((p (agent-fleet-test--last-request server "agent.focus")))
        (should (equal (herdr-agent-id agent) (plist-get p :target)))))))


;;; --- List / Get / Show-output --------------------------------------

(ert-deftest agent-fleet-list-refresh ()
  "list with refresh pulls agent.list and upserts into the cache.
Proves the `agent_list' envelope is unwrapped: removing an agent from
the cache then refreshing restores it (the pre-fix code's refresh was a
no-op and would have left it missing)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let* ((names (mapcar #'herdr-agent-name (agent-fleet-list))))
        (should (member "demo" names))
        (should (member "arch" names)))
      ;; drop the STARTED agent from the client cache; refresh must
      ;; restore it via the `agent_list' envelope (mock returns :agents,
      ;; not a bare list — the pre-fix code's refresh was a no-op).
      (let ((pid (herdr-agent-id agent)))
        (herdr-model-remove-agent pid)
        (should-not (herdr-model-find-agent pid))
        (agent-fleet-list t)
        (should (agent-fleet-test--saw-request-p server "agent.list"))
        (should (herdr-model-find-agent pid))))))

(ert-deftest agent-fleet-unwraps-typed-envelopes ()
  "agent result envelopes (the live Herdr shape) are unwrapped to payloads."
  ;; agent.list envelope -> list of AgentInfo
  (should (equal '(:pane_id "w1:p1" :name "a")
                 (car (agent-fleet--agent-list-from-result
                       '(:type "agent_list"
                         :agents ((:pane_id "w1:p1" :name "a")))))))
  ;; bare single AgentInfo still passes through
  (should (equal 1 (length (agent-fleet--agent-list-from-result
                            '(:pane_id "w1:p1" :name "a")))))
  ;; agent_info envelope -> AgentInfo
  (should (equal "w1:p1"
                 (plist-get (agent-fleet--unwrap-agent
                             '(:type "agent_info" :agent (:pane_id "w1:p1")))
                           :pane_id)))
  ;; bare AgentInfo passes through
  (should (equal "w1:p1"
                 (plist-get (agent-fleet--unwrap-agent '(:pane_id "w1:p1"))
                            :pane_id)))
  ;; a bare ack with no agent/pane_id yields nil (send_keys tolerance)
  (should-not (agent-fleet--unwrap-agent '(:type "ok")))
  ;; pane_read envelope -> PaneReadResult
  (should (equal "hi"
                 (plist-get (agent-fleet--unwrap-read
                             '(:type "pane_read" :read (:text "hi")))
                            :text))))

(ert-deftest herdr-agent-display-name-fallbacks ()
  "display-name falls back through workspace/cwd/title/kind/pane-id.
These use bare structs (no cache), so the workspace-label and cwd-basename
steps are nil and the chain reaches the terminal title / kind / id — the
late fallbacks for a malformed agent with no workspace or cwd."
  ;; name wins
  (should (equal "arch"
                 (herdr-agent-display-name
                  (make-herdr-agent :name "arch" :id "w1:p1"
                    :terminal-title-stripped "x"))))
  ;; no name/workspace/cwd -> terminal-title-stripped
  (should (equal "tty"
                 (herdr-agent-display-name
                  (make-herdr-agent :id "w1:p1"
                    :terminal-title-stripped "tty"))))
  ;; no name/workspace/cwd/title -> agent kind
  (should (equal "claude"
                 (herdr-agent-display-name
                  (make-herdr-agent :id "w1:p1" :agent "claude"))))
  ;; nothing but the pane id
  (should (equal "w1:p1"
                 (herdr-agent-display-name
                  (make-herdr-agent :id "w1:p1"))))
  (should-not (herdr-agent-display-name nil)))

(ert-deftest herdr-agent-display-name-prefers-workspace-label ()
  "display-name shows the Herdr workspace identity, NOT the terminal title.
The terminal title is the agent's current task (e.g. a Claude agent's
task text); Herdr's identity is the workspace label.  An agent in
workspace w1 (label \"demo\") with a task title \"building foo\" must
display as \"demo\", and `agent-fleet-list' messages it as \"demo · claude\".
The terminal title/cwd arrive in the PaneInfo (a `pane_created' event
carries them); `pane_agent_detected' carries only the agent kind, so
this uses `pane_created' to establish the agent with its pane fields."
  (with-agent-fleet-mock path server
    (herdr-mock-create-pane server
      `(:pane_id "w1:p2" :workspace_id "w1" :agent "claude"
        :agent_status "idle" :terminal_title "building foo"
        :terminal_title_stripped "building foo" :cwd "/tmp/demo"
        :terminal_id "term_p2" :tab_id "w1:t1" :focused nil
        :revision 0))
    (agent-fleet-test--pump)
    (let ((agent (herdr-find-agent "w1:p2")))
      (should agent)
      ;; workspace label "demo" wins over the task title "building foo"
      (should (equal "demo" (herdr-agent-display-name agent)))
      ;; the terminal title is still reachable for the Task column
      (should (equal "building foo"
                     (herdr-agent-terminal-title-stripped agent)))
      ;; the list label matches Herdr's "{workspace} · {kind}"
      (should (equal "demo · claude" (agent-fleet--list-label agent))))))

(ert-deftest agent-fleet-get-caches ()
  "get fetches authoritative info and caches it."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((got (agent-fleet-get agent)))
        (should (herdr-agent-p got))
        (should (equal "arch" (herdr-agent-name got)))))))

(ert-deftest agent-fleet-show-output-buffer ()
  "show-output opens a read-only buffer with the agent's text."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((buf-name "*Agent Output: arch*"))
        (unwind-protect
            (progn
              (agent-fleet-show-output agent 5)
              (should (get-buffer buf-name))
              (with-current-buffer buf-name
                (should (string-match-p "line 1" (buffer-string)))
                (should buffer-read-only)))
          (when (get-buffer buf-name)
            (kill-buffer buf-name)))))))


;;; --- Hook bus (event-driven) ---------------------------------------

(ert-deftest agent-fleet-done-hook-fires-on-event ()
  "a done status event fires agent-fleet-agent-done-hook."
  (with-agent-fleet-mock path server
    (let ((agent-fleet-agent-done-hook nil)
          (agent-fleet-agent-status-changed-hook nil)
          (fired nil))
      (add-hook 'agent-fleet-agent-done-hook
                (lambda (d) (push d fired)))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "done"))
      (agent-fleet-test--pump)
      (should (= 1 (length fired)))
      (should (equal "done" (plist-get (car fired) :status)))
      (should (equal "w1:p1" (plist-get (car fired) :pane-id))))))

(ert-deftest agent-fleet-blocked-hook-fires-on-event ()
  "a blocked status event fires agent-fleet-agent-blocked-hook."
  (with-agent-fleet-mock path server
    (let ((agent-fleet-agent-blocked-hook nil)
          (fired nil))
      (add-hook 'agent-fleet-agent-blocked-hook
                (lambda (d) (push d fired)))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "blocked"))
      (agent-fleet-test--pump)
      (should (= 1 (length fired)))
      (should (equal "blocked" (plist-get (car fired) :status))))))

(ert-deftest agent-fleet-status-changed-hook-routes-by-status ()
  "the status-changed hook fires for every transition; blocked/done route on."
  (with-agent-fleet-mock path server
    (let ((agent-fleet-agent-status-changed-hook nil)
          (statuses nil))
      (add-hook 'agent-fleet-agent-status-changed-hook
                (lambda (d) (push (plist-get d :status) statuses)))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "working"))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "done"))
      (agent-fleet-test--pump)
      (should (member "working" statuses))
      (should (member "done" statuses)))))

(ert-deftest agent-fleet-dotted-per-pane-status-push-fires-hook ()
  "A per-pane status push carries a DOTTED `event' kind
(`pane.agent_status_changed', the real `SubscriptionEventEnvelope' shape),
NOT the underscored global form.  The client must normalize dotted->
underscored so the model's `pane_agent_status_changed' pcase arm matches
— otherwise it falls through to `:unknown' and the agent-status hook
NEVER fires (the live-dashboard refresh path was dead before the fix; the
mock hid it by pushing the underscored global form).  This is the W3
teeth test: push the faithful dotted kind and assert the hook fires."
  (with-agent-fleet-mock path server
    (let ((agent-fleet-agent-status-changed-hook nil)
          (fired nil))
      (add-hook 'agent-fleet-agent-status-changed-hook
                (lambda (d) (push (plist-get d :status) fired)))
      ;; Faithful per-pane envelope: dotted kind, bare-string agent.
      (herdr-mock-push-event server "pane.agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "blocked"
                               :agent "claude" :workspace_id "w1"))
      (agent-fleet-test--pump)
      (should (member "blocked" fired))
      ;; and the cache reflects the transition (W4: patched in place):
      (should (equal (herdr-agent-agent-status
                      (herdr-model-find-agent (herdr-model-cache) "w1:p1"))
                     "blocked")))))


;;; --- Target resolution / status ------------------------------------

(ert-deftest agent-fleet-resolve-target-by-name-or-pane-id ()
  "target resolution prefers the pane id but accepts a name or symbol."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((pid (herdr-agent-id agent)))
        ;; by struct -> pane id
        (agent-fleet-prompt agent "s1")
        (should (equal pid (plist-get
                            (agent-fleet-test--last-request server "agent.prompt")
                            :target)))
        ;; by name -> pane id (resolved from cache)
        (agent-fleet-prompt "arch" "s2")
        (should (equal pid (plist-get
                            (agent-fleet-test--last-request server "agent.prompt")
                            :target)))
        ;; by symbol -> name -> pane id
        (agent-fleet-prompt 'arch "s3")
        (should (equal pid (plist-get
                            (agent-fleet-test--last-request server "agent.prompt")
                            :target)))
        ;; by pane-id string -> itself
        (agent-fleet-prompt pid "s4")
        (should (equal pid (plist-get
                            (agent-fleet-test--last-request server "agent.prompt")
                            :target)))))))

(ert-deftest agent-fleet-status-reads-cache ()
  "status returns the cached status as a symbol."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (should (eq 'idle (agent-fleet-status agent)))
      (agent-fleet-prompt-and-wait agent "x")
      (agent-fleet-test--pump)
      (should (eq 'done (agent-fleet-status "arch"))))))


;;; --- Error paths ---------------------------------------------------

(ert-deftest agent-fleet-not-connected-signals ()
  "calling a control RPC without a connection signals not-connected."
  (let ((herdr--conn nil))
    (should-error (agent-fleet-prompt "x" "y")
                  :type 'agent-fleet-not-connected)
    (should-error (agent-fleet-start 'claude)
                  :type 'agent-fleet-not-connected)
    (should-error (agent-fleet-read "x")
                  :type 'agent-fleet-not-connected)))

(ert-deftest agent-fleet-list-when-disconnected-is-nil-safe ()
  "list and the cache read accessors return nil (not a type error) with no session.
A nil `herdr-session' must yield an empty result, not a
`wrong-type-argument' crash on the `herdr-session' struct."
  (let ((herdr--conn nil))
    (herdr-model-clear-cache)
    (should-not (agent-fleet-list))
    (should-not (agent-fleet-list t))      ; refresh path swallows the error
    (should-not (herdr-agents))
    (should-not (herdr-workspaces))
    (should-not (herdr-panes))
    (should-not (herdr-tabs))
    (should-not (herdr-model-find-agent "w1:p1"))
    (should-not (herdr-model-find-pane "w1:p1"))
    (should-not (herdr-model-focused-pane))
    (should-not (herdr-model-focused-workspace))))

(ert-deftest agent-fleet-target-not-found-signals ()
  "an unresolvable non-string target signals target-not-found."
  (with-agent-fleet-mock path server
    (should-error (agent-fleet-prompt 42 "y")
                  :type 'agent-fleet-target-not-found)))

(ert-deftest agent-fleet-server-not-found-propagates ()
  "a not_found server error propagates as a herdr-error."
  (with-agent-fleet-mock path server
    (should-error (agent-fleet-prompt "no-such-agent" "hi")
                  :type 'herdr-error)))


;;; --- Doctor --------------------------------------------------------

(ert-deftest agent-fleet-doctor-renders ()
  "doctor renders a buffer with the herdr + agent checks."
  (with-agent-fleet-mock path server
    (let ((buf "*agent-fleet-doctor*"))
      (unwind-protect
          (progn
            (agent-fleet-doctor)
            (should (get-buffer buf))
            (with-current-buffer buf
              (should (string-match-p "Agent Fleet Doctor" (buffer-string)))
              ;; agent CLI checks are present
              (should (string-match-p "Claude Code executable" (buffer-string)))))
        (when (get-buffer buf)
          (kill-buffer buf))))))

(provide 'agent-fleet-test)
;;; agent-fleet-test.el ends here
