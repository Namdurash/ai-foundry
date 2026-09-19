SHELL := /bin/bash

# Gates and hooks ship to users' projects and run in CI, so they are held to the
# same standard as the CLI itself.
SHELL_SOURCES := bin/aif $(wildcard lib/*.sh) \
                 $(wildcard sets/*/gates/*.sh) $(wildcard sets/*/hooks/*.sh) \
                 scripts/check-set.sh scripts/check-work.sh \
                 scripts/check-board.sh

# Where `make link` puts the symlink. Homebrew's prefix when there is one, so
# the link lands on the same PATH entry the tap would have used.
PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)

.PHONY: help lint fmt check link unlink

help:
	@echo "make lint    Run shellcheck over all shell sources"
	@echo "make fmt     Run shfmt (write mode) over all shell sources"
	@echo "make check   Smoke-check the CLI entry point"
	@echo "make link    Put THIS clone on PATH as \`aif\` (development)"
	@echo "make unlink  Take it back off"

# Run the clone, not the tap. Without this the obvious thing — cloning, editing,
# typing `aif` — silently runs whatever version Homebrew installed, and the
# difference only shows up as a command that does not exist yet.
link:
	@if brew list aif >/dev/null 2>&1; then \
		echo "Homebrew has aif installed; unlinking it so this clone wins:"; \
		brew unlink aif || true; \
	fi
	@mkdir -p "$(PREFIX)/bin"
	@ln -sfn "$(CURDIR)/bin/aif" "$(PREFIX)/bin/aif"
	@echo "linked $(PREFIX)/bin/aif -> $(CURDIR)/bin/aif"
	@command -v aif >/dev/null 2>&1 && printf 'which: %s\nversion: ' "$$(command -v aif)" && aif version || \
		echo "warning: $(PREFIX)/bin is not on your PATH"

unlink:
	@if [ -L "$(PREFIX)/bin/aif" ]; then rm -f "$(PREFIX)/bin/aif"; echo "removed $(PREFIX)/bin/aif"; \
	else echo "$(PREFIX)/bin/aif is not our symlink — left alone"; fi
	@brew list aif >/dev/null 2>&1 && echo "run 'brew link aif' to go back to the tap" || true

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
	@/bin/bash scripts/check-set.sh
	@/bin/bash scripts/check-work.sh
	@/bin/bash scripts/check-board.sh
	@echo "ok"
