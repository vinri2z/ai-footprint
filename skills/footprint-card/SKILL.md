---
name: footprint-card
description: Generate shareable PNG report cards of your AI coding agents' carbon + water footprint
---

Run the following bash command and present the output to the user. Show the exported file paths so they can share the PNGs.

```bash
#!/usr/bin/env bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." 2>/dev/null && pwd)"
SCRIPT="${REPO_ROOT}/scripts/generate-report.sh"
if [ ! -f "$SCRIPT" ]; then
  SCRIPT="${HOME}/code/ai-footprint/scripts/generate-report.sh"
fi
if [ ! -f "$SCRIPT" ]; then
  echo "Script not found. Re-run the installer or set AI_FOOTPRINT_DIR."
  exit 1
fi
bash "$SCRIPT"
```

After the script completes, tell the user where the PNGs were exported (in `${REPO_ROOT}/exports/`).
