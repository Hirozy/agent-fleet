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
;; The mode tests use `advice-member-p' to check that enabling adds and
;; disabling removes the `:around' advice on `agent-fleet--read-agent-name'.

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

(ert-deftest consult-agent-fleet-mode-installs-advice ()
  "Enabling the mode adds `:around' advice on `agent-fleet--read-agent-name'.
The mode is global; the unwind-protect restores the global advice
state even if an assertion fails."
  (unwind-protect
      (progn
        (consult-agent-fleet-mode 1)
        (should (advice-member-p #'consult-agent-fleet--read-agent-name
                                 'agent-fleet--read-agent-name)))
    (consult-agent-fleet-mode -1)))

(ert-deftest consult-agent-fleet-mode-toggle-removes-advice ()
  "Disabling the mode removes the advice it installed.
The mode is global; the unwind-protect restores the global advice
state even if an assertion fails."
  (unwind-protect
      (progn
        (consult-agent-fleet-mode 1)
        (should (advice-member-p #'consult-agent-fleet--read-agent-name
                                 'agent-fleet--read-agent-name))
        (consult-agent-fleet-mode -1)
        (should-not (advice-member-p #'consult-agent-fleet--read-agent-name
                                    'agent-fleet--read-agent-name)))
    (consult-agent-fleet-mode -1)))

(ert-deftest consult-agent-fleet--read-agent-name-uses-consult ()
  "With the mode on, the advised reader selects via consult.
`agent-fleet--read-agent-name' is advised to call
`consult-agent-fleet--select', so invoking the reader returns
consult's lookup result (the pane id), not the built-in
`completing-read' path.  The advice is removed in the unwind-protect so
the real reader is left intact."
  (let (got-table got-lookup)
    (cl-letf (((symbol-function #'agent-fleet-agent-candidates)
               (lambda ()
                 (list (list :agent nil :pane-id "w1:p1" :name "arch"
                             :label "arch" :kind "Claude" :task "—"
                             :workspace "demo")
                       (list :agent nil :pane-id "w1:p2" :name "arch"
                             :label "arch  [w1:p2]" :kind "Codex" :task "—"
                             :workspace "demo")))))
      (cl-letf (((symbol-function #'consult--read)
                 (lambda (table &rest opts)
                   (setq got-table table
                         got-lookup (plist-get opts :lookup))
                   (let ((sel (car (cadr table))))
                     (funcall got-lookup sel table nil nil)))))
        (unwind-protect
            (progn
              (consult-agent-fleet-mode 1)
              (should (equal (agent-fleet--read-agent-name "Pick")
                             "w1:p2")))
          (consult-agent-fleet-mode -1))))
    (should (equal got-table
                   '(("arch" . "w1:p1") ("arch  [w1:p2]" . "w1:p2"))))
    (should (eq got-lookup #'consult--lookup-cdr))))

(provide 'consult-agent-fleet-test)
;;; consult-agent-fleet-test.el ends here
