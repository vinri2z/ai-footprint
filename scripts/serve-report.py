#!/usr/bin/env python3
"""
serve-report.py — Interactive footprint dashboard for ai-footprint.
Starts a local HTTP server with an explorable breakdown by agent, provider,
model, and daily timeline.  Matches the card design (beige, Clash Display,
Owner Text, same colour palette).

Data comes live from tokscale via scripts/footprint-data.sh — there is no
database; every launch queries tokscale directly.
"""

import argparse
import json
import subprocess
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

DATA_SCRIPT = Path(__file__).resolve().parent / "footprint-data.sh"
DEFAULT_PORT = 7331

# ---------------------------------------------------------------------------
# HTML page — design tokens mirrored from report-summary.html / report-detailed.html
# ---------------------------------------------------------------------------

HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ai footprint</title>
  <link href="https://api.fontshare.com/v2/css?f[]=clash-display@400,500,600,700&display=swap" rel="stylesheet">
  <link href="https://api.fontshare.com/v2/css?f[]=owner-text@400,500,600&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg:      #faf8f5;
      --text:    #1d1d1f;
      --muted:   #7a6e63;
      --accent:  #f55c0f;
      --border:  rgba(29,29,31,0.08);
      --track:   rgba(29,29,31,0.04);
      --bar:     #7a6e63;
    }
    *, *::before, *::after { margin:0; padding:0; box-sizing:border-box; }

    body {
      background: var(--bg);
      color: var(--text);
      font-family: "Owner Text", -apple-system, sans-serif;
      font-size: 15px;
      line-height: 1.5;
      min-height: 100vh;
    }

    /* ── Layout ─────────────────────────────────────────────────────────── */
    .page { max-width: 1120px; margin: 0 auto; padding: 52px 48px 64px; }

    /* ── Header ─────────────────────────────────────────────────────────── */
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 44px;
    }
    .logo {
      font-family: "Clash Display", sans-serif;
      font-weight: 600;
      font-size: 20px;
      letter-spacing: -0.5px;
      color: var(--text);
    }
    .logo span { color: var(--muted); font-weight: 400; }
    .header-right { display: flex; align-items: center; gap: 18px; }
    .datestamp { font-size: 14px; color: var(--muted); }

    /* ── Period selector ─────────────────────────────────────────────────── */
    .period-sel {
      display: flex;
      gap: 3px;
      background: var(--track);
      border-radius: 7px;
      padding: 3px;
    }
    .period-btn {
      font-family: "Clash Display", sans-serif;
      font-weight: 500;
      font-size: 13px;
      padding: 5px 15px;
      border: none;
      background: transparent;
      color: var(--muted);
      border-radius: 5px;
      cursor: pointer;
      transition: background 0.12s, color 0.12s, box-shadow 0.12s;
    }
    .period-btn.active {
      background: var(--bg);
      color: var(--text);
      box-shadow: 0 1px 4px rgba(29,29,31,0.10);
    }

    /* ── Hero strip ──────────────────────────────────────────────────────── */
    .hero {
      display: grid;
      grid-template-columns: 2fr 1fr 1fr 1fr 1fr;
      border: 1px solid var(--border);
      border-radius: 10px;
      overflow: hidden;
      margin-bottom: 28px;
    }
    .hero-main {
      padding: 32px 32px 28px;
      border-right: 1px solid var(--border);
    }
    .hero-context {
      font-size: 12px;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: 0.6px;
      margin-bottom: 10px;
    }
    .hero-number {
      font-family: "Clash Display", sans-serif;
      font-weight: 700;
      font-size: 68px;
      line-height: 1;
      letter-spacing: -3px;
      color: var(--text);
    }
    .hero-unit {
      font-family: "Clash Display", sans-serif;
      font-weight: 400;
      font-size: 16px;
      color: var(--muted);
      margin-top: 6px;
    }
    .hero-tile {
      padding: 24px 20px;
      border-right: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      justify-content: center;
    }
    .hero-tile:last-child { border-right: none; }
    .tile-val {
      font-family: "Clash Display", sans-serif;
      font-weight: 700;
      font-size: 26px;
      letter-spacing: -1px;
      color: var(--text);
      line-height: 1.1;
    }
    .tile-label { font-size: 12px; color: var(--muted); margin-top: 5px; }

    /* ── Monthly chart ───────────────────────────────────────────────────── */
    .section { margin-bottom: 28px; }
    .section-title {
      font-size: 13px;
      color: var(--muted);
      font-style: italic;
      margin-bottom: 14px;
    }
    .bar-row {
      display: flex;
      align-items: center;
      margin-bottom: 7px;
    }
    .bar-lbl {
      font-family: "Clash Display", sans-serif;
      font-weight: 500;
      font-size: 12px;
      color: var(--muted);
      width: 52px;
      flex-shrink: 0;
    }
    .bar-track {
      flex: 1;
      height: 18px;
      background: var(--track);
      border-radius: 3px;
      overflow: hidden;
      margin: 0 12px;
    }
    .bar-fill {
      height: 100%;
      background: var(--bar);
      border-radius: 3px;
      min-width: 3px;
    }
    .bar-val {
      font-family: "Clash Display", sans-serif;
      font-weight: 600;
      font-size: 12px;
      color: var(--text);
      width: 72px;
      text-align: right;
      flex-shrink: 0;
    }

    /* ── Equivalences ────────────────────────────────────────────────────── */
    .equiv-strip {
      display: flex;
      border: 1px solid var(--border);
      border-radius: 10px;
      overflow: hidden;
      margin-bottom: 36px;
    }
    .equiv-tile {
      flex: 1;
      padding: 16px 18px;
      border-right: 1px solid var(--border);
    }
    .equiv-tile:last-child { border-right: none; }
    .equiv-val {
      font-family: "Clash Display", sans-serif;
      font-weight: 700;
      font-size: 20px;
      letter-spacing: -0.5px;
      color: var(--text);
    }
    .equiv-lbl { font-size: 11px; color: var(--muted); margin-top: 4px; }

    /* ── Tab navigation ──────────────────────────────────────────────────── */
    .tab-nav {
      display: flex;
      border-bottom: 1px solid var(--border);
      margin-bottom: 0;
    }
    .tab-btn {
      font-family: "Clash Display", sans-serif;
      font-weight: 500;
      font-size: 14px;
      padding: 11px 20px;
      border: none;
      background: none;
      color: var(--muted);
      cursor: pointer;
      border-bottom: 2px solid transparent;
      margin-bottom: -1px;
      transition: color 0.12s, border-color 0.12s;
    }
    .tab-btn.active { color: var(--text); border-bottom-color: var(--text); }
    .tab-pane { display: none; }
    .tab-pane.active { display: block; }

    /* ── Tables ──────────────────────────────────────────────────────────── */
    .tbl-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    thead th {
      text-align: left;
      padding: 13px 14px;
      font-family: "Clash Display", sans-serif;
      font-weight: 500;
      font-size: 11px;
      color: var(--muted);
      border-bottom: 1px solid var(--border);
      cursor: pointer;
      user-select: none;
      white-space: nowrap;
    }
    thead th:hover { color: var(--text); }
    thead th.s-asc::after  { content: " ↑"; color: var(--accent); font-size: 10px; }
    thead th.s-desc::after { content: " ↓"; color: var(--accent); font-size: 10px; }
    thead th.r { text-align: right; }
    tbody tr { border-bottom: 1px solid var(--border); }
    tbody tr:last-child { border-bottom: none; }
    tbody tr:hover { background: var(--track); }
    tbody td { padding: 11px 14px; }
    tbody td.r {
      text-align: right;
      font-family: "Clash Display", sans-serif;
      font-weight: 500;
      font-size: 13px;
    }
    tbody td.dim { color: var(--muted); font-size: 13px; }
    .name-cell { font-weight: 500; }
    .family-tag {
      display: inline-block;
      font-size: 11px;
      color: var(--muted);
      background: var(--track);
      padding: 2px 7px;
      border-radius: 3px;
      margin-left: 8px;
      vertical-align: middle;
      font-family: "Clash Display", sans-serif;
    }

    /* Mini CO₂ bar inside table */
    .co2-cell { min-width: 180px; }
    .co2-wrap { display: flex; align-items: center; gap: 9px; }
    .mini-track {
      flex: 1;
      height: 5px;
      background: var(--track);
      border-radius: 2px;
      overflow: hidden;
    }
    .mini-fill { height: 100%; background: var(--bar); border-radius: 2px; }
    .co2-txt {
      font-family: "Clash Display", sans-serif;
      font-weight: 600;
      font-size: 13px;
      white-space: nowrap;
    }

    /* ── Footer ──────────────────────────────────────────────────────────── */
    .footer {
      margin-top: 52px;
      padding-top: 20px;
      border-top: 1px solid var(--border);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .footer-logo {
      font-family: "Clash Display", sans-serif;
      font-weight: 600;
      font-size: 15px;
    }
    .footer-logo span { color: var(--muted); font-weight: 400; }
    .footer-link { font-family: "Clash Display", sans-serif; font-size: 13px; color: var(--accent); }
    .footer-badge {
      font-size: 12px;
      color: var(--muted);
      background: var(--track);
      padding: 5px 13px;
      border-radius: 4px;
    }

    /* ── Responsive ──────────────────────────────────────────────────────── */
    @media (max-width: 860px) {
      .page { padding: 32px 20px 48px; }
      .hero { grid-template-columns: 1fr 1fr; }
      .hero-main { grid-column: 1 / -1; border-right: none; border-bottom: 1px solid var(--border); }
      .hero-tile { border-right: none; border-bottom: 1px solid var(--border); }
      .equiv-strip { flex-wrap: wrap; }
      .equiv-tile { min-width: 45%; }
    }
  </style>
</head>
<body>
<div class="page">

  <!-- ── Header ───────────────────────────────────────────────────────── -->
  <div class="header">
    <div class="logo">ai <span>footprint</span></div>
    <div class="header-right">
      <div class="datestamp" id="js-date"></div>
      <div class="period-sel">
        <button class="period-btn" data-p="today">Today</button>
        <button class="period-btn" data-p="year">This Year</button>
        <button class="period-btn active" data-p="all">All Time</button>
      </div>
    </div>
  </div>

  <!-- ── Hero strip ───────────────────────────────────────────────────── -->
  <div class="hero">
    <div class="hero-main">
      <div class="hero-context">AI coding footprint</div>
      <div class="hero-number" id="h-co2-val">–</div>
      <div class="hero-unit" id="h-co2-unit">of estimated CO₂</div>
    </div>
    <div class="hero-tile">
      <div class="tile-val" id="h-water">–</div>
      <div class="tile-label">estimated water</div>
    </div>
    <div class="hero-tile">
      <div class="tile-val" id="h-cost">–</div>
      <div class="tile-label">API cost</div>
    </div>
    <div class="hero-tile">
      <div class="tile-val" id="h-tokens">–</div>
      <div class="tile-label">tokens</div>
    </div>
    <div class="hero-tile">
      <div class="tile-val" id="h-agents">–</div>
      <div class="tile-label" id="h-agents-lbl">agents · models</div>
    </div>
  </div>

  <!-- ── Monthly chart ────────────────────────────────────────────────── -->
  <div class="section">
    <div class="section-title">monthly CO₂ breakdown</div>
    <div id="chart"></div>
  </div>

  <!-- ── Equivalences ─────────────────────────────────────────────────── -->
  <div class="equiv-strip">
    <div class="equiv-tile">
      <div class="equiv-val" id="eq-car">–</div>
      <div class="equiv-lbl">km by car (120 gCO₂/km)</div>
    </div>
    <div class="equiv-tile">
      <div class="equiv-val" id="eq-tgv">–</div>
      <div class="equiv-lbl">km by TGV (2.4 gCO₂/km)</div>
    </div>
    <div class="equiv-tile">
      <div class="equiv-val" id="eq-google">–</div>
      <div class="equiv-lbl">Google searches (0.2 gCO₂)</div>
    </div>
    <div class="equiv-tile">
      <div class="equiv-val" id="eq-bottles">–</div>
      <div class="equiv-lbl">water bottles (0.5 L)</div>
    </div>
    <div class="equiv-tile">
      <div class="equiv-val" id="eq-showers">–</div>
      <div class="equiv-lbl">showers (65 L)</div>
    </div>
  </div>

  <!-- ── Tabs ─────────────────────────────────────────────────────────── -->
  <div class="tab-nav">
    <button class="tab-btn active" data-tab="projects">By Project</button>
    <button class="tab-btn" data-tab="agents">By Agent</button>
    <button class="tab-btn" data-tab="providers">By Provider</button>
    <button class="tab-btn" data-tab="models">By Model</button>
    <button class="tab-btn" data-tab="months">By Month</button>
    <button class="tab-btn" data-tab="daily">Daily Timeline</button>
  </div>

  <!-- By Project -->
  <div class="tab-pane active" id="pane-projects">
    <div class="tbl-wrap">
      <table id="tbl-projects">
        <thead><tr>
          <th data-col="project">Project</th>
          <th data-col="co2" class="r s-desc">CO₂</th>
          <th data-col="water" class="r">Water</th>
          <th data-col="cost" class="r">Cost</th>
          <th data-col="tokens" class="r">Tokens</th>
          <th data-col="top_agent">Top agent</th>
          <th data-col="agent_count" class="r">Agents</th>
          <th data-col="model_count" class="r">Models</th>
        </tr></thead>
        <tbody id="body-projects"></tbody>
      </table>
    </div>
  </div>

  <!-- By Agent -->
  <div class="tab-pane" id="pane-agents">
    <div class="tbl-wrap">
      <table id="tbl-agents">
        <thead><tr>
          <th data-col="client">Agent</th>
          <th data-col="co2" class="r s-desc">CO₂</th>
          <th data-col="water" class="r">Water</th>
          <th data-col="cost" class="r">Cost</th>
          <th data-col="tokens" class="r">Tokens</th>
          <th data-col="project_count" class="r">Projects</th>
          <th data-col="model_count" class="r">Models</th>
          <th data-col="first_date">First seen</th>
        </tr></thead>
        <tbody id="body-agents"></tbody>
      </table>
    </div>
  </div>

  <!-- By Provider -->
  <div class="tab-pane" id="pane-providers">
    <div class="tbl-wrap">
      <table id="tbl-providers">
        <thead><tr>
          <th data-col="provider">Provider</th>
          <th data-col="co2" class="r s-desc">CO₂</th>
          <th data-col="water" class="r">Water</th>
          <th data-col="cost" class="r">Cost</th>
          <th data-col="tokens" class="r">Tokens</th>
          <th data-col="model_count" class="r">Models</th>
          <th data-col="agent_count" class="r">Agents</th>
        </tr></thead>
        <tbody id="body-providers"></tbody>
      </table>
    </div>
  </div>

  <!-- By Model -->
  <div class="tab-pane" id="pane-models">
    <div class="tbl-wrap">
      <table id="tbl-models">
        <thead><tr>
          <th data-col="model">Model</th>
          <th data-col="provider">Provider</th>
          <th data-col="co2" class="r s-desc">CO₂</th>
          <th data-col="water" class="r">Water</th>
          <th data-col="cost" class="r">Cost</th>
          <th data-col="tokens" class="r">Tokens</th>
          <th data-col="agent_count" class="r">Agents</th>
        </tr></thead>
        <tbody id="body-models"></tbody>
      </table>
    </div>
  </div>

  <!-- By Month -->
  <div class="tab-pane" id="pane-months">
    <div class="tbl-wrap">
      <table id="tbl-months">
        <thead><tr>
          <th data-col="month" class="s-desc">Month</th>
          <th data-col="co2" class="r">CO₂</th>
          <th data-col="water" class="r">Water</th>
          <th data-col="cost" class="r">Cost</th>
          <th data-col="tokens" class="r">Tokens</th>
          <th data-col="project_count" class="r">Projects</th>
          <th data-col="agent_count" class="r">Agents</th>
          <th data-col="model_count" class="r">Models</th>
        </tr></thead>
        <tbody id="body-months"></tbody>
      </table>
    </div>
  </div>

  <!-- Daily Timeline -->
  <div class="tab-pane" id="pane-daily">
    <div class="tbl-wrap">
      <table id="tbl-daily">
        <thead><tr>
          <th data-col="date" class="s-desc">Date</th>
          <th data-col="co2" class="r">CO₂</th>
          <th data-col="water" class="r">Water</th>
          <th data-col="cost" class="r">Cost</th>
          <th data-col="tokens" class="r">Tokens</th>
          <th data-col="agent_count" class="r">Agents</th>
        </tr></thead>
        <tbody id="body-daily"></tbody>
      </table>
    </div>
  </div>

  <!-- ── Footer ───────────────────────────────────────────────────────── -->
  <div class="footer">
    <div class="footer-logo">ai <span>footprint</span></div>
    <span class="footer-link">github.com/datamaraneers/ai-footprint</span>
    <span class="footer-badge">open source</span>
  </div>

</div><!-- .page -->
<script>
// ── Injected data ──────────────────────────────────────────────────────────
const D = __DATA__;

// ── Formatting helpers ─────────────────────────────────────────────────────
function co2Str(g) {
  if (g == null) return '–';
  if (g >= 1e6)  return (g/1e6).toFixed(2) + ' tCO₂';
  if (g >= 1e3)  return (g/1e3).toFixed(2) + ' kg';
  return g.toFixed(1) + ' g';
}
function co2Hero(g) {
  if (g == null || g === 0) return { val:'0', unit:'g of estimated CO₂' };
  if (g >= 1e6) return { val:(g/1e6).toFixed(2), unit:'tCO₂ of estimated CO₂' };
  if (g >= 1e3) return { val:(g/1e3).toFixed(2), unit:'kg of estimated CO₂' };
  return { val:g.toFixed(1), unit:'g of estimated CO₂' };
}
function waterStr(l) {
  if (l == null) return '–';
  if (l >= 1e3)  return (l/1e3).toFixed(2) + ' kL';
  if (l >= 1)    return l.toFixed(2) + ' L';
  return (l*1e3).toFixed(0) + ' mL';
}
function costStr(u) {
  if (u == null) return '–';
  if (u >= 1e3)  return '$' + (u/1e3).toFixed(1) + 'k';
  return '$' + u.toFixed(2);
}
function tokStr(n) {
  if (n == null) return '–';
  if (n >= 1e9) return (n/1e9).toFixed(1) + 'B';
  if (n >= 1e6) return (n/1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n/1e3).toFixed(0) + 'K';
  return String(n);
}
function numFmt(n, dec=0) {
  if (n == null) return '–';
  return n.toLocaleString('en', { maximumFractionDigits: dec });
}

// ── Period selector ────────────────────────────────────────────────────────
let period = 'all';

document.querySelectorAll('.period-btn').forEach(b => {
  b.addEventListener('click', () => {
    document.querySelectorAll('.period-btn').forEach(x => x.classList.remove('active'));
    b.classList.add('active');
    period = b.dataset.p;
    refreshHero();
    refreshEquiv();
  });
});

function pd() { return D[period] || {}; }

function refreshHero() {
  const d = pd();
  const co2 = d.co2 || 0;
  const { val, unit } = co2Hero(co2);
  document.getElementById('h-co2-val').textContent  = val;
  document.getElementById('h-co2-unit').textContent = unit;
  document.getElementById('h-water').textContent    = waterStr(d.water || 0);
  document.getElementById('h-cost').textContent     = costStr(d.cost || 0);
  document.getElementById('h-tokens').textContent   = tokStr(d.tokens || 0);
  document.getElementById('h-agents').textContent   = (d.agents || 0) + ' · ' + (d.models || 0);
}

function refreshEquiv() {
  const d = pd();
  const co2 = d.co2 || 0, water = d.water || 0;
  document.getElementById('eq-car').textContent     = numFmt(co2 / 120);
  document.getElementById('eq-tgv').textContent     = numFmt(co2 / 2.4);
  document.getElementById('eq-google').textContent  = numFmt(co2 / 0.2);
  document.getElementById('eq-bottles').textContent = numFmt(water / 0.5);
  document.getElementById('eq-showers').textContent = (water / 65).toFixed(1);
}

// ── Monthly chart ──────────────────────────────────────────────────────────
function buildChart() {
  const months = D.by_month || [];
  const el = document.getElementById('chart');
  if (!months.length) { el.textContent = 'No data yet.'; return; }
  const maxCo2 = Math.max(...months.map(m => m.co2 || 0));
  el.innerHTML = months.map(m => {
    const pct = maxCo2 > 0 ? (m.co2 / maxCo2 * 100).toFixed(1) : 0;
    const d = new Date(m.month + '-02'); // +2 avoids UTC-offset day-1 issues
    const lbl = d.toLocaleString('en', { month:'short' }) + " '" + String(d.getFullYear()).slice(2);
    return '<div class="bar-row">'
      + '<div class="bar-lbl">' + lbl + '</div>'
      + '<div class="bar-track"><div class="bar-fill" style="width:' + pct + '%"></div></div>'
      + '<div class="bar-val">' + co2Str(m.co2) + '</div>'
      + '</div>';
  }).join('');
}

// ── Tab switching ──────────────────────────────────────────────────────────
document.querySelectorAll('.tab-btn').forEach(b => {
  b.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(x => x.classList.remove('active'));
    document.querySelectorAll('.tab-pane').forEach(x => x.classList.remove('active'));
    b.classList.add('active');
    document.getElementById('pane-' + b.dataset.tab).classList.add('active');
  });
});

