;;; herdr-mock-server.el --- Tiny fake Herdr socket server for tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; A minimal Herdr socket server for ERT tests, so they run without a
;; real Herdr install.  It speaks the real wire protocol:
;;   - one-shot request connections: respond, then close;
;;   - subscription connections: ack, then push events (long-lived).
;; It is NOT a faithful Herdr — only enough surface to exercise the
;; client's framing, request/response, subscription, event dispatch,
;; and reconnection paths.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(cl-defstruct herdr-mock--server
  "A fake Herdr server."
  path process
  handlers                          ; alist method -> (lambda (params) result-or-error)
  snapshot                          ; plist snapshot to return for session.snapshot
  pending-events                    ; list of (KIND . DATA-plist) to push after subscribe
  subscription-client              ; the long-lived client proc, or nil
  received-requests                 ; list of (id method params) received
  agents                            ; hash pane_id -> info plist (agent state)
  panes                             ; hash pane_id -> pane-info plist (provisioned panes)
  worktrees                         ; hash workspace_id -> worktree plist (worktree state)
  (pane-counter 0)                  ; monotonic mock pane id source
  (workspace-counter 0)             ; monotonic mock workspace id source
  (worktree-counter 0))             ; monotonic mock worktree id source

(defvar herdr-mock--seq 0
  "Counter for unique mock server process names.")

(defvar herdr-mock--current nil
  "The most recently started mock server (sequential-test convention).")

