.PHONY: test test-proxy test-live lint indent

test:
	cask install
	cask exec emacs --batch -Q -L . -L test -l test/run-tests.el

test-proxy:
	python3 -m unittest discover -s test/proxy -v

test-live:
	python3 test/proxy/run-live.py


lint:
	cask install
	cask exec emacs --batch -Q \
	  -l scripts/op-lint.el \
	  $(wildcard *.el)

indent:
	./scripts/check-indent.sh
