;;; consult-agent-fleet.el --- consult integration for agent-fleet  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.2.0
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
;; Once loaded, the `consult-agent-fleet-attach',
;; `consult-agent-fleet-show-output', `consult-agent-fleet-switch',
;; `consult-agent-fleet-kill', and `consult-agent-fleet-interrupt'
;; commands select a cached Herdr agent with `consult--read' and run the
;; matching agent-fleet action on the selection.  Each candidate shows
;; the agent identity and, as a consult annotation, its kind, task, and
;; workspace -- the same fields the agent-fleet dashboard shows.  The
;; candidate data comes from `agent-fleet-agent-candidates', so consult
;; and the built-in `completing-read' listing carry identical
;; information.

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

(defun consult-agent-fleet--read (prompt action)
  "Select a cached Herdr agent with consult and call ACTION on it.
PROMPT is shown in the minibuffer.  ACTION is a function called with
the selected agent's pane id -- the value `consult--read' returns
through its `:lookup'.  Candidates are the `agent-fleet-agent-candidates'
data: each shows the agent identity and, as a consult annotation aligned
with `consult--annotate-align', its kind, task, and workspace, mirroring
the dashboard columns.  Agents sharing an identity are disambiguated
with the pane id in brackets, as in the built-in listing.  Signal
`user-error' when no agent is cached."
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
    (let ((pane-id
           (consult--read
            candidates
            :prompt (concat prompt ": ")
            :require-match t
            :history '(:input consult-agent-fleet--history)
            :category 'agent-fleet-agent
            :annotate annotate
            :lookup #'consult--lookup-cdr)))
      (when pane-id
        (funcall action pane-id)))))

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

(provide 'consult-agent-fleet)

;;; consult-agent-fleet.el ends here
