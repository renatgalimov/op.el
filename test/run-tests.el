;;; run-tests.el --- run Buttercup suite -*- lexical-binding: t; -*-

(let* ((script-dir (file-name-directory (or load-file-name buffer-file-name)))
       (root-dir (expand-file-name ".." script-dir)))
  (add-to-list 'load-path root-dir)
  (add-to-list 'load-path script-dir)
  (require 'buttercup)
  (load (expand-file-name "op-test.el" script-dir))
  (load (expand-file-name "op-auth-source-test.el" script-dir)))

(setq backtrace-on-error-noninteractive nil)

(let ((buttercup-fail-fast t)
      (buttercup-stack-frame-style 'crop))
  (buttercup-run))
