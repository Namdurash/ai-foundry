SHELL := /bin/bash

# Gates and hooks ship to users' projects and run in CI, so they are held to the
# same standard as the CLI itself.
SHELL_SOURCES := bin/aif $(wildcard lib/*.sh) \
                 $(wildcard sets/*/gates/*.sh) $(wildcard sets/*/hooks/*.sh)

.PHONY: help lint fmt check

help:
	@echo "make lint   Run shellcheck over all shell sources"
	@echo "make fmt    Run shfmt (write mode) over all shell sources"
	@echo "make check  Smoke-check the CLI entry point"

lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "shellcheck not found — brew install shellcheck"; exit 1; }
	shellcheck -x $(SHELL_SOURCES)

fmt:
	@command -v shfmt >/dev/null 2>&1 || { \
		echo "shfmt not found — brew install shfmt"; exit 1; }
	shfmt -w -i 2 -ci $(SHELL_SOURCES)

# aif targets bash 3.2 (stock macOS). Run the entry point under it explicitly
# so that a newer bash on PATH cannot hide a 3.2 incompatibility.
check:
	@/bin/bash --version | head -1
	@/bin/bash bin/aif version
	@/bin/bash bin/aif help >/dev/null
	@echo "ok"
