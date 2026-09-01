;;; agent-fleet-project.el --- project.el integration for agent-fleet -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Author: agent-fleet
;; Keywords: processes, tools, convenience, projects
;; Version: 0.4.0
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

;; The project-integration layer.  Maps Herdr-managed
;; agents to Emacs `project.el' projects by **canonical cwd**:
;; "不要仅通过 label 判断" — do not judge by workspace label alone; match by
;; `file-truename (project-root ...)`, and lets the user start/list agents
;; scoped to the current project.
;;
;; Design rules honored:
;;     `project.el' is the default backend; Projectile is opt-in via
;;        `agent-fleet-project-backend' (both yield a cwd root; the git-worktree
;;        normalization runs first either way, so git repos resolve identically).
;;        Default mapping: one Emacs project ↔ one Herdr workspace.
;;     match by canonical cwd; allow multiple workspaces per repo (worktrees,
;;        investigation workspaces).  No label-based matching, no stale table —
;;        the association is *derived* from agent cwds each time.
;;     deliverables: project.el + cwd↔workspace + project-scoped dashboard,
;;        plus commands `agent-fleet-start-for-project' and
;;        `agent-fleet-project-agents'.
;;
;; This is a thin layer over the control commands (`agent-fleet-start')
;; and the model accessors (`herdr-agents', `herdr-agent-cwd',
;; `herdr-agent-workspace-id').  It adds no wire protocol.  Worktree isolation
;; (`:worktree t') is forwarded to `agent-fleet-start'.
;;
;; The workspace *label* is intentionally not set on creation: the
;; `workspace.create' label param is undocumented, and labels are not used for
;; identity anyway.  Project identity comes from agent cwd, not workspace label.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'agent-fleet)
(require 'herdr-model)


;;; --- Project backend ------------------------------------------------

(defcustom agent-fleet-project-backend 'project
  "Source for project detection: built-in `project' or `projectile'.
The default `project' uses `project-current'/`project-root' with a
`vc-root-dir' fallback.  The `projectile' backend uses
`projectile-project-root', which does its own fallback.  Either way the
git worktree normalization (`agent-fleet-project--git-common-root') runs
first, so git repos resolve identically under either backend — this only
affects how non-git or non-standard-git projects are detected.
Projectile is an optional dependency; the `projectile' backend loads it on
demand and signals a `user-error' if it is absent."
  :type '(choice (const :tag "Built-in project.el" project)
                 (const :tag "Projectile" projectile))
  :group 'agent-fleet)

;; Projectile is optional: declare the entry point so the byte-compiler does
;; not warn, without forcing a top-level `require' (mirrors the magit idiom).
(declare-function projectile-project-root "projectile" (&optional dir))

(defun agent-fleet-project--ensure-projectile ()
  "Load Projectile or signal a `user-error' that it is not installed.
Used by the project-resolution dispatch when
`agent-fleet-project-backend' is `projectile'."
  (unless (require 'projectile nil t)
    (user-error "agent-fleet-project-backend is `projectile' \
but Projectile is not installed")))


;;; --- Project root resolution ----------------------------------------

(defun agent-fleet-project--git-common-root (dir)
  "Return the primary checkout root shared by Git worktree DIR, or nil.
For a normal checkout, `git rev-parse --git-common-dir' yields ROOT/.git;
for a linked worktree it yields that same directory in the primary checkout.
Mapping both to ROOT makes all worktrees of one repository share the project
identity.  Non-standard separate git-dir layouts fall
back to `project.el' rather than guessing."
  (when (and (executable-find "git") (file-directory-p dir))
    (let ((default-directory (file-name-as-directory (file-truename dir))))
      (with-temp-buffer
        (when (eq 0 (process-file "git" nil t nil
                                  "rev-parse" "--path-format=absolute"
                                  "--git-common-dir"))
          (let* ((raw (string-trim (buffer-string)))
                 (common (and (not (string-empty-p raw))
                              (file-truename
                               (expand-file-name raw default-directory)))))
            (when (and common
                       (string= (file-name-nondirectory
                                 (directory-file-name common))
                                ".git"))
              (directory-file-name
               (file-truename (file-name-directory
                               (directory-file-name common)))))))))))

