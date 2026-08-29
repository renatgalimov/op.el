;;; op-test.el --- unit tests -*- lexical-binding: t; -*-

(require 'buttercup)
(load-file "op.el")

(defun op-test--file-bytes (path)
  "Return the contents of PATH as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (insert-file-contents-literally path))
    (buffer-string)))

(describe "op-read"
	  (it "reads a secret via op executable"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(expect (op-read "op://Op.el/Email/password") :to-equal "comanche-muscular-tabloids-minotaur-ally")))

	  (it "returns empty string on error"
	      (let ((op-executable (expand-file-name "../bin/op.py"
						     (file-name-directory load-file-name))))
		(expect (op-read "op://Nonexistent/Item/password") :to-equal ""))))

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

(describe "op-run with a working directory and a stdout file"
	  ;; These specs bind `op-executable' to ordinary system commands rather
	  ;; than bin/op.py: what is under test is the shell command op-run
	  ;; builds, not any op behaviour.
	  (before-each
	   (when (and op--pty-process (process-live-p op--pty-process))
	     (delete-process op--pty-process)
	     (setq op--pty-process nil)))

	  (it "should run the command in the requested directory"
	      (let* ((op-executable "/bin/pwd")
		     (directory (file-truename (make-temp-file "op-cwd-" t)))
		     (result (op-run nil nil directory)))
		(unwind-protect
		    (progn
		      (expect (plist-get result :exit-code) :to-equal 0)
		      (expect (string-trim (plist-get result :stdout)) :to-equal directory))
		  (delete-directory directory t))))

	  (it "should report a non-zero exit code when the directory is missing"
	      (let* ((op-executable "/bin/pwd")
		     (result (op-run nil nil "/nonexistent-op-el-directory")))
		(expect (plist-get result :exit-code) :not :to-equal 0)))

	  (it "should write stdout to a caller-supplied file instead of returning it"
	      (let* ((op-executable "/bin/echo")
		     (stdout-file (make-temp-file "op-stdout-test-")))
		(unwind-protect
		    (let ((result (op-run (list "hello") nil nil stdout-file)))
		      (expect (plist-get result :exit-code) :to-equal 0)
		      (expect (plist-get result :stdout) :to-equal "")
		      (expect (with-temp-buffer
				(insert-file-contents stdout-file)
				(buffer-string))
			      :to-equal "hello\n"))
		  (delete-file stdout-file))))

	  (it "should preserve bytes that Emacs cannot decode as text"
	      ;; Reading arbitrary bytes back through the PTY corrupts them, which
	      ;; is why the shim has op write stdout straight to a file.
	      (let* ((op-executable "/bin/cat")
		     (source (make-temp-file "op-binary-source-"))
		     (stdout-file (make-temp-file "op-binary-out-")))
		(unwind-protect
		    (progn
		      (let ((coding-system-for-write 'binary))
			(with-temp-file source
			  (set-buffer-multibyte nil)
			  (dotimes (byte 256) (insert byte))))
		      (op-run (list source) nil nil stdout-file)
		      (expect (op-test--file-bytes stdout-file)
			      :to-equal (op-test--file-bytes source)))
		  (delete-file source)
		  (delete-file stdout-file)))))

(describe "op--start-pty"
	  (before-each
	   (when (and op--pty-process (process-live-p op--pty-process))
	     (delete-process op--pty-process)
	     (setq op--pty-process nil)))

	  (it "should mark the shell so the shim never forwards back into Emacs"
	      ;; The PTY shell is itself a descendant of Emacs, so the ancestry
	      ;; check cannot stop a loop; this flag is what stops it.
	      (let ((op-executable "/usr/bin/printenv"))
		(expect (string-trim (plist-get (op-run (list "OP_SHIM_DISABLE")) :stdout))
			:to-equal "1"))))

(provide 'op-test)
