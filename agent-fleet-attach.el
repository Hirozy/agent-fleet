;;; agent-fleet-attach.el --- interactive terminal attach for agent-fleet -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience, term
;; Version: 0.8.0
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You file should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The interactive-terminal layer (PLAN.md Phase 8, §43/§44/§45/§45.1/§73/§79).
;; Attaches live to a Herdr agent pane inside an Emacs terminal buffer, so the
;; user can drive the agent's real PTY/TUI without leaving Emacs:
;;
;;   (agent-fleet-attach "arch")           ; dashboard `a', or M-x
;;
;; Attach is NOT a socket RPC: there is no `agent.attach' method (§43).
;; `herdr agent attach <pane-id>' is a CLI helper that bridges a single live
;; pane as an interactive PTY client (§44 path A).  This layer spawns that
;; CLI inside a terminal backend (eat / ghostel / vterm) and pops the buffer.
;; Killing the process detaches; the agent is preserved (it is NOT closed).
;;
;;   Emacs terminal backend (eat/ghostel/vterm)
;;     ↓  PTY
;;   herdr agent attach <pane-id>
;;     ↓  socket
;;   Herdr server → one live agent pane
;;
;; Terminal backends are OPTIONAL dependencies (PLAN §45): the core control
;; plane works with none of them installed.  `agent-fleet-attach-backend'
;; defaults to `auto', which picks the first ready backend in preference
;; order (ghostel > eat > vterm > external).  ghostel is preferred (highest
;; rendering fidelity, §45.1) but only when its dynamic module is actually
;; loaded and current — a stale/older module leaves ghostel's terminal
;; functions void, so `auto' falls through to eat (pure Elisp, no module).
;; `external' (§44 path C) tells the user to run the attach CLI in their own
;; terminal when no Emacs backend is available.
;;
;; Security (PLAN §46/§23, unchanged): attach is user-initiated interactive
;; viewing — the terminal buffer is transient, NOT persisted or continuously
;; mirrored (same boundary as `agent-fleet-show-output''s read-snapshot).
;;
;; This file requires `agent-fleet' one-way; `agent-fleet.el' does NOT require
;; it, so there is no load cycle (mirrors `agent-fleet-worktree.el' /
;; `-magit.el' / `-parallel.el').  `agent-fleet-dashboard.el' requires it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-fleet)

;; Terminal backends are optional (PLAN §45): declare the public entry points
;; so the byte-compiler does not warn, without forcing a top-level `require'.
;; ghostel's module-backed functions (e.g. `ghostel-make-term') are NOT
;; declared here: they are probed at runtime via `fboundp' (a stale module
;; leaves them void), which is how `agent-fleet-attach--ghostel-ready-p' tells
;; a working ghostel from a lisp-only one.
(declare-function eat-exec "eat" (buffer name command startfile switches))
(declare-function eat-mode "eat" ())
(declare-function eat-kill-process "eat" ())
(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function vterm "vterm" (&optional arg))
;; Marked special (no value) so the byte-compiler treats a `let'-binding of
;; `vterm-shell' as dynamic, not lexical — vterm.el defines it as a defcustom,
;; but is an optional dep that may not be loaded at byte-compile time.  The
;; vterm launch reads `vterm-shell' dynamically via `sh -c "exec <vterm-shell>"'.
(defvar vterm-shell)


;;; --- Customizable backend + buffer naming ---------------------------

(defcustom agent-fleet-attach-backend 'auto
  "Terminal backend for `agent-fleet-attach' (PLAN §45/§73).
`auto' (default) picks the first ready backend in preference order:
ghostel (highest fidelity, §45.1) > eat (pure Elisp) > vterm > external.
An explicit symbol (`ghostel'/`eat'/`vterm'/`external') uses that backend
when ready, else `user-error's — an explicit unavailable choice is reported
rather than silently substituted (set `auto' for graceful fallback).
`external' is always ready: it prints the `herdr agent attach' command for
the user to run in their own terminal (§44 path C)."
  :type '(choice (const auto) (const ghostel) (const eat)
                 (const vterm) (const external))
  :group 'agent-fleet)

