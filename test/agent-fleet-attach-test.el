;;; agent-fleet-attach-test.el --- ERT tests for agent-fleet-attach.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026  agent-fleet contributors

;; Phase 8 tests: the backend abstraction (readiness/preference/fallback
;; to a nil pick when no backend is ready), the §45.1 stale-module guard,
;; argv + buffer-name, target resolution, live-buffer reuse, the
;; per-backend spawn dispatch, and the dashboard `a' key wiring.  Terminal backends (eat/ghostel/vterm)
;; are NOT required — they are stubbed via `cl-letf', mirroring how
;; `agent-fleet-magit-test' stubs Magit (PLAN §45: optional deps).  Run:
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

;; vterm-shell is a defcustom in vterm.el (an optional dep NOT on the test
;; load-path).  The vterm spawn test reads it dynamically: `--spawn' let-binds
;; `vterm-shell' to the command string and the stubbed `vterm' must see that
;; value, so the variable must be SPECIAL here.  A valueless `(defvar)'
;; does not mark a variable special (and would not propagate from
;; agent-fleet-attach.el's own declaration), so this test-local declaration
;; gives it a nil value + specialness.  It never touches real vterm (the stub
;; replaces `vterm'), so there is no clobbering risk; agent-fleet-attach.el
;; itself keeps a valueless `(defvar vterm-shell)' to avoid clobbering vterm's
;; defcustom when that package is loaded for real.
(defvar vterm-shell nil)


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
  "`--buffer-name' yields `*agent:NAME*' (PLAN §73), via the prefix defcustom."
  (let ((agent-fleet-attach-buffer-prefix "*agent:"))
    (should (equal "*agent:arch*"
                   (agent-fleet-attach--buffer-name "arch")))))


;;; --- Backend readiness: the §45.1 stale-module guard ----------------

