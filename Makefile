PLUGIN     := claude-ssh
SRC        := src
PKG        := $(PLUGIN).txz
TESTS      := tests
PLUGIN_DIR := $(SRC)/usr/local/emhttp/plugins/$(PLUGIN)

.PHONY: all clean test

all: $(PKG)

# Stage LICENSE into the plugin tree just before tar so the .txz ships it at
# /usr/local/emhttp/plugins/claude-ssh/LICENSE on the NAS. Removed after the
# tar so the source tree stays clean. .gitignore covers the staged copy.
$(PKG): $(shell find $(SRC) -type f 2>/dev/null) LICENSE
	@echo "Building $(PKG)..."
	@cp LICENSE $(PLUGIN_DIR)/LICENSE
	@cd $(SRC) && tar cJf ../$(PKG) --owner=root --group=root usr
	@rm -f $(PLUGIN_DIR)/LICENSE
	@md5=$$(md5sum $(PKG) 2>/dev/null | cut -d' ' -f1); \
	  [ -z "$$md5" ] && md5=$$(md5 -q $(PKG) 2>/dev/null); \
	  echo "Built: $(PKG) (md5: $$md5)"

test:
	@echo "Running claude-ssh plugin tests..."
	@bash $(TESTS)/run-all.sh

clean:
	rm -f $(PKG)
