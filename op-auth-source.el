;;; op-auth-source.el --- auth-source backend for 1Password -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026 Renat Galimov

;; Author: Renat Galimov
;; Maintainer: Renat Galimov
;; Version: 0.3
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/renatgalimov/op.el
;; Keywords: password, op, 1password, auth-source

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

(defun op-auth-source--make-result (item resolved)
  "Build an auth-source result plist from ITEM and RESOLVED match.
ITEM is the full 1Password item alist.  RESOLVED is the plist
returned by `op-auth-source--match-item' with matched :host, :user, :port."
  (let ((id (alist-get 'id item))
        (account-uuid (alist-get 'account_uuid item))
        (secret-label (or (op-auth-source--find-secret-label item)
                          "password")))
    (list :host (or (plist-get resolved :host) "")
          :user (or (plist-get resolved :user) "")
          :port (or (plist-get resolved :port) "")
          :account account-uuid
          :secret (lambda () (op-auth-source--get-secret id account-uuid secret-label)))))

(cl-defun op-auth-source-search (&rest criteria
                                       &key backend create
                                       (max 1)
                                       &allow-other-keys)
  "Search 1Password for credentials matching CRITERIA.
CRITERIA is a plist of auth-source search parameters.  Each criterion-patterns
pair is matched against item fields by label.
BACKEND and TYPE have their standard auth-source meanings.
MAX limits the number of results (default 1).  When MAX is 0,
returns t if any match exists, nil otherwise.
When CREATE is non-nil and no items match, dispatches to BACKEND's
`create-function' so the user can persist a new credential.
Returns a list of plists with :host, :user, :port, and :secret."
  (op--log "search called with criteria: %S" criteria)
  (or (cl-loop for item in (op--fetch-items op-auth-source-tag)
               for resolved = (op-auth-source--match-item item criteria)
               when resolved
               collect (op-auth-source--make-result item resolved)
               into results
               finally return
               (cond
                ((null results) nil)
                ((zerop max) t)
                ((> (length results) max) (seq-take results max))
                (t results)))
      (and create backend
           (apply (slot-value backend 'create-function) criteria))))

(cl-defun op-auth-source-create (&rest spec
                                       &key backend create
                                       &allow-other-keys)
  "Create a 1Password item to satisfy auth-source's `:create' request.
Prompts for any missing required fields and returns a one-element list
with a result plist whose `:save-function' runs `op item create'."
  (ignore backend)
  (let* ((account (op-auth-source--resolve-account))
         (vault (op-auth-source--resolve-vault account))
         (fields (op-auth-source--prompt-fields spec create)))
    (list (list :host (plist-get fields :host)
                :user (plist-get fields :user)
                :port (plist-get fields :port)
                :account account
                :secret (lambda () (plist-get fields :secret))
                :save-function (lambda ()
                                 (op-auth-source--save-item account vault fields))))))

(defconst op-auth-source--redacted-secret "<redacted>"
  "Placeholder substituted for the password in `*op-error*' diagnostics.")

(defun op-auth-source--save-item (account vault fields)
  "Persist a new 1Password Login item.
FIELDS is the plist returned by `op-auth-source--prompt-fields'.
Builds a JSON template tagged with `op-auth-source-tag' and pipes it
to `op --account ACCOUNT item create --vault VAULT'.  Returns the
parsed item alist on success.  Signals an error and pops up
`*op-error*' on failure."
  (let* ((template (op-auth-source--build-template
                    op-auth-source-tag
                    (plist-get fields :host)
                    (plist-get fields :user)
                    (plist-get fields :port)
                    (plist-get fields :secret)))
         (result (op-run (list "--account" account
                               "item" "create"
                               "--vault" vault
                               "--format" "json"
                               "-")
                         template)))
    (op--check-exit (plist-get result :exit-code)
                    (plist-get result :stderr)
                    (format "op --account %s item create --vault %s --format json -"
                            account vault)
                    ;; Pass a redacted template so a failed create never writes
                    ;; the cleartext password into the `*op-error*' buffer.
                    (op-auth-source--build-template
                     op-auth-source-tag
                     (plist-get fields :host)
                     (plist-get fields :user)
                     (plist-get fields :port)
                     op-auth-source--redacted-secret))
    (json-read-from-string (plist-get result :stdout))))

(defun op-auth-source--resolve-account ()
  "Pick a 1Password account UUID, prompting only if there are multiple."
  (let ((accounts (op--list-accounts)))
    (cond
     ((null accounts) (error "No 1Password accounts available"))
     ((null (cdr accounts)) (alist-get 'account_uuid (car accounts)))
     (t (op-auth-source--prompt-account accounts)))))

(defun op-auth-source--prompt-account (accounts)
  "Prompt the user to choose from ACCOUNTS, returning the chosen UUID."
  (let ((choices (mapcar (lambda (account)
                           (cons (or (alist-get 'email account)
                                     (alist-get 'account_uuid account))
                                 (alist-get 'account_uuid account)))
                         accounts)))
    (cdr (assoc (completing-read "1Password account: " choices nil t) choices))))

(defun op-auth-source--resolve-vault (account)
  "Prompt the user to choose a vault from ACCOUNT, returning the vault name."
  (let ((names (mapcar (lambda (vault) (alist-get 'name vault))
                       (op-auth-source--list-vaults account))))
    (when (null names)
      (error "No 1Password vaults available for account %s" account))
    (completing-read "1Password vault: " names nil t)))

(defun op-auth-source--list-vaults (account)
  "List 1Password vaults visible to ACCOUNT.
Returns a list of alists with vault details.
Signals an error and pops up `*op-error*' on failure."
  (let ((result (op-run (list "--account" account
                              "vault" "list"
                              "--format" "json"))))
    (op--check-exit (plist-get result :exit-code)
                    (plist-get result :stderr)
                    (format "op --account %s vault list --format json" account))
    (append (json-read-from-string (plist-get result :stdout)) nil)))

(defun op-auth-source--prompt-fields (spec create)
  "Resolve required fields, prompting for any missing values.
SPEC is the auth-source create spec.  CREATE may be t or a list of
extra field symbols to require beyond `(host user port secret)'.
Returns a plist with `:host', `:user', `:port', `:secret', plus any extras."
  (let ((resolved nil))
    (dolist (field (append '(host user port secret)
                           (and (consp create) create)))
      (setq resolved
            (plist-put resolved
                       (intern (concat ":" (symbol-name field)))
                       (op-auth-source--resolve-field field spec resolved))))
    resolved))

(defun op-auth-source--resolve-field (field spec resolved)
  "Resolve one FIELD from SPEC, falling back to a prompt.
RESOLVED is the partial plist of fields collected so far, used to
provide context to the prompt."
  (let ((provided (plist-get spec (intern (concat ":" (symbol-name field))))))
    (if (and provided (not (eq provided t)))
        (op-auth-source--value-to-string provided)
      (op-auth-source--prompt-for-field field resolved))))

(defun op-auth-source--prompt-for-field (field resolved)
  "Prompt the user for FIELD, given the partially RESOLVED plist.
Uses `read-passwd' for `secret' and `read-string' for everything else.
Signals an error if FIELD is not one of the recognized fields."
  (cl-case field
    (secret (read-passwd (format "1Password password for %s@%s: "
                                 (or (plist-get resolved :user) "")
                                 (or (plist-get resolved :host) ""))))
    (user   (read-string (format "1Password username for %s: "
                                 (or (plist-get resolved :host) ""))
                         nil nil (user-login-name)))
    (host   (read-string "1Password host: "))
    (port   (read-string (format "1Password port for %s@%s (empty for none): "
                                 (or (plist-get resolved :user) "")
                                 (or (plist-get resolved :host) ""))))
    (t      (error "op-auth-source: cannot prompt for unknown field `%s'" field))))

(defvar op-auth-source-backend
  (auth-source-backend
   :source "1password"
   :type '1password
   :search-function #'op-auth-source-search
   :create-function #'op-auth-source-create)
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

(defun op-auth-source--get-labels-for-key (key)
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
        (labels (op-auth-source--get-labels-for-key label))
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
Strings pass through; symbols are converted via `symbol-name'; a list
resolves to its first element (auth-source \"any of these\" patterns)."
  (cond
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   ((consp value) (op-auth-source--value-to-string (car value)))
   (t (format "%s" value))))

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

(defun op-auth-source--build-template (tag host user port secret)
  "Build a 1Password Login item JSON template string.
TAG, HOST, USER and SECRET are required strings.  PORT is included
as a custom field only when it is a non-empty string."
  (let* ((base-fields
          (list `((id . "username") (type . "STRING") (purpose . "USERNAME")
                  (label . "username") (value . ,user))
                `((id . "password") (type . "CONCEALED") (purpose . "PASSWORD")
                  (label . "password") (value . ,secret))
                `((id . "host") (type . "STRING")
                  (label . "host") (value . ,host))))
         (port-field (and port (not (string-empty-p port))
                          (list `((id . "port") (type . "STRING")
                                  (label . "port") (value . ,port)))))
         (fields (vconcat base-fields port-field)))
    (json-encode
     `((title . ,host)
       (category . "LOGIN")
       (tags . ,(vector tag))
       (fields . ,fields)))))

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
    (op--check-exit exit-code stderr
                    (format "op --account %s item get %s --fields %s --reveal"
                            account item-id field-arg))
    output))

(provide 'op-auth-source)
;;; op-auth-source.el ends here
