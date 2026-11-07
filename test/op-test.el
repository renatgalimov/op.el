;;; op-test.el --- op tests -*- lexical-binding: t; -*-

(require 'buttercup)
(load-file "op.el")
(load (expand-file-name "op-test-support.el" (file-name-directory load-file-name)))

(defun op-test--fixture ()
  "Return the disposable fixture reference, or skip integration tests."
  (let ((vault (getenv "OP_TEST_VAULT_ID"))
        (item (getenv "OP_TEST_ITEM_ID")))
    (unless (and vault (not (string-empty-p vault))
                 item (not (string-empty-p item))
                 (op-test--loopback-proxy-p)
                 (op-test--mitmproxy-p)
                 (executable-find "op"))
      (buttercup-skip "Set disposable fixture IDs and a loopback mitmproxy for real op tests"))
    (format "op://%s/%s/password" vault item)))

(defun op-test--stop-pty ()
  "Discard the persistent test shell."
  (when (and op--pty-process (process-live-p op--pty-process))
    (delete-process op--pty-process))
  (setq op--pty-process nil))

(defun op-test--hang-script (ignore-int)
  "Create a deterministic executable which hangs, optionally ignoring INT."
  (let ((file (make-temp-file "op-test-hang-")))
    (with-temp-file file
      (insert "#!/bin/sh\n" (if ignore-int "trap '' INT\n" "")
              "while :; do sleep 1; done\n"))
    (set-file-modes file #o700)
    file))

(describe "integration proxy prerequisites"
	  (it "rejects nonlocal, conflicting, and bypassed proxies"
	      (let ((process-environment (copy-sequence process-environment)))
		(setenv "NO_PROXY" nil) (setenv "no_proxy" nil)
		(setenv "https_proxy" nil) (setenv "HTTPS_PROXY" "http://proxy.example:8080")
		(expect (op-test--loopback-proxy-p) :to-be nil)
		(setenv "HTTPS_PROXY" "http://127.0.0.1:8080")
		(expect (op-test--loopback-proxy-p) :to-be-truthy)
		(setenv "https_proxy" "http://proxy.example:8080")
		(expect (op-test--loopback-proxy-p) :to-be nil)
		(setenv "https_proxy" nil) (setenv "NO_PROXY" "*")
		(expect (op-test--loopback-proxy-p) :to-be nil)))
	  (it "rejects a loopback address without a mitmproxy listener"
	      (let ((process-environment (copy-sequence process-environment)))
		(setenv "HTTPS_PROXY" "http://127.0.0.1:0")
		(setenv "https_proxy" nil) (setenv "NO_PROXY" nil) (setenv "no_proxy" nil)
		(expect (op-test--mitmproxy-p) :to-be nil))))

(describe "op-read"
	  (after-each (op-test--stop-pty))
	  (it "reads a disposable secret via the real op executable"
	      (let ((reference (op-test--fixture)) (op-executable "op"))
		(expect (op-read reference) :to-equal "fixture-only-not-a-secret")))
	  (it "returns empty string on error"
	      (let ((reference (concat (op-test--fixture) "-missing-field")) (op-executable "op"))
		(expect (op-read reference) :to-equal ""))))

(describe "op--generate-random-tag"
	  (it "returns a 16-character string"
	      (expect (length (op--generate-random-tag)) :to-equal 16))
	  (it "contains only lowercase alphanumeric characters"
	      (expect (op--generate-random-tag) :to-match "^[a-z0-9]\\{16\\}$"))
	  (it "returns different values on successive calls"
	      (expect (op--generate-random-tag) :not :to-equal (op--generate-random-tag))))

(describe "op--ensure-pty"
	  (before-each (op-test--stop-pty))
	  (after-each (op-test--stop-pty))
	  (it "starts a live process"
	      (op--ensure-pty)
	      (expect (process-live-p op--pty-process) :to-be-truthy))
	  (it "reuses an existing live process"
	      (op--ensure-pty)
	      (let ((first-process op--pty-process))
		(op--ensure-pty)
		(expect op--pty-process :to-equal first-process))))

(describe "op-run"
	  (before-each (op-test--stop-pty))
	  (after-each (op-test--stop-pty))
	  (it "returns stdout from a real read"
	      (let* ((reference (op-test--fixture)) (op-executable "op")
		     (result (op-run (list "read" reference))))
		(expect (plist-get result :exit-code) :to-equal 0)
		(expect (string-trim (plist-get result :stdout)) :to-equal "fixture-only-not-a-secret")))
	  (it "passes --no-color before command arguments"
	      (let ((op-executable "echo"))
		(expect (op-run (list "read" "example"))
			:to-equal (list :exit-code 0 :stdout "--no-color read example\n" :stderr ""))))
	  (it "returns a nonzero exit and stderr on a real read error"
	      (let* ((reference (concat (op-test--fixture) "-missing-field")) (op-executable "op")
		     (result (op-run (list "read" reference))))
		(expect (plist-get result :exit-code) :not :to-equal 0)
		(expect (plist-get result :stderr) :not :to-equal "")))
	  (it "passes item JSON via stdin to the real CLI"
	      (op-test--fixture)
	      (let* ((op-executable "op")
		     (item (getenv "OP_TEST_ITEM_ID"))
		     (vault (getenv "OP_TEST_VAULT_ID"))
		     (input (json-encode (vector (list (cons 'id item)))))
		     (result (op-run (list "item" "get" "-" "--vault" vault "--format" "json") input)))
		(expect (plist-get result :exit-code) :to-equal 0)
		(let ((items (op--parse-json-objects (plist-get result :stdout))))
		  (expect (length items) :to-equal 1)
		  (expect (alist-get 'id (car items)) :to-equal item))))
	  (it "reuses the same PTY process across real calls"
	      (let ((reference (op-test--fixture)) (op-executable "op"))
		(expect (plist-get (op-run (list "read" reference)) :exit-code) :to-equal 0)
		(let ((first-process op--pty-process))
		  (expect (plist-get (op-run (list "read" reference)) :exit-code) :to-equal 0)
		  (expect op--pty-process :to-equal first-process))))
	  (it "signals timeout and leaves the PTY usable"
	      (let ((script (op-test--hang-script nil)) (op-command-timeout-seconds 1))
		(unwind-protect
		    (progn
		      (let ((op-executable script))
			(expect (op-run nil) :to-throw 'error))
		      (let ((op-executable "echo"))
			(expect (plist-get (op-run (list "recovered")) :exit-code) :to-equal 0)))
		  (delete-file script))))
	  (it "runs a real read after a timed-out command"
	      (let ((reference (op-test--fixture))
		    (script (op-test--hang-script nil))
		    (op-command-timeout-seconds 1))
		(unwind-protect
		    (progn
		      (let ((op-executable script))
			(expect (op-run nil) :to-throw 'error))
		      (let ((op-executable "op") (op-command-timeout-seconds 30))
			(expect (op-read reference) :to-equal "fixture-only-not-a-secret")))
		  (delete-file script))))
	  (it "kills the PTY when the command ignores SIGINT and recovers"
	      (let ((script (op-test--hang-script t)) (op-command-timeout-seconds 1))
		(unwind-protect
		    (progn
		      (let ((op-executable script))
			(expect (op-run nil) :to-throw 'error))
		      (expect op--pty-process :to-be nil)
		      (let ((op-executable "echo"))
			(expect (plist-get (op-run (list "recovered")) :exit-code) :to-equal 0)))
		  (delete-file script))))
	  (it "cleans up stdin and stderr files on timeout"
	      (let ((script (op-test--hang-script nil))
		    (temporary-file-directory (make-temp-file "op-test-temp-" t))
		    (op-command-timeout-seconds 1)
		    (observed-files nil)
		    timer)
		(unwind-protect
		    (let ((op-executable script))
		      (setq timer (run-at-time 0.2 nil
					       (lambda ()
						 (setq observed-files
						       (directory-files temporary-file-directory nil
									"^op-\\(stdin\\|stderr\\)-")))))
		      (expect (op-run nil "test-stdin-data") :to-throw 'error)
		      (expect (length observed-files) :to-equal 2)
		      (expect (directory-files temporary-file-directory nil "^op-\\(stdin\\|stderr\\)-")
			      :to-equal nil))
		  (when timer (cancel-timer timer))
		  (delete-file script)
		  (delete-directory temporary-file-directory t)))))

(provide 'op-test)
