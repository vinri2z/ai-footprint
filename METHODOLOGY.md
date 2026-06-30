# Methodology

## Overview

Emissions are estimated from token counts using per-token factors derived from peer-reviewed research. The approach is intentionally simple: one number per model family per token direction. No real-time data, no per-request tracing.

Token usage is collected across **all** local AI coding agents — not just Claude Code — via [tokscale](https://github.com/junhoyeo/tokscale) (see Token usage source below), so the footprint covers Codex, Cursor, Gemini CLI, Copilot, OpenCode, and 30+ other clients alongside Claude Code.

## Token usage source

[tokscale](https://github.com/junhoyeo/tokscale) scans the local session stores of 30+ AI coding agents and reports per-`(client, provider, model)` token counts (`input`, `output`, `cacheRead`, `cacheWrite`, `reasoning`) plus an estimated `cost`. `scripts/footprint-data.sh` queries it directly at report time (`tokscale models --json --group-by client,provider,model --since … --until …`), maps each model to a family (below), computes CO2 + water with the formula below, and prints an aggregated JSON document that the report consumers render. Computed per-bucket rows are cached in a local SQLite DB so only live buckets (current month, recent days) are re-queried; the cache self-invalidates when the tokscale agent set or the factors change, so the numbers stay current. `reasoning` tokens are folded into output (they are generated tokens). `cost` is taken straight from tokscale (multi-provider), not recomputed.

Because tokscale's `models` report cannot group by date, the time-series views are built by looping tokscale over time buckets: a month loop (earliest month with data → today) backs the all-time/year totals and the by-agent/by-provider/by-model/by-month aggregates, and a day loop over a trailing window (default 35 days) backs the daily timeline and "today".

## Source

Jegham et al. (2025), "Measuring the Carbon Footprint of AI Inference"
[arxiv.org/abs/2505.09598](https://arxiv.org/abs/2505.09598)

The paper measures inference energy consumption on AWS infrastructure for a range of models, then converts to CO2e using grid-average carbon intensity.

## Formula

```
session_co2_grams = (
    (input_tokens + cache_write_tokens) * input_factor
  + cache_read_tokens * (input_factor * cache_read_factor)
  + output_tokens * output_factor
) / 1_000_000
```

Factors are in gCO2e per million tokens. `cache_write_tokens` (`cache_creation_input_tokens`) are a full prefill, so they count at the input factor. `cache_read_tokens` count at a reduced `cache_read_factor` (default 0.08) of the input factor (see Cache read energy below).

## Infrastructure parameters

| Parameter | Value            | Description                                      |
| --------- | ---------------- | ------------------------------------------------ |
| PUE       | 1.14             | AWS datacenter power usage effectiveness         |
| CIF       | 0.287 kgCO2e/kWh | Carbon intensity factor (US grid average)        |
| WUE       | 0.18 L/kWh       | Onsite water usage effectiveness (used in water calc) |
| EWIF      | 3.14 L/kWh       | Offsite electricity-generation water intensity (used in water calc) |

## Per-model factors (gCO2e per million tokens)

| Model family | Input | Output | Source                     |
| ------------ | ----- | ------ | -------------------------- |
| Fable        | 1000  | 6000   | Extrapolated (2x Opus)     |
| Opus         | 500   | 3000   | Extrapolated (3x Sonnet)   |
| Sonnet       | 190   | 1140   | Measured (Jegham et al.)   |
| Haiku        | 95    | 570    | Extrapolated (0.5x Sonnet) |
| frontier     | 500   | 3000   | Extrapolated, Opus-tier proxy (gpt-5, o-series, *-pro, grok-4, deepseek-r) |
| mid          | 190   | 1140   | Extrapolated, Sonnet-tier proxy (gpt-4 class, gemini, glm, kimi, qwen, llama, mistral) |
| small        | 95    | 570    | Extrapolated, Haiku-tier proxy (*-mini, *-nano, *-flash, *-lite, 7b/8b) |
| default      | 190   | 1140   | Extrapolated, Sonnet-tier fallback (any real model not matched above) |

### Family mapping (all agents)

Claude families are matched as before. Every other agent's model is mapped to a provider-agnostic tier — `frontier` (Opus-equivalent), `mid` (Sonnet-equivalent), `small` (Haiku-equivalent), or `default` (Sonnet-equivalent fallback) — by an ordered, case-insensitive `family_patterns` list in `data/factors.json`. The first matching pattern wins, and specific tiers (e.g. `*-mini` → small) are listed before generic ones (`gpt-5` → frontier), so `gpt-5-mini` resolves to small. The tiers are deliberately coarse: the only number that moves between them is the input factor (95 / 190 / 500), output is always 6x input, and water tracks CO2 — so a misclassification shifts the estimate by at most ~2.6x, well inside the order-of-magnitude accuracy of the whole method. These non-Anthropic factors are **estimates** (no direct measurement); provenance is recorded per family in `factors.json` `_provenance`.

## Why input and output factors differ

Output tokens are ~6x more expensive than input tokens in terms of compute. During prefill (input processing), the model processes all input tokens in parallel. During decoding (output generation), each token requires a full forward pass through the model sequentially. This autoregressive step dominates energy consumption.

## Why Fable, Opus and Haiku are extrapolated

The Jegham paper measured Sonnet-class models directly. The other families are estimated by scaling:

- Fable = 2x Opus (no published measurement for Fable 5 / Mythos 5; the list-price ratio, $10/$50 vs $5/$25, is used as a compute proxy)
- Opus = 3x Sonnet (larger model, roughly proportional parameter count)
- Haiku = 0.5x Sonnet (smaller model, lighter compute)

These are order-of-magnitude estimates. Actual values depend on Anthropic's specific hardware configuration and batching strategies, which are not publicly available.

## Water footprint

Water is estimated from the same inference energy as CO2, using a water-intensity factor in place of the carbon-intensity factor. Both are `energy × intensity`, so per token the two are proportional:

```
session_water_liters = (
    (input_tokens + cache_write_tokens) * water_input_factor
  + cache_read_tokens * (water_input_factor * cache_read_factor)
  + output_tokens * water_output_factor
) / 1_000_000
```

Water factors are in liters per million tokens. The same `cache_read_factor` (0.08) applies, because water tracks energy.

### Water intensity (WIF)

Total water intensity is the sum of two components:

| Component | Value      | What it covers                                                        |
| --------- | ---------- | --------------------------------------------------------------------- |
| Onsite (WUE)  | 0.18 L/kWh | Water evaporated by datacenter cooling (AWS 2024 reported ~0.15, rounded up) |
| Offsite (EWIF)| 3.14 L/kWh | Water consumed generating the electricity (US-grid average)           |
| **Total (WIF)** | **3.32 L/kWh** | Onsite + offsite                                                  |

Per-model water factors are derived from the CO2 factors: `water_factor = co2_factor × WIF / CIF = co2_factor × 3.32 / 287 ≈ co2_factor × 0.0115679 L/gCO2e`.

| Model family | Input (L/Mtok) | Output (L/Mtok) |
| ------------ | -------------- | --------------- |
| Fable        | 11.568         | 69.408          |
| Opus         | 5.784          | 34.704          |
| Sonnet       | 2.198          | 13.187          |
| Haiku        | 1.099          | 6.594           |

**Fable consumes twice the water of Opus** (11.568 / 69.408 vs 5.784 / 34.704 L/Mtok). Water tracks energy, so the same 2x extrapolation applied to its CO2 factors carries through: for identical token counts a Fable session's water footprint is double an Opus session's.

### Why this is a conservative (over-estimated) figure

The offsite EWIF uses the **US-grid average** (3.14 L/kWh, Reig et al./WRI), not the more water-efficient mix of the specific AWS regions Anthropic runs in. Applying both the onsite WUE and the offsite EWIF to the full facility-level energy (which already includes PUE) over-applies the onsite term slightly. Both choices push the estimate up on purpose: the headline water number is meant to be an upper bound, not a best guess.

Sources: AWS 2024 sustainability report (onsite WUE); Li et al. 2023, "Making AI Less Thirsty" ([arXiv:2304.03271](https://arxiv.org/abs/2304.03271)); Reig et al./WRI (US EWIF 3.14); EESI.

## Excluded models

Unlike the Claude-only era, non-Anthropic models are **no longer excluded** — they map to a provider-agnostic tier and receive an estimate (see Family mapping). Only entries that represent no real inference are excluded: the `<synthetic>` marker (non-billed synthetic turns) and any user-added pattern in the `exclude_models` list in `data/factors.json`. Excluded entries contribute zero CO2/water and are left out of all report aggregates. Exclusion takes effect immediately on the next report run: edit `exclude_models` in `data/factors.json` — there is nothing to recompute because CO2/water are derived live from tokscale every time.

## Token counting and deduplication

Token counts come from tokscale, which reads each agent's native session store and is responsible for deduplication and per-model attribution across all 30+ clients (for Claude Code this replaces the previous bespoke JSONL `(message.id, requestId)` dedup). `footprint-data.sh` consumes tokscale's per-`(client, provider, model)` totals for each time bucket; `reasoning` tokens are added to `output`.

## Live data, no store

Reports recompute CO2/water from `data/factors.json` and cache the results per time bucket in a local SQLite DB. `data/factors.json` is part of the cache fingerprint, so editing a factor or the family mapping invalidates the cache and the next report recomputes from scratch — there is still nothing to migrate or hand-recompute. Sealed (past) buckets are otherwise read straight from the cache instead of re-querying tokscale.

The trade-off is retention. tokscale only sees what each agent keeps on disk, and agents purge their local session stores on their own schedules (Claude Code at ~30 days). Because nothing is snapshotted, usage older than an agent's retention window — and daily resolution older than the trailing day-window — is not reconstructable. Month-level totals remain available for as long as tokscale still reports that month. This is the deliberate consequence of reading tokscale directly rather than maintaining a separate store.

## Cache read energy

A `cache_read` token is a previously-processed context token whose key/value tensors are reused, so its prefill compute is skipped. It is not free in energy: during decode, every generated token re-reads the entire KV cache from HBM, including the cached tokens (GreenCache, SIGMETRICS: "caching does not reduce computation in the decode phase"). So the energy of a cached token is the decode-phase KV-read residual that survives caching.

No study directly measures the cache_read-to-input energy ratio. The default `cache_read_factor` of **0.08** (defensible range 0.05-0.15, hard bound 0-0.20) is an engineering estimate derived from adjacent measurements: prefill is ≤ 3.4% of total inference energy for generation workloads (Solovyeva & Castor), a larger KV cache amplifies per-token decode energy by 1.3-51.8%, and per-token energy rises ~3x from 2K to 10K context (TokenPowerBench, H100). The factor is workload-dependent and grows with context length; a flat constant understates very long reused prefixes.

This factor is **not** Anthropic's 0.1x cache_read billing ratio. That is a price, not an energy measurement (OpenAI prices the same mechanism at 0.5x). Setting `cache_read_factor` to 0 is a defensible lower bound but treats a reused 100K-token system prompt as carbon-free, which understates a real memory-bandwidth cost.

Sources: GreenCache (arXiv:2505.23970), TokenPowerBench (arXiv:2512.03024), Solovyeva & Castor (arXiv:2602.05712), From Prompts to Power (arXiv:2511.05597).

## Cost estimate

The reported cost is the estimated API list value of the usage (what it would cost on pay-as-you-go), not the subscription price actually paid. It is taken directly from tokscale, which maintains real-time per-provider pricing (LiteLLM with an OpenRouter fallback) across all clients, including cache read/write discounts. `data/prices.json` (Anthropic list pricing) is still used by the live status line (`statusline.sh`), which estimates the in-flight Claude Code session's cost before tokscale has seen it.

## Limitations

- Order of magnitude only. Do not use these numbers for regulatory reporting or lifecycle assessments.
- Inference only. Training costs and hardware manufacturing are not included. Cooling water (onsite) and electricity-generation water (offsite) ARE included in the water estimate, at order-of-magnitude accuracy.
- Cache read energy is a derived estimate, not a measurement (see Cache read energy below). Cache reads are 90%+ of tokens in Claude Code, so the chosen factor (default 0.08) is the single biggest lever on the headline number.
- Status line is approximate. Claude Code does not expose `cache_read_input_tokens` separately in the statusline hook JSON, and parsing JSONL incrementally at each turn would be too slow. The live display uses `context_window.total_input_tokens` (current context size, includes cache reads, no subagents). This is not used in reports.
- Grid-average, not real-time. The CIF is a static US grid average. Actual emissions depend on Anthropic's datacenter location, energy mix, and time of day.
- No multi-region awareness. AWS runs inference in multiple regions with different grid intensities.

## Equivalences used in reports

| Activity              | Emission factor | Source                                |
| --------------------- | --------------- | ------------------------------------- |
| Car                   | 120 gCO2e/km    | ADEME 2024 (thermal vehicle, average) |
| Google search         | 0.2 gCO2e       | Google Environmental Report 2023      |
| Email with attachment | 19 gCO2e        | ADEME 2024                            |
| TGV                   | 2.4 gCO2e/km    | SNCF 2023 Environmental Report        |

### Water equivalences

| Activity        | Water factor | Source                  |
| --------------- | ------------ | ----------------------- |
| Bottle of water | 0.5 L        | standard 50 cL bottle   |
| Shower (8 min)  | 65 L         | EPA (~2.1 gal/min)      |
