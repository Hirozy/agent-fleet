;;; agent-fleet-optional-test.el --- Real optional-package bindings -*- lexical-binding: t; -*-
;; Run separately with Evil and its dependencies on the load path.
(require 'ert)
(require 'agent-fleet-dashboard)
(require 'agent-fleet-start)
(require 'agent-fleet-cleanup)
(require 'agent-fleet-batch)
(setq evil-want-keybinding nil)
(require 'evil)
(declare-function evil-change-state "evil-core" (state &optional message))
(declare-function evil-local-mode "evil-core" (&optional arg))

(ert-deftest fleet-evil-keeps-dashboard-and-review-commands-accessible ()
  (dolist (state '(motion normal))
    (with-temp-buffer
      (agent-fleet-mode)
      (evil-local-mode 1)
      (evil-change-state state)
      (dolist (key '("RET" "v" "n" "p" "o" "i" "m" "d" "s" "k"
                     "h" "P" "!" "c" "g" "q" "C-g"))
        (should (eq (key-binding (kbd key)) (lookup-key agent-fleet-mode-map (kbd key))))))
    (dolist (mode '(agent-fleet-cleanup-mode agent-fleet-batch-mode))
      (with-temp-buffer
        (funcall mode)
        (evil-local-mode 1)
        (evil-change-state state)
        (should (eq (key-binding (kbd "q")) #'agent-fleet-view-quit))
        (should (eq (key-binding (kbd "C-c C-c"))
                    (if (eq mode 'agent-fleet-cleanup-mode)
                        #'agent-fleet-cleanup-execute #'agent-fleet-batch-execute)))
        (when (eq mode 'agent-fleet-cleanup-mode)
          (should (eq (key-binding (kbd "SPC")) #'agent-fleet-cleanup-toggle)))))))

(ert-deftest fleet-evil-keeps-widget-field-submit-and-close-accessible ()
  (save-window-excursion
    (let ((buffer (agent-fleet-start-form)))
      (unwind-protect
          (with-current-buffer buffer
            (evil-local-mode 1)
            (dolist (state '(emacs insert normal))
              (evil-change-state state)
              (dolist (widget agent-fleet--start-fields)
                (goto-char (widget-field-start widget))
                (should (eq (key-binding (kbd "C-c C-c")) #'agent-fleet--start-form-submit))
                (should (eq (key-binding (kbd "C-c C-k")) #'agent-fleet-view-quit)))))
        (kill-buffer buffer)))))

(provide 'agent-fleet-optional-test)
