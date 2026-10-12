# Makefile for asmview.nvim

STYLUA_PATHS ?= lua plugin
NEOSPEC      ?= neospec
NVIM_VERSION ?= v0.12.0
SPEC_DIR     ?= tests/asmview
SPEC_INIT    ?= tests/minimal_init.lua
SPEC_GLOB    ?= $(SPEC_DIR)/**/*_spec.lua

.PHONY: help lint format test test-file require-neospec

help:
	@echo "asmview.nvim — development commands"
	@echo ""
	@echo "  make lint              — run stylua --check against $(STYLUA_PATHS)"
	@echo "  make format            — rewrite $(STYLUA_PATHS) through stylua"
	@echo "  make test              — run every spec under $(SPEC_DIR)"
	@echo "  make test-file FILE=x  — run a single spec file"

lint:
	stylua --check $(STYLUA_PATHS)

format:
	stylua $(STYLUA_PATHS)

require-neospec:
	@command -v $(NEOSPEC) >/dev/null 2>&1 || { \
	  echo "error: $(NEOSPEC) not on PATH"; \
	  echo "install from https://github.com/jedi-knights/neospec/releases"; \
	  exit 1; \
	}

test: require-neospec
	@$(NEOSPEC) run --init-file=$(SPEC_INIT) --pattern='$(SPEC_GLOB)' \
		--neovim-version=$(NVIM_VERSION) --format=console

test-file: require-neospec
	@test -n "$(FILE)" || { echo "usage: make test-file FILE=tests/asmview/<name>_spec.lua"; exit 1; }
	@$(NEOSPEC) run --init-file=$(SPEC_INIT) --pattern='$(FILE)' \
		--neovim-version=$(NVIM_VERSION) --format=console
