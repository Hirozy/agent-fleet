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

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The interactive-terminal layer.
;; Attaches live to a Herdr agent pane inside an Emacs terminal buffer, so the
;; user can drive the agent's real PTY/TUI without leaving Emacs:
;;
;;   (agent-fleet-attach "arch")           ; dashboard `a', or M-x
;;
;; Attach is NOT a socket RPC: there is no `agent.attach' method.
;; `herdr agent attach <pane-id>' is a CLI helper that bridges a single live
;; pane as an interactive PTY client (path A).  This layer spawns that
;; CLI inside the ghostel terminal backend and pops the buffer.
;; Killing the process detaches; the agent is preserved (it is NOT closed).
;;
;;   ghostel terminal backend
;;     ↓  PTY
;;   herdr agent attach <pane-id>
;;     ↓  socket
;;   Herdr server → one live agent pane
;;
;; ghostel is an OPTIONAL dependency: the core control plane works
;; without it installed.  `agent-fleet-attach-backend' defaults to `auto',
;; which uses ghostel when its dynamic module is actually loaded and current
;; — a stale/older module leaves ghostel's terminal functions void, so `auto'
;; yields no backend rather than calling a `ghostel-exec' that would crash.
;; When ghostel is not available, attach reports the `herdr agent attach'
;; command to run in the user's own terminal.
;;
;; Security: attach is user-initiated interactive
;; viewing — the terminal buffer is transient, NOT persisted or continuously
;; mirrored (same boundary as the output view's read-snapshot).
;;
;; This feature module requires the provided `agent-fleet' control feature;
;; the package entry point loads it through `agent-fleet-dashboard' after
;; providing that feature, so the dependency graph has no load cycle.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-fleet)
(require 'transient)

;; ghostel is an optional backend: declare its public entry
;; point so the byte-compiler does not warn, without forcing a top-level
;; `require'.  `ghostel-exec' is what `--spawn' calls; the working-module
;; probe lives in `agent-fleet-attach--ghostel-ready-p'.
(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function ghostel-send-key "ghostel" (key-name &optional mods))
;; Presentation-variant commands the leaves below dispatch to.  The Magit
;; and Worktree variants live in their optional feature modules (loaded
;; lazily by the leaves); the output child-frame variant lives in the
;; dashboard (loaded lazily); the output buffer variant lives in the
;; already-required `agent-fleet' base, so it needs no declaration.  Each
;; is declared here so `agent-fleet-attach' byte-compiles without a top-level
;; `require' of these modules.
(declare-function agent-fleet-show-output-in-child-frame
                  "agent-fleet-dashboard" (agent &optional lines source))
(declare-function agent-fleet-magit-status-in-buffer
                  "agent-fleet-magit" (target))
(declare-function agent-fleet-magit-status-in-child-frame
                  "agent-fleet-magit" (target))
(declare-function agent-fleet-magit-diff-in-buffer
                  "agent-fleet-magit" (target))
(declare-function agent-fleet-magit-diff-in-child-frame
                  "agent-fleet-magit" (target))
(declare-function agent-fleet-worktree-status-in-buffer
                  "agent-fleet-worktree" (target))
(declare-function agent-fleet-worktree-status-in-child-frame
                  "agent-fleet-worktree" (target))
;; Auxiliary child-frame lifecycle (agent-fleet-display).  Loaded lazily so
;; the command-map leaves can byte-compile without a top-level require.
(declare-function agent-fleet-display--aux-run "agent-fleet-display" (thunk &optional parameters))
(declare-function agent-fleet-display--aux-close "agent-fleet-display" (child))
(declare-function agent-fleet-display--make-outcome "agent-fleet-display" (opened &optional value buffer))
;; text-mode-map is loaded on demand by (text-mode); declared here so the
;; compose keymap byte-compiles without a top-level require.
(defvar text-mode-map)
;; Optional evil-escape dependency.  Its global pre-command hook consults
;; this variable dynamically, so a buffer-local value can safely protect an
;; attach terminal without loading evil-escape or changing the user's global
;; configuration.
(defvar evil-escape-inhibit nil)

(defvar-local agent-fleet-attach-pane-id nil
  "Pane id owned by the current attach terminal buffer.")

(defvar-local agent-fleet-attach--compose-pane-id nil
  "Pane id the compose buffer should send its text to.
Set buffer-locally on the compose buffer so the submit key can
route the prompt to the right agent.")


;;; --- Customizable backend + buffer naming ---------------------------

(defcustom agent-fleet-attach-backend 'auto
  "Terminal backend for `agent-fleet-attach'.
`auto' (default) uses ghostel when its dynamic module is loaded and
current.  An explicit `ghostel' uses that backend when ready, else
`user-error's (set `auto' for graceful fallback).  When ghostel is not
ready, `agent-fleet-attach' reports the `herdr agent attach' command to
run in the user's own terminal."
  :type '(choice (const auto) (const ghostel))
  :group 'agent-fleet)

(defcustom agent-fleet-attach-buffer-prefix "*agent:"
  "Prefix for `agent-fleet-attach' buffer names.
The buffer is named PREFIX<name>*; <name> is the agent's display name."
  :type 'string
  :group 'agent-fleet)

(defcustom agent-fleet-attach-inhibit-evil-escape t
  "Whether attach buffers inhibit `evil-escape' locally.
`evil-escape' probes the first key of its escape sequence by running
`self-insert-command' from `pre-command-hook'.  Terminal modes such as
Ghostel forward that synthetic insertion to the PTY and then forward the
real key command too, so a sequence beginning with `j' makes a plain `j'
arrive twice.  A non-nil value prevents that input corruption in attach
buffers only; the user's global Evil/evil-escape configuration is unchanged.

While inhibited, the configured escape sequence is sent literally to the
attached terminal.  Use the terminal backend's normal ESC/Evil integration
when an escape is needed.  Set this to nil only when the installed terminal
and evil-escape integration is known to avoid synthetic insertion."
  :type 'boolean
  :group 'agent-fleet)

(defcustom agent-fleet-attach-compose-frame-scale 0.5
  "Child-frame scale for the compose prompt (C-g).
A fraction of the parent frame's width and height.  The compose frame
defaults to half-size so it does not cover the whole terminal; other
auxiliary views (output, diff, Magit) keep the full-fill default."
  :type 'number
  :group 'agent-fleet)

;; `auto' probes only ghostel; when its module is not ready,
;; `auto' yields nil and the attach command reports the CLI instead.
(defconst agent-fleet-attach--backend-preference
  '(ghostel)
  "Backend probe order for `agent-fleet-attach-backend' = `auto'.")


;;; --- Backend readiness (the stale-module guard) --------------

(defun agent-fleet-attach--ghostel-ready-p ()
  "Return non-nil if ghostel is loaded AND its dynamic module is working.
The ghostel lisp can load fine while the dynamic module fails to load (an
older/broken on-disk module, or a missing libghostty-vt dependency): at
ghostel.el load time the module loader calls module-load, which provides
the ghostel-module feature ONLY on success.  So checking that feature is
the staleness signal — nil when the lisp loaded but the module did not
take.  This lets `auto' yield no backend rather than calling `ghostel-exec'
when it would crash at runtime (the module-dependency risk, realized
in some dev envs)."
  (and (require 'ghostel nil t)
       (featurep 'ghostel-module)
       (fboundp 'ghostel-exec)))

(defun agent-fleet-attach--ready-p (backend)
  "Return non-nil if BACKEND is usable in this Emacs."
  (pcase backend
    ('ghostel (agent-fleet-attach--ghostel-ready-p))
    (_ nil)))

(defun agent-fleet-attach--pick-backend ()
  "Return the backend symbol to use, honoring `agent-fleet-attach-backend'.
For `auto', return the first ready backend in
`agent-fleet-attach--backend-preference', or nil when none is ready
(the caller reports the attach command then).  For an explicit symbol,
that backend if ready, else `user-error' (report an explicit unavailable
choice rather than silently substituting)."
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
  "Return the attach buffer name for agent display NAME."
  (concat agent-fleet-attach-buffer-prefix name "*"))

(defun agent-fleet-attach--buffer-name-for-pane (name pane-id)
  "Return a collision-safe attach buffer name for NAME and PANE-ID.
Keep the documented `*agent:NAME*' name when it is unused or already
belongs to PANE-ID.  If another pane owns it, add the stable pane id so two
unnamed agents with the same workspace-derived display name cannot reuse
each other's live terminal."
  (let* ((base (agent-fleet-attach--buffer-name name))
         (buf (get-buffer base))
         (owner (and buf
                     (buffer-local-value 'agent-fleet-attach-pane-id buf))))
    (if (and buf (not (equal owner pane-id)))
        (agent-fleet-attach--buffer-name
         (format "%s [%s]" name pane-id))
      base)))

(defun agent-fleet-attach--argv (pane-id takeover)
  "Build the `herdr agent attach' argv for PANE-ID.
TAKEOVER (non-nil) appends `--takeover'.  The leading `agent' and `attach'
are subcommand words, not the program (the program `herdr' is supplied by
the backend launch)."
  (append (list "agent" "attach" pane-id)
          (and takeover '("--takeover"))))

(defun agent-fleet-attach--live-buffer-p (buf-name &optional pane-id)
  "Return non-nil if BUF-NAME is a live attach buffer for PANE-ID.
When PANE-ID is nil only process liveness is checked.  With PANE-ID, the
buffer-local owner must match, preventing same-display-name agents from
being cross-attached."
  (when-let* ((buf (get-buffer buf-name)))
    (with-current-buffer buf
      (let ((proc (get-buffer-process buf)))
        (and (or (null pane-id)
                 (equal agent-fleet-attach-pane-id pane-id))
             proc (processp proc)
             (memq (process-status proc) '(run stop open connect)))))))

(defun agent-fleet-attach--live-buffer-for-pane (pane-id)
  "Return the live attach buffer owned by PANE-ID, or nil.
Attach buffer names are display labels and can change after an agent rename or
when a same-label collision disappears.  The pane id is the stable identity,
so scan buffer-local ownership before deriving a fresh name; otherwise a live
disambiguated/old-name attach can be duplicated under a new base name."
  (cl-find-if
   (lambda (buffer)
     (agent-fleet-attach--live-buffer-p (buffer-name buffer) pane-id))
   (buffer-list)))

(defun agent-fleet-attach--prepare-buffer (buffer &optional pane-id)
  "Apply attach-specific input safeguards and action keymap to BUFFER.
BUFFER may be a buffer or its name.  The terminal backend must initialize its
major mode before this runs, because changing major mode clears buffer-local
variables.  When PANE-ID is non-nil, owns it buffer-locally and syncs
`default-directory' to the agent's cached cwd so directory-aware commands
\(M-x magit-status, etc.) resolve correctly even when the agent process
does not emit OSC 7; either way, enables `agent-fleet-attach-mode' so the
`C-c C-a' prefix keys act on the pane id owned by this buffer.  Returns
BUFFER."
  (when-let* ((buf (get-buffer buffer)))
    (with-current-buffer buf
      (when pane-id
        (setq-local agent-fleet-attach-pane-id pane-id)
        ;; Sync default-directory to the agent's cached cwd.  Many agent
        ;; CLIs (Claude Code) do not emit OSC 7, so ghostel never updates
        ;; default-directory from the terminal side; without this, M-x
        ;; magit-status and similar commands in the attach buffer resolve
        ;; to the wrong directory.  A later OSC 7 (if any) still wins.
        (when-let* ((agent (agent-fleet--find-agent pane-id))
                    (cwd (herdr-agent-cwd agent))
                    ((and (stringp cwd)
                          (not (string-empty-p cwd))
                          (file-directory-p cwd))))
          (setq-local default-directory
                      (file-name-as-directory (file-truename cwd)))))
      (if agent-fleet-attach-inhibit-evil-escape
          (setq-local evil-escape-inhibit t)
        (kill-local-variable 'evil-escape-inhibit))
      (agent-fleet-attach-mode 1))
    buf))


;;; --- Presentation (same-window display) -----------------------------

(defun agent-fleet-attach--display (buffer)
  "Display BUFFER in the selected window, replacing its contents.
An attach buffer is the surface for driving a live agent terminal, so it
takes over the current window rather than splitting the frame — the
terminal fills the window the user just acted from.  Every attach entry
point (`M-x agent-fleet-attach', the dashboard `a' key, and the
auto-attach after `agent-fleet-start') goes through here, so they all
present the same way.  A dedicated selected window is replaced directly
and remains dedicated to the attach buffer; no display fallback may create
a split or resize another terminal window."
  (let* ((window (selected-window))
         (dedicated (window-dedicated-p window)))
    (when dedicated
      (set-window-dedicated-p window nil))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          window)
      (when (window-live-p window)
        (set-window-dedicated-p window dedicated)))))

;;; --- Spawn (backend dispatch) ---------------------------------------

(defun agent-fleet-attach--spawn (backend buf-name pane-id takeover)
  "Spawn `herdr agent attach PANE-ID' in BUF-NAME via BACKEND.
TAKEOVER (non-nil) adds `--takeover'.  Pops the buffer so the user can drive
the live terminal.  No output is persisted: the buffer is a
transient interactive view; killing the process detaches and preserves the
agent; detaching never closes the pane."
  (let ((argv (agent-fleet-attach--argv pane-id takeover)))
    (pcase backend
      ('ghostel
       ;; Unlike the interactive `ghostel' entry point, `ghostel-exec'
       ;; requires BUFFER to exist already (`with-current-buffer' is its
       ;; first operation).  Pass the buffer object as well, so a missing
       ;; BUF-NAME cannot surface as "No buffer named ...".
       (let ((buffer (get-buffer-create buf-name)))
         (ghostel-exec buffer "herdr" argv)
         (agent-fleet-attach--prepare-buffer buffer pane-id)
         (agent-fleet-attach--display buffer)))
      (_ (error "Unknown attach backend %S" backend)))))


;;; --- Attach command (dashboard `a', or M-x) -------------------------

;;;###autoload
(defun agent-fleet-attach (target &optional takeover)
  "Attach interactively to TARGET's terminal via `herdr agent attach'.
TARGET is an agent name, pane id, symbol, or `herdr-agent' struct, resolved
to a real pane id.  Spawns the attach CLI inside the chosen terminal backend
(`agent-fleet-attach-backend', default `auto') in a `*agent:NAME*' buffer and
displays it in the selected window (replacing its contents) so the live
agent PTY/TUI can be driven from Emacs.  If a live attach buffer for the
agent already exists, reuses it instead of double-attaching.

This is a live interactive session, NOT a persisted or mirrored view:
the buffer is transient; killing the process detaches and the agent is
preserved; detaching does not close the pane.  With a prefix arg
\(TAKEOVER), passes `--takeover' to the attach CLI.

No socket RPC is involved: there is no `agent.attach' method; this is a
client-side PTY bridge over the `herdr' CLI.  If no Emacs terminal backend is
ready, `user-error's with the `herdr agent attach' command to run in the
user's own terminal."
  (interactive (list (agent-fleet--read-agent-name "Attach to agent")
                     current-prefix-arg))
  (agent-fleet--ensure-connected)
  (let* ((struct (or (agent-fleet--find-agent target)
                     (signal 'agent-fleet-target-not-found
                             (list :agent target))))
         (pane-id (agent-fleet--resolve-pane-id struct))
         (name (herdr-agent-display-name struct))
         (existing (agent-fleet-attach--live-buffer-for-pane pane-id))
         (buf-name (if existing
                       (buffer-name existing)
                     (agent-fleet-attach--buffer-name-for-pane name pane-id)))
         (backend (agent-fleet-attach--pick-backend)))
    (if (agent-fleet-attach--live-buffer-p buf-name pane-id)
        (progn
          ;; Also repair attach buffers created before this safeguard was
          ;; added, or buffers whose local value was changed after spawning.
          (agent-fleet-attach--prepare-buffer buf-name pane-id)
          (agent-fleet-attach--display buf-name))
      (if backend
          (agent-fleet-attach--spawn backend buf-name pane-id takeover)
        (user-error
         "No Emacs terminal backend found (install ghostel).  \
Run in your terminal: herdr agent attach %s%s"
         pane-id (if takeover " --takeover" ""))))))

;;; --- Current-agent actions (attach buffer keymap + transient) -------
;;
;; An attach buffer already owns the pane id it drives
;; (`agent-fleet-attach-pane-id').  These leaf commands act on that agent
;; directly -- no `agent-fleet--read-agent-name' selection prompt -- mirroring
;; the dashboard at-point commands (agent-fleet-dashboard.el) but scoped to
;; the buffer's own agent.  They live under a `C-c C-a' prefix: ghostel
;; reserves plain keys for the PTY in char mode, and `C-c' is in
;; `ghostel-keymap-exceptions' so it reaches Emacs; the prefix avoids
;; ghostel's own `C-c C-c' and `C-c C-z'.

(defun agent-fleet-attach--current-pane-id ()
  "Return the pane id of the agent this attach buffer is driving, or signal.
Signals `user-error' when not in an attach buffer (no buffer-local
`agent-fleet-attach-pane-id'), so the leaf commands fail fast instead of
acting on nil."
  (or agent-fleet-attach-pane-id
      (user-error "Not in an agent-fleet attach buffer")))

(defun agent-fleet-attach-inspect-in-child-frame (&optional lines)
  "Show this buffer's agent output as a read snapshot in an auxiliary child frame.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.  With a
prefix arg, prompt for the line count; otherwise the default
`agent-fleet-default-read-lines' is used.  Signal a `user-error' when
child frames are unsupported; there is no silent buffer fallback (use
`agent-fleet-attach-inspect-in-buffer' for that)."
  (interactive "P")
  (require 'agent-fleet-display nil t)
  (let ((pane-id (agent-fleet-attach--current-pane-id)))
    (agent-fleet-show-output-in-child-frame pane-id
                             (and lines
                                  (read-number "Lines: "
                                               agent-fleet-default-read-lines)))))

(defun agent-fleet-attach-inspect-in-buffer (&optional lines)
  "Show this buffer's agent output as a read snapshot in an ordinary buffer.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.  With a
prefix arg, prompt for the line count; otherwise the default
`agent-fleet-default-read-lines' is used."
  (interactive "P")
  (let ((pane-id (agent-fleet-attach--current-pane-id)))
    (agent-fleet-show-output-in-buffer pane-id
                             (and lines
                                  (read-number "Lines: "
                                               agent-fleet-default-read-lines)))))

(defun agent-fleet-attach-prompt ()
  "Send a one-shot prompt to the agent this buffer drives.
Reads the text with `read-string' and sends it via `agent-fleet-prompt'.
Acts on the pane id owned by this buffer, so no selection prompt is needed."
  (interactive)
  (let ((pane-id (agent-fleet-attach--current-pane-id))
        (text (read-string "Prompt: ")))
    (unless (string-empty-p text)
      (agent-fleet-prompt pane-id text))))

(defun agent-fleet-attach-prompt-in-child-frame ()
  "Open a child frame to compose a prompt for this buffer's agent.
In the ghostel terminal, C-g normally reaches the CLI tool which
launches $EDITOR.  When this command is bound to C-g (the default
in `agent-fleet-attach-mode-map'), it intercepts the key before it
reaches the PTY: instead of an external editor, an auxiliary child
frame with a text buffer opens for composing a multi-line prompt.
C-c C-c pastes the text into the terminal (bracketed paste) and
closes the frame; the user then presses Enter to submit.  C-c C-k
closes without pasting.  Acts on the pane id owned by this buffer,
so no selection prompt is needed."
  (interactive)
  (require 'agent-fleet-display nil t)
  ;; ghostel sets inhibit-quit t in terminal buffers, so C-g sets
  ;; quit-flag instead of running keyboard-quit.  Clear it so our
  ;; command runs uninterrupted.
  (setq quit-flag nil)
  (let* ((pane-id (agent-fleet-attach--current-pane-id))
         (scale agent-fleet-attach-compose-frame-scale)
         (agent (agent-fleet--find-agent pane-id))
         (name (or (and agent (herdr-agent-display-name agent)) pane-id)))
    (agent-fleet-display--aux-run
     (lambda ()
       (let ((buf (get-buffer-create "*agent-fleet-compose*")))
         (with-current-buffer buf
           (erase-buffer)
           (text-mode)
           (use-local-map (agent-fleet-attach--compose-map))
           (setq-local agent-fleet-attach--compose-pane-id pane-id)
           (setq-local header-line-format
                       (concat "  Compose prompt: "
                               (propertize name 'face 'bold)
                               (propertize
                                "  —  C-c C-c paste · C-c C-k abort"
                                'face 'shadow))))
         (set-window-buffer nil buf))
       (agent-fleet-display--make-outcome t))
     (list (cons 'width scale)
           (cons 'height scale)
           (cons 'name (format "agent-fleet compose: %s" name))))))

(defun agent-fleet-attach--compose-map ()
  "Return a keymap for the compose buffer.
Layered on top of `text-mode-map' so all standard editing keys work;
adds C-c C-c (submit) and C-c C-k (abort)."
  (make-composed-keymap
   (define-keymap
     "C-c C-c" #'agent-fleet-attach--compose-submit
     "C-c C-k" #'agent-fleet-attach--compose-abort)
   text-mode-map))

(defun agent-fleet-attach--compose-submit ()
  "Paste the composed text into the terminal and close the child frame.
Pastes the text into the agent's ghostel terminal via bracketed paste
(so multi-line prompts stay atomic) but does NOT press Enter — the
user reviews the text and presses Enter manually to submit."
  (interactive)
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (pane-id agent-fleet-attach--compose-pane-id)
        (frame (selected-frame)))
    (agent-fleet-display--aux-close frame)
    (when (and pane-id (not (string-empty-p (string-trim text))))
      (when-let* ((buf (agent-fleet-attach--live-buffer-for-pane pane-id)))
        (with-current-buffer buf
          (ghostel-paste-string text))))))

(defun agent-fleet-attach--compose-abort ()
  "Close the compose child frame without sending."
  (interactive)
  (agent-fleet-display--aux-close (selected-frame)))

(defun agent-fleet-attach-send-keys ()
  "Send key notation to the agent this buffer drives.
Reads a key string (such as \"ctrl+c\", \"enter\", or \"esc\") and delegates
to `agent-fleet-send-keys'.  Acts on the pane id owned by this buffer, so
no selection prompt is needed."
  (interactive)
  (let ((pane-id (agent-fleet-attach--current-pane-id))
        (keys (read-string "Keys: ")))
    (unless (string-empty-p keys)
      (agent-fleet-send-keys pane-id keys))))

(defun agent-fleet-attach-interrupt ()
  "Send Ctrl-C to the agent this buffer drives.
Delegates to `agent-fleet-interrupt'.  Acts on the pane id owned by this
buffer, so no selection prompt is needed."
  (interactive)
  (agent-fleet-interrupt (agent-fleet-attach--current-pane-id)))

(defun agent-fleet-attach-kill ()
  "Kill the agent this buffer drives by closing its pane.
Asks for confirmation first, then delegates to `agent-fleet-kill'.  Acts on
the pane id owned by this buffer, so no selection prompt is needed."
  (interactive)
  (let ((pane-id (agent-fleet-attach--current-pane-id)))
    (when (y-or-n-p (format "Kill agent %s? " pane-id))
      (agent-fleet-kill pane-id))))

(defun agent-fleet-attach-rename ()
  "Rename the agent this buffer drives.
Reads the new name with `read-string' (defaulting to the current display
name) and delegates to `agent-fleet-rename'.  Acts on the pane id owned by
this buffer, so no selection prompt is needed."
  (interactive)
  (let* ((pane-id (agent-fleet-attach--current-pane-id))
         (cur (let ((a (agent-fleet--find-agent pane-id)))
                (or (and a (herdr-agent-display-name a)) pane-id)))
         (name (read-string "New name: " cur)))
    (unless (or (null name) (string-empty-p name))
      (agent-fleet-rename pane-id name))))

(defun agent-fleet-attach-diff-in-child-frame ()
  "Show this buffer's agent working-tree diff in an auxiliary child frame.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.  Signal a
`user-error' when child frames are unsupported; there is no silent buffer
fallback (use `agent-fleet-attach-diff-in-buffer' for that).  `user-error's
if Magit is not installed."
  (interactive)
  (require 'agent-fleet-magit nil t)
  (agent-fleet-magit-diff-in-child-frame
   (agent-fleet-attach--current-pane-id)))

(defun agent-fleet-attach-diff-in-buffer ()
  "Show this buffer's agent working-tree diff in an ordinary buffer.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.
`user-error's if Magit is not installed."
  (interactive)
  (require 'agent-fleet-magit nil t)
  (agent-fleet-magit-diff-in-buffer
   (agent-fleet-attach--current-pane-id)))

(defun agent-fleet-attach-magit-in-child-frame ()
  "Open Magit status for this buffer's agent in an auxiliary child frame.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.  Signal a
`user-error' when child frames are unsupported; there is no silent buffer
fallback (use `agent-fleet-attach-magit-in-buffer' for that).  `user-error's
if Magit is not installed."
  (interactive)
  (require 'agent-fleet-magit nil t)
  (agent-fleet-magit-status-in-child-frame
   (agent-fleet-attach--current-pane-id)))

(defun agent-fleet-attach-magit-in-buffer ()
  "Open Magit status for this buffer's agent in an ordinary buffer.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.
`user-error's if Magit is not installed."
  (interactive)
  (require 'agent-fleet-magit nil t)
  (agent-fleet-magit-status-in-buffer
   (agent-fleet-attach--current-pane-id)))

(defun agent-fleet-attach-worktree-in-child-frame ()
  "Show this buffer's agent worktree status in an auxiliary child frame.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.  Signal a
`user-error' when child frames are unsupported; there is no silent buffer
fallback (use `agent-fleet-attach-worktree-in-buffer' for that)."
  (interactive)
  (require 'agent-fleet-worktree nil t)
  (agent-fleet-worktree-status-in-child-frame
   (agent-fleet-attach--current-pane-id)))

(defun agent-fleet-attach-worktree-in-buffer ()
  "Show this buffer's agent worktree status in an ordinary buffer.
Acts on the agent whose terminal this buffer drives
(`agent-fleet-attach-pane-id'), so no selection prompt is needed."
  (interactive)
  (require 'agent-fleet-worktree nil t)
  (agent-fleet-worktree-status-in-buffer
   (agent-fleet-attach--current-pane-id)))

(transient-define-prefix agent-fleet-attach-menu ()
  "Act on the agent this attach buffer is driving.
Each entry acts on the pane id owned by this buffer
(`agent-fleet-attach-pane-id'), so no selection prompt is needed.  Bound to
`C-c C-a h' or `C-c C-a ?' in attach buffers.  The view entries are split
by presentation: the \"child frame\" group opens an auxiliary child frame
over the terminal parent, leaving its window geometry untouched; the
\"buffer\" group opens an ordinary buffer.  Lowercase keys select the
child frame, uppercase the buffer."
  [["Agent"
    ("s" "Prompt"            agent-fleet-attach-prompt)
    ("S" "Prompt (compose)"  agent-fleet-attach-prompt-in-child-frame)
    ("k" "Send keys"         agent-fleet-attach-send-keys)
    ("i" "Interrupt"         agent-fleet-attach-interrupt)
    ("x" "Kill"              agent-fleet-attach-kill)
    ("r" "Rename"            agent-fleet-attach-rename)]
   ["View (child frame)"
    ("o" "Inspect output"    agent-fleet-attach-inspect-in-child-frame)
    ("d" "Working-tree diff" agent-fleet-attach-diff-in-child-frame)
    ("m" "Magit status"      agent-fleet-attach-magit-in-child-frame)
    ("w" "Worktree status"   agent-fleet-attach-worktree-in-child-frame)]
   ["View (buffer)"
    ("O" "Inspect output"    agent-fleet-attach-inspect-in-buffer)
    ("D" "Working-tree diff" agent-fleet-attach-diff-in-buffer)
    ("M" "Magit status"      agent-fleet-attach-magit-in-buffer)
    ("W" "Worktree status"   agent-fleet-attach-worktree-in-buffer)]])

;;;###autoload
(defvar-keymap agent-fleet-attach-command-map
  :doc "Prefix map for attach-buffer current-agent commands.
Bound to `C-c C-a' in `agent-fleet-attach-mode-map'.  You can rebind it
there, e.g. (keymap-set agent-fleet-attach-mode-map \"C-c C-f\"
\\='agent-fleet-attach-command-map).
Lowercase repo/view keys (`o'/`w'/`m'/`d') open an auxiliary child frame
over the terminal parent, leaving its window geometry untouched; uppercase
(`O'/`W'/`M'/`D') open an ordinary buffer."
  "o" #'agent-fleet-attach-inspect-in-child-frame
  "O" #'agent-fleet-attach-inspect-in-buffer
  "s" #'agent-fleet-attach-prompt
  "S" #'agent-fleet-attach-prompt-in-child-frame
  "k" #'agent-fleet-attach-send-keys
  "i" #'agent-fleet-attach-interrupt
  "x" #'agent-fleet-attach-kill
  "r" #'agent-fleet-attach-rename
  "d" #'agent-fleet-attach-diff-in-child-frame
  "D" #'agent-fleet-attach-diff-in-buffer
  "m" #'agent-fleet-attach-magit-in-child-frame
  "M" #'agent-fleet-attach-magit-in-buffer
  "w" #'agent-fleet-attach-worktree-in-child-frame
  "W" #'agent-fleet-attach-worktree-in-buffer
  "h" #'agent-fleet-attach-menu
  "?" #'agent-fleet-attach-menu)

;;;###autoload
(defvar-keymap agent-fleet-attach-mode-map
  :doc "Keymap for `agent-fleet-attach-mode', active in attach buffers.
Bind `agent-fleet-attach-command-map' to a prefix key of your choice.
C-g is bound to `agent-fleet-attach-prompt-in-child-frame' so it
intercepts the key before the CLI tool can launch $EDITOR — the
prompt is composed in an auxiliary child frame instead.  To send a
literal C-g to the terminal, use \\[ghostel-send-next-key] (C-q)."
  "C-g" #'agent-fleet-attach-prompt-in-child-frame)

(define-minor-mode agent-fleet-attach-mode
  "Buffer-local minor mode for attach terminal buffers.
Commands in `agent-fleet-attach-command-map' act on the agent whose
pane id is `agent-fleet-attach-pane-id' (the agent you are driving)."
  :init-value nil
  :lighter " Fleet"
  :keymap agent-fleet-attach-mode-map)

(provide 'agent-fleet-attach)
;;; agent-fleet-attach.el ends here
