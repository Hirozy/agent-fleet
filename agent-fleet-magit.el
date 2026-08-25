;;; agent-fleet-magit.el --- Magit integration for agent-fleet -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience, vc
;; Version: 0.6.0
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

;; The Magit layer.  Opens Magit's own status /
;; diff buffers scoped to an agent's checkout — it does NOT reinvent a diff
;; or cherry-pick UI ( "不需要重新发明 diff viewer";  "尽量全部调用
;; Magit public API").  Cherry-pick, merge, and worktree deletion are reached
;; via Magit's own keys inside the status buffer opened by `m'.
;;
;; Two entry points, wired to the dashboard `m' / `d' keys:
;;   `agent-fleet-magit-status'  -> `magit-status' on the agent's repo root
;;   `agent-fleet-magit-diff'    -> `magit-diff-working-tree' (uncommitted)
;;
;; Magit is an OPTIONAL dependency; the doctor already reports
;; availability at `herdr.el'.  Entry points `user-error' clearly when Magit
;; is absent; `declare-function' silences the byte-compiler without a top-level
;; `require', so the package loads and compiles with no Magit installed.
;;
;; The package entry point loads this feature module through the dashboard
;; after providing `agent-fleet', so its control/project/worktree requires do
;; not create a load cycle.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-fleet)
(require 'agent-fleet-project)
(require 'agent-fleet-worktree)

;; Magit is optional: declare the public entry points so the
;; byte-compiler does not warn, without forcing a top-level `require'.
(declare-function magit-status "magit-status" (&optional directory))
(declare-function magit-diff-working-tree "magit-diff" (&optional range args files))


;;; --- Availability guard --------------------------------------------

(defun agent-fleet-magit--available-p ()
  "Return non-nil if Magit is loaded or loadable.
Magit is an optional dependency; this loads it on demand so the
rest of the package compiles and loads without it.  Returning nil (Magit
not installed) causes the entry points to `user-error' with install advice."
  (or (featurep 'magit) (require 'magit nil t)))


;;; --- Root resolution (testable core) --------------------------------

(defun agent-fleet-magit--checkout-root-for-cwd (cwd)
  "Return the concrete git checkout containing CWD, or nil.
Unlike project identity resolution, this deliberately does not follow a
linked worktree's git-common-dir back to the primary checkout: Magit must
open on the files the agent is actually editing."
  (when (and (stringp cwd)
             (not (string-empty-p cwd))
             (file-directory-p cwd))
    (when-let* ((root (locate-dominating-file cwd ".git")))
      (directory-file-name (file-truename root)))))

(defun agent-fleet-magit--root-for-agent (agent)
  "Return the git root to open Magit on for AGENT, or nil.
AGENT is resolved via `agent-fleet--find-agent'.  For an agent whose cwd
is inside a worktree, the root is that worktree's root; for a bare agent
it is the main repo root.  Resolution is by canonical cwd
(`agent-fleet-project-root-for-cwd'), reusing its nil/empty/
non-existent-cwd guards.  When the agent has no usable cwd but a worktree
is cached, the worktree path is the fallback ( \"open agent
worktree in Magit\").  Returns nil if no directory is reachable."
  (when-let* ((a (agent-fleet--find-agent agent)))
    (or (agent-fleet-magit--checkout-root-for-cwd (herdr-agent-cwd a))
        (when-let* ((wt (agent-fleet--worktree-for-agent a))
                    (path (herdr-worktree-path wt))
                    ((file-directory-p path)))
          path))))


;;; --- Shared command helper ------------------------------------------

(defun agent-fleet-magit--with-root (target label open-fn)
  "Resolve TARGET to a git root and call OPEN-FN with it.
Guards Magit availability: `user-error' when Magit is absent.
Messages and returns nil when TARGET is unresolvable or has no reachable
git root.  OPEN-FN is called as (funcall OPEN-FN ROOT) with
`default-directory' let-bound to ROOT, so Magit commands that read it
\(such as `magit-diff-working-tree') resolve to the agent's repo.  LABEL
names the action in the no-root message."
  (unless (agent-fleet-magit--available-p)
    (user-error
     "Magit is not installed (M-x package-install RET magit); \
it is an optional dependency"))
  (let* ((agent (agent-fleet--find-agent target))
         (root (and agent (agent-fleet-magit--root-for-agent agent))))
    (if (null root)
        (progn
          (message "%s: no accessible git root for %s"
                   label
                   (or (and agent (herdr-agent-display-name agent)) "agent"))
          nil)
      (let ((default-directory root))
        (funcall open-fn root)))))


;;; --- Commands (dashboard `m' / `d') ---------------------------------

;;;###autoload
(defun agent-fleet-magit-status (target)
  "Open Magit status on TARGET's checkout.
TARGET is an agent name, pane id, symbol, or `herdr-agent' struct.  For a
worktree agent, status opens on the worktree root; for a bare agent, the
main repo root.  Cherry-pick, merge, and worktree deletion are then
Magit's own keys inside the status buffer (use Magit public
API, do not reinvent).  `user-error's if Magit is not installed."
  (interactive (list (agent-fleet--read-agent-name "Magit status for agent")))
  (agent-fleet-magit--with-root
   target "Magit status"
   (lambda (root) (magit-status root))))

;;;###autoload
(defun agent-fleet-magit-diff (target)
  "Show TARGET's working-tree diff.
Opens `magit-diff-working-tree' scoped to TARGET's checkout — the
uncommitted changes the agent is making right now (HEAD vs working tree).
The branch-vs-base review diff is reachable by opening Magit status (`m')
and pressing `d' there.  `user-error's if Magit is not installed."
  (interactive (list (agent-fleet--read-agent-name "Diff for agent")))
  (agent-fleet-magit--with-root
   target "Diff"
   (lambda (_root) (magit-diff-working-tree))))

(provide 'agent-fleet-magit)
;;; agent-fleet-magit.el ends here