// ── Generic sortable table ─────────────────────────────────────────────────
function makeTable(tblId, bodyId, rows, cols) {
  const tbl  = document.getElementById(tblId);
  const body = document.getElementById(bodyId);
  const defaultSortCol = cols.find(c => c.defaultSort);
  let sortCol = defaultSortCol ? defaultSortCol.key : (cols[1] && cols[1].key);
  let sortDir = defaultSortCol && defaultSortCol.asc ? 1 : -1;

  function render() {
    const sorted = [...rows].sort((a, b) => {
      const av = a[sortCol], bv = b[sortCol];
      if (av == null) return 1;
      if (bv == null) return -1;
      return sortDir * (typeof av === 'string' ? av.localeCompare(bv) : av - bv);
    });
    const maxCo2 = Math.max(1, ...rows.map(r => r.co2 || 0));

    body.innerHTML = '';
    sorted.forEach(row => {
      const tr = document.createElement('tr');
      tr.innerHTML = cols.map(col => {
        const v = row[col.key];
        if (col.key === 'co2') {
          const pct = (((v || 0) / maxCo2) * 100).toFixed(1);
          return '<td class="co2-cell">'
            + '<div class="co2-wrap">'
            + '<div class="mini-track"><div class="mini-fill" style="width:' + pct + '%"></div></div>'
            + '<span class="co2-txt">' + co2Str(v) + '</span>'
            + '</div></td>';
        }
        const cls = (col.r ? 'r' : '') + (col.dim ? ' dim' : '');
        const html = col.render ? col.render(v, row) : (v == null ? '–' : String(v));
        return '<td' + (cls ? ' class="' + cls.trim() + '"' : '') + '>' + html + '</td>';
      }).join('');
      body.appendChild(tr);
    });

    tbl.querySelectorAll('th').forEach(th => th.classList.remove('s-asc', 's-desc'));
    const hdr = tbl.querySelector('th[data-col="' + sortCol + '"]');
    if (hdr) hdr.classList.add(sortDir === -1 ? 's-desc' : 's-asc');
  }

  tbl.querySelectorAll('th[data-col]').forEach(th => {
    th.addEventListener('click', () => {
      const col = th.dataset.col;
      if (sortCol === col) sortDir *= -1;
      else { sortCol = col; sortDir = -1; }
      render();
    });
  });

  render();
}

