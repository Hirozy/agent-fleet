;;; herdr-core.el --- Client for herdr-core -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "29.1"))
;; Version: 1.0.0
;;; Commentary:
;; JSON-RPC control and a separate snapshot/event stream over hc connect.
;; The cache contains Core facts only.  Requests never replay after failure.
;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup herdr-core nil "Herdr Core connection." :group 'processes)
(defcustom herdr-core-executable "hc" "Core CLI executable."
  :type 'file :group 'herdr-core)
(defcustom herdr-core-session "default" "Session for the next connection."
  :type 'string :group 'herdr-core)
(defcustom herdr-core-socket nil
  "Explicit socket for the next connection.
Otherwise use HC_SOCKET or the standard Core session socket.  Set this
option when using a custom socket in Core's config.toml."
  :type '(choice (const nil) file) :group 'herdr-core)
(defcustom herdr-core-auto-start t "Allow hc to start the selected Core."
  :type 'boolean :group 'herdr-core)
(defcustom herdr-core-request-timeout 30 "Default request timeout in seconds."
  :type 'number :group 'herdr-core)
(defcustom herdr-core-reconnect-delay 2 "Seconds before a reconnect attempt."
  :type 'number :group 'herdr-core)
(define-error 'herdr-core-error "Core error")
(define-error 'herdr-core-request-error "Core rejected request" 'herdr-core-error)
(define-error 'herdr-core-uncertain "Core request outcome unknown" 'herdr-core-error)

(defun herdr-core-error-message (err)
  "Return ERR's readable Core message, preserving the structured error itself."
  (let ((message (and (eq (car-safe err) 'herdr-core-request-error)
                      (plist-get (plist-get (cdr err) :error) :message))))
    (if (stringp message) message (error-message-string err))))
(defvar herdr-core-changed-hook nil "Hook after model or connection changes.")
(defvar herdr-core-event-hook nil "Hook called with each applied event.")
(defvar herdr-core--control nil)
(defvar herdr-core--events nil)
(defvar herdr-core--environment nil)
(defvar herdr-core--program nil)
(defvar herdr-core--hello nil)
(defvar herdr-core--state 'disconnected)
(defvar herdr-core--seq -1)
(defvar herdr-core--terminals (make-hash-table :test 'equal))
(defvar herdr-core--serial 0)
(defvar herdr-core--retry nil)
(defvar herdr-core--attempts 0)
(defvar herdr-core--closing nil)
(defvar herdr-core--desired nil)
(defconst herdr-core-minimum-version "0.1.17"
  "Oldest Core release covered by the protocol contract.")

(defun herdr-core--hooks (hook &rest args)
  "Run HOOK with ARGS, isolating consumer failures from protocol handling."
  (dolist (fn (symbol-value hook))
    (condition-case err (apply fn args)
      (error (message "Core consumer: %s" (error-message-string err))))))

(defun herdr-core--state (state)
  "Publish connection STATE."
  (setq herdr-core--state state)
  (herdr-core--hooks 'herdr-core-changed-hook))

(defun herdr-core-id () "Return the connected Core's persistent identity."
  (plist-get (plist-get herdr-core--hello :core) :id))
(defun herdr-core-terminal (address) "Return cached terminal at ADDRESS."
  (gethash address herdr-core--terminals))
(defun herdr-core-terminals () "Return all cached terminal records."
  (hash-table-values herdr-core--terminals))
(defun herdr-core-local-address-p (address)
  "Return non-nil for a local terminal ADDRESS, excluding routed addresses."
  (and (stringp address) (not (string-empty-p address))
       (not (string-match-p "/" address))))

(defun herdr-core-identity (terminal)
  "Pin local TERMINAL to its Core and creation identity."
  (let ((address (plist-get terminal :address)))
    (unless (herdr-core-local-address-p address)
      (user-error "Fleet supports local terminals only"))
    (list (herdr-core-id) address (plist-get terminal :created_ms))))

(defun herdr-core-identity-address (identity)
  "Resolve local IDENTITY, rejecting another Core or a routed identity."
  (unless (equal (car identity) (herdr-core-id))
    (user-error "Core identity changed; reopen this view"))
  (let ((address (nth 1 identity)))
    (unless (herdr-core-local-address-p address)
      (user-error "Fleet supports local terminals only"))
    address))
(defun herdr-core-environment () "Return a copy of the pinned CLI environment."
  (copy-sequence herdr-core--environment))

(defun herdr-core--endpoint ()
  "Resolve the socket for a new connection."
  (unless (string-match-p "\\`[a-zA-Z0-9_-]+\\'" herdr-core-session)
    (user-error "Invalid Core session name"))
  (or herdr-core-socket (getenv "HC_SOCKET")
      (let* ((runtime (or (getenv "XDG_RUNTIME_DIR")
                          (let ((path (format "/run/user/%s" (user-uid))))
                            (and (file-directory-p path) path))))
             (dir (if runtime (expand-file-name "herdr-core" runtime)
                    (expand-file-name
                     (concat "herdr-core/" herdr-core-session)
                     (or (getenv "XDG_STATE_HOME") "~/.local/state")))))
        (expand-file-name (concat herdr-core-session ".sock") dir))))

(defun herdr-core--pin ()
  "Capture configuration once for control, reconnect and attach."
  (let ((socket (expand-file-name (herdr-core--endpoint))))
    (unless (or herdr-core-auto-start (file-exists-p socket))
      (user-error "Core is not running; start hc or enable herdr-core-auto-start"))
    (setq herdr-core--program
          (or (executable-find herdr-core-executable)
              (user-error "Cannot find %s; customize herdr-core-executable"
                          herdr-core-executable)))
    (let ((process-environment (copy-sequence process-environment)))
      (setenv "HC_SOCKET" socket)
      (setenv "HC_SESSION" herdr-core-session)
      (setenv "HC_TERMINAL_ID" nil)
      (setq herdr-core--environment process-environment))))

(defun herdr-core--complete (process id result error)
  "Complete PROCESS request ID with RESULT or ERROR exactly once."
  (let* ((pending (process-get process 'pending))
         (entry (gethash id pending)))
    (when entry
      (remhash id pending)
      (when (timerp (cdr entry)) (cancel-timer (cdr entry)))
      (condition-case err (funcall (car entry) result error)
        (error (message "Core callback: %s" (error-message-string err)))))))

(defun herdr-core--timeout (process id method)
  "Report unknown outcome for PROCESS request ID using METHOD."
  (herdr-core--complete process id nil
                       (list 'herdr-core-uncertain :method method :reason 'timeout)))

(defun herdr-core--send (process method params callback timeout)
  "Send METHOD with PARAMS on PROCESS; invoke CALLBACK within TIMEOUT."
  (unless (process-live-p process)
    (signal 'herdr-core-error (list :reason 'disconnected)))
  (let ((id (cl-incf herdr-core--serial)))
    (puthash id (cons callback (run-at-time timeout nil
                                          #'herdr-core--timeout process id method))
             (process-get process 'pending))
    (condition-case err
        (process-send-string
         process (concat (json-serialize
                          `(:jsonrpc "2.0" :id ,id :method ,method
                            :params ,(or params (make-hash-table)))
                          :null-object nil :false-object :false) "\n"))
      (error (herdr-core--complete
              process id nil (list 'herdr-core-uncertain :method method :cause err))))
    id))

(defun herdr-core--call (process method params timeout)
  "Call METHOD on PROCESS with PARAMS and TIMEOUT while servicing events."
  (let (done value failure)
    (let ((id (herdr-core--send
               process method params
               (lambda (result err) (setq done t value result failure err)) timeout)))
      (unwind-protect
          (while (not done) (accept-process-output nil 0.05))
        (unless done
          (herdr-core--complete process id nil
                               (list 'herdr-core-uncertain :reason 'interrupted)))))
    (if failure (signal (car failure) (cdr failure)) value)))

(defun herdr-core--valid-terminal-p (record)
  "Return whether RECORD has a usable identity and lifecycle."
  (and (listp record) (stringp (plist-get record :address))
       (numberp (plist-get record :created_ms))
       (member (plist-get record :state) '("live" "finished"))))

(defun herdr-core--valid-send-result-p (result)
  "Return whether RESULT acknowledges a send with Core's required turn."
  (and (listp result) (integerp (plist-get result :turn))
       (>= (plist-get result :turn) 0)))

(defun herdr-core--snapshot (snapshot)
  "Atomically install authoritative SNAPSHOT."
  (unless (and (integerp (plist-get snapshot :seq))
               (plist-member snapshot :terminals))
    (error "Invalid Core snapshot"))
  (let ((table (make-hash-table :test 'equal)))
    (dolist (record (plist-get snapshot :terminals))
      (unless (herdr-core--valid-terminal-p record) (error "Invalid terminal"))
      (puthash (plist-get record :address) record table))
    (setq herdr-core--terminals table herdr-core--seq (plist-get snapshot :seq)))
  (herdr-core--hooks 'herdr-core-changed-hook))

(defun herdr-core--event (event)
  "Apply EVENT before notifying consumers."
  (let* ((seq (plist-get event :seq)) (type (plist-get event :type))
         (address (plist-get event :terminal)) (data (plist-get event :data))
         (old (gethash address herdr-core--terminals)))
    (unless (integerp seq) (error "Invalid event sequence"))
    (when (> seq herdr-core--seq)
      (pcase type
        ((or "created" "restarted")
         (unless (and (herdr-core--valid-terminal-p data)
                      (equal address (plist-get data :address)))
           (error "Invalid created terminal"))
         (puthash address data herdr-core--terminals))
        ("removed" (remhash address herdr-core--terminals))
        (_
         (when old
           (let ((record (copy-tree old)))
             (pcase type
               ("finished" (setq record (plist-put record :state "finished"))
                (setq record (plist-put record :status nil))
                (setq record (plist-put record :foreground nil)))
               ("lost" (setq record (plist-put record :pid nil))
                (setq record (plist-put record :foreground nil)))
               ("foreground" (setq record (plist-put record :foreground data))))
             ;; Event fields are not flattened terminal records: turn.state is
             ;; a work-state word, and foreground.cwd/name belong to a process.
             (dolist (key (pcase type
                            ((or "finished" "lost") '(:reason :exit_code :signal :finished_ms))
                            ("status" '(:status :records :reported))
                            ("turn" '(:turn))
                            ("title" '(:title))
                            ("labels" '(:labels))
                            ("size" '(:cols :rows))
                            ("keep" '(:keep))))
               (when (plist-member data key)
                 (setq record (plist-put record key (plist-get data key)))))
             (puthash address record herdr-core--terminals)))))
      (setq herdr-core--seq seq)
      (herdr-core--hooks 'herdr-core-event-hook event)
      (herdr-core--hooks 'herdr-core-changed-hook))))

(defun herdr-core--message (process message)
  "Dispatch decoded MESSAGE from PROCESS."
  (if (plist-member message :id)
      (herdr-core--complete
       process (plist-get message :id) (plist-get message :result)
       (when-let* ((err (plist-get message :error)))
         (list 'herdr-core-request-error :error err)))
    (when (eq process herdr-core--events)
      (pcase (plist-get message :method)
        ("event" (herdr-core--event (plist-get message :params)))
        ("missed" (herdr-core--snapshot (plist-get message :params)))))))

(defun herdr-core--filter (process chunk)
  "Decode newline-delimited CHUNK on PROCESS, retaining partial messages."
  (process-put process 'input (concat (process-get process 'input) chunk))
  (condition-case err
      (let ((input (process-get process 'input)) pos)
        (while (setq pos (string-match "\n" input))
          (let ((line (substring input 0 pos)))
            (setq input (substring input (1+ pos)))
            (process-put process 'input input)
            (unless (string-empty-p line)
              (herdr-core--message
               process (json-parse-string line :object-type 'plist :array-type 'list
                                          :null-object nil :false-object :false)))))
        (when (> (length input) (* 16 1024 1024)) (error "Oversized Core message")))
    (error
     (message "Core protocol: %s" (error-message-string err))
     (delete-process process))))

(defun herdr-core--sentinel (process _event)
  "Fail outstanding requests and schedule recovery when PROCESS closes."
  (unless (process-live-p process)
    (let ((pending (process-get process 'pending)))
      (when pending
        (dolist (id (hash-table-keys pending))
          (herdr-core--complete process id nil
                               '(herdr-core-uncertain :reason disconnected)))))
    (when (and (not herdr-core--closing)
               (memq process (list herdr-core--control herdr-core--events)))
      (herdr-core--close-processes)
      (herdr-core--state 'reconnecting)
      (herdr-core--schedule-reconnect))))

(defun herdr-core--spawn (name)
  "Spawn a pinned plain-mode hc connect process named NAME."
  (let* ((process-environment (herdr-core-environment))
         (process (make-process :name name :command (list herdr-core--program "connect")
                                :connection-type 'pipe :coding 'utf-8-unix :noquery t
                                :stderr (get-buffer-create " *herdr-core-errors*")
                                :filter #'herdr-core--filter
                                :sentinel #'herdr-core--sentinel)))
    (process-put process 'pending (make-hash-table :test 'equal))
    (process-put process 'input "")
    process))

(defun herdr-core--close-processes ()
  "Close both transports without recursively scheduling recovery."
  (let ((herdr-core--closing t))
    (dolist (process (list herdr-core--control herdr-core--events))
      (when (processp process) (delete-process process))))
  (setq herdr-core--control nil herdr-core--events nil))

(defun herdr-core--open ()
  "Open transports using the pinned endpoint and reconcile current state."
  (setq herdr-core--control (herdr-core--spawn "hc-control"))
  (let ((hello (herdr-core--call herdr-core--control "hello" '(:generation 1) 10)))
    (unless (and (eq (plist-get hello :generation) 1)
                 (stringp (plist-get hello :version))
                 (version<= herdr-core-minimum-version (plist-get hello :version))
                 (stringp (plist-get (plist-get hello :core) :id)))
      (error "Unsupported Core handshake"))
    (dolist (method '("terminal.run" "terminal.get" "terminal.list"
                      "terminal.send" "terminal.rm" "events.subscribe"))
      (unless (member method (plist-get hello :methods))
        (error "Core lacks required method %s" method)))
    (setq herdr-core--hello hello))
  (setq herdr-core--events (herdr-core--spawn "hc-events"))
  (let ((hello (herdr-core--call herdr-core--events "hello" '(:generation 1) 10)))
    (unless (equal (plist-get (plist-get hello :core) :id) (herdr-core-id))
      (error "Core changed while subscribing")))
  ;; Install the snapshot in the response callback, before the filter can
  ;; process notifications concatenated in the very same process chunk.
  (let (done failure)
    (herdr-core--send
     herdr-core--events "events.subscribe" nil
     (lambda (result err)
       (condition-case problem
           (if err (setq failure err) (herdr-core--snapshot result))
         (error (setq failure problem)))
       (setq done t)) 10)
    (while (not done) (accept-process-output nil 0.05))
    (when failure (signal (car failure) (cdr failure))))
  (unless (and (process-live-p herdr-core--control)
               (process-live-p herdr-core--events))
    (error "Core disconnected while synchronizing"))
  (setq herdr-core--attempts 0)
  (herdr-core--state 'connected))

(defun herdr-core--schedule-reconnect ()
  "Schedule one bounded reconnect to the pinned endpoint."
  (when (and herdr-core--desired (not herdr-core--retry)
             (< herdr-core--attempts 5))
    (setq herdr-core--retry
          (run-at-time (* herdr-core-reconnect-delay (1+ herdr-core--attempts))
                       nil #'herdr-core--reconnect))))

(defun herdr-core--reconnect ()
  "Reconnect without replaying pending operations."
  (setq herdr-core--retry nil)
  (cl-incf herdr-core--attempts)
  (condition-case err (herdr-core--open)
    (error
     (herdr-core--close-processes)
     (message "Core reconnect failed: %s" (error-message-string err))
     (herdr-core--state 'disconnected)
     (herdr-core--schedule-reconnect))))

;;;###autoload
(defun herdr-core-connect ()
  "Connect to Core and install its authoritative subscription snapshot."
  (interactive)
  (unless (eq herdr-core--state 'connected)
    (herdr-core-disconnect)
    (herdr-core--pin)
    (setq herdr-core--desired t herdr-core--attempts 0)
    (herdr-core--state 'connecting)
    (condition-case err (herdr-core--open)
      ((error quit)
       (herdr-core-disconnect)
       (signal (car err) (cdr err))))))

;;;###autoload
(defun herdr-core-disconnect ()
  "Detach Fleet's connections, preserving every Core program."
  (interactive)
  (setq herdr-core--desired nil)
  (when (timerp herdr-core--retry) (cancel-timer herdr-core--retry))
  (setq herdr-core--retry nil)
  (herdr-core--close-processes)
  (herdr-core--state 'disconnected))

(defun herdr-core-request (method &optional params timeout)
  "Request METHOD with PARAMS, returning a result or structured error.
TIMEOUT defaults to `herdr-core-request-timeout'.  Events remain serviced."
  (herdr-core-connect)
  (herdr-core--call herdr-core--control method params
                    (or timeout herdr-core-request-timeout)))

(defun herdr-core-request-async (method params callback &optional timeout)
  "Request METHOD with PARAMS; invoke CALLBACK with (RESULT ERROR).
No mutation is retried.  TIMEOUT is a local deadline, not cancellation."
  (herdr-core-connect)
  (herdr-core--send herdr-core--control method params callback
                    (or timeout herdr-core-request-timeout)))

(provide 'herdr-core)
;;; herdr-core.el ends here
