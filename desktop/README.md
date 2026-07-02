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
brew tap vinri2z/ai-footprint            # taps github.com/vinri2z/homebrew-ai-footprint
brew install --cask vinri2z/ai-footprint/ai-footprint
```

The app is ad-hoc signed, not notarized, so Gatekeeper quarantines it on download.
If macOS blocks it with "developer cannot be verified", right-click the app → **Open**
(once), or clear the quarantine flag:
`xattr -dr com.apple.quarantine "/Applications/AI Footprint.app"`.

> Homebrew cannot install a cask from a local `.rb` path — casks must come from a tap.
> For local testing without the tap, just build and run the app directly:
> `bash desktop/build-app.sh && open "desktop/build/AI Footprint.app"`.

### Cutting a release

The canonical cask lives in the tap repo (`vinri2z/homebrew-ai-footprint`);
`Casks/ai-footprint.rb` here is the maintained source that gets copied there.

1. `bash desktop/build-app.sh --zip` → `desktop/build/AI-Footprint-<version>.zip`
2. Upload that zip to the `v<version>` GitHub release.
3. Pin the cask's `sha256` to `shasum -a 256` of that exact zip.
4. Copy `Casks/ai-footprint.rb` into the tap repo and push.
