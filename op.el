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

(defcustom op-debug nil
  "When non-nil, log op operations to the *op-log* buffer."
  :type 'boolean
  :group 'op)

(defcustom op-executable "op"
  "Path to the op CLI executable."
  :type 'string
  :group 'op)

(defcustom op-command-timeout-seconds 30
  "Maximum seconds to wait for a single op CLI command to finish."
  :type 'integer
  :group 'op)

(defconst op--sigkill 9
  "SIGKILL signal number used to forcefully terminate a stuck process.")

(defconst op--sigint-grace-period-seconds 1
  "Seconds to wait for a process to exit after sending Ctrl-C (SIGINT).
If the process does not exit within this period, it is killed with SIGKILL.")

(defconst op--poll-interval-seconds 0.1
  "Seconds between polls when waiting for op command output.")

(defconst op--pty-startup-timeout-seconds 1
  "Seconds to wait for the PTY shell to initialize after startup.")

(defun op--log (format-string &rest arguments)
  "Log a message to the *op-log* buffer when `op-debug' is non-nil.
FORMAT-STRING and ARGUMENTS are passed to `format'."
  (when op-debug
    (with-current-buffer (get-buffer-create "*op-log*")
      (goto-char (point-max))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ")
              (apply #'format format-string arguments)
              "\n"))))

;;; PTY-based process management
;;
;; 1Password CLI caches biometric sessions per terminal.  Running all
;; op commands through a single persistent shell with a PTY ensures
;; the session is reused, avoiding repeated fingerprint prompts.

(defvar op--pty-process nil
  "Persistent shell process with a PTY for running op commands.")

(defvar op--pty-output ""
  "Accumulated output from the PTY shell process.")

(defun op-read (path &optional account)
  "Read a default field from a 1Password item at PATH.

You can specify an ACCOUNT to read from a specific 1Password account."
  (let* ((args (append (when account (list "--account" account))
                       (list "read" path)))
         (result (op-run args)))
    (string-trim (plist-get result :stdout))))

(defun op--fetch-items (tag)
  "Fetch full 1Password items tagged with TAG.
Iterates over all accounts, fetching items from each.
Each returned item alist has an extra `account_uuid' key."
  (let ((accounts (op--list-accounts))
        (all-items nil))
    (op--log "found %d accounts" (length accounts))
    (dolist (account accounts)
      (let* ((account-uuid (alist-get 'account_uuid account))
             (items-json (op--list-items account-uuid tag))
             (items-list (json-read-from-string items-json)))
        (op--log "account %s: %d items from list" account-uuid
                 (if (vectorp items-list) (length items-list) 0))
        (when (and (vectorp items-list) (> (length items-list) 0))
          (let ((detailed (op--get-items items-json account-uuid)))
            (op--log "account %s: %d detailed items" account-uuid (length detailed))
            (dolist (item detailed)
              (push (cons (cons 'account_uuid account-uuid) item) all-items))))))
    (nreverse all-items)))

(defun op--list-accounts ()
  "List all 1Password accounts.
Returns a list of alists with account details.
Signals an error and pops up stderr if the command fails."
  (let* ((result (op-run (list "account" "list" "--format" "json")))
         (exit-code (plist-get result :exit-code))
         (output (plist-get result :stdout))
         (stderr (plist-get result :stderr)))
    (op--check-exit exit-code stderr "op account list --format json")
    (append (json-read-from-string output) nil)))

(defun op--list-items (account tag)
  "List 1Password item summaries tagged with TAG for ACCOUNT.
ACCOUNT is an account UUID string.
TAG is the tag string to filter items by.
Returns a JSON string.
Signals an error and pops up stderr if the command fails."
  (let* ((result (op-run (list "--account" account
                               "item" "list"
                               "--tags" tag
                               "--format" "json")))
         (exit-code (plist-get result :exit-code))
         (output (plist-get result :stdout))
         (stderr (plist-get result :stderr)))
    (op--check-exit exit-code stderr
                    (format "op --account %s item list --tags %s --format json"
                            account tag))
    output))

(defun op--get-items (items-json account)
  "Get full details for items by passing ITEMS-JSON via a pipe.
ACCOUNT is the account UUID to use.
Returns a list of alists with full item details.
Signals an error and pops up stderr if the command fails."
  (let* ((result (op-run (list "--account" account
                               "item" "get" "-"
                               "--format" "json")
                         items-json))
         (exit-code (plist-get result :exit-code))
         (output (plist-get result :stdout))
         (stderr (plist-get result :stderr))
         (command (format "op --account %s item get - --format json" account)))
    (op--check-exit exit-code stderr command items-json)
    (op--parse-json-objects output)))

(defun op--parse-json-objects (string)
  "Parse STRING containing one or more concatenated JSON objects.
Returns a list of alists.  Handles both a JSON array and
concatenated top-level objects as output by `op item get'."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let (items)
      (skip-chars-forward " \t\n\r")
      (while (not (eobp))
        (let ((obj (json-read)))
          (if (vectorp obj)
              (dolist (element (append obj nil))
                (push element items))
            (push obj items)))
        (skip-chars-forward " \t\n\r"))
      (nreverse items))))

(defun op--check-exit (exit-code stderr command &optional stdin-data)
  "Check EXIT-CODE of COMMAND; if non-zero, pop up STDERR and signal error.
STDERR is a string containing the standard error output.
COMMAND is a string describing the full command invocation for the error message.
STDIN-DATA, if non-nil, is included in the error buffer for diagnostics."
  (unless (zerop exit-code)
    (with-current-buffer (get-buffer-create "*op-error*")
      (goto-char (point-max))
      (unless (bobp) (insert "\n\n"))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ") command "\n")
      (insert (format "Exit code: %d\n" exit-code))
      (when stdin-data
        (insert "Stdin:\n" stdin-data "\n"))
      (insert "Stderr:\n" stderr "\n")
      (display-buffer (current-buffer)))
    (error "%s failed (exit %d)" command exit-code)))

(defun op-run (args &optional stdin-data)
  "Run the op CLI with ARGS through a persistent PTY shell.
ARGS is a list of argument strings.  Optional STDIN-DATA is a string
piped to the command\\='s stdin via a temp file.
Returns a plist (:exit-code N :stdout STRING :stderr STRING)."
  (op--ensure-pty)
  (op--log "op-run: %s %s" op-executable (mapconcat #'identity args " "))
  (let ((command-id (op--generate-random-tag)))
    (unwind-protect
        (let ((result (progn
                        (setq op--pty-output "")
                        (process-send-string op--pty-process (op--make-run-shell-command command-id args stdin-data))
                        (op--wait-for-command command-id args)
                        (op--parse-pty-output command-id))))
          (op--log "op-run: exit-code=%d" (plist-get result :exit-code))
          result)
      (op--cleanup-temp-files command-id))))

(defun op--ensure-pty ()
  "Ensure the PTY shell process is alive, starting it if needed."
  (unless (and op--pty-process (process-live-p op--pty-process))
    (op--start-pty)))

(defun op--generate-random-tag ()
  "Generate a random alphanumeric tag for command output markers."
  (let ((chars "abcdefghijklmnopqrstuvwxyz0123456789"))
    (apply #'string (cl-loop repeat 16 collect (aref chars (random (length chars)))))))

(defun op--filter-pty (_process output)
  "Accumulate OUTPUT from the PTY process."
  (setq op--pty-output (concat op--pty-output output)))

(defun op--start-pty ()
  "Start a fresh PTY shell process for op commands."
  (setq op--pty-process
        (make-process
         :name "op-pty"
         :buffer (generate-new-buffer " *op-pty*")
         :command (list "bash" "--norc" "--noprofile")
         :connection-type 'pty
         :filter #'op--filter-pty)
        op--pty-output "")
  (process-send-string op--pty-process "stty -echo && PS1='' && PS2=''\n")
  (accept-process-output op--pty-process op--pty-startup-timeout-seconds)
  (setq op--pty-output ""))

(defun op--kill-stuck-command ()
  "Try to stop a stuck command on the PTY process.
First sends Ctrl-C (SIGINT) and waits briefly.  If the process
does not respond, escalates to SIGKILL and discards the PTY."
  (when (process-live-p op--pty-process)
    (process-send-string op--pty-process "\C-c\n")
    (setq op--pty-output "")
    (accept-process-output op--pty-process op--sigint-grace-period-seconds)
    (when (and (process-live-p op--pty-process)
               (string-empty-p (string-trim op--pty-output)))
      (signal-process op--pty-process op--sigkill)
      (setq op--pty-process nil))))

(defun op--read-and-delete-file (path)
  "Read the contents of file at PATH, delete it, and return the trimmed string."
  (prog1 (with-temp-buffer
           (insert-file-contents path)
           (string-trim (buffer-string)))
    (delete-file path)))

(defun op--make-stderr-path (command-id)
  "Return the stderr temp file path for COMMAND-ID."
  (expand-file-name (format "op-stderr-%s" command-id) temporary-file-directory))

(defun op--make-stdin-path (command-id)
  "Return the stdin temp file path for COMMAND-ID."
  (expand-file-name (format "op-stdin-%s" command-id) temporary-file-directory))

(defun op--make-run-shell-command (command-id args &optional stdin-data)
  "Build the shell command string for an op invocation.
COMMAND-ID is a unique tag used to delimit output.
ARGS is a list of argument strings for the op executable.
Optional STDIN-DATA, if non-nil, is written to a temp file and piped as stdin.
Returns the shell command string."
  (let ((begin-tag (format "__OP_BEGIN_%s__" command-id))
        (end-tag (format "__OP_END_%s__" command-id))
        (stderr-file (op--make-stderr-path command-id))
        (stdin-file (when stdin-data
                      (let ((file (op--make-stdin-path command-id)))
                        (write-region stdin-data nil file nil 'silent)
                        file)))
        (quoted-args (mapconcat #'shell-quote-argument args " ")))
    (format "printf '\\n%s\\n' && %s %s%s 2>%s; printf '\\n%s:%%d\\n' \"$?\"\n"
            begin-tag
            (shell-quote-argument op-executable)
            quoted-args
            (if stdin-file
                (format " <%s" (shell-quote-argument stdin-file))
              "")
            (shell-quote-argument stderr-file)
            end-tag)))

(defun op--parse-pty-output (command-id)
  "Parse `op--pty-output' delimited by COMMAND-ID markers.
Returns a plist (:exit-code N :stdout STRING :stderr STRING)."
  (let* ((begin-tag (format "__OP_BEGIN_%s__" command-id))
         (end-tag (format "__OP_END_%s__" command-id))
         (begin-re (format "\n%s\n" (regexp-quote begin-tag)))
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
         (stderr (op--read-and-delete-file (op--make-stderr-path command-id))))
    (list :exit-code exit-code :stdout stdout :stderr stderr)))

(defun op--wait-for-command (command-id args)
  "Wait for the PTY command identified by COMMAND-ID to finish.
ARGS is the original argument list, used in the timeout error message.
Signals an error if the command does not complete within `op-command-timeout-seconds'."
  (let ((end-tag-re (regexp-quote (format "__OP_END_%s__" command-id)))
        (deadline (+ (float-time) op-command-timeout-seconds)))
    (while (and (not (string-match-p end-tag-re op--pty-output))
                (process-live-p op--pty-process)
                (< (float-time) deadline))
      (accept-process-output op--pty-process op--poll-interval-seconds))
    (unless (string-match-p end-tag-re op--pty-output)
      (op--kill-stuck-command)
      (error "op timed out after %d seconds: %s %s"
             op-command-timeout-seconds op-executable
             (mapconcat #'identity args " ")))))

(defun op--cleanup-temp-files (command-id)
  "Delete temporary stdin and stderr files for COMMAND-ID if they exist."
  (when (file-exists-p (op--make-stdin-path command-id))
    (delete-file (op--make-stdin-path command-id)))
  (when (file-exists-p (op--make-stderr-path command-id))
    (delete-file (op--make-stderr-path command-id))))


(provide 'op)

;;; op.el ends here
