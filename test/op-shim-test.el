;;; op-shim-test.el --- unit tests -*- lexical-binding: t; -*-

(require 'buttercup)
(load-file "op-shim.el")

;;; The fixtures were captured from a live unix socket on macOS 15.7.7 with
;;; lsof 4.91, then sanitized: unrelated socket paths were replaced but every
;;; pid, file descriptor and device address is real.
;;;
;;; test/fixtures/lsof-unix-sockets.txt describes:
;;;   pid 99637 fd 4 device 0x96a5f5db93475e68  the listening socket
;;;   pid 99637 fd 5 device 0xdeff708da00ef69d  the accepted connection
;;;   pid 99640 fd 3 named ->0xdeff708da00ef69d the process that connected
;;;
;;; test/fixtures/ps-process-tree.txt describes:
;;;   99640 -> 99639 -> 99637 -> 99635 -> 88574 -> 3354 -> 1   the caller
;;;   860 -> 649 -> 1                                          an outsider

(defconst op-shim-test--socket-path "/var/folders/zz/opshim-fixture/op.sock")
(defconst op-shim-test--server-pid 99637)
(defconst op-shim-test--connected-pid 99640)
(defconst op-shim-test--listener-device "0x96a5f5db93475e68")
(defconst op-shim-test--outsider-pid 860)

;; Captured while this file loads: `load-file-name' is nil by the time a spec
;; body actually runs.
(defconst op-shim-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun op-shim-test--fixture (name)
  "Return the contents of the fixture file NAME."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "fixtures/" name) op-shim-test--directory))
    (buffer-string)))

(defun op-shim-test--file-bytes (path)
  "Return the contents of PATH as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (insert-file-contents-literally path))
    (buffer-string)))

(describe "op-shim--peer-pids"
	  (it "should return the connecting pid for a socket the server owns"
	      (expect (op-shim--peer-pids (op-shim-test--fixture "lsof-unix-sockets.txt")
					  op-shim-test--socket-path
					  op-shim-test--server-pid)
		      :to-equal (list op-shim-test--connected-pid)))

	  (it "should return nil when no process is connected to the socket"
	      (expect (op-shim--peer-pids (op-shim-test--fixture "lsof-unix-sockets.txt")
					  "/var/folders/zz/opshim-fixture/absent.sock"
					  op-shim-test--server-pid)
		      :to-equal nil))

	  (it "should return nil when the socket belongs to a different process"
	      (expect (op-shim--peer-pids (op-shim-test--fixture "lsof-unix-sockets.txt")
					  op-shim-test--socket-path
					  12345)
		      :to-equal nil))

	  (it "should not report the server itself as its own peer"
	      (expect (op-shim--peer-pids (op-shim-test--fixture "lsof-unix-sockets.txt")
					  op-shim-test--socket-path
					  op-shim-test--server-pid)
		      :not :to-contain op-shim-test--server-pid))

	  (it "should return nil for a listening socket nobody has connected to"
	      ;; Only the accepted connection is referenced by a "->device" record,
	      ;; so a listener that never accepted anything resolves to no peer.
	      (expect (op-shim--peer-pids
		       (concat "p" (number-to-string op-shim-test--server-pid) "\n"
			       "f4\n"
			       "d" op-shim-test--listener-device "\n"
			       "n" op-shim-test--socket-path "\n")
		       op-shim-test--socket-path
		       op-shim-test--server-pid)
		      :to-equal nil)))

(describe "op-shim--descendant-of-p"
	  (it "should return non-nil for a process below the ancestor"
	      (expect (op-shim--descendant-of-p (op-shim-test--fixture "ps-process-tree.txt")
						op-shim-test--connected-pid
						op-shim-test--server-pid)
		      :to-be-truthy))

	  (it "should return nil for a process whose ancestry reaches init instead"
	      (expect (op-shim--descendant-of-p (op-shim-test--fixture "ps-process-tree.txt")
						op-shim-test--outsider-pid
						op-shim-test--server-pid)
		      :to-equal nil))

	  (it "should return nil for the ancestor itself"
	      (expect (op-shim--descendant-of-p (op-shim-test--fixture "ps-process-tree.txt")
						op-shim-test--server-pid
						op-shim-test--server-pid)
		      :to-equal nil))

	  (it "should return nil for a process absent from the tree"
	      (expect (op-shim--descendant-of-p (op-shim-test--fixture "ps-process-tree.txt")
						4242
						op-shim-test--server-pid)
		      :to-equal nil))

	  (it "should terminate on a cycle rather than looping forever"
	      ;; A cycle cannot occur in a real process tree; this guards the walk
	      ;; against hanging Emacs if ps output is ever malformed.
	      (expect (op-shim--descendant-of-p "10 20\n20 10\n" 10 op-shim-test--server-pid)
		      :to-equal nil)))

;;; End-to-end: the shim runs as a child of this Emacs, so it is a real
;;; descendant and passes the genuine ancestry check.  Nothing here is faked.

(defvar op-shim-test--runtime nil)
(defvar op-shim-test--saved-executable nil)
(defvar op-shim-test--saved-runtime-directory nil)

(defun op-shim-test--run (arguments &optional environment)
  "Run the shim with ARGUMENTS and return (EXIT-CODE STDOUT STDERR).
ENVIRONMENT entries are prepended to `process-environment'.  The shim is
run asynchronously because it waits for a reply that only this Emacs can
send: blocking here would deadlock the request it just made."
  (let* ((stdout-buffer (generate-new-buffer " *op-shim-stdout*"))
	 (stderr-buffer (generate-new-buffer " *op-shim-stderr*"))
	 (process-environment (append environment process-environment))
	 ;; `ignore' sentinels keep "Process ... finished" out of the captures.
	 (stderr-process (make-pipe-process :name "op-shim-client-stderr"
					    :buffer stderr-buffer
					    :coding 'binary
					    :noquery t
					    :sentinel #'ignore))
	 (shim (make-process
		:name "op-shim-client"
		:buffer stdout-buffer
		:stderr stderr-process
		:coding 'binary
		:noquery t
		:sentinel #'ignore
		:command (cons (expand-file-name "bin/op-shim.py") arguments))))
    (process-send-eof shim)
    (with-timeout (20 (delete-process shim))
      (while (process-live-p shim)
	(accept-process-output shim 0.05)))
    (while (accept-process-output nil 0.05))
    (unwind-protect
	(list (process-exit-status shim)
	      (with-current-buffer stdout-buffer (buffer-string))
	      (with-current-buffer stderr-buffer (buffer-string)))
      (kill-buffer stdout-buffer)
      (kill-buffer stderr-buffer))))

(describe "op-shim-mode"
	  (before-each
	   (setq op-shim-test--saved-executable op-executable
		 op-shim-test--saved-runtime-directory op-shim-runtime-directory
		 op-shim-test--runtime (make-temp-file "op-shim-runtime-" t))
	   (setq op-shim-runtime-directory op-shim-test--runtime
		 op-executable (expand-file-name "bin/op.py"))
	   (when (and op--pty-process (process-live-p op--pty-process))
	     (delete-process op--pty-process)
	     (setq op--pty-process nil))
	   (op-shim-mode 1))

	  (after-each
	   (op-shim-mode -1)
	   (delete-directory op-shim-test--runtime t)
	   (setq op-executable op-shim-test--saved-executable
		 op-shim-runtime-directory op-shim-test--saved-runtime-directory))

	  (it "should create an owner-only socket"
	      (expect (file-modes (op-shim--socket-path)) :to-equal #o600))

	  (it "should put an executable named op on PATH"
	      (expect (file-name-directory (executable-find "op"))
		      :to-equal (file-name-as-directory op-shim-test--runtime)))

	  (it "should return the secret and a zero exit code"
	      (expect (op-shim-test--run (list "read" "op://Op.el/Email/password"))
		      :to-equal (list 0 "comanche-muscular-tabloids-minotaur-ally\n" "")))

	  (it "should pass through the exit code and stderr of a failing command"
	      (let ((result (op-shim-test--run
			     (list "--account" "PXCTHFHEUXV4KPI5J63KDYOBO5"
				   "item" "list" "--tags" "OpElFail" "--format" "json"))))
		(expect (nth 0 result) :to-equal 1)
		(expect (nth 1 result) :to-equal "")
		(expect (nth 2 result) :not :to-equal "")))

	  (it "should preserve bytes that Emacs cannot decode as text"
	      ;; Compared by digest: the bytes contain `%', which buttercup would
	      ;; feed to `format' while rendering a failure message.
	      (let* ((source (make-temp-file "op-shim-binary-"))
		     (op-executable "/bin/cat"))
		(unwind-protect
		    (progn
		      (let ((coding-system-for-write 'binary))
			(with-temp-file source
			  (set-buffer-multibyte nil)
			  (dotimes (byte 256) (insert byte))))
		      (expect (md5 (nth 1 (op-shim-test--run (list source))))
			      :to-equal (md5 (op-shim-test--file-bytes source))))
		  (delete-file source))))

	  (it "should exec the real op instead of forwarding when disabled"
	      (expect (op-shim-test--run (list "read" "op://Op.el/Email/password")
					 (list "OP_SHIM_DISABLE=1"
					       "OP_SHIM_REAL_OP=/bin/echo"))
		      :to-equal (list 0 "read op://Op.el/Email/password\n" "")))

	  (it "should exec the real op for commands needing the caller's terminal"
	      (expect (nth 1 (op-shim-test--run (list "run" "--" "true")
						(list "OP_SHIM_REAL_OP=/bin/echo")))
		      :to-equal "run -- true\n"))

	  (it "should keep concurrent requests from corrupting each other"
	      ;; A request arriving while op-run waits on the PTY must be queued,
	      ;; not run: re-entering op-run would clobber op--pty-output.
	      (let ((results (list (op-shim-test--run (list "read" "op://Op.el/Email/password"))
				   (op-shim-test--run (list "read" "op://Op.el/Email/password")))))
		(expect results
			:to-equal
			(list (list 0 "comanche-muscular-tabloids-minotaur-ally\n" "")
			      (list 0 "comanche-muscular-tabloids-minotaur-ally\n" "")))))

	  (it "should restore PATH after being enabled more than once"
	      (let ((path-while-enabled (getenv "PATH")))
		(op-shim-mode 1)
		(expect (getenv "PATH") :to-equal path-while-enabled)
		(op-shim-mode -1)
		(expect (getenv "PATH") :not :to-match
			(regexp-quote op-shim-test--runtime))))

	  (it "should be found as op by a shell running under Emacs"
	      ;; The path a vterm user actually takes: bash resolves `op' from
	      ;; PATH and finds the installed shim.
	      (let* ((stdout-buffer (generate-new-buffer " *op-shim-shell*"))
		     (shell (make-process
			     :name "op-shim-shell"
			     :buffer stdout-buffer
			     :coding 'binary
			     :noquery t
			     :sentinel #'ignore
			     :command (list "bash" "--norc" "--noprofile" "-c"
					    "op read op://Op.el/Email/password"))))
		(process-send-eof shell)
		(unwind-protect
		    (progn
		      (with-timeout (20 (delete-process shell))
			(while (process-live-p shell)
			  (accept-process-output shell 0.05)))
		      (expect (process-exit-status shell) :to-equal 0)
		      (expect (with-current-buffer stdout-buffer (buffer-string))
			      :to-equal "comanche-muscular-tabloids-minotaur-ally\n"))
		  (kill-buffer stdout-buffer))))

	  (it "should refuse a caller that does not descend from Emacs"
	      ;; The caller is reparented to init before it connects, so the
	      ;; ancestry check sees a process outside this Emacs's tree.  This is
	      ;; the whole security guarantee, so it is checked against a real
	      ;; detached process rather than a stubbed pid.
	      (let ((report (make-temp-file "op-shim-detached-")))
		(unwind-protect
		    (progn
		      (call-process (expand-file-name "test/helpers/detach.py") nil nil nil
				    report
				    (expand-file-name "bin/op-shim.py")
				    "read" "op://Op.el/Email/password")
		      (with-timeout (20 nil)
			(while (zerop (or (file-attribute-size (file-attributes report)) 0))
			  (accept-process-output nil 0.05)))
		      (let ((output (with-temp-buffer
				      (insert-file-contents report)
				      (buffer-string))))
			(expect output :to-match "does not descend from this Emacs")
			(expect output :to-match "EXIT:1")
			(expect output :not :to-match "comanche")))
		  (delete-file report)))))

;;; op-shim-test.el ends here
