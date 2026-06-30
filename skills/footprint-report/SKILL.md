---
name: footprint-report
description: Launch an interactive web dashboard showing CO2, water, cost and token footprint across all AI coding agents — explorable by project, agent, provider, model, month, and daily timeline. Opens a browser at http://localhost:7331.
---

Run the following bash script exactly as written and present the output to the user. Do not paraphrase or reformat the results.

```bash
#!/usr/bin/env bash
export LC_ALL=C

PORT=7331

# Resolve the repo root relative to this skill file, falling back to ~/code/ai-footprint
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." 2>/dev/null && pwd)"
SCRIPT="${REPO_ROOT}/scripts/serve-report.py"

# Fallback for legacy installs
if [ ! -f "$SCRIPT" ]; then
  SCRIPT="${HOME}/code/ai-footprint/scripts/serve-report.py"
fi

if [ ! -f "$SCRIPT" ]; then
  echo "Server script not found. Re-run the installer or set AI_FOOTPRINT_DIR."
  exit 1
fi

# Kill any existing instance on this port
pkill -f "serve-report.py" 2>/dev/null || true
sleep 0.3

# Start server in background (opens browser automatically)
python3 "$SCRIPT" --port "$PORT" &
SERVER_PID=$!

# Give it a moment to start
sleep 1.2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "Failed to start server — check that Python 3 is available."
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ai-footprint interactive report"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Open: http://localhost:${PORT}"
echo "  (the first load reads live from tokscale and may take ~20-60s)"
echo ""
echo "  Explore your footprint by:"
echo "    • Project  — per workspace/repo, with its top agent"
echo "    • Agent    — Claude Code, Codex, Cursor, Gemini CLI …"
echo "    • Provider — Anthropic, OpenAI, Google, xAI …"
echo "    • Model    — claude-opus-4-6, gpt-4o, gemini-2-flash …"
echo "    • Month    — monthly CO₂/water/cost/token totals"
echo "    • Timeline — daily breakdown with all metrics"
echo ""
echo "  Click any column header to sort."
echo "  Switch period: Today / This Year / All Time."
echo ""
echo "  Server PID: $SERVER_PID"
echo "  Stop with:  kill $SERVER_PID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```
