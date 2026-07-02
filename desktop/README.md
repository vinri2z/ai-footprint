# AI Footprint — macOS menu-bar app

A native menu-bar companion that runs the footprint dashboard in the background and
shows today's CO₂ at a glance. It's a thin AppKit shell — all computation stays in the
existing bash/python pipeline (`tokscale` → `lib-factors.sh` → `footprint-data.sh`),
which is bundled inside the app. The app never does the math itself.

## What it does

- Lives in the menu bar (no Dock icon, `LSUIElement`).
- Keeps `scripts/serve-report.py` resident and polls its `/api/data.json` every 60s.
- Menu-bar title shows today's CO₂ (e.g. `🍃 4.0kg`).
- Menu shows today / this-year / all-time CO₂, water and cost.
- **Open Dashboard** → the full interactive report at `http://localhost:7331`.
- **Start at Login** via `SMAppService` (macOS 13+).
- Reuses an already-running server (e.g. from `/footprint-report`) instead of spawning a duplicate.

## Runtime dependencies

Not bundled — supplied by the Homebrew cask's formula deps:

- `node` (for `npx tokscale@latest`, the usage source)
- `jq`
- `python3` and `git` ship with macOS Command Line Tools

## Build from source

```bash
bash desktop/build-app.sh          # → desktop/build/AI Footprint.app
bash desktop/build-app.sh --zip    # also produces AI-Footprint-<version>.zip for the cask
```

Requires the Xcode Command Line Tools (`swiftc`). The build bundles `scripts/` and
`data/` into `Contents/Resources` (as siblings, so `scripts/../data/factors.json`
resolves) and ad-hoc codesigns the bundle (needed for launch-at-login).

Run it directly without installing:

```bash
open "desktop/build/AI Footprint.app"
```

## Install via Homebrew

```bash
brew install --cask vinri2z/ai-footprint/ai-footprint
# or, from a local checkout:
brew install --cask ./Casks/ai-footprint.rb
```

The cask (`Casks/ai-footprint.rb`) points at a GitHub release zip. To cut a release:
`bash desktop/build-app.sh --zip`, upload the zip to the `v<version>` release, then
pin the cask's `sha256` to `shasum -a 256` of that zip.
