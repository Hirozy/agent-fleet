;;; consult-agent-fleet-test.el --- tests for consult-agent-fleet  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; This file is NOT part of `make test' because `make compile'/`make
;; test' run with `LOAD_PATH = -L . -L test' and cannot see consult,
;; which the user installs separately (e.g. via borg).  Run it by hand
;; with consult on `load-path':
;;
;;     emacs --batch -L /path/to/consult -L . -L test \
;;           -l consult-agent-fleet -l test/consult-agent-fleet-test.el \
;;           -f ert-run-tests-batch-and-exit
;;
;; (or via the load-path bootstrap the project uses).  The tests stub
;; `consult--read' so they need consult *loadable* but never invoke its
;; live minibuffer; the real `consult--lookup-cdr' is exercised through
;; the stub, so the (label . pane-id) alist shape is checked end to end.

;;; Code:

(require 'ert)
(require 'consult-agent-fleet)

(ert-deftest consult-agent-fleet--read-runs-action-with-pane-id ()
  "Build (label . pane-id) pairs and call ACTION with consult's return.
`consult-agent-fleet--read' hands `consult--read' the alist plus a
`consult--lookup-cdr' lookup, and consult returns the cdr for the
selected candidate; ACTION must receive that pane id, not the label."
  (let (got-table got-lookup acted-with)
    (cl-letf (((symbol-function #'agent-fleet-agent-candidates)
               (lambda ()
                 (list (list :agent nil :pane-id "w1:p1" :name "arch"
                             :label "arch" :kind "Claude" :task "—"
                             :workspace "demo")
                       (list :agent nil :pane-id "w1:p2" :name "arch"
                             :label "arch  [w1:p2]" :kind "Codex" :task "—"
                             :workspace "demo")))))
      ;; Simulate consult: capture the table and :lookup it was handed,
      ;; then apply that lookup to a selected candidate as consult would.
      (cl-letf (((symbol-function #'consult--read)
                 (lambda (table &rest opts)
                   (setq got-table table
                         got-lookup (plist-get opts :lookup))
                   (let ((sel (car (cadr table))))
                     (funcall got-lookup sel table nil nil)))))
        (consult-agent-fleet--read
         "Pick" (lambda (pane-id) (setq acted-with pane-id)))))
    (should (equal got-table
                   '(("arch" . "w1:p1") ("arch  [w1:p2]" . "w1:p2"))))
    (should (eq got-lookup #'consult--lookup-cdr))
    (should (equal acted-with "w1:p2"))))

(ert-deftest consult-agent-fleet--read-signals-when-no-agents ()
  "With no cached agents, signal `user-error' before `consult--read'."
  (cl-letf (((symbol-function #'agent-fleet-agent-candidates) (lambda () nil))
            ((symbol-function #'consult--read)
             (lambda (&rest _) (error "consult--read should not run"))))
    (should-error (consult-agent-fleet--read "Pick" #'ignore)
                  :type 'user-error)))

(provide 'consult-agent-fleet-test)
;;; consult-agent-fleet-test.el ends here
