;;; consult-agent-fleet.el --- Optional Consult selection -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "29.1") (consult "3.7") (agent-fleet "1.0.0"))
;;; Commentary:
;; Optional explicit Consult entry point using Fleet's shared model.
;;; Code:
(require 'agent-fleet)
(declare-function consult--read "consult" (candidates &rest options))
;;;###autoload
(defun consult-agent-fleet ()
  "Select a live Fleet member with Consult and attach."
  (interactive)
  (unless (require 'consult nil t) (user-error "Install Consult for this command"))
  (herdr-core-connect)
  (let* ((choices (mapcar (lambda (r) (cons (format "%s [%s] %s"
                                                   (agent-fleet-name r)
                                                   (plist-get r :address)
                                                   (agent-fleet-status r))
                                           (agent-fleet-reference r)))
                          (agent-fleet-agents))))
    (unless choices (user-error "No Fleet members"))
    (agent-fleet-attach
     (cdr (assoc (consult--read (mapcar #'car choices)
                               :prompt "Agent: " :require-match t :category 'agent-fleet)
                 choices)))))
(provide 'consult-agent-fleet)
;;; consult-agent-fleet.el ends here