// ── Boot ───────────────────────────────────────────────────────────────────
document.getElementById('js-date').textContent = new Date().toLocaleDateString('en-US', {
  year:'numeric', month:'long', day:'numeric'
});

refreshHero();
refreshEquiv();
buildChart();

function monthLabel(m) {
  const d = new Date(m + '-02'); // +2 avoids UTC-offset day-1 issues
  return d.toLocaleString('en', { month:'short' }) + " '" + String(d.getFullYear()).slice(2);
}

makeTable('tbl-projects', 'body-projects', D.by_project || [], [
  { key:'project',     render:(v) => '<span class="name-cell">' + (v||'–') + '</span>' },
  { key:'co2' },
  { key:'water',       r:true, render:(v) => waterStr(v) },
  { key:'cost',        r:true, render:(v) => costStr(v) },
  { key:'tokens',      r:true, render:(v) => tokStr(v) },
  { key:'top_agent',   dim:true },
  { key:'agent_count', r:true, dim:true },
  { key:'model_count', r:true, dim:true },
]);

makeTable('tbl-agents', 'body-agents', D.by_agent || [], [
  { key:'client',        render:(v) => '<span class="name-cell">' + (v||'–') + '</span>' },
  { key:'co2' },
  { key:'water',         r:true, render:(v) => waterStr(v) },
  { key:'cost',          r:true, render:(v) => costStr(v) },
  { key:'tokens',        r:true, render:(v) => tokStr(v) },
  { key:'project_count', r:true, dim:true },
  { key:'model_count',   r:true, dim:true },
  { key:'first_date',    dim:true },
]);