(defun agent-fleet-project--backend-root-for-cwd (dir)
  "Return the project root for DIR per `agent-fleet-project-backend', or nil.
Runs AFTER the shared git-worktree normalization, so it is only reached for
dirs the git pass left unresolved.  `project' (default) uses
`project-current'/`project-root' with a `vc-root-dir' fallback;
`projectile' uses `projectile-project-root', which does its own fallback.
Returns a `file-truename'-canonicalized directory or nil."
  (let ((default-directory (file-truename dir)))
    (pcase agent-fleet-project-backend
      ('projectile
       (agent-fleet-project--ensure-projectile)
       (when-let* ((root (projectile-project-root (file-truename dir))))
         (directory-file-name (file-truename root))))
      (_
       (let ((proj (project-current)))
         (cond
          (proj (directory-file-name (file-truename (project-root proj))))
          (t
           ;; VC fallback for repos not yet known to project.el.
           (let ((root (vc-root-dir)))
             (and root (not (string-empty-p root))
                  (directory-file-name (file-truename root)))))))))))

(defun agent-fleet-project-root-for-cwd (dir)
  "Return the canonical project root for DIR, or nil.
Resolves via the shared git-worktree normalization first
(`agent-fleet-project--git-common-root'), then the configured
`agent-fleet-project-backend' (`project' uses `project-current'/`project-root'
with a `vc-root-dir' fallback; `projectile' uses `projectile-project-root').
The result is `file-truename'-canonicalized so symlinked cwd variants of one
repo all match.
Nil-safe: nil, empty, or non-existent DIR returns nil — an empty cwd would
otherwise expand to `default-directory' (via `file-directory-p') and leak the
caller's project as the agent's."
  (when (and (stringp dir) (not (string-empty-p dir)) (file-directory-p dir))
    (or (agent-fleet-project--git-common-root (file-truename dir))
        (agent-fleet-project--backend-root-for-cwd dir))))

(defun agent-fleet-project--canonical-root (dir)
  "Return the canonical Project identity for explicit root DIR, or nil.
Unlike `agent-fleet-project-root-for-cwd', DIR is already a project root and
must not be re-discovered through the current buffer.  It still goes through
the shared Git common-root normalization so a `project.el' struct rooted at a
linked worktree matches agents in the primary checkout and sibling worktrees.
Non-Git roots retain their explicit `file-truename' identity."
  (when (and (stringp dir) (not (string-empty-p dir))
             (file-directory-p dir))
    (let ((truename (file-truename dir)))
      (or (agent-fleet-project--git-common-root truename)
          (directory-file-name truename)))))

(defun agent-fleet-project-for-agent (agent)
  "Return the canonical project root for AGENT (by its cwd), or nil."
  (agent-fleet-project-root-for-cwd (herdr-agent-cwd agent)))

(defun agent-fleet--project-root (project-or-root)
  "Normalize PROJECT-OR-ROOT to a canonical root directory string.
PROJECT-OR-ROOT is either a project struct (its `project-root' is used) or
a directory string; either way the result uses the same linked-worktree/Git
common-root Project identity as `agent-fleet-project-root-for-cwd'.  Returns
nil when PROJECT-OR-ROOT is nil or its root is not a directory."
  (when project-or-root
    (agent-fleet-project--canonical-root
     (if (stringp project-or-root)
         project-or-root
       (project-root project-or-root)))))

(defun agent-fleet-project-current ()
  "Return the current project, for `agent-fleet--project-root'.
Dispatches on `agent-fleet-project-backend': `project' returns
`(project-current)' (a project struct); `projectile' returns
`(projectile-project-root default-directory)' (a root string).  Either shape
is accepted by `agent-fleet--project-root'.  Returns nil when no project is
current."
  (pcase agent-fleet-project-backend
    ('projectile
     (agent-fleet-project--ensure-projectile)
     (projectile-project-root default-directory))
    (_ (project-current))))


;;; --- Project label (dashboard column) -------------------------------

(defun agent-fleet-project-label (agent)
  "Return a Project label for AGENT.
Returns the canonical project-root basename when a project is
resolved; \"—\" (em dash) otherwise.  A cwd without a project is NOT
labeled by its basename — presenting an arbitrary directory as a
Project would mislead the user into treating it as a codebase
identity."
  (let ((root (agent-fleet-project-for-agent agent)))
    (if (and root (file-directory-p root))
        (file-name-nondirectory (directory-file-name root))
      "—")))


;;; --- Project-scoped agent queries -----------------------------------

