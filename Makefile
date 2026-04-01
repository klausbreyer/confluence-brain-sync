TARGET_DIR ?= $(HOME)/vault/v01/myo
SCRIPT_NAME := sync_confluence.exs
CONFIG_EXAMPLE := sync_confluence.local.example.exs
CONFIG_NAME := sync_confluence.local.exs

.PHONY: deploy

deploy:
	mkdir -p "$(TARGET_DIR)"
	cp -f "$(SCRIPT_NAME)" "$(TARGET_DIR)/$(SCRIPT_NAME)"
	cp -f "$(CONFIG_EXAMPLE)" "$(TARGET_DIR)/$(CONFIG_EXAMPLE)"
	@echo "Copied $(SCRIPT_NAME) to $(TARGET_DIR)/$(SCRIPT_NAME)"
	@echo "Copied $(CONFIG_EXAMPLE) to $(TARGET_DIR)/$(CONFIG_EXAMPLE)"
	@if [ ! -f "$(TARGET_DIR)/$(CONFIG_NAME)" ]; then \
		echo "Create $(TARGET_DIR)/$(CONFIG_NAME) from the example file and put your private values there."; \
	fi
