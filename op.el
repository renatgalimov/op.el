;;; op.el --- 1Password interaction via op command -*- lexical-binding: t; -*-

;; Author: Renat Galimov
;; Version: 0.3
;; Keywords: password, op, 1password

;;; Commentary:

;; This package allows interaction with 1Password via the `op` CLI command.
;; It supports signing in, listing vault items, reading passwords, and logs all events in *op-log* buffer.
;;; Code:

(require 'cl-lib)
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

(defcustom op-command-timeout-seconds 30
  "Maximum seconds to wait for a single op CLI command to finish."
  :type 'integer
  :group 'op)

(defcustom op-read-cache-duration (* 10 60)
  "Cache duration in seconds for `op-read` results. Default is 10 minutes."
  :type 'integer
  :group 'op)

(defvar op-read-cache (make-hash-table :test 'equal)
  "Cache for storing results of `op-read' calls.
Each entry is a cons cell of the form (RESULT . TIMESTAMP).")

;;; PTY-based process management
;;
;; 1Password CLI caches biometric sessions per terminal.  Running all
;; op commands through a single persistent shell with a PTY ensures
;; the session is reused, avoiding repeated fingerprint prompts.

(defvar op--pty-process nil
  "Persistent shell process with a PTY for running op commands.")

(defvar op--pty-output ""
  "Accumulated output from the PTY shell process.")

(defun op--random-tag ()
  "Generate a random alphanumeric tag for command output markers."
  (let ((chars "abcdefghijklmnopqrstuvwxyz0123456789"))
    (apply #'string (cl-loop repeat 16 collect (aref chars (random (length chars)))))))

(defun op--pty-filter (_process output)
  "Accumulate OUTPUT from the PTY process."
  (setq op--pty-output (concat op--pty-output output)))

(defun op--pty-start ()
  "Start a fresh PTY shell process for op commands."
  (setq op--pty-process
        (make-process
         :name "op-pty"
         :buffer (generate-new-buffer " *op-pty*")
         :command (list "bash" "--norc" "--noprofile")
         :connection-type 'pty
         :filter #'op--pty-filter)
        op--pty-output "")
  (process-send-string op--pty-process "stty -echo && PS1='' && PS2=''\n")
  (accept-process-output op--pty-process 1)
  (setq op--pty-output ""))

(defun op--pty-ensure ()
  "Ensure the PTY shell process is alive, starting it if needed."
  (unless (and op--pty-process (process-live-p op--pty-process))
    (op--pty-start)))

(defun op--read-and-delete-file (path)
  "Read the contents of file at PATH, delete it, and return the trimmed string."
  (prog1 (with-temp-buffer
           (insert-file-contents path)
           (string-trim (buffer-string)))
    (delete-file path)))

(defun op-run (args &optional stdin-data)
  "Run the op CLI with ARGS through a persistent PTY shell.
ARGS is a list of argument strings.  Optional STDIN-DATA is a string
piped to the command\\='s stdin via a temp file.
Returns a plist (:exit-code N :stdout STRING :stderr STRING)."
  (op--pty-ensure)
  (let* ((command-id (op--random-tag))
         (begin-tag (format "__OP_BEGIN_%s__" command-id))
         (end-tag (format "__OP_END_%s__" command-id))
         (stderr-file (make-temp-file "op-stderr"))
         (stdin-file (when stdin-data
                       (let ((file (make-temp-file "op-stdin")))
                         (write-region stdin-data nil file nil 'silent)
                         file)))
         (quoted-args (mapconcat #'shell-quote-argument args " "))
         (shell-command
          (format "printf '\\n%s\\n' && %s %s%s 2>%s; printf '\\n%s:%%d\\n' \"$?\"\n"
                  begin-tag
                  (shell-quote-argument op-executable)
                  quoted-args
                  (if stdin-file
                      (format " <%s" (shell-quote-argument stdin-file))
                    "")
                  (shell-quote-argument stderr-file)
                  end-tag)))
    (setq op--pty-output "")
    (process-send-string op--pty-process shell-command)
    (let ((deadline (+ (float-time) op-command-timeout-seconds)))
      (while (and (not (string-match-p (regexp-quote end-tag) op--pty-output))
                  (process-live-p op--pty-process)
                  (< (float-time) deadline))
        (accept-process-output op--pty-process 0.1)))
    (when stdin-file (delete-file stdin-file))
    (let* ((begin-re (format "\n%s\n" (regexp-quote begin-tag)))
           (end-re (format "\n%s:\\([0-9]+\\)" (regexp-quote end-tag)))
           (begin-pos (when (string-match begin-re op--pty-output)
                        (match-end 0)))
           (end-pos (when (and begin-pos
                               (string-match end-re op--pty-output begin-pos))
                      (match-beginning 0)))
           (exit-code (if end-pos
                          (string-to-number (match-string 1 op--pty-output))
                        -1))
           (stdout (if (and begin-pos end-pos)
                       (substring op--pty-output begin-pos end-pos)
                     ""))
           (stderr (op--read-and-delete-file stderr-file)))
      (list :exit-code exit-code :stdout stdout :stderr stderr))))

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
             (result (op-run args))
             (exit-code (plist-get result :exit-code))
             (output (string-trim (plist-get result :stdout))))
        (when (zerop exit-code)
          (puthash cache-key (cons output now) op-read-cache))
        output))))


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