(defcustom agent-fleet-attach-buffer-prefix "*agent:"
  "Prefix for `agent-fleet-attach' buffer names (PLAN §73: `*agent:NAME*').
The buffer is named PREFIX<name>*; <name> is the agent's display name."
  :type 'string
  :group 'agent-fleet)

;; Preference order for `auto' (PLAN §45.1: ghostel preferred; §79: eat as the
;; reliable Elisp fallback; vterm next; external the floor).
(defconst agent-fleet-attach--backend-preference
  '(ghostel eat vterm external)
  "Backend probe order for `agent-fleet-attach-backend' = `auto'.")


;;; --- Backend readiness (the §45.1 stale-module guard) --------------

(defun agent-fleet-attach--ghostel-ready-p ()
  "Return non-nil if ghostel is loaded AND its dynamic module is working.
ghostel's lisp can `require' successfully while the module-backed terminal
functions stay void — this happens when the on-disk module is older than the
lisp requires.  The `fboundp' check on a module function distinguishes a
working ghostel from a lisp-only one, so `auto' falls through to eat rather
than calling a `ghostel-exec' that would fail at runtime (PLAN §45.1)."
  (and (require 'ghostel nil t)
       (fboundp 'ghostel-make-term)))

(defun agent-fleet-attach--eat-ready-p ()
  "Return non-nil if Eat is loaded or loadable (pure Elisp, no module)."
  (or (featurep 'eat) (require 'eat nil t)))

(defun agent-fleet-attach--vterm-ready-p ()
  "Return non-nil if vterm is loaded or loadable."
  (or (featurep 'vterm) (require 'vterm nil t)))

(defun agent-fleet-attach--ready-p (backend)
  "Return non-nil if BACKEND is usable in this Emacs."
  (pcase backend
    ('ghostel (agent-fleet-attach--ghostel-ready-p))
    ('eat     (agent-fleet-attach--eat-ready-p))
    ('vterm   (agent-fleet-attach--vterm-ready-p))
    ('external t)
    (_ nil)))

(defun agent-fleet-attach--pick-backend ()
  "Return the backend symbol to use, honoring `agent-fleet-attach-backend'.
For `auto', the first ready backend in `agent-fleet-attach--backend-preference'
(`external' is the floor, so `auto' always yields a backend).  For an explicit
symbol, that backend if ready, else `user-error' (report an explicit
unavailable choice rather than silently substituting)."
  (let ((choice agent-fleet-attach-backend))
    (cond
     ((eq choice 'auto)
      (cl-some (lambda (b) (and (agent-fleet-attach--ready-p b) b))
               agent-fleet-attach--backend-preference))
     ((agent-fleet-attach--ready-p choice) choice)
     (t (user-error
         "Attach backend `%s' is not available; set \
`agent-fleet-attach-backend' to `auto' or install the package" choice)))))


;;; --- Buffer name, argv, live-buffer probe (testable core) -----------

(defun agent-fleet-attach--buffer-name (name)
  "Return the attach buffer name for agent display NAME (PLAN §73)."
  (concat agent-fleet-attach-buffer-prefix name "*"))

(defun agent-fleet-attach--argv (pane-id takeover)
  "Build the `herdr agent attach' argv for PANE-ID.
TAKEOVER (non-nil) appends `--takeover'.  The leading `agent' and `attach'
are subcommand words, not the program (the program `herdr' is supplied by
the backend launch)."
  (append (list "agent" "attach" pane-id)
          (and takeover '("--takeover"))))

(defun agent-fleet-attach--live-buffer-p (buf-name)
  "Return non-nil if BUF-NAME is a live attach buffer (process alive).
Reused instead of double-attaching an agent that already has an open session."
  (when-let* ((buf (get-buffer buf-name)))
    (with-current-buffer buf
      (let ((proc (get-buffer-process buf)))
        (and proc (processp proc)
             (memq (process-status proc) '(run stop open connect)))))))


;;; --- Spawn (backend dispatch) ---------------------------------------

(defun agent-fleet-attach--spawn (backend buf-name pane-id takeover)
  "Spawn `herdr agent attach PANE-ID' in BUF-NAME via BACKEND.
TAKEOVER (non-nil) adds `--takeover'.  Pops the buffer so the user can drive
the live terminal.  No output is persisted (§46/§23): the buffer is a
transient interactive view; killing the process detaches and preserves the
agent (PLAN §79)."
  (let ((argv (agent-fleet-attach--argv pane-id takeover)))
    (pcase backend
      ('eat
       (with-current-buffer (get-buffer-create buf-name)
         (eat-mode)
         (eat-exec buf-name "herdr-attach" "herdr" nil argv))
       (pop-to-buffer buf-name))
      ('ghostel
       (ghostel-exec buf-name "herdr" argv)
       (pop-to-buffer buf-name))
      ('vterm
       ;; vterm has no argv launch API: it runs `vterm-shell' via
       ;; `sh -c "...; exec <vterm-shell>"', so a command string is parsed
       ;; by the shell.  Build it as a quoted shell command.
       (let ((vterm-shell (mapconcat
                           #'shell-quote-argument
                           (append '("herdr") argv) " ")))
         (vterm buf-name))
       (pop-to-buffer buf-name))
      ('external
       (user-error
        "No Emacs terminal backend found (install eat, ghostel, or vterm).  \
Run in your terminal: herdr agent attach %s%s"
        pane-id (if takeover " --takeover" "")))
      (_ (error "Unknown attach backend %S" backend)))))


;;; --- Attach command (dashboard `a', or M-x) -------------------------

;;;###autoload
(defun agent-fleet-attach (target &optional takeover)
  "Attach interactively to TARGET's terminal via `herdr agent attach' (§73).
TARGET is an agent name, pane id, symbol, or `herdr-agent' struct, resolved
to a real pane id.  Spawns the attach CLI inside the chosen terminal backend
(`agent-fleet-attach-backend', default `auto') in a `*agent:NAME*' buffer and
pops it so the live agent PTY/TUI can be driven from Emacs.  If a live attach
buffer for the agent already exists, reuses it instead of double-attaching.

This is a live interactive session, NOT a persisted or mirrored view (§46/§23):
the buffer is transient; killing the process detaches and the agent is
preserved (PLAN §79 — detach does NOT close the pane).  With a prefix arg
\(TAKEOVER), passes `--takeover' to the attach CLI.

No socket RPC is involved: there is no `agent.attach' method (§43); this is a
client-side PTY bridge over the `herdr' CLI.  `user-error's if no backend is
available (set `agent-fleet-attach-backend' to `external' for the command text)."
  (interactive (list (agent-fleet--read-agent-name "Attach to agent")
                     current-prefix-arg))
  (agent-fleet--ensure-connected)
  (let* ((struct (or (agent-fleet--find-agent target)
                     (signal 'agent-fleet-target-not-found
                             (list :agent target))))
         (pane-id (agent-fleet--resolve-pane-id struct))
         (name (herdr-agent-display-name struct))
         (buf-name (agent-fleet-attach--buffer-name name))
         (backend (agent-fleet-attach--pick-backend)))
    (if (agent-fleet-attach--live-buffer-p buf-name)
        (pop-to-buffer buf-name)
      (agent-fleet-attach--spawn backend buf-name pane-id takeover))))

(provide 'agent-fleet-attach)
;;; agent-fleet-attach.el ends here
