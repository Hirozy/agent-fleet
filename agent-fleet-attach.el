;;; agent-fleet-attach.el --- Core terminal attachment -*- lexical-binding: t; -*-
;;; Commentary:
;; Ghostel runs a pinned hc attach viewer.  Killing the viewer only detaches.
;;; Code:
(require 'agent-fleet)
(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function agent-fleet-editor-arm-current-attach "agent-fleet-editor" ())
(defcustom agent-fleet-attach-inhibit-evil-escape t
  "Inhibit Evil escape sequences in agent terminals."
  :type 'boolean :group 'agent-fleet)

(defun agent-fleet-attach--ghostel-ready-p ()
  "Return whether Ghostel has its working native module and launch API."
  (and (require 'ghostel nil t) (featurep 'ghostel-module) (fboundp 'ghostel-exec)))

(defun agent-fleet-attach--live-buffer (reference)
  "Find the live attach viewer for REFERENCE."
  (cl-find-if (lambda (buffer)
                (with-current-buffer buffer
                  (and (bound-and-true-p agent-fleet-attach-mode)
                       (equal agent-fleet-target reference)
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
               (set-buffer buffer)
               window)
      (set-window-dedicated-p window dedicated))))

(defun agent-fleet-attach--ctrl-g ()
  "Route an external editor request when the bridge is enabled."
  (interactive)
  (if (bound-and-true-p agent-fleet-editor-bridge-mode)
      (agent-fleet-editor-arm-current-attach)
    (herdr-core-request "terminal.keys"
                        (list :terminal (agent-fleet-attach--current-address) :keys ["ctrl+g"]))))

;;;###autoload (autoload 'agent-fleet-attach-command-map "agent-fleet-attach" nil t 'keymap)
(defvar agent-fleet-attach-command-map agent-fleet-command-map)
(fset 'agent-fleet-attach-command-map agent-fleet-attach-command-map)
(defvar agent-fleet-attach-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") agent-fleet-attach-command-map)
    (define-key map (kbd "C-c C-g") #'agent-fleet-attach--ctrl-g) map))
(define-minor-mode agent-fleet-attach-mode
  "Agent operations scoped to this attach buffer."
  :lighter " Fleet")

;;;###autoload
(defun agent-fleet-attach (target)
  "Attach to TARGET in the current window, reusing its live viewer."
  (interactive (list (agent-fleet-current-target)))
  (let* ((record (agent-fleet-resolve target t))
         (address (plist-get record :address))
         (reference (agent-fleet-reference record))
         (buffer (agent-fleet-attach--live-buffer reference)))
    (unless (and (equal (plist-get record :state) "live")
                 (not (member (plist-get record :reason) '("spawn_pending" "holder_lost"))))
      (user-error "Terminal is finished or recovering; inspect its details"))
    (unless buffer
      (unless (agent-fleet-attach--ghostel-ready-p)
        (let* ((process-environment (herdr-core-environment))
               (socket (getenv "HC_SOCKET")))
          (user-error "Install working Ghostel, or run: HC_SOCKET=%s %s attach %s"
                      (shell-quote-argument socket) (shell-quote-argument herdr-core--program)
                      (shell-quote-argument address))))
      (setq buffer (generate-new-buffer (format "*agent:%s*" (agent-fleet-name record))))
      (condition-case err
          (let ((process-environment (herdr-core-environment)))
            (ghostel-exec buffer herdr-core--program (list "attach" address))
            (unless (process-live-p (get-buffer-process buffer))
              (error "hc attach did not start"))
            (with-current-buffer buffer
              (setq-local agent-fleet-target reference)
              (when (and (not (string-match-p "/" address))
                         (file-directory-p (plist-get record :cwd)))
                (setq default-directory (file-name-as-directory (plist-get record :cwd))))
              (setq-local evil-escape-inhibit agent-fleet-attach-inhibit-evil-escape)
              (agent-fleet-attach-mode 1)))
        (error (when (buffer-live-p buffer) (kill-buffer buffer))
               (signal (car err) (cdr err)))))
    (agent-fleet-attach--display buffer)))
(provide 'agent-fleet-attach)
;;; agent-fleet-attach.el ends here
