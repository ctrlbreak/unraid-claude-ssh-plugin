PLUGIN  := claude-ssh
SRC     := src
PKG     := $(PLUGIN).txz
TESTS   := tests

.PHONY: all clean test

all: $(PKG)

$(PKG): $(shell find $(SRC) -type f 2>/dev/null)
	@echo "Building $(PKG)..."
	@cd $(SRC) && tar cJf ../$(PKG) --owner=root --group=root usr
	@md5=$$(md5sum $(PKG) 2>/dev/null | cut -d' ' -f1); \
	  [ -z "$$md5" ] && md5=$$(md5 -q $(PKG) 2>/dev/null); \
	  echo "Built: $(PKG) (md5: $$md5)"

test:
	@echo "Running claude-ssh plugin tests..."
	@bash $(TESTS)/run-all.sh

clean:
	rm -f $(PKG)
