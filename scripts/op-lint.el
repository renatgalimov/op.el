;;; op-lint.el --- 1Password interaction via op command -*- lexical-binding: t; -*-
;;
;; Filename: op-lint.el
;; Description:
;; Author: Renat Galimov
;; Maintainer:
;; Created: Mon Jun 30 13:56:03 2025 (+0300)
;; Version:
;; Package-Requires: ()
;; Last-Updated:
;;           By:
;;     Update #: 3
;; URL:
;; Doc URL:
;; Keywords:
;; Compatibility:
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;;
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Change Log:
;;
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

;; lint-script.el
(require 'package-lint)
(package-initialize)

;; Advice to let Flymake see all of `load-path`
(advice-add 'elisp-flymake-byte-compile :around
            (lambda (orig &rest args)
              (let ((elisp-flymake-byte-compile-load-path
                     (append load-path elisp-flymake-byte-compile-load-path)))
                (apply orig args))))

(setq exit-code 0)

;; Process each file passed after `--`
(dolist (file command-line-args-left)
  (message "👉 Linting %s..." file)
  (let ((diags
         (with-temp-buffer
           (insert-file-contents file)
           (flymake-mode 1)
           (flymake-start)
           (sit-for 0.1)
           (flymake-diagnostics))))
    (dolist (d diags)
      (when (flymake-diagnostic-error-p d)
        (setq exit-code 1)
        (pp d)))
    ;; Check package-lint if it's a package file
    (when (string-match-p "-pkg\\.el\\'" file)
      (let ((res (package-lint-buffer)))
        (unless (null res)
          (setq exit-code 1)
          (princ res)))))
  (message "✅ Done %s" file))

(kill-emacs exit-code)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; op-lint.el ends here
