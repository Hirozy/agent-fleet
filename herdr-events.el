;;; herdr-events.el --- Subscription logic and local event bus -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, terminals
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

;; You should have a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Pure logic layer (no I/O) for Herdr subscriptions and the local
;; event bus.  It computes WHICH subscriptions to ask the server for,
;; decides when the per-pane subscription set must be rebuilt (because
;; `pane.agent_status_changed' is scoped to a `pane_id'), and dispatches
;; pushed events: first reconciling the cache (via `herdr-model'), then
;; running the local hook bus.
;;
;; The actual long-lived subscription connection lives in `herdr.el',
;; which calls into here for the subscription set and the per-event
;; callback.  See docs/PROTOCOL.md for the subscription/event model.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-protocol)
(require 'herdr-model)


;;; --- Subscription type catalog ------------------------------------

;; Dotted subscription types that need no extra fields (global).  These
;; cover workspace/tab/pane/worktree/layout lifecycle + focus changes so
;; the cache mirrors the live Herdr UI without polling.
(defconst herdr-events-global-types
  '("workspace.created" "workspace.updated" "workspace.metadata_updated"
    "workspace.renamed" "workspace.moved" "workspace.reordered"
    "workspace.closed" "workspace.focused"
    "worktree.created" "worktree.opened" "worktree.removed"
    "tab.created" "tab.closed" "tab.focused" "tab.renamed" "tab.moved"
    "pane.created" "pane.closed" "pane.updated" "pane.focused"
    "pane.moved" "pane.exited" "pane.agent_detected"
    "layout.updated")
  "Global Herdr subscription types (no per-pane fields required).")

;; Per-pane subscription types we want.  Each requires a `pane_id'.
(defconst herdr-events-per-pane-types
  '("pane.agent_status_changed")
  "Per-pane subscription types (each needs a `pane_id').")


;;; --- Subscription computation ------------------------------------

(defun herdr-events-default-subscriptions ()
  "Return the list of global subscription alists.
Each element is an alist like ((\"type\" . \"workspace.created\"))."
  (mapcar (lambda (type) `(("type" . ,type)))
          herdr-events-global-types))

(defun herdr-events-pane-subscriptions-for-ids (pane-ids)
  "Return per-pane subscription alists for PANE-IDS.
PANE-IDS is a list of stable Herdr pane-id strings.  A separate
`pane.agent_status_changed' subscription is required for every pane because
Herdr does not provide a wildcard status subscription.  Keeping this helper
independent of the cache lets the connection layer subscribe from an
authoritative `pane.list' before its first snapshot is installed."
  (let (subs)
    (dolist (pane-id pane-ids)
      (when (and (stringp pane-id) (not (string-empty-p pane-id)))
        (dolist (type herdr-events-per-pane-types)
          (push `(("type" . ,type) ("pane_id" . ,pane-id)) subs))))
    (nreverse subs)))

(defun herdr-events-pane-subscriptions (session)
  "Return per-pane subscription alists for SESSION.
One `pane.agent_status_changed' subscription per current pane."
  (herdr-events-pane-subscriptions-for-ids
   (delq nil (mapcar #'herdr-pane-id (herdr-model-panes session)))))

(defun herdr-events-subscriptions-for (session)
  "Return the full subscription set for SESSION: global + per-pane.
Order: global subscriptions first, then one per-pane block per pane."
  (nconc (herdr-events-default-subscriptions)
         (herdr-events-pane-subscriptions session)))

(defun herdr-events-subscriptions-for-pane-ids (pane-ids)
  "Return global plus per-pane subscriptions for PANE-IDS.
Unlike `herdr-events-subscriptions-for', this function does not require a
parsed session cache.  It is used during connection bootstrap and stream
handover, where v0.9 servers require the subscription to be live before the
authoritative snapshot is requested."
  (nconc (herdr-events-default-subscriptions)
         (herdr-events-pane-subscriptions-for-ids pane-ids)))


;;; --- Rebuild detection --------------------------------------------

;; `pane.agent_status_changed' is scoped to a pane, so when panes come
;; and go the per-pane subscription set must be recomputed and the
;; subscription re-established (the server does not accept additional
;; subscribe requests on an existing stream).  The global and per-pane sets
;; share one stream, which is replaced together during a rebuild.
;;
;; Legacy replayed events are excluded: before Herdr 0.9 the ring drained on
;; every subscribe (global subscriptions replay from sequence 0), so a
;; `pane_created' for a pane already in the cache (from the snapshot) or
;; remembered gone is a stale replay, not a real new pane.  `apply-event'
;; flags these :replayp; rebuilding for them would resubscribe per replay,
;; and each resubscribe replays again — an infinite loop.  See
;; `herdr-model-apply-event' and `herdr--synchronize-live' (herdr.el).