makeTable('tbl-providers', 'body-providers', D.by_provider || [], [
  { key:'provider',    render:(v) => '<span class="name-cell">' + (v||'–') + '</span>' },
  { key:'co2' },
  { key:'water',       r:true, render:(v) => waterStr(v) },
  { key:'cost',        r:true, render:(v) => costStr(v) },
  { key:'tokens',      r:true, render:(v) => tokStr(v) },
  { key:'model_count', r:true, dim:true },
  { key:'agent_count', r:true, dim:true },
]);

makeTable('tbl-models', 'body-models', D.by_model || [], [
  { key:'model',
    render:(v,row) => '<span class="name-cell">' + (v||'–') + '</span>'
      + (row.family ? '<span class="family-tag">' + row.family + '</span>' : '') },
  { key:'provider', dim:true },
  { key:'co2' },
  { key:'water',       r:true, render:(v) => waterStr(v) },
  { key:'cost',        r:true, render:(v) => costStr(v) },
  { key:'tokens',      r:true, render:(v) => tokStr(v) },
  { key:'agent_count', r:true, dim:true },
]);

makeTable('tbl-months', 'body-months', D.by_month || [], [
  { key:'month',         defaultSort:true, render:(v) => '<span class="name-cell">' + monthLabel(v) + '</span>' },
  { key:'co2' },
  { key:'water',         r:true, render:(v) => waterStr(v) },
  { key:'cost',          r:true, render:(v) => costStr(v) },
  { key:'tokens',        r:true, render:(v) => tokStr(v) },
  { key:'project_count', r:true, dim:true },
  { key:'agent_count',   r:true, dim:true },
  { key:'model_count',   r:true, dim:true },
]);

