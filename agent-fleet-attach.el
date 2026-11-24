;;; agent-fleet-attach.el --- Core terminal attachment -*- lexical-binding: t; -*-
;;; Commentary:
;; Ghostel runs a pinned hc attach viewer.  Killing the viewer only detaches.
;;; Code:
(require 'agent-fleet)
(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-force-redraw "ghostel" ())
(declare-function ghostel--window-on-cursor-p "ghostel" (window))
(defvar ghostel-query-before-killing)
(defcustom agent-fleet-attach-inhibit-evil-escape t
  "Inhibit Evil escape sequences in agent terminals."
  :type 'boolean :group 'agent-fleet)
(defvar-local agent-fleet-observe-p nil "Non-nil for a read-only Core viewer.")
(defvar-local agent-fleet-attach--name nil "Last Fleet-managed buffer name.")
(defvar-local agent-fleet-attach--redraw-timer nil)
(defvar-local agent-fleet-attach--refit-windows nil
  "Windows whose current display of this viewer changed size before redraw.")

(defun agent-fleet-attach--cancel-redraw ()
  "Cancel this viewer's pending arrival redraw."
  (when (timerp agent-fleet-attach--redraw-timer)
    (cancel-timer agent-fleet-attach--redraw-timer))
  (setq agent-fleet-attach--redraw-timer nil))

(defun agent-fleet-attach--redraw (buffer)
  "Redraw BUFFER after arrival if it is still a visible, live Fleet viewer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent-fleet-attach--redraw-timer nil)
      (let ((refit-windows agent-fleet-attach--refit-windows))
        (setq agent-fleet-attach--refit-windows nil)
        (when (and (bound-and-true-p agent-fleet-attach-mode)
                   (get-buffer-window buffer t)
                   (process-live-p (get-buffer-process buffer))
                   (fboundp 'ghostel-force-redraw))
          (with-demoted-errors "Fleet terminal redraw: %S"
            (let ((views
                   (mapcar (lambda (window)
                             (list window (copy-marker (window-point window))
                                   (copy-marker (window-start window))
                                   (window-hscroll window) (window-vscroll window t)))
                           (cl-remove-if
                            (lambda (window)
                              (and (memq window refit-windows)
                                   (not (agent-fleet-display-window-restoring-p window))
                                   ;; Only refit live input.  History readers and
                                   ;; explicit Fleet return positions stay put.
                                   (fboundp 'ghostel--window-on-cursor-p)
                                   (ghostel--window-on-cursor-p window)))
                            (get-buffer-window-list buffer nil t)))))
              (unwind-protect
                  (if (and (eq (window-buffer (selected-window)) buffer)
                           (not (assq (selected-window) views)))
                      (ghostel-force-redraw)
                    (save-excursion (ghostel-force-redraw)))
                (dolist (view views)
                  (let ((window (car view)))
                    (when (and (window-live-p window) (eq (window-buffer window) buffer))
                      (set-window-point window (nth 1 view))
                      (set-window-start window (nth 2 view) t)
                      (set-window-hscroll window (nth 3 view))
                      (set-window-vscroll window (nth 4 view) t)))
                  (set-marker (nth 1 view) nil)
                  (set-marker (nth 2 view) nil))))))))))

(defun agent-fleet-attach--on-size-change (window)
  "Refresh WINDOW after its Fleet viewport changes size.
Remember sizes per window and viewer, so a temporary review buffer's
header does not count as resizing the hidden terminal."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (bound-and-true-p agent-fleet-attach-mode)
        (let* ((previous (window-parameter window 'agent-fleet-attach-size))
               (size (list (current-buffer) (window-body-width window t)
                           (window-body-height window t))))
          (set-window-parameter window 'agent-fleet-attach-size size)
          (when (and (eq (car previous) (current-buffer)) (not (equal previous size)))
            ;; Let Ghostel fit the live viewport to its new geometry instead
            ;; of restoring the scroll offset from the smaller window.
            (cl-pushnew window agent-fleet-attach--refit-windows)
            (agent-fleet-attach--schedule-redraw t)))))))

(defun agent-fleet-attach--schedule-redraw (&optional resized)
  "Coalesce redraws, allowing asynchronous resize output to arrive if RESIZED.
The hc attach client samples its PTY size at up to 100 ms intervals; Core
and the program then react.  Debounce actual geometry changes for 250 ms.
Ordinary arrivals must not shorten a pending resize redraw."
  (when resized (agent-fleet-attach--cancel-redraw))
  (when (and (not agent-fleet-attach--redraw-timer)
             (fboundp 'ghostel-force-redraw))
    (setq agent-fleet-attach--redraw-timer
          (run-at-time (if resized 0.25 0) nil
                       #'agent-fleet-attach--redraw (current-buffer)))))

(defun agent-fleet-attach--on-arrival (window &optional same-display)
  "Schedule one redraw when WINDOW displays a Fleet view.
SAME-DISPLAY is non-nil for selection and focus changes.
Resolve the buffer from WINDOW: older Emacs versions do not make the
window's buffer current when calling buffer-change hooks."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (bound-and-true-p agent-fleet-attach-mode)
        (unless same-display
          (setq agent-fleet-attach--refit-windows (delq window agent-fleet-attach--refit-windows)))
        ;; Let buffer changes and Fleet return-position restoration finish.
        (agent-fleet-attach--schedule-redraw)))))

(defun agent-fleet-attach--on-selection (window)
  "Refresh WINDOW on selection, without refreshing the deselected view."
  (when (eq window (selected-window))
    (agent-fleet-attach--on-arrival window t)))

(defun agent-fleet-attach--on-focus ()
  "Refresh visible Fleet viewers in focused frames, without selecting them."
  (dolist (frame (frame-list))
    (when (and (eq (frame-visible-p frame) t)
               (eq (frame-focus-state frame) t))
      (dolist (window (window-list frame 'nomini))
        (agent-fleet-attach--on-arrival window t)))))

(defun agent-fleet-attach--sync-name (record)
  "Update this viewer's name from RECORD without changing its process."
  (let ((name (format "*%s:%s*" (if agent-fleet-observe-p "observe" "agent")
                      (agent-fleet-name record))))
    (unless (equal name agent-fleet-attach--name)
      ;; Fleet owns viewer names; program titles still belong to Ghostel, but
      ;; must not replace the agent's display name in its buffer or mode line.
      (setq-local ghostel-buffer-name-function nil)
      (setq-local ghostel-buffer-identification-format "%b")
      (setq-local mode-line-buffer-identification (propertized-buffer-identification "%b"))
      (rename-buffer name t)
      (setq agent-fleet-attach--name name)
      (force-mode-line-update))))

(defun agent-fleet-attach--refresh-names ()
  "Refresh viewer names from the cache, including after reconnection."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p agent-fleet-attach-mode)
        (let* ((identity (plist-get agent-fleet-target :fleet-identity))
               (address (nth 1 identity))
               (record (and (herdr-core-local-address-p address)
                            (herdr-core-terminal address))))
          (when (and record (equal identity (herdr-core-identity record)))
            (agent-fleet-attach--sync-name record)))))))
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

(defun agent-fleet-attach--reuse-visible (target)
  "Validate and reuse TARGET's interactive viewer in the origin frame.
Return its window on success, nil if absent.  Keep the requesting view selected
until the caller can close it after successful attachment."
  (let* ((reference (agent-fleet-reference (agent-fleet-resolve target)))
         (buffer (agent-fleet-attach--live-buffer reference))
         (window (and buffer (get-buffer-window buffer (agent-fleet-display-origin-frame)))))
    (when (window-live-p window)
      (with-selected-window window
        (agent-fleet-attach reference))
      window)))

(defvar agent-fleet-attach-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") agent-fleet-terminal-command-map)
    map))
(defvar-local agent-fleet-attach--dashboard-key-p nil)
(defvar agent-fleet-attach--keymaps
  `((agent-fleet-attach-mode . ,agent-fleet-attach-mode-map)
    (agent-fleet-attach--dashboard-key-p
     . ,(let ((map (make-sparse-keymap)))
          (define-key map (kbd "s-d") #'agent-fleet) map)))
  "Keep Fleet prefixes and the opted-in Dashboard key above terminal input.")

(defun agent-fleet-attach--install-refresh-hooks ()
  "Install current refresh handlers in this viewer, including after reload."
  (remove-hook 'window-selection-change-functions #'agent-fleet-attach--on-arrival t)
  (add-hook 'window-buffer-change-functions #'agent-fleet-attach--on-arrival nil t)
  (add-hook 'window-selection-change-functions #'agent-fleet-attach--on-selection nil t)
  (add-hook 'window-size-change-functions #'agent-fleet-attach--on-size-change nil t)
  (add-hook 'kill-buffer-hook #'agent-fleet-attach--cancel-redraw nil t))

(define-minor-mode agent-fleet-attach-mode
  "Agent operations scoped to this attach buffer."
  :lighter " Fleet"
  (setq-local agent-fleet-attach--dashboard-key-p
              (and agent-fleet-attach-mode
                   (eq (lookup-key (current-global-map) (kbd "s-d")) #'agent-fleet)))
  (setq-local emulation-mode-map-alists
              (delq 'agent-fleet-attach--keymaps (copy-sequence emulation-mode-map-alists)))
  (if agent-fleet-attach-mode
      (progn
        (push 'agent-fleet-attach--keymaps emulation-mode-map-alists)
        (agent-fleet-attach--install-refresh-hooks))
    (remove-hook 'window-buffer-change-functions #'agent-fleet-attach--on-arrival t)
    (remove-hook 'window-selection-change-functions #'agent-fleet-attach--on-selection t)
    (remove-hook 'window-size-change-functions #'agent-fleet-attach--on-size-change t)
    (remove-hook 'kill-buffer-hook #'agent-fleet-attach--cancel-redraw t)
    (setq agent-fleet-attach--refit-windows nil)
    (agent-fleet-attach--cancel-redraw)))

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
              (when (and (stringp (plist-get record :cwd))
                         (not (file-remote-p (plist-get record :cwd)))
                         (file-directory-p (plist-get record :cwd)))
                (setq default-directory (file-name-as-directory (plist-get record :cwd))))
              (setq-local evil-escape-inhibit agent-fleet-attach-inhibit-evil-escape)
              (when (boundp 'ghostel-inhibit-anchor-functions)
                (add-hook 'ghostel-inhibit-anchor-functions
                          #'agent-fleet-attach--inhibit-return-anchor nil t))
              (agent-fleet-attach-mode 1)))
        (error (when (buffer-live-p buffer) (kill-buffer buffer))
               (signal (car err) (cdr err)))))
    (with-current-buffer buffer
      ;; Also repair local hooks when reusing a viewer from an older load.
      (agent-fleet-attach--install-refresh-hooks)
      (agent-fleet-attach--sync-name record))
    (prog1 (if observe
               (agent-fleet-display-window-open buffer)
             (agent-fleet-attach--display buffer))
      ;; In-place reattachment need not generate any window-change event.
      (with-current-buffer buffer
        (agent-fleet-attach--schedule-redraw)))))
(add-hook 'herdr-core-changed-hook #'agent-fleet-attach--refresh-names)
(add-function :after after-focus-change-function #'agent-fleet-attach--on-focus)
;; Reloading must update existing viewers without restarting their clients.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (bound-and-true-p agent-fleet-attach-mode)
      (agent-fleet-attach--install-refresh-hooks)
      (when (get-buffer-window buffer t)
        (agent-fleet-attach--schedule-redraw)))))
(provide 'agent-fleet-attach)
;;; agent-fleet-attach.el ends here
