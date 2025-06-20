;;; run-tests.el --- run Buttercup suite -*- lexical-binding: t; -*-

(let* ((script-dir (file-name-directory (or load-file-name buffer-file-name)))
       (root-dir (expand-file-name ".." script-dir)))
  (add-to-list 'load-path root-dir)
  (add-to-list 'load-path script-dir)
  (require 'buttercup)
  (load (expand-file-name "op-test.el" script-dir)))

(buttercup-run)
