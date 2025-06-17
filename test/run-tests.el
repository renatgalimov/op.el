(let* ((script-dir (file-name-directory (or load-file-name buffer-file-name)))
       (root-dir (expand-file-name ".." script-dir)))
  (add-to-list 'load-path root-dir)
  (load (expand-file-name "op-test.el" script-dir)))

(ert-run-tests-batch-and-exit)
