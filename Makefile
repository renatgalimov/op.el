.PHONY: lint
lint:
	cask install
	cask exec emacs --batch -Q \
	  -f elisp-lint-files-batch \
	  -l scripts/op-lint.el \
	  -- $(wildcard *.el)
