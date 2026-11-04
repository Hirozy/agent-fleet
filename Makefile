EMACS ?= emacs
LOAD_PATH = -L . -L test
SOURCES = herdr-core.el agent-fleet.el agent-fleet-display.el agent-fleet-project.el agent-fleet-start.el agent-fleet-attach.el agent-fleet-dashboard.el agent-fleet-cleanup.el agent-fleet-magit.el agent-fleet-editor.el consult-agent-fleet.el
TESTS = test/herdr-core-test.el test/agent-fleet-core-test.el test/agent-fleet-display-test.el test/agent-fleet-editor-test.el
GUI_LOAD_PATH ?=
.PHONY: compile test test-live test-gui clean autoloads
autoloads:
	$(EMACS) -Q --batch -L . -l cl-lib -l cl-macs --eval "(require 'loaddefs-gen)" --eval '(let ((output (expand-file-name "agent-fleet-autoloads.el"))) (when (file-exists-p output) (delete-file output)) (loaddefs-generate default-directory output))'
compile: autoloads
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' -f batch-byte-compile $(SOURCES) $(TESTS) test/herdr-core-live-test.el test/herdr-core-gui-smoke.el
test: compile
	$(EMACS) -Q --batch $(LOAD_PATH) -l ert $(foreach f,$(TESTS),-l $(f)) -f ert-run-tests-batch-and-exit
test-live: compile
	$(EMACS) -Q --batch $(LOAD_PATH) -l ert -l test/herdr-core-live-test.el -f ert-run-tests-batch-and-exit
test-gui: compile
	$(EMACS) -Q -L $(CURDIR) -L $(CURDIR)/test $(GUI_LOAD_PATH) -l $(CURDIR)/test/herdr-core-gui-smoke.el
clean:
	find . -name '*.elc' -delete
	rm -f agent-fleet-autoloads.el
