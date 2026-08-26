;;; consult-agent-fleet.el --- consult integration for agent-fleet  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (consult "3.7") (agent-fleet "0.2.0"))

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

;; Optional consult integration for the agent-fleet package.
;;
;; This is a separate, opt-in package.  It is not autoloaded and
;; agent-fleet's own load chain never pulls it in, so the base layer
;; stays consult-free.  Enable it by requiring it explicitly, after both
;; consult and agent-fleet are installed:
;;
;;     (require 'consult-agent-fleet)
;;
;; Two ways to use it:
;;
;;   * Turn on `consult-agent-fleet-mode'.  This installs `:around'
;;     advice on `agent-fleet--read-agent-name' -- the shared reader
;;     that the interactive forms of `agent-fleet-attach',
;;     `agent-fleet-show-output', `agent-fleet-switch',
;;     `agent-fleet-kill', `agent-fleet-interrupt', and the other
;;     selection commands all call.  Every entry point that goes through
;;     the reader -- keys you have bound, `M-x', and programmatic calls
;;     -- then picks the agent with `consult--read' instead of
;;     `completing-read'.  Disabling the mode removes the advice, so the
;;     original listing runs unchanged.
;;
;;   * Or call the standalone `consult-agent-fleet-attach',
;;     `consult-agent-fleet-show-output', `consult-agent-fleet-switch',
;;     `consult-agent-fleet-kill', or `consult-agent-fleet-interrupt'
;;     commands directly, without enabling the mode.  These select a
;;     cached Herdr agent with `consult--read' and run the matching
;;     agent-fleet action on the selection.
;;
;; In either case each candidate shows the agent identity and, as a
;; consult annotation, its kind, task, and workspace -- the same fields
;; the agent-fleet dashboard shows.  The candidate data comes from
;; `agent-fleet-agent-candidates', so consult and the built-in
;; `completing-read' listing carry identical information.

;;; Code:

(require 'consult)
(require 'agent-fleet)

(declare-function agent-fleet-attach "agent-fleet-attach" (target &optional takeover))
(declare-function agent-fleet-show-output "agent-fleet" (agent &optional lines source))
(declare-function agent-fleet-switch "agent-fleet" (agent))
(declare-function agent-fleet-kill "agent-fleet" (agent))
(declare-function agent-fleet-interrupt "agent-fleet" (agent))

(defvar consult-agent-fleet--history nil
  "Minibuffer history for `consult-agent-fleet' agent selection.")

(defun consult-agent-fleet--select (prompt)
  "Select a cached Herdr agent with consult, returning its pane id.
PROMPT is shown in the minibuffer.  Candidates are the
`agent-fleet-agent-candidates' data: each shows the agent identity
and, as a consult annotation aligned with `consult--annotate-align',
its kind, task, and workspace, mirroring the dashboard columns.
Agents sharing an identity are disambiguated with the pane id in
brackets, as in the built-in listing.  Signal `user-error' when no
agent is cached.  The return value is the pane id that the consult
`:lookup' yields, so it round-trips through `agent-fleet--find-agent'."
  (let* ((entries (agent-fleet-agent-candidates))
         (candidates
          (mapcar (lambda (entry)
                    (cons (plist-get entry :label)
                          (plist-get entry :pane-id)))
                  entries))
         (suffix
          (let ((table (make-hash-table :test 'equal)))
            (dolist (entry entries table)
              (puthash (plist-get entry :label)
                       (agent-fleet-agent-candidate-suffix entry)
                       table))))
         (annotate
          (lambda (cand)
            (consult--annotate-align
             cand (gethash cand suffix "")))))
    (unless candidates
      (user-error "No agents are available"))
    (consult--read
     candidates
     :prompt (concat prompt ": ")
     :require-match t
     :history '(:input consult-agent-fleet--history)
     :category 'agent-fleet-agent
     :annotate annotate
     :lookup #'consult--lookup-cdr)))

(defun consult-agent-fleet--read (prompt action)
  "Select a cached Herdr agent with consult and call ACTION on it.
PROMPT is shown in the minibuffer.  ACTION is a function called with
the pane id of the selected agent -- the value that
`consult-agent-fleet--select' returns through the consult `:lookup'.
Candidates and annotations are as described for
`consult-agent-fleet--select'.  Signal `user-error' when no agent is
cached."
  (let ((pane-id (consult-agent-fleet--select prompt)))
    (when pane-id
      (funcall action pane-id))))

(defun consult-agent-fleet-attach ()
  "Attach to a Herdr agent's terminal, choosing the agent with consult.
Select from the cached agents and run `agent-fleet-attach' on the
selection."
  (interactive)
  (consult-agent-fleet--read "Attach to agent" #'agent-fleet-attach))

(defun consult-agent-fleet-show-output ()
  "Show a Herdr agent's recent output, choosing the agent with consult.
Select from the cached agents and run `agent-fleet-show-output' on the
selection."
  (interactive)
  (consult-agent-fleet--read "Show output of" #'agent-fleet-show-output))

(defun consult-agent-fleet-switch ()
  "Focus a Herdr agent, choosing the agent with consult.
Select from the cached agents and run `agent-fleet-switch' on the
selection."
  (interactive)
  (consult-agent-fleet--read "Focus agent" #'agent-fleet-switch))

(defun consult-agent-fleet-kill ()
  "Kill a Herdr agent, choosing the agent with consult.
Select from the cached agents and run `agent-fleet-kill' on the
selection."
  (interactive)
  (consult-agent-fleet--read "Kill agent" #'agent-fleet-kill))

(defun consult-agent-fleet-interrupt ()
  "Interrupt a Herdr agent, choosing the agent with consult.
Select from the cached agents and run `agent-fleet-interrupt' on the
selection."
  (interactive)
  (consult-agent-fleet--read "Interrupt agent" #'agent-fleet-interrupt))

(defun consult-agent-fleet--read-agent-name (_orig-fn prompt)
  "`:around' advice that selects an agent with consult.
Installed by `consult-agent-fleet-mode' (which also removes it on
disable), so while the mode is off the original
`agent-fleet--read-agent-name' runs unchanged.  Delegates to
`consult-agent-fleet--select', whose consult `:lookup' returns the pane
id -- matching the return value of the original reader so it
round-trips through `agent-fleet--find-agent'.  _ORIG-FN is the
original reader (ignored; this advice fully replaces it while active);
PROMPT is passed through."
  (consult-agent-fleet--select prompt))

(define-minor-mode consult-agent-fleet-mode
  "Use consult to select agents in every agent-fleet selection command.
When on, this installs `:around' advice on
`agent-fleet--read-agent-name' -- the shared reader that the
interactive forms of `agent-fleet-attach', `agent-fleet-show-output',
`agent-fleet-switch', `agent-fleet-kill', `agent-fleet-interrupt', and
the other selection commands all call.  Because the advice sits on the
reader, every entry point that goes through it is covered: keys you
have bound to those commands, `M-x', dashboard bindings, and
programmatic calls.  The consult candidates show the agent identity
with kind, task, and workspace as a consult annotation, with narrowing
and preview, instead of the built-in `completing-read' listing.
Disabling the mode removes the advice, so the original reader runs
unchanged -- no remap or residue is left behind.  This is a GLOBAL
minor mode; toggling it once affects every buffer.  For a per-command
opt-in without the mode, call the `consult-agent-fleet-*' commands
directly.  Load the package first, then toggle with
\\[consult-agent-fleet-mode]."
  :init-value nil
  :global t
  :lighter " Consult/Fleet"
  :group 'agent-fleet
  (if consult-agent-fleet-mode
      (advice-add 'agent-fleet--read-agent-name :around
                  #'consult-agent-fleet--read-agent-name)
    (advice-remove 'agent-fleet--read-agent-name
                   #'consult-agent-fleet--read-agent-name)))

(provide 'consult-agent-fleet)

;;; consult-agent-fleet.el ends here
