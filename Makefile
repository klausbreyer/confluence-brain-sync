# Prefer the versioned vault, falling back to the legacy location.
TARGET_DIR ?= $(shell for target in "$(HOME)/vault/v01/myo" "$(HOME)/vault/myo"; do \
	if [ -d "$$target" ]; then printf '%s' "$$target"; break; fi; \
done)

.DEFAULT_GOAL := deploy
.PHONY: deploy deploy-pages deploy-spaces test

deploy-pages deploy-spaces: deploy

deploy:
	@if [ ! -d "$(TARGET_DIR)" ]; then \
		echo "No existing vault found. Checked $(HOME)/vault/v01/myo and $(HOME)/vault/myo. Set TARGET_DIR to an existing directory." >&2; \
		exit 1; \
	fi
	cp -f sync_confluence.exs sync_confluence_spaces.exs "$(TARGET_DIR)/"
	@echo "Copied both sync scripts to $(TARGET_DIR)"
	@for config in sync_confluence.local.exs sync_confluence_spaces.local.exs; do \
		if [ ! -f "$(TARGET_DIR)/$$config" ]; then \
			echo "Create $(TARGET_DIR)/$$config yourself with your private values."; \
		fi; \
	done

test:
	elixir sync_confluence_spaces_test.exs
	elixir sync_confluence_metadata_test.exs sync_confluence.exs
	elixir sync_confluence_metadata_test.exs sync_confluence_spaces.exs
