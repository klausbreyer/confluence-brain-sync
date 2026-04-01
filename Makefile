TARGET_DIR ?= $(HOME)/vault/v01/myo
SCRIPT_NAME := sync_confluence.exs
CONFIG_NAME := sync_confluence.local.exs

.PHONY: deploy

deploy:
	mkdir -p "$(TARGET_DIR)"
	cp -f "$(SCRIPT_NAME)" "$(TARGET_DIR)/$(SCRIPT_NAME)"
	@echo "Copied $(SCRIPT_NAME) to $(TARGET_DIR)/$(SCRIPT_NAME)"
	@if [ ! -f "$(TARGET_DIR)/$(CONFIG_NAME)" ]; then \
		echo "Create $(TARGET_DIR)/$(CONFIG_NAME) yourself with your private values."; \
	fi
