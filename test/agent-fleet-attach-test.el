;;; agent-fleet-attach-test.el --- ERT tests for agent-fleet-attach.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Tests: the backend abstraction (readiness/preference/fallback
;; to a nil pick when no backend is ready), the stale-module guard,
;; argv + buffer-name, target resolution, live-buffer reuse, the
;; per-backend spawn dispatch, and the dashboard `a' key wiring.  ghostel
;; are NOT required — they are stubbed via `cl-letf', mirroring how
;; `agent-fleet-magit-test' stubs Magit.  Run:
;;   emacs -batch -L . -L test -l ert -l herdr -l agent-fleet \
;;         -l agent-fleet-attach -l agent-fleet-dashboard \
;;         -l herdr-mock-server -l test/agent-fleet-test \
;;         -l test/agent-fleet-attach-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr)
(require 'herdr-model)
(require 'agent-fleet)
(require 'agent-fleet-attach)
(require 'agent-fleet-dashboard)
(require 'herdr-mock-server)
(require 'agent-fleet-test)            ; harness: with-agent-fleet-mock, --pump

;;; --- argv + buffer-name (pure core) ---------------------------------

(ert-deftest agent-fleet-attach-argv ()
  "`--argv' builds the `herdr agent attach' subcommand argv; TAKEOVER
appends `--takeover'.  `agent' and `attach' are subcommand words — the
program `herdr' is prepended by the backend launch, not by `--argv'."
  (should (equal '("agent" "attach" "w4:p1")
                 (agent-fleet-attach--argv "w4:p1" nil)))
  (should (equal '("agent" "attach" "w4:p1" "--takeover")
                 (agent-fleet-attach--argv "w4:p1" t))))

(ert-deftest agent-fleet-attach-buffer-name ()
  "`--buffer-name' yields `*agent:NAME*', via the prefix defcustom."
  (let ((agent-fleet-attach-buffer-prefix "*agent:"))
    (should (equal "*agent:arch*"
                   (agent-fleet-attach--buffer-name "arch")))))


;;; --- Backend readiness: the stale-module guard ----------------

