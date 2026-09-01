;;; consult-agent-fleet.el --- consult integration for agent-fleet  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience
;; Version: 0.4.0
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
;; stays consult-free.  Enable it by requiring it explicitly, after
;; both consult and agent-fleet are installed, then turn the mode on:
;;
;;     (require 'consult-agent-fleet)
;;     (consult-agent-fleet-mode)
;;
;; The mode installs `:around' advice on `agent-fleet-read-agent-name'
;; -- the shared reader that the interactive forms of
;; `agent-fleet-attach', `agent-fleet-show-output-in-buffer',
;; `agent-fleet-switch', `agent-fleet-kill', `agent-fleet-interrupt',
;; and the other selection commands all call -- so every entry point
;; that goes through the
;; reader (keys, `M-x', dashboard bindings, and programmatic calls)
;; picks the agent with `consult--read' instead of `completing-read'.
;; Disabling the mode removes the advice, so the original listing runs
;; unchanged.
;;
;; Each candidate shows the agent identity and, as a consult
;; annotation, its kind, task, and project -- the same fields the
;; agent-fleet dashboard shows.  The candidate data comes from
;; `agent-fleet-agent-candidates', so consult and the built-in
;; `completing-read' listing carry identical information.

;;; Code:

(require 'consult)
(require 'agent-fleet)

(defvar consult-agent-fleet--history nil
  "Minibuffer history for `consult-agent-fleet' agent selection.")

(defun consult-agent-fleet--select (prompt)
  "Select a cached Herdr agent with consult, returning its pane id.
PROMPT is shown in the minibuffer.  Candidates are the
`agent-fleet-agent-candidates' data: each shows the agent identity and,
as a consult annotation aligned with `consult--annotate-align', its kind,
task, and project.  The suffix comes from the SAME public
`agent-fleet-agent-annotation' the built-in reader's completion table
declares (via `agent-fleet-completion-annotation-table'), so consult and
the native *Completions* show identical suffixes with no duplicated
label->suffix logic.  Agents sharing an identity are disambiguated with
the pane id in brackets.  Signal `user-error' when no agent is cached.
The return value is the pane id that the consult `:lookup' yields, so it
round-trips through `agent-fleet--find-agent'."
  (let* ((entries (agent-fleet-agent-candidates))
         (candidates
          (mapcar (lambda (entry)
                    (cons (plist-get entry :label)
                          (plist-get entry :pane-id)))
                  entries))
         (agent-fleet-completion-annotations
          (agent-fleet-completion-annotation-table entries)))
    (unless candidates
      (user-error "No agents are available"))
    (consult--read
     candidates
     :prompt (concat prompt ": ")
     :require-match t
     :history '(:input consult-agent-fleet--history)
     :category 'agent-fleet-agent
     :annotate (lambda (cand)
                 (consult--annotate-align
                  cand (agent-fleet-agent-annotation cand)))
     :lookup #'consult--lookup-cdr)))

(defun consult-agent-fleet--read-agent-name (_orig-fn prompt)
  "`:around' advice that selects an agent with consult.
Installed by `consult-agent-fleet-mode' (which also removes it on
disable), so while the mode is off the original
`agent-fleet-read-agent-name' runs unchanged.  Delegates to
`consult-agent-fleet--select', whose consult `:lookup' returns the pane
id -- matching the return value of the original reader so it
round-trips through `agent-fleet--find-agent'.  _ORIG-FN is the
original reader (ignored; this advice fully replaces it while active);
PROMPT is passed through."
  (consult-agent-fleet--select prompt))

(define-minor-mode consult-agent-fleet-mode
  "Use consult to select agents in every agent-fleet selection command.
When on, this installs `:around' advice on
`agent-fleet-read-agent-name' -- the shared public reader that the
interactive forms of `agent-fleet-attach',
`agent-fleet-show-output-in-buffer', `agent-fleet-switch',
`agent-fleet-kill', `agent-fleet-interrupt', and
the other selection commands all call.  Because the advice sits on the
reader, every entry point that goes through it is covered: keys you
have bound to those commands, `M-x', dashboard bindings, and
programmatic calls.  The consult candidates show the agent identity
with kind, task, and project as a consult annotation, with narrowing
and preview, instead of the built-in `completing-read' listing.
Disabling the mode removes the advice, so the original reader runs
unchanged -- no remap or residue is left behind.  This is a GLOBAL
minor mode; toggling it once affects every buffer.  Load the package
first, then toggle with \\[consult-agent-fleet-mode]."
  :init-value nil
  :global t
  :lighter " Consult/Fleet"
  :group 'agent-fleet
  (if consult-agent-fleet-mode
      (advice-add 'agent-fleet-read-agent-name :around
                  #'consult-agent-fleet--read-agent-name)
    (advice-remove 'agent-fleet-read-agent-name
                   #'consult-agent-fleet--read-agent-name)))

(provide 'consult-agent-fleet)

;;; consult-agent-fleet.el ends here
