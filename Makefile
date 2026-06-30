# ai-footprint — semver release tooling (semversioner-backed)
#
#   make add-change BUMP=minor MSG="..."   record a changeset under .semversioner/next-release
#   make release                           consume changesets: bump, regen CHANGELOG, commit + tag
#   make changelog                         regenerate CHANGELOG.md from changesets
#   make version                           print current version
#   make help                              this list
#
# Engine: semversioner (pip install semversioner). It owns version computation
# from the changesets in .semversioner/; we mirror the result into plugin.json
# + marketplace.json (the canonical version) and the git tag.

PLUGIN_JSON   := .claude-plugin/plugin.json
MARKET_JSON   := .claude-plugin/marketplace.json
CHANGELOG     := CHANGELOG.md
TEMPLATE      := .semversioner/config/template.j2

BUMP ?= patch

# Resolve current version from semversioner (falls back to plugin.json).
VERSION := $(shell semversioner current-version 2>/dev/null || jq -r .version $(PLUGIN_JSON) 2>/dev/null)

.DEFAULT_GOAL := help

.PHONY: help version add-change release changelog

help:
	@echo "ai-footprint release tooling (semversioner)"
	@echo ""
	@echo "  make add-change BUMP=major|minor|patch MSG=\"...\"  record a changeset"
	@echo "  make release                                       bump, regen CHANGELOG, commit + tag"
	@echo "  make changelog                                     regenerate CHANGELOG.md"
	@echo "  make version                                       print current version ($(VERSION))"
	@echo ""
	@echo "Current version: $(VERSION)"

version:
	@echo $(VERSION)

# --- add-change -------------------------------------------------------------
add-change:
	@command -v semversioner >/dev/null || { echo "error: semversioner not found — pip install semversioner"; exit 1; }
	@if [ -z "$(MSG)" ]; then echo 'error: MSG="..." is required'; exit 1; fi
	@case "$(BUMP)" in major|minor|patch) ;; *) echo "error: BUMP must be major|minor|patch"; exit 1;; esac
	semversioner add-change --type $(BUMP) --description "$(MSG)"

# --- changelog --------------------------------------------------------------
changelog:
	@command -v semversioner >/dev/null || { echo "error: semversioner not found — pip install semversioner"; exit 1; }
	semversioner changelog --template $(TEMPLATE) > $(CHANGELOG)
	@echo "regenerated $(CHANGELOG)"

# --- release ----------------------------------------------------------------
release:
	@command -v semversioner >/dev/null || { echo "error: semversioner not found — pip install semversioner"; exit 1; }
	@command -v jq >/dev/null || { echo "error: jq not found"; exit 1; }
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: working tree is dirty — commit or stash before releasing"; exit 1; fi
	@if [ -z "$$(ls -A .semversioner/next-release 2>/dev/null)" ]; then \
		echo "error: no pending changesets — run 'make add-change' first"; exit 1; fi
	semversioner release
	@new="$$(semversioner current-version)"; today="$$(date +%F)"; \
	echo "releasing -> $$new"; \
	jq --arg v "$$new" '.version = $$v' $(PLUGIN_JSON) > $(PLUGIN_JSON).tmp && mv $(PLUGIN_JSON).tmp $(PLUGIN_JSON); \
	jq --arg v "$$new" '.plugins[0].version = $$v' $(MARKET_JSON) > $(MARKET_JSON).tmp && mv $(MARKET_JSON).tmp $(MARKET_JSON); \
	semversioner changelog --template $(TEMPLATE) > $(CHANGELOG); \
	perl -pi -e "s|/badge/release-v[0-9.]+(-blue)|/badge/release-v$$new-blue|" README.md; \
	git add .semversioner $(PLUGIN_JSON) $(MARKET_JSON) $(CHANGELOG) README.md; \
	git commit -m "release: v$$new"; \
	git tag -a "v$$new" -m "v$$new"; \
	echo ""; \
	echo "tagged v$$new"
