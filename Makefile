EMACS ?= emacs
LOAD_PATH = -L . -L test
SOURCES = herdr-protocol.el herdr-model.el herdr-events.el herdr.el
TESTS = test/herdr-protocol-test.el test/herdr-model-test.el test/herdr-events-test.el test/herdr-integration-test.el
ALL_EL = $(SOURCES) test/herdr-mock-server.el $(TESTS)

.PHONY: compile test test-live clean doctor

compile:
	@for f in $(ALL_EL); do \
	  $(EMACS) --batch $(LOAD_PATH) -f batch-byte-compile $$f 2>&1 | grep -v "^$$" || true; \
	done

test: compile
	$(EMACS) --batch $(LOAD_PATH) -l ert -l herdr -l herdr-mock-server \
	  -l test/herdr-protocol-test.el -l test/herdr-model-test.el -l test/herdr-events-test.el \
	  -f ert-run-tests-batch-and-exit

# Live integration tests need a running Herdr server on the local socket.
test-live: compile
	HERDR_TEST_LIVE=1 $(EMACS) --batch $(LOAD_PATH) -l ert -l herdr \
	  -l test/herdr-integration-test.el -f ert-run-tests-batch-and-exit

doctor:
	$(EMACS) --batch $(LOAD_PATH) -l herdr --eval '(progn (herdr-doctor) (princ (with-current-buffer "*herdr-doctor*" (buffer-string))))'

clean:
	find . -name '*.elc' -delete
