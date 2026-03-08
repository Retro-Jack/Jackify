INSTALL_DIR := $(HOME)/.local/bin
LINK_NAME   := jackify
SCRIPT      := jackify.sh

.PHONY: install uninstall

install:
	@mkdir -p "$(INSTALL_DIR)"
	@ln -sf "$(CURDIR)/$(SCRIPT)" "$(INSTALL_DIR)/$(LINK_NAME)"
	@echo "Installed: $(INSTALL_DIR)/$(LINK_NAME) -> $(CURDIR)/$(SCRIPT)"

uninstall:
	@rm -f "$(INSTALL_DIR)/$(LINK_NAME)"
	@echo "Removed: $(INSTALL_DIR)/$(LINK_NAME)"
