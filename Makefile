PREFIX ?= $(HOME)/.local
BINDIR = $(PREFIX)/bin
COMPDIR = $(HOME)/.local/share/bash-completion/completions

.PHONY: install uninstall

install:
	@mkdir -p $(BINDIR)
	@mkdir -p $(COMPDIR)
	install -m 755 toolboxer $(BINDIR)/toolboxer
	install -m 644 completions/toolboxer.bash $(COMPDIR)/toolboxer
	@echo "Installed toolboxer to $(BINDIR)/toolboxer"
	@echo "Installed completions to $(COMPDIR)/toolboxer"
	@case ":$$PATH:" in \
		*:$(BINDIR):*) ;; \
		*) echo "NOTE: $(BINDIR) is not in your PATH. Add it with:"; \
		   echo "  export PATH=\"\$$PATH:$(BINDIR)\"" ;; \
	esac

uninstall:
	rm -f $(BINDIR)/toolboxer
	rm -f $(COMPDIR)/toolboxer
	@echo "Uninstalled toolboxer"
