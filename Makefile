.PHONY: test lint indent

test:
	cask install
	cask exec emacs --batch -Q -L . -L test -l test/run-tests.el


lint:
	cask install
	cask exec emacs --batch -Q \
	  -l scripts/op-lint.el \
	  $(wildcard *.el)

indent:
	./scripts/check-indent.sh
