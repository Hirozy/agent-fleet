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
  received-requests)               ; list of (id method params) received

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
  (let ((server (make-herdr-mock--server
                 :path path
                 :handlers (plist-get opts :handlers)
                 :snapshot (or (plist-get opts :snapshot)
                              (herdr-mock--default-snapshot))
                 :pending-events (plist-get opts :pending-events)
                 :received-requests nil)))
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
  "Stop a mock server and delete its socket."
  (when-let* ((proc (herdr-mock--server-process server)))
    (when (process-live-p proc)
      (delete-process proc)))
  (when-let* ((path (herdr-mock--server-path server)))
    (when (file-exists-p path)
      (delete-file path)))
  (when (eq herdr-mock--current server)
    (setq herdr-mock--current nil)))

(defun herdr-mock-push-event (server kind data)
  "Push one event (KIND, DATA plist) to the live subscription client."
  (when-let* ((client (herdr-mock--server-subscription-client server))
              ((process-live-p client)))
    (process-send-string
     client
     (concat (herdr-mock--encode-event kind data) "\n"))))

(defun herdr-mock-close-subscription (server)
  "Drop the subscription connection (simulates server-side loss)."
  (when-let* ((client (herdr-mock--server-subscription-client server)))
    (when (process-live-p client)
      (delete-process client))
    (setf (herdr-mock--server-subscription-client server) nil)))

(defun herdr-mock-received (server)
  "Return the list of received (ID METHOD PARAMS) requests, newest last."
  (nreverse (herdr-mock--server-received-requests server)))

(defun herdr-mock-set-handlers (server handlers)
  "Replace the server's method handlers."
  (setf (herdr-mock--server-handlers server) handlers))

(defun herdr-mock-set-snapshot (server snapshot)
  "Replace the canned snapshot."
  (setf (herdr-mock--server-snapshot server) snapshot))

(defun herdr-mock-set-pending-events (server events)
  "Replace the pending events to push after the next subscribe.
EVENTS is a list of (KIND-STRING . DATA-PLIST)."
  (setf (herdr-mock--server-pending-events server) events))


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
                                            :version "0.8.0-mock"
                                            :protocol 19
                                            :capabilities (:live_handoff t :detached_server_daemon t)))
          (delete-process client))
         ((equal method "session.snapshot")
          (herdr-mock--respond client id `(:snapshot ,(herdr-mock--server-snapshot server)))
          (delete-process client))
         ((equal method "events.subscribe")
          (herdr-mock--respond client id '(:type "subscription_started"))
          (setf (herdr-mock--server-subscription-client server) client)
          (dolist (ev (herdr-mock--server-pending-events server))
            (herdr-mock-push-event server (car ev) (cdr ev))))
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

(defun herdr-mock--respond (client id result)
  "Send a success response frame to CLIENT and flush."
  (process-send-string client (concat (herdr-mock--encode-response id result) "\n")))

(defun herdr-mock--respond-error (client id code message)
  "Send an error response frame to CLIENT."
  (process-send-string
   client
   (concat (herdr-mock--encode
            `(("id" . ,id) ("error" . (("code" . ,code) ("message" . ,message)))))
           "\n")))


;;; --- JSON encode/decode (mock side) ------------------------------

;; We build frames as alists (string keys) + vectors, matching the
;; convention verified against json.el; nil -> "{}".

(defun herdr-mock--encode (object)
  "Encode OBJECT as JSON (alists->objects, vectors->arrays, nil->\"{}\")."
  (cond
   ((null object) "{}")
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
   (t (json-encode object))))

(defun herdr-mock--encode-response (id result)
  "Encode a success response frame {id,result}."
  (herdr-mock--encode
   `(("id" . ,id) ("result" . ,(herdr-mock--to-value result)))))

(defun herdr-mock--to-value (v)
  "Convert a Lisp value V (used in mock results) to a JSON-encodable form.
Keywords become strings; plists become alists; vectors stay vectors."
  (cond
   ((null v) (make-hash-table :test 'equal))
   ((keywordp v) (substring (symbol-name v) 1))
   ((and (listp v) (proper-list-p v)
         (let ((fst (car-safe v)))
           (or (and (consp fst) (atom (car fst)))    ; alist
               (keywordp fst))))                     ; plist
    (if (keywordp (car v))
        (herdr-mock--plist-to-alist v)
      v))
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
  '(:protocol 19 :version "0.8.0-mock"
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
              :agent "claude" :agent_status "working"
              :agent_session (:agent "claude" :kind "id"
                              :source "herdr:claude" :value "sess-1")))
    :layouts ()))

(provide 'herdr-mock-server)
;;; herdr-mock-server.el ends here
