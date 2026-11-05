;;; agent-fleet-display-test.el --- Retained frame safety regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'agent-fleet-display)
(defvar agent-fleet-display-test--current-frame nil)
(defvar agent-fleet-display-test--displayed 0)
(defvar agent-fleet-display-test--deleted nil)
(ert-deftest agent-fleet-display-child-frame-centers-in-parent ()
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

(ert-deftest agent-fleet-display-child-frame-recenters-on-parent-resize ()
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
               (lambda (f parameter)
                 (and (eq f 'child) (eq parameter 'agent-fleet-auxiliary-frame)))))
      (let ((agent-fleet-display--centered-children (list (cons 'child 'parent))))
        (agent-fleet-display--recenter-on-parent-resize 'parent)
        (should (= 1 calls))
        ;; A resize of an unrelated frame does not touch the child.
        (agent-fleet-display--recenter-on-parent-resize 'other)
        (should (= 1 calls))
        ;; A tracked frame without Fleet's auxiliary marker is left alone.
        (cl-letf (((symbol-function 'frame-parameter) (lambda (&rest _) nil)))
          (agent-fleet-display--recenter-on-parent-resize 'parent)
          (should (= 1 calls)))))))

(ert-deftest agent-fleet-display-frame-callbacks-use-real-hook-lists ()
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

(ert-deftest agent-fleet-display-frame-hooks-are-idempotent ()
  "Reloading preserves unrelated hooks without duplicating Fleet callbacks."
  (let ((window-size-change-functions (list #'ignore))
        (delete-frame-functions nil)
        (agent-fleet-display--centered-children nil))
    (agent-fleet-display--setup-frame-hooks)
    (agent-fleet-display--setup-frame-hooks)
    (should (memq #'ignore window-size-change-functions))
    (dolist (entry
             '((window-size-change-functions
                . agent-fleet-display--recenter-on-parent-resize)
               (delete-frame-functions
                . agent-fleet-display--forget-centered-child)))
      (let ((value (default-value (car entry))))
        (should (listp value))
        (should (= 1 (cl-count (cdr entry) value)))))
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

(defmacro agent-fleet-display-test--with-aux-frames (&rest body)
  "Run BODY with the frame APIs stubbed for auxiliary child-frame tests.
`selected-frame' answers `agent-fleet-display-test--current-frame',
which the `select-frame-set-input-focus' stub updates, so the test can
observe the final focus.  The auxiliary child is tagged `aux-child' with
its origin recorded, as `--aux-create' would stamp on a real frame."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'selected-frame)
              (lambda () agent-fleet-display-test--current-frame))
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
                (cl-incf agent-fleet-display-test--displayed)
                'aux-window))
             ((symbol-function 'window-frame) (lambda (_) 'aux-child))
             ((symbol-function 'window-list) (lambda (&rest _) nil))
             ((symbol-function 'modify-frame-parameters) (lambda (&rest _)))
             ((symbol-function 'select-frame-set-input-focus)
              (lambda (frame)
                (setq agent-fleet-display-test--current-frame frame)))
             ((symbol-function 'agent-fleet-display--center-child-frame)
              (lambda (&rest _)))
             ((symbol-function 'delete-frame)
              (lambda (frame &optional _)
                (setq agent-fleet-display-test--deleted frame))))
     ,@body))

(ert-deftest agent-fleet-display-aux-run-errors-without-fallback ()
  "An unsupported runtime is a `user-error', never a buffer fallback.
The child-frame runner must not invoke the thunk on an unsupported display."
  (let (ran)
    (cl-letf (((symbol-function 'selected-frame) (lambda () 'origin))
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'frame-parent) (lambda (&rest _) nil))
              ((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
      (should-error
       (agent-fleet-display--aux-run (lambda () (setq ran t) 'fallback))
       :type 'user-error))
    (should-not ran)))

(ert-deftest agent-fleet-display-delayed-refocus-does-not-steal-focus ()
  "An old child-close callback must not focus over a newer child."
  (let ((current 'old-child)
        (selections nil)
        (raised nil)
        idle-function
        idle-args)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (&rest _) t))
              ((symbol-function 'selected-frame) (lambda () current))
              ((symbol-function 'select-frame-set-input-focus)
               (lambda (frame)
                 (setq current frame)
                 (push frame selections)))
              ((symbol-function 'raise-frame)
               (lambda (frame) (push frame raised)))
              ((symbol-function 'run-with-idle-timer)
               (lambda (_seconds _repeat function &rest args)
                 (setq idle-function function
                       idle-args args))))
      (agent-fleet-display--refocus-frame 'origin)
      (should (eq current 'origin))
      ;; A newer auxiliary child becomes current before the idle callback
      ;; scheduled by the previous child deletion gets a chance to run.
      (setq current 'new-child)
      (apply idle-function idle-args)
      (should (eq current 'new-child))
      (should (equal selections '(origin)))
      (should-not raised))))

(ert-deftest agent-fleet-display-aux-run-nil-closes-new-child ()
  "A nil thunk result closes a child created this call and refocuses origin.
An empty new child must not linger."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-display-test--current-frame 'origin)
        (agent-fleet-display-test--displayed 0)
        (agent-fleet-display-test--deleted nil))
    (agent-fleet-display-test--with-aux-frames
      (should-not (agent-fleet-display--aux-run (lambda () nil))))
    (should (= 1 agent-fleet-display-test--displayed))
    (should (eq 'aux-child agent-fleet-display-test--deleted))
    (should (eq 'origin agent-fleet-display-test--current-frame))
    (should-not (gethash 'origin agent-fleet-display--aux-frames))
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-display-aux-run-nil-keeps-reused-child ()
  "A nil thunk result keeps a reused child showing its prior view.
No new child is created and nothing is deleted."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-display-test--current-frame 'origin)
        (agent-fleet-display-test--displayed 0)
        (agent-fleet-display-test--deleted nil))
    (puthash 'origin 'aux-child agent-fleet-display--aux-frames)
    (agent-fleet-display-test--with-aux-frames
      (should-not (agent-fleet-display--aux-run (lambda () nil))))
    (should (zerop agent-fleet-display-test--displayed))
    (should-not agent-fleet-display-test--deleted)
    (should (eq 'aux-child agent-fleet-display-test--current-frame))
    (should (eq 'aux-child (gethash 'origin agent-fleet-display--aux-frames)))))

(ert-deftest agent-fleet-display-aux-run-error-closes-and-resignals ()
  "A thunk error deletes a newly created child, refocuses origin, resignals."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-display-test--current-frame 'origin)
        (agent-fleet-display-test--displayed 0)
        (agent-fleet-display-test--deleted nil))
    (agent-fleet-display-test--with-aux-frames
      (should-error
       (agent-fleet-display--aux-run (lambda () (error "boom")))
       :type 'error))
    (should (= 1 agent-fleet-display-test--displayed))
    (should (eq 'aux-child agent-fleet-display-test--deleted))
    (should (eq 'origin agent-fleet-display-test--current-frame))
    (should-not (gethash 'origin agent-fleet-display--aux-frames))
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-display-aux-run-reuses-one-child-per-origin ()
  "Repeated successful opens reuse the same auxiliary child."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-display-test--current-frame 'origin)
        (agent-fleet-display-test--displayed 0)
        (agent-fleet-display-test--deleted nil))
    (agent-fleet-display-test--with-aux-frames
      (dotimes (_ 3)
        (should (agent-fleet-display--outcome-opened-p
                 (agent-fleet-display--aux-run
                  (lambda () (agent-fleet-display-make-outcome t))))))
      (should (eq 'aux-child (gethash 'origin agent-fleet-display--aux-frames))))
    (should (= 1 agent-fleet-display-test--displayed))
    (should-not agent-fleet-display-test--deleted)
    (should (eq 'aux-child agent-fleet-display-test--current-frame))
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-display-aux-run-keeps-child-on-opened-nil-value ()
  "A nil domain value with `:opened' t keeps the child.
This is the Magit case: `magit-status' returns nil but the view opened.
Without the explicit outcome, the old truthiness check would close the
newly created child."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-display-test--current-frame 'origin)
        (agent-fleet-display-test--displayed 0)
        (agent-fleet-display-test--deleted nil))
    (agent-fleet-display-test--with-aux-frames
      (let ((outcome (agent-fleet-display--aux-run
                      (lambda ()
                        (agent-fleet-display-make-outcome t nil)))))
        (should (agent-fleet-display--outcome-opened-p outcome))))
    (should (eq 'aux-child agent-fleet-display-test--current-frame))
    (should-not agent-fleet-display-test--deleted)
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-display-aux-run-resizes-reused-child ()
  "A reused child receives the current full-parent size parameters.
This also repairs a live half-size auxiliary frame created before the
full-size presentation policy was loaded."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-display-test--current-frame 'origin)
        modified)
    (puthash 'origin 'aux-child agent-fleet-display--aux-frames)
    (agent-fleet-display-test--with-aux-frames
      (cl-letf (((symbol-function 'modify-frame-parameters)
                 (lambda (frame parameters)
                   (setq modified (cons frame parameters)))))
        (should (agent-fleet-display--outcome-opened-p
                 (agent-fleet-display--aux-run
                  (lambda () (agent-fleet-display-make-outcome t)))))))
    (should (eq 'aux-child (car modified)))
    (should (= 1.0 (alist-get 'width (cdr modified))))
    (should (= 1.0 (alist-get 'height (cdr modified))))))

(ert-deftest agent-fleet-display-aux-run-cleans-placeholder-after-split ()
  "Windows still showing the placeholder are deleted after the thunk opens.
Magit's `magit-status' splits the child's window instead of replacing
the placeholder; without cleanup the placeholder stays as an empty pane."
  (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
        (agent-fleet-display-test--current-frame 'origin)
        (agent-fleet-display-test--displayed 0)
        (agent-fleet-display-test--deleted nil)
        (deleted-windows nil))
    ;; The cl-letf* stubs run INSIDE the macro body so they override the
    ;; macro's own window-list stub.
    (agent-fleet-display-test--with-aux-frames
      (cl-letf* (((symbol-function 'window-list)
                  (lambda (&optional frame &rest _)
                    (when (eq frame 'aux-child)
                      (list 'real-win 'placeholder-win))))
                 ((symbol-function 'window-buffer)
                  (lambda (win)
                    (cond ((eq win 'placeholder-win)
                           (get-buffer-create agent-fleet-display--aux-buffer-name))
                          (t (get-buffer-create " *magit*")))))
                 ((symbol-function 'delete-window)
                  (lambda (win) (push win deleted-windows))))
        (should (agent-fleet-display--outcome-opened-p
                 (agent-fleet-display--aux-run
                  (lambda ()
                    (agent-fleet-display-make-outcome t)))))))
    ;; The placeholder window should be deleted; the real window kept.
    (should (memq 'placeholder-win deleted-windows))
    (should-not (memq 'real-win deleted-windows))
    (when (get-buffer agent-fleet-display--aux-buffer-name)
      (kill-buffer (get-buffer agent-fleet-display--aux-buffer-name)))
    (when (get-buffer " *magit*")
      (kill-buffer (get-buffer " *magit*")))
    (when (get-buffer " *agent-fleet-aux*")
      (kill-buffer (get-buffer " *agent-fleet-aux*")))))

(ert-deftest agent-fleet-display-aux-origin-frame-prevents-nesting ()
  "An auxiliary child never nests under another child frame.
An aux child opened from an aux child reuses its recorded origin; another
native child frame resolves to its parent."
  (cl-letf (((symbol-function 'selected-frame) (lambda () 'aux-child))
            ((symbol-function 'frame-parameter)
             (lambda (frame parameter)
               (and (eq frame 'aux-child)
                    (eq parameter 'agent-fleet-auxiliary-origin-frame)
                    'origin)))
            ((symbol-function 'frame-live-p)
             (lambda (frame) (memq frame '(origin aux-child)))))
    (should (eq 'origin (agent-fleet-display--aux-origin-frame))))
  (cl-letf (((symbol-function 'selected-frame) (lambda () 'native-child))
            ((symbol-function 'frame-parameter)
             (lambda (&rest _) nil))
            ((symbol-function 'frame-parent)
             (lambda (frame) (and (eq frame 'native-child) 'parent)))
            ((symbol-function 'frame-live-p)
             (lambda (frame) (memq frame '(parent native-child)))))
    (should (eq 'parent (agent-fleet-display--aux-origin-frame)))))

(ert-deftest agent-fleet-display-aux-forget-removes-from-reuse-table ()
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


(ert-deftest agent-fleet-display--quit-window-advice-is-installed ()
  "`quit-restore-window' is advised so auxiliary child frames close on q.
Installed by `agent-fleet-display--setup-frame-hooks'; the advice is
idempotent (a single member on the symbol)."
  (should (advice-member-p #'agent-fleet-display--aux-quit-restore-window
                            'quit-restore-window)))

(ert-deftest agent-fleet-display--quit-window-closes-aux-child ()
  "Quitting a view window closes the auxiliary child, not switch buffers.
`quit-restore-window' on a window inside an auxiliary child deletes the
child, forgets the reuse entry, and refocuses the origin.  The bury
variant leaves the view buffer alive; the kill variant kills it."
  (dolist (mode '(bury kill))
    (let ((agent-fleet-display--aux-frames (make-hash-table :test 'eq))
          (agent-fleet-display-test--current-frame 'aux-child)
          (agent-fleet-display-test--deleted nil)
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
                   (setq agent-fleet-display-test--deleted frame)))
                ((symbol-function 'select-frame-set-input-focus)
                 (lambda (frame)
                   (setq agent-fleet-display-test--current-frame frame))))
        (quit-restore-window nil mode))
      (should (eq 'aux-child agent-fleet-display-test--deleted))
      (should (eq 'origin agent-fleet-display-test--current-frame))
      (should-not (gethash 'origin agent-fleet-display--aux-frames))
      (if (eq mode 'kill)
          (should-not (buffer-live-p view-buf))
        (should (buffer-live-p view-buf))
        (kill-buffer view-buf)))))

(ert-deftest agent-fleet-display--quit-window-passes-through-ordinary-frames ()
  "Quitting a window on an ordinary frame keeps the default behavior."
  (let ((switched nil))
    (cl-letf (((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'switch-to-prev-buffer)
               (lambda (&rest _) (setq switched t) t)))
      (quit-restore-window nil 'bury))
    (should switched)))



(provide 'agent-fleet-display-test)
