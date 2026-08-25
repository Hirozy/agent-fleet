;;; agent-fleet-worktree.el --- worktree management for agent-fleet -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience, vc
;; Version: 0.5.0
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

;; The worktree layer.  Herdr can create a
;; git worktree — a separate checkout of a repo — and host a workspace +
;; root pane in it, so multiple agents do not modify the same checkout.
;; This layer exposes that as standalone management commands and as the
;; dashboard `w' status action.
;;
;; The `:worktree t' start flow itself lives in `agent-fleet-start'
;; (`agent-fleet--provision-worktree'); this file provides the surrounding
;; list / open / remove / status commands.  It is a thin layer over the
;; Phase 1 RPCs (`herdr-request') and the Phase 1 model accessors
;; (`herdr-model-worktrees', `herdr-model-find-worktree-for-workspace',
;; `herdr-model-upsert-worktree').  It adds no wire protocol.
;;
;; Design rules honored:
;;   §25  no polling.  `worktree.list' is called only on user action
;;        (a command or the dashboard `w' key), never on a timer.
;;   §33  worktree.create/open/remove are the worktree RPCs.
;;   §34  worktree isolation: an agent started with `:worktree t' works in
;;        its own checkout.
;;   §46/§23  the status view shows worktree METADATA only (path/branch/
;;        repo); no pane output is ever persisted or mirrored.
;;
;; The package entry point loads this feature module through the dashboard
;; after providing `agent-fleet', so requiring the control feature below does
;; not create a load cycle.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr)
(require 'herdr-model)
(require 'agent-fleet)


;;; --- Fetch helper ---------------------------------------------------

(defun agent-fleet-worktree--fetch (&optional cwd)
  "Call `worktree.list' and upsert every result into the cache.
CWD, when non-empty, scopes the query to the repo at that path (otherwise
all known worktrees are listed).  Returns a cons (STRUCTS . SOURCE):
STRUCTS is the list of parsed worktree structs now in the cache, and
SOURCE is the `WorktreeSourceInfo' plist (repo metadata) or nil.
User-initiated (never a timer; §25)."
  (let* ((res (herdr-request "worktree.list"
                             (if (and cwd (not (string-empty-p cwd)))
                                 `(("cwd" . ,cwd))
                               nil)))
         (source (plist-get res :source))
         (raw (let ((w (plist-get res :worktrees)))
                (cond ((listp w) w) ((vectorp w) (append w nil)) (t nil))))
         ;; An unscoped list is authoritative for the complete worktree set.
         ;; Drop stale entries before upserting; a scoped repo query cannot
         ;; safely remove entries belonging to other repos.
         (_reconciled (when (and (or (null cwd) (string-empty-p cwd))
                                  (herdr-model-cache))
                        (clrhash (herdr-session-worktrees
                                  (herdr-model-cache)))))
         (structs (delq nil (mapcar #'herdr-model-upsert-worktree raw))))
    (cons structs source)))


;;; --- List -----------------------------------------------------------

;;;###autoload
(defun agent-fleet-worktree-list (&optional cwd)
  "List Herdr worktrees and cache them.
With a prefix arg, prompt for a repo CWD to scope the query; otherwise
list all known worktrees.  Each result is upserted into the cache — the
only way to seed worktree state besides events (user-initiated, not
polling; §25).  Returns the worktree structs.  When called
interactively, messages the count and paths."
  (interactive
   (list (when current-prefix-arg
           (read-directory-name "Repo cwd (empty for all): "))))
  (agent-fleet--ensure-connected)
  (let ((structs (car (agent-fleet-worktree--fetch cwd))))
    (when (called-interactively-p 'any)
      (cond
       ((null (herdr-model-cache))
        (message "Not connected to Herdr"))
       (structs
        (message "%d worktree(s): %s"
                 (length structs)
                 (mapconcat #'herdr-worktree-path structs ", ")))
       (t
        (message "No worktrees"))))
    structs))


;;; --- Open -----------------------------------------------------------

;;;###autoload
(cl-defun agent-fleet-worktree-open (cwd &key branch base focus)
  "Open a Herdr workspace for an existing worktree at repo CWD.
Calls `worktree.open': if a workspace is already open
for the worktree it is reused (the result carries `:already-open').  An
optional BRANCH/BASE identify the worktree (nil lets Herdr decide); FOCUS
focuses the workspace in the Herdr UI.  The returned worktree + workspace
are upserted into the cache immediately.  Returns
\`(:workspace-id WS :pane-id PANE :worktree WT :already-open BOOL)', or
signals `agent-fleet-provisioning-failed' (step `worktree-open') if the
response lacks a workspace or root pane."
  (interactive
   (list (read-directory-name "Repo cwd: ")))
  (agent-fleet--ensure-connected)
  (let* ((params `(("cwd" . ,cwd)
                   ("focus" . ,(if focus t :false))
                   ,@(and branch `(("branch" . ,branch)))
                   ,@(and base `(("base" . ,base)))))
         (res (herdr-request "worktree.open" params))
         (ws (plist-get res :workspace))
         (pane (plist-get res :root_pane))
         (wt (plist-get res :worktree)))
    (unless (and ws pane (plist-get pane :pane_id))
      (signal 'agent-fleet-provisioning-failed
              (list :step 'worktree-open :result res)))
    (herdr-model-upsert-workspace ws)
    (when wt (herdr-model-upsert-worktree wt))
    `(:workspace-id ,(plist-get ws :workspace_id)
      :pane-id ,(plist-get pane :pane_id)
      :worktree ,wt
      :already-open ,(not (memq (plist-get res :already_open) '(nil :false))))))


;;; --- Remove ---------------------------------------------------------

(defun agent-fleet-worktree--workspace-choices ()
  "Return an alist (LABEL . WORKSPACE-ID) of worktree-hosting workspaces.
Drawn from cached worktrees, deduplicated by workspace id.  Ordinary agent
workspaces are deliberately excluded: `worktree.remove' is invalid for them."
  (let ((seen (make-hash-table :test 'equal))
        (choices nil))
    (dolist (wt (herdr-model-worktrees))
      (when-let* ((ws-id (herdr-worktree-open-workspace-id wt)))
        (unless (gethash ws-id seen)
          (puthash ws-id t seen)
          (push (cons (format "%s (worktree)" (herdr-worktree-path wt)) ws-id)
                choices))))
    (nreverse choices)))

;;;###autoload
(defun agent-fleet-worktree-remove (workspace-id &optional force)
  "Remove the worktree hosted by WORKSPACE-ID via `worktree.remove' (§33).
FORCE (prefix arg, interactively) removes the worktree even if it has
uncommitted changes.  The worktree is removed from the cache eagerly; the
pushed `worktree_removed' event also removes it.  Returns the RPC result."
  (interactive
   (let* ((choices (agent-fleet-worktree--workspace-choices))
          (_ (unless choices (user-error "No cached worktrees to remove")))
          (default (and choices (caar choices)))
          (sel (completing-read
                (if default
                    (format "Remove worktree for workspace (default %s): "
                            default)
                  "Remove worktree for workspace: ")
                choices nil t nil nil default)))
     (list (cdr (assoc sel choices)) current-prefix-arg)))
  (agent-fleet--ensure-connected)
  (unless workspace-id
    (signal 'agent-fleet-error
            (list :hint "worktree-remove needs a workspace id")))
  (let ((res (herdr-request "worktree.remove"
                            `(("workspace_id" . ,workspace-id)
                              ("force" . ,(if force t :false))))))
    ;; Eager cache removal (the `worktree_removed' event also removes it).
    (when-let* ((wt (herdr-model-find-worktree-for-workspace workspace-id)))
      (herdr-model-remove-worktree (herdr-worktree-path wt)))
    res))


;;; --- Status (dashboard `w' action) ----------------------------------

(defun agent-fleet--worktree-for-agent (agent)
  "Return the worktree struct for AGENT's workspace, or nil.
AGENT may be a struct, name, pane id, or symbol (resolved via
`agent-fleet--find-agent').  Looks up the worktree whose open workspace
is the agent's workspace."
  (when-let* ((a (agent-fleet--find-agent agent))
              (ws-id (herdr-agent-workspace-id a)))
    (herdr-model-find-worktree-for-workspace ws-id)))

(defun agent-fleet-worktree--insert-field (label value)
  "Insert a formatted LABEL / VALUE field line into the current buffer."
  (insert (format "%-12s %s\n" label value)))

(defun agent-fleet-worktree--display (wt ws-id source)
  "Render worktree WT (workspace WS-ID, repo SOURCE) in a read-only buffer.
Shows worktree METADATA only.  SOURCE
is a `WorktreeSourceInfo' plist or nil."
  (let ((buf (get-buffer-create "*Agent Fleet Worktree*")))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert (format "Worktree for workspace %s\n\n" (or ws-id "?")))
      (agent-fleet-worktree--insert-field "Path" (or (herdr-worktree-path wt) "?"))
      (agent-fleet-worktree--insert-field
       "Branch" (or (herdr-worktree-branch wt) "(detached)"))
      (agent-fleet-worktree--insert-field
       "Label" (or (herdr-worktree-label wt) "—"))
      (agent-fleet-worktree--insert-field
       "Repo" (or (plist-get source :repo_name)
                  (plist-get source :repo_root)
                  "—"))
      (agent-fleet-worktree--insert-field
       "Linked" (if (herdr-worktree-is-linked-worktree wt) "yes" "no"))
      (agent-fleet-worktree--insert-field
       "Bare" (if (herdr-worktree-is-bare wt) "yes" "no"))
      (agent-fleet-worktree--insert-field
       "Detached" (if (herdr-worktree-is-detached wt) "yes" "no"))
      (agent-fleet-worktree--insert-field
       "Prunable" (if (herdr-worktree-is-prunable wt) "yes" "no"))
      (goto-char (point-min))
      (read-only-mode 1)
      (set-buffer-modified-p nil))
    (display-buffer buf)))

;;;###autoload
(defun agent-fleet-worktree-status (target)
  "Show the worktree for TARGET's workspace (the dashboard `w' action).
TARGET is an agent name, pane id, symbol, or `herdr-agent' struct.
Displays the worktree path/branch/repo/metadata read-only
(§46/§23: no pane output is persisted).  Refreshes worktree state from
`worktree.list' on each call (user-initiated, never a timer; §25), so the
status reflects the live worktree set and repo source.
Returns the worktree struct, or nil and messages when no worktree is open
for the workspace."
  (interactive
   (list (agent-fleet--read-agent-name "Worktree status for agent")))
  (agent-fleet--ensure-connected)
  (let* ((agent (or (agent-fleet--find-agent target)
                    (signal 'agent-fleet-target-not-found (list :agent target))))
         (ws-id (herdr-agent-workspace-id agent))
         (fetch (agent-fleet-worktree--fetch))
         (structs (car fetch))
         (source (cdr fetch))
         (wt (cl-find-if
              (lambda (s) (equal (herdr-worktree-open-workspace-id s) ws-id))
              structs)))
    (if wt
        (progn
          (agent-fleet-worktree--display wt ws-id source)
          wt)
      (message "No worktree for %s (workspace %s)"
               (herdr-agent-display-name agent) (or ws-id "?"))
      nil)))


;;; --- Cleanup (§71: delete finished worktrees) -----------------------

;;;###autoload
(defun agent-fleet-worktree-cleanup (&optional no-confirm)
  "Remove the worktrees of all finished (`done') agents.
Lists each done agent's worktree (name + path) and asks for confirmation
before removing them via `agent-fleet-worktree-remove' (which issues
`worktree.remove' and drops the worktree from the cache eagerly).  With
non-nil NO-CONFIRM (prefix arg, interactively) skip the prompt.
Agents that are not `done', or have no worktree, are left alone.  A
worktree with uncommitted changes makes `worktree.remove' fail (it is
not forced) — review it first with `d'/`m' — and is reported as failed.
Returns the number of worktrees removed."
  (interactive "P")
  (agent-fleet--ensure-connected)
  (let* ((done (cl-remove-if-not
                (lambda (a) (eq 'done (agent-fleet-status a)))
                (agent-fleet-list)))
         (seen (make-hash-table :test 'equal))
         (targets
          (cl-remove-if-not
           (lambda (a)
             (when-let* ((wt (agent-fleet--worktree-for-agent a))
                         (ws-id (herdr-worktree-open-workspace-id wt)))
               (unless (gethash ws-id seen)
                 (puthash ws-id t seen)
                 t)))
           done)))
    (if (null targets)
        (progn (message "No finished-agent worktrees to clean up") 0)
      (let ((n (length targets))
            removed failures)
        (if (not (or no-confirm
                     (y-or-n-p
                      (mapconcat
                       #'identity
                       (append
                        (list (format "Remove %d finished-agent worktree(s)?"
                                      n))
                        (mapcar (lambda (a)
                                  (let ((wt (agent-fleet--worktree-for-agent a)))
                                    (format "  %s  %s"
                                            (herdr-agent-display-name a)
                                            (herdr-worktree-path wt))))
                                targets))
                       "\n"))))
            (progn (message "Canceled") 0)
          (dolist (a targets)
            (let ((ws-id (herdr-agent-workspace-id a)))
              (condition-case _err
                  (progn (agent-fleet-worktree-remove ws-id)
                         (push a removed))
                (error (push a failures)))))
          (message "Removed %d/%d finished-agent worktree(s)%s"
                   (length removed) n
                   (if failures
                       (format "; %d failed (review with `d'/`m')"
                               (length failures))
                     ""))
          (length removed))))))

(provide 'agent-fleet-worktree)
;;; agent-fleet-worktree.el ends here
