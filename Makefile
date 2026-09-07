PREFIX ?= $(HOME)/.local
BINDIR = $(PREFIX)/bin
COMPDIR ?= $(PREFIX)/share/bash-completion/completions
SHELLCHECK ?= shellcheck

.PHONY: install uninstall test lint

install:
	@mkdir -p "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(COMPDIR)"
	install -m 755 toolboxer "$(DESTDIR)$(BINDIR)/toolboxer"
	install -m 644 completions/toolboxer.sh "$(DESTDIR)$(COMPDIR)/toolboxer"
	@echo "Installed toolboxer to $(BINDIR)/toolboxer"
	@echo "Installed completions to $(COMPDIR)/toolboxer"
	@case ":$$PATH:" in \
		*:"$(BINDIR)":*) ;; \
		*) echo "NOTE: $(BINDIR) is not in your PATH. Add it with:"; \
		   echo "  export PATH=\"\$$PATH:$(BINDIR)\"" ;; \
	esac

uninstall:
	rm -f -- "$(DESTDIR)$(BINDIR)/toolboxer"
	rm -f -- "$(DESTDIR)$(COMPDIR)/toolboxer"
	@echo "Uninstalled toolboxer"

test:
	TOOLBOXER_SKIP_PODMAN=1 bash tests/test_toolboxer.sh
	TOOLBOXER_SKIP_PODMAN=1 bash tests/test_isolation.sh
	python3 tests/test_regressions.py

lint:
	$(SHELLCHECK) toolboxer diagnose.sh install.sh completions/toolboxer.sh tests/*.sh
	@for script in toolboxer diagnose.sh install.sh completions/toolboxer.sh tests/*.sh; do bash -n "$$script" || exit; done
