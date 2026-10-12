# Makefile for asmview.nvim

STYLUA_PATHS ?= lua plugin

.PHONY: help lint format

help:
	@echo "asmview.nvim — development commands"
	@echo ""
	@echo "  make lint    — run stylua --check against $(STYLUA_PATHS)"
	@echo "  make format  — rewrite $(STYLUA_PATHS) through stylua"

lint:
	stylua --check $(STYLUA_PATHS)

format:
	stylua $(STYLUA_PATHS)
