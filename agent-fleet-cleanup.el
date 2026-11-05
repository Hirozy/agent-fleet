;;; agent-fleet-cleanup.el --- Review finished Core history -*- lexical-binding: t; -*-
;;; Commentary:
;; Only terminal.rm is dispatched.  No process termination or filesystem deletion.
;;; Code:
(require 'agent-fleet)
(defface agent-fleet-cleanup-title
  '((t (:inherit bold :height 1.2)))
  "Heading for cleanup reviews and results."
  :group 'agent-fleet)
(defface agent-fleet-cleanup-directory
  '((t (:inherit font-lock-keyword-face :weight bold)))
  "Directory headings in cleanup reviews and results."
  :group 'agent-fleet)
(defvar-local agent-fleet-cleanup--items nil)
(defvar-local agent-fleet-cleanup--display-items nil)
(defvar-local agent-fleet-cleanup--core nil)
(defvar-local agent-fleet-cleanup--state nil)
(defvar agent-fleet-cleanup-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map agent-fleet-review-mode-map)
    (define-key map (kbd "SPC") #'agent-fleet-cleanup-toggle)
    (define-key map (kbd "n") #'agent-fleet-cleanup-next)
    (define-key map (kbd "p") #'agent-fleet-cleanup-previous)
    (define-key map (kbd "C-c C-c") #'agent-fleet-cleanup-execute) map))
(define-derived-mode agent-fleet-cleanup-mode agent-fleet-review-mode "Fleet Cleanup"
  "Review exact finished records before removing their retained history."
  (hl-line-mode 1))

(defun agent-fleet-cleanup--records ()
  "Read and validate a complete, fresh Core terminal inventory."
  (let* ((result (herdr-core-request "terminal.list" '(:all t)))
         (records (plist-get result :terminals)))
    (unless (and (plist-member result :terminals)
                 (cl-every #'herdr-core--valid-terminal-p records))
      (error "Invalid Core inventory; cleanup refused"))
    records))

(defun agent-fleet-cleanup--table (records)
  "Index fresh RECORDS for ownership queries."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (r records) (puthash (plist-get r :address) r table)) table))

(defun agent-fleet-cleanup--depth (record table)
  "Measure RECORD's parent depth in TABLE, tolerating cycles."
  (let ((n 0) seen)
    (while (and record (not (member (plist-get record :address) seen)))
      (push (plist-get record :address) seen)
      (setq record (gethash (plist-get record :parent) table))
      (cl-incf n))
    n))

(defun agent-fleet-cleanup--scan (records)
  "Return review items for eligible RECORDS, children before their parents."
  (let* ((table (agent-fleet-cleanup--table records))
         (herdr-core--terminals table)
         (candidates (cl-remove-if-not
                      (lambda (r) (and (agent-fleet-managed-p r)
                                        (equal (plist-get r :state) "finished"))) records)))
    (setq candidates
          (sort candidates (lambda (a b) (> (agent-fleet-cleanup--depth a table)
                                            (agent-fleet-cleanup--depth b table)))))
    (mapcar (lambda (r) (list :reference (agent-fleet-reference r)
                              :record r :selected t :status 'pending :reason nil :error nil)) candidates)))

(defun agent-fleet-cleanup--face (status)
  "Return the semantic face for STATUS."
  (pcase status
    ('removed 'success) ((or 'failed 'uncertain) 'error)
    ((or 'skipped 'pending) 'warning) (_ 'default)))

(defun agent-fleet-cleanup--groups ()
  "Group items by literal directory without changing execution order."
  (let (groups)
    (dolist (item agent-fleet-cleanup--items)
      (let* ((directory (plist-get (plist-get item :record) :cwd))
             (group (assoc directory groups)))
        (if group (setcdr group (cons item (cdr group)))
          (push (list directory item) groups))))
    (mapcar (lambda (group) (cons (car group) (nreverse (cdr group))))
            (nreverse groups))))

(defun agent-fleet-cleanup--insert-item (item review name-width)
  "Insert ITEM as a REVIEW or result row with NAME-WIDTH columns."
  (let* ((record (plist-get item :record))
         (status (plist-get item :status))
         (name (agent-fleet-name record))
         (begin (point)))
    (insert "  "
            (propertize
             (format "%-14s" (if review
                                    (if (plist-get item :selected) "[x] Remove" "[ ] Keep")
                                  (if (eq status 'pending) "Not attempted"
                                    (capitalize (symbol-name status)))))
             'face (if review
                       (if (plist-get item :selected) 'font-lock-keyword-face 'shadow)
                     (agent-fleet-cleanup--face status)))
            (propertize name 'face 'bold)
            (make-string (+ 2 (max 0 (- name-width (string-width name)))) ?\s)
            (propertize (plist-get record :address) 'face 'shadow) "\n")
    (when-let* ((reason (plist-get item :reason)))
      (insert (propertize
               (concat "    " (replace-regexp-in-string "\n" "\n    " reason t t) "\n")
               'face (agent-fleet-cleanup--face status))))
    (add-text-properties begin (point) (list 'fleet-cleanup-item item))))

(defun agent-fleet-cleanup--render ()
  "Render this review and its retained per-record outcomes."
  (let ((inhibit-read-only t)
        (current-item (get-text-property (point) 'fleet-cleanup-item))
        (review (eq agent-fleet-cleanup--state 'review))
        (groups (agent-fleet-cleanup--groups))
        (name-width (apply #'max 5 (mapcar
                                   (lambda (item)
                                     (string-width (agent-fleet-name (plist-get item :record))))
                                   agent-fleet-cleanup--items))))
    (erase-buffer)
    (insert (propertize (if review "Review finished history\n" "Cleanup results\n")
                        'face 'agent-fleet-cleanup-title) "\n")
    (insert
     (if review
         (propertize (format "%d of %d records selected\n"
                 (cl-count-if (lambda (item) (plist-get item :selected)) agent-fleet-cleanup--items)
                 (length agent-fleet-cleanup--items)) 'face 'bold)
       (concat
        (mapconcat
         #'identity
         (delq nil
               (mapcar (lambda (status)
                         (let ((count (cl-count status agent-fleet-cleanup--items
                                                :key (lambda (item) (plist-get item :status)))))
                           (when (> count 0)
                             (propertize
                              (format "%d %s" count (if (eq status 'pending) "not attempted" status))
                              'face (list :inherit (agent-fleet-cleanup--face status) :weight 'bold)))))
                       '(removed skipped failed uncertain pending))) "  ·  ")
        "\n")))
    (insert (propertize
             (if review "Removes terminal records and output history.\n"
               "Finished records and their output history only.\n") 'face 'shadow)
            (propertize "Live programs and code directories are preserved.\n" 'face 'shadow))
    (setq agent-fleet-cleanup--display-items (apply #'append (mapcar #'cdr groups)))
    (dolist (group groups)
      (insert "\n" (propertize (or (car group) "No directory reported")
                                 'face 'agent-fleet-cleanup-directory)
              (propertize (format "  (%d)\n" (length (cdr group))) 'face 'shadow)
              (propertize (format (format "  %%-14s%%-%ds  ID\n" name-width)
                                  (if review "Selection" "Result") "Agent")
                          'face 'shadow))
      (dolist (item (cdr group))
        (agent-fleet-cleanup--insert-item item review name-width)))
    (setq header-line-format
          (if (eq agent-fleet-cleanup--state 'review)
              "n/p records   SPC include/exclude   C-c C-c execute   q / C-g cancel"
            "n/p records   q close"))
    (goto-char (or (and current-item
                        (text-property-any (point-min) (point-max) 'fleet-cleanup-item current-item))
                   (text-property-not-all (point-min) (point-max) 'fleet-cleanup-item nil)
                   (point-min)))
    (set-buffer-modified-p nil)))

(defun agent-fleet-cleanup--move (direction)
  "Move by DIRECTION between records, skipping paths and diagnostics."
  (let* ((item (get-text-property (point) 'fleet-cleanup-item))
         (index (and item (cl-position item agent-fleet-cleanup--display-items :test #'eq)))
         (next (if index (+ index direction)
                 (if (> direction 0) 0 (1- (length agent-fleet-cleanup--display-items)))))
         (target (nth (max 0 (min next (1- (length agent-fleet-cleanup--display-items))))
                      agent-fleet-cleanup--display-items)))
    (when target
      (goto-char (text-property-any (point-min) (point-max) 'fleet-cleanup-item target)))))

;;;###autoload
(defun agent-fleet-cleanup-next ()
  "Move to the next reviewed record."
  (interactive)
  (agent-fleet-cleanup--move 1))

;;;###autoload
(defun agent-fleet-cleanup-previous ()
  "Move to the previous reviewed record."
  (interactive)
  (agent-fleet-cleanup--move -1))

;;;###autoload
(defun agent-fleet-cleanup ()
  "Review all finished Fleet records on this connection, then execute once."
  (interactive)
  (herdr-core-connect)
  (let* ((items (agent-fleet-cleanup--scan (agent-fleet-cleanup--records)))
         (buffer (and items (generate-new-buffer "*Fleet Cleanup*"))))
    (if (not items) (progn (message "No finished Fleet records to clean") nil)
      (with-current-buffer buffer
        (agent-fleet-cleanup-mode)
        (setq agent-fleet-cleanup--items items agent-fleet-cleanup--core (herdr-core-id)
              agent-fleet-cleanup--state 'review)
        (agent-fleet-cleanup--render))
      (agent-fleet-present-buffer buffer))))

(defun agent-fleet-cleanup-toggle ()
  "Toggle the record on this line."
  (interactive)
  (unless (eq agent-fleet-cleanup--state 'review) (user-error "Review already executed"))
  (let ((item (get-text-property (point) 'fleet-cleanup-item)))
    (unless item (user-error "No record on this line"))
    (setf (plist-get item :selected) (not (plist-get item :selected)))
    (agent-fleet-cleanup--render)))

(defun agent-fleet-cleanup--preflight (item)
  "Revalidate ITEM, returning its current record or a reason to retain it."
  (unless (and (eq herdr-core--state 'connected)
               (equal agent-fleet-cleanup--core (herdr-core-id)))
    (error "Connection changed; create a fresh review"))
  (let* ((records (agent-fleet-cleanup--records))
         (table (agent-fleet-cleanup--table records))
         (herdr-core--terminals table)
         (identity (plist-get (plist-get item :reference) :fleet-identity))
         (address (herdr-core-identity-address identity))
         (record (gethash address table)))
    (cond
     ((not record) "Record is no longer present")
     ((not (equal identity (herdr-core-identity record))) "Identity changed")
     ((not (equal (plist-get record :state) "finished")) "Program is live")
     ((not (agent-fleet-managed-p record)) "Fleet association is no longer established")
     ((cl-some (lambda (r) (equal address (plist-get r :parent))) records)
      "Retained: child records still reference this parent")
     (t record))))

(defun agent-fleet-cleanup-execute ()
  "Execute the reviewed selection once; retain partial and uncertain outcomes."
  (interactive)
  (unless (eq agent-fleet-cleanup--state 'review) (user-error "Create a fresh cleanup review"))
  (setq agent-fleet-cleanup--state 'running)
  (let (stop)
    (dolist (item agent-fleet-cleanup--items)
      (cond
       (stop (setf (plist-get item :reason) "Not attempted after an interrupted or uncertain operation"))
       ((not (plist-get item :selected))
        (setf (plist-get item :status) 'skipped (plist-get item :reason) "Excluded in review"))
       (t
        (let (dispatched)
          (condition-case err
              (let ((record (agent-fleet-cleanup--preflight item)))
                (if (stringp record)
                    (setf (plist-get item :status) 'skipped (plist-get item :reason) record)
                  (setq dispatched t)
                  (let* ((address (plist-get record :address))
                         (result (herdr-core-request "terminal.rm" (list :terminal address))))
                    (unless (equal (plist-get result :removed) address)
                      (signal 'herdr-core-uncertain
                              (list :method "terminal.rm" :reason 'invalid-acknowledgement
                                    :expected address :response result)))
                    (setf (plist-get item :status) 'removed))))
            ((error quit)
             (let ((uncertain (and dispatched (not (eq (car err) 'herdr-core-request-error)))))
               (setf (plist-get item :status) (if uncertain 'uncertain 'failed)
                     (plist-get item :reason) (error-message-string err)
                     (plist-get item :error) err)
               (when (or uncertain (eq (car err) 'quit) (not dispatched)) (setq stop t))))))))))
  (setq agent-fleet-cleanup--state 'complete)
  (agent-fleet-cleanup--render))
(provide 'agent-fleet-cleanup)
;;; agent-fleet-cleanup.el ends here
