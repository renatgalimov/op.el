;;; op-test.el --- unit tests -*- lexical-binding: t; -*-

(require 'buttercup)
(load-file "op.el")

(describe "op-read"
	  (before-each
	   (setq op-read-cache (make-hash-table :test #'equal)))

	  (it "reads a secret via op executable"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(expect (op-read "op://Op.el/Email/password") :to-equal "comanche-muscular-tabloids-minotaur-ally")))

	  (it "caches result"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(op-read "op://Op.el/Email/password")
		(expect (gethash "op://Op.el/Email/password" op-read-cache) :not :to-be nil)))

	  (it "does not cache error output"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(op-read "op://Nonexistent/Item/password")
		(expect (gethash "op://Nonexistent/Item/password" op-read-cache) :to-be nil)))

	  (it "when called twice should use the cached result"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(expect (op-read "op://Op.el/Email/password")
			:to-equal "comanche-muscular-tabloids-minotaur-ally")
		;; Second call with broken executable proves cache is used
		(let ((op-executable "/nonexistent"))
		  (expect (op-read "op://Op.el/Email/password")
			  :to-equal "comanche-muscular-tabloids-minotaur-ally")))))

(describe "op-read-cache-cleanup"
	  (it "when run should remove expired entries"
	      (let ((op-read-cache (make-hash-table :test 'equal)))
		(puthash "old" (cons "val" (- (float-time) (* 11 60))) op-read-cache)
		(puthash "recent" (cons "val" (float-time)) op-read-cache)
		(op-read-cache-cleanup)
		(expect (gethash "old" op-read-cache) :to-be nil)
		(expect (gethash "recent" op-read-cache) :not :to-be nil))))

(describe "op-read-cache-duration"
	  (it "should allow customizing the cache duration"
	      (let ((op-read-cache (make-hash-table :test 'equal))
		    (op-read-cache-duration 1)
		    (op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(expect (op-read "op://Op.el/Email/password")
			:to-equal "comanche-muscular-tabloids-minotaur-ally")
		;; Cache should serve the result even with a broken executable
		(let ((op-executable "/nonexistent"))
		  (expect (op-read "op://Op.el/Email/password")
			  :to-equal "comanche-muscular-tabloids-minotaur-ally"))
		;; After expiry, cache should not serve stale results
		(sleep-for 2)
		(let ((op-executable "/nonexistent"))
		  (expect (op-read "op://Op.el/Email/password")
			  :to-equal "")))))

(describe "op--generate-random-tag"
	  (it "should return a 16-character string"
	      (expect (length (op--generate-random-tag)) :to-equal 16))

	  (it "should contain only lowercase alphanumeric characters"
	      (expect (op--generate-random-tag) :to-match "^[a-z0-9]\\{16\\}$"))

	  (it "should return different values on successive calls"
	      (expect (op--generate-random-tag) :not :to-equal (op--generate-random-tag))))

(describe "op--ensure-pty"
	  (before-each
	   (when (and op--pty-process (process-live-p op--pty-process))
	     (delete-process op--pty-process)
	     (setq op--pty-process nil)))

	  (it "should start a live process"
	      (op--ensure-pty)
	      (expect (process-live-p op--pty-process) :to-be-truthy))

	  (it "should reuse an existing live process"
	      (op--ensure-pty)
	      (let ((first-process op--pty-process))
		(op--ensure-pty)
		(expect op--pty-process :to-equal first-process))))

(describe "op-run"
	  (before-each
	   (when (and op--pty-process (process-live-p op--pty-process))
	     (delete-process op--pty-process)
	     (setq op--pty-process nil)))

	  (it "should return stdout from a successful command"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(let ((result (op-run (list "read" "op://Op.el/Email/password"))))
		  (expect (plist-get result :exit-code) :to-equal 0)
		  (expect (string-trim (plist-get result :stdout))
			  :to-equal "comanche-muscular-tabloids-minotaur-ally"))))

	  (it "should return non-zero exit code on failure"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(let ((result (op-run (list "read" "op://Nonexistent/Item/password"))))
		  (expect (plist-get result :exit-code) :not :to-equal 0)
		  (expect (plist-get result :stderr) :not :to-equal ""))))

	  (it "should pass stdin-data to the command"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(let* ((items-json "[{\"title\":\"Email\"},{\"title\":\"Email Duplicate\"}]")
		       (result (op-run (list "--account" "PXCTHFHEUXV4KPI5J63KDYOBO5"
					     "item" "get" "-"
					     "--format" "json")
				       items-json)))
		  (expect (plist-get result :exit-code) :to-equal 0)
		  (expect (plist-get result :stdout) :not :to-equal ""))))

	  (it "should reuse the same PTY process across calls"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(op-run (list "read" "op://Op.el/Email/password"))
		(let ((first-process op--pty-process))
		  (op-run (list "read" "op://Op.el/Email/password"))
		  (expect op--pty-process :to-equal first-process))))

	  (it "when command hangs should signal a timeout error"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name)))
		    (op-command-timeout-seconds 2))
		(expect (op-run (list "--test-freeze")) :to-throw 'error)))

	  (it "when command hangs should keep the PTY usable for subsequent calls"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name)))
		    (op-command-timeout-seconds 2))
		(ignore-errors (op-run (list "--test-freeze")))
		(let ((result (op-run (list "read" "op://Op.el/Email/password"))))
		  (expect (plist-get result :exit-code) :to-equal 0)
		  (expect (string-trim (plist-get result :stdout))
			  :to-equal "comanche-muscular-tabloids-minotaur-ally"))))

	  (it "when command ignores signals should kill PTY and recover"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name)))
		    (op-command-timeout-seconds 2))
		(expect (op-run (list "--test-freeze" "--test-ignore-sigint"))
			:to-throw 'error)
		;; PTY should have been killed; next call starts a fresh one
		(let ((result (op-run (list "read" "op://Op.el/Email/password"))))
		  (expect (plist-get result :exit-code) :to-equal 0)
		  (expect (string-trim (plist-get result :stdout))
			  :to-equal "comanche-muscular-tabloids-minotaur-ally"))))

	  (it "on error should cleanup stdin file"
	      (let* ((op-executable (expand-file-name "../bin/op.py"
						      (file-name-directory load-file-name)))
		     (leaked-stdin-file nil)
		     (call-count 0)
		     (real-process-live-p (symbol-function 'process-live-p)))
		(op--ensure-pty)
		(cl-letf (((symbol-function 'process-live-p)
			   (lambda (proc)
			     (cl-incf call-count)
			     ;; Let op--ensure-pty pass (call 1), error on while loop (call 2+)
			     (if (= call-count 1)
				 (funcall real-process-live-p proc)
			       (setq leaked-stdin-file
				     (car (directory-files temporary-file-directory t "op-stdin")))
			       (error "simulated process-live-p failure")))))
		  (ignore-errors
		    (op-run (list "read" "op://Op.el/Email/password") "test-stdin-data")))
		(expect leaked-stdin-file :not :to-be nil)
		(expect (file-exists-p leaked-stdin-file) :to-be nil)))

	  (it "on error should cleanup stderr file"
	      (let* ((op-executable (expand-file-name "../bin/op.py"
						      (file-name-directory load-file-name)))
		     (call-count 0)
		     (real-process-live-p (symbol-function 'process-live-p))
		     (stderr-files-before (directory-files temporary-file-directory t "op-stderr")))
		(op--ensure-pty)
		(cl-letf (((symbol-function 'process-live-p)
			   (lambda (proc)
			     (cl-incf call-count)
			     (if (= call-count 1)
				 (funcall real-process-live-p proc)
			       (error "simulated process-live-p failure")))))
		  (ignore-errors
		    (op-run (list "read" "op://Op.el/Email/password"))))
		(let ((stderr-files-after (directory-files temporary-file-directory t "op-stderr")))
		  (expect stderr-files-after :to-equal stderr-files-before)))))

(provide 'op-test)
