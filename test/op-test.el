;;; op-test.el --- unit tests -*- lexical-binding: t; -*-

(require 'buttercup)
(load-file "op.el")

(describe "op-read"
	  (before-each
	   (setq op-read-cache (make-hash-table :test #'equal)))

	  (it "caches result"
	      (let ((called 0))
		(cl-letf (((symbol-function 'call-process)
			   (lambda (&rest args)
			     (setq called (1+ called))
			     (with-current-buffer (nth 2 args)
			       (insert "secret"))
			     0)))
			 (expect (op-read "item") :to-equal "secret")
			 (expect called :to-be 1)
			 (expect (op-read "item") :to-equal "secret")
			 (expect called :to-be 1))))

	  (it "does not cache error output"
	      (let ((called 0))
		(cl-letf (((symbol-function 'call-process)
			   (lambda (&rest args)
			     (setq called (1+ called))
			     (with-current-buffer (nth 2 args)
			       (insert "err"))
			     1)))
			 (expect (op-read "item") :to-equal "err")
			 (expect (gethash "item" op-read-cache) :to-be nil)
			 (expect called :to-be 1)
			 (expect (op-read "item") :to-equal "err")
			 (expect called :to-be 2))))

	  (it "when called twice should use the cached result"
	      (let ((op-read-cache (make-hash-table :test 'equal))
		    (called 0))
		(cl-letf (((symbol-function 'call-process)
			   (lambda (&rest args)
			     (setq called (1+ called))
			     (with-current-buffer (nth 2 args)
			       (insert "secret"))
			     0)))
			 (expect (op-read "item") :to-equal "secret")
			 (expect called :to-equal 1)
			 (expect (op-read "item") :to-equal "secret")
			 (expect called :to-equal 1)))))

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
		    (called 0)
		    (op-read-cache-duration 1)) ; 1 second for test
		(cl-letf (((symbol-function 'call-process)
			   (lambda (&rest args)
			     (setq called (1+ called))
			     (with-current-buffer (nth 2 args)
			       (insert "secret"))
			     0)))
			 (expect (op-read "item") :to-equal "secret")
			 (expect called :to-equal 1)
			 (sleep-for 2)
			 (expect (op-read "item") :to-equal "secret")
			 (expect called :to-equal 2)))))

(provide 'op-test)
