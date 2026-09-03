;;; agent-fleet-test.el --- ERT tests for agent-fleet.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests: start/prompt/read/wait/send-keys/interrupt/rename/
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

(ert-deftest herdr-mock-default-state-is-isolated-between-servers ()
  "Mutating one mock's agent state never changes a later default server."
  (let* ((path-1 (make-temp-name "/tmp/herdr-mock-isolation-1-"))
         (path-2 (make-temp-name "/tmp/herdr-mock-isolation-2-"))
         (server-1 (herdr-mock-start path-1))
         server-2)
    (unwind-protect
        (progn
          (should (equal "working"
                         (herdr-mock-agent-state server-1 "w1:p1")))
          (herdr-mock--agent-transition server-1 "w1:p1" "done")
          (should (equal "done"
                         (herdr-mock-agent-state server-1 "w1:p1")))
          (herdr-mock-stop server-1)
          (setq server-1 nil
                server-2 (herdr-mock-start path-2))
          (should (equal "working"
                         (herdr-mock-agent-state server-2 "w1:p1"))))
      (when server-1 (herdr-mock-stop server-1))
      (when server-2 (herdr-mock-stop server-2)))))


;;; --- Start ----------------------------------------------------------

(ert-deftest agent-fleet-provision-pane-stays-in-requested-workspace ()
  "A globally focused pane in another workspace is never split."
  (let ((session (herdr-model-parse-snapshot
                  '(:focused_workspace_id "w1" :focused_tab_id "w1:t1"
                    :focused_pane_id "w1:p1"
                    :workspaces ((:workspace_id "w1") (:workspace_id "w2"))
                    :tabs ()
                    :panes ((:pane_id "w1:p1" :workspace_id "w1"
                             :tab_id "w1:t1" :terminal_id "t1"
                             :focused t :revision 0 :agent_status "idle")
                            (:pane_id "w2:p1" :workspace_id "w2"
                             :tab_id "w2:t1" :terminal_id "t2"
                             :focused :false :revision 0 :agent_status "idle"))
                    :agents ()))))
    (let ((herdr-model--cache session)
          split-params)
      (cl-letf (((symbol-function 'herdr-request)
                 (lambda (method &optional params &rest _keys)
                   (when (equal method "pane.split")
                     (setq split-params params))
                   '(:pane_id "w2:p2"))))
        (should (equal "w2:p2"
                       (agent-fleet--provision-pane "w2" "/repo" nil))))
      (should (equal "w2"
                     (alist-get "workspace_id" split-params nil nil #'equal)))
      (should (equal "w2:p1"
                     (alist-get "target_pane_id" split-params nil nil #'equal))))))

(ert-deftest agent-fleet-provision-pane-uses-tab-root-pane-envelope ()
  "tab.create uses its root_pane and never an unrelated pane.current."
  (let ((herdr-model--cache (herdr-model--empty-session))
        methods)
    (cl-letf (((symbol-function 'herdr-request)
               (lambda (method &optional _params &rest _keys)
                 (push method methods)
                 (pcase method
                   ("tab.create"
                    '(:type "tab_created"
                      :tab (:tab_id "w9:t1" :workspace_id "w9")
                      :root_pane (:pane_id "w9:p1" :workspace_id "w9"
                                  :tab_id "w9:t1")))
                   ("pane.current" '(:pane_id "wrong:pane"))))))
      (should (equal "w9:p1"
                     (agent-fleet--provision-pane "w9" "/repo" nil))))
    (should (equal '("tab.create") (nreverse methods)))))

(ert-deftest agent-fleet-start-reuses-new-workspace-root-pane ()
  "workspace.create's root pane is the agent target; no extra tab is made."
  (let ((herdr-model--cache (herdr-model--empty-session))
        (agent-fleet-agent-started-hook nil)
        methods start-params)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _keys)
                 (push method methods)
                 (pcase method
                   ("workspace.create"
                    '(:type "workspace_created"
                      :workspace (:workspace_id "new" :label "repo")
                      :tab (:tab_id "new:t1" :workspace_id "new")
                      :root_pane (:pane_id "new:p1" :workspace_id "new"
                                  :tab_id "new:t1" :cwd "/repo")))
                   ("agent.start"
                    (setq start-params params)
                    '(:type "agent_started"
                      :agent (:pane_id "new:p1" :workspace_id "new"
                              :name "root" :agent "codex"
                              :agent_status "idle")))
                   (_ (error "unexpected request %s" method))))))
      (should (herdr-agent-p
               (agent-fleet-start 'codex :name "root" :cwd "/repo"))))
    (should (equal "new:p1" (alist-get "pane_id" start-params nil nil
                                        #'equal)))
    (should (equal '("workspace.create" "agent.start")
                   (nreverse methods)))))

(ert-deftest agent-fleet-resolve-pane-id-unwraps-agent-get ()
  "An uncached agent name resolves through the typed agent_info envelope."
  (let ((herdr-model--cache (herdr-model--empty-session)))
    (cl-letf (((symbol-function 'herdr-request)
               (lambda (method &optional params &rest _keys)
                 (should (equal method "agent.get"))
                 (should (equal "arch" (alist-get "target" params nil nil
                                                   #'equal)))
                 '(:type "agent_info"
                   :agent (:pane_id "w1:p7" :name "arch"
                           :agent "codex")))))
      (should (equal "w1:p7" (agent-fleet--resolve-pane-id "arch"))))))

(ert-deftest agent-fleet-long-rpcs-expand-transport-timeout ()
  "Server timeout_ms is always shorter than the socket request timeout."
  (let ((herdr-model--cache (herdr-model--empty-session))
        calls)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet--resolve-target)
               (lambda (_agent) "w1:p1"))
              ((symbol-function 'herdr-request)
               (lambda (method &optional _params &rest keys)
                 (push (cons method (plist-get keys :timeout)) calls)
                 '(:type "agent_info"
                   :agent (:pane_id "w1:p1" :workspace_id "w1"
                           :agent "claude" :agent_status "done")))))
      (agent-fleet-prompt-and-wait "w1:p1" "go" :timeout-ms 9000)
      (agent-fleet-wait "w1:p1" nil :timeout-ms 11000))
    (should (= 14.0 (cdr (assoc "agent.prompt" calls))))
    (should (= 16.0 (cdr (assoc "agent.wait" calls))))))

(ert-deftest agent-fleet-start-expands-transport-timeout ()
  "agent.start keeps its socket alive beyond the server startup deadline."
  (let ((herdr-model--cache (herdr-model--empty-session))
        (agent-fleet-agent-started-hook nil)
        captured-timeout)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (method &optional _params &rest keys)
                 (when (equal method "agent.start")
                   (setq captured-timeout (plist-get keys :timeout)))
                 '(:type "agent_started"
                   :agent (:pane_id "w1:p9" :workspace_id "w1"
                           :name "slow" :agent "codex"
                           :agent_status "idle")))))
      (agent-fleet-start 'codex :name "slow" :workspace "w1"
                         :pane "w1:p9" :timeout-ms 7000))
    (should (= 12.0 captured-timeout))))

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

(ert-deftest agent-fleet-start-explicit-pane-does-not-create-workspace ()
  "An explicit pane is sufficient even when no workspace is focused."
  (let ((herdr-model--cache (herdr-model--empty-session))
        (agent-fleet-agent-started-hook nil)
        methods)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (method &optional _params &rest _keys)
                 (push method methods)
                 (pcase method
                   ("agent.start"
                    '(:type "agent_started"
                      :agent (:pane_id "w9:p7" :workspace_id "w9"
                              :name "direct" :agent "codex"
                              :agent_status "idle")))
                   (_ (error "unexpected request %s" method))))))
      (should (herdr-agent-p
               (agent-fleet-start 'codex :name "direct" :pane "w9:p7"))))
    (should (equal '("agent.start") (nreverse methods)))))

(ert-deftest agent-fleet-start-auto-name ()
  "start without :name generates a unique name."
  (with-agent-fleet-mock path server
    (let ((a1 (agent-fleet-start 'claude))
          (a2 (agent-fleet-start 'claude)))
      (should (herdr-agent-name a1))
      (should (herdr-agent-name a2))
      (should-not (equal (herdr-agent-name a1) (herdr-agent-name a2))))))


;;; --- Interactive workspace picking + auto-attach -------------------

(defun agent-fleet-test--unfocused-session ()
  "Return a cache with one workspace (w1) but no focused workspace or panes.
This is the state that triggers the interactive workspace picker: a
workspace exists to choose, yet none is focused, so a non-interactive
start would fall through to creating a new frame."
  (let ((session (herdr-model--empty-session)))
    (puthash "w1" (make-herdr-workspace :id "w1" :custom-name "demo")
             (herdr-session-workspaces session))
    session))

(ert-deftest agent-fleet-read-workspace-returns-chosen-id ()
  "The interactive workspace picker offers cached workspaces via
`completing-read' and returns the selected workspace id (not its label)."
  (let ((herdr-model--cache (agent-fleet-test--unfocused-session)))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (car (car collection)))))   ; pick the first choice
      (should (equal "w1"
                     (agent-fleet--read-workspace "Start in workspace: "))))))

(ert-deftest agent-fleet-read-workspace-errors-when-none-cached ()
  "With no workspace cached the picker signals `user-error' rather than
returning nil (which would silently fall through to creating a new frame)."
  (let ((herdr-model--cache (herdr-model--empty-session)))
    (should-error (agent-fleet--read-workspace "Start in workspace: ")
                  :type 'user-error)))

(ert-deftest agent-fleet-kind-choices-maps-executable-to-symbol ()
  "Interactive kind prompts display the executable name (what the user runs
in the shell) and map the selection back to the kind symbol.  The
`pi-agent' kind runs the `pi' executable, so the user picks `pi' while
the code receives `pi-agent' — the internal symbol must not surface in
the minibuffer, where it would otherwise inherit Emacs's obsolete `pi'
variable marker."
  (let ((choices (agent-fleet--kind-choices)))
    (should (equal 'claude (cdr (assoc "claude" choices #'equal))))
    (should (equal 'codex (cdr (assoc "codex" choices #'equal))))
    (should (equal 'pi-agent (cdr (assoc "pi" choices #'equal))))
    ;; The candidate labels shown to the user are executable names, never
    ;; the internal kind symbols.
    (should-not (member "pi-agent" (mapcar #'car choices))))
  ;; Executable customization must not silently change the protocol kind.
  (let ((agent-fleet-agent-executables
         '((claude "/opt/local/claude-wrapper" "Claude Code"))))
    (should (equal "claude" (agent-fleet--kind-wire-name 'claude)))))

(ert-deftest agent-fleet-suggest-name ()
  "Default name suggestion is `<workspace-label>-<smallest free serial>',
and falls back to the global kind+counter when there is no workspace."
  (let* ((session (herdr-model--empty-session))
         (herdr-model--cache session)
         (ws (make-herdr-workspace :id "ws1" :custom-name "demo")))
    (puthash "ws1" ws (herdr-session-workspaces session))
    ;; No agents yet: serial starts at 1.
    (should (equal "demo-1" (agent-fleet--suggest-name "ws1" 'codex)))
    ;; Occupy demo-1 and demo-2: the next free serial is 3.
    (puthash "p1" (make-herdr-agent :id "p1" :workspace-id "ws1"
                                    :name "demo-1" :agent "codex")
             (herdr-session-agents session))
    (puthash "p2" (make-herdr-agent :id "p2" :workspace-id "ws1"
                                    :name "demo-2" :agent "codex")
             (herdr-session-agents session))
    (should (equal "demo-3" (agent-fleet--suggest-name "ws1" 'codex)))
    ;; No workspace id: fall back to the global kind+counter default.
    (let ((agent-fleet--name-counter 0))
      (should (equal "codex-1" (agent-fleet--suggest-name nil 'codex))))))

(ert-deftest agent-fleet-start-pi-agent-uses-pi-wire-kind ()
  "The internal `pi-agent' alias never reaches `agent.start' or auto names."
  (with-agent-fleet-mock path server
    (let* ((agent (agent-fleet-start 'pi-agent))
           (params (agent-fleet-test--last-request server "agent.start")))
      (should (equal "pi" (plist-get params :kind)))
      (should (equal "pi" (herdr-agent-agent agent)))
      (should (string-prefix-p "pi-" (herdr-agent-name agent)))
      (should-not (string-prefix-p "pi-agent-" (herdr-agent-name agent))))))

(ert-deftest agent-fleet-start-interactive-picks-workspace-and-opens-tab ()
  "An interactive start always prompts for the workspace (manual selection
is required) and opens the agent as a fresh tab in it — not a new frame,
and not a pane split.  `called-interactively-p' is stubbed to model the
command-loop case: in batch a plain `call-interactively' does not set it
(the interactive test suite uses the same convention)."
  (let ((herdr-model--cache (agent-fleet-test--unfocused-session))
        (agent-fleet-agent-started-hook nil)
        methods)
    (cl-letf (((symbol-function 'called-interactively-p) (lambda (_) t))
              ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet-attach) #'ignore) ; attach tested elsewhere
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (car (car collection))))   ; pick the first workspace
              ((symbol-function 'herdr-request)
               (lambda (method &optional _params &rest _)
                 (push method methods)
                 (pcase method
                   ("tab.create"
                    '(:type "tab_created"
                      :tab (:tab_id "w1:t2" :workspace_id "w1")
                      :root_pane (:pane_id "w1:p2" :workspace_id "w1"
                                  :tab_id "w1:t2")))
                   ("agent.start"
                    '(:type "agent_started"
                      :agent (:pane_id "w1:p2" :workspace_id "w1"
                              :name "arch" :agent "claude"
                              :agent_status "idle")))
                   (_ (error "unexpected request %s" method))))))
      (should (herdr-agent-p (agent-fleet-start 'claude :name "arch"))))
    (should (member "tab.create" methods))
    (should-not (member "pane.split" methods))
    (should-not (member "workspace.create" methods))
    (should (member "agent.start" methods))))

(ert-deftest agent-fleet-start-interactive-prompts-even-when-workspace-focused ()
  "An interactive start prompts for the workspace even when one is already
focused — it does not silently reuse the focused workspace.  The selected
workspace receives a fresh tab, not a split of the focused pane.  This is
the regression for the reported bug where a focused workspace let the
start skip selection entirely."
  (let* ((session (agent-fleet-test--unfocused-session))
         ;; Give w1 a focused pane so the focused-workspace shortcut would
         ;; apply (and a pane.split would be attempted) without the fix.
         (pane (make-herdr-pane :id "w1:p1" :workspace-id "w1"
                                :tab-id "w1:t1" :cwd "/tmp" :focused t))
         (agent-fleet-agent-started-hook nil)
         (completing-read-called nil)
         methods)
    (setf (herdr-session-focused-workspace-id session) "w1"
          (herdr-session-focused-pane-id session) "w1:p1")
    (puthash "w1:p1" pane (herdr-session-panes session))
    (let ((herdr-model--cache session))
      (cl-letf (((symbol-function 'called-interactively-p) (lambda (_) t))
                ((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                ((symbol-function 'agent-fleet-attach) #'ignore)
                ((symbol-function 'completing-read)
                 (lambda (_prompt _collection &rest _)
                   (setq completing-read-called t)
                   "w1 (demo)"))
                ((symbol-function 'herdr-request)
                 (lambda (method &optional _params &rest _)
                   (push method methods)
                   (pcase method
                     ("tab.create"
                      '(:type "tab_created"
                        :tab (:tab_id "w1:t2" :workspace_id "w1")
                        :root_pane (:pane_id "w1:p2" :workspace_id "w1"
                                    :tab_id "w1:t2")))
                     ("agent.start"
                      '(:type "agent_started"
                        :agent (:pane_id "w1:p2" :workspace_id "w1"
                                :name "arch" :agent "claude"
                                :agent_status "idle")))
                     (_ (error "unexpected request %s" method))))))
        (should (herdr-agent-p (agent-fleet-start 'claude :name "arch")))))
    (should completing-read-called)
    (should (member "tab.create" methods))
    (should-not (member "pane.split" methods))
    (should-not (member "workspace.create" methods))))

(ert-deftest agent-fleet-start-programming-does-not-attach-or-prompt ()
  "A non-interactive start (the path taken by parallel orchestration and
external scripts) neither attaches the terminal nor prompts for a
workspace.  `called-interactively-p' is left at its batch default (nil)
and :attach defaults to nil, so both are skipped.  With no focused
workspace the original fallback (create a new frame) is preserved for
programming callers."
  (let ((herdr-model--cache (agent-fleet-test--unfocused-session))
        (agent-fleet-agent-started-hook nil)
        attach-called read-called)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet-attach)
               (lambda (&rest _) (setq attach-called t)))
              ((symbol-function 'agent-fleet--read-workspace)
               (lambda (&rest _) (setq read-called t) nil))
              ((symbol-function 'herdr-request)
               (lambda (method &optional _params &rest _)
                 (pcase method
                   ("workspace.create"
                    '(:type "workspace_created"
                      :workspace (:workspace_id "new" :label "repo")
                      :tab (:tab_id "new:t1" :workspace_id "new")
                      :root_pane (:pane_id "new:p1" :workspace_id "new"
                                  :tab_id "new:t1" :cwd "/repo")))
                   ("agent.start"
                    '(:type "agent_started"
                      :agent (:pane_id "new:p1" :workspace_id "new"
                              :name "arch" :agent "claude"
                              :agent_status "idle")))
                   (_ (error "unexpected request %s" method))))))
      (should (herdr-agent-p (agent-fleet-start 'claude :name "arch" :cwd "/repo"))))
    (should-not attach-called)
    (should-not read-called)))


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

(ert-deftest agent-fleet-ordinary-pane-close-does-not-fire-agent-exited-hook ()
  "Closing a shell pane is not reported as an agent lifecycle event."
  (let ((agent-fleet-agent-exited-hook nil)
        (fired nil))
    (add-hook 'agent-fleet-agent-exited-hook
              (lambda (descriptor) (push descriptor fired)))
    (agent-fleet--on-pane-event
     '(:event "pane_closed" :what :pane-closed :id "w1:shell"
       :agentp nil :replayp nil))
    (should-not fired)))

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

(ert-deftest agent-fleet-list-refresh-removes-server-absent-agents ()
  "Authoritative agent.list removes stale client-only cache entries."
  (with-agent-fleet-mock path server
    (herdr-model-upsert-agent-info
     '(:pane_id "gone:p1" :workspace_id "gone" :name "ghost"
       :agent "codex" :agent_status "idle"))
    (should (herdr-model-find-agent "gone:p1"))
    (agent-fleet-list t)
    (should-not (herdr-model-find-agent "gone:p1"))
    (should (herdr-model-find-agent "w1:p1"))))

(ert-deftest agent-fleet-list-refresh-replays-concurrent-event-after-snapshot ()
  "An event received during agent.list is replayed after its stale snapshot.
`herdr-request' synchronously pumps process output, so the subscription can
deliver a newer event before the request returns.  The refresh must rebuild
from the response first and then apply that queued event, making the event's
status authoritative."
  (let* ((session (herdr-model--empty-session))
         (herdr-model--cache session)
         (herdr--event-deferral-depth 0)
         (herdr--deferred-events nil))
    (puthash "w1:p1"
             (make-herdr-agent :id "w1:p1" :workspace-id "w1"
                               :agent "claude" :agent-status "working")
             (herdr-session-agents session))
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected)
               (lambda () t))
              ((symbol-function 'herdr-request)
               (lambda (method &optional _params &rest _keys)
                 (should (equal method "agent.list"))
                 ;; Model a subscription frame handled by
                 ;; `accept-process-output' while the request is in flight.
                 (herdr--on-event
                  "pane_agent_status_changed"
                  '(:pane_id "w1:p1" :agent "claude"
                    :agent_status "done"))
                 '(:type "agent_list"
                   :agents ((:pane_id "w1:p1" :workspace_id "w1"
                              :agent "claude" :agent_status "working"))))))
      (agent-fleet-list t))
    (should (equal "done"
                   (herdr-agent-agent-status
                    (herdr-model-find-agent session "w1:p1"))))))

(ert-deftest herdr-deferred-events-preserve-order-and-survive-error ()
  "Deferred events replay in arrival order even when the protected call fails."
  (let* ((session (herdr-model--empty-session))
         (herdr-model--cache session)
         (herdr--event-deferral-depth 0)
         (herdr--deferred-events nil)
         (seen nil)
         (herdr-event-agent-status-hook
          (list (lambda (descriptor)
                  (setq seen (append seen (list (plist-get descriptor :status))))))))
    (puthash "w1:p1"
             (make-herdr-agent :id "w1:p1" :workspace-id "w1"
                               :agent "claude" :agent-status "working")
             (herdr-session-agents session))
    (should-error
     (herdr-call-with-deferred-events
      (lambda ()
        (herdr--on-event
         "pane_agent_status_changed"
         '(:pane_id "w1:p1" :agent "claude" :agent_status "blocked"))
        (herdr--on-event
         "pane_agent_status_changed"
         '(:pane_id "w1:p1" :agent "claude" :agent_status "done"))
        (should (equal "working"
                       (herdr-agent-agent-status
                        (herdr-model-find-agent session "w1:p1"))))
        (error "simulated request failure"))))
    (should (equal '("blocked" "done") seen))
    (should (equal "done"
                   (herdr-agent-agent-status
                    (herdr-model-find-agent session "w1:p1"))))))

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

(ert-deftest agent-fleet-show-output-in-buffer-view ()
  "`agent-fleet-show-output-in-buffer' opens a read-only buffer with the
agent's text."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((buf-name "*Agent Output: arch*"))
        (unwind-protect
            (progn
              (agent-fleet-show-output-in-buffer agent 5)
              (should (get-buffer buf-name))
              (with-current-buffer buf-name
                (should (string-match-p "line 1" (buffer-string)))
                (should buffer-read-only)
                (should (eq 'quit-window
                            (lookup-key (current-local-map) (kbd "q"))))))
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
      ;; A duplicate/replayed state must not produce a second side effect.
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
                             '(:pane_id "w1:p1" :agent_status "idle"))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "done"))
      (agent-fleet-test--pump)
      (should (member "idle" statuses))
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
  "Manual policy keeps the explicit not-connected error behavior."
  (let ((herdr--conn nil)
        (agent-fleet-auto-connect nil))
    (should-error (agent-fleet-prompt "x" "y")
                  :type 'agent-fleet-not-connected)
    (should-error (agent-fleet-start 'claude)
                  :type 'agent-fleet-not-connected)
    (should-error (agent-fleet-read "x")
                  :type 'agent-fleet-not-connected)))

(ert-deftest agent-fleet-ensure-connected-connects-on-demand-once ()
  "Automatic mode connects at first use and reuses the live connection."
  (let ((agent-fleet-auto-connect 'on-demand)
        (connected nil)
        (calls 0))
    (cl-letf (((symbol-function 'herdr-connected-p)
               (lambda () connected))
              ((symbol-function 'herdr-connect)
               (lambda (&optional _socket-path)
                 (cl-incf calls)
                 (setq connected t))))
      (should (agent-fleet--ensure-connected))
      (should (agent-fleet--ensure-connected)))
    (should (= 1 calls))))

(ert-deftest agent-fleet-control-command-connects-on-demand-end-to-end ()
  "A real control call bootstraps the protocol before sending its RPC."
  (let* ((path (make-temp-name "/tmp/agentfleet-auto-connect-"))
         (server (herdr-mock-start path))
         (herdr-socket-path path)
         (herdr--conn nil)
         (agent-fleet-auto-connect 'on-demand))
    (herdr-mock-set-agent-handlers server)
    (unwind-protect
        (progn
          (should-not (herdr-connected-p))
          (should (agent-fleet-prompt "demo" "connect automatically"))
          (should (herdr-connected-p))
          (should (agent-fleet-test--saw-request-p server "ping"))
          (should (agent-fleet-test--saw-request-p server "session.snapshot"))
          (should (agent-fleet-test--saw-request-p server "events.subscribe"))
          (should (agent-fleet-test--saw-request-p server "agent.prompt")))
      (ignore-errors (herdr-disconnect))
      (herdr-mock-stop server))))

(ert-deftest agent-fleet-ensure-connected-reports-auto-connect-cause ()
  "A failed automatic attempt becomes an actionable fleet-level error."
  (let ((agent-fleet-auto-connect 'on-demand))
    (cl-letf (((symbol-function 'herdr-connected-p) (lambda () nil))
              ((symbol-function 'herdr-connect)
               (lambda (&optional _socket-path)
                 (signal 'herdr-connection-error '(:reason no-server)))))
      (let* ((condition
              (should-error (agent-fleet--ensure-connected)
                            :type 'agent-fleet-not-connected))
             (data (cdr condition)))
        (should (eq 'herdr-connection-error
                    (car (plist-get data :cause))))
        (should (string-match-p "Herdr server"
                                (plist-get data :hint)))))))

(ert-deftest agent-fleet-ensure-connected-does-not-reenter-connect ()
  "A re-entrant timer or command never starts a second bootstrap."
  (let ((agent-fleet-auto-connect 'on-demand)
        (agent-fleet--connect-in-progress t)
        called)
    (cl-letf (((symbol-function 'herdr-connected-p) (lambda () nil))
              ((symbol-function 'herdr-connect)
               (lambda (&optional _socket-path) (setq called t))))
      (should-error (agent-fleet--ensure-connected)
                    :type 'agent-fleet-not-connected))
    (should-not called)))

(ert-deftest agent-fleet-ensure-connected-does-not-redetect-during-reconnect ()
  "A command during reconnect preserves the connection's saved endpoint.
Changing the Session and explicit socket settings while the reconnect timer
is pending must not call `herdr-connect' and rediscover a different socket."
  (let* ((saved "/tmp/agent-fleet-session-a.sock")
         (herdr--conn
          (make-herdr--connection :socket-path saved
                                  :connected nil
                                  :reconnect-timer 'pending-reconnect))
         (herdr-socket-path "/tmp/agent-fleet-session-b.sock")
         (herdr-default-session-name "session-b")
         (agent-fleet-auto-connect 'on-demand)
         called)
    (cl-letf (((symbol-function 'herdr-connect)
               (lambda (&optional _path) (setq called t))))
      (let* ((err (should-error (agent-fleet--ensure-connected)
                                :type 'agent-fleet-not-connected))
             (data (cdr err)))
        (should-not called)
        (should (equal saved (herdr--connection-socket-path herdr--conn)))
        (should (string-match-p "existing Session endpoint"
                                (plist-get data :hint)))))))

(ert-deftest agent-fleet-after-init-auto-connect-is-idle-and-nonfatal ()
  "Startup mode schedules on idle and contains a failed bootstrap."
  (let ((agent-fleet-auto-connect 'after-init)
        (agent-fleet-auto-connect-delay 0.25)
        (agent-fleet--auto-connect-timer nil)
        scheduled-delay scheduled-function messages)
    (cl-letf (((symbol-function 'herdr-connected-p) (lambda () nil))
              ((symbol-function 'run-with-idle-timer)
               (lambda (delay repeat function &rest _args)
                 (should-not repeat)
                 (setq scheduled-delay delay
                       scheduled-function function)
                 'test-auto-connect-timer))
              ((symbol-function 'herdr-connect)
               (lambda (&optional _socket-path)
                 (signal 'herdr-connection-error '(:reason no-server))))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (agent-fleet--schedule-auto-connect)
      (should (= 0.25 scheduled-delay))
      (should (eq #'agent-fleet--auto-connect-now scheduled-function))
      ;; A missing server is reported, but the timer callback does not signal.
      (should-not (funcall scheduled-function)))
    (should-not agent-fleet--auto-connect-timer)
    (should (string-match-p "pre-connection failed" (car messages)))))

(ert-deftest agent-fleet-after-init-policy-installs-deferred-hook ()
  "Loading before Emacs initialization defers scheduling to after-init-hook."
  (let ((agent-fleet-auto-connect 'after-init)
        (agent-fleet--auto-connect-timer nil)
        (after-init-hook nil)
        (after-init-time nil))
    (agent-fleet--configure-auto-connect)
    (should (memq #'agent-fleet--schedule-auto-connect after-init-hook))))

(ert-deftest agent-fleet-core-does-not-load-features ()
  "Requiring `agent-fleet' loads only the core control plane.
Feature modules (dashboard, attach, editor, magit, worktree, parallel) and
Emacs's server library are NOT loaded by a bare `require', while public entry
points and the prefix map remain available through generated autoloads.  This
is verified in a fresh Emacs subprocess so the already-loaded test environment
does not mask the result."
  (skip-unless (executable-find "emacs"))
  (let* ((dir (or (file-name-directory (locate-library "agent-fleet"))
                  default-directory))
         (script (make-temp-file "af-features-" nil ".el"
                    (concat "(require 'agent-fleet)\n"
                            "(princ \"START\")\n"
                            "(princ (format \"%S\"\n"
                            "  (list :features\n"
                            "    (mapcar #'symbol-name\n"
                            "      (seq-filter (lambda (f)\n"
                            "        (string-prefix-p \"agent-fleet\" (symbol-name f)))\n"
                            "      features))\n"
                            "    :server-loaded (featurep 'server)\n"
                            "    :dashboard-command (commandp 'agent-fleet)\n"
                            "    :attach-command (commandp 'agent-fleet-attach)\n"
                            "    :command-map (boundp 'agent-fleet-command-map))))\n"))))
    (unwind-protect
        (let* ((cmd (format "emacs --batch -L %s -l %s 2>&1"
                            (shell-quote-argument dir)
                            (shell-quote-argument script)))
               (output (shell-command-to-string cmd))
               (start (string-match "START" output))
               (result (when start
                         (condition-case nil
                             (read (substring output (+ start 5)))
                           (error nil))))
               (feats (plist-get result :features)))
          (should (locate-library "agent-fleet-autoloads"))
          (should (member "agent-fleet" feats))
          (should-not (member "agent-fleet-dashboard" feats))
          (should-not (member "agent-fleet-attach" feats))
          (should-not (member "agent-fleet-editor" feats))
          (should-not (member "agent-fleet-magit" feats))
          (should-not (plist-get result :server-loaded))
          (should (plist-get result :dashboard-command))
          (should (plist-get result :attach-command))
          (should (plist-get result :command-map)))
      (delete-file script))))

(ert-deftest agent-fleet-start-validates-required-fields-before-provisioning ()
  "Bad kind/args/timeout values fail before any resource-creating RPC."
  (let (called)
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'herdr-request)
               (lambda (&rest _) (setq called t))))
      (should-error (agent-fleet-start nil) :type 'agent-fleet-error)
      (should-error (agent-fleet-start 'codex :args "--bad")
                    :type 'agent-fleet-error)
      (should-error (agent-fleet-start 'codex :timeout-ms 3000)
                    :type 'agent-fleet-error))
    (should-not called)))

(ert-deftest agent-fleet-read-agent-name-errors-when-cache-empty ()
  "Interactive target readers report an empty fleet before minibuffer input."
  (let ((herdr-model--cache (herdr-model--empty-session)))
    (should-error (agent-fleet-read-agent-name "Agent") :type 'user-error)))

(ert-deftest agent-fleet-list-when-disconnected-is-nil-safe ()
  "list and the cache read accessors return nil (not a type error) with no session.
A nil `herdr-session' must yield an empty result, not a
`wrong-type-argument' crash on the `herdr-session' struct."
  (let ((herdr--conn nil)
        (agent-fleet-auto-connect nil))
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

(ert-deftest agent-fleet-doctor-unwraps-manifest-envelope ()
  "server.agent_manifests typed envelopes render their manifest agents."
  (let ((agent-fleet-agent-executables nil))
    (cl-letf (((symbol-function 'herdr-request)
               (lambda (&rest _)
                 '(:type "agent_manifests"
                   :manifests ((:agent "claude") (:agent "codex"))))))
      (let ((check (assoc "Agent manifests (Herdr)"
                          (agent-fleet--doctor-agent-checks))))
        (should (nth 1 check))
        (should (equal "claude, codex" (nth 2 check)))))))

;;; --- Shared presentation descriptor --------------------------------

(defun agent-fleet-test--presentation-session (agent)
  "Install AGENT in a fresh cache session for presentation tests.
Returns the session.  The caller MUST clear the cache when done
\(typically in an `unwind-protect' via `herdr-model-clear-cache')."
  (let ((session (herdr-model--empty-session)))
    (puthash (herdr-agent-id agent) agent (herdr-session-agents session))
    (herdr-model-set-cache session)
    session))

(ert-deftest agent-fleet-presentation-fields ()
  "The presentation's slots are the shared formatters' output (single source)."
  (let ((agent (make-herdr-agent :id "w1:p1" :name "arch"
                                  :agent "claude" :agent-status "blocked"
                                  :cwd "/repo")))
    (agent-fleet-test--presentation-session agent)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-project-label)
                   (lambda (_) "myproj")))
          (let ((p (agent-fleet--presentation-for-agent agent))
                (name (herdr-agent-display-name agent)))
            (should (equal "w1:p1" (agent-fleet-agent-presentation-pane-id p)))
            (should (equal name (agent-fleet-agent-presentation-name p)))
            (should (equal "myproj" (agent-fleet-agent-presentation-project p)))
            (should (equal "Claude" (agent-fleet-agent-presentation-kind p)))
            (should (eq 'blocked (agent-fleet-agent-presentation-status p)))
            (should (equal "—" (agent-fleet-agent-presentation-task p)))))
      (herdr-model-clear-cache))))

(ert-deftest agent-fleet-list-entry-uses-project-column ()
  "The quick list's 5th cell is Project (not Workspace); 2nd is the upcase status."
  (let ((agent (make-herdr-agent :id "w1:p1" :name "arch"
                                  :agent "claude" :agent-status "blocked"
                                  :cwd "/repo")))
    (agent-fleet-test--presentation-session agent)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-project-label)
                   (lambda (_) "myproj")))
          (let ((row (agent-fleet--list-entry agent)))
            (should (equal "w1:p1" (car row)))
            ;; [Name Status Kind Task Project]
            (should (equal "arch"  (aref (cadr row) 0)))
            (should (equal "BLOCKED" (aref (cadr row) 1)))
            (should (equal "Claude" (aref (cadr row) 2)))
            (should (equal "—"     (aref (cadr row) 3)))
            (should (equal "myproj" (aref (cadr row) 4)))))
      (herdr-model-clear-cache))))

(ert-deftest agent-fleet-agent-candidates-carry-project ()
  "Completion candidates carry :project (not :workspace); the suffix shows it."
  (let ((agent (make-herdr-agent :id "w1:p1" :name "arch"
                                  :agent "claude" :agent-status "blocked"
                                  :cwd "/repo")))
    (agent-fleet-test--presentation-session agent)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-project-label)
                   (lambda (_) "myproj")))
          (let* ((entries (agent-fleet-agent-candidates))
                 (entry (car entries))
                 (suffix (agent-fleet-agent-candidate-suffix entry)))
            (should entry)
            (should (equal "w1:p1" (plist-get entry :pane-id)))
            (should (equal "myproj" (plist-get entry :project)))
            (should-not (plist-member entry :workspace))
            (should (string-match-p "myproj" suffix))
            (should (string-match-p "Claude" suffix))))
      (herdr-model-clear-cache))))


;;; --- Completion API + action registry ------------------------------

(ert-deftest agent-fleet-agent-annotation-returns-suffix ()
  "The public annotation fn reads the populated var; empty when unset/unknown."
  (let ((agent (make-herdr-agent :id "w1:p1" :name "arch" :agent "claude"
                                  :agent-status "blocked" :cwd "/repo")))
    (agent-fleet-test--presentation-session agent)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-project-label) (lambda (_) "myproj")))
          ;; No annotations bound -> empty (no crash), and nil candidate safe.
          (should (equal "" (let (agent-fleet-completion-annotations)
                              (agent-fleet-agent-annotation "arch"))))
          (should (equal "" (agent-fleet-agent-annotation nil)))
          ;; Populated from candidates -> the kind/task/project suffix.
          (let ((agent-fleet-completion-annotations
                 (agent-fleet-completion-annotation-table
                  (agent-fleet-agent-candidates))))
            (should (equal "Claude · — · myproj"
                           (agent-fleet-agent-annotation "arch")))
            (should (equal "" (agent-fleet-agent-annotation "no-such-agent")))))
      (herdr-model-clear-cache))))

(ert-deftest agent-fleet-read-agent-name-uses-category ()
  "The reader uses a completion table declaring the agent-fleet-agent category
and annotation, with clean-label candidates (no inlined suffix)."
  (let ((agent (make-herdr-agent :id "w1:p1" :name "arch" :agent "claude"
                                  :agent-status "blocked" :cwd "/repo")))
    (agent-fleet-test--presentation-session agent)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-fleet-project-label) (lambda (_) "myproj"))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt coll &rest _)
                     (should (eq coll #'agent-fleet--agent-collection))
                     (let ((md (funcall coll "" nil 'metadata)))
                       (should (eq (car md) 'metadata))
                       (should (equal (assq 'category (cdr md))
                                      '(category . agent-fleet-agent)))
                       (should (eq (cdr (assq 'annotation-function (cdr md)))
                                   #'agent-fleet-agent-annotation)))
                     ;; Clean-label candidate; suffix is an annotation, not inlined.
                     (should (equal "w1:p1"
                                    (cdr (assoc "arch"
                                                agent-fleet--completion-candidates))))
                     (should (equal "Claude · — · myproj"
                                    (gethash "arch"
                                             agent-fleet-completion-annotations "")))
                     "arch")))
          (should (equal "w1:p1" (agent-fleet-read-agent-name "Pick"))))
      (herdr-model-clear-cache))))

(ert-deftest agent-fleet-action-registry-accessors ()
  "Registry accessors return the canonical labels and per-surface bindings."
  (should (equal "Inspect output" (agent-fleet-action-label 'inspect)))
  (should (equal "Magit status" (agent-fleet-action-label 'magit)))
  (should (equal "Working-tree diff" (agent-fleet-action-label 'diff)))
  (should-not (agent-fleet-action-label 'no-such))
  ;; Dashboard: one (key . cmd) per shared action.
  (should (member '("o" . agent-fleet-dashboard--inspect)
                  (agent-fleet-action-dashboard-bindings)))
  (should (member '("m" . agent-fleet-dashboard--magit)
                  (agent-fleet-action-dashboard-bindings)))
  ;; Attach: flat list incl both child-frame/buffer variants.
  (should (member '("o" . agent-fleet-attach-inspect-in-child-frame)
                  (agent-fleet-action-attach-bindings)))
  (should (member '("O" . agent-fleet-attach-inspect-in-buffer)
                  (agent-fleet-action-attach-bindings))))


(provide 'agent-fleet-test)
;;; agent-fleet-test.el ends here
