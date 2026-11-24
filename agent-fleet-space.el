;;; agent-fleet-space.el --- Optional Herdr App project grouping -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Herdr App adopts Core terminals carrying herdr.space and creates the
;; space, possibly well after terminal.run has completed.
;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'herdr-core)

(declare-function agent-fleet-project-checkout-for-cwd "agent-fleet-project" (cwd &optional refresh))
(declare-function agent-fleet-project--short-labels "agent-fleet-project" (roots))

(defcustom agent-fleet-herdr-app-spaces nil
  "When non-nil, group newly launched agents into local Herdr App spaces.
Each Git checkout gets its own space.  Outside projects, group by directory.
An explicit herdr.space launch label takes precedence."
  :type 'boolean :group 'agent-fleet)

(defun agent-fleet-space--id (root)
  "Derive the stable local Herdr App space ID for canonical ROOT."
  (concat "sp" (substring (secure-hash 'sha256
                                      (encode-coding-string (concat "agent-fleet:" root) 'utf-8))
                          0 32)))

(defun agent-fleet-space--launch-labels (cwd labels)
  "Return launch LABELS for canonical CWD, including Fleet ownership."
  (let ((result (plist-put (copy-sequence labels) :fleet.role "agent")))
    (when (and agent-fleet-herdr-app-spaces (not (plist-member labels :herdr.space)))
      (require 'agent-fleet-project)
      (let ((root (or (agent-fleet-project-checkout-for-cwd cwd t) (directory-file-name cwd))))
        (setq result (plist-put result :herdr.space (agent-fleet-space--id root))
              result (plist-put result :fleet.space-root root))))
    result))

(defun agent-fleet-space--roots ()
  "Index spaces automatically assigned to live local Fleet agents."
  (let ((roots (make-hash-table :test 'equal)))
    (dolist (r (herdr-core-terminals))
      (let* ((labels (plist-get r :labels)) (id (plist-get labels :herdr.space))
             (root (plist-get labels :fleet.space-root)))
        (when (and (herdr-core-local-address-p (plist-get r :address))
                   (equal (plist-get r :state) "live") (equal (plist-get labels :fleet.role) "agent")
                   (stringp root) (equal id (agent-fleet-space--id root)))
          (puthash id root roots))))
    roots))

(defvar agent-fleet-space--timer nil)

(defun agent-fleet-space--schedule ()
  "Coalesce launch, layout and reconnect notifications outside the process filter."
  (when (and agent-fleet-herdr-app-spaces (not agent-fleet-space--timer))
    (setq agent-fleet-space--timer (run-at-time 0.15 nil #'agent-fleet-space--sync))))

(defun agent-fleet-space--event (event)
  "Schedule initial naming when EVENT changes space membership or App layout."
  (when (and agent-fleet-herdr-app-spaces
             (or (member (plist-get event :type) '("created" "labels"))
                 (and (equal (plist-get event :type) "doc")
                      (equal (plist-get (plist-get event :data) :name) "herdr-app"))))
    (agent-fleet-space--schedule)))

(defun agent-fleet-space--name-empty (layout roots)
  "Fill empty names of Fleet-owned spaces in LAYOUT using ROOTS.
Return non-nil only if the App document needs a version-checked write."
  (require 'agent-fleet-project)
  (let ((spaces (and (hash-table-p layout) (gethash "spaces" layout)))
        (names (agent-fleet-project--short-labels (hash-table-values roots)))
        changed)
    (when (vectorp spaces)
      (seq-doseq (space spaces)
        (when-let* (((hash-table-p space))
                    (root (gethash (gethash "id" space) roots))
                    ((equal (gethash "name" space) "")))
          (puthash "name" (gethash root names) space)
          (setq changed t))))
    changed))

(defun agent-fleet-space--named (_result err)
  "Handle ERR from a conditional name update."
  (when err
    (if (equal (plist-get (plist-get (plist-get (cdr err) :error) :data) :kind) "conflict")
        (agent-fleet-space--schedule)
      (message "Fleet space naming: %s" (herdr-core-error-message err)))))

(defun agent-fleet-space--sync ()
  "Initialize names in existing spaces on the pinned Core."
  (setq agent-fleet-space--timer nil)
  (when (and agent-fleet-herdr-app-spaces (eq herdr-core--state 'connected))
    (let ((roots (agent-fleet-space--roots)) (core (herdr-core-id)))
      (unless (zerop (hash-table-count roots))
        (herdr-core-request-async
         "doc.get" '(:name "herdr-app")
         (lambda (doc err)
           (cond
            (err (message "Fleet space lookup: %s" (herdr-core-error-message err)))
            ((and agent-fleet-herdr-app-spaces (eq herdr-core--state 'connected)
                  (equal core (herdr-core-id)) (natnump (plist-get doc :version))
                  (agent-fleet-space--name-empty (plist-get doc :value) roots))
             (herdr-core-request-async
              "doc.set" (list :name "herdr-app" :version (plist-get doc :version)
                              :value (plist-get doc :value))
              #'agent-fleet-space--named)))))))))

(add-hook 'herdr-core-event-hook #'agent-fleet-space--event)
(add-hook 'herdr-core-snapshot-hook #'agent-fleet-space--schedule)

(provide 'agent-fleet-space)
;;; agent-fleet-space.el ends here
