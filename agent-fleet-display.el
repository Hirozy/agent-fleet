;;; agent-fleet-display.el --- Frame lifecycle for agent-fleet views -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The presentation lifecycle layer: child-frame capability checks,
;; frame parameter merging, parent resolution, centering and resize
;; tracking, and the auxiliary child-frame reuse/close contract.
;;
;; This module depends only on Emacs primitives.  It does NOT depend on
;; Magit, worktree, attach, the dashboard buffer, or any Herdr RPC.
;; Feature modules call `agent-fleet-display--aux-run' to open a view
;; in an auxiliary child frame; the dashboard calls the capability and
;; centering helpers for its own child-frame backend.

;;; Code:

(require 'cl-lib)
(require 'subr-x)


;;; --- Capability checks ----------------------------------------------

(defconst agent-fleet-display-child-frame-minimum-emacs-version "29.1"
  "Minimum Emacs version supported by native child frames.

The package itself requires this Emacs version, but the explicit feature
gate keeps child-frame creation safe when the file is loaded outside the
package manager or the package requirement changes independently later.")

(defun agent-fleet-display-child-frame-available-p (&optional parent-frame)
  "Return non-nil when a child frame can use PARENT-FRAME.

Availability requires Emacs
`agent-fleet-display-child-frame-minimum-emacs-version' or newer, a
graphical parent frame, and the native `display-buffer-in-child-frame'
action function.  PARENT-FRAME defaults to the selected frame."
  (and (version<= agent-fleet-display-child-frame-minimum-emacs-version
                  emacs-version)
       (fboundp 'display-buffer-in-child-frame)
       (display-graphic-p (or parent-frame (selected-frame)))))

(defun agent-fleet-display--child-frame-unavailable-reason
    (&optional parent-frame)
  "Explain why a child frame cannot use PARENT-FRAME, or return nil."
  (cond
   ((version< emacs-version
              agent-fleet-display-child-frame-minimum-emacs-version)
    (format "native child frames require Emacs %s or newer (running %s)"
            agent-fleet-display-child-frame-minimum-emacs-version
            emacs-version))
   ((not (fboundp 'display-buffer-in-child-frame))
    "this Emacs lacks display-buffer-in-child-frame")
   ((not (display-graphic-p (or parent-frame (selected-frame))))
    "native child frames require a graphical Emacs frame")))


;;; --- Frame parameters -----------------------------------------------

(defun agent-fleet-display--merge-frame-parameters (base overrides)
  "Return a copy of frame parameter alist BASE updated by OVERRIDES."
  (let ((parameters (copy-tree base)))
    (dolist (entry overrides)
      (setq parameters (assq-delete-all (car entry) parameters))
      (push (cons (car entry) (cdr entry)) parameters))
    parameters))


;;; --- Parent resolution ----------------------------------------------

(defun agent-fleet-display--parent-frame (&optional frame)
  "Return the native parent frame for FRAME, or FRAME itself.
A native child frame (one with a `frame-parent') resolves to that
parent; an ordinary or standalone frame is its own parent.  This is
the generic parent resolver used by the auxiliary child layer; the
dashboard has its own `agent-fleet-dashboard--child-parent-frame' that
also consults the backend registry."
  (let* ((frame (or frame (selected-frame)))
         (parent (frame-parent frame)))
    (if (frame-live-p parent) parent frame)))


;;; --- Centering and resize tracking ---------------------------------

(defvar agent-fleet-display--centered-children nil
  "Alist (CHILD-FRAME . PARENT-FRAME) for centered child frames.
Used by the parent-resize hook to re-center a child after its parent is
resized, since fractional `left'/`top' position parameters are not
reliably applied on every build.")

