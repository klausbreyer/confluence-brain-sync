TARGET_DIR ?= $(HOME)/vault/myo
SCRIPT_NAME := sync_confluence.exs
CONFIG_NAME := sync_confluence.local.exs

.DEFAULT_GOAL := deploy
.PHONY: deploy deploy-spaces test

deploy-spaces: SCRIPT_NAME := sync_confluence_spaces.exs
deploy-spaces: CONFIG_NAME := sync_confluence_spaces.local.exs

deploy deploy-spaces:
	mkdir -p "$(TARGET_DIR)"
	cp -f "$(SCRIPT_NAME)" "$(TARGET_DIR)/$(SCRIPT_NAME)"
	@echo "Copied $(SCRIPT_NAME) to $(TARGET_DIR)/$(SCRIPT_NAME)"
	@if [ ! -f "$(TARGET_DIR)/$(CONFIG_NAME)" ]; then \
		echo "Create $(TARGET_DIR)/$(CONFIG_NAME) yourself with your private values."; \
	fi

test:
	elixir sync_confluence_spaces_test.exs
