# Agent Instructions

Four rules for working in this repo.

## 1. Stop making silent assumptions

When you hit ambiguity, ask before assuming. Surface the tradeoffs explicitly instead of picking an interpretation and building on top of it. A wrong assumption made in line two becomes a debugging problem 200 lines later.

## 2. Stop over-engineering

Write the minimum code that solves the actual problem. No abstraction layers for single-use code. No clever patterns that make future maintenance harder. A config parser is a function, not a plugin architecture.

## 3. Stop causing collateral damage

Only touch files and functions directly related to the task. Don't reformat comments, rename variables, or adjust imports in files you weren't asked to change. If something adjacent looks wrong, flag it — don't silently fix it.

## 4. Stay honest about what you don't know

Say "I'm not sure" when you're not sure. Don't invent APIs, patterns, or library features. Flag uncertainty explicitly rather than producing confident output that's wrong.

## Working in this repo

This is a Claude Code plugin written in Bash (with a Python helper for the dashboard). There is no build step and no database — every report reads token usage live from [tokscale](https://github.com/junhoyeo/tokscale).

### Dependencies

- `jq`, `git`, `python3`, `node`/`npx` — required (`npx tokscale@latest` is the usage source)
- `playwright-core` — only for PNG cards (`/footprint-card`)

Scripts must stay **bash 3.2 compatible** (macOS default): no associative arrays, no `mapfile`.

### Commands

```bash
# Verify toolchain + print a one-shot footprint summary
bash scripts/setup.sh

# Run the methodology test suite (replays tests/methodology-vectors.json
# against the real CO2/water/cost math in scripts/lib-factors.sh)
bash tests/run-vectors.sh

# Live footprint dashboard at http://localhost:7331 (same as /footprint-report)
python3 scripts/serve-report.py            # --port N to override

# Generate PNG report cards into exports/ (same as /footprint-card)
bash scripts/generate-report.sh            # current year
bash scripts/generate-report.sh --since 2026-03-01
bash scripts/generate-report.sh --all

# Render the status line (reads statusline JSON on stdin)
echo '{"session_id":"..."}' | bash scripts/statusline.sh
```

### Key files

- `scripts/lib-factors.sh` — shared CO2/water math (`resolve_family`, `is_excluded`, `factor`, `compute_footprint`). The single source of truth; tests source it directly.
- `scripts/footprint-data.sh` / `footprint-live.sh` — pull usage from tokscale and apply the factors.
- `data/factors.json` — CO2/water emission factors. `data/prices.json` — Claude per-Mtok prices for live session cost.
- `METHODOLOGY.md` — where the factors come from and how they're applied.

### Releases

Versioning is [semversioner](https://pypi.org/project/semversioner/)-backed via the `Makefile`:

```bash
make add-change BUMP=minor MSG="..."   # record a changeset
make release                           # bump, regen CHANGELOG, commit + tag
make version                           # print current version
```
