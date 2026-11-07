;;; op-test-support.el --- shared test safeguards -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(defun op-test--loopback-proxy-p ()
  "Return non-nil only for an unambiguous loopback HTTPS proxy.
Disallow bypass settings so real CLI traffic cannot escape the proxy."
  (let ((upper (getenv "HTTPS_PROXY"))
        (lower (getenv "https_proxy")))
    (and (or upper lower)
         (cl-every (lambda (value)
                     (or (null value)
                         (string-match-p
                          "\\`http://\\(127\\.0\\.0\\.1\\|localhost\\|\\[::1\\]\\):[0-9]+/?\\'"
                          value)))
                   (list upper lower))
         (or (null upper) (null lower) (equal upper lower))
         (cl-every (lambda (value) (or (null value) (string-empty-p value)))
                   (list (getenv "NO_PROXY") (getenv "no_proxy"))))))

(defun op-test--mitmproxy-p ()
  "Probe the configured loopback proxy's mitmproxy certificate page."
  (when (and (op-test--loopback-proxy-p) (executable-find "curl"))
    (with-temp-buffer
      (and (eq 0 (call-process "curl" nil t nil "--silent" "--show-error"
                               "--fail" "--max-time" "2" "--proxy"
                               (or (getenv "HTTPS_PROXY") (getenv "https_proxy"))
                               "--noproxy" "" "http://mitm.it/"))
           (progn (goto-char (point-min))
                  (search-forward "<title>mitmproxy</title>" nil t))))))

(provide 'op-test-support)