(defun agent-fleet-project-agents (&optional project)
  "Return the agents whose project root matches PROJECT.
PROJECT defaults to the current project (per `agent-fleet-project-backend').
It may be a project struct or a root directory string.  Matching is by
canonical cwd, so
agents in separate worktrees or checkouts of one repo all match.  Nil-safe
when not connected or when PROJECT resolves to no root."
  (let ((root (agent-fleet--project-root (or project (agent-fleet-project-current)))))
    (if (not root)
        nil
      (cl-remove-if-not
       (lambda (a)
         (let ((r (agent-fleet-project-for-agent a)))
           (and r (string= r root))))
       (herdr-agents)))))

(defun agent-fleet--workspace-for-root (root)
  "Return a workspace id hosting an agent whose project root is ROOT, or nil.
Used to co-locate a project's agents in one workspace (one
project ↔ one workspace, by default).  Returns the first match."
  (cl-loop for a in (herdr-agents)
           when (equal (agent-fleet-project-for-agent a) root)
           return (herdr-agent-workspace-id a)))


;;; --- Start for project ----------------------------------------------

;;;###autoload
(cl-defun agent-fleet-start-for-project (kind &key project name args
                                                  (timeout-ms agent-fleet-start-timeout-ms)
                                                  focus worktree branch base)
  "Start a CLI agent of KIND in Emacs project PROJECT (default: current).
Resolves the project root, then finds a Herdr workspace
already serving this project (one with an agent in it); if none, reuses the
focused workspace; if none, creates a workspace with `cwd=root'.  The agent
is started at `cwd=root' so the derived project association is immediate.

With `:worktree t', the project root becomes the source repo for a fresh
git worktree: the agent starts in an isolated checkout instead of the
normal working tree.  Optional BRANCH/BASE override the
default branch selection.  When `:worktree t' is set, the workspace/pane
resolution above is skipped — `worktree.create' provisions both.

When called interactively, if no workspace serves this project and none
is focused, the user is prompted to pick an existing workspace; the
agent's terminal is then attached automatically after start (see
`agent-fleet-attach').

KIND is a symbol like `claude' (see `agent-fleet-agent-executables').
Keyword args:
  :name        agent name (auto-generated if nil)
  :project     a project struct or root dir (default: current project,
               per `agent-fleet-project-backend')
  :args        list of extra CLI arg strings
  :timeout-ms  startup timeout (Herdr requires > 3000)
  :focus       non-nil to focus the new pane in the Herdr UI
  :worktree    non-nil to start in a fresh git worktree at the project root
  :branch      worktree branch override (with :worktree; nil = Herdr decides)
  :base        worktree base ref override (with :worktree)

Returns the `herdr-agent' for the started agent.  Signals `user-error' if
no project can be resolved."
  (interactive
   (let* ((choices (agent-fleet--kind-choices))
          (sel (completing-read "Agent kind: " (mapcar #'car choices) nil t))
          (kind (cdr (assoc sel choices #'equal)))
          (nm (read-string "Name (empty for auto): ")))
     (list kind :name (and (not (string-empty-p nm)) nm))))
  (agent-fleet--ensure-connected)
  (let ((root (agent-fleet--project-root (or project (agent-fleet-project-current)))))
    (unless root
      (user-error "No current project; call from a project buffer or pass :project"))
    (let ((interactive-p (called-interactively-p 'interactive)))
      (if worktree
          ;; A worktree start provisions its own workspace + pane via
          ;; `worktree.create'; the project root is the source repo.
          (agent-fleet-start kind :name name :cwd root :args args
                                 :timeout-ms timeout-ms :focus focus
                                 :worktree worktree :branch branch :base base
                                 :attach interactive-p)
        (let ((ws (or (agent-fleet--workspace-for-root root)
                      (when (herdr-focused-workspace)
                        (herdr-workspace-id (herdr-focused-workspace)))
                      ;; Interactive with no project/focused workspace: pick
                      ;; an existing one instead of silently creating a frame.
                      (when interactive-p
                        (agent-fleet--read-workspace "Start in workspace: ")))))
          (agent-fleet-start kind :name name :cwd root :workspace ws
                                 :args args :timeout-ms timeout-ms :focus focus
                                 :attach interactive-p))))))


;;; --- Prompt DWIM: task reference from buffer context ----------------

(defcustom agent-fleet-prompt-dwim-max-region-chars 4000
  "Maximum region size (chars) to include verbatim in a dwim prompt.
A region larger than this is referenced by line range only — the
prompt stays small and the agent reads the file directly from its
working directory."
  :type 'integer
  :group 'agent-fleet)

(defun agent-fleet-prompt-dwim--read-agent ()
  "Read an agent, preferring one in the same Project as the buffer.
When exactly one same-Project agent exists it is used without a
prompt (the DWIM case).  Multiple same-Project agents are offered
as a filtered completion; when none exist, fall back to the
unfiltered `agent-fleet-read-agent-name'."
  (let* ((current-root (agent-fleet--project-root
                         (agent-fleet-project-current)))
         (same-project (and current-root
                            (agent-fleet-project-agents current-root))))
    (cond
     ((and same-project (= 1 (length same-project)))
      (herdr-agent-id (car same-project)))
     (same-project
      ;; Reuse the public candidate descriptors so duplicate display names
      ;; carry the same pane-id disambiguation and dashboard metadata as all
      ;; other Fleet completion UIs.  Filtering the descriptors by the
      ;; canonical Project keeps the target preference without rebuilding a
      ;; second, ambiguous candidate format here.
      (let* ((same-ids (mapcar #'herdr-agent-id same-project))
             (candidates
              (cl-remove-if-not
               (lambda (entry)
                 (member (plist-get entry :pane-id) same-ids))
               (agent-fleet-agent-candidates)))
             (alist (mapcar
                     (lambda (entry)
                       (cons (format "%s  %s"
                                     (plist-get entry :label)
                                     (agent-fleet-agent-candidate-suffix entry))
                             (plist-get entry :pane-id)))
                     candidates))
             (choice (completing-read "Prompt agent (same project): "
                                      alist nil t)))
        (cdr (assoc choice alist))))
     (t (agent-fleet-read-agent-name "Prompt agent")))))

(defun agent-fleet-prompt-dwim--context (project-root)
  "Build a task-reference string from the current buffer context.
PROJECT-ROOT is the selected agent's working directory (for making the
file path relative), or nil.  Gathers: the buffer's file path
(relative to the selected agent's working directory when under it, else
absolute truename),
the active region's line range, the symbol near point, and — when
the region is small enough (see `agent-fleet-prompt-dwim-max-region-chars')
— the selected text.  Returns \"\" when nothing can be gathered."
  (let* ((file (and (buffer-file-name)
                    (let ((truename (file-truename (buffer-file-name))))
                      (if (and project-root
                               (string-prefix-p
                                (file-name-as-directory project-root)
                                truename))
                          (file-relative-name truename project-root)
                        truename))))
         (region-p (use-region-p))
         (beg (and region-p (region-beginning)))
         (end (and region-p (region-end)))
         (line1 (and beg (line-number-at-pos beg)))
         ;; REGION-END is exclusive.  Looking up its line directly includes
         ;; the next line when the selection ends at that line's first
         ;; character (for example, selecting "alpha\n" before "beta").
         (line2 (and end
                     (line-number-at-pos
                      (if (and beg (> end beg))
                          (max beg (1- end))
                        end))))
         ;; When a region is active, only report a symbol if point is inside
         ;; the selected half-open interval.  At the end boundary
         ;; `thing-at-point' would otherwise describe text outside the
         ;; selection.
         (symbol (and (or (not region-p)
                          (and beg end (>= (point) beg) (< (point) end)))
                      (thing-at-point 'symbol t)))
         (region-text (and region-p
                           (<= (- end beg)
                               agent-fleet-prompt-dwim-max-region-chars)
                           (buffer-substring-no-properties beg end))))
    (let ((loc (cond
                ((and file line1 line2 (not (= line1 line2)))
                 (format "%s:%d-%d" file line1 line2))
                ((and file line1)
                 (format "%s:%d" file line1))
                (file file))))
      (let ((base (if symbol
                      (if loc
                          (format "%s  (symbol: %s)" loc symbol)
                        (format "(symbol: %s)" symbol))
                    loc)))
        (cond
         ((and base region-text) (format "%s\n\n%s" base region-text))
         (base base)
         (t ""))))))

;;;###autoload
(defun agent-fleet-prompt-dwim (agent)
  "Send a task reference built from the current buffer to AGENT.
Gathers a lightweight reference — file path (relative to the
agent's project root when possible), the active region's line
range, the symbol near point, and the selected text when small
(see `agent-fleet-prompt-dwim-max-region-chars').  Prefers an agent
in the same Project as the current buffer; when exactly one exists
it is selected automatically.  The built reference is pre-filled into
`read-string' for review or editing before submission via
`agent-fleet-prompt'.  Does not save user files or copy an entire
buffer by default."
  (interactive
   (progn
     ;; Candidate readers inspect the cache, so establish the on-demand
     ;; connection before asking the user to choose a target.  The body keeps
     ;; its own ensure for non-interactive callers and race-safe reuse.
     (agent-fleet--ensure-connected)
     (list (agent-fleet-prompt-dwim--read-agent))))
  (let* ((struct (agent-fleet--find-agent agent))
       (root (and struct (herdr-agent-cwd struct))))
    (agent-fleet--ensure-connected)
    (let ((text (read-string "Task: "
                             (agent-fleet-prompt-dwim--context root))))
      (unless (string-empty-p text)
        (agent-fleet-prompt agent text)))))

(provide 'agent-fleet-project)
;;; agent-fleet-project.el ends here