(defun herdr-mock-start (path &rest opts)
  "Start a mock Herdr server bound to the Unix socket at PATH.
OPTS keys:
  :handlers   alist method-string -> (lambda (params) result) [default nil]
  :snapshot   plist snapshot for session.snapshot [a canned default]
  :pending-events  list of (KIND . DATA) pushed after a subscribe
Returns a `herdr-mock--server'.  Use `herdr-mock-stop' to tear down."
  ;; Handlers mutate nested AgentInfo plists in place to model authoritative
  ;; server state.  Copy the fixture (including vectors) so one mock instance
  ;; cannot mutate a quoted default or a caller-owned snapshot and leak status
  ;; into the next test.
  (let* ((snapshot (copy-tree (or (plist-get opts :snapshot)
                                  (herdr-mock--default-snapshot))
                              t))
         (server (make-herdr-mock--server
                  :path path
                  :handlers (plist-get opts :handlers)
                  :snapshot snapshot
                  :pending-events (plist-get opts :pending-events)
                  :received-requests nil
                  :agents (make-hash-table :test 'equal)
                  :panes (make-hash-table :test 'equal)
                  :worktrees (make-hash-table :test 'equal)
                  :pane-counter 0
                  :workspace-counter 0)))
    ;; Seed the mutable agent list from the snapshot so `agent.list'
    ;; returns every agent — faithful to live Herdr, where agent.list
    ;; includes agents started outside this client (the snapshot agents),
    ;; not just those started via `agent.start'.
    (dolist (info (plist-get snapshot :agents))
      (when-let* ((pid (plist-get info :pane_id)))
        (puthash pid info (herdr-mock--server-agents server))))
    ;; Seed the pane table from the snapshot too, so `pane.list' (ground
    ;; truth for pane existence) reports every pane the snapshot claims —
    ;; and `pane.close' can actually remove one.  Without this, pane.list
    ;; would omit snapshot panes and the client's reconciliation would
    ;; wrongly drop them as stale.
    (dolist (pn (plist-get snapshot :panes))
      (when-let* ((pid (plist-get pn :pane_id)))
        (puthash pid pn (herdr-mock--server-panes server))))
    (let* ((sname (format "herdr-mock-%d" (cl-incf herdr-mock--seq)))
           (proc (make-network-process
                  :name sname
                  :server t
                  :family 'local
                  :service path
                  :noquery t)))
      (setf (herdr-mock--server-process server) proc)
      (process-put proc 'herdr-mock-server server)
      (process-put proc 'herdr-mock-server-name sname)
      (set-process-sentinel proc #'herdr-mock--server-sentinel))
    (setq herdr-mock--current server)
    server))

(defun herdr-mock-stop (server)
  "Stop a mock server and delete its socket.
Also closes every client connection the server accepted (the
long-lived subscription client and any one-shot/resubscribe clients
whose EOF sentinels have not yet run).  In batch Emacs those sentinels
never fire without an intervening `accept-process-output', so without
this the accepted client procs linger alive, accumulate across tests,
and eventually SIGPIPE the batch run."
  (let ((sname (when-let* ((proc (herdr-mock--server-process server)))
                 (process-get proc 'herdr-mock-server-name))))
    ;; Close the tracked subscription client first.
    (herdr-mock-close-subscription server)
    ;; Then sweep any other live client procs this server accepted
    ;; (named \"SNAME <N>\").  The listen proc deletion does not reap
    ;; them, and their peers may already be gone.
    (when sname
      (let ((prefix (concat sname " <")))
        (dolist (p (process-list))
          (when (and (process-live-p p)
                     (let ((nm (process-name p)))
                       (and (stringp nm) (string-prefix-p prefix nm))))
            (delete-process p)))))
    (when-let* ((proc (herdr-mock--server-process server)))
      (when (process-live-p proc)
        (delete-process proc)))
    (when-let* ((path (herdr-mock--server-path server)))
      (when (file-exists-p path)
        (delete-file path)))
    (when (eq herdr-mock--current server)
      (setq herdr-mock--current nil))))

(defun herdr-mock-push-event (server kind data)
  "Push one event (KIND, DATA plist) to the live subscription client."
  (when-let* ((client (herdr-mock--server-subscription-client server))
              ((process-live-p client)))
    (process-send-string
     client
     (concat (herdr-mock--encode-event kind data) "\n"))))

(defun herdr-mock-create-pane (server pane-info)
  "Register PANE-INFO (a PaneInfo plist) and push a `pane_created' event.
Tests that surface a screen-detected pane by pushing `pane_created' must
also keep it in the server's pane table: the client's connect-time
reconcile re-fetches `pane.list' before each per-pane resubscribe (the
EventHub ring-buffer replay churns resubscribes), and a pane present only
as an event would be dropped as stale on the next reconcile.  Real Herdr
has the pane in its table the moment it emits `pane_created'; this helper
mirrors that so the cache entry survives."
  (puthash (plist-get pane-info :pane_id)
           pane-info
           (herdr-mock--server-panes server))
  (herdr-mock-push-event server "pane_created" `(:pane ,pane-info)))

(defun herdr-mock-close-subscription (server)
  "Drop the subscription connection (simulates server-side loss)."
  (when-let* ((client (herdr-mock--server-subscription-client server)))
    (when (process-live-p client)
      (delete-process client))
    (setf (herdr-mock--server-subscription-client server) nil)))

(defun herdr-mock-received (server)
  "Return the list of received (ID METHOD PARAMS) requests, newest last.
Returns a fresh copy: the stored request log is left intact so repeated
calls (e.g. several `agent-fleet-test--last-request' lookups in one
test) do not mutate it.  `nreverse' would reverse the cons cells in
place and truncate the stored list to its head on every call."
  (reverse (herdr-mock--server-received-requests server)))

(defun herdr-mock-set-handlers (server handlers)
  "Replace the server's method handlers."
  (setf (herdr-mock--server-handlers server) handlers))

(defun herdr-mock-set-snapshot (server snapshot)
  "Replace the canned snapshot."
  (setf (herdr-mock--server-snapshot server) (copy-tree snapshot t)))

(defun herdr-mock-set-pending-events (server events)
  "Replace the pending events to push after the next subscribe.
EVENTS is a list of (KIND-STRING . DATA-PLIST)."
  (setf (herdr-mock--server-pending-events server) events))


;;; --- Agent state -------------------------------------------

(defun herdr-mock--fresh-pane-id (server &optional workspace-id)
  "Return a fresh mock pane id for SERVER in WORKSPACE-ID."
  (let ((n (1+ (herdr-mock--server-pane-counter server))))
    (setf (herdr-mock--server-pane-counter server) n)
    (format "%s:pmock%d" (or workspace-id "w1") n)))

(defun herdr-mock--agent-set (server pane-id info)
  "Store agent INFO (a plist) for PANE-ID on SERVER."
  (puthash pane-id info (herdr-mock--server-agents server)))

(defun herdr-mock--agent-get (server pane-id)
  "Return the agent info plist for PANE-ID on SERVER, or nil."
  (gethash pane-id (herdr-mock--server-agents server)))

(defun herdr-mock--agent-del (server pane-id)
  "Remove the agent for PANE-ID on SERVER."
  (remhash pane-id (herdr-mock--server-agents server)))

(defun herdr-mock--agent-list (server)
  "Return all agent info plists on SERVER as a list."
  (let (out)
    (maphash (lambda (_k v) (push v out))
             (herdr-mock--server-agents server))
    (nreverse out)))

(defun herdr-mock--agent-find (server target)
  "Find an agent on SERVER by TARGET (pane id or name).
Returns the info plist, or nil."
  (or (and (stringp target)
           (herdr-mock--agent-get server target))
      (cl-find target (herdr-mock--agent-list server)
               :test #'equal
               :key (lambda (info) (or (plist-get info :name) "")))))

(defun herdr-mock--agent-transition (server pane-id status)
  "Move the agent at PANE-ID on SERVER to STATUS, bumping revision/seq.
Returns the updated info plist, or nil if no such agent."
  (let ((info (herdr-mock--agent-get server pane-id)))
    (when info
      (let ((rev (1+ (or (plist-get info :revision) 0))))
        (setq info (plist-put info :agent_status status))
        (setq info (plist-put info :revision rev))
        (setq info (plist-put info :state_change_seq rev))
        (herdr-mock--agent-set server pane-id info)
        info))))

(defun herdr-mock-agent-state (server pane-id)
  "Return the agent_status string for PANE-ID on SERVER, or nil."
  (let ((info (herdr-mock--agent-get server pane-id)))
    (and info (plist-get info :agent_status))))

(defun herdr-mock-set-agent-handlers (server)
  "Install the default agent/pane handlers on SERVER."
  (herdr-mock-set-handlers server (herdr-mock-default-agent-handlers)))


;;; --- Connection handling ------------------------------------------

(defun herdr-mock--server-sentinel (client event)
  "Server sentinel: on a new client, install its per-connection filter."
  (let ((server herdr-mock--current))
    (cond
     ((string-match-p "^open" event)
      (process-put client 'herdr-mock-pending "")
      (set-process-filter client #'herdr-mock--client-filter))
     ((string-match-p "^deleted\\|^connection" event)
      ;; client gone: clear it if it was the subscription stream
      (when (and server
                 (eq client (herdr-mock--server-subscription-client server)))
        (setf (herdr-mock--server-subscription-client server) nil))))))

(defun herdr-mock--server-for-client (_client)
  "Return the current mock server struct (sequential-test convention)."
  herdr-mock--current)

(defun herdr-mock--client-filter (client string)
  "Per-client filter: line-buffer and dispatch each complete frame."
  (let ((server (herdr-mock--server-for-client client)))
    (process-put client 'herdr-mock-pending
                 (concat (process-get client 'herdr-mock-pending) string))
    (while (string-search "\n" (process-get client 'herdr-mock-pending))
      (let* ((pending (process-get client 'herdr-mock-pending))
             (nl (string-search "\n" pending))
             (line (substring pending 0 nl)))
        (process-put client 'herdr-mock-pending (substring pending (1+ nl)))
        (when server
          (herdr-mock--handle-line server client line))))))

(defun herdr-mock--live-pane-ids (server)
  "Return a hash table of pane ids SERVER currently reports as live.
Every pane a real Herdr `pane_get' would confirm: the pane table (snapshot
panes seeded at start + panes provisioned by pane.split / worktree.create,
minus any closed by pane.close) plus registered agents' pane ids (an agent
is always on a live pane).  Used to reject per-pane subscriptions for
stale pane ids, mirroring real Herdr's `pane_get(...)?' batch rejection."
  (let ((live (make-hash-table :test 'equal)))
    (maphash (lambda (id _pn) (puthash id t live))
             (herdr-mock--server-panes server))
    (maphash (lambda (pid _info) (puthash pid t live))
             (herdr-mock--server-agents server))
    live))

(defun herdr-mock--find-stale-pane-sub (params server)
  "Return the first stale pane_id in a per-pane subscription in PARAMS, or nil.
Real Herdr's `events.subscribe' calls `pane_get(...)?' for each per-pane
subscription (pane.agent_status_changed / pane.output_matched /
pane.scroll_changed); a missing pane_id rejects the WHOLE batch.  This
scans PARAMS's `subscriptions' for a per-pane sub whose `pane_id' the
mock does not report as live (`herdr-mock--live-pane-ids'), returning
that id or nil."
  (let ((live (herdr-mock--live-pane-ids server))
        (stale nil))
    (dolist (sub (plist-get params :subscriptions))
      (let ((type (plist-get sub :type))
            (pid (plist-get sub :pane_id)))
        (when (and pid
                   (member type '("pane.agent_status_changed"
                                  "pane.output_matched"
                                  "pane.scroll_changed"))
                   (not (gethash pid live)))
          (setq stale pid))))
    stale))

(defun herdr-mock--handle-line (server client line)
  "Parse one request LINE and respond per the mock's rules."
  (let ((msg (herdr-mock--decode line)))
    (when msg
      (let ((id (plist-get msg :id))
            (method (plist-get msg :method))
            (params (plist-get msg :params)))
        (push (list id method params)
              (herdr-mock--server-received-requests server))
        (cond
         ((equal method "ping")
          (herdr-mock--respond client id `(:type "pong"
                                            :version "0.8.2-mock"
                                            :protocol 20
                                            :capabilities (:live_handoff t :detached_server_daemon t)))
          (delete-process client))
         ((equal method "session.snapshot")
          (herdr-mock--respond client id `(:snapshot ,(herdr-mock--server-snapshot server)))
          (delete-process client))
         ((equal method "events.subscribe")
          (let ((stale (herdr-mock--find-stale-pane-sub params server)))
            (if stale
                ;; Real Herdr calls pane_get(...)? for each per-pane
                ;; subscription (subscriptions.rs:260); one missing pane_id
                ;; rejects the WHOLE batch with pane_not_found.  Simulate
                ;; that so the client's pane.list reconciliation (which
                ;; drops stale ids before subscribing) is exercised, not
                ;; just the happy path.
                (progn
                  (herdr-mock--respond-error client id "pane_not_found"
                                             (format "pane not found: %s" stale))
                  (delete-process client))
              (herdr-mock--respond client id '(:type "subscription_started"))
              (setf (herdr-mock--server-subscription-client server) client)
              (dolist (ev (herdr-mock--server-pending-events server))
                (herdr-mock-push-event server (car ev) (cdr ev))))))
         (t
          (let ((handler (and (herdr-mock--server-handlers server)
                              (assoc method (herdr-mock--server-handlers server))))
                (close-after nil))
            (cond
             ((and handler (eq (cdr handler) 'herdr-mock--silent))
              ;; don't respond, don't close: client will time out
              )
             ((and handler (functionp (cdr handler)))
              (let ((result (condition-case err
                               (funcall (cdr handler) params)
                             (error (list 'error "mock_handler"
                                          (error-message-string err))))))
                (if (and (consp result) (eq (car result) 'error))
                    (herdr-mock--respond-error client id
                                               (nth 1 result) (nth 2 result))
                  (herdr-mock--respond client id result))
                (setq close-after t)))
             (t
              (herdr-mock--respond-error client id "not_found"
                                         (format "no mock handler for %s" method))
              (setq close-after t)))
            (when close-after
              (delete-process client)))))))))

(defun herdr-mock--send (client frame)
  "Send FRAME to CLIENT unless it is already gone.
A caller may have closed the connection before reading the response
\(e.g. the doctor's Events check unsubscribes before draining the ack);
writing to such a socket can error or wedge `accept-process-output', so
we skip dead clients and swallow send errors."
  (when (and (processp client) (process-live-p client))
    (condition-case nil
        (process-send-string client frame)
      (error nil))))

(defun herdr-mock--respond (client id result)
  "Send a success response frame to CLIENT and flush."
  (herdr-mock--send client
                    (concat (herdr-mock--encode-response id result) "\n")))

(defun herdr-mock--respond-error (client id code message)
  "Send an error response frame to CLIENT."
  (herdr-mock--send
   client
   (concat (herdr-mock--encode
            `(("id" . ,id) ("error" . (("code" . ,code) ("message" . ,message)))))
           "\n")))


;;; --- JSON encode/decode (mock side) ------------------------------

;; We build frames as alists (string keys) + vectors, matching the
;; convention verified against json.el; nil -> "{}".

(defun herdr-mock--encode (object)
  "Encode OBJECT as JSON (alists->objects, vectors->arrays, nil->\"{}\").
Boolean false is `:false' (bound to `json-false'); true is t."
  (let ((json-false :false))
    (cond
     ((null object) "{}")
     ((eq object :false) "false")
     ((stringp object) (json-encode-string object))
     ((numberp object) (number-to-string object))
     ((eq object t) "true")
     ((keywordp object) (json-encode-string (substring (symbol-name object) 1)))
     ((hash-table-p object) (json-encode object))
     ((vectorp object) (let ((json-array-type 'vector)) (json-encode object)))
     ((and (listp object) (proper-list-p object)
           (let ((fst (car-safe object)))
             (and (consp fst) (atom (car fst)))))
      (json-encode object))                       ; alist
     (t (json-encode object)))))

(defun herdr-mock--encode-response (id result)
  "Encode a success response frame {id,result}."
  (herdr-mock--encode
   `(("id" . ,id) ("result" . ,(herdr-mock--to-value result)))))

(defun herdr-mock--to-value (v)
  "Convert a Lisp value V (used in mock results) to a JSON-encodable form.
Plists become alists with string keys; a list of plists becomes a vector
(so it encodes as a JSON array, not a flattened object); vectors recurse
element-wise; :false passes through as a JSON boolean; nil becomes an
empty object."
  (cond
   ((null v) (make-hash-table :test 'equal))
   ((eq v :false) :false)                  ; JSON false (via json-false)
   ((keywordp v) (substring (symbol-name v) 1))
   ((vectorp v) (vconcat (mapcar #'herdr-mock--to-value (append v nil))))
   ((and (listp v) (proper-list-p v))
    (let ((fst (car-safe v)))
      (cond
       ((null fst) (make-hash-table :test 'equal))        ; empty list -> {}
       ((keywordp fst) (herdr-mock--plist-to-alist v))    ; plist -> alist
       ((and (consp fst) (keywordp (car fst)))            ; list of plists -> vector
        (vconcat (mapcar #'herdr-mock--to-value v)))
       (t v))))                                            ; alist / scalar list
   (t v)))

(defun herdr-mock--plist-to-alist (plist)
  "Convert PLIST (:k v) to alist ((\"k\" . v))."
  (let (out)
    (while plist
      (push (cons (substring (symbol-name (car plist)) 1)
                  (herdr-mock--to-value (cadr plist)))
            out)
      (setq plist (cddr plist)))
    (nreverse out)))

(defun herdr-mock--encode-event (kind data)
  "Encode a pushed event frame {event,data}."
  (let* ((kind-str (if (keywordp kind) (substring (symbol-name kind) 1) kind))
         (data-val (herdr-mock--to-value data)))
    (herdr-mock--encode
     `(("event" . ,kind-str) ("data" . ,data-val)))))

(defun herdr-mock--decode (string)
  "Decode a JSON line to a plist (tolerant)."
  (when (and string (not (string-empty-p string)))
    (let ((json-object-type 'plist) (json-array-type 'list)
          (json-false :false) (json-null nil))
      (condition-case nil
          (json-read-from-string string)
        (error nil)))))


;;; --- Canned snapshot ----------------------------------------------

(defun herdr-mock--default-snapshot ()
  "Return a canned, anonymized snapshot plist."
  '(:protocol 20 :version "0.8.2-mock"
    :focused_workspace_id "w1" :focused_tab_id "w1:t1"
    :focused_pane_id "w1:p1"
    :workspaces ((:workspace_id "w1" :label "demo" :number 1
                  :focused t :active_tab_id "w1:t1"
                  :tab_count 1 :pane_count 1 :agent_status "working"))
    :tabs ((:tab_id "w1:t1" :workspace_id "w1" :label "1"
            :number 1 :focused t :pane_count 1 :agent_status "working"))
    :panes ((:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
             :terminal_id "term_mock1" :terminal_title "demo"
             :terminal_title_stripped "demo"
             :cwd "/tmp/demo" :foreground_cwd "/tmp/demo"
             :focused t :revision 5 :agent "claude"
             :agent_status "working"
             :agent_session (:agent "claude" :kind "id"
                              :source "herdr:claude" :value "sess-1")))
    :agents ((:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
              :terminal_id "term_mock1" :terminal_title "demo"
              :terminal_title_stripped "demo"
              :cwd "/tmp/demo" :foreground_cwd "/tmp/demo"
              :focused t :revision 5 :state_change_seq 5
              :name "demo" :display_agent "claude" :title "demo"
              :interactive_ready t :launch_pending :false
              :agent "claude" :agent_status "working"
              :agent_session (:agent "claude" :kind "id"
                              :source "herdr:claude" :value "sess-1")))
    :layouts ()))


;;; --- Default agent/pane handlers ---------------------------
;;
;; Each handler is a function (PARAMS) -> result-plist | (error CODE MSG).
;; They read `herdr-mock--current' for the server, mutate the agent
;; registry, and push events on the subscription stream so the client's
;; event-driven cache updates fire during tests.

(defun herdr-mock--canned-output (lines)
  "Return LINES lines of canned agent output text."
  (mapconcat (lambda (i) (format "line %d: working..." i))
             (number-sequence 1 (max 1 lines)) "\n"))

(defun herdr-mock--agent-info-for (pane-id name kind)
  "Build a fresh agent info plist for PANE-ID, NAME, KIND.
Inherits the pane's cwd, workspace id, and tab id from the provisioned
pane (live Herdr's `agent.start' returns the pane's fields), defaulting
to \"/tmp\" / \"w1\" / \"w1:t1\" when the pane is unknown (e.g. an
externally-supplied pane id).  Inheriting the workspace id matters for
worktree starts: the agent's workspace must match the
worktree's `open_workspace_id' so `find-worktree-for-workspace' resolves."
  (let* ((server herdr-mock--current)
         (pane (and server (gethash pane-id (herdr-mock--server-panes server))))
         (cwd (or (and pane (plist-get pane :cwd)) "/tmp"))
         (ws-id (or (and pane (plist-get pane :workspace_id)) "w1"))
         (tab-id (or (and pane (plist-get pane :tab_id)) "w1:t1")))
    `(:pane_id ,pane-id :workspace_id ,ws-id :tab_id ,tab-id
      :terminal_id ,(format "term_%s" pane-id)
      :terminal_title ,name :terminal_title_stripped ,name
      :cwd ,cwd :foreground_cwd ,cwd
      :focused t :revision 0 :state_change_seq 0
      :name ,name :display_agent ,kind :title ,name
      :interactive_ready t :launch_pending :false
      :agent ,kind :agent_status "idle"
      :agent_session (:agent ,kind :kind "id"
                      :source "herdr:mock" :value ,(format "sess-%s" pane-id)))))

(defun herdr-mock--push-status (server pane-id status)
  "Transition the agent at PANE-ID to STATUS and push a status event.
Faithful to the per-pane `SubscriptionEventEnvelope': the `event' kind is
DOTTED (`pane.agent_status_changed', NOT the underscored global form) and
`agent' is the bare agent-kind STRING (Option<String>), not an AgentInfo
plist.  The client normalizes dotted->underscored before the model pcase,
so this is what exercises that normalization on the wire."
  (let ((info (herdr-mock--agent-transition server pane-id status)))
    (herdr-mock-push-event server "pane.agent_status_changed"
                           `(:pane_id ,pane-id
                             :workspace_id ,(plist-get info :workspace_id)
                             :agent_status ,status
                             :agent ,(plist-get info :agent)
                             :title ,(plist-get info :title)
                             :display_agent ,(plist-get info :display_agent)))))

(defun herdr-mock--h-agent-start (params)
  "Mock agent.start: register the agent, return the live envelope.
Returns `(:type \"agent_started\" :agent <AgentInfo> :argv <argv>)'.
Does NOT push `pane_agent_detected' inline: live Herdr emits that
asynchronously from its screen-scrape loop (src/app/api.rs
`emit_pane_state_update'), after the RPC returns — not during it.
Pushing it here would race the RPC result (the client's
`accept-process-output' drain processes the subscription before the
result is cached, firing the started hook from a minimal agent).  The
client fires `agent-fleet-agent-started-hook' from the authoritative
result instead; tests that exercise the detection path push the event
explicitly."
  (let* ((server herdr-mock--current)
         (name (or (plist-get params :name) "agent"))
         (kind (or (plist-get params :kind) "claude"))
         (pane-id (plist-get params :pane_id)))
    (if (null pane-id)
        (list 'error "invalid_params" "agent.start needs a pane_id")
      (let ((info (herdr-mock--agent-info-for pane-id name kind)))
        (herdr-mock--agent-set server pane-id info)
        `(:type "agent_started" :agent ,info :argv ,(or (plist-get params :args) []))))))

(defun herdr-mock--h-agent-prompt (params)
  "Mock agent.prompt: idle->working->done, honoring the `wait' field.
Returns the live envelope `(:type \"agent_prompted\" :agent <AgentInfo>)';
the AgentInfo's `:agent_status' is the outcome (done for a wait, working
for a fire-and-forget prompt before the done event lands)."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (info (herdr-mock--agent-find server target)))
    (if (null info)
        (list 'error "not_found" (format "no agent for target %S" target))
      (let ((pane-id (plist-get info :pane_id)))
        (herdr-mock--push-status server pane-id "working")
        (herdr-mock--push-status server pane-id "done")
        `(:type "agent_prompted"
          :agent ,(herdr-mock--agent-get server pane-id))))))

(defun herdr-mock--h-agent-read (params)
  "Mock agent.read: return a read snapshot for the target agent.
Returns the live envelope `(:type \"pane_read\" :read <PaneReadResult>)'."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (info (herdr-mock--agent-find server target)))
    (if (null info)
        (list 'error "not_found" (format "no agent for target %S" target))
      (let ((pane-id (plist-get info :pane_id))
            (lines (or (plist-get params :lines) 10)))
        `(:type "pane_read"
          :read (:pane_id ,pane-id :workspace_id "w1" :tab_id "w1:t1"
                 :source ,(plist-get params :source)
                 :format ,(plist-get params :format)
                 :text ,(herdr-mock--canned-output lines)
                 :revision ,(plist-get info :revision)
                 :truncated :false))))))

(defun herdr-mock--h-agent-wait (params)
  "Mock agent.wait: transition the agent into a state in UNTIL and return it.
Returns the live envelope `(:type \"agent_info\" :agent <AgentInfo>)'.
Prefers `done' if the `until' list allows it (the common wait target),
else the first requested status; pushes a status event so the client
cache stays in step."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (info (herdr-mock--agent-find server target))
         (until (or (plist-get params :until) '("done"))))
    (if (null info)
        (list 'error "not_found" (format "no agent for target %S" target))
      (let ((pane-id (plist-get info :pane_id))
            (status (if (member "done" until) "done" (car until))))
        (unless (equal (herdr-mock-agent-state server pane-id) status)
          (herdr-mock--push-status server pane-id status))
        `(:type "agent_info"
          :agent ,(herdr-mock--agent-get server pane-id))))))

(defun herdr-mock--h-agent-send-keys (params)
  "Mock agent.send_keys: acknowledge key input (ctrl+c idles a worker)."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (info (herdr-mock--agent-find server target)))
    (if (null info)
        (list 'error "not_found" (format "no agent for target %S" target))
      (let ((pane-id (plist-get info :pane_id))
            (keys (plist-get params :keys)))
        (when (and (member "ctrl+c" keys)
                   (equal (herdr-mock-agent-state server pane-id) "working"))
          (herdr-mock--push-status server pane-id "idle"))
        `(:type "agent_info"
          :agent ,(herdr-mock--agent-get server pane-id))))))

(defun herdr-mock--h-agent-rename (params)
  "Mock agent.rename: update the stored name and return the info.
Returns the live envelope `(:type \"agent_info\" :agent <AgentInfo>)'."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (name (plist-get params :name))
         (info (herdr-mock--agent-find server target)))
    (if (null info)
        (list 'error "not_found" (format "no agent for target %S" target))
      (let* ((pane-id (plist-get info :pane_id))
             (new (plist-put (copy-tree info t) :name name)))
        (setq new (plist-put new :title name))
        (setq new (plist-put new :terminal_title name))
        (setq new (plist-put new :terminal_title_stripped name))
        (herdr-mock--agent-set server pane-id new)
        `(:type "agent_info" :agent ,new)))))

(defun herdr-mock--h-agent-list (_params)
  "Mock agent.list: return all registered agents.
Returns the live envelope `(:type \"agent_list\" :agents [...])'."
  `(:type "agent_list" :agents ,(herdr-mock--agent-list herdr-mock--current)))

(defun herdr-mock--h-agent-get (params)
  "Mock agent.get: return the info for the target agent.
Returns the live envelope `(:type \"agent_info\" :agent <AgentInfo>)'."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (info (herdr-mock--agent-find server target)))
    (if info
        `(:type "agent_info" :agent ,info)
      (list 'error "not_found" (format "no agent for target %S" target)))))

(defun herdr-mock--h-agent-focus (params)
  "Mock agent.focus: acknowledge focusing the target agent.
Returns the live envelope `(:type \"agent_info\" :agent <AgentInfo>)'."
  (let* ((server herdr-mock--current)
         (target (plist-get params :target))
         (info (herdr-mock--agent-find server target)))
    (if (null info)
        (list 'error "not_found" (format "no agent for target %S" target))
      `(:type "agent_info" :agent ,info))))

(defun herdr-mock--h-pane-split (params)
  "Mock pane.split: allocate a fresh pane id and return a pane info.
Honors the optional `cwd' parameter, defaulting
to \"/tmp\" when absent.  Pushes a `pane_created' event (as a real Herdr
would) so the client's cache gains the pane and its per-pane status
subscription is rebuilt.  Records the pane so `agent.start' can inherit
its cwd (faithful to live Herdr, where an agent's cwd is the pane's cwd)."
  (let* ((server herdr-mock--current)
         (ws-id (or (plist-get params :workspace_id) "w1"))
         (pane-id (herdr-mock--fresh-pane-id server ws-id))
         (cwd (or (plist-get params :cwd) "/tmp"))
         (info `(:pane_id ,pane-id :workspace_id ,ws-id
                  :tab_id ,(format "%s:t1" ws-id)
                  :terminal_id ,(format "term_%s" pane-id)
                  :terminal_title "shell" :terminal_title_stripped "shell"
                  :cwd ,cwd :foreground_cwd ,cwd
                  :focused t :revision 0)))
    (puthash pane-id info (herdr-mock--server-panes server))
    (herdr-mock-push-event server "pane_created" `(:pane ,info))
    `(:type "pane_info" :pane ,info)))

(defun herdr-mock--h-pane-close (params)
  "Mock pane.close: drop the pane + agent and push a pane_closed event.
Removing the pane from the pane table (not just the agent) keeps
`pane.list' faithful: a closed pane is no longer ground-truth live, so
the client's `herdr--reconcile-panes' can drop a stale cache entry for
it rather than being told it still exists."
  (let* ((server herdr-mock--current)
         (pane-id (plist-get params :pane_id)))
    (remhash pane-id (herdr-mock--server-panes server))
    (herdr-mock--agent-del server pane-id)
    (herdr-mock-push-event server "pane_closed" `(:pane_id ,pane-id))
    `(:ok t)))

(defun herdr-mock--h-pane-current (_params)
  "Mock pane.current: return the focused pane (first registered agent)."
  (let ((agents (herdr-mock--agent-list herdr-mock--current)))
    (if agents
        (car agents)
      `(:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"))))

(defun herdr-mock--h-workspace-create (params)
  "Mock workspace.create with workspace/tab/root-pane typed payload."
  (let* ((server herdr-mock--current)
         (cwd (or (plist-get params :cwd) "/tmp"))
         (n (1+ (herdr-mock--server-workspace-counter server)))
         (ws-id (format "wmock%d" n))
         (tab-id (format "%s:t1" ws-id))
         (pane-id (herdr-mock--fresh-pane-id server ws-id))
         (workspace `(:workspace_id ,ws-id :label "mock" :number 2
                       :focused ,(plist-get params :focus)
                       :active_tab_id ,tab-id :tab_count 1 :pane_count 1
                       :agent_status "idle"))
         (tab `(:tab_id ,tab-id :workspace_id ,ws-id :label "1" :number 1
                :focused t :pane_count 1 :agent_status "idle"))
         (pane `(:pane_id ,pane-id :workspace_id ,ws-id :tab_id ,tab-id
                 :terminal_id ,(format "term_%s" pane-id)
                 :cwd ,cwd :foreground_cwd ,cwd :focused t :revision 0
                 :agent_status "idle")))
    (setf (herdr-mock--server-workspace-counter server) n)
    (puthash pane-id pane (herdr-mock--server-panes server))
    `(:type "workspace_created" :workspace ,workspace
      :tab ,tab :root_pane ,pane)))

(defun herdr-mock--h-workspace-close (params)
  "Mock workspace.close: remove its panes/agents and push the close event."
  (let* ((server herdr-mock--current)
         (ws-id (plist-get params :workspace_id))
         pane-ids)
    (maphash (lambda (pane-id pane)
               (when (equal ws-id (plist-get pane :workspace_id))
                 (push pane-id pane-ids)))
             (herdr-mock--server-panes server))
    (dolist (pane-id pane-ids)
      (remhash pane-id (herdr-mock--server-panes server))
      (herdr-mock--agent-del server pane-id))
    (herdr-mock-push-event server "workspace_closed"
                           `(:workspace_id ,ws-id :workspace nil))
    `(:type "workspace_closed" :workspace_id ,ws-id :workspace nil)))

(defun herdr-mock--h-tab-create (params)
  "Mock tab.create with the live `tab_created' response envelope."
  (let* ((server herdr-mock--current)
         (ws-id (or (plist-get params :workspace_id) "w1"))
         (pane-id (herdr-mock--fresh-pane-id server ws-id))
         (tab-id (format "%s:tmock" ws-id))
         (pane `(:pane_id ,pane-id :workspace_id ,ws-id :tab_id ,tab-id
                 :terminal_id ,(format "term_%s" pane-id)
                 :cwd ,(or (plist-get params :cwd) "/tmp")
                 :agent_status "idle")))
    (puthash pane-id pane (herdr-mock--server-panes server))
    `(:type "tab_created"
      :tab (:tab_id ,tab-id :workspace_id ,ws-id :label "mock"
            :pane_count 1 :agent_status "idle")
      :root_pane ,pane)))

;;; --- Worktree handlers -------------------------------------
;;
;; `worktree.create' provisions a workspace + tab + root pane (a shell at
;; the worktree cwd) + the worktree itself, all in one step — so the
;; client's `agent.start' targets `root_pane.pane_id' directly.  The mock
;; tracks created worktrees so `worktree.list'/`remove' stay consistent,
;; and pushes `worktree_created'/`opened'/`removed' events so the client's
;; event-driven cache updates fire during tests.

(defun herdr-mock--worktree-envelope (params already-open)
  "Build a worktree create/open envelope from PARAMS.
ALREADY-OPEN non-nil selects `worktree.open' semantics (the result type
is `worktree_opened' and carries `:already_open').  Provisions a fresh
workspace, tab, root pane, and worktree; records the root pane (so
`agent.start' inherits its cwd/workspace) and the worktree (so
`worktree.list'/`remove' stay consistent); and pushes the matching event."
  (let* ((server herdr-mock--current)
         (cwd (or (plist-get params :cwd) "/tmp"))
         (branch (or (plist-get params :branch) "mock-branch"))
         (n (1+ (herdr-mock--server-worktree-counter server)))
         (ws-id (format "wt%d" n))
         (tab-id (format "%s:t1" ws-id))
         (pane-id (format "%s:p1" ws-id))
         (wt-path (format "%s-wt-%d" (directory-file-name cwd) n))
         (root-pane `(:pane_id ,pane-id :workspace_id ,ws-id :tab_id ,tab-id
                       :terminal_id ,(format "term_%s" pane-id)
                       :terminal_title "shell" :terminal_title_stripped "shell"
                       :cwd ,wt-path :foreground_cwd ,wt-path
                       :focused t :revision 0))
         (workspace `(:workspace_id ,ws-id
                       :label ,(file-name-nondirectory wt-path)
                       :number ,(+ n 1) :focused t :active_tab_id ,tab-id
                       :tab_count 1 :pane_count 1 :agent_status "idle"))
         (tab `(:tab_id ,tab-id :workspace_id ,ws-id :label "1"
                 :number 1 :focused t :pane_count 1 :agent_status "idle"))
         (worktree `(:path ,wt-path :branch ,branch :is_bare :false
                     :is_detached :false :is_prunable :false
                     :is_linked_worktree t :label nil
                     :open_workspace_id ,ws-id))
         (kind (if already-open "worktree_opened" "worktree_created")))
    (setf (herdr-mock--server-worktree-counter server) n)
    (puthash pane-id root-pane (herdr-mock--server-panes server))
    (puthash ws-id worktree (herdr-mock--server-worktrees server))
    (herdr-mock-push-event server kind
                           `(:workspace ,workspace :worktree ,worktree))
    (if already-open
        `(:type "worktree_opened" :workspace ,workspace :tab ,tab
          :root_pane ,root-pane :worktree ,worktree :already_open :false)
      `(:type "worktree_created" :workspace ,workspace :tab ,tab
        :root_pane ,root-pane :worktree ,worktree))))

(defun herdr-mock--h-worktree-create (params)
  "Mock worktree.create: provision a workspace + root pane + worktree."
  (herdr-mock--worktree-envelope params nil))

(defun herdr-mock--h-worktree-open (params)
  "Mock worktree.open: like create, reporting `:already_open'."
  (herdr-mock--worktree-envelope params t))

(defun herdr-mock--h-worktree-list (_params)
  "Mock worktree.list: return all tracked worktrees + the repo source.
Returns the live envelope (:type \"worktree_list\" :source ... :worktrees
[WorktreeInfo...])."
  (let ((server herdr-mock--current)
        (wts nil))
    (maphash (lambda (_ws-id wt) (push wt wts))
             (herdr-mock--server-worktrees server))
    `(:type "worktree_list"
      :source (:repo_key "mock-repo" :repo_name "mock-repo"
               :repo_root "/tmp" :source_checkout_path "/tmp")
      :worktrees ,(nreverse wts))))

(defun herdr-mock--h-worktree-remove (params)
  "Mock worktree.remove: drop the tracked worktree, push a removed event."
  (let* ((server herdr-mock--current)
         (ws-id (plist-get params :workspace_id))
         (force (plist-get params :force))
         (wt (and ws-id (gethash ws-id (herdr-mock--server-worktrees server)))))
    (if (null wt)
        (list 'error "not_found" (format "no worktree for workspace %S" ws-id))
      (remhash ws-id (herdr-mock--server-worktrees server))
      (herdr-mock-push-event server "worktree_removed"
                             `(:workspace_id ,ws-id :worktree ,wt
                               :forced ,(if (eq force :false) :false t)))
      `(:type "worktree_removed" :path ,(plist-get wt :path)
        :workspace_id ,ws-id :forced ,(if (eq force :false) :false t)))))

(defun herdr-mock--h-pane-list (_params)
  "Mock pane.list: return every pane the server reports (ground truth).
The pane table holds snapshot panes (seeded at start) plus panes
provisioned by pane.split / worktree.create, minus any closed by
pane.close — exactly the set a real `pane.list' (`PaneList { panes:
Vec<PaneInfo> }') would return.  The client's `herdr--reconcile-panes'
reads this to drop cached pane ids the server no longer reports."
  (let ((server herdr-mock--current)
        (out nil))
    (maphash (lambda (_id pn) (push pn out))
             (herdr-mock--server-panes server))
    `(:type "pane_list" :panes ,(nreverse out))))

(defun herdr-mock-default-agent-handlers ()
  "Return an alist of mock handlers for the agent/pane RPCs.
Covers agent.start/prompt/read/wait/send_keys/rename/list/get/focus,
pane.split/close/current/send_input/send_keys, workspace.create,
tab.create, and the worktree.create/open/list/remove RPCs.
Install with `herdr-mock-set-agent-handlers'."
  `(("agent.start" . herdr-mock--h-agent-start)
    ("agent.prompt" . herdr-mock--h-agent-prompt)
    ("agent.read"   . herdr-mock--h-agent-read)
    ("agent.wait"   . herdr-mock--h-agent-wait)
    ("agent.send_keys" . herdr-mock--h-agent-send-keys)
    ("agent.rename" . herdr-mock--h-agent-rename)
    ("agent.list"   . herdr-mock--h-agent-list)
    ("agent.get"    . herdr-mock--h-agent-get)
    ("agent.focus"  . herdr-mock--h-agent-focus)
    ("pane.split"   . herdr-mock--h-pane-split)
    ("pane.close"   . herdr-mock--h-pane-close)
    ("pane.current" . herdr-mock--h-pane-current)
    ("pane.list"    . herdr-mock--h-pane-list)
    ("pane.send_input" . ,(lambda (_params) `(:ok t)))
    ("pane.send_keys"  . ,(lambda (_params) `(:ok t)))
    ("workspace.create" . herdr-mock--h-workspace-create)
    ("workspace.close"  . herdr-mock--h-workspace-close)
    ("tab.create"       . herdr-mock--h-tab-create)
    ("worktree.create"  . herdr-mock--h-worktree-create)
    ("worktree.open"    . herdr-mock--h-worktree-open)
    ("worktree.list"    . herdr-mock--h-worktree-list)
    ("worktree.remove"  . herdr-mock--h-worktree-remove)))

(provide 'herdr-mock-server)
;;; herdr-mock-server.el ends here