makeTable('tbl-daily', 'body-daily', D.by_day || [], [
  { key:'date',        defaultSort:true, dim:true },
  { key:'co2' },
  { key:'water',       r:true, render:(v) => waterStr(v) },
  { key:'cost',        r:true, render:(v) => costStr(v) },
  { key:'tokens',      r:true, render:(v) => tokStr(v) },
  { key:'agent_count', r:true, dim:true },
]);
</script>
</body>
</html>
"""

# ---------------------------------------------------------------------------
# Data source — live from tokscale via footprint-data.sh (no database)
# ---------------------------------------------------------------------------

def query_tokscale(data_script: str) -> dict:
    """Run footprint-data.sh and return its aggregated JSON document."""
    proc = subprocess.run(
        ["bash", data_script, "--all"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise RuntimeError(f"footprint-data.sh exited {proc.returncode}")
    if not proc.stdout.strip():
        raise RuntimeError("footprint-data.sh produced no output — is tokscale available?")
    return json.loads(proc.stdout)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    page_bytes: bytes = b""

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type",   "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(self.page_bytes)))
            self.end_headers()
            self.wfile.write(self.page_bytes)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):  # silence access log
        pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Interactive ai-footprint report server")
    ap.add_argument("--port",       type=int, default=DEFAULT_PORT, help="TCP port (default 7331)")
    ap.add_argument("--data-script", default=str(DATA_SCRIPT),       help="Path to footprint-data.sh")
    ap.add_argument("--no-browser", action="store_true",            help="Don't open browser automatically")
    args = ap.parse_args()

    script = Path(args.data_script)
    if not script.exists():
        print(f"error: data script not found at {script}", file=sys.stderr)
        sys.exit(1)

    print("Loading data from tokscale … (this can take a moment)", flush=True)
    try:
        data = query_tokscale(str(script))
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    page = HTML.replace("__DATA__", json.dumps(data, ensure_ascii=False))
    Handler.page_bytes = page.encode("utf-8")

    url = f"http://localhost:{args.port}"
    server = HTTPServer(("", args.port), Handler)
    print(f"Footprint dashboard → {url}", flush=True)
    print("Press Ctrl+C to stop.", flush=True)

    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
