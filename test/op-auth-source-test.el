;;; op-auth-source-test.el --- auth-source tests -*- lexical-binding: t; -*-

(require 'buttercup)
(require 'auth-source)
(load-file "op-auth-source.el")
(load (expand-file-name "op-test-support.el" (file-name-directory load-file-name)))

;; Live tests are opt-in.  Set OP_AUTH_TEST_ACCOUNT to the account UUID,
;; OP_AUTH_TEST_VAULT to a writable disposable vault ID, OP_AUTH_TEST_ITEM to
;; a disposable Login item ID in that vault, and OP_AUTH_TEST_TAG to its unique
;; tag.  Set OP_AUTH_TEST_HOST, OP_AUTH_TEST_USER, OP_AUTH_TEST_PORT and
;; OP_AUTH_TEST_SECRET to the item's host, username, port and password fields.
;; OP_AUTH_TEST_DUPLICATE_ITEM optionally identifies a second matching item.
;; Use synthetic values only.  Configure op authentication and the proxy/CA
;; before starting Emacs; op.el keeps a persistent subprocess.  The account
;; must be visible in `op account list'; every account listed must be signed
;; in because search traverses all of them.  The suite creates and deletes one
;; additional item; interrupted runs may require manual cleanup in the vault.
;; Without the complete environment, integration specs are explicitly pending.

(defun op-auth-test--require-live ()
  "Skip unless the disposable live fixture is completely configured."
  (dolist (name '("OP_AUTH_TEST_ACCOUNT" "OP_AUTH_TEST_VAULT"
                  "OP_AUTH_TEST_ITEM" "OP_AUTH_TEST_TAG" "OP_AUTH_TEST_HOST"
                  "OP_AUTH_TEST_USER" "OP_AUTH_TEST_PORT" "OP_AUTH_TEST_SECRET"))
    (unless (and (getenv name) (not (string-empty-p (getenv name))))
      (buttercup-skip "Live fixture requires %s" name)))
  (unless (and (op-test--loopback-proxy-p) (op-test--mitmproxy-p)
               (equal op-executable "op") (executable-find "op"))
    (buttercup-skip "Live tests require real op and a loopback mitmproxy")))

(defconst op-test-frozen-time (encode-time 0 0 0 1 1 2026)
  "Fixed time for all tests: 2026-01-01 00:00:00.")

(defconst op-test-any 'op-test-any
  "Wildcard that matches any value in `:to-smart-match' patterns.")

(defun op-test--smart-equal (actual expected)
  "Return t if ACTUAL matches EXPECTED, treating `op-test-any' as wildcard."
  (cond
   ((eq expected 'op-test-any) t)
   ((and (consp actual) (consp expected))
    (and (op-test--smart-equal (car actual) (car expected))
         (op-test--smart-equal (cdr actual) (cdr expected))))
   (t (equal actual expected))))

(buttercup-define-matcher :to-smart-match (actual expected)
                          (let ((a (funcall actual))
                                (e (funcall expected)))
                            (if (op-test--smart-equal a e)
                                t
                              (cons nil (format "Expected %S to match pattern %S" a e)))))

(defvar op-test--real-format-time-string (symbol-function 'format-time-string))

(describe
 "op-auth-source"
 (before-each
  (spy-on 'format-time-string :and-call-fake
	  (lambda (format-string &optional time zone)
	    (funcall op-test--real-format-time-string format-string op-test-frozen-time zone)))
  (setq op-auth-source-test--orig-sources auth-sources)
  (setq op-auth-source-test--orig-tag op-auth-source-tag)
  (setq op-auth-source-tag "OpElTest")
  (when (get-buffer "*op-error*")
    (kill-buffer "*op-error*")))

 (after-each
  (setq op-auth-source-tag op-auth-source-test--orig-tag)
  (setq auth-sources op-auth-source-test--orig-sources))

 (describe "--labels-for-key"
	   (it "when given :host should return host aliases"
	       (expect (op-auth-source--get-labels-for-key :host)
		       :to-equal '("host" "server" "hostname")))

	   (it "when given :user should return user aliases"
	       (expect (op-auth-source--get-labels-for-key :user)
		       :to-equal '("user" "username" "email")))

	   (it "when given :port should return port aliases"
	       (expect (op-auth-source--get-labels-for-key :port)
		       :to-equal '("port" "port number")))

	   (it "when given an unknown key should return the key name without colon"
	       (expect (op-auth-source--get-labels-for-key :credential)
		       :to-equal '("credential"))))

 (describe "--field-match-p"
	   (it "when field label matches and value matches should return non-nil"
	       (let ((item '((fields . [((label . "username") (value . "alice@example.com"))]))))
		 (expect (op-auth-source--field-match-p item :user "alice@example.com")
			 :to-be-truthy)))

	   (it "when field label matches case-insensitively should return non-nil"
	       (let ((item '((fields . [((label . "Username") (value . "alice@example.com"))]))))
		 (expect (op-auth-source--field-match-p item :user "alice@example.com")
			 :to-be-truthy)))

	   (it "when field label matches but value differs should return nil"
	       (let ((item '((fields . [((label . "username") (value . "bob@example.com"))]))))
		 (expect (op-auth-source--field-match-p item :user "alice@example.com")
			 :to-be nil)))

	   (it "when no field label matches should return nil"
	       (let ((item '((fields . [((label . "credential") (value . "alice@example.com"))]))))
		 (expect (op-auth-source--field-match-p item :user "alice@example.com")
			 :to-be nil)))

	   (it "when label alias matches should return non-nil"
	       (let ((item '((fields . [((label . "server") (value . "smtp.example.com"))]))))
		 (expect (op-auth-source--field-match-p item :host "smtp.example.com")
			 :to-be-truthy)))

	   (it "when item has no fields should return nil"
	       (let ((item '((id . "abc123"))))
		 (expect (op-auth-source--field-match-p item :user "alice@example.com")
			 :to-be nil))))

 (describe "--value-to-string"
	   (it "when given a list pattern should resolve to the first element"
	       (expect (op-auth-source--value-to-string (quote ("587" "465")))
		       :to-equal "587"))

	   (it "when given a symbol should return its name"
	       (expect (op-auth-source--value-to-string (quote imap))
		       :to-equal "imap")))

 (describe "--match-item"
	   (it "when field label matches host should return non-nil"
	       (let ((item '((fields . [((label . "server") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))]))))
		 (expect (op-auth-source--match-item item '(:host "smtp.gmail.com" :user "alice@gmail.com"))
			 :to-be-truthy)))

	   (it "when field label matches port should return non-nil"
	       (let ((item '((fields . [((label . "server") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))
					((label . "port number") (value . "587"))]))))
		 (expect (op-auth-source--match-item item '(:host "smtp.gmail.com" :user "alice@gmail.com" :port "587"))
			 :to-be-truthy)))

	   (it "when field value does not match should return nil"
	       (let ((item '((fields . [((label . "server") (value . "other.com"))
					((label . "username") (value . "alice@gmail.com"))]))))
		 (expect (op-auth-source--match-item item '(:host "smtp.gmail.com" :user "alice@gmail.com"))
			 :to-be nil)))

	   (it "when user is nil should match any item with matching host"
	       (let ((item '((fields . [((label . "server") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))]))))
		 (expect (op-auth-source--match-item item '(:host "smtp.gmail.com"))
			 :to-be-truthy)))

	   (it "when host is nil should match any item with matching user"
	       (let ((item '((fields . [((label . "server") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))]))))
		 (expect (op-auth-source--match-item item '(:user "alice@gmail.com"))
			 :to-be-truthy)))

	   (it "when spec has unknown key should match against field with that label"
	       (let ((item '((fields . [((label . "credential") (value . "DEADBEEF"))]))))
		 (expect (op-auth-source--match-item item '(:credential "DEADBEEF"))
			 :to-be-truthy)))

	   (it "when spec has keys not present on item should return nil"
	       (let ((item '((fields . [((label . "server") (value . "smtp.gmail.com"))]))))
		 (expect (op-auth-source--match-item item '(:host "smtp.gmail.com" :user "alice@gmail.com"))
			 :to-be nil)))

	   (it "when value is a list should match if any element matches"
	       (let ((item '((fields . [((label . "server") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))]))))
		 (expect (op-auth-source--match-item item '(:host ("smtp.gmail.com" "imap.gmail.com")))
			 :to-be-truthy)))

	   (it "when value is a list and none match should return nil"
	       (let ((item '((fields . [((label . "server") (value . "other.com"))]))))
		 (expect (op-auth-source--match-item item '(:host ("smtp.gmail.com" "imap.gmail.com")))
			 :to-be nil)))

	   (it "when value is t should match any item"
	       (let ((item '((fields . [((label . "server") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))]))))
		 (expect (op-auth-source--match-item item '(:host t))
			 :to-be-truthy)))

	   (it "when value is a symbol should match its string value"
	       (let ((item '((fields . [((label . "port number") (value . "irc-nickserv"))]))))
		 (expect (op-auth-source--match-item item '(:port irc-nickserv))
			 :to-be-truthy)))

	   (it "when value is a list with symbols should match their string values"
	       (let ((item '((fields . [((label . "port number") (value . "irc-nickserv"))]))))
		 (expect (op-auth-source--match-item item '(:port (irc irc-nickserv)))
			 :to-be-truthy)))

	   (it "when all criteria are nil or ignored should return nil"
	       (let ((item '((fields . [((label . "host") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))
					((label . "port number") (value . "587"))
					((label . "password") (value . "secret123"))]))))
		 (expect (op-auth-source--match-item item '(:host nil :user nil))
			 :to-be nil)))

	   (it "when criteria is empty should return nil"
	       (let ((item '((fields . [((label . "host") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))
					((label . "port number") (value . "587"))
					((label . "password") (value . "secret123"))]))))
		 (expect (op-auth-source--match-item item '())
			 :to-be nil)))

	   (it "when criteria has only ignored keys should return nil"
	       (let ((item '((fields . [((label . "host") (value . "smtp.gmail.com"))
					((label . "username") (value . "alice@gmail.com"))
					((label . "port number") (value . "587"))
					((label . "password") (value . "secret123"))]))))
		 (expect (op-auth-source--match-item item '(:backend 1password :type 1password :max 1))
			 :to-be nil))))

 (describe "--parse-json-objects"
	   (it "when given a JSON array should return a list of alists"
	       (expect (op--parse-json-objects "[{\"id\":\"a\"},{\"id\":\"b\"}]")
		       :to-equal '(((id . "a")) ((id . "b")))))

	   (it "when given concatenated JSON objects should return a list of alists"
	       (expect (op--parse-json-objects "{\"id\":\"a\"}\n{\"id\":\"b\"}")
		       :to-equal '(((id . "a")) ((id . "b")))))

	   (it "when given a single JSON object should return a one-element list"
	       (expect (op--parse-json-objects "{\"id\":\"a\"}")
		       :to-equal '(((id . "a")))))

	   (it "when given invalid JSON should signal an error"
	       (expect (op--parse-json-objects "not json at all")
		       :to-throw 'json-error)))

 (describe "--find-secret-label"
	   (it "when item has a password field should return password"
	       (expect (op-auth-source--find-secret-label
			'((fields . [((label . "username") (value . "me"))
				     ((label . "password") (value . "secret"))])))
		       :to-equal "password"))

	   (it "when item has a credential field should return credential"
	       (expect (op-auth-source--find-secret-label
			'((fields . [((label . "credential") (value . "token123"))])))
		       :to-equal "credential"))

	   (it "when item has both should prefer password"
	       (expect (op-auth-source--find-secret-label
			'((fields . [((label . "credential") (value . "token"))
				     ((label . "password") (value . "pass"))])))
		       :to-equal "password"))

	   (it "when item has neither should return nil"
	       (expect (op-auth-source--find-secret-label
			'((fields . [((label . "username") (value . "me"))])))
		       :to-equal nil)))

 (describe "--build-template"
	   (it "when given full spec should emit a deterministic login json string"
	       (expect (op-auth-source--build-template
			"emacs-auth-source"
			"smtp.example.com"
			"alice@example.com"
			"587"
			"p@ss")
		       :to-equal
		       "{\"title\":\"smtp.example.com\",\"category\":\"LOGIN\",\"tags\":[\"emacs-auth-source\"],\"fields\":[{\"id\":\"username\",\"type\":\"STRING\",\"purpose\":\"USERNAME\",\"label\":\"username\",\"value\":\"alice@example.com\"},{\"id\":\"password\",\"type\":\"CONCEALED\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"p@ss\"},{\"id\":\"host\",\"type\":\"STRING\",\"label\":\"host\",\"value\":\"smtp.example.com\"},{\"id\":\"port\",\"type\":\"STRING\",\"label\":\"port\",\"value\":\"587\"}]}"))

	   (it "when port is empty should omit the port field"
	       (expect (op-auth-source--build-template
			"emacs-auth-source"
			"imap.example.com"
			"bob@example.com"
			""
			"topsecret")
		       :to-equal
		       "{\"title\":\"imap.example.com\",\"category\":\"LOGIN\",\"tags\":[\"emacs-auth-source\"],\"fields\":[{\"id\":\"username\",\"type\":\"STRING\",\"purpose\":\"USERNAME\",\"label\":\"username\",\"value\":\"bob@example.com\"},{\"id\":\"password\",\"type\":\"CONCEALED\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"topsecret\"},{\"id\":\"host\",\"type\":\"STRING\",\"label\":\"host\",\"value\":\"imap.example.com\"}]}"))

	   (it "when port is nil should omit the port field"
	       (expect (op-auth-source--build-template
			"emacs-auth-source"
			"imap.example.com"
			"bob@example.com"
			nil
			"topsecret")
		       :to-equal
		       "{\"title\":\"imap.example.com\",\"category\":\"LOGIN\",\"tags\":[\"emacs-auth-source\"],\"fields\":[{\"id\":\"username\",\"type\":\"STRING\",\"purpose\":\"USERNAME\",\"label\":\"username\",\"value\":\"bob@example.com\"},{\"id\":\"password\",\"type\":\"CONCEALED\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"topsecret\"},{\"id\":\"host\",\"type\":\"STRING\",\"label\":\"host\",\"value\":\"imap.example.com\"}]}"))

	   (it "when given extra fields should append them as string fields after the base fields"
	       (expect (op-auth-source--build-template
			"emacs-auth-source"
			"smtp.example.com"
			"alice@example.com"
			"587"
			"p@ss"
			'(:description "primary mail"))
		       :to-equal
		       "{\"title\":\"smtp.example.com\",\"category\":\"LOGIN\",\"tags\":[\"emacs-auth-source\"],\"fields\":[{\"id\":\"username\",\"type\":\"STRING\",\"purpose\":\"USERNAME\",\"label\":\"username\",\"value\":\"alice@example.com\"},{\"id\":\"password\",\"type\":\"CONCEALED\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"p@ss\"},{\"id\":\"host\",\"type\":\"STRING\",\"label\":\"host\",\"value\":\"smtp.example.com\"},{\"id\":\"port\",\"type\":\"STRING\",\"label\":\"port\",\"value\":\"587\"},{\"id\":\"description\",\"type\":\"STRING\",\"label\":\"description\",\"value\":\"primary mail\"}]}")))

 (describe "--extra-fields"
	   (it "when fields include keys beyond the base set should return only the extras"
	       (expect (op-auth-source--extra-fields '(:host "h" :user "u" :port "587" :secret "s" :description "primary mail"))
		       :to-equal '(:description "primary mail")))

	   (it "when fields contain only base keys should return nil"
	       (expect (op-auth-source--extra-fields '(:host "h" :user "u" :port "587" :secret "s"))
		       :to-be nil)))

 (describe "live disposable fixture"
	   (before-each
	    (setq op-auth-source-tag (getenv "OP_AUTH_TEST_TAG"))
	    ;; Do not reuse a shell started before proxy configuration.
	    (when (and op--pty-process (process-live-p op--pty-process))
	      (delete-process op--pty-process))
	    (setq op--pty-process nil))

	   (it "lists the configured account and tagged fixture"
	       (op-auth-test--require-live)
	       (let ((account (getenv "OP_AUTH_TEST_ACCOUNT"))
		     (item (getenv "OP_AUTH_TEST_ITEM")))
		 (expect (assoc account (mapcar (lambda (a) (cons (alist-get 'account_uuid a) a))
						(op--list-accounts))) :to-be-truthy)
		 (expect (seq-find (lambda (x) (equal (alist-get 'id x) item))
				   (append (json-read-from-string
					    (op--list-items account op-auth-source-tag)) nil)) :to-be-truthy)))

	   (it "retrieves the actual fixture secret"
	       (op-auth-test--require-live)
	       (expect (op-auth-source--get-secret (getenv "OP_AUTH_TEST_ITEM")
						   (getenv "OP_AUTH_TEST_ACCOUNT") "password")
		       :to-equal (getenv "OP_AUTH_TEST_SECRET")))

	   (it "reports CLI item-list and secret errors in the error buffer"
	       (op-auth-test--require-live)
	       (expect (op--list-items "op-el-nonexistent-account" op-auth-source-tag) :to-throw 'error)
	       (expect (get-buffer "*op-error*") :to-be-truthy)
	       (expect (with-current-buffer "*op-error*" (buffer-string)) :to-match "Exit code:")
	       (expect (op-auth-source--get-secret "op-el-nonexistent-item"
						   (getenv "OP_AUTH_TEST_ACCOUNT") "password")
		       :to-throw 'error))

	   (it "searches, resolves list criteria, limits and lazily retrieves credentials"
	       (op-auth-test--require-live)
	       (let* ((host (getenv "OP_AUTH_TEST_HOST"))
		      (user (getenv "OP_AUTH_TEST_USER"))
		      (port (getenv "OP_AUTH_TEST_PORT"))
		      (result (op-auth-source-search :host (list "no-such-host.invalid" host)
						     :user (list "no-such-user" user)
						     :port (list "no-such-port" port) :max 1))
		      (entry (car result)))
		 (expect (length result) :to-equal 1)
		 (expect (plist-get entry :host) :to-equal host)
		 (expect (plist-get entry :user) :to-equal user)
		 (expect (plist-get entry :port) :to-equal port)
		 (expect (plist-get entry :account) :to-equal (getenv "OP_AUTH_TEST_ACCOUNT"))
		 (expect (funcall (plist-get entry :secret)) :to-equal (getenv "OP_AUTH_TEST_SECRET"))
		 (expect (op-auth-source-search :host host :max 0) :to-equal t)
		 (expect (op-auth-source-search :host "no-such-host.invalid" :max 0) :to-be nil)))

	   (it "uses the registered auth-source backend"
	       (op-auth-test--require-live)
	       (let ((auth-sources nil))
		 (unwind-protect
		     (progn
		       (op-auth-source-enable)
		       (let* ((result (auth-source-search :host (getenv "OP_AUTH_TEST_HOST")
							  :user (getenv "OP_AUTH_TEST_USER") :max 1))
			      (entry (car result)))
			 (expect (length result) :to-equal 1)
			 (expect (plist-get entry :account) :to-equal (getenv "OP_AUTH_TEST_ACCOUNT"))
			 (expect (funcall (plist-get entry :secret)) :to-equal (getenv "OP_AUTH_TEST_SECRET"))))
		   (op-auth-source-disable))))

	   (it "returns no match for unmatched scalar and list criteria"
	       (op-auth-test--require-live)
	       (let ((host (getenv "OP_AUTH_TEST_HOST")) (user (getenv "OP_AUTH_TEST_USER")))
		 (expect (op-auth-source-search :host "no-such-host.invalid" :user user) :to-be nil)
		 (expect (op-auth-source-search :host '("no-such-host.invalid" "other.invalid") :user user) :to-be nil)
		 (expect (op-auth-source-search :host host :user user :port '("no-such-port" "other-port")) :to-be nil)))

	   (it "matches list criteria and rejects nonmatches through auth-source"
	       (op-auth-test--require-live)
	       (let ((auth-sources nil) (auth-source-do-cache nil)
		     (host (getenv "OP_AUTH_TEST_HOST")) (user (getenv "OP_AUTH_TEST_USER"))
		     (port (getenv "OP_AUTH_TEST_PORT")))
		 (unwind-protect
		     (progn
		       (op-auth-source-enable)
		       (expect (length (auth-source-search :host (list "no-such-host.invalid" host) :user user :max 1)) :to-equal 1)
		       (expect (length (auth-source-search :host host :user (list "no-such-user" user) :max 1)) :to-equal 1)
		       (expect (length (auth-source-search :host host :user user :port (list "no-such-port" port) :max 1)) :to-equal 1)
		       (expect (auth-source-search :host '("no-such-host.invalid" "other.invalid") :user user) :to-be nil)
		       (expect (auth-source-search :host host :user user :port '("no-such-port" "other-port")) :to-be nil))
		   (op-auth-source-disable))))

	   (it "returns duplicate matches and honors multi-result limits"
	       (op-auth-test--require-live)
	       (let ((duplicate (getenv "OP_AUTH_TEST_DUPLICATE_ITEM"))
		     (host (getenv "OP_AUTH_TEST_HOST")) (user (getenv "OP_AUTH_TEST_USER"))
		     (port (getenv "OP_AUTH_TEST_PORT")))
		 (unless (and duplicate (not (string-empty-p duplicate)))
		   (buttercup-skip "Set OP_AUTH_TEST_DUPLICATE_ITEM for duplicate coverage"))
		 (expect duplicate :not :to-equal (getenv "OP_AUTH_TEST_ITEM"))
		 (expect (seq-find (lambda (x) (equal (alist-get 'id x) duplicate))
				   (append (json-read-from-string
					    (op--list-items (getenv "OP_AUTH_TEST_ACCOUNT") op-auth-source-tag)) nil)) :to-be-truthy)
		 (expect (> (length (op-auth-source-search :host host :user user :port port :max 10)) 1) :to-be-truthy)
		 (expect (length (op-auth-source-search :host host :user user :port port :max 1)) :to-equal 1)))

	   (it "honors zero and nonmatching limits through auth-source"
	       (op-auth-test--require-live)
	       (let ((auth-sources nil) (auth-source-do-cache nil))
		 (unwind-protect
		     (progn
		       (op-auth-source-enable)
		       (expect (auth-source-search :host (getenv "OP_AUTH_TEST_HOST") :max 0) :to-equal t)
		       (expect (auth-source-search :host "no-such-host.invalid" :max 0) :to-be nil)
		       (expect (auth-source-search :host "no-such-host.invalid") :to-be nil))
		   (op-auth-source-disable))))

	   (it "creates through auth-source, reads back, and deletes the disposable item"
	       (op-auth-test--require-live)
	       (let* ((auth-sources nil)
		      (account (getenv "OP_AUTH_TEST_ACCOUNT"))
		      (vault (getenv "OP_AUTH_TEST_VAULT"))
		      (host (format "op-el-%s-%s.invalid" (emacs-pid) (op--generate-random-tag)))
		      (created nil))
		 (unwind-protect
		     (progn
		       (op-auth-source-enable)
		       ;; Stub UI only: account and vault selection still run real CLI calls.
		       (cl-letf (((symbol-function 'completing-read)
				  (lambda (prompt &rest _)
				    (if (string-match-p "account" prompt)
					(or (alist-get 'email (seq-find
							       (lambda (a) (equal (alist-get 'account_uuid a) account))
							       (op--list-accounts))) account)
				      (alist-get 'name (seq-find
							(lambda (v) (equal (alist-get 'id v) vault))
							(op-auth-source--list-vaults account))))))
				 ((symbol-function 'read-string)
				  (lambda (prompt &rest _)
				    (if (string-match-p "username" prompt) "op-test-user" "443")))
				 ((symbol-function 'read-passwd) (lambda (&rest _) "op-test-secret")))
			 (let ((entry (car (auth-source-search :host host :create t))))
			   (expect entry :to-be-truthy)
			   (setq created (alist-get 'id (funcall (plist-get entry :save-function))))
			   (expect created :to-be-truthy)
			   (expect (op-auth-source--get-secret created account "password")
				   :to-equal "op-test-secret")
			   (let ((found (car (op-auth-source-search :host host :user "op-test-user"))))
			     (expect found :to-be-truthy)
			     (expect (funcall (plist-get found :secret)) :to-equal "op-test-secret")))))
		   (when created
		     (let* ((args (list "--account" account "item" "delete" created "--vault" vault))
			    (result (op-run args)))
		       (op--check-exit (plist-get result :exit-code) (plist-get result :stderr)
				       "disposable item cleanup")
		       (expect (plist-get (op-run (list "--account" account "item" "get" created
							"--vault" vault "--format" "json"))
					  :exit-code) :not :to-equal 0)))
		   (op-auth-source-disable))))

	   (it "redacts stdin when real op rejects creation in an invalid vault"
	       (op-auth-test--require-live)
	       (let ((secret "op-el-redaction-canary"))
		 (expect (op-auth-source--save-item (getenv "OP_AUTH_TEST_ACCOUNT")
						    "op-el-nonexistent-vault"
						    (list :host "failure.invalid" :user "test"
							  :port "443" :secret secret))
			 :to-throw 'error)
		 (expect (get-buffer "*op-error*") :to-be-truthy)
		 (with-current-buffer "*op-error*"
		   (expect (buffer-string) :not :to-match secret)
		   (expect (buffer-string) :to-match "<redacted>")))) )

 (describe "--prompt-for-field"
	   (it "when given an unknown field should signal an error"
	       (expect (op-auth-source--prompt-for-field 'unknown nil)
		       :to-throw 'error)))

 (describe "create"
	   (before-each
	    (spy-on 'op-auth-source--resolve-account
		    :and-return-value "unit-account")
	    (spy-on 'op-auth-source--resolve-vault
		    :and-return-value "unit-vault"))

	   (it "when spec provides every required field should return a result without prompting"
	       (cl-letf (((symbol-function 'read-string)
			  (lambda (&rest _) (error "read-string must not be called")))
			 ((symbol-function 'read-passwd)
			  (lambda (&rest _) (error "read-passwd must not be called"))))
		 (expect (op-auth-source-create
			  :host "smtp.example.com"
			  :user "alice@example.com"
			  :port "587"
			  :secret "p@ss"
			  :create t
			  :backend op-auth-source-backend)
			 :to-smart-match
			 '((:host "smtp.example.com"
				  :user "alice@example.com"
				  :port "587"
				  :account "unit-account"
				  :secret op-test-any
				  :save-function op-test-any)))))

	   (it "when fields are missing should prompt and use the entered values"
	       (let ((string-prompts '("smtp.test.com" "alice" "587"))
		     (passwd-prompts '("topsecret")))
		 (cl-letf (((symbol-function 'read-string)
			    (lambda (&rest _) (pop string-prompts)))
			   ((symbol-function 'read-passwd)
			    (lambda (&rest _) (pop passwd-prompts))))
		   (let ((entry (car (op-auth-source-create
				      :create t
				      :backend op-auth-source-backend))))
		     (expect entry
			     :to-smart-match
			     '(:host "smtp.test.com"
				     :user "alice"
				     :port "587"
				     :account "unit-account"
				     :secret op-test-any
				     :save-function op-test-any))
		     (expect (funcall (plist-get entry :secret))
			     :to-equal "topsecret")))))
	   )

 (describe "backend-parse"
	   (it "when given 1password symbol should return a backend"
	       (let ((backend (op-auth-source-backend-parse '1password)))
		 (expect backend :not :to-be nil)))

	   (it "when given 1password symbol should return a backend with create-function wired"
	       (let ((backend (op-auth-source-backend-parse '1password)))
		 (expect (slot-value backend 'create-function)
			 :to-equal #'op-auth-source-create)))

	   (it "when given an unrelated entry should return nil"
	       (expect (op-auth-source-backend-parse "~/.authinfo") :to-be nil)
	       (expect (op-auth-source-backend-parse 'default) :to-be nil)))

 (describe "enable"
	   (after-each
	    (op-auth-source-disable))

	   (it "when called should add 1password to auth-sources"
	       (let ((auth-sources '("~/.authinfo")))
		 (cl-letf (((symbol-function 'auth-source-forget-all-cached) #'ignore))
		   (op-auth-source-enable)
		   (expect (memq '1password auth-sources) :to-be-truthy))))

	   (it "when called should register the backend parser"
	       (let ((auth-sources '("~/.authinfo")))
		 (cl-letf (((symbol-function 'auth-source-forget-all-cached) #'ignore))
		   (op-auth-source-enable)
		   (if (boundp 'auth-source-backend-parser-functions)
		       (expect (memq #'op-auth-source-backend-parse
				     auth-source-backend-parser-functions)
			       :to-be-truthy)
		     (expect (advice-member-p #'op-auth-source-backend-parse
					      'auth-source-backend-parse)
			     :to-be-truthy))))))

 (describe "disable"
	   (before-each
	    (cl-letf (((symbol-function 'auth-source-forget-all-cached) #'ignore))
	      (op-auth-source-enable)))

	   (it "when called should remove 1password from auth-sources"
	       (let ((auth-sources '(1password "~/.authinfo")))
		 (cl-letf (((symbol-function 'auth-source-forget-all-cached) #'ignore))
		   (op-auth-source-disable)
		   (expect (memq '1password auth-sources) :to-be nil))))

	   (it "when called should unregister the backend parser"
	       (let ((auth-sources '(1password)))
		 (cl-letf (((symbol-function 'auth-source-forget-all-cached) #'ignore))
		   (op-auth-source-disable)
		   (if (boundp 'auth-source-backend-parser-functions)
		       (expect (memq #'op-auth-source-backend-parse
				     auth-source-backend-parser-functions)
			       :to-be nil)
		     (expect (advice-member-p #'op-auth-source-backend-parse
					      'auth-source-backend-parse)
			     :to-be nil)))))) ;; end disable
 ) ;; end op-auth-source

(provide 'op-auth-source-test)
;;; op-auth-source-test.el ends here