(ert-deftest agent-fleet-attach-ghostel-ready-p-rejects-stale-module ()
  "ghostel's lisp can `require' successfully while its dynamic module does
NOT load (an older/broken module, or a missing libghostty-vt dependency) —
the stale-module case.  `module-load' sets the
`ghostel-module' feature only on success, so `--ghostel-ready-p' must check
`featurep 'ghostel-module', NOT merely that `require' succeeded.  Here
`require' is stubbed so ghostel \"loads\" while `featurep' returns nil
(module not loaded) — ready-p must be nil.  (An earlier version probed a
symbol `ghostel-make-term' that ghostel does not expose — it was always
void, so `auto' always yielded no backend even with a working module; this test
now pins the real guard.)"
  (let ((real-require (symbol-function 'require))
        (real-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional file noerror)
                 (if (eq feature 'ghostel)
                     t                  ; lisp "loaded"
                   (funcall real-require feature file noerror))))
              ((symbol-function 'featurep)
               (lambda (feature &optional sub)
                 (if (eq feature 'ghostel-module)
                     nil                ; module did NOT load
                   (funcall real-featurep feature sub)))))
      (should-not (agent-fleet-attach--ghostel-ready-p)))))

(ert-deftest agent-fleet-attach-ghostel-ready-p-accepts-loaded-module ()
  "When ghostel's lisp loads AND the module loaded (featurep t), ready-p is
non-nil — `auto' picks ghostel (native libghostty-vt, fastest)."
  (let ((real-require (symbol-function 'require))
        (real-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional file noerror)
                 (if (eq feature 'ghostel)
                     t
                   (funcall real-require feature file noerror))))
              ((symbol-function 'featurep)
               (lambda (feature &optional sub)
                 (if (eq feature 'ghostel-module)
                     t                  ; module loaded
                   (funcall real-featurep feature sub))))
              ((symbol-function 'ghostel-exec) (lambda (&rest _))))
      (should (agent-fleet-attach--ghostel-ready-p)))))

(ert-deftest agent-fleet-attach-ghostel-ready-p-requires-entry-point ()
  "A provided module without ghostel-exec is not a usable backend."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
            ((symbol-function 'featurep)
             (lambda (feature &optional _sub)
               (memq feature '(ghostel ghostel-module))))
            ((symbol-function 'fboundp)
             (lambda (symbol) (not (eq symbol 'ghostel-exec)))))
    (should-not (agent-fleet-attach--ghostel-ready-p))))


;;; --- Backend selection (auto preference + fallbacks) -----------------

(ert-deftest agent-fleet-attach-auto-prefers-ghostel-when-ready ()
  "With ghostel's module working, `auto' picks ghostel
(highest rendering fidelity)."
  (let ((agent-fleet-attach-backend 'auto))
    (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
               (lambda () t)))
      (should (eq 'ghostel (agent-fleet-attach--pick-backend))))))

(ert-deftest agent-fleet-attach-auto-with-no-backend-reports-command ()
  "With no Emacs backend ready, `auto' picks nil and the attach command
`user-error's with the `herdr agent attach' command text so the user can
run it in their own terminal (path C)."
  (let ((agent-fleet-attach-backend 'auto))
    (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
              ((symbol-function 'agent-fleet--find-agent)
               (lambda (_) (make-herdr-agent :id "w4:p1" :name "x")))
              ((symbol-function 'agent-fleet--resolve-pane-id)
               (lambda (_) "w4:p1"))
              ((symbol-function 'herdr-agent-display-name)
               (lambda (_) "x"))
              ((symbol-function 'agent-fleet-attach--live-buffer-for-pane)
               (lambda (_) nil))
              ((symbol-function 'agent-fleet-attach--live-buffer-p)
               (lambda (_b _p) nil))
              ((symbol-function 'agent-fleet-attach--ghostel-ready-p)
               (lambda () nil)))
      (should-not (agent-fleet-attach--pick-backend))
      (let ((err (should-error (agent-fleet-attach "x")
                               :type 'user-error)))
        (should (string-match-p "herdr agent attach" (cadr err)))
        (should (string-match-p "w4:p1" (cadr err))))
      ;; A takeover request appends `--takeover' to the suggested command.
      (let ((err (should-error (agent-fleet-attach "x" t)
                               :type 'user-error)))
        (should (string-match-p "--takeover" (cadr err)))))))

(ert-deftest agent-fleet-attach-explicit-unavailable-backend-errors ()
  "An explicit backend that is not ready `user-error's — reported, not
silently substituted (set `auto' for graceful fallback)."
  (let ((agent-fleet-attach-backend 'ghostel))
    (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
               (lambda () nil)))
      (should-error (agent-fleet-attach--pick-backend) :type 'user-error))))


;;; --- Target resolution + live-buffer reuse (the command) -------------

(ert-deftest agent-fleet-attach-resolves-target-and-spawns ()
  "`agent-fleet-attach' resolves a struct/name/symbol/pane-id to a real
pane-id and dispatches `--spawn' with it.  `--spawn' is stubbed to capture
the call; readiness is stubbed so `auto' resolves to ghostel.  No display side
effects (the real `--spawn' / `--display' never run)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((pid (herdr-agent-id agent))
            captured)
        (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
                   (lambda () t))
                  ((symbol-function 'agent-fleet-attach--spawn)
                   (lambda (backend buf-name pane-id takeover)
                     (push (list backend buf-name pane-id takeover)
                           captured))))
          (agent-fleet-attach agent)        ; by struct
          (agent-fleet-attach "arch")       ; by name
          (agent-fleet-attach 'arch)        ; by symbol
          (agent-fleet-attach pid))         ; by pane-id string
        (should (= 4 (length captured)))
        (dolist (call captured)
          (should (eq 'ghostel (nth 0 call)))
          (should (equal "*agent:arch*" (nth 1 call)))
          (should (equal pid (nth 2 call)))
          (should-not (nth 3 call)))))))    ; no takeover (no prefix arg)

(ert-deftest agent-fleet-start-attaches-when-attach-flag ()
  "A start with :attach t (how interactive starts and wrapper commands
forward their interactivity) attaches the agent's terminal after a
successful start, dispatching `--spawn' with the new pane id.  Readiness
is stubbed so `auto' resolves to ghostel; `--spawn' is stubbed to capture
the dispatch, so no display side effects run."
  (with-agent-fleet-mock path server
    (let (captured)
      (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
                 (lambda () t))
                ((symbol-function 'agent-fleet-attach--spawn)
                 (lambda (backend buf-name pane-id takeover)
                   (push (list backend buf-name pane-id takeover) captured))))
        (let ((agent (agent-fleet-start 'claude :name "arch" :attach t)))
          (should (herdr-agent-p agent))
          (should (= 1 (length captured)))
          (should (eq 'ghostel (nth 0 (car captured))))
          (should (equal (herdr-agent-id agent) (nth 2 (car captured))))
          (should-not (nth 3 (car captured))))))))  ; no takeover

(ert-deftest agent-fleet-attach-reuses-live-buffer ()
  "If a live attach buffer for the agent already exists (process alive),
`agent-fleet-attach' reuses it (displaying it via `--display') instead of
double-attaching — `--spawn' is NOT called.  `--display' is stubbed to
avoid window side effects in batch."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((buf-name (agent-fleet-attach--buffer-name
                       (herdr-agent-display-name agent)))
            spawn-called)
        (unwind-protect
            (progn
              ;; simulate an existing live attach buffer: a buffer whose
              ;; associated process is running.
              (with-current-buffer (get-buffer-create buf-name)
                (setq-local agent-fleet-attach-pane-id
                            (herdr-agent-id agent))
                (start-process "fake-attach" buf-name "sleep" "30"))
              (should (agent-fleet-attach--live-buffer-p
                       buf-name (herdr-agent-id agent)))
              (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
                         (lambda () t))
                        ((symbol-function 'agent-fleet-attach--spawn)
                         (lambda (&rest _) (setq spawn-called t)))
                        ((symbol-function 'agent-fleet-attach--display)
                         (lambda (_buf) nil)))
                (agent-fleet-attach agent))
              (should-not spawn-called)
              (should (buffer-local-value 'evil-escape-inhibit
                                           (get-buffer buf-name))))
          (when (get-buffer buf-name)
            (let ((proc (get-buffer-process (get-buffer buf-name))))
              (when proc (delete-process proc)))
            (kill-buffer buf-name)))))))

(ert-deftest agent-fleet-attach-same-display-name-never-reuses-other-pane ()
  "Two panes with one display label get distinct attach buffers."
  (let* ((session (herdr-model--empty-session))
         (workspace (make-herdr-workspace :id "w1" :cached-label "demo"
                                           :custom-name "demo"))
         (first (make-herdr-agent :id "w1:p1" :workspace-id "w1"
                                  :agent "claude"))
         (second (make-herdr-agent :id "w1:p2" :workspace-id "w1"
                                   :agent "codex"))
         (base (agent-fleet-attach--buffer-name "demo"))
         captured)
    (puthash "w1" workspace (herdr-session-workspaces session))
    (puthash "w1:p1" first (herdr-session-agents session))
    (puthash "w1:p2" second (herdr-session-agents session))
    (let ((herdr-model--cache session))
      (unwind-protect
          (progn
            (with-current-buffer (get-buffer-create base)
              (setq-local agent-fleet-attach-pane-id "w1:p1")
              (start-process "fake-attach-collision" base "sleep" "30"))
            (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                      ((symbol-function 'agent-fleet-attach--pick-backend)
                       (lambda () 'ghostel))
                      ((symbol-function 'agent-fleet-attach--spawn)
                       (lambda (_backend buffer pane-id _takeover)
                         (setq captured (list buffer pane-id)))))
              (agent-fleet-attach second))
            (should (equal "w1:p2" (cadr captured)))
            (should-not (equal base (car captured)))
            (should (string-match-p "w1:p2" (car captured))))
        (when-let* ((buf (get-buffer base)))
          (when-let* ((proc (get-buffer-process buf)))
            (delete-process proc))
          (kill-buffer buf))))))

(ert-deftest agent-fleet-attach-reuses-pane-after-buffer-name-changes ()
  "A live attach is found by pane id after collision/rename changes its name."
  (let* ((session (herdr-model--empty-session))
         (workspace (make-herdr-workspace :id "w1" :cached-label "renamed"
                                           :custom-name "renamed"))
         (agent (make-herdr-agent :id "w1:p2" :workspace-id "w1"
                                  :agent "codex"))
         ;; Simulate a buffer created earlier under a collision-safe or old
         ;; display name.  There is deliberately no current base-name buffer.
         (old-name "*agent:old [w1:p2]*")
         spawn-called popped)
    (puthash "w1" workspace (herdr-session-workspaces session))
    (puthash "w1:p2" agent (herdr-session-agents session))
    (let ((herdr-model--cache session))
      (unwind-protect
          (progn
            (with-current-buffer (get-buffer-create old-name)
              (setq-local agent-fleet-attach-pane-id "w1:p2")
              (start-process "fake-attach-renamed" old-name "sleep" "30"))
            (cl-letf (((symbol-function 'agent-fleet--ensure-connected) #'ignore)
                      ((symbol-function 'agent-fleet-attach--pick-backend)
                       (lambda () 'ghostel))
                      ((symbol-function 'agent-fleet-attach--spawn)
                       (lambda (&rest _) (setq spawn-called t)))
                      ((symbol-function 'agent-fleet-attach--display)
                       (lambda (buffer) (setq popped buffer))))
              (agent-fleet-attach agent))
            (should-not spawn-called)
            (should (equal old-name popped)))
        (when-let* ((buf (get-buffer old-name)))
          (when-let* ((proc (get-buffer-process buf)))
            (delete-process proc))
          (kill-buffer buf))))))

(ert-deftest agent-fleet-attach-live-buffer-p-ignores-dead ()
  "`--live-buffer-p' is nil for a buffer with NO process (e.g. a stale
leftover buffer from a crashed session) so a fresh attach is spawned."
  (let ((buf-name "*agent:fresh-test*"))
    (unwind-protect
        (progn
          (get-buffer-create buf-name)
          (should-not (agent-fleet-attach--live-buffer-p buf-name)))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))

(ert-deftest agent-fleet-attach-prepare-buffer-inhibits-evil-escape-locally ()
  "Attach input disables evil-escape's synthetic first-key insertion locally.
The global/default value must remain untouched, so `jk' continues to work in
ordinary Evil editing buffers."
  (let ((buf (generate-new-buffer " *agent-fleet-evil-escape*"))
        (evil-escape-inhibit nil)
        (agent-fleet-attach-inhibit-evil-escape t))
    (unwind-protect
        (progn
          (should-not (buffer-local-value 'evil-escape-inhibit buf))
          (should (eq buf (agent-fleet-attach--prepare-buffer buf)))
          (should (local-variable-p 'evil-escape-inhibit buf))
          (should (buffer-local-value 'evil-escape-inhibit buf))
          (should-not evil-escape-inhibit))
      (kill-buffer buf))))

(ert-deftest agent-fleet-attach-prepare-buffer-can-be-disabled ()
  "The evil-escape safeguard honors its explicit opt-out."
  (let ((buf (generate-new-buffer " *agent-fleet-evil-escape-opt-out*"))
        (agent-fleet-attach-inhibit-evil-escape nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local evil-escape-inhibit t))
          (should (eq buf (agent-fleet-attach--prepare-buffer buf)))
          (should-not (local-variable-p 'evil-escape-inhibit buf))
          (should-not (buffer-local-value 'evil-escape-inhibit buf)))
      (kill-buffer buf))))


;;; --- Spawn dispatch (per backend, entry points stubbed) --------------

(ert-deftest agent-fleet-attach-spawn-via-ghostel ()
  "`--spawn' creates Ghostel's buffer before calling `ghostel-exec'.
The real `ghostel-exec' starts with `with-current-buffer' and therefore
signals `No buffer named ...' when callers pass an uncreated name.  Pin
both that precondition and the attach argv (TAKEOVER adds `--takeover')."
  (let ((buf-name "*agent:arch-ghostel*")
        ghostel-called pop-inhibited)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel-exec)
                   (lambda (buffer program &optional args)
                     (push (list (bufferp buffer)
                                 (buffer-live-p buffer)
                                 (buffer-name buffer)
                                 program args)
                           ghostel-called)))
                  ((symbol-function 'agent-fleet-attach--display)
                   (lambda (buffer)
                     (setq pop-inhibited
                           (buffer-local-value
                            'evil-escape-inhibit (get-buffer buffer))))))
          (agent-fleet-attach--spawn 'ghostel buf-name "w4:p1" t))
      (when (get-buffer buf-name) (kill-buffer buf-name)))
    (should (= 1 (length ghostel-called)))
    (should pop-inhibited)
    (should (eq t (nth 0 (car ghostel-called))))
    (should (eq t (nth 1 (car ghostel-called))))
    (should (equal buf-name (nth 2 (car ghostel-called))))
    (should (equal "herdr" (nth 3 (car ghostel-called))))
    (should (equal '("agent" "attach" "w4:p1" "--takeover")
                   (nth 4 (car ghostel-called))))))


;;; --- Presentation: same-window display ------------------------------

(ert-deftest agent-fleet-attach-display-uses-same-window ()
  "`--display' replaces the selected window without creating a split."
  (let* ((window (selected-window))
         (old-buffer (window-buffer window))
         (old-dedicated (window-dedicated-p window))
         (window-count (length (window-list nil 'nomini)))
         (buf (generate-new-buffer "*agent:display-test*")))
    (unwind-protect
        (progn
          (set-window-dedicated-p window nil)
          (should (eq window (agent-fleet-attach--display buf)))
          (should (eq buf (window-buffer window)))
          (should (= window-count (length (window-list nil 'nomini)))))
      (set-window-dedicated-p window nil)
      (set-window-buffer window old-buffer)
      (set-window-dedicated-p window old-dedicated)
      (kill-buffer buf))))

(ert-deftest agent-fleet-attach-display-replaces-dedicated-window ()
  "A dedicated selected window is reused, never bypassed with a new split."
  (let* ((window (selected-window))
         (old-buffer (window-buffer window))
         (old-dedicated (window-dedicated-p window))
         (window-count (length (window-list nil 'nomini)))
         (buf (generate-new-buffer "*agent:dedicated-display-test*")))
    (unwind-protect
        (progn
          (set-window-dedicated-p window t)
          (should (eq window (agent-fleet-attach--display buf)))
          (should (eq buf (window-buffer window)))
          (should (window-dedicated-p window))
          (should (= window-count (length (window-list nil 'nomini)))))
      (set-window-dedicated-p window nil)
      (set-window-buffer window old-buffer)
      (set-window-dedicated-p window old-dedicated)
      (kill-buffer buf))))


;;; --- Dashboard `a' key wiring ---------------------------------------

(ert-deftest agent-fleet-dashboard-attach-key-bound ()
  "The dashboard mode-map binds `a' to `agent-fleet-dashboard-attach'
."
  (should (eq #'agent-fleet-dashboard-attach
              (lookup-key agent-fleet-mode-map "a"))))

(provide 'agent-fleet-attach-test)
;;; agent-fleet-attach-test.el ends here
