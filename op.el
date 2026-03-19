;;; op.el --- 1Password interaction via op command -*- lexical-binding: t; -*-

;; Author: Renat Galimov
;; Version: 0.2
;; Keywords: password, op, 1password

;;; Commentary:

;; This package allows interaction with 1Password via the `op` CLI command.
;; It supports signing in, listing vault items, reading passwords, and logs all events in *op-log* buffer.
;;; Code:

(require 'json)
(require 'subr-x)
(require 'time)

(defgroup op nil
  "1Password integration via the op CLI."
  :group 'applications)

(defcustom op-executable "op"
  "Path to the op CLI executable."
  :type 'string
  :group 'op)

(defcustom op-read-cache-duration (* 10 60)
  "Cache duration in seconds for `op-read` results. Default is 10 minutes."
  :type 'integer
  :group 'op)

(defvar op-read-cache (make-hash-table :test 'equal)
  "Cache for storing results of `op-read' calls.
Each entry is a cons cell of the form (RESULT . TIMESTAMP).")

(defun op-read (path &optional account)
  "Read a default field from from a 1Password item at PATH.

The result is cached for efficiency.

You can specify an ACCOUNT to read from a specific 1Password account."

  (let* ((cache-key (if account (format "%s|%s" account path) path))
         (entry (gethash cache-key op-read-cache))
         (cached-result (car-safe entry))
         (timestamp (cdr-safe entry))
         (now (float-time)))
    (if (and cached-result (< (- now timestamp) op-read-cache-duration))
        cached-result
      (let* ((args (append (when account (list "--account" account))
                           (list "read" path)))
             (result-buffer (generate-new-buffer "*op-read*"))
             (exit-code (apply #'call-process op-executable nil result-buffer nil args))
             (result (with-current-buffer result-buffer
                       (prog1 (string-trim (buffer-string))
                         (kill-buffer result-buffer)))))
        (when (zerop exit-code)
          (puthash cache-key (cons result now) op-read-cache))
        result))))


(defun op-read-cache-cleanup (&optional force)
  "Remove cache entries older than `op-read-cache-duration' seconds.

Use optional FORCE argument to force cleanup regardless of age."
  (interactive "P")
  (let ((now (float-time)))
    (maphash (lambda (key val)
               (when (or force (> (- now (cdr val)) op-read-cache-duration))
                 (remhash key op-read-cache)))
             op-read-cache)))

;; Set up a timer that runs when Emacs is idle for a while
(run-with-idle-timer 60 t #'op-read-cache-cleanup)

(provide 'op)

;;; op.el ends here
