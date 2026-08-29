;;; op-shim.el --- forward op CLI calls into the Emacs PTY -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026 Renat Galimov

;; Author: Renat Galimov
;; Maintainer: Renat Galimov
;; Version: 0.3
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/renatgalimov/op.el
;; Keywords: password, op, 1password

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; 1Password CLI caches its biometric session per terminal, so `op' invoked
;; from an Emacs vterm gets a fresh terminal and prompts for a fingerprint.
;; This package listens on a unix socket and forwards such invocations to the
;; already-authenticated PTY that `op.el' maintains, so they never prompt.
;;
;; A caller is authorized only when the kernel says it descends from this
;; Emacs process.  Note this is not a defence against an attacker running as
;; the same user: that attacker can already read this process's memory and
;; environment.  It is a barrier against unrelated processes on the machine.

;;; Code:

(require 'op)
(require 'seq)
(require 'json)

(defconst op-shim--max-ancestry-depth 64
  "Maximum number of parent links to follow when checking ancestry.
Caps the walk so malformed `ps' output cannot hang Emacs.")

(defconst op-shim--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory this package was loaded from, used to locate bin/op-shim.py.")

(defcustom op-shim-runtime-directory
  (expand-file-name (format "op-el-%d" (user-uid))
                    (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory))
  "Directory holding the shim socket and the `op' executable put on PATH.
Created with owner-only permissions."
  :type 'directory
  :group 'op)

(defvar op-shim--server nil
  "Network process listening for shim requests, or nil.")

(defvar op-shim--queue nil
  "Requests waiting to run, as a list of (CONNECTION . REQUEST-LINE).")

(defvar op-shim--busy nil
  "Non-nil while the queue is being drained.")

(defconst op-shim--retry-delay-seconds 0.05
  "Seconds to wait before retrying a request that arrived while op was busy.")

(defvar op-shim--saved-path nil
  "Value of the PATH environment variable before `op-shim-mode' changed it.")

;;;###autoload
(define-minor-mode op-shim-mode
  "Serve op invocations from Emacs\='s children through the authenticated PTY.

While enabled, a unix socket accepts requests from the shim installed on
PATH, and each request is run through `op-run' so it reuses the biometric
session `op.el' already holds.

A request is served only when the kernel reports that the process which
opened the connection descends from this Emacs.  That is not a defence
against an attacker running as the same user, who can already read this
process\='s memory; it is a barrier against unrelated processes."
  :global t
  :group 'op
  (if op-shim-mode
      (condition-case error
          (op-shim--start)
        (error (setq op-shim-mode nil)
               (signal (car error) (cdr error))))
    (op-shim--stop)))

(defun op-shim--peer-lookup-supported-p ()
  "Return non-nil when this platform can report who opened a connection.
Identifying the caller relies on `lsof' naming a connected socket after
its peer\='s device address, which is a BSD form."
  ;; ponytail: macOS only.  Linux lsof reports unix peers through
  ;; /proc/net/unix inodes instead, so it needs `ss -x -p' or a /proc walk.
  ;; Until that exists the mode refuses to start rather than serving requests
  ;; it cannot attribute.
  (and (eq system-type 'darwin)
       (executable-find "lsof")
       t))

(defun op-shim--start ()
  "Create the runtime directory, install the shim and start listening.
Tears down a running server first, so enabling the mode twice does not
stack another copy of the runtime directory onto PATH."
  (unless (op-shim--peer-lookup-supported-p)
    (user-error "op-shim-mode cannot identify callers on %s: it needs macOS lsof"
                system-type))
  (when op-shim--server
    (op-shim--stop))
  (make-directory op-shim-runtime-directory t)
  (set-file-modes op-shim-runtime-directory #o700)
  (op-shim--install-executable)
  (when (file-exists-p (op-shim--socket-path))
    (delete-file (op-shim--socket-path)))
  (setq op-shim--queue nil
        op-shim--server (make-network-process
                         :name "op-shim"
                         :server t
                         :family 'local
                         :service (op-shim--socket-path)
                         :coding 'utf-8-unix
                         :noquery t
                         :filter #'op-shim--filter))
  (set-file-modes (op-shim--socket-path) #o600)
  (setq op-shim--saved-path (getenv "PATH"))
  (setenv "PATH" (concat op-shim-runtime-directory path-separator op-shim--saved-path))
  (setenv "OP_SHIM_SOCKET" (op-shim--socket-path))
  (setenv "OP_SHIM_REAL_OP" (or (executable-find op-executable) op-executable))
  (add-to-list 'exec-path op-shim-runtime-directory))

(defun op-shim--stop ()
  "Stop listening and undo everything `op-shim--start' put in place."
  (when op-shim--server
    (delete-process op-shim--server)
    (setq op-shim--server nil))
  (when (file-exists-p (op-shim--socket-path))
    (delete-file (op-shim--socket-path)))
  (setq op-shim--queue nil
        exec-path (delete op-shim-runtime-directory exec-path))
  (setenv "PATH" op-shim--saved-path)
  (setenv "OP_SHIM_SOCKET" nil)
  (setenv "OP_SHIM_REAL_OP" nil))

(defun op-shim--socket-path ()
  "Return the path of the socket shim requests arrive on."
  (expand-file-name "op.sock" op-shim-runtime-directory))

(defun op-shim--install-executable ()
  "Link bin/op-shim.py into the runtime directory under the name `op'."
  (let ((link (expand-file-name "op" op-shim-runtime-directory)))
    (when (file-symlink-p link)
      (delete-file link))
    (make-symbolic-link (expand-file-name "bin/op-shim.py" op-shim--directory)
                        link t)))

;;; Request handling
;;
;; The filter only queues: a request can arrive while `op-run' is waiting on
;; the PTY, and running it there would corrupt the in-flight command.

(defun op-shim--filter (connection output)
  "Queue any complete request line CONNECTION has sent in OUTPUT."
  (process-put connection 'op-shim-input
               (concat (or (process-get connection 'op-shim-input) "") output))
  (let ((pending (process-get connection 'op-shim-input)))
    (when (string-match "\n" pending)
      (process-put connection 'op-shim-input (substring pending (match-end 0)))
      (setq op-shim--queue
            (append op-shim--queue
                    (list (cons connection (substring pending 0 (match-beginning 0))))))
      (run-at-time 0 nil #'op-shim--drain))))

(defun op-shim--drain ()
  "Run queued requests one at a time.
Waits for any op command already in flight, including one started from
Lisp rather than from here: `op-run' keeps a single command's output in
`op--pty-output', so starting a second would corrupt both."
  (if (or op-shim--busy op--running)
      (when op-shim--queue
        (run-at-time op-shim--retry-delay-seconds nil #'op-shim--drain))
    (let ((op-shim--busy t))
      (while op-shim--queue
        (let ((request (pop op-shim--queue)))
          (op-shim--serve (car request) (cdr request)))))))

(defun op-shim--serve (connection request-line)
  "Run the op invocation described by REQUEST-LINE and reply on CONNECTION."
  (condition-case error
      (if (not (op-shim--authorized-p))
          (op-shim--respond connection
                            (list :error "caller does not descend from this Emacs"))
        (let* ((request (json-parse-string request-line
                                           :object-type 'plist
                                           :array-type 'list
                                           :null-object nil))
               (result (op-run (plist-get request :argv)
                               (op-shim--read-stdin (plist-get request :stdin))
                               (plist-get request :cwd)
                               (plist-get request :stdout))))
          (op-shim--respond connection
                            (list :exit_code (plist-get result :exit-code)
                                  :stderr (plist-get result :stderr)))))
    (error (op-shim--respond connection (list :error (error-message-string error))))))

(defun op-shim--respond (connection payload)
  "Send PAYLOAD to CONNECTION as one JSON line and close it."
  (when (process-live-p connection)
    (process-send-string connection (concat (json-serialize payload) "\n"))
    (process-send-eof connection))
  (when (process-live-p connection)
    (delete-process connection)))

(defun op-shim--read-stdin (path)
  "Return the contents of PATH as a string, or nil when PATH is nil."
  (when path
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (buffer-string))))

;;; Caller authorization
;;
;; A request is served only when the process that opened the connection
;; descends from this Emacs.  The connecting pid comes from the kernel via
;; `lsof' rather than from the request itself, so a caller cannot claim to be
;; someone else.

(defun op-shim--authorized-p ()
  "Return non-nil when every process connected to the socket descends from Emacs."
  (let ((peers (op-shim--peer-pids (op-shim--command-output "lsof" "-F" "pfdn" "-U")
                                   (op-shim--socket-path)
                                   (emacs-pid))))
    (and peers
         (let ((tree (op-shim--command-output "ps" "-Ao" "pid=,ppid=")))
           (seq-every-p (lambda (pid) (op-shim--descendant-of-p tree pid (emacs-pid)))
                        peers)))))

(defun op-shim--command-output (program &rest args)
  "Return the standard output of PROGRAM run with ARGS.
Signals an error carrying PROGRAM's stderr when it fails, so a broken
lookup is reported as such instead of being reported to the caller as a
failed ancestry check."
  (let ((stderr-file (make-temp-file "op-shim-stderr-")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process program nil
                               (list t stderr-file) nil args)))
            (unless (eq status 0)
              (error "%s exited with %s: %s" program status
                     (string-trim (op--read-and-delete-file stderr-file))))
            (buffer-string)))
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

(defun op-shim--peer-pids (lsof-output socket-path server-pid)
  "Return the pids connected to SOCKET-PATH through SERVER-PID's sockets.
LSOF-OUTPUT is the output of `lsof -F pfdn -U'.  Every socket SERVER-PID
has bound to SOCKET-PATH contributes a device address, and a peer is any
other process holding a socket named \"->DEVICE\".  A listening socket has
no such referrer, so only accepted connections resolve to a peer."
  (let* ((sockets (op-shim--parse-lsof lsof-output))
         (referrers (mapcar (lambda (socket)
                              (concat "->" (plist-get socket :device)))
                            (seq-filter
                             (lambda (socket)
                               (and (equal (plist-get socket :pid) server-pid)
                                    (equal (plist-get socket :name) socket-path)))
                             sockets))))
    (delete-dups
     (mapcar (lambda (socket) (plist-get socket :pid))
             (seq-filter
              (lambda (socket)
                (and (not (equal (plist-get socket :pid) server-pid))
                     (member (plist-get socket :name) referrers)))
              sockets)))))

(defun op-shim--parse-lsof (lsof-output)
  "Parse LSOF-OUTPUT from `lsof -F pfdn -U' into a list of socket plists.
Each plist holds :pid, :fd, :device and :name.  A `p' field introduces a
process and applies to every file record that follows it until the next
`p', so the pid is carried forward rather than repeated per record."
  (let ((sockets nil)
        (pid nil)
        (fd nil)
        (device nil))
    (dolist (line (split-string lsof-output "\n" t))
      (pcase (aref line 0)
        (?p (setq pid (string-to-number (substring line 1))))
        (?f (setq fd (substring line 1)
                  device nil))
        (?d (setq device (substring line 1)))
        (?n (push (list :pid pid :fd fd :device device :name (substring line 1))
                  sockets))))
    (nreverse sockets)))

(defun op-shim--descendant-of-p (ps-output child-pid ancestor-pid)
  "Return non-nil when CHILD-PID descends from ANCESTOR-PID.
PS-OUTPUT is the output of `ps -Ao pid=,ppid='.  ANCESTOR-PID must appear
strictly above CHILD-PID, so a process never counts as its own descendant.
The walk stops after `op-shim--max-ancestry-depth' links so a malformed
process tree cannot hang Emacs."
  (let ((parents (op-shim--parse-process-tree ps-output))
        (current child-pid)
        (depth 0)
        (found nil))
    (while (and current (not found) (< depth op-shim--max-ancestry-depth))
      (setq current (gethash current parents)
            depth (1+ depth))
      (when (and current (= current ancestor-pid))
        (setq found t)))
    found))

(defun op-shim--parse-process-tree (ps-output)
  "Parse PS-OUTPUT from `ps -Ao pid=,ppid=' into a pid-to-parent hash table."
  (let ((parents (make-hash-table :test 'eql)))
    (dolist (line (split-string ps-output "\n" t))
      (let ((fields (split-string line nil t)))
        (when (= (length fields) 2)
          (puthash (string-to-number (nth 0 fields))
                   (string-to-number (nth 1 fields))
                   parents))))
    parents))

(provide 'op-shim)

;;; op-shim.el ends here