(defun agent-fleet-display--center-child-frame (frame parent)
  "Center child FRAME within PARENT in pixels.
The fractional `left'/`top' parameters should center a child frame per
the Emacs manual, but some builds (notably macOS) do not apply them at
creation.  Compute the center in pixels and call `set-frame-position'
explicitly so the child is reliably centered within its parent."
  (when (and (frame-live-p frame)
             (frame-live-p parent)
             (display-graphic-p parent))
    (let* ((pw (frame-pixel-width parent))
           (ph (frame-pixel-height parent))
           (cw (frame-pixel-width frame))
           (ch (frame-pixel-height frame))
           (left (max 0 (/ (- pw cw) 2)))
           (top  (max 0 (/ (- ph ch) 2))))
      (set-frame-position frame left top)
      (setf (alist-get frame agent-fleet-display--centered-children) parent))))

(defun agent-fleet-display--recenter-on-parent-resize (frame)
  "Re-center child frames whose parent is FRAME after it resizes."
  (when (and (display-graphic-p frame)
             agent-fleet-display--centered-children)
    (dolist (cell agent-fleet-display--centered-children)
      (let ((child (car cell))
            (parent (cdr cell)))
        (when (and (eq parent frame)
                   (frame-live-p child)
                   (or (eq (frame-parameter child 'agent-fleet-dashboard-display)
                           'child-frame)
                       (frame-parameter child 'agent-fleet-auxiliary-frame)))
          (agent-fleet-display--center-child-frame child parent))))))

(defun agent-fleet-display--forget-centered-child (frame)
  "Drop FRAME from the centered-children tracking when it is deleted."
  (setq agent-fleet-display--centered-children
        (assq-delete-all frame agent-fleet-display--centered-children)))


;;; --- Auxiliary child frame -----------------------------------------

;; An auxiliary child frame floats over an attached terminal's parent
;; frame so that opening output, worktree, or Magit views never resizes
;; the terminal window.  It is a distinct presentation surface from the
;; dashboard child frame: separate parameters and lifecycle metadata,
;; reused per origin, and never used as the dashboard display backend.

(defvar agent-fleet-display--aux-frame-parameters
  '((width . 1.0)
    (height . 1.0)
    (left . 0.5)
    (top . 0.5)
    (keep-ratio . t)
    (undecorated . t)
    (minibuffer . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (child-frame-border-width . 1)
    (no-other-frame . t)
    (agent-fleet-auxiliary-frame . t))
  "Frame parameters for an auxiliary child frame.
Unlike the compact dashboard, auxiliary interfaces fill their parent so
full-screen interfaces such as Magit do not open in a half-size surface.
`parent-frame' and the origin marker are merged on top at display time.")

(defvar agent-fleet-display--aux-frames (make-hash-table :test 'eq)
  "Hash table mapping an origin frame to its auxiliary child frame.
At most one auxiliary child exists per origin and is reused on repeated
opens.  Entries are forgotten when the child is deleted.")

(defconst agent-fleet-display--aux-buffer-name " *agent-fleet-aux*"
  "Name of the throwaway placeholder buffer shown in a new auxiliary child.
It is replaced by the view buffer once the presentation thunk runs, and
any window still showing it after the thunk is deleted so the child
contains only the view's own windows.")

(defun agent-fleet-display--aux-cleanup-placeholder (child)
  "Delete windows in CHILD that still show the placeholder buffer.
Third-party commands such as `magit-status' may split the child frame's
window instead of replacing the placeholder; without this cleanup the
placeholder stays visible as an empty pane alongside the real content."
  (when (frame-live-p child)
    (let* ((placeholder (get-buffer agent-fleet-display--aux-buffer-name))
           (windows (window-list child))
           (ph-windows (if placeholder
                           (cl-remove-if-not
                            (lambda (w) (eq (window-buffer w) placeholder))
                            windows)
                         nil)))
      ;; Only delete placeholder windows when there are other windows
      ;; to take their place; never delete the last window on the frame.
      (when (and ph-windows (> (length windows) (length ph-windows)))
        (dolist (w ph-windows)
          (ignore-errors (delete-window w)))))))

(defun agent-fleet-display--aux-origin-frame (&optional frame)
  "Return the non-child parent frame to own an auxiliary child for FRAME.
FRAME defaults to the selected frame.  An auxiliary child opened from
another auxiliary child reuses that child's recorded origin; a native
child frame resolves to its parent; an ordinary or standalone frame is
its own origin.  This prevents a child of a child."
  (let* ((frame (or frame (selected-frame)))
         (aux-origin (frame-parameter frame 'agent-fleet-auxiliary-origin-frame)))
    (cond
     ((and aux-origin (frame-live-p aux-origin)) aux-origin)
     (t (agent-fleet-display--parent-frame frame)))))

(defun agent-fleet-display--aux-frame-for-origin (origin)
  "Return the live auxiliary child frame for ORIGIN, or nil."
  (let ((child (gethash origin agent-fleet-display--aux-frames)))
    (and (frame-live-p child) child)))

(defun agent-fleet-display--aux-focus-origin (origin)
  "Return input focus to ORIGIN when it is a live frame."
  (when (frame-live-p origin)
    (select-frame-set-input-focus origin)))

(defun agent-fleet-display--aux-create (origin)
  "Create, register and return the auxiliary child frame for ORIGIN.
Display a placeholder buffer in a native child frame, stamp the origin
marker, center the child on ORIGIN, and select it so the caller's
display lands in it.  Signal a `user-error' when Emacs cannot create it."
  (let* ((private `((parent-frame . ,origin)
                    (agent-fleet-auxiliary-origin-frame . ,origin)))
         (parameters (agent-fleet-display--merge-frame-parameters
                      agent-fleet-display--aux-frame-parameters private))
         (buffer (get-buffer-create agent-fleet-display--aux-buffer-name)))
    (condition-case err
        (if-let* ((window (display-buffer
                           buffer
                           `((display-buffer-in-child-frame)
                             (child-frame-parameters . ,parameters)))))
            (let ((child (window-frame window)))
              (modify-frame-parameters child private)
              (select-frame-set-input-focus child)
              (agent-fleet-display--center-child-frame child origin)
              (puthash origin child agent-fleet-display--aux-frames)
              child)
          (user-error "agent-fleet: could not create a child frame"))
      (error
       (user-error "agent-fleet: child-frame creation failed: %s"
                   (error-message-string err))))))

(defun agent-fleet-display--aux-close (child)
  "Delete auxiliary CHILD, forget its reuse entry and refocus its origin."
  (let* ((origin (frame-parameter child 'agent-fleet-auxiliary-origin-frame))
         (mapped (and origin
                      (gethash origin agent-fleet-display--aux-frames))))
    (when (frame-live-p child)
      (delete-frame child))
    (when (and origin (eq mapped child))
      (remhash origin agent-fleet-display--aux-frames))
    (agent-fleet-display--aux-focus-origin origin)))

(defun agent-fleet-display--aux-forget (frame)
  "Forget FRAME from auxiliary reuse tracking when it is deleted."
  (when (frame-parameter frame 'agent-fleet-auxiliary-frame)
    (when-let* ((origin (frame-parameter
                         frame 'agent-fleet-auxiliary-origin-frame)))
      (let ((mapped (gethash origin agent-fleet-display--aux-frames)))
        (when (eq mapped frame)
          (remhash origin agent-fleet-display--aux-frames))))))

(defun agent-fleet-display--aux-quit-restore-window
    (orig &optional window bury-or-kill)
  "Around advice on `quit-restore-window' for auxiliary child frames.
Quitting a window whose frame is an auxiliary child closes that child —
delete it, forget the reuse entry, refocus its origin — instead of the
default behavior.  The default would not match the frame-deletion branch
of `quit-restore-window' (the recorded buffer is the placeholder the
child was created with, not the view buffer later swapped in) and would
switch the window to an unrelated buffer, leaving the child behind.
BURY-OR-KILL is still applied to the window's buffer afterwards.
Windows on any other frame pass through unchanged."
  (let* ((win (if (window-live-p window) window (selected-window)))
         (frame (window-frame win)))
    (if (frame-parameter frame 'agent-fleet-auxiliary-frame)
        (let ((buffer (window-buffer win)))
          (agent-fleet-display--aux-close frame)
          (when (buffer-live-p buffer)
            (cond ((eq bury-or-kill 'kill)
                   (kill-buffer buffer))
                  ((memq bury-or-kill '(bury burying))
                   (bury-buffer-internal buffer)))))
      (funcall orig window bury-or-kill))))

;;; --- View outcomes --------------------------------------------------

;; A view outcome is the internal protocol between a presentation thunk
;; and the aux runner / dashboard visitor.  It decouples lifecycle
;; decisions (keep or close the child frame) from the domain return
;; value, which may be nil even on success (e.g. `magit-status').

(defun agent-fleet-display--make-outcome (opened &optional value buffer)
  "Return a view outcome plist.
OPENED is non-nil when the view was established.  VALUE is the original
domain return value (may be nil).  BUFFER is the optional destination
buffer, for callers that want to inspect it."
  (list :opened (if opened t) :value value :buffer buffer))

(defun agent-fleet-display--outcome-opened-p (outcome)
  "Return non-nil if OUTCOME marks the view as opened.
A non-outcome value (a plain return from a thunk that has not been
migrated) is treated as opened when non-nil, for backward compatibility."
  (if (and (consp outcome) (eq (car outcome) :opened))
      (plist-get outcome :opened)
    outcome))

(defun agent-fleet-display--outcome-value (outcome)
  "Return OUTCOME's domain value, or nil."
  (if (and (consp outcome) (eq (car outcome) :opened))
      (plist-get outcome :value)
    outcome))

(defun agent-fleet-display--outcome-buffer (outcome)
  "Return OUTCOME's destination buffer, or nil."
  (if (and (consp outcome) (eq (car outcome) :opened))
      (plist-get outcome :buffer)
    nil))

(defun agent-fleet-display--aux-run (thunk)
  "Run THUNK in an auxiliary child frame and enforce its lifecycle.
Resolve the current origin to a non-child parent frame, ensure one
auxiliary child for it (creating and selecting it when absent), run
THUNK with that child selected, and apply the close contract:

- when the outcome's `:opened' is non-nil, keep the child and
  return the outcome;
- when `:opened' is nil and the child was newly created this call, delete
  it and refocus the origin (an empty new child must not linger);
- when `:opened' is nil but the child was reused, keep it and refocus it
  so the prior view stays coherent;
- when THUNK errors, delete a newly created child (or refocus a reused
  one) and re-signal the error.

A non-outcome return value is treated as opened when non-nil (backward
compat).  Signal a `user-error' when child frames are unsupported; an
explicit `-in-child-frame' command never falls back to an ordinary buffer."
  (let* ((origin (agent-fleet-display--aux-origin-frame))
         (reason (agent-fleet-display--child-frame-unavailable-reason origin)))
    (if reason
        (user-error "agent-fleet: %s" reason)
      (let* ((existing (agent-fleet-display--aux-frame-for-origin origin))
             (created-p (null existing))
             (child (or existing (agent-fleet-display--aux-create origin))))
        ;; Reapply presentation parameters when reusing a frame.  Besides
        ;; keeping live frames aligned with customization/reloads, this grows
        ;; auxiliary frames created by older versions that inherited the
        ;; dashboard's compact dimensions.
        (modify-frame-parameters child
                                 agent-fleet-display--aux-frame-parameters)
        (agent-fleet-display--center-child-frame child origin)
        (select-frame-set-input-focus child)
        (condition-case err
            (let* ((result (funcall thunk))
                   (opened (agent-fleet-display--outcome-opened-p result)))
              (when opened
                ;; Third-party commands (e.g. `magit-status') may split the
                ;; child's window instead of replacing the placeholder; remove
                ;; any placeholder windows so the child shows only real content.
                (agent-fleet-display--aux-cleanup-placeholder child))
              (cond
               ((and (not opened) created-p)
                (agent-fleet-display--aux-close child))
               ((not opened)
                (select-frame-set-input-focus child))
               (t
                (select-frame-set-input-focus child)))
              result)
          (error
           (if created-p
               (agent-fleet-display--aux-close child)
             (select-frame-set-input-focus child))
           (signal (car err) (cdr err))))))))


;;; --- Frame hooks ---------------------------------------------------

(defun agent-fleet-display--setup-frame-hooks ()
  "Install child-frame lifecycle callbacks as ordinary, idempotent hooks.
`remove-function' first undoes the erroneous function-composition form used
by an older release.  It leaves a proper hook list unchanged, so this also
repairs an already-running Emacs before `add-hook' installs the callbacks in
the normal representation."
  (remove-function (default-value 'window-size-change-functions)
                   #'agent-fleet-display--recenter-on-parent-resize)
  (remove-function (default-value 'delete-frame-functions)
                   #'agent-fleet-display--forget-centered-child)
  (remove-function (default-value 'delete-frame-functions)
                   #'agent-fleet-display--aux-forget)
  (advice-remove 'quit-restore-window
                 #'agent-fleet-display--aux-quit-restore-window)
  (add-hook 'window-size-change-functions
            #'agent-fleet-display--recenter-on-parent-resize)
  (add-hook 'delete-frame-functions
            #'agent-fleet-display--forget-centered-child)
  (add-hook 'delete-frame-functions
            #'agent-fleet-display--aux-forget)
  (advice-add 'quit-restore-window :around
              #'agent-fleet-display--aux-quit-restore-window))

(agent-fleet-display--setup-frame-hooks)

(provide 'agent-fleet-display)
;;; agent-fleet-display.el ends here
