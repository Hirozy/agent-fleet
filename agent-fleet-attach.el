;;; agent-fleet-attach.el --- Core terminal attachment -*- lexical-binding: t; -*-
;;; Commentary:
;; Ghostel runs a pinned hc attach viewer.  Killing the viewer only detaches.
;;; Code:
(require 'agent-fleet)
(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(defvar ghostel-query-before-killing)
(defcustom agent-fleet-attach-inhibit-evil-escape t
  "Inhibit Evil escape sequences in agent terminals."
  :type 'boolean :group 'agent-fleet)
(defvar-local agent-fleet-observe-p nil "Non-nil for a read-only Core viewer.")
(defvar agent-fleet-observe--keymaps
  `((agent-fleet-observe-p
     . ,(let ((map (make-sparse-keymap)))
          (define-key map (kbd "q") #'agent-fleet-observe-quit)
          map)))
  "Observer-only commands taking precedence over terminal input maps.")

;;;###autoload
(defun agent-fleet-observe-quit ()
  "Close this observer and restore preceding views without ending the agent."
  (interactive)
  (unless (and (bound-and-true-p agent-fleet-attach-mode) agent-fleet-observe-p)
    (user-error "Not an Agent Fleet observer"))
  (let ((buffer (current-buffer))
        (ghostel-query-before-killing nil))
    (dolist (window (get-buffer-window-list buffer nil t))
      (agent-fleet-display-window-quit window))
    (kill-buffer buffer)))

(defun agent-fleet-attach--inhibit-return-anchor (window _force)
  "Preserve WINDOW's saved position during a Fleet review return."
  (agent-fleet-display-window-restoring-p window))

(defun agent-fleet-attach--ghostel-ready-p ()
  "Return whether Ghostel has its working native module and launch API."
  (and (require 'ghostel nil t) (featurep 'ghostel-module) (fboundp 'ghostel-exec)))

(defun agent-fleet-attach--live-buffer (reference &optional observe)
  "Find the live attach viewer for REFERENCE."
  (cl-find-if (lambda (buffer)
                (with-current-buffer buffer
                  (and (bound-and-true-p agent-fleet-attach-mode)
                       (equal agent-fleet-target reference)
                       (eq agent-fleet-observe-p observe)
                       (process-live-p (get-buffer-process buffer)))))
              (buffer-list)))

(defun agent-fleet-attach--current-address ()
  "Return this attach buffer's verified terminal address."
  (unless agent-fleet-target (user-error "Not an Agent Fleet attach buffer"))
  (plist-get (agent-fleet-resolve agent-fleet-target) :address))

(defun agent-fleet-attach--display (buffer)
  "Replace the current window with BUFFER without splitting."
  (let* ((window (selected-window)) (dedicated (window-dedicated-p window)))
    (unwind-protect
        (progn (set-window-dedicated-p window nil)
               (set-window-buffer window buffer)
               (set-window-parameter window 'agent-fleet-return-stack nil)
               (set-buffer buffer)
               window)
      (set-window-dedicated-p window dedicated))))

(defun agent-fleet-attach--ctrl-g ()
  "Send exactly Ctrl-G to the current terminal, without submitting input."
  (interactive)
  (when agent-fleet-observe-p (user-error "Read-only observer; attach to send terminal keys"))
  (herdr-core-request "terminal.keys"
                      (list :terminal (agent-fleet-attach--current-address) :keys ["ctrl+g"])))

(defvar agent-fleet-attach-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") agent-fleet-terminal-command-map)
    (define-key map (kbd "C-c C-g") #'agent-fleet-attach--ctrl-g) map))
(defvar-local agent-fleet-attach--dashboard-key-p nil)
(defvar agent-fleet-attach--keymaps
  `((agent-fleet-attach-mode . ,agent-fleet-attach-mode-map)
    (agent-fleet-attach--dashboard-key-p
     . ,(let ((map (make-sparse-keymap)))
          (define-key map (kbd "s-d") #'agent-fleet) map)))
  "Keep Fleet prefixes and the opted-in Dashboard key above terminal input.")
(define-minor-mode agent-fleet-attach-mode
  "Agent operations scoped to this attach buffer."
  :lighter " Fleet"
  (setq-local agent-fleet-attach--dashboard-key-p
              (and agent-fleet-attach-mode
                   (eq (lookup-key (current-global-map) (kbd "s-d")) #'agent-fleet)))
  (setq-local emulation-mode-map-alists
              (delq 'agent-fleet-attach--keymaps (copy-sequence emulation-mode-map-alists)))
  (when agent-fleet-attach-mode
    (push 'agent-fleet-attach--keymaps emulation-mode-map-alists)))

;;;###autoload
(defun agent-fleet-attach (target)
  "Attach to TARGET in the current window, reusing its live viewer."
  (interactive (list (agent-fleet-current-target)))
  (agent-fleet-call-with-presentation (lambda () (agent-fleet-attach--present target nil))))

;;;###autoload
(defun agent-fleet-observe (target)
  "Observe TARGET live without sending input or resizing its PTY."
  (interactive (list (agent-fleet-current-target)))
  (agent-fleet-call-with-presentation (lambda () (agent-fleet-attach--present target t))))

(defun agent-fleet-attach--present (target observe)
  "Open TARGET's viewer at the origin, closing an auxiliary view on success."
  (if (not (frame-parameter nil 'agent-fleet-auxiliary-frame))
      (agent-fleet-attach--open target observe)
    (let ((child (selected-frame)) (origin (agent-fleet-display-origin-frame)))
      (select-frame-set-input-focus origin)
      (select-window (frame-selected-window origin))
      (condition-case err
          (prog1 (agent-fleet-attach--open target observe)
            (agent-fleet-display-close-auxiliary-frame child))
        ((error quit)
         (when (frame-live-p child) (select-frame-set-input-focus child))
         (signal (car err) (cdr err)))))))

(defun agent-fleet-attach--open (target observe)
  "Open TARGET's viewer, with read-only OBSERVE semantics when non-nil."
  (let* ((record (agent-fleet-resolve target t))
         (address (plist-get record :address))
         (reference (agent-fleet-reference record))
         (buffer (agent-fleet-attach--live-buffer reference observe)))
    (unless (and (equal (plist-get record :state) "live")
                 (not (member (plist-get record :reason) '("spawn_pending" "holder_lost"))))
      (user-error "Terminal is finished or recovering; inspect its details"))
    (unless buffer
      (unless (agent-fleet-attach--ghostel-ready-p)
        (let* ((process-environment (herdr-core-environment))
               (socket (getenv "HC_SOCKET")))
          (user-error "Install working Ghostel, or run: HC_SOCKET=%s %s attach %s%s"
                      (shell-quote-argument socket) (shell-quote-argument herdr-core--program)
                      (if observe "--observe " "")
                      (shell-quote-argument address))))
      (setq buffer (generate-new-buffer (format "*%s:%s*" (if observe "observe" "agent")
                                                (agent-fleet-name record))))
      (condition-case err
          (let ((process-environment (herdr-core-environment)))
            (ghostel-exec buffer herdr-core--program
                          (append '("attach") (and observe '("--observe")) (list address)))
            (unless (process-live-p (get-buffer-process buffer))
              (error "hc attach did not start"))
            (with-current-buffer buffer
              (setq-local agent-fleet-target reference)
              (setq-local agent-fleet-observe-p observe)
              (when observe
                (setq-local header-line-format "Read-only observer · q back / detach · agent keeps running")
                (setq-local emulation-mode-map-alists
                            (cons 'agent-fleet-observe--keymaps emulation-mode-map-alists)))
              (when (and (not (string-match-p "/" address))
                         (file-directory-p (plist-get record :cwd)))
                (setq default-directory (file-name-as-directory (plist-get record :cwd))))
              (setq-local evil-escape-inhibit agent-fleet-attach-inhibit-evil-escape)
              (when (boundp 'ghostel-inhibit-anchor-functions)
                (add-hook 'ghostel-inhibit-anchor-functions
                          #'agent-fleet-attach--inhibit-return-anchor nil t))
              (agent-fleet-attach-mode 1)))
        (error (when (buffer-live-p buffer) (kill-buffer buffer))
               (signal (car err) (cdr err)))))
    (if observe
        (agent-fleet-display-window-open buffer)
      (agent-fleet-attach--display buffer))))
(provide 'agent-fleet-attach)
;;; agent-fleet-attach.el ends here
