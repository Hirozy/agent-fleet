;;; agent-fleet-dashboard-test.el --- ERT tests for agent-fleet-dashboard.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests: dashboard rendering, event-driven refresh, faces,
;; column fallbacks, and notification gating.
;; Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l agent-fleet-dashboard -l herdr-mock-server \
;;         -l test/agent-fleet-dashboard-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'herdr)
(require 'agent-fleet)
(require 'agent-fleet-dashboard)
(require 'agent-fleet-parallel)
(require 'herdr-mock-server)
(require 'agent-fleet-test)            ; harness: with-agent-fleet-mock, --pump


;;; --- Helpers --------------------------------------------------------

(defun agent-fleet-dashboard-test--cell (pane-id col)
  "Return column COL (0-based) for PANE-ID in the dashboard, or nil.
Columns: 0 Project, 1 Agent, 2 Kind, 3 State, 4 Task."
  (when-let* ((buf (get-buffer "*Agent Fleet*")))
    (with-current-buffer buf
      (let ((entry (assoc pane-id tabulated-list-entries)))
        (and entry (aref (cadr entry) col))))))

(defmacro with-dashboard-fresh (&rest body)
  "Run BODY with a fresh *Agent Fleet* buffer (any old one killed first)."
  (declare (indent 0))
  `(progn
     (when (get-buffer "*Agent Fleet*") (kill-buffer "*Agent Fleet*"))
     ,@body))


;;; --- Command help ---------------------------------------------------

(ert-deftest agent-fleet-dashboard-help-is-transient ()
  "Dashboard `h' opens a transient containing every documented row action."
  ;; Check the map that `define-derived-mode' actually activates, then check
  ;; an initialized buffer.  Inspecting the former dashboard-named map alone
  ;; missed a regression where no dashboard bindings were active at all.
  (should (eq #'agent-fleet-dashboard-help
              (lookup-key agent-fleet-mode-map (kbd "h"))))
  (with-temp-buffer
    (agent-fleet-mode)
    (should (eq #'agent-fleet-dashboard-help (key-binding (kbd "h")))))
  (dolist (entry '(("o" . agent-fleet-dashboard-inspect)
                   ("s" . agent-fleet-dashboard-prompt)
                   ("i" . agent-fleet-dashboard-interrupt)
                   ("x" . agent-fleet-dashboard-kill)
                   ("r" . agent-fleet-dashboard-rename)
                   ("g" . agent-fleet-dashboard-refresh)
                   ("P" . agent-fleet-dashboard-toggle-project-filter)
                   ("T" . agent-fleet-dashboard-toggle-task-filter)
                   ("w" . agent-fleet-dashboard-worktree)
                   ("d" . agent-fleet-dashboard-diff)
                   ("m" . agent-fleet-dashboard-magit)
                   ("a" . agent-fleet-dashboard-attach)
                   ("N" . agent-fleet-dashboard-new)
                   ("q" . agent-fleet-dashboard-quit)))
    (let ((suffix (transient-get-suffix
                   'agent-fleet-dashboard-help (car entry))))
      ;; Transient represents a suffix several ways across versions: a
      ;; vector of key/description/command, a layout entry whose third
      ;; element is a plist, and a specification list whose cdr is a plist.
      (should (eq (cdr entry)
                  (cond
                   ((vectorp suffix) (aref suffix 2))
                   ((keywordp (cadr suffix))
                    (plist-get (cdr suffix) :command))
                   (t (plist-get (nth 2 suffix) :command))))))))

(ert-deftest agent-fleet-dashboard-installs-bindings-for-evil-states ()
  "Dashboard commands override Evil normal/motion keys when Evil is present."
  (let (states map evil-bindings)
    (cl-letf (((symbol-function 'evil-define-key*)
               (lambda (arg-states arg-map &rest bindings)
                 (setq states arg-states
                       map arg-map
                       evil-bindings bindings))))
      (agent-fleet-dashboard--install-key-bindings))
    (should (equal states '(normal motion)))
    (should (eq map agent-fleet-mode-map))
    (dolist (binding agent-fleet-dashboard--bindings)
      (should (eq (cdr binding)
                  (cadr (member (kbd (car binding)) evil-bindings)))))
    (dolist (key agent-fleet-dashboard--retired-bindings)
      (let ((entry (member (kbd key) evil-bindings)))
        (should entry)
        (should-not (cadr entry))))))

(ert-deftest agent-fleet-dashboard-reload-updates-existing-mode-map ()
  "Reinstalling bindings repairs additions and removals in an older map."
  (let ((agent-fleet-mode-map (make-sparse-keymap)))
    (define-key agent-fleet-mode-map (kbd "RET")
                #'agent-fleet-dashboard-inspect)
    (should-not (lookup-key agent-fleet-mode-map (kbd "h")))
    (agent-fleet-dashboard--install-key-bindings)
    (should (eq #'agent-fleet-dashboard-help
                (lookup-key agent-fleet-mode-map (kbd "h"))))
    (should-not (lookup-key agent-fleet-mode-map (kbd "RET")))))


;;; --- Display backends ----------------------------------------------

(ert-deftest agent-fleet-dashboard-child-frame-has-explicit-version-gate ()
  "Native child dashboards require the documented Emacs version and GUI."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
    (let ((emacs-version "28.2"))
      (should-not (agent-fleet-display-child-frame-available-p 'parent))
      (should (string-match-p
               "require Emacs 29\\.1"
               (agent-fleet-display--child-frame-unavailable-reason
                'parent))))
    (let ((emacs-version "29.1"))
      (should (agent-fleet-display-child-frame-available-p 'parent))))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
    (let ((emacs-version "30.2"))
      (should-not (agent-fleet-display-child-frame-available-p 'parent))
      (should (string-match-p
               "graphical Emacs frame"
               (agent-fleet-display--child-frame-unavailable-reason
                'parent))))))

(ert-deftest agent-fleet-dashboard-child-frame-defaults-to-center ()
  "The native child dashboard is centered within its parent frame."
  (should (= 0.5
             (alist-get 'left
                        agent-fleet-dashboard--child-frame-parameters)))
  (should (= 0.5
             (alist-get 'top
                        agent-fleet-dashboard--child-frame-parameters))))

(ert-deftest agent-fleet-dashboard-backends-registry-classifies-backends ()
  "The backend registry tags each display backend with its lifecycle role.
Locks the refactor that replaced scattered `child-frame' symbol checks with
a metadata table; adding a backend must not change these classifications."
  (should (equal '(buffer child-frame frame)
                 (mapcar #'car agent-fleet-dashboard--backends)))
  (should-not (agent-fleet-dashboard--backend-property 'buffer :container))
  (should-not (agent-fleet-dashboard--backend-property 'buffer :auto-close))
  (should-not (agent-fleet-dashboard--backend-property 'buffer :parented))
  (should (agent-fleet-dashboard--backend-property 'child-frame :container))
  (should (agent-fleet-dashboard--backend-property 'child-frame :auto-close))
  (should (agent-fleet-dashboard--backend-property 'child-frame :parented))
  (should (agent-fleet-dashboard--backend-property 'frame :container))
  (should-not (agent-fleet-dashboard--backend-property 'frame :auto-close))
  (should-not (agent-fleet-dashboard--backend-property 'frame :parented))
  (should (eq #'agent-fleet-dashboard--display-in-buffer
             (agent-fleet-dashboard--display-backend 'buffer))))

(ert-deftest agent-fleet-dashboard-child-frame-uses-native-display-action ()
  "Child display injects the selected parent and private lifecycle markers."
  (let ((agent-fleet-dashboard--child-frame-parameters
         '((width . 0.4) (left . 0.5) (top . 0.5)
           (parent-frame . wrong)))
        action modified focused)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'parent))
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function
                'agent-fleet-display--child-frame-unavailable-reason)
               (lambda (&optional _) nil))
              ((symbol-function 'display-buffer)
               (lambda (_buffer arg-action)
                 (setq action arg-action)
                 'dashboard-window))
              ((symbol-function 'window-frame) (lambda (_) 'child))
              ((symbol-function 'modify-frame-parameters)
               (lambda (frame parameters)
                 (setq modified (cons frame parameters))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq focused frame))))
      (with-temp-buffer
        (should (eq (current-buffer)
                    (agent-fleet-dashboard--display-in-child-frame
                     (current-buffer))))))
    (should (equal '(display-buffer-in-child-frame) (car action)))
    (let ((parameters (alist-get 'child-frame-parameters (cdr action))))
      (should (eq 'parent (alist-get 'parent-frame parameters)))
      (should (eq 'child-frame
                  (alist-get 'agent-fleet-dashboard-display parameters)))
      (should (= 0.4 (alist-get 'width parameters)))
      (should (= 0.5 (alist-get 'left parameters)))
      (should (= 0.5 (alist-get 'top parameters))))
    (should (eq 'child (car modified)))
    (should (eq 'parent
                (alist-get 'agent-fleet-dashboard-origin-frame
                           (cdr modified))))
    (should (eq 'child focused))))

(ert-deftest agent-fleet-dashboard-child-frame-falls-back-when-unsupported ()
  "An unavailable child backend displays the ordinary dashboard buffer."
  (let (fallback)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'parent))
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function
                'agent-fleet-display--child-frame-unavailable-reason)
               (lambda (&optional _) "unsupported test frame"))
              ((symbol-function 'agent-fleet-dashboard--fallback-to-buffer)
               (lambda (buffer reason)
                 (setq fallback (list buffer reason))
                 buffer)))
      (with-temp-buffer
        (agent-fleet-dashboard--display-in-child-frame (current-buffer))
        (should (eq (current-buffer) (car fallback)))))
    (should (equal "unsupported test frame" (cadr fallback)))))

(ert-deftest agent-fleet-dashboard-child-frame-centers-in-parent ()
  "Centering computes the pixel midpoint of the parent minus the child."
  (let (position)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'display-graphic-p) (lambda (_) t))
              ((symbol-function 'frame-pixel-width)
               (lambda (f) (if (eq f 'parent) 1000 480)))
              ((symbol-function 'frame-pixel-height)
               (lambda (f) (if (eq f 'parent) 800 440)))
              ((symbol-function 'set-frame-position)
               (lambda (frame left top)
                 (setq position (list frame left top))))
              ((symbol-function 'frame-parameter)
               (lambda (_f _p) nil)))
      (let ((agent-fleet-display--centered-children nil))
        (agent-fleet-display--center-child-frame 'child 'parent)
        (should (equal '(child 260 180) position))   ; (1000-480)/2, (800-440)/2
        (should (eq 'parent
                    (alist-get 'child
                               agent-fleet-display--centered-children)))))))

(ert-deftest agent-fleet-dashboard-child-frame-recenters-on-parent-resize ()
  "A parent resize re-centers its tracked child frame."
  (let ((calls 0))
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'display-graphic-p) (lambda (_) t))
              ((symbol-function 'frame-pixel-width)
               (lambda (f) (if (eq f 'parent) 1000 480)))
              ((symbol-function 'frame-pixel-height)
               (lambda (f) (if (eq f 'parent) 800 440)))
              ((symbol-function 'set-frame-position)
               (lambda (_f _l _t) (cl-incf calls)))
              ((symbol-function 'frame-parameter)
               (lambda (f _p) (and (eq f 'child) 'child-frame))))
      (let ((agent-fleet-display--centered-children (list (cons 'child 'parent))))
        (agent-fleet-display--recenter-on-parent-resize 'parent)
        (should (= 1 calls))
        ;; A resize of an unrelated frame does not touch the child.
        (agent-fleet-display--recenter-on-parent-resize 'other)
        (should (= 1 calls))))))

(ert-deftest agent-fleet-dashboard-frame-callbacks-use-real-hook-lists ()
  "Frame lifecycle callbacks are installed as hooks and dispatch safely.
This exercises `run-hook-with-args' itself; directly calling the callbacks
would not catch an accidental `add-function' wrapper around a nil hook."
  (dolist (entry
           '((window-size-change-functions
              . agent-fleet-display--recenter-on-parent-resize)
             (delete-frame-functions
              . agent-fleet-display--forget-centered-child)))
    (let ((value (default-value (car entry))))
      (should (listp value))
      (should (memq (cdr entry) value))))
  (let ((window-size-change-functions
         (list #'agent-fleet-display--recenter-on-parent-resize))
        (delete-frame-functions
         (list #'agent-fleet-display--forget-centered-child))
        (agent-fleet-display--centered-children nil))
    (should
     (eq 'ok
         (condition-case nil
             (progn
               (run-hook-with-args 'window-size-change-functions
                                   (selected-frame))
               (run-hook-with-args 'delete-frame-functions
                                   (selected-frame))
               'ok)
           (error 'failed))))))

(ert-deftest agent-fleet-dashboard-frame-hooks-repair-old-function-wrapper ()
  "Reloading repairs hook values composed by the former `add-function' bug."
  (let ((window-size-change-functions nil)
        (delete-frame-functions nil)
        (agent-fleet-display--centered-children nil))
    ;; Reproduce the old top-level registration exactly.  Each hook becomes
    ;; a single advice wrapper whose original function is nil.
    (add-function :after (default-value 'window-size-change-functions)
                  #'agent-fleet-display--recenter-on-parent-resize)
    (add-function :after (default-value 'delete-frame-functions)
                  #'agent-fleet-display--forget-centered-child)
    (should-not (listp (default-value 'window-size-change-functions)))
    (should-not (listp (default-value 'delete-frame-functions)))
    (agent-fleet-display--setup-frame-hooks)
    (dolist (entry
             '((window-size-change-functions
                . agent-fleet-display--recenter-on-parent-resize)
               (delete-frame-functions
                . agent-fleet-display--forget-centered-child)))
      (let ((value (default-value (car entry))))
        (should (listp value))
        (should (memq (cdr entry) value))))
    (should
     (eq 'ok
         (condition-case nil
             (progn
               (run-hook-with-args 'window-size-change-functions
                                   (selected-frame))
               (run-hook-with-args 'delete-frame-functions
                                   (selected-frame))
               'ok)
           (error 'failed))))))

(ert-deftest agent-fleet-dashboard-child-frame-reopen-avoids-nesting ()
  "Reopening from the dashboard child uses its existing native parent."
  (cl-letf (((symbol-function 'selected-frame) (lambda () 'child))
            ((symbol-function 'frame-parameter)
             (lambda (_frame parameter)
               (and (eq parameter 'agent-fleet-dashboard-display)
                    'child-frame)))
            ((symbol-function 'frame-parent)
             (lambda (frame) (and (eq frame 'child) 'parent))))
    (should (eq 'parent
                (agent-fleet-dashboard--child-parent-frame)))))

(ert-deftest agent-fleet-dashboard-standalone-frame-is-reused ()
  "Repeated standalone display focuses one frame instead of creating more."
  (let ((agent-fleet-dashboard--standalone-frame nil)
        (created 0)
        displayed modified focused)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'origin))
              ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (eq frame 'dashboard)))
              ((symbol-function 'make-frame)
               (lambda (_parameters)
                 (cl-incf created)
                 'dashboard))
              ((symbol-function 'modify-frame-parameters)
               (lambda (frame parameters)
                 (setq modified (cons frame parameters))))
              ((symbol-function 'frame-selected-window)
               (lambda (_) 'dashboard-window))
              ((symbol-function 'set-window-buffer)
               (lambda (window buffer) (setq displayed (cons window buffer))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq focused frame))))
      (with-temp-buffer
        (agent-fleet-dashboard--display-in-frame (current-buffer))
        (agent-fleet-dashboard--display-in-frame (current-buffer))
        (should (eq (current-buffer) (cdr displayed)))))
    (should (= 1 created))
    (should (eq 'dashboard (car modified)))
    (should (eq 'origin
                (alist-get 'agent-fleet-dashboard-origin-frame
                           (cdr modified))))
    (should (eq 'dashboard focused))))

(ert-deftest agent-fleet-dashboard-row-display-selects-origin-frame ()
  "Display-producing row actions leave dashboard frames for their origin."
  (let (focused shown)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--agent-at-point)
               (lambda () "w1:p1"))
              ((symbol-function 'selected-frame) (lambda () 'dashboard))
              ((symbol-function 'frame-parameter)
               (lambda (_frame parameter)
                 (and (eq parameter 'agent-fleet-dashboard-origin-frame)
                      'origin)))
              ((symbol-function 'frame-parent) (lambda (_) nil))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (eq frame 'origin)))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq focused frame)))
              ((symbol-function 'agent-fleet-show-output-in-buffer)
               (lambda (pane-id &rest _) (setq shown pane-id))))
      (agent-fleet-dashboard-inspect))
    (should (eq 'origin focused))
    (should (equal "w1:p1" shown))))

(ert-deftest agent-fleet-dashboard-external-actions-close-child-frame ()
  "Every successful external dashboard view closes its originating child."
  (let ((current-frame 'child)
        deleted calls)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--agent-at-point)
               (lambda () "w1:p1"))
              ((symbol-function 'selected-frame)
               (lambda () current-frame))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (cond
                  ((and (eq frame 'child)
                        (eq parameter 'agent-fleet-dashboard-display))
                   'child-frame)
                  ((and (eq frame 'child)
                        (eq parameter
                            'agent-fleet-dashboard-origin-frame))
                   'parent))))
              ((symbol-function 'frame-parent)
               (lambda (frame) (and (eq frame 'child) 'parent)))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (memq frame '(child parent))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq current-frame frame)))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (setq deleted frame)))
              ((symbol-function 'agent-fleet-show-output-in-buffer)
               (lambda (target &rest _)
                 (push (list 'output target) calls)
                 'opened))
              ((symbol-function 'agent-fleet-worktree-status-in-buffer)
               (lambda (target)
                 (push (list 'worktree target) calls)
                 'opened))
              ((symbol-function 'agent-fleet-magit--diff-outcome)
               (lambda (target)
                 (push (list 'diff target) calls)
                 (agent-fleet-display--make-outcome t nil)))
              ((symbol-function 'agent-fleet-magit--status-outcome)
               (lambda (target)
                 (push (list 'magit target) calls)
                 (agent-fleet-display--make-outcome t nil))))
      (dolist (command '(agent-fleet-dashboard-inspect
                         agent-fleet-dashboard-worktree
                         agent-fleet-dashboard-diff
                         agent-fleet-dashboard-magit))
        (setq current-frame 'child
              deleted nil)
        (funcall command)
        (should (eq current-frame 'parent))
        (should (eq deleted 'child))))
    (dolist (expected '((output "w1:p1")
                        (worktree "w1:p1")
                        (diff "w1:p1")
                        (magit "w1:p1")))
      (should (member expected calls)))))

(ert-deftest agent-fleet-dashboard-missing-external-view-keeps-child-frame ()
  "An external action that opens no destination restores its child dashboard."
  (let ((current-frame 'child)
        deleted)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--agent-at-point)
               (lambda () "w1:p1"))
              ((symbol-function 'selected-frame)
               (lambda () current-frame))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (and (eq frame 'child)
                      (eq parameter 'agent-fleet-dashboard-display)
                      'child-frame)))
              ((symbol-function 'frame-parent)
               (lambda (frame) (and (eq frame 'child) 'parent)))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (memq frame '(child parent))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq current-frame frame)))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (setq deleted frame)))
              ((symbol-function 'agent-fleet-worktree-status-in-buffer)
               (lambda (_) nil)))
      (should-not (agent-fleet-dashboard-worktree)))
    (should (eq current-frame 'child))
    (should-not deleted)))

(ert-deftest agent-fleet-dashboard-visitor-no-close-on-not-opened-value ()
  "A non-nil domain value with `:opened' nil does not close the dashboard.
The visitor checks `:opened', not truthiness: a command that returns a
non-nil value but failed to open a view must keep the dashboard child."
  (let ((current-frame 'child)
        deleted)
    (cl-letf (((symbol-function 'selected-frame) (lambda () current-frame))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (and (eq frame 'child)
                      (eq parameter 'agent-fleet-dashboard-display)
                      'child-frame)))
              ((symbol-function 'frame-parent)
               (lambda (frame) (and (eq frame 'child) 'parent)))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (memq frame '(child parent))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq current-frame frame)))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (setq deleted frame))))
      (agent-fleet-dashboard--visit-external-interface
       (lambda ()
         (agent-fleet-display--make-outcome nil 'non-nil-value))))
    (should (eq current-frame 'child))
    (should-not deleted)))

(ert-deftest agent-fleet-dashboard-inline-actions-stay-in-child-frame ()
  "Prompt/control/edit actions do not invoke external-interface navigation."
  (let (external calls)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--agent-at-point)
               (lambda () "w1:p1"))
              ((symbol-function
                'agent-fleet-dashboard--visit-external-interface)
               (lambda (&rest _) (setq external t)))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Prompt" prompt) "do it" "new")))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'agent-fleet--find-agent)
               (lambda (_) (make-herdr-agent :id "w1:p1" :name "old")))
              ((symbol-function 'agent-fleet-prompt)
               (lambda (&rest _) (push 'prompt calls)))
              ((symbol-function 'agent-fleet-interrupt)
               (lambda (&rest _) (push 'interrupt calls)))
              ((symbol-function 'agent-fleet-rename)
               (lambda (&rest _) (push 'rename calls)))
              ((symbol-function 'agent-fleet-dashboard--after-row-change)
               #'ignore))
      (agent-fleet-dashboard-prompt)
      (agent-fleet-dashboard-interrupt)
      (agent-fleet-dashboard-kill)
      (agent-fleet-dashboard-rename))
    (should-not external)
    (should (equal '(rename interrupt prompt) calls))))

(ert-deftest agent-fleet-dashboard-child-attach-replaces-parent-and-closes ()
  "Child attach selects the parent frame, delegates to `agent-fleet-attach'
(which itself displays same-window), then deletes the child dashboard.
The visitor selects the origin frame first so the attach buffer lands in
the parent's window, not the child dashboard."
  (let ((current-frame 'child)
        attached deleted)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--agent-at-point)
               (lambda () "w1:p1"))
              ((symbol-function 'selected-frame)
               (lambda () current-frame))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (cond
                  ((and (eq frame 'child)
                        (eq parameter 'agent-fleet-dashboard-display))
                   'child-frame)
                  ((and (eq frame 'child)
                        (eq parameter
                            'agent-fleet-dashboard-origin-frame))
                   'parent))))
              ((symbol-function 'frame-parent)
               (lambda (frame) (and (eq frame 'child) 'parent)))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (memq frame '(child parent))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq current-frame frame)))
              ((symbol-function 'agent-fleet-attach)
               (lambda (pane-id &optional takeover)
                 (setq attached (list pane-id takeover))
                 'attached))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (setq deleted frame))))
      (should (eq 'attached (agent-fleet-dashboard-attach))))
    (should (equal '("w1:p1" nil) attached))
    (should (eq current-frame 'parent))
    (should (eq deleted 'child))))

(ert-deftest agent-fleet-dashboard-child-attach-error-keeps-dashboard ()
  "A failed attach leaves its child dashboard open for recovery."
  (let ((current-frame 'child)
        deleted)
    (cl-letf (((symbol-function 'agent-fleet-dashboard--agent-at-point)
               (lambda () "w1:p1"))
              ((symbol-function 'selected-frame)
               (lambda () current-frame))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (and (eq frame 'child)
                      (eq parameter 'agent-fleet-dashboard-display)
                      'child-frame)))
              ((symbol-function 'frame-parent)
               (lambda (frame) (and (eq frame 'child) 'parent)))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (memq frame '(child parent))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq current-frame frame)))
              ((symbol-function 'agent-fleet-attach)
               (lambda (&rest _) (user-error "backend unavailable")))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (setq deleted frame))))
      (should-error (agent-fleet-dashboard-attach) :type 'user-error))
    (should-not deleted)
    (should (eq current-frame 'child))))

(ert-deftest agent-fleet-dashboard-new-delegates-to-start-and-closes-child ()
  "`agent-fleet-dashboard-new' starts a new agent via `agent-fleet-start'
(interactive dispatch, so workspace-picking and auto-attach apply), then
closes the child dashboard on success — the same lifecycle as `a'.
`agent-fleet-start' is stubbed with an interactive lambda so
`call-interactively' dispatches without real prompts or RPC."
  (let ((current-frame 'child)
        started deleted)
    (cl-letf (((symbol-function 'selected-frame)
               (lambda () current-frame))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (cond
                  ((and (eq frame 'child)
                        (eq parameter 'agent-fleet-dashboard-display))
                   'child-frame)
                  ((and (eq frame 'child)
                        (eq parameter
                            'agent-fleet-dashboard-origin-frame))
                   'parent))))
              ((symbol-function 'frame-parent)
               (lambda (frame) (and (eq frame 'child) 'parent)))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (memq frame '(child parent))))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq current-frame frame)))
              ((symbol-function 'agent-fleet-start)
               (lambda (&rest _args) (interactive) (setq started t) 'started))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _force) (setq deleted frame))))
      (should (eq 'started (agent-fleet-dashboard-new))))
    (should started)
    (should (eq current-frame 'parent))
    (should (eq deleted 'child))))

(ert-deftest agent-fleet-dashboard-quit-respects-display-container ()
  "Dashboard q deletes owned frames but only quits ordinary windows."
  (let (deleted quit)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'dashboard))
              ((symbol-function 'frame-parameter)
               (lambda (_frame parameter)
                 (and (eq parameter 'agent-fleet-dashboard-display)
                      'child-frame)))
              ((symbol-function 'delete-frame)
               (lambda (frame &optional _) (setq deleted frame)))
              ((symbol-function 'quit-window)
               (lambda (&rest _) (setq quit t))))
      (agent-fleet-dashboard-quit))
    (should (eq deleted 'dashboard))
    (should-not quit))
  (let (deleted quit)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'ordinary))
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'delete-frame)
               (lambda (&rest _) (setq deleted t)))
              ((symbol-function 'quit-window)
               (lambda (&rest _) (setq quit t))))
      (agent-fleet-dashboard-quit))
    (should quit)
    (should-not deleted)))


;;; --- Rendering + event-driven refresh -------------------------------

(ert-deftest agent-fleet-dashboard-entry-ensures-connection ()
  "Opening the dashboard uses the same connection gate as control commands."
  (with-dashboard-fresh
    (let ((herdr-model--cache (herdr-model--empty-session))
          checked)
      (cl-letf (((symbol-function 'agent-fleet--ensure-connected)
                 (lambda () (setq checked t)))
                ((symbol-function 'pop-to-buffer) #'ignore))
        (agent-fleet))
      (should checked))))

(ert-deftest agent-fleet-dashboard-opens-and-lists-agents ()
  "`M-x agent-fleet' opens the dashboard with the cached agent."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (with-current-buffer "*Agent Fleet*"
        (should (eq major-mode 'agent-fleet-mode)))
      (should (equal "w1:p1"
                     (car (assoc "w1:p1"
                                 (with-current-buffer "*Agent Fleet*"
                                   tabulated-list-entries)))))
      (should (equal "demo"    (agent-fleet-dashboard-test--cell "w1:p1" 1))) ; Agent
      (should (equal "Claude"  (agent-fleet-dashboard-test--cell "w1:p1" 2))) ; Kind
      (should (equal "WORKING" (agent-fleet-dashboard-test--cell "w1:p1" 3)))))) ; State

(ert-deftest agent-fleet-dashboard-updates-on-status-event ()
  "A pushed status event updates the State cell live (no `g' needed)."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (equal "WORKING" (agent-fleet-dashboard-test--cell "w1:p1" 3)))
      (herdr-mock-push-event server "pane_agent_status_changed"
                             '(:pane_id "w1:p1" :agent_status "blocked"))
      (agent-fleet-test--pump)
      (let ((cell (agent-fleet-dashboard-test--cell "w1:p1" 3)))
        (should (equal "BLOCKED" cell))
        (should (eq 'agent-fleet-blocked-face
                    (get-text-property 0 'face cell)))))))

(ert-deftest agent-fleet-dashboard-refreshes-on-reconnect ()
  "An open dashboard refreshes from the post-reconnect snapshot (no `g').
The synced hook fires after `herdr--reconnect' replaces the cache from a
fresh `session.snapshot'; an already-open dashboard picks up the new
state without a manual refresh or a polling timer."
  (with-agent-fleet-mock path server
    (let ((herdr-reconnect-delay 0.1)
          (herdr-reconnect-max-delay 0.2)
          (herdr-reconnect-max-attempts 5))
      (with-dashboard-fresh
        (agent-fleet)
        (agent-fleet-test--pump)
        (should (equal "WORKING" (agent-fleet-dashboard-test--cell "w1:p1" 3)))
        ;; Mutate the server snapshot so the reconnect's snapshot fetch
        ;; reports w1:p1 as blocked.  Protocol 20 satisfies the >= 19 check.
        (herdr-mock-set-snapshot
         server
         '(:protocol 20 :version "0.8.2-mock"
           :focused_workspace_id "w1" :focused_tab_id "w1:t1"
           :focused_pane_id "w1:p1"
           :workspaces ((:workspace_id "w1" :label "demo" :number 1
                         :focused t :active_tab_id "w1:t1"
                         :tab_count 1 :pane_count 1 :agent_status "blocked"))
           :tabs ((:tab_id "w1:t1" :workspace_id "w1" :label "1"
                   :number 1 :focused t :pane_count 1 :agent_status "blocked"))
           :panes ((:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
                    :terminal_id "term_mock1" :terminal_title "demo"
                    :terminal_title_stripped "demo"
                    :cwd "/tmp/demo" :foreground_cwd "/tmp/demo"
                    :focused t :revision 5 :agent "claude"
                    :agent_status "blocked"
                    :agent_session (:agent "claude" :kind "id"
                                     :source "herdr:claude" :value "sess-1")))
           :agents ((:pane_id "w1:p1" :workspace_id "w1" :tab_id "w1:t1"
                     :terminal_id "term_mock1" :terminal_title "demo"
                     :terminal_title_stripped "demo"
                     :cwd "/tmp/demo" :foreground_cwd "/tmp/demo"
                     :focused t :revision 5 :state_change_seq 5
                     :name "demo" :display_agent "claude" :title "demo"
                     :interactive_ready t :launch_pending :false
                     :agent "claude" :agent_status "blocked"
                     :agent_session (:agent "claude" :kind "id"
                                     :source "herdr:claude" :value "sess-1")))
           :layouts ()))
        ;; Simulate server-side subscription loss -> client reconnects and
        ;; pulls the mutated snapshot.
        (herdr-mock-close-subscription server)
        (let ((deadline (+ (float-time) 4.0)))
          (while (and (not (herdr-connected-p))
                      (< (float-time) deadline))
            (agent-fleet-test--pump 1)))
        (should (herdr-connected-p))
        (agent-fleet-test--pump)
        ;; The dashboard refreshed via the synced hook — no `g' was pressed.
        (should (equal "BLOCKED" (agent-fleet-dashboard-test--cell "w1:p1" 3)))))))

(ert-deftest agent-fleet-dashboard-adds-row-on-started ()
  "A `pane_agent_detected' event adds a new row without `g'.
The faithful detection payload carries only the agent kind (NO status:
`final_status' is set only when `released' is true — src/app/actions.rs).
So the row appears with Kind from the detection and State from a
following `pane.agent_status_changed' (dotted per-pane kind) event."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (= 1 (length (with-current-buffer "*Agent Fleet*"
                             tabulated-list-entries))))
      (herdr-mock-push-event server "pane_agent_detected"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :released :false))
      (agent-fleet-test--pump)
      (should (= 2 (length (with-current-buffer "*Agent Fleet*"
                             tabulated-list-entries))))
      (should (equal "Codex" (agent-fleet-dashboard-test--cell "w1:p2" 2)))
      ;; the status lands via the per-pane status event, not the detection
      (herdr-mock-push-event server "pane.agent_status_changed"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :agent_status "idle"))
      (agent-fleet-test--pump)
      (should (equal "IDLE"  (agent-fleet-dashboard-test--cell "w1:p2" 3))))))

(ert-deftest agent-fleet-dashboard-removes-row-on-exit ()
  "A `pane_closed' event removes the agent's row without `g'."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (agent-fleet-dashboard-test--cell "w1:p1" 3))
      (herdr-mock-push-event server "pane_closed" '(:pane_id "w1:p1"))
      (agent-fleet-test--pump)
      (should-not (agent-fleet-dashboard-test--cell "w1:p1" 3)))))

(ert-deftest agent-fleet-dashboard-refresh-from-server ()
  "`g' (from-server refresh) repopulates a dropped agent from `agent.list'."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (agent-fleet-dashboard-test--cell "w1:p1" 3))
      ;; Drop it from the LOCAL cache only (no event, no server state change).
      (remhash "w1:p1" (herdr-session-agents (herdr-model-cache)))
      (with-current-buffer "*Agent Fleet*"
        (agent-fleet-dashboard-refresh))            ; local reprint -> gone
      (should-not (agent-fleet-dashboard-test--cell "w1:p1" 3))
      (with-current-buffer "*Agent Fleet*"
        (agent-fleet-dashboard-refresh t))          ; g: re-fetch from server
      (agent-fleet-test--pump)
      (should (agent-fleet-dashboard-test--cell "w1:p1" 3)))))

(ert-deftest agent-fleet-dashboard-blocked-sorts-first ()
  "Blocked agents sort above working agents."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      ;; add a second, blocked agent; the existing w1:p1 is WORKING.
      ;; the detection establishes the agent; the dotted per-pane status
      ;; event sets it blocked (detection carries no status).
      (herdr-mock-push-event server "pane_agent_detected"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :released :false))
      (agent-fleet-test--pump)
      (herdr-mock-push-event server "pane.agent_status_changed"
                             '(:pane_id "w1:p2" :workspace_id "w1"
                               :agent "codex" :agent_status "blocked"))
      (agent-fleet-test--pump)
      (let ((ids (mapcar #'car
                         (with-current-buffer "*Agent Fleet*"
                           tabulated-list-entries))))
        (should (equal "w1:p2" (car ids)))))))      ; blocked first


;;; --- Faces --------------------------------------------

(ert-deftest agent-fleet-dashboard-state-face ()
  "Each status symbol maps to its face; nil/unknown map to the unknown face."
  (should (eq 'agent-fleet-blocked-face
              (agent-fleet-dashboard--face-for-status 'blocked)))
  (should (eq 'agent-fleet-working-face
              (agent-fleet-dashboard--face-for-status 'working)))
  (should (eq 'agent-fleet-done-face
              (agent-fleet-dashboard--face-for-status 'done)))
  (should (eq 'agent-fleet-idle-face
              (agent-fleet-dashboard--face-for-status 'idle)))
  (should (eq 'agent-fleet-unknown-face
              (agent-fleet-dashboard--face-for-status 'unknown)))
  (should (eq 'agent-fleet-unknown-face
              (agent-fleet-dashboard--face-for-status nil)))
  (should (eq 'agent-fleet-unknown-face
              (agent-fleet-dashboard--face-for-status 'bogus)))
  ;; State cell carries the face on its text.
  (let ((cell (agent-fleet-dashboard--state-cell
               (make-herdr-agent :agent-status "blocked"))))
    (should (equal "BLOCKED" cell))
    (should (eq 'agent-fleet-blocked-face (get-text-property 0 'face cell))))
  (let ((cell (agent-fleet-dashboard--state-cell (make-herdr-agent))))
    (should (equal "UNKNOWN" cell))
    (should (eq 'agent-fleet-unknown-face (get-text-property 0 'face cell)))))


;;; --- Column fallbacks ----------------------------------------------

(ert-deftest agent-fleet-dashboard-columns ()
  "Project/Kind/Task/State helpers fall back gracefully."
  ;; Project: workspace label (live cache) -> cwd basename -> "—".
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (agent-fleet)
      (agent-fleet-test--pump)
      (should (equal "demo"                 ; workspace w1 label
                     (agent-fleet-dashboard--project-label
                      (herdr-find-agent "w1:p1"))))))
  (should (equal "—"
                 (agent-fleet-dashboard--project-label
                  (make-herdr-agent :workspace-id nil :cwd nil))))
  (should (equal "—"
                 (agent-fleet-dashboard--project-label
                  (make-herdr-agent :workspace-id nil :cwd ""))))
  (should (equal "proj"
                 (agent-fleet-dashboard--project-label
                  (make-herdr-agent :workspace-id nil :cwd "/home/me/proj"))))
  ;; Kind: capitalize or "—".
  (should (equal "Claude" (agent-fleet-dashboard--kind-label
                           (make-herdr-agent :agent "claude"))))
  (should (equal "—"      (agent-fleet-dashboard--kind-label
                           (make-herdr-agent :agent nil))))
  ;; Task: terminal title unless it duplicates the Agent label, else "—".
  (should (equal "building"
                 (agent-fleet-dashboard--task-label
                  (make-herdr-agent :name "arch"
                                    :terminal-title-stripped "building")
                  "arch")))
  (should (equal "—"
                 (agent-fleet-dashboard--task-label
                  (make-herdr-agent :name "arch"
                                    :terminal-title-stripped "arch")
                  "arch")))
  (should (equal "—"
                 (agent-fleet-dashboard--task-label
                  (make-herdr-agent) "arch"))))


;;; --- Notifications ------------------------------------

(ert-deftest agent-fleet-dashboard-notify-gated ()
  "Notifications fire only for statuses in `agent-fleet-notify-on'."
  (let ((agent-fleet-notify-on '(blocked)))
    (should (equal "agent-fleet: demo → blocked"
                   (agent-fleet-dashboard--notify-message
                    '(:status "blocked" :name "demo"))))
    ;; done is not in the set -> nil (no notification).
    (should (null (agent-fleet-dashboard--notify-message
                   '(:status "done" :name "demo"))))
    ;; name falls back to pane-id, then "agent".
    (should (equal "agent-fleet: w1:p1 → blocked"
                   (agent-fleet-dashboard--notify-message
                    '(:status "blocked" :pane-id "w1:p1"))))
    (should (equal "agent-fleet: agent → blocked"
                   (agent-fleet-dashboard--notify-message
                    '(:status "blocked")))))
  ;; default set includes done.
  (let ((agent-fleet-notify-on '(blocked done)))
    (should (equal "agent-fleet: demo → done"
                   (agent-fleet-dashboard--notify-message
                    '(:status "done" :name "demo")))))
  ;; disabled entirely.
  (let ((agent-fleet-notify-on nil))
    (should (null (agent-fleet-dashboard--notify-message
                   '(:status "blocked" :name "demo"))))))


;;; --- Command map --------------------------------------

(ert-deftest agent-fleet-command-map-has-no-global-binding ()
  "The package must not bind a global key."
  ;; Loading the feature should not have installed any C-c a binding.
  (should-not (where-is-internal 'agent-fleet global-map)))

(ert-deftest agent-fleet-command-map-keys ()
  "The prefix map binds the documented commands."
  (should (eq (lookup-key agent-fleet-command-map "a") #'agent-fleet))
  (should (eq (lookup-key agent-fleet-command-map "s") #'agent-fleet-start))
  (should (eq (lookup-key agent-fleet-command-map "p") #'agent-fleet-prompt))
  (should (eq (lookup-key agent-fleet-command-map "o") #'agent-fleet-show-output-in-buffer))
  (should (eq (lookup-key agent-fleet-command-map "i") #'agent-fleet-interrupt))
  (dolist (command '(agent-fleet-start agent-fleet-prompt
                     agent-fleet-wait agent-fleet-interrupt agent-fleet-rename
                     agent-fleet-kill agent-fleet-switch agent-fleet-show-output-in-buffer))
    (should (commandp command)))
  ;; The documented unquoted map value forms a real prefix keymap.
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") agent-fleet-command-map)
    (should (eq (lookup-key map (kbd "C-c a p")) #'agent-fleet-prompt))))


;;; --- Row keys -----------------------------------------

(ert-deftest agent-fleet-dashboard-row-keys-d-and-m ()
  "The dashboard binds `d' to the diff command and `m' to the magit command,
not the old `--not-yet' stubs."
  (should (eq #'agent-fleet-dashboard-diff
              (lookup-key agent-fleet-mode-map "d")))
  (should (eq #'agent-fleet-dashboard-magit
              (lookup-key agent-fleet-mode-map "m"))))


;;; --- Task column + T filter ---------------------------

(ert-deftest agent-fleet-dashboard-row-keys-t-and-p ()
  "`T' narrows to a task; `P' narrows to a project."
  (should (eq #'agent-fleet-dashboard-toggle-task-filter
              (lookup-key agent-fleet-mode-map "T")))
  (should (eq #'agent-fleet-dashboard-toggle-project-filter
              (lookup-key agent-fleet-mode-map "P"))))

(ert-deftest agent-fleet-dashboard-task-filter-and-column ()
  "The Task column shows a task agent's task title; the `T' filter narrows
to that task's agents and the mode-line banner shows the live aggregate
state."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (let* ((task (agent-fleet-parallel
                    '((claude . "do A") (codex . "do B"))
                    :title "rev" :cwd "/tmp"))
             (pids (agent-fleet-task-agents task)))
        (agent-fleet)
        (agent-fleet-test--pump)
        ;; the task agents' Task column shows the task title (the group
        ;; label), not the pane's terminal title.
        (should (equal "rev" (agent-fleet-dashboard-test--cell (nth 0 pids) 4)))
        (should (equal "rev" (agent-fleet-dashboard-test--cell (nth 1 pids) 4)))
        ;; the pre-existing snapshot agent is present while unfiltered.
        (should (agent-fleet-dashboard-test--cell "w1:p1" 3))
        ;; narrow to the task.
        (with-current-buffer "*Agent Fleet*"
          (setq agent-fleet-dashboard--task-filter (agent-fleet-task-id task))
          (agent-fleet-dashboard-refresh))
        (let ((ids (mapcar #'car
                           (with-current-buffer "*Agent Fleet*"
                             tabulated-list-entries))))
          (should (member (nth 0 pids) ids))
          (should (member (nth 1 pids) ids))
          (should-not (member "w1:p1" ids)))
        ;; the mode-line banner shows the title + live aggregate state.
        (with-current-buffer "*Agent Fleet*"
          (should (string-match-p "rev" (or agent-fleet-dashboard--task-banner "")))
          (should (string-match-p "done" agent-fleet-dashboard--task-banner)))))))

(ert-deftest agent-fleet-dashboard-task-column-refreshes-on-registration ()
  "Task metadata refreshes the dashboard even without a later status event."
  (with-agent-fleet-mock path server
    (with-dashboard-fresh
      (let ((agent-fleet--tasks nil)
            (agent-fleet--agent-tasks (make-hash-table :test 'equal)))
        (agent-fleet)
        (agent-fleet-test--pump)
        ;; Suppress prompt-driven status events: the task-created hook is the
        ;; only event capable of refreshing the just-established task mapping.
        (cl-letf (((symbol-function 'agent-fleet-prompt)
                   (lambda (&rest _) '(:agent_status "idle"))))
          (let* ((task (agent-fleet-parallel
                        '((claude . "quiet")) :title "quiet-task" :cwd "/tmp"))
                 (pid (car (agent-fleet-task-agents task))))
            (should (equal "quiet-task"
                           (agent-fleet-dashboard-test--cell pid 4)))))))))


;;; --- Auxiliary child frame -------------------------------------------

;; Dynamic scratch for the shared frame stubs below: `let'-binding these in a
;; test makes them visible inside the stub lambdas.
(defvar agent-fleet-dashboard-test--current-frame nil)
(defvar agent-fleet-dashboard-test--displayed 0)
(defvar agent-fleet-dashboard-test--deleted nil)

(ert-deftest agent-fleet-dashboard-aux-frame-fills-parent ()
  "Auxiliary views use the full parent instead of dashboard proportions.
Magit needs a full-size presentation surface; the compact 0.48 by 0.55
dimensions belong only to the dashboard child frame."
  (should (= 1.0
             (alist-get 'width agent-fleet-display--aux-frame-parameters)))
  (should (= 1.0
             (alist-get 'height agent-fleet-display--aux-frame-parameters)))
  (should (= 0.48
             (alist-get 'width
                        agent-fleet-dashboard--child-frame-parameters)))
  (should (= 0.55
             (alist-get 'height
                        agent-fleet-dashboard--child-frame-parameters))))

(defmacro agent-fleet-dashboard-test--with-aux-frames (&rest body)
  "Run BODY with the frame APIs stubbed for auxiliary child-frame tests.
`selected-frame' answers `agent-fleet-dashboard-test--current-frame',
which the `select-frame-set-input-focus' stub updates, so the test can
observe the final focus.  The auxiliary child is tagged `aux-child' with
its origin recorded, as `--aux-create' would stamp on a real frame."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'selected-frame)
              (lambda () agent-fleet-dashboard-test--current-frame))
             ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
             ((symbol-function 'frame-parameter)
              (lambda (frame parameter)
                (cond
                 ((and (eq frame 'aux-child)
                       (eq parameter 'agent-fleet-auxiliary-origin-frame))
                  'origin)
                 ((and (eq frame 'aux-child)
                       (eq parameter 'agent-fleet-auxiliary-frame))
                  t)
                 (t nil))))
             ((symbol-function 'frame-parent) (lambda (_) nil))
             ((symbol-function 'frame-live-p)
              (lambda (frame) (memq frame '(origin aux-child))))
             ((symbol-function 'display-buffer)
              (lambda (_buffer &optional _action &rest _)
                (cl-incf agent-fleet-dashboard-test--displayed)
                'aux-window))
             ((symbol-function 'window-frame) (lambda (_) 'aux-child))
             ((symbol-function 'modify-frame-parameters) (lambda (&rest _)))
             ((symbol-function 'select-frame-set-input-focus)
              (lambda (frame)
                (setq agent-fleet-dashboard-test--current-frame frame)))
             ((symbol-function 'agent-fleet-display--center-child-frame)
              (lambda (&rest _)))
             ((symbol-function 'delete-frame)
              (lambda (frame &optional _)
                (setq agent-fleet-dashboard-test--deleted frame))))
     ,@body))

(ert-deftest agent-fleet-dashboard-aux-run-errors-without-fallback ()
  "An unsupported runtime is a `user-error', never a buffer fallback.
The thunk must not run at all: an explicit `-in-child-frame' command
either opens a child frame or signals."
  (let (ran)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'origin))
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'frame-parent) (lambda (&rest _) nil))
              ((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
      (should-error
       (agent-fleet-display--aux-run (lambda () (setq ran t) 'fallback))
       :type 'user-error))
    (should-not ran)))

(ert-deftest agent-fleet-dashboard-aux-run-nil-closes-new-child ()
  "A nil thunk result closes a child created this call and refocuses origin.
An empty new child must not linger."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-dashboard-test--current-frame 'origin)
        (agent-fleet-dashboard-test--displayed 0)
        (agent-fleet-dashboard-test--deleted nil))
    (agent-fleet-dashboard-test--with-aux-frames
      (should-not (agent-fleet-display--aux-run (lambda () nil))))
    (should (= 1 agent-fleet-dashboard-test--displayed))
    (should (eq 'aux-child agent-fleet-dashboard-test--deleted))
    (should (eq 'origin agent-fleet-dashboard-test--current-frame))
    (should-not (gethash 'origin agent-fleet-display--aux-frames))
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-dashboard-aux-run-nil-keeps-reused-child ()
  "A nil thunk result keeps a reused child showing its prior view.
No new child is created and nothing is deleted."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-dashboard-test--current-frame 'origin)
        (agent-fleet-dashboard-test--displayed 0)
        (agent-fleet-dashboard-test--deleted nil))
    (puthash 'origin 'aux-child agent-fleet-display--aux-frames)
    (agent-fleet-dashboard-test--with-aux-frames
      (should-not (agent-fleet-display--aux-run (lambda () nil))))
    (should (zerop agent-fleet-dashboard-test--displayed))
    (should-not agent-fleet-dashboard-test--deleted)
    (should (eq 'aux-child agent-fleet-dashboard-test--current-frame))
    (should (eq 'aux-child (gethash 'origin agent-fleet-display--aux-frames)))))

(ert-deftest agent-fleet-dashboard-aux-run-error-closes-and-resignals ()
  "A thunk error deletes a newly created child, refocuses origin, resignals."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-dashboard-test--current-frame 'origin)
        (agent-fleet-dashboard-test--displayed 0)
        (agent-fleet-dashboard-test--deleted nil))
    (agent-fleet-dashboard-test--with-aux-frames
      (should-error
       (agent-fleet-display--aux-run (lambda () (error "boom")))
       :type 'error))
    (should (= 1 agent-fleet-dashboard-test--displayed))
    (should (eq 'aux-child agent-fleet-dashboard-test--deleted))
    (should (eq 'origin agent-fleet-dashboard-test--current-frame))
    (should-not (gethash 'origin agent-fleet-display--aux-frames))
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-dashboard-aux-run-reuses-one-child-per-origin ()
  "Repeated successful opens reuse the same auxiliary child."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-dashboard-test--current-frame 'origin)
        (agent-fleet-dashboard-test--displayed 0)
        (agent-fleet-dashboard-test--deleted nil))
    (agent-fleet-dashboard-test--with-aux-frames
      (dotimes (_ 3)
        (should (eq 'ok (agent-fleet-display--aux-run (lambda () 'ok)))))
      (should (eq 'aux-child (gethash 'origin agent-fleet-display--aux-frames))))
    (should (= 1 agent-fleet-dashboard-test--displayed))
    (should-not agent-fleet-dashboard-test--deleted)
    (should (eq 'aux-child agent-fleet-dashboard-test--current-frame))
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-dashboard-aux-run-keeps-child-on-opened-nil-value ()
  "A nil domain value with `:opened' t keeps the child.
This is the Magit case: `magit-status' returns nil but the view opened.
Without the explicit outcome, the old truthiness check would close the
newly created child."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-dashboard-test--current-frame 'origin)
        (agent-fleet-dashboard-test--displayed 0)
        (agent-fleet-dashboard-test--deleted nil))
    (agent-fleet-dashboard-test--with-aux-frames
      (let ((outcome (agent-fleet-display--aux-run
                      (lambda ()
                        (agent-fleet-display--make-outcome t nil)))))
        (should (agent-fleet-display--outcome-opened-p outcome))))
    (should (eq 'aux-child agent-fleet-dashboard-test--current-frame))
    (should-not agent-fleet-dashboard-test--deleted)
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-dashboard-aux-run-resizes-reused-child ()
  "A reused child receives the current full-parent size parameters.
This also repairs a live half-size auxiliary frame created before the
full-size presentation policy was loaded."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-dashboard-test--current-frame 'origin)
        modified)
    (puthash 'origin 'aux-child agent-fleet-display--aux-frames)
    (agent-fleet-dashboard-test--with-aux-frames
      (cl-letf (((symbol-function 'modify-frame-parameters)
                 (lambda (frame parameters)
                   (setq modified (cons frame parameters)))))
        (should (eq 'ok (agent-fleet-display--aux-run (lambda () 'ok))))))
    (should (eq 'aux-child (car modified)))
    (should (= 1.0 (alist-get 'width (cdr modified))))
    (should (= 1.0 (alist-get 'height (cdr modified))))))

(ert-deftest agent-fleet-dashboard-aux-origin-frame-prevents-nesting ()
  "An auxiliary child never nests under another child frame.
An aux child opened from an aux child reuses its recorded origin; a
dashboard child-frame resolves to its native parent."
  (cl-letf (((symbol-function 'selected-frame) (lambda () 'aux-child))
            ((symbol-function 'frame-parameter)
             (lambda (frame parameter)
               (and (eq frame 'aux-child)
                    (eq parameter 'agent-fleet-auxiliary-origin-frame)
                    'origin)))
            ((symbol-function 'frame-live-p)
             (lambda (frame) (memq frame '(origin aux-child)))))
    (should (eq 'origin (agent-fleet-display--aux-origin-frame))))
  (cl-letf (((symbol-function 'selected-frame) (lambda () 'dashboard-child))
            ((symbol-function 'frame-parameter)
             (lambda (_frame parameter)
               (and (eq parameter 'agent-fleet-dashboard-display)
                    'child-frame)))
            ((symbol-function 'frame-parent)
             (lambda (frame) (and (eq frame 'dashboard-child) 'parent)))
            ((symbol-function 'frame-live-p)
             (lambda (frame) (memq frame '(parent dashboard-child)))))
    (should (eq 'parent (agent-fleet-display--aux-origin-frame)))))

(ert-deftest agent-fleet-dashboard-aux-forget-removes-from-reuse-table ()
  "Deleting an aux child forgets its reuse entry; others stay untouched.
A frame without the auxiliary marker, or mapped to a different origin
entry, leaves the table alone."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq)))
    (puthash 'origin 'aux-child agent-fleet-display--aux-frames)
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (cond
                  ((and (eq frame 'aux-child)
                        (eq parameter 'agent-fleet-auxiliary-frame))
                   t)
                  ((and (eq frame 'aux-child)
                        (eq parameter 'agent-fleet-auxiliary-origin-frame))
                   'origin)
                  (t nil)))))
      (agent-fleet-display--aux-forget 'aux-child)
      (should-not (gethash 'origin agent-fleet-display--aux-frames))
      ;; A non-auxiliary frame is never forgotten.
      (puthash 'origin 'aux-child agent-fleet-display--aux-frames)
      (agent-fleet-display--aux-forget 'ordinary)
      (should (eq 'aux-child (gethash 'origin agent-fleet-display--aux-frames)))
      ;; A frame not matching the mapped child is never forgotten.
      (puthash 'origin 'other-child agent-fleet-display--aux-frames)
      (agent-fleet-display--aux-forget 'aux-child)
      (should (eq 'other-child
                  (gethash 'origin agent-fleet-display--aux-frames))))))


(ert-deftest agent-fleet-dashboard-quit-window-advice-is-installed ()
  "`quit-restore-window' is advised so auxiliary child frames close on q.
Installed by `agent-fleet-display--setup-frame-hooks'; the advice is
idempotent (a single member on the symbol)."
  (should (advice-member-p #'agent-fleet-display--aux-quit-restore-window
                            'quit-restore-window)))

(ert-deftest agent-fleet-dashboard-quit-window-closes-aux-child ()
  "Quitting a view window closes the auxiliary child, not switch buffers.
`quit-restore-window' on a window inside an auxiliary child deletes the
child, forgets the reuse entry, and refocuses the origin.  The bury
variant leaves the view buffer alive; the kill variant kills it."
  (dolist (mode '(bury kill))
    (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
          (agent-fleet-dashboard-test--current-frame 'aux-child)
          (agent-fleet-dashboard-test--deleted nil)
          (view-buf (get-buffer-create " *aux-quit-view*")))
      (puthash 'origin 'aux-child agent-fleet-display--aux-frames)
      (cl-letf (((symbol-function 'selected-frame) (lambda () 'aux-child))
                ((symbol-function 'window-live-p) (lambda (&optional _) t))
                ((symbol-function 'window-frame) (lambda (&rest _) 'aux-child))
                ((symbol-function 'window-buffer) (lambda (&rest _) view-buf))
                ((symbol-function 'frame-parameter)
                 (lambda (frame parameter)
                   (cond
                    ((and (eq frame 'aux-child)
                          (eq parameter 'agent-fleet-auxiliary-frame))
                     t)
                    ((and (eq frame 'aux-child)
                          (eq parameter 'agent-fleet-auxiliary-origin-frame))
                     'origin)
                    (t nil))))
                ((symbol-function 'frame-live-p)
                 (lambda (frame) (memq frame '(origin aux-child))))
                ((symbol-function 'delete-frame)
                 (lambda (frame &optional _)
                   (setq agent-fleet-dashboard-test--deleted frame)))
                ((symbol-function 'select-frame-set-input-focus)
                 (lambda (frame)
                   (setq agent-fleet-dashboard-test--current-frame frame))))
        (quit-restore-window nil mode))
      (should (eq 'aux-child agent-fleet-dashboard-test--deleted))
      (should (eq 'origin agent-fleet-dashboard-test--current-frame))
      (should-not (gethash 'origin agent-fleet-display--aux-frames))
      (if (eq mode 'kill)
          (should-not (buffer-live-p view-buf))
        (should (buffer-live-p view-buf))
        (kill-buffer view-buf)))))

(ert-deftest agent-fleet-dashboard-quit-window-passes-through-ordinary-frames ()
  "Quitting a window on an ordinary frame keeps the default behavior."
  (let ((switched nil))
    (cl-letf (((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'switch-to-prev-buffer)
               (lambda (&rest _) (setq switched t) t)))
      (quit-restore-window nil 'bury))
    (should switched)))


(provide 'agent-fleet-dashboard-test)
;;; agent-fleet-dashboard-test.el ends here