(defconst herdr-events--rebuild-kinds
  '("workspace_closed" "tab_closed"
    "pane_created" "pane_closed" "pane_exited"
    "pane_moved" "pane_agent_detected")
  "Event kinds that change the pane set and so require resubscription.")

(defun herdr-events-rebuild-needed-p (descriptor)
  "Return non-nil if DESCRIPTOR describes a genuine pane-set change.
When true, the caller (herdr.el) rebuilds the per-pane subscription set
(`pane.agent_status_changed' is pane-scoped, so a new pane needs a new
per-pane subscription and the server accepts no additions to a live
stream).  A REPLAYED event (DESCRIPTOR's :replayp is non-nil) is not a
change: a `pane_created' for a pane already cached (or remembered gone)
adds no new pane — rebuilding for it would resubscribe on every such
event, and each resubscribe might re-receive it, looping.  See
`herdr-model-apply-event' for how replays are flagged."
  (and descriptor
       (not (plist-get descriptor :replayp))
       (member (plist-get descriptor :event)
               herdr-events--rebuild-kinds)))


;;; --- Local event bus ----------------------------------------------

;; Hooks are run with the descriptor plist as their sole argument.
;; The catch-all runs for every event; the category hooks run only for
;; the matching class.  agent-fleet.el builds its
;; blocked/done notification hooks on top of `herdr-event-agent-status-hook'.

(defvar herdr-event-hook nil
  "Hook run for every Herdr event.  Each function receives the
descriptor plist (:event :what :id :status ...).")

(defvar herdr-event-workspace-hook nil
  "Hook run for workspace events.  Receives the descriptor plist.")

(defvar herdr-event-tab-hook nil
  "Hook run for tab events.  Receives the descriptor plist.")

(defvar herdr-event-pane-hook nil
  "Hook run for pane events.  Receives the descriptor plist.")

(defvar herdr-event-worktree-hook nil
  "Hook run for worktree events (created/opened/removed).  Receives the
descriptor plist, whose :id is the worktree `path' (the canonical key).")

(defvar herdr-event-agent-status-hook nil
  "Hook run when an agent's status actually changes.  Receives the
descriptor plist, whose :status is the new Herdr agent status
(idle/working/blocked/done/unknown), :previous-status is the prior value,
and :changed-p is non-nil.  Duplicate/replayed status frames still reach
the catch-all hook but are suppressed here so transition consumers do not
repeat side effects.")

(defun herdr-events-dispatch (kind data)
  "Reconcile one pushed event into the cache and run event hooks.
KIND is the underscored event type; DATA is the decoded payload plist.
Returns the descriptor, or nil if there is no live cache to update."
  (let ((session (herdr-model-cache)))
    (if (null session)
        (progn
          (herdr--log 'debug "event %s dropped (no cache)" kind)
          nil)
      (let ((descriptor (herdr-model-apply-event session kind data)))
        (run-hook-with-args 'herdr-event-hook descriptor)
        (pcase (plist-get descriptor :what)
          ((or :workspace-updated :workspace-closed :workspace-focused
               :workspace-reordered)
           (run-hook-with-args 'herdr-event-workspace-hook descriptor))
          ((or :tab-updated :tab-closed :tab-focused)
           (run-hook-with-args 'herdr-event-tab-hook descriptor))
          ((or :pane-updated :pane-closed :pane-focused
               :pane-output :pane-scroll :agent-detected)
           (run-hook-with-args 'herdr-event-pane-hook descriptor))
          ((or :worktree-created :worktree-opened :worktree-removed)
           (run-hook-with-args 'herdr-event-worktree-hook descriptor))
          (:agent-status
           (when (plist-get descriptor :changed-p)
             (run-hook-with-args 'herdr-event-agent-status-hook descriptor)))
          (_ nil))
        ;; A workspace/tab close can remove several agent panes without the
        ;; server necessarily delivering separate pane_closed frames first.
        ;; Fan those authoritative removals into the pane lifecycle bus so
        ;; dashboards/tasks receive the same exit notifications.  Replayed
        ;; close events carry no cached agents and are skipped.
        (unless (plist-get descriptor :replayp)
          (dolist (agent (plist-get descriptor :closed-agents))
            (run-hook-with-args
             'herdr-event-pane-hook
             `(:event ,kind :what :pane-closed :id ,(herdr-agent-id agent)
               :agentp t :replayp nil :agent ,agent))))
        descriptor))))


(provide 'herdr-events)
;;; herdr-events.el ends here
