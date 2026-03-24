;;; op-auth-source.el --- auth-source backend for 1Password -*- lexical-binding: t; -*-

;; Author: Renat Galimov
;; Version: 0.3
;; Keywords: password, op, 1password, auth-source

;;; Commentary:

;; This package provides an auth-source backend that retrieves
;; credentials from 1Password using the `op' CLI tool.  It searches
;; items tagged `emacs-auth-source' by URL and username.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'op)

(defcustom op-auth-source-tag "emacs-auth-source"
  "Tag used to filter 1Password items for auth-source."
  :type 'string
  :group 'op)

(define-obsolete-variable-alias 'op-auth-source-debug 'op-debug "0.4")

;;;###autoload
(defun op-auth-source-enable ()
  "Enable the 1Password auth-source backend.
Registers the backend parser, adds `1password' to `auth-sources',
and clears the auth-source cache."
  (interactive)
  (if (boundp 'auth-source-backend-parser-functions)
      (add-hook 'auth-source-backend-parser-functions
                #'op-auth-source-backend-parse)
    (advice-add 'auth-source-backend-parse :before-until
                #'op-auth-source-backend-parse))
  (add-to-list 'auth-sources '1password)
  (auth-source-forget-all-cached))

(defun op-auth-source-disable ()
  "Disable the 1Password auth-source backend.
Unregisters the backend parser, removes `1password' from `auth-sources',
and clears the auth-source cache."
  (interactive)
  (if (boundp 'auth-source-backend-parser-functions)
      (remove-hook 'auth-source-backend-parser-functions
                   #'op-auth-source-backend-parse)
    (advice-remove 'auth-source-backend-parse
                   #'op-auth-source-backend-parse))
  (setq auth-sources (delq '1password auth-sources))
  (auth-source-forget-all-cached))

(cl-defun op-auth-source-search (&rest criteria
                                       &key host user port
                                       (max 1)
                                       &allow-other-keys)
  "Search 1Password for credentials matching CRITERIA.
CRITERIA is a plist of auth-source search parameters.  Each criterion-patterns
pair is matched against item fields by label.
BACKEND and TYPE have their standard auth-source meanings.
MAX limits the number of results (default 1).  When MAX is 0,
returns t if any match exists, nil otherwise.
Returns a list of plists with :host, :user, :port, and :secret."
  (op--log "search called with criteria: %S" criteria)
  (let ((items (op-auth-source--fetch-items)))
    (cl-loop for item in items
             for resolved = (op-auth-source--match-item item criteria)
             when resolved
             collect (let ((id (alist-get 'id item))
                           (account-uuid (alist-get 'account_uuid item))
                           (secret-label (or (op-auth-source--find-secret-label item)
                                             "password")))
                       (list :host (or (plist-get resolved :host) "")
                             :user (or (plist-get resolved :user) "")
                             :port (or (plist-get resolved :port) "")
                             :account account-uuid
                             :secret (lambda () (op-auth-source--get-secret id account-uuid secret-label))))
             into results
             finally return
             (cond
              ((null results) nil)
              ((zerop max) t)
              ((> (length results) max) (seq-take results max))
              (t results)))))

(defvar op-auth-source-backend
  (auth-source-backend
   :source "1password"
   :type '1password
   :search-function #'op-auth-source-search)
  "Auth-source backend for 1Password.")

(defun op-auth-source-backend-parse (entry)
  "Create a 1Password auth-source backend from ENTRY.
Recognizes the symbol `1password' in `auth-sources'."
  (when (eq entry '1password)
    (auth-source-backend-parse-parameters entry op-auth-source-backend)))

(defconst op-auth-source--label-aliases
  '((:host "host" "server" "hostname")
    (:user "user" "username" "email")
    (:port "port" "port number"))
  "Mapping from auth-source keywords to 1Password field label aliases.")

(defun op-auth-source--labels-for-key (key)
  "Return list of field labels to search for auth-source KEY.
Uses `op-auth-source--label-aliases' for well-known keys,
otherwise uses the keyword name itself (without colon)."
  (or (cdr (assq key op-auth-source--label-aliases))
      (list (substring (symbol-name key) 1))))

(defun op-auth-source--field-match-p (item label value)
  "Return non-nil if any field in ITEM with a label in LABELS has VALUE.
VALUE is coerced to a string before comparison.
Comparison is case-insensitive for labels, exact for values."
  (let ((fields (append (alist-get 'fields item) nil))
        (labels (op-auth-source--labels-for-key label))
        (value (op-auth-source--value-to-string value)))
    (seq-some (lambda (field)
                (and (member-ignore-case (alist-get 'label field) labels)
                     (equal (alist-get 'value field) value)))
              fields)))

(defconst op-auth-source--ignored-keys
  '(:backend :type :max :require :create :account)
  "Auth-source spec keys that should not be used for item matching.")

(defun op-auth-source--value-to-string (value)
  "Coerce VALUE to a string for field matching.
Strings pass through; symbols are converted via `symbol-name'."
  (cond
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun op-auth-source--match-criterion (item label criterion)
  "Return the resolved match value if ITEM matches CRITERION for LABEL, or nil.
LABEL is a keyword like :host.  Ignored keys return `skipped'.
A nil CRITERION is treated as absent (returns `skipped').
A t CRITERION means \"match any value\" and returns `wildcard'.
When CRITERION is a list, return the first element that matches.
Logs rejected criteria when debugging is enabled."
  (cond
   ((memq label op-auth-source--ignored-keys) 'skipped)
   ((null criterion) 'skipped)
   ((eq criterion t) 'wildcard)
   (t (let ((candidates (if (listp criterion) criterion (list criterion))))
        (or (seq-some (lambda (candidate)
                        (when (op-auth-source--field-match-p item label candidate)
                          candidate))
                      candidates)
            (progn
              (op--log "item %s rejected: %s=%S not found in fields"
                       (or (alist-get 'title item) (alist-get 'id item) "?")
                       label criterion)
              nil))))))

(defun op-auth-source--match-item (item criteria)
  "Return a plist of resolved matches if ITEM matches all CRITERIA, or nil.
CRITERIA is a plist of auth-source search parameters.  Every
criterion-pattern pair must match for the item to be considered a
match.  Each pair is matched against the item's fields by label.
Well-known criteria (:host, :user, :port) are matched against
multiple label aliases.  Nil patterns and t are treated as wildcards.
When a pattern is a list, the resolved value is the specific element
that matched.  Symbol values are coerced to strings.
Returns a plist like (:host \"matched.com\" :user \"me@x.com\" ...)
with only the non-ignored criteria resolved."
  (cl-loop with resolved = (list :matched t)
           with has-real-match = nil
           for (label criterion) on criteria by #'cddr
           for match = (op-auth-source--match-criterion item label criterion)
           unless match return nil
           when (eq match 'wildcard)
           do (setq has-real-match t)
           unless (memq match '(skipped wildcard))
           do (setq resolved (plist-put resolved label match)
                    has-real-match t)
           finally return (and has-real-match resolved)))


(defun op-auth-source--list-accounts ()
  "List all 1Password accounts.
Returns a list of alists with account details.
Signals an error and pops up stderr if the command fails."
  (let* ((result (op-run (list "account" "list" "--format" "json")))
         (exit-code (plist-get result :exit-code))
         (output (plist-get result :stdout))
         (stderr (plist-get result :stderr)))
    (op-auth-source--check-exit exit-code stderr "op account list --format json")
    (append (json-read-from-string output) nil)))

(defun op-auth-source--list-items (account)
  "List 1Password item summaries tagged with `op-auth-source-tag' for ACCOUNT.
ACCOUNT is an account UUID string.
Returns a JSON string.
Signals an error and pops up stderr if the command fails."
  (let* ((result (op-run (list "--account" account
                               "item" "list"
                               "--tags" op-auth-source-tag
                               "--format" "json")))
         (exit-code (plist-get result :exit-code))
         (output (plist-get result :stdout))
         (stderr (plist-get result :stderr)))
    (op-auth-source--check-exit exit-code stderr
                                (format "op --account %s item list --tags %s --format json"
                                        account op-auth-source-tag))
    output))

(defun op-auth-source--get-items (items-json account)
  "Get full details for items by passing ITEMS-JSON via a pipe.
ACCOUNT is the account UUID to use.
Returns a list of alists with full item details.
Signals an error and pops up stderr if the command fails."
  (let* ((result (op-run (list "--account" account
                               "item" "get" "-"
                               "--format" "json")
                         items-json))
         (exit-code (plist-get result :exit-code))
         (output (plist-get result :stdout))
         (stderr (plist-get result :stderr))
         (command (format "op --account %s item get - --format json" account)))
    (op-auth-source--check-exit exit-code stderr command items-json)
    (op-auth-source--parse-json-objects output)))

(defun op-auth-source--parse-json-objects (string)
  "Parse STRING containing one or more concatenated JSON objects.
Returns a list of alists.  Handles both a JSON array and
concatenated top-level objects as output by `op item get'."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let (items)
      (skip-chars-forward " \t\n\r")
      (while (not (eobp))
        (let ((obj (json-read)))
          (if (vectorp obj)
              (dolist (el (append obj nil))
                (push el items))
            (push obj items)))
        (skip-chars-forward " \t\n\r"))
      (nreverse items))))

(defun op-auth-source--fetch-items ()
  "Fetch full 1Password items tagged with `op-auth-source-tag'.
Iterates over all accounts, fetching items from each.
Each returned item alist has an extra `account_uuid' key."
  (let ((accounts (op-auth-source--list-accounts))
        (all-items nil))
    (op--log "found %d accounts" (length accounts))
    (dolist (account accounts)
      (let* ((account-uuid (alist-get 'account_uuid account))
             (items-json (op-auth-source--list-items account-uuid))
             (items-list (json-read-from-string items-json)))
        (op--log "account %s: %d items from list" account-uuid
                 (if (vectorp items-list) (length items-list) 0))
        (when (and (vectorp items-list) (> (length items-list) 0))
          (let ((detailed (op-auth-source--get-items items-json account-uuid)))
            (op--log "account %s: %d detailed items" account-uuid (length detailed))
            (dolist (item detailed)
              (push (cons (cons 'account_uuid account-uuid) item) all-items))))))
    (nreverse all-items)))

(defconst op-auth-source--secret-labels '("password" "credential")
  "Field labels to try when fetching the secret from a 1Password item.
Tried in order; the first label that exists on the item wins.")

(defun op-auth-source--find-secret-label (item)
  "Return the first matching secret field label found in ITEM's fields.
Checks labels from `op-auth-source--secret-labels' in order.
Returns the label string, or nil if none match."
  (let ((field-labels (mapcar (lambda (field) (alist-get 'label field))
                              (alist-get 'fields item))))
    (seq-some (lambda (secret-label)
                (and (member-ignore-case secret-label field-labels)
                     secret-label))
              op-auth-source--secret-labels)))

(defun op-auth-source--get-secret (item-id account secret-label)
  "Fetch the SECRET-LABEL field for 1Password item ITEM-ID in ACCOUNT.
SECRET-LABEL is the field label to retrieve (e.g. \"password\" or \"credential\").
Returns the trimmed secret string.
Signals an error and pops up stderr if the command fails."
  (let* ((field-arg (format "label=%s" secret-label))
         (result (op-run (list "--account" account
                               "item" "get" item-id
                               "--fields" field-arg
                               "--reveal")))
         (exit-code (plist-get result :exit-code))
         (output (string-trim (plist-get result :stdout)))
         (stderr (plist-get result :stderr)))
    (op-auth-source--check-exit exit-code stderr
                                (format "op --account %s item get %s --fields %s --reveal"
                                        account item-id field-arg))
    output))

(defun op-auth-source--check-exit (exit-code stderr command &optional stdin-data)
  "Check EXIT-CODE of COMMAND; if non-zero, pop up STDERR and signal error.
STDERR is a string containing the standard error output.
COMMAND is a string describing the full command invocation for the error message.
STDIN-DATA, if non-nil, is included in the error buffer for diagnostics."
  (unless (zerop exit-code)
    (with-current-buffer (get-buffer-create "*op-error*")
      (goto-char (point-max))
      (unless (bobp) (insert "\n\n"))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ") command "\n")
      (insert (format "Exit code: %d\n" exit-code))
      (when stdin-data
        (insert "Stdin:\n" stdin-data "\n"))
      (insert "Stderr:\n" stderr "\n")
      (display-buffer (current-buffer)))
    (error "%s failed (exit %d)" command exit-code)))

(provide 'op-auth-source)
;;; op-auth-source.el ends here
