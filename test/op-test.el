;;; op-test.el --- unit tests -*- lexical-binding: t; -*-

(require 'buttercup)
(load-file "op.el")

(describe "op-read"
	  (it "when called twice should use the cached result"
	      (let ((op-read-cache (make-hash-table :test 'equal))
		    (called 0))
		(spy-on 'shell-command-to-string
			:and-call-fake (lambda (&rest _)
					 (setq called (1+ called))
					 "secret"))
		(expect (op-read "item") :to-equal "secret")
		(expect called :to-equal 1)
		(expect (op-read "item") :to-equal "secret")
		(expect called :to-equal 1))))

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
        (spy-on 'shell-command-to-string
                :and-call-fake (lambda (&rest _)
                                 (setq called (1+ called))
                                 "secret"))
        (expect (op-read "item") :to-equal "secret")
        (expect called :to-equal 1)
        (sleep-for 2)
        (expect (op-read "item") :to-equal "secret")
        (expect called :to-equal 2))))

(provide 'op-test)
