;;; op-auth-source-test.el --- tests for op-auth-source -*- lexical-binding: t; -*-

(require 'buttercup)
(require 'auth-source)
(load-file "op-auth-source.el")

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
  (setq op-auth-source-test--orig-executable op-executable)
  (setq op-executable (expand-file-name "../bin/op.py"
					(file-name-directory load-file-name)))
  (when (get-buffer "*op-error*")
    (kill-buffer "*op-error*")))

 (after-each
  (setq op-executable op-auth-source-test--orig-executable)
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

 (describe "--list-accounts"
	   (it "when called via op.py should return a list of account alists"
	       (expect (op--list-accounts)
		       :to-equal
		       '(((account_uuid . "WRYZIV66ZGZOUUQR3SKXFQ753Q")
			  (email . "akparb9@igassa15.co")
			  (url . "sa.niwehonow.co")
			  (user_uuid . "HKP5DUHCUNSXGH4UC6QUUNFNQT"))
			 ((account_uuid . "PXCTHFHEUXV4KPI5J63KDYOBO5")
			  (email . "butele1@ownuth3d.gov")
			  (url . "sa.niwehonow.co")
			  (user_uuid . "F6RKTCOKKHEU3H6JM4XQBEJPJT"))))))

 (describe "--list-items"
	   (it "when op fails should signal an error and pop up *op-error* buffer"
	       (let ((op-auth-source-tag "OpElFail"))
		 (expect (op--list-items "PXCTHFHEUXV4KPI5J63KDYOBO5" op-auth-source-tag)
			 :to-throw 'error '("op --account PXCTHFHEUXV4KPI5J63KDYOBO5 item list --tags OpElFail --format json failed (exit 1)"))
		 (expect (get-buffer "*op-error*") :not :to-be nil)
		 (expect (with-current-buffer "*op-error*" (buffer-string))
			 :to-equal "[2026-01-01 00:00:00] op --account PXCTHFHEUXV4KPI5J63KDYOBO5 item list --tags OpElFail --format json\nExit code: 1\nStderr:\n[ERROR] 2026/03/13 14:47:38 found no accounts for filter \"VK6XJVTGTFE3TG6WEQZLYIDWEA\"\n"))))

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
		       "{\"title\":\"imap.example.com\",\"category\":\"LOGIN\",\"tags\":[\"emacs-auth-source\"],\"fields\":[{\"id\":\"username\",\"type\":\"STRING\",\"purpose\":\"USERNAME\",\"label\":\"username\",\"value\":\"bob@example.com\"},{\"id\":\"password\",\"type\":\"CONCEALED\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"topsecret\"},{\"id\":\"host\",\"type\":\"STRING\",\"label\":\"host\",\"value\":\"imap.example.com\"}]}")))

 (describe "--get-secret"
	   (it "when called via op.py should return the password"
	       (expect (op-auth-source--get-secret "sre4q66mawycb5dzmm7ka7kblm" "PXCTHFHEUXV4KPI5J63KDYOBO5" "password")
		       :to-equal "comanche-muscular-tabloids-minotaur-ally"))

	   ;; "abc123" has no fixture in test/fixtures/, so op.py exits with code 1.
	   (it "when op fails should signal an error"
	       (expect (op-auth-source--get-secret "abc123" "PXCTHFHEUXV4KPI5J63KDYOBO5" "password")
		       :to-throw 'error '("op --account PXCTHFHEUXV4KPI5J63KDYOBO5 item get abc123 --fields label=password --reveal failed (exit 1)"))))

 (describe "search"
	   (it "when matching items exist should return a list of plists with account"
	       (expect (op-auth-source-search :host "imap.example.com"
					      :user "test@example.com"
					      :port "993"
					      :max 2)
		       :to-smart-match
		       '((:host "imap.example.com" :user "test@example.com" :port "993" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any)
			 (:host "imap.example.com" :user "test@example.com" :port "993" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any))))

	   (it "when secret is called should fetch password via op item get"
	       (let* ((result (op-auth-source-search :host "imap.example.com"
						     :user "test@example.com"))
		      (entry (car result)))
		 (expect (funcall (plist-get entry :secret))
			 :to-equal "comanche-muscular-tabloids-minotaur-ally")))

	   (it "when no items match should return nil"
	       (expect (op-auth-source-search :host "nonexistent.example.com"
					      :user "nobody@example.com")
		       :to-be nil))

	   (it "when multiple items match should return all matches with account"
	       (let ((op-auth-source-tag "OpElDuplicate"))
		 (expect (op-auth-source-search :host "imap.example.com"
						:user "test@example.com"
						:max 10)
			 :to-smart-match
			 '((:host "imap.example.com" :user "test@example.com" :port "" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any)
			   (:host "imap.example.com" :user "test@example.com" :port "" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any))))))

 (describe "auth-source-search integration"
	   (before-each
	    (setq auth-sources nil)
	    (op-auth-source-enable))

	   (after-each
	    (op-auth-source-disable))

	   (it "should return credentials with account via auth-source-search"
	       (let* ((result (auth-source-search :host "imap.example.com"
						  :user "test@example.com"
						  :max 2))
		      (entry (car result)))

		 (expect result
			 :to-smart-match
			 '((:host "imap.example.com" :user "test@example.com" :port "" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any)
			   (:host "imap.example.com" :user "test@example.com" :port "" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any)))

		 (expect (funcall (plist-get entry :secret))
			 :to-equal "comanche-muscular-tabloids-minotaur-ally")))

	   (it "should return nil when no items match"
	       (expect (auth-source-search :host "nonexistent.example.com")
		       :to-be nil))

	   (it "when :max is 1 should return at most one result"
	       (expect (auth-source-search :host "imap.example.com"
					   :user "test@example.com"
					   :max 1)
		       :to-smart-match
		       '((:host "imap.example.com" :user "test@example.com" :port "" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any))))

	   (it "when :max is 0 should return t if matches exist"
	       (expect (auth-source-search :host "imap.example.com"
					   :user "test@example.com"
					   :max 0)
		       :to-equal t))

	   (it "when :max is 0 and no matches should return nil"
	       (expect (auth-source-search :host "nonexistent.example.com"
					   :max 0)
		       :to-be nil))

	   (it "when :host is a list should match any host in the list"
	       (expect (auth-source-search :host '("nonexistent.example.com" "imap.example.com")
					   :user "test@example.com"
					   :max 1)
		       :to-smart-match
		       '((:host "imap.example.com" :user "test@example.com" :port "" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any))))

	   (it "when :host is a list and none match should return nil"
	       (expect (auth-source-search :host '("nonexistent.example.com" "other.example.com")
					   :user "test@example.com")
		       :to-be nil))

	   (it "when :user is a list should match any user in the list"
	       (expect (auth-source-search :host "imap.example.com"
					   :user '("nobody@example.com" "test@example.com")
					   :max 1)
		       :to-smart-match
		       '((:host "imap.example.com" :user "test@example.com" :port "" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any))))

	   (it "when :port is a list should match any port in the list"
	       (expect (auth-source-search :host "imap.example.com"
					   :user "test@example.com"
					   :port '("587" "993")
					   :max 1)
		       :to-smart-match
		       '((:host "imap.example.com" :user "test@example.com" :port "993" :account "PXCTHFHEUXV4KPI5J63KDYOBO5" :secret op-test-any))))

	   (it "when :port is a list and none match should return nil"
	       (expect (auth-source-search :host "imap.example.com"
					   :user "test@example.com"
					   :port '("25" "587"))
		       :to-be nil))

	   (it "when no items match and :create t should dispatch to create-function and persist via op item create"
	       (spy-on 'op-auth-source--resolve-account
		       :and-return-value "PXCTHFHEUXV4KPI5J63KDYOBO5")
	       (spy-on 'op-auth-source--resolve-vault
		       :and-return-value "Op.el")
	       (spy-on 'op-run :and-call-through)
	       (let ((string-prompts '("alice" "587"))
		     (passwd-prompts '("topsecret")))
		 (cl-letf (((symbol-function 'read-string)
			    (lambda (&rest _) (pop string-prompts)))
			   ((symbol-function 'read-passwd)
			    (lambda (&rest _) (pop passwd-prompts))))
		   (let ((entry (car (auth-source-search
				      :host "nonexistent.create.com"
				      :create t))))
		     (expect 'op-auth-source--resolve-account :to-have-been-called)
		     (expect 'op-auth-source--resolve-vault :to-have-been-called)
		     (expect (alist-get 'title (funcall (plist-get entry :save-function)))
			     :to-equal "nonexistent.create.com")
		     (expect 'op-run :to-have-been-called-with
			     '("--account" "PXCTHFHEUXV4KPI5J63KDYOBO5"
			       "item" "create"
			       "--vault" "Op.el"
			       "--format" "json"
			       "-")
			     "{\"title\":\"nonexistent.create.com\",\"category\":\"LOGIN\",\"tags\":[\"OpElTest\"],\"fields\":[{\"id\":\"username\",\"type\":\"STRING\",\"purpose\":\"USERNAME\",\"label\":\"username\",\"value\":\"alice\"},{\"id\":\"password\",\"type\":\"CONCEALED\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"topsecret\"},{\"id\":\"host\",\"type\":\"STRING\",\"label\":\"host\",\"value\":\"nonexistent.create.com\"},{\"id\":\"port\",\"type\":\"STRING\",\"label\":\"port\",\"value\":\"587\"}]}"))))))

 (describe "--prompt-for-field"
	   (it "when given an unknown field should signal an error"
	       (expect (op-auth-source--prompt-for-field 'unknown nil)
		       :to-throw 'error)))

 (describe "create"
	   (before-each
	    (spy-on 'op-auth-source--resolve-account
		    :and-return-value "PXCTHFHEUXV4KPI5J63KDYOBO5")
	    (spy-on 'op-auth-source--resolve-vault
		    :and-return-value "Op.el"))

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
				  :account "PXCTHFHEUXV4KPI5J63KDYOBO5"
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
				     :account "PXCTHFHEUXV4KPI5J63KDYOBO5"
				     :secret op-test-any
				     :save-function op-test-any))
		     (expect (funcall (plist-get entry :secret))
			     :to-equal "topsecret")))))

	   (it "when save-function is called and op fails should signal an error"
	       (let ((entry (car (op-auth-source-create
				  :host "create-fail.example.com"
				  :user "alice@example.com"
				  :port "443"
				  :secret "topsecret"
				  :create t
				  :backend op-auth-source-backend))))
		 (expect (funcall (plist-get entry :save-function))
			 :to-throw 'error
			 '("op --account PXCTHFHEUXV4KPI5J63KDYOBO5 item create --vault Op.el --format json - failed (exit 1)"))))

	   (it "when save-function fails should not write the cleartext password into *op-error*"
	       (let ((entry (car (op-auth-source-create
				  :host "create-fail.example.com"
				  :user "alice@example.com"
				  :port "443"
				  :secret "topsecret"
				  :create t
				  :backend op-auth-source-backend))))
		 (ignore-errors (funcall (plist-get entry :save-function)))
		 (with-current-buffer "*op-error*"
		   (expect (buffer-string) :not :to-match "topsecret")
		   (expect (buffer-string) :to-match "<redacted>")))))

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
