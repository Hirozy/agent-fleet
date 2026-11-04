;;; agent-fleet-magit.el --- Optional Magit views -*- lexical-binding: t; -*-
;;; Commentary:
;; Open an agent's actual checkout, preserving attached terminal geometry.
;;; Code:
(require 'agent-fleet)
(declare-function magit-status "magit-status" (&optional directory))
(declare-function magit-diff-working-tree "magit-diff" (&optional range args files))
(declare-function agent-fleet-remote-review "agent-fleet-remote" (target))
(defun agent-fleet-magit--open (target diff)
  "Open TARGET's Magit view; DIFF selects the working-tree diff."
  (let* ((record (agent-fleet-resolve target t))
         (cwd (plist-get record :cwd)))
    (if (string-match-p "/" (plist-get record :address))
        (progn (require 'agent-fleet-remote) (agent-fleet-remote-review target))
      (unless (require 'magit nil t) (user-error "Install Magit to review code"))
      (unless (and cwd (file-directory-p cwd) (locate-dominating-file cwd ".git"))
        (user-error "Agent has no accessible Git checkout"))
      (let ((open (lambda ()
                    (let ((default-directory (file-name-as-directory cwd))
                          (display-buffer-overriding-action '(display-buffer-same-window)))
                      (if diff
                          (let ((base (agent-fleet-label record "fleet.review-base")))
                            (when (and base (not (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" base)))
                              (user-error "Invalid review base; inspect agent labels"))
                            (magit-diff-working-tree base))
                        (magit-status cwd))
                      (unless (derived-mode-p 'magit-mode)
                        (error "Magit did not open a review buffer"))
                      (agent-fleet-display-make-outcome t (current-buffer) (current-buffer))))))
        (if (and (bound-and-true-p agent-fleet-attach-mode)
                 (agent-fleet-display-child-frame-available-p))
            (agent-fleet-display--aux-run open)
          (funcall open))))))
;;;###autoload
(defun agent-fleet-magit-status (target)
  "Open Magit status for TARGET's checkout."
  (interactive (list (agent-fleet-current-target)))
  (agent-fleet-magit--open target nil))
;;;###autoload
(defun agent-fleet-magit-diff (target)
  "Review TARGET's tracked changes, including commits since its recorded base."
  (interactive (list (agent-fleet-current-target)))
  (agent-fleet-magit--open target t))
(provide 'agent-fleet-magit)
;;; agent-fleet-magit.el ends here
