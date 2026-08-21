EMACS ?= emacs
LOAD_PATH = -L . -L test
SOURCES = herdr-protocol.el herdr-model.el herdr-events.el herdr.el agent-fleet.el agent-fleet-worktree.el agent-fleet-project.el agent-fleet-magit.el agent-fleet-parallel.el agent-fleet-attach.el agent-fleet-dashboard.el
TESTS = test/herdr-protocol-test.el test/herdr-model-test.el test/herdr-events-test.el test/herdr-integration-test.el test/agent-fleet-test.el test/agent-fleet-dashboard-test.el test/agent-fleet-project-test.el test/agent-fleet-worktree-test.el test/agent-fleet-magit-test.el test/agent-fleet-parallel-test.el test/agent-fleet-attach-test.el
ALL_EL = $(SOURCES) test/herdr-mock-server.el $(TESTS)

.PHONY: compile test test-live clean doctor

compile:
	@for f in $(ALL_EL); do \
	  $(EMACS) --batch $(LOAD_PATH) -f batch-byte-compile $$f 2>&1 | grep -v "^$$" || true; \
	done

test: compile
	$(EMACS) --batch $(LOAD_PATH) -l ert -l herdr -l agent-fleet \
	  -l agent-fleet-worktree -l agent-fleet-project -l agent-fleet-magit \
	  -l agent-fleet-parallel -l agent-fleet-attach -l agent-fleet-dashboard \
	  -l herdr-mock-server \
	  -l test/herdr-protocol-test.el -l test/herdr-model-test.el -l test/herdr-events-test.el \
	  -l test/agent-fleet-test.el -l test/agent-fleet-dashboard-test.el \
	  -l test/agent-fleet-project-test.el -l test/agent-fleet-worktree-test.el \
	  -l test/agent-fleet-magit-test.el -l test/agent-fleet-parallel-test.el \
	  -l test/agent-fleet-attach-test.el \
	  -f ert-run-tests-batch-and-exit

# Live integration tests need a running Herdr server on the local socket.
test-live: compile
	HERDR_TEST_LIVE=1 $(EMACS) --batch $(LOAD_PATH) -l ert -l herdr \
	  -l test/herdr-integration-test.el -f ert-run-tests-batch-and-exit

doctor:
	$(EMACS) --batch $(LOAD_PATH) -l herdr --eval '(progn (herdr-doctor) (princ (with-current-buffer "*herdr-doctor*" (buffer-string))))'

clean:
	find . -name '*.elc' -delete