(ert-deftest agent-fleet-attach-ghostel-ready-p-rejects-stale-module ()
  "ghostel's lisp can `require' successfully while its dynamic module does
NOT load (an older/broken module, or a missing libghostty-vt dependency) —
the stale-module case (PLAN §45.1).  `module-load' sets the
`ghostel-module' feature only on success, so `--ghostel-ready-p' must check
`featurep 'ghostel-module', NOT merely that `require' succeeded.  Here
`require' is stubbed so ghostel \"loads\" while `featurep' returns nil
(module not loaded) — ready-p must be nil.  (An earlier version probed a
symbol `ghostel-make-term' that ghostel does not expose — it was always
void, so `auto' ALWAYS fell to eat even with a working module; this test
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
  "With ghostel's module working AND eat available, `auto' prefers ghostel
(highest rendering fidelity, PLAN §45.1)."
  (let ((agent-fleet-attach-backend 'auto))
    (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
               (lambda () t))
              ((symbol-function 'agent-fleet-attach--eat-ready-p)
               (lambda () t))
              ((symbol-function 'agent-fleet-attach--vterm-ready-p)
               (lambda () t)))
      (should (eq 'ghostel (agent-fleet-attach--pick-backend))))))

(ert-deftest agent-fleet-attach-auto-falls-through-stale-ghostel-to-eat ()
  "With ghostel's module stale (ready-p nil) but eat available, `auto'
picks eat — graceful degradation (§45/§45.1; the stale-module risk realized
in the dev env, here simulated by stubbing the predicate)."
  (let ((agent-fleet-attach-backend 'auto))
    (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
               (lambda () nil))
              ((symbol-function 'agent-fleet-attach--eat-ready-p)
               (lambda () t))
              ((symbol-function 'agent-fleet-attach--vterm-ready-p)
               (lambda () nil)))
      (should (eq 'eat (agent-fleet-attach--pick-backend))))))

(ert-deftest agent-fleet-attach-auto-falls-back-to-vterm ()
  "With ghostel and eat unavailable, `auto' picks vterm (weakest fit, but
available)."
  (let ((agent-fleet-attach-backend 'auto))
    (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
               (lambda () nil))
              ((symbol-function 'agent-fleet-attach--eat-ready-p)
               (lambda () nil))
              ((symbol-function 'agent-fleet-attach--vterm-ready-p)
               (lambda () t)))
      (should (eq 'vterm (agent-fleet-attach--pick-backend))))))

(ert-deftest agent-fleet-attach-auto-with-no-backend-reports-command ()
  "With no Emacs backend ready, `auto' picks nil and the attach command
`user-error's with the `herdr agent attach' command text so the user can
run it in their own terminal (§44 path C)."
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
               (lambda () nil))
              ((symbol-function 'agent-fleet-attach--eat-ready-p)
               (lambda () nil))
              ((symbol-function 'agent-fleet-attach--vterm-ready-p)
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
the call; readiness is stubbed so `auto' resolves to eat.  No display side
effects (the real `--spawn' / `pop-to-buffer' never run)."
  (with-agent-fleet-mock path server
    (let ((agent (agent-fleet-start 'claude :name "arch")))
      (agent-fleet-test--pump)
      (let ((pid (herdr-agent-id agent))
            captured)
        (cl-letf (((symbol-function 'agent-fleet-attach--ghostel-ready-p)
                   (lambda () nil))
                  ((symbol-function 'agent-fleet-attach--eat-ready-p)
                   (lambda () t))
                  ((symbol-function 'agent-fleet-attach--vterm-ready-p)
                   (lambda () nil))
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
          (should (eq 'eat (nth 0 call)))
          (should (equal "*agent:arch*" (nth 1 call)))
          (should (equal pid (nth 2 call)))
          (should-not (nth 3 call)))))))    ; no takeover (no prefix arg)

(ert-deftest agent-fleet-attach-reuses-live-buffer ()
  "If a live attach buffer for the agent already exists (process alive),
`agent-fleet-attach' reuses it (`pop-to-buffer') instead of double-attaching
— `--spawn' is NOT called.  `pop-to-buffer' is stubbed to avoid window side
effects in batch."
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
              (cl-letf (((symbol-function 'agent-fleet-attach--eat-ready-p)
                         (lambda () t))
                        ((symbol-function 'agent-fleet-attach--spawn)
                         (lambda (&rest _) (setq spawn-called t)))
                        ((symbol-function 'pop-to-buffer)
                         (lambda (_buf &rest _) nil)))
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
                       (lambda () 'eat))
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
                       (lambda () 'eat))
                      ((symbol-function 'agent-fleet-attach--spawn)
                       (lambda (&rest _) (setq spawn-called t)))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) (setq popped buffer))))
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

(ert-deftest agent-fleet-attach-spawn-via-eat ()
  "`--spawn' with the eat backend enables `eat-mode' then calls `eat-exec'
with the buffer, the `herdr' program, and the attach argv.  `eat-mode' and
`eat-exec' are stubbed so no real terminal/process is spawned."
  (let ((eat-called nil)
        (mode-called nil)
        (pop-inhibited nil)
        (buf-name "*agent:arch-eat*"))
    (unwind-protect
        (cl-letf (((symbol-function 'eat-mode)
                   (lambda () (setq mode-called t)))
                  ((symbol-function 'eat-exec)
                   (lambda (buffer name command startfile switches)
                     (push (list buffer name command startfile switches)
                           eat-called)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _)
                     (setq pop-inhibited
                           (buffer-local-value
                            'evil-escape-inhibit (get-buffer buffer))))))
          (agent-fleet-attach--spawn 'eat buf-name "w4:p1" nil))
      (when (get-buffer buf-name) (kill-buffer buf-name)))
    (should mode-called)
    (should pop-inhibited)
    (should (= 1 (length eat-called)))
    (should (equal buf-name (nth 0 (car eat-called))))     ; buffer
    (should (equal "herdr"     (nth 2 (car eat-called))))  ; command
    (should (equal '("agent" "attach" "w4:p1")
                   (nth 4 (car eat-called))))))            ; switches = argv

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
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _)
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

(ert-deftest agent-fleet-attach-spawn-via-vterm ()
  "`--spawn' with vterm sets `vterm-shell' to the space-joined,
shell-quoted command string and calls `vterm'.  vterm has no argv launch
API: it runs `vterm-shell' via `sh -c \"exec <vterm-shell>\"', so the
command+args are shell-quoted into one string (pane-ids have no spaces)."
  (let ((buf-name "*agent:arch-vterm*")
        vterm-shell-seen vterm-called pop-inhibited)
    (unwind-protect
        (cl-letf (((symbol-function 'vterm)
                   (lambda (&optional buffer)
                     (get-buffer-create buffer)
                     (setq vterm-shell-seen vterm-shell
                           vterm-called t)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _)
                     (setq pop-inhibited
                           (buffer-local-value
                            'evil-escape-inhibit (get-buffer buffer))))))
          ;; `vterm-shell' is declared special in agent-fleet-attach.el, so
          ;; this binding is dynamic and visible to the stubbed `vterm'.
          (let ((vterm-shell "sentinel"))
            (agent-fleet-attach--spawn 'vterm buf-name "w4:p1" nil)))
      (when (get-buffer buf-name) (kill-buffer buf-name)))
    (should vterm-called)
    (should pop-inhibited)
    (should (stringp vterm-shell-seen))
    (should (string-match-p "herdr" vterm-shell-seen))
    (should (string-match-p "agent" vterm-shell-seen))
    (should (string-match-p "attach" vterm-shell-seen))
    ;; pane-id shell-quoted by `shell-quote-argument' (the colon may be
    ;; backslash-escaped or quote-wrapped depending on the platform; both
    ;; are sh-safe), so match the pane id with an optional backslash before
    ;; the colon.
    (should (string-match-p "w4\\\\?:p1" vterm-shell-seen))
    (should-not (string-match-p "sentinel" vterm-shell-seen))))


;;; --- Dashboard `a' key wiring ---------------------------------------

(ert-deftest agent-fleet-dashboard-attach-key-bound ()
  "The dashboard mode-map binds `a' to `agent-fleet-dashboard-attach'
(PLAN §73; mirrors the `d'/`m'/`T' wiring tests)."
  (should (eq #'agent-fleet-dashboard-attach
              (lookup-key agent-fleet-mode-map "a"))))

(provide 'agent-fleet-attach-test)
;;; agent-fleet-attach-test.el ends here
