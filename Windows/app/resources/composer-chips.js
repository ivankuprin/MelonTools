/* Melon Tools — Codex composer chips.
 *
 * Injected into the Codex desktop app (ChatGPT.app, Electron) over the Chrome
 * DevTools Protocol. Renders account-pool chips inside the composer footer:
 *
 *   pool:      [Аккаунты N · 5 ч X% · Неделя Y%] [refresh]
 *   provider:  [OpenRouter ≈$0.09] [refresh]
 *
 * and a "Статус аккаунтов" / provider popover on click.
 *
 * Data flow (no network — the app CSP blocks localhost fetches):
 *   - Melon Tools pushes status with  __melonChipsSetStatus(json)  via
 *     Runtime.evaluate on every bridge tick.
 *   - The refresh button calls the __melonSend CDP binding; the bridge
 *     receives Runtime.bindingCalled and pushes fresh data back.
 *   - If no push arrives for 25 s the chips dim to an "offline" state.
 *
 * The script is idempotent: re-injecting disposes all previous instances via
 * window.__melonInstances and wipes stale DOM. React wipes the composer on
 * re-render, so a MutationObserver + interval re-attach the container.
 */
(() => {
  'use strict';

  const CFG = window.__MELON_COMPOSER_CONFIG__ || {};
  const LABELS = Object.assign({
    accounts: 'Аккаунты',
    fiveHour: '5 ч',
    week: 'Неделя',
    title: 'Статус аккаунтов',
    working: 'Рабочие',
    failed: 'Сбой',
    paused: 'Пауза',
    refresh: 'Обновить квоты',
    context: 'Контекст',
    session: 'Сессия',
    spent: 'Потрачено',
    remaining: 'Остаток',
    credits: 'Кредиты',
    key: 'Ключ',
    cached: 'Кеш',
    cacheShare: 'Кеш',
    input: 'Ввод',
    output: 'Вывод',
    reasoning: 'Размышления',
    turns: 'Ходы',
    workspace: 'Воркспейс',
    models: 'Модели',
    balance: 'Баланс',
    balanceUnavailable: 'Баланс недоступен через API провайдера.',
    freeTier: 'Бесплатный тир',
    providerData: 'Данные провайдера',
    sessionModel: 'Модель сессии',
    lastTurnModel: 'Модель последнего хода',
    keyRemaining: 'Остаток по ключу',
    updated: 'обновлено',
    noData: 'нет данных',
    tokens: 'Токены',
    of: 'из',
    yes: 'Да',
    no: 'Нет',
  }, CFG.labels || {});
  const PROVIDERS = Object.assign({ openai: 'OpenAI', opencode: 'OpenCode', openrouter: 'OpenRouter' }, CFG.providers || {});

  // ---------------------------------------------------------------- helpers

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function icon(paths, size) {
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('width', String(size || 14));
    svg.setAttribute('height', String(size || 14));
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '2');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    for (const d of paths) {
      const path = document.createElementNS(NS, 'path');
      path.setAttribute('d', d);
      svg.appendChild(path);
    }
    return svg;
  }

  function parseColor(value) {
    const match = String(value || '').match(/rgba?\(([^)]+)\)/);
    if (!match) return null;
    const parts = match[1].split(',').map((p) => parseFloat(p.trim()));
    if (parts.length < 3 || parts.some((n) => Number.isNaN(n))) return null;
    return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
  }

  function effectiveBackground(node) {
    let current = node;
    while (current && current !== document.documentElement) {
      const color = parseColor(getComputedStyle(current).backgroundColor);
      if (color && color.a > 0.3) return color;
      current = current.parentElement;
    }
    const body = parseColor(getComputedStyle(document.body).backgroundColor);
    return body && body.a > 0 ? body : { r: 24, g: 24, b: 26, a: 1 };
  }

  function luminance(color) {
    const channel = (v) => {
      const c = v / 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
  }

  function round(value) {
    return Math.round(Number(value) || 0);
  }

  function formatTokens(value) {
    const n = Number(value) || 0;
    if (n >= 1e9) return (n / 1e9).toFixed(1).replace('.', ',') + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(1).replace('.', ',') + 'M';
    if (n >= 1e3) return Math.round(n / 1e3) + 'K';
    return String(n);
  }

  function formatMoney(value) {
    const n = Number(value);
    if (!isFinite(n) || value == null) return '—';
    if (Math.abs(n) >= 1000) return '$' + Math.round(n);
    return '$' + n.toFixed(2).replace(/\.00$/, '');
  }

  function percent(part, whole) {
    const p = Number(part) || 0;
    const w = Number(whole) || 0;
    if (w <= 0) return null;
    return Math.round((p / w) * 100);
  }

  function timeOfDay(unixSeconds) {
    const n = Number(unixSeconds);
    if (!isFinite(n) || n <= 0) return null;
    const date = new Date(n * 1000);
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  // ---------------------------------------------------------------- state

  const state = {
    status: null,
    popover: null,
    popoverOpen: false,
    refreshBusy: false,
    refreshDeadline: 0,
    lastPushAt: Date.now(),
    booted: false,
    fullWidth: 0,
    lastLeft: null,
    lastTop: null,
    observer: null,
    timers: [],
    debounceTimer: null,
    docListeners: [],
  };

  // ---------------------------------------------------------------- styles

  const STYLE_ID = 'melon-composer-chips-style';
  const style = el('style');
  style.id = STYLE_ID;
  style.textContent = `
  .melon-chips {
    display: none; align-items: center; gap: 4px;
    position: fixed; z-index: 2147483000;
    pointer-events: none;
    -webkit-app-region: no-drag;
    user-select: none; -webkit-user-select: none;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  }
  /* The palette lives on two scopes: the chips render inside the composer,
     the popover is appended to <body> — custom properties are inherited, and
     these two elements are siblings, so each one needs its own copy. */
  .melon-chips, .melon-popover {
    --melon-fg: #ececf1;
    --melon-dim: rgba(236, 236, 241, 0.6);
    --melon-bg: #242428;
    --melon-bg-hover: #2d2d33;
    --melon-border: rgba(255,255,255,0.14);
    --melon-shadow: 0 2px 10px rgba(0,0,0,0.22), inset 0 1px 0 rgba(255,255,255,0.10);
    --melon-pop-bg: rgba(30, 30, 35, 0.72);
    --melon-pop-border: rgba(255,255,255,0.16);
    --melon-pop-shadow: 0 18px 50px rgba(0,0,0,0.45), 0 4px 14px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.10);
    --melon-divider: rgba(255,255,255,0.10);
    --melon-close-fg: rgba(236,236,241,0.65);
  }
  .melon-chips[data-melon-theme="light"], .melon-popover[data-melon-theme="light"] {
    --melon-fg: #1c1c1e;
    --melon-dim: rgba(28, 28, 30, 0.58);
    --melon-bg: #f4f4f7;
    --melon-bg-hover: #ffffff;
    --melon-border: rgba(0,0,0,0.09);
    --melon-shadow: 0 2px 8px rgba(0,0,0,0.10), inset 0 1px 0 rgba(255,255,255,0.85);
    --melon-pop-bg: rgba(250, 250, 252, 0.78);
    --melon-pop-border: rgba(0,0,0,0.10);
    --melon-pop-shadow: 0 18px 50px rgba(0,0,0,0.16), 0 4px 14px rgba(0,0,0,0.08), inset 0 1px 0 rgba(255,255,255,0.9);
    --melon-divider: rgba(0,0,0,0.08);
    --melon-close-fg: rgba(28,28,30,0.6);
  }
  .melon-chip {
    display: inline-flex; align-items: center; gap: 4px;
    height: 28px; padding: 0 8px; border-radius: 999px;
    pointer-events: auto;
    background: var(--melon-bg);
    border: 0.5px solid var(--melon-border);
    box-shadow: var(--melon-shadow);
    color: var(--melon-fg);
    font-size: 12px; font-weight: 500; line-height: 1; white-space: nowrap;
    cursor: default; transition: background 0.15s ease, transform 0.12s ease;
  }
  .melon-chip:hover { background: var(--melon-bg-hover); }
  .melon-chip:active { transform: scale(0.97); }
  .melon-chip[data-clickable="true"] { cursor: pointer; }
  .melon-chips.melon-compact .melon-chip:not([data-clickable="true"]) { display: none; }
  .melon-chips.melon-tiny { display: none; }
  .melon-chips.melon-offline { opacity: 0.55; }
  .melon-chips.melon-offline:hover { opacity: 0.85; }
  /* Two chip sets share one container: the account-pool quota chips and the
     provider chips (OpenCode / OpenRouter). The mode attribute switches them. */
  .melon-chips .melon-pool-group, .melon-chips .melon-provider-group {
    display: inline-flex; align-items: center; gap: 4px;
  }
  .melon-chips .melon-provider-group { display: none; }
  .melon-chips[data-melon-mode="opencode"] .melon-pool-group,
  .melon-chips[data-melon-mode="openrouter"] .melon-pool-group { display: none; }
  .melon-chips[data-melon-mode="opencode"] .melon-provider-group,
  .melon-chips[data-melon-mode="openrouter"] .melon-provider-group { display: inline-flex; }
  /* Picker grouping (injected into the Codex model menu). */
  .melon-pick-group {
    padding: 10px 12px 4px 12px;
    font-size: 10.5px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase;
    opacity: 0.55; pointer-events: none;
    user-select: none; -webkit-user-select: none;
  }
  [role="menuitemradio"][data-melon-provider] { position: relative; padding-right: 84px; }
  [role="menuitemradio"][data-melon-provider]::after {
    content: attr(data-melon-provider);
    position: absolute; right: 10px; top: 50%; transform: translateY(-50%);
    font-size: 10px; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase;
    opacity: 0.45; color: currentColor; pointer-events: none;
  }
  .melon-chip-label { color: var(--melon-dim); font-weight: 500; }
  .melon-chip-value { font-weight: 600; font-variant-numeric: tabular-nums; }
  .melon-chip-sep { color: var(--melon-dim); opacity: 0.55; margin: 0 1px; }
  .melon-dot {
    width: 6px; height: 6px; border-radius: 50%;
    box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.28), 0 0 7px var(--melon-glow, rgba(255,255,255,0.25));
  }
  .melon-dot-purple { background: radial-gradient(circle at 35% 30%, #c4b5fd, #8b5cf6 72%); --melon-glow: rgba(139,92,246,0.55); }
  .melon-dot-blue   { background: radial-gradient(circle at 35% 30%, #93c5fd, #3b82f6 72%); --melon-glow: rgba(59,130,246,0.55); }
  .melon-dot-green  { background: radial-gradient(circle at 35% 30%, #6ee7b7, #10b981 72%); --melon-glow: rgba(16,185,129,0.55); }
  .melon-dot-teal   { background: radial-gradient(circle at 35% 30%, #5eead4, #14b8a6 72%); --melon-glow: rgba(20,184,166,0.55); }
  .melon-dot-orange { background: radial-gradient(circle at 35% 30%, #fdba74, #f97316 72%); --melon-glow: rgba(249,115,22,0.55); }
  .melon-refresh {
    display: inline-flex; align-items: center; justify-content: center;
    width: 28px; height: 28px; border-radius: 999px; padding: 0;
    pointer-events: auto;
    background: var(--melon-bg);
    border: 0.5px solid var(--melon-border);
    box-shadow: var(--melon-shadow);
    color: var(--melon-dim); cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease, transform 0.12s ease;
  }
  .melon-refresh:hover { background: var(--melon-bg-hover); color: var(--melon-fg); }
  .melon-refresh:active { transform: scale(0.94); }
  .melon-refresh.melon-spinning svg { animation: melon-spin 0.8s linear infinite; }
  @keyframes melon-spin { to { transform: rotate(360deg); } }

  .melon-popover {
    position: fixed; z-index: 2147483000; width: 296px;
    border-radius: 14px; overflow: hidden;
    background: var(--melon-pop-bg);
    -webkit-backdrop-filter: blur(30px) saturate(180%);
    backdrop-filter: blur(30px) saturate(180%);
    border: 0.5px solid var(--melon-pop-border);
    box-shadow: var(--melon-pop-shadow);
    color: var(--melon-fg);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    -webkit-app-region: no-drag;
    user-select: none; -webkit-user-select: none;
  }
  .melon-pop-head {
    display: flex; align-items: center; gap: 8px;
    padding: 12px 14px 10px 14px;
  }
  .melon-pop-title { font-size: 13px; font-weight: 600; }
  .melon-pop-close {
    margin-left: auto; display: inline-flex; align-items: center; justify-content: center;
    width: 22px; height: 22px; border-radius: 6px; border: none; padding: 0;
    background: transparent; color: var(--melon-close-fg); cursor: pointer;
  }
  .melon-pop-close:hover { background: var(--melon-divider); color: var(--melon-fg); }
  .melon-pop-divider { height: 1px; background: var(--melon-divider); }
  .melon-pop-row {
    display: flex; align-items: center; gap: 8px;
    padding: 10px 14px; font-size: 12px;
  }
  .melon-pop-plan { font-weight: 700; letter-spacing: 0.04em; }
  .melon-pop-section {
    padding: 9px 14px 2px 14px;
    font-size: 10.5px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase;
    color: var(--melon-dim);
  }
  .melon-pop-row .melon-pop-label { color: var(--melon-dim); }
  .melon-pop-note {
    padding: 2px 14px 8px 14px;
    font-size: 10.5px; line-height: 1.45;
    color: var(--melon-dim);
  }
  .melon-pop-metric { display: inline-flex; align-items: center; gap: 6px; color: var(--melon-dim); font-variant-numeric: tabular-nums; }
  .melon-pop-metric b { color: var(--melon-fg); font-weight: 600; }
  .melon-pop-spacer { flex: 1; }
  .melon-pop-foot {
    display: flex; align-items: center;
    padding: 9px 14px; font-size: 12px; color: var(--melon-dim);
    font-variant-numeric: tabular-nums;
  }
  .melon-pop-foot b { color: var(--melon-fg); font-weight: 600; }
  `;

  // ---------------------------------------------------------------- DOM

  const container = el('div', 'melon-chips no-drag');
  container.setAttribute('data-melon-chips', '1');
  container.setAttribute('data-melon-mode', 'openai');

  function makeChip(dotClass, label, clickable) {
    const chip = el('span', 'melon-chip');
    const dot = el('span', 'melon-dot ' + dotClass);
    chip.appendChild(dot);
    const labelNode = el('span', 'melon-chip-label', label);
    chip.appendChild(labelNode);
    const value = el('span', 'melon-chip-value', '—');
    chip.appendChild(value);
    if (clickable) chip.setAttribute('data-clickable', 'true');
    return { chip, value, dot, label: labelNode };
  }

  /// Appends a `· label value` segment to an existing chip and returns the
  /// value node so live updates can replace just the text.
  function chipSegment(chip, label, value) {
    chip.chip.appendChild(el('span', 'melon-chip-sep', '·'));
    chip.chip.appendChild(el('span', 'melon-chip-label', label));
    const node = el('span', 'melon-chip-value', value);
    chip.chip.appendChild(node);
    return node;
  }

  // Account pool: one compact chip with the pool numbers (accounts · 5h · week).
  const poolGroup = el('span', 'melon-pool-group');
  const poolChip = makeChip('melon-dot-purple', LABELS.accounts, true);
  const fiveValue = chipSegment(poolChip, LABELS.fiveHour, '—');
  const weekValue = chipSegment(poolChip, LABELS.week, '—');
  poolGroup.appendChild(poolChip.chip);

  // Provider set: shown when the selected model comes from OpenCode or
  // OpenRouter. One compact chip carries the session spend of that provider;
  // the full breakdown lives in the popover.
  const providerGroup = el('span', 'melon-provider-group');
  const providerChip = makeChip('melon-dot-teal', '—', true);
  providerGroup.appendChild(providerChip.chip);

  container.appendChild(poolGroup);
  container.appendChild(providerGroup);

  const refreshButton = el('button', 'melon-refresh');
  refreshButton.type = 'button';
  refreshButton.title = LABELS.refresh;
  refreshButton.appendChild(icon(['M21 12a9 9 0 1 1-2.64-6.36', 'M21 3v6h-6'], 13));
  // The Windows bridge does not expose __melonSend yet; do not show a button
  // that silently does nothing.
  if (typeof window.__melonSend === "function") container.appendChild(refreshButton);

  // ---------------------------------------------------------------- data

  function totals() {
    const status = state.status || {};
    const groups = Array.isArray(status.groups) ? status.groups : [];
    let five = 0;
    let week = 0;
    let haveData = false;
    for (const group of groups) {
      if (group.fiveHour != null || group.weekly != null) haveData = true;
      five += Number(group.fiveHour) || 0;
      week += Number(group.weekly) || 0;
    }
    return {
      accounts: Number(status.accounts) || 0,
      five: haveData ? round(five) + '%' : '—',
      week: haveData ? round(week) + '%' : '—',
      groups,
      health: status.health || {},
    };
  }

  // ------------------------------------------------------- model & provider

  function modelIndex() {
    const status = state.status || {};
    return Array.isArray(status.models) ? status.models : [];
  }

  let modelCache = { at: 0, value: null };

  /// The model of the visible composer (one composer exists per open tab;
  /// hidden ones have no box).
  function currentModel(force) {
    if (!force && Date.now() - modelCache.at < 500) return modelCache.value;
    let best = null;
    const models = modelIndex();
    if (models.length) {
      for (const button of document.querySelectorAll('button')) {
        if (button.closest('[role="menu"]') || button.closest('.melon-chips') || button.closest('.melon-popover')) continue;
        const rect = button.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) continue;
        const text = (button.textContent || '').trim();
        if (!text) continue;
        for (const model of models) {
          if (!model.name || text.indexOf(model.name) === -1) continue;
          if (!best || model.name.length > best.name.length) best = model;
        }
      }
    }
    modelCache = { at: Date.now(), value: best };
    return best;
  }

  /// Provider of the selected model, or null for the account-pool models.
  function providerMode() {
    const model = currentModel();
    const provider = model && model.provider;
    return provider && provider !== 'openai' ? provider : null;
  }

  function activeThreadId() {
    const node = document.querySelector('[data-app-action-sidebar-thread-active="true"]');
    const raw = node && node.getAttribute('data-app-action-sidebar-thread-id');
    if (!raw) return null;
    const parts = String(raw).split(':');
    return parts[parts.length - 1] || null;
  }

  function contextStats(session) {
    if (!session) return { used: null, window: null, percent: null, detail: null };
    const windowSize = Number(session.contextWindow) || 0;
    const last = session.last || {};
    const used = (Number(last.input) || 0) + (Number(last.output) || 0);
    const pct = windowSize > 0 && used > 0 ? Math.round((used / windowSize) * 100) : null;
    const detail = used > 0 && windowSize > 0
      ? formatTokens(used) + ' / ' + formatTokens(windowSize) + (pct != null ? ' (' + pct + '%)' : '')
      : null;
    return { used, window: windowSize, percent: pct, detail };
  }

  // ------------------------------------------------------ provider rendering

  /// Model selected in the visible composer; falls back to the last turn's model.
  function activeModelName() {
    const status = state.status || {};
    const active = status.active || {};
    if (active.model) return String(active.model);
    const session = status.session || null;
    return session && session.model ? String(session.model) : '';
  }

  /// Session spend of one provider: the priced part of the thread cost.
  function providerSpend(kind) {
    const session = state.status ? state.status.session : null;
    const cost = session && session.cost ? session.cost : null;
    const providers = cost && cost.providers ? cost.providers : null;
    const stats = providers ? providers[kind] : null;
    const amount = stats && stats.usd != null && isFinite(Number(stats.usd)) ? Number(stats.usd) : null;
    return { amount, cost, stats };
  }

  function renderProvider(kind) {
    const status = state.status || {};
    const stats = (status.providers || {})[kind] || null;
    const spend = providerSpend(kind);

    providerChip.label.textContent = PROVIDERS[kind] || kind;
    providerChip.dot.className = 'melon-dot ' + (kind === 'opencode' ? 'melon-dot-teal' : 'melon-dot-orange');
    const session = status.session || null;
    const ctx = contextStats(session);
    const modelName = activeModelName();
    if (ctx.percent != null) {
      providerChip.value.textContent = ctx.percent + '%';
      let title = (modelName ? modelName + ' · ' : '') + LABELS.context + ': ' + (ctx.detail || ctx.percent + '%');
      if (spend.amount != null) {
        title += ' · ' + LABELS.sessionSpend + ': ≈' + formatMoney(spend.amount);
        if (spend.cost && spend.cost.scaled) title += ' ' + LABELS.scaledNote;
      }
      providerChip.chip.title = title;
    } else if (spend.amount != null) {
      providerChip.value.textContent = '≈' + formatMoney(spend.amount);
      let title = LABELS.sessionSpend + ': ' + LABELS.estimatedFrom;
      if (spend.cost && spend.cost.scaled) title += ' ' + LABELS.scaledNote;
      providerChip.chip.title = title;
    } else {
      providerChip.value.textContent = '—';
      providerChip.chip.title = stats && stats.error ? String(stats.error) : LABELS.noPricing;
    }
  }

  function render() {
    const mode = providerMode();
    container.setAttribute('data-melon-mode', mode || 'openai');
    // Pool values stay current even when the pool group is hidden, so a mode
    // switch never shows stale numbers.
    const data = totals();
    poolChip.value.textContent = String(data.accounts);
    fiveValue.textContent = data.five;
    weekValue.textContent = data.week;
    if (mode) {
      renderProvider(mode);
    }
    if (state.popoverOpen) renderPopoverPane(mode);
  }

  /// Re-renders the open popover for the current mode.
  function renderPopoverPane(mode) {
    if (mode) renderProviderPopover(mode);
    else renderPopover();
  }

  // ---------------------------------------------------------------- popover

  function renderPopover() {
    const pop = state.popover;
    if (!pop) return;
    const status = state.status || {};
    const body = pop.querySelector('.melon-pop-body');
    const foot = pop.querySelector('.melon-pop-foot');
    const data = totals();
    const dot = pop.querySelector('.melon-pop-head .melon-dot');
    const title = pop.querySelector('.melon-pop-title');
    if (dot) dot.className = 'melon-dot melon-dot-purple';
    if (title) title.textContent = LABELS.title;
    body.textContent = '';
    if (data.groups.length === 0) {
      const empty = el('div', 'melon-pop-row');
      empty.appendChild(el('span', 'melon-pop-metric', '—'));
      body.appendChild(empty);
    }
    for (const group of data.groups) {
      const row = el('div', 'melon-pop-row');
      row.appendChild(el('span', 'melon-dot melon-dot-purple'));
      row.appendChild(el('span', 'melon-pop-plan', String(group.plan || '—').toUpperCase()));
      row.appendChild(el('span', 'melon-chip-value', String(group.count || 0)));
      row.appendChild(el('span', 'melon-pop-spacer'));
      const weekMetric = el('span', 'melon-pop-metric');
      weekMetric.appendChild(el('span', 'melon-dot melon-dot-green'));
      weekMetric.appendChild(el('span', null, LABELS.week + ' '));
      weekMetric.appendChild(el('b', null, group.weekly != null ? round(group.weekly) + '%' : '—'));
      row.appendChild(weekMetric);
      row.appendChild(el('span', 'melon-pop-metric', '·'));
      const fiveMetric = el('span', 'melon-pop-metric');
      fiveMetric.appendChild(el('span', 'melon-dot melon-dot-blue'));
      fiveMetric.appendChild(el('span', null, LABELS.fiveHour + ' '));
      fiveMetric.appendChild(el('b', null, group.fiveHour != null ? round(group.fiveHour) + '%' : '—'));
      row.appendChild(fiveMetric);
      body.appendChild(row);
    }
    foot.textContent = '';
    const working = el('span', null, LABELS.working + ' ');
    working.appendChild(el('b', null, `${data.health.working != null ? data.health.working : 0}/${data.health.total != null ? data.health.total : data.accounts}`));
    foot.appendChild(working);
    if (Number(status.requests) > 0) {
      foot.appendChild(el('span', 'melon-pop-metric', ' · ' + (LABELS.requests || 'Requests') + ': ' + round(status.requests) + '/min'));
    }
    foot.appendChild(el('span', 'melon-pop-spacer'));
    const issues = el('span', null, '');
    issues.appendChild(el('span', null, LABELS.failed + ' '));
    issues.appendChild(el('b', null, String(data.health.failed != null ? data.health.failed : 0)));
    issues.appendChild(el('span', null, ' · ' + LABELS.paused + ' '));
    issues.appendChild(el('b', null, String(data.health.paused != null ? data.health.paused : 0)));
    foot.appendChild(issues);
  }

  function popRow(label, value) {
    const row = el('div', 'melon-pop-row');
    row.appendChild(el('span', 'melon-pop-label', label));
    row.appendChild(el('span', 'melon-pop-spacer'));
    row.appendChild(el('b', null, value));
    return row;
  }

  /// A dim explanatory line under a popover row.
  function popNote(text) {
    return el('div', 'melon-pop-note', text);
  }

  /// Provider details: session token accounting plus everything the provider
  /// API exposes (OpenRouter credits and key limits, OpenCode workspace).
  function renderProviderPopover(kind) {
    const pop = state.popover;
    if (!pop) return;
    const status = state.status || {};
    const stats = (status.providers || {})[kind] || null;
    const session = status.session || null;
    const title = pop.querySelector('.melon-pop-title');
    const dot = pop.querySelector('.melon-pop-head .melon-dot');
    if (title) title.textContent = (PROVIDERS[kind] || kind) + ' · ' + LABELS.providerData;
    if (dot) dot.className = 'melon-dot ' + (kind === 'opencode' ? 'melon-dot-teal' : 'melon-dot-orange');

    const body = pop.querySelector('.melon-pop-body');
    const foot = pop.querySelector('.melon-pop-foot');
    body.textContent = '';
    foot.textContent = '';

    const context = contextStats(session);
    const spend = providerSpend(kind);
    const sessionStats = spend.stats;
    body.appendChild(el('div', 'melon-pop-section', LABELS.session));
    body.appendChild(popRow(
      LABELS.sessionSpend,
      spend.amount != null ? '≈' + formatMoney(spend.amount) : LABELS.noData
    ));
    if (spend.amount != null) {
      body.appendChild(popNote(LABELS.estimatedFrom));
      if (spend.cost && spend.cost.scaled) body.appendChild(popNote(LABELS.scaledNote));
    } else {
      body.appendChild(popNote(sessionStats ? LABELS.noPricing : LABELS.sessionNoData));
    }
    body.appendChild(popRow(LABELS.context, context.detail || LABELS.noData));
    if (sessionStats && Number(sessionStats.tokens) > 0) {
      body.appendChild(popRow(LABELS.tokens, formatTokens(sessionStats.tokens)));
      body.appendChild(popRow(LABELS.input, formatTokens(sessionStats.input)));
      const hit = percent(sessionStats.cached, sessionStats.input);
      body.appendChild(popRow(LABELS.cached, formatTokens(sessionStats.cached) + (hit != null ? ' (' + hit + '%)' : '')));
      body.appendChild(popRow(LABELS.output, formatTokens(sessionStats.output)));
      body.appendChild(popRow(LABELS.reasoning, formatTokens(sessionStats.reasoning)));
      body.appendChild(popRow(LABELS.turns, String(sessionStats.turns || 0)));
      const activeName = activeModelName();
      if (activeName) body.appendChild(popRow(LABELS.sessionModel, activeName));
      if (session && session.model && activeName && String(session.model) !== activeName) {
        body.appendChild(popRow(LABELS.lastTurnModel, String(session.model)));
      }
    } else {
      body.appendChild(popRow(LABELS.tokens, LABELS.noData));
    }

    body.appendChild(el('div', 'melon-pop-section', PROVIDERS[kind] || kind));
    if (kind === 'openrouter' && stats) {
      body.appendChild(popRow(LABELS.available, stats.creditsRemaining != null ? formatMoney(stats.creditsRemaining) : LABELS.noData));
      body.appendChild(popRow(LABELS.creditsSpent + ' · ' + LABELS.lifetime, stats.creditsUsage != null ? formatMoney(stats.creditsUsage) : LABELS.noData));
      body.appendChild(popRow(LABELS.purchased, stats.creditsTotal != null ? formatMoney(stats.creditsTotal) : LABELS.noData));
      body.appendChild(popRow(LABELS.keyUsage, stats.keyUsage != null ? formatMoney(stats.keyUsage) : LABELS.noData));
      body.appendChild(popRow(LABELS.keyLimit, stats.keyLimit != null ? formatMoney(stats.keyLimit) : LABELS.noData));
      body.appendChild(popRow(LABELS.keyRemaining, stats.keyRemaining != null ? formatMoney(stats.keyRemaining) : LABELS.noData));
      body.appendChild(popNote(LABELS.creditsNote));
      body.appendChild(popRow(LABELS.freeTier, stats.isFreeTier ? LABELS.yes : LABELS.no));
      if (stats.error) body.appendChild(popRow('—', String(stats.error)));
    } else if (kind === 'opencode' && stats) {
      body.appendChild(popRow(LABELS.workspace, stats.workspace || LABELS.noData));
      body.appendChild(popRow(LABELS.models, String(stats.modelCount || 0)));
      body.appendChild(popRow(LABELS.balance, LABELS.balanceUnavailable));
      if (stats.error) body.appendChild(popRow('—', String(stats.error)));
    } else {
      body.appendChild(popRow(LABELS.providerData, LABELS.noData));
    }

    const updated = stats ? timeOfDay(stats.updatedAt) : null;
    foot.appendChild(el('span', null, updated ? LABELS.updated + ' ' + updated : LABELS.noData));
    foot.appendChild(el('span', 'melon-pop-spacer'));
    foot.appendChild(el('b', null, activeModelName()));
  }

  function buildPopover() {
    const pop = el('div', 'melon-popover');
    pop.setAttribute('data-melon-theme', container.getAttribute('data-melon-theme') || 'dark');
    const head = el('div', 'melon-pop-head');
    head.appendChild(el('span', 'melon-dot melon-dot-purple'));
    head.appendChild(el('span', 'melon-pop-title', LABELS.title));
    const close = el('button', 'melon-pop-close');
    close.type = 'button';
    close.appendChild(icon(['M18 6 6 18', 'm6 6 12 12'], 13));
    close.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      togglePopover(false);
    });
    head.appendChild(close);
    pop.appendChild(head);
    pop.appendChild(el('div', 'melon-pop-divider'));
    pop.appendChild(el('div', 'melon-pop-body'));
    pop.appendChild(el('div', 'melon-pop-divider'));
    pop.appendChild(el('div', 'melon-pop-foot'));
    pop.addEventListener('mousedown', (event) => event.stopPropagation());
    pop.addEventListener('click', (event) => event.stopPropagation());
    return pop;
  }

  function positionPopover() {
    const pop = state.popover;
    if (!pop || !state.popoverOpen) return;
    const anchorChip = providerMode() ? providerChip.chip : poolChip.chip;
    const rect = anchorChip.getBoundingClientRect();
    pop.style.left = '0px';
    pop.style.bottom = '0px';
    const width = pop.offsetWidth;
    let left = Math.round(rect.left - 6);
    left = Math.max(12, Math.min(left, window.innerWidth - width - 12));
    pop.style.left = left + 'px';
    pop.style.bottom = Math.round(window.innerHeight - rect.top + 10) + 'px';
  }

  function togglePopover(force) {
    const open = force != null ? force : !state.popoverOpen;
    if (open === state.popoverOpen) return;
    state.popoverOpen = open;
    if (open) {
      if (!state.popover) state.popover = buildPopover();
      state.popover.setAttribute('data-melon-theme', container.getAttribute('data-melon-theme') || 'dark');
      document.body.appendChild(state.popover);
      render();
      positionPopover();
      addDocListener(document, 'mousedown', onOutside, true);
      addDocListener(document, 'keydown', onKey, true);
      addDocListener(window, 'resize', positionPopover, true);
      addDocListener(window, 'scroll', positionPopover, true);
    } else {
      if (state.popover && state.popover.parentElement) state.popover.remove();
      removeDocListener(document, 'mousedown', onOutside, true);
      removeDocListener(document, 'keydown', onKey, true);
      removeDocListener(window, 'resize', positionPopover, true);
      removeDocListener(window, 'scroll', positionPopover, true);
    }
  }

  function onOutside(event) {
    if (!state.popoverOpen) return;
    if (state.popover && state.popover.contains(event.target)) return;
    if (container.contains(event.target)) return;
    togglePopover(false);
  }

  function onKey(event) {
    if (event.key === 'Escape') togglePopover(false);
  }

  // ---------------------------------------------------------------- listeners

  function addDocListener(target, type, handler, capture) {
    target.addEventListener(type, handler, capture);
    state.docListeners.push([target, type, handler, capture]);
  }

  function removeDocListener(target, type, handler, capture) {
    target.removeEventListener(type, handler, capture);
    state.docListeners = state.docListeners.filter((entry) => !(entry[0] === target && entry[1] === type && entry[2] === handler));
  }

  poolChip.chip.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    togglePopover();
  });

  providerChip.chip.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    togglePopover();
  });

  // ---------------------------------------------------------------- refresh

  function startSpin() {
    refreshButton.classList.add('melon-spinning');
  }

  function stopSpin() {
    refreshButton.classList.remove('melon-spinning');
    state.refreshBusy = false;
  }

  refreshButton.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (state.refreshBusy) return;
    state.refreshBusy = true;
    state.refreshDeadline = Date.now() + 90000;
    startSpin();
    try {
      if (typeof window.__melonSend === 'function') {
        window.__melonSend(JSON.stringify({ action: 'refresh' }));
      }
    } catch (error) { /* binding unavailable */ }
  });

  // ---------------------------------------------------------------- attach

  function isVisible(node) {
    const rect = node.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function findSelector(row) {
    // The model dropdown lives in the last visible child that holds a ComposerDropdown.
    const visible = Array.from(row.children).filter(isVisible);
    for (let index = visible.length - 1; index >= 0; index -= 1) {
      if (visible[index].querySelector && visible[index].querySelector('[class*="ComposerDropdown"]')) {
        return visible[index];
      }
    }
    return visible.length ? visible[visible.length - 1] : null;
  }

  function findAnchor() {
    // The overlay sits between the permissions pill and the model selector.
    const footers = Array.from(document.querySelectorAll('[class*="ComposerLayoutFooter"]')).filter(isVisible);
    for (const footer of footers) {
      let rightColumn = footer.querySelector(':scope > .col-start-3');
      if (!rightColumn) {
        rightColumn = Array.from(footer.children).find((child) => String(child.className).includes('col-start-3'));
      }
      if (!rightColumn) continue;
      const row = rightColumn.querySelector('.flex-1.justify-end') || rightColumn.querySelector('.flex.justify-end');
      if (!row) continue;
      const selector = findSelector(row);
      if (!selector) continue;
      let leftBound = row.getBoundingClientRect().left - 32;
      for (const child of footer.children) {
        if (String(child.className).includes('col-start-1')) {
          const rect = child.getBoundingClientRect();
          if (rect.width > 0) leftBound = Math.max(leftBound, rect.right - 12);
        }
      }
      return { footer, row, selector, leftBound };
    }
    const rows = Array.from(document.querySelectorAll('.flex-1.justify-end, .flex.justify-end')).filter(isVisible);
    for (const row of rows) {
      const selector = findSelector(row);
      if (selector) {
        return {
          footer: row.closest('[class*="ComposerLayoutFooter"]') || row,
          row,
          selector,
          leftBound: row.getBoundingClientRect().left - 32,
        };
      }
    }
    return null;
  }

  function updateTheme(anchor) {
    const theme = luminance(effectiveBackground(anchor || container)) > 0.5 ? 'light' : 'dark';
    if (container.getAttribute('data-melon-theme') !== theme) {
      container.setAttribute('data-melon-theme', theme);
      if (state.popover) state.popover.setAttribute('data-melon-theme', theme);
    }
  }

  function updateDensity(available) {
    // Adaptive density: full chips → compact (accounts + refresh) → hidden.
    // Density follows the real free band between the permissions pill and the model selector.
    if (available < 138) {
      container.classList.add('melon-tiny');
      container.classList.remove('melon-compact');
      return;
    }
    container.classList.remove('melon-tiny');
    if (!container.classList.contains('melon-compact')) {
      state.fullWidth = container.scrollWidth;
      if (state.fullWidth > available) container.classList.add('melon-compact');
    } else if ((state.fullWidth || 0) + 24 < available) {
      container.classList.remove('melon-compact');
    }
    if (container.classList.contains('melon-compact') && container.scrollWidth > available) {
      container.classList.add('melon-tiny');
    }
  }

  function wipeForeign() {
    // Remove containers left by replaced instances (their one-shot debounce may
    // re-attach a container right after dispose — this catches that).
    for (const node of document.querySelectorAll('.melon-chips, .melon-popover')) {
      if (node !== container && node !== state.popover) node.remove();
    }
    for (const node of document.querySelectorAll('#' + STYLE_ID)) {
      if (node !== style) node.remove();
    }
  }

  function ensureAttached() {
    injectPicker();
    const anchor = findAnchor();
    if (!anchor) {
      container.style.display = 'none';
      return;
    }
    const selectorRect = anchor.selector.getBoundingClientRect();
    if (selectorRect.width === 0) {
      container.style.display = 'none';
      return;
    }
    container.style.display = 'flex';
    const rightEdge = selectorRect.left - 4;
    const available = Math.max(0, rightEdge - anchor.leftBound);
    updateDensity(available);
    if (container.classList.contains('melon-tiny')) {
      container.style.display = 'none';
      return;
    }
    const width = container.offsetWidth;
    const height = container.offsetHeight;
    const top = Math.round(selectorRect.top + (selectorRect.height - height) / 2);
    const left = Math.round(rightEdge - width);
    if (state.lastLeft !== left || state.lastTop !== top) {
      state.lastLeft = left;
      state.lastTop = top;
      container.style.left = left + 'px';
      container.style.top = top + 'px';
    }
    wipeForeign();
    updateTheme(anchor.footer);
    if (state.popoverOpen) positionPopover();
  }

  function watchdog() {
    if (Date.now() - state.lastPushAt > 25000) {
      container.classList.add('melon-offline');
    }
    if (state.refreshBusy && Date.now() > state.refreshDeadline) {
      stopSpin();
    }
  }

  // ---------------------------------------------------------------- picker

  /// Groups the Codex model menu by provider: one injected header before the
  /// first model of every provider band, plus a right-aligned provider tag on
  /// the third-party rows. React re-renders the menu on every open, so the
  /// markup is re-applied from a signature check.
  function providerOfName(name) {
    const models = modelIndex();
    let best = null;
    for (const model of models) {
      if (!model.name) continue;
      if (name === model.name) return model;
      if (name.indexOf(model.name) !== -1 && (!best || model.name.length > best.name.length)) best = model;
    }
    return best;
  }

  function injectPicker() {
    for (const menu of document.querySelectorAll('[role="menu"]')) {
      const items = Array.from(menu.querySelectorAll('[role="menuitemradio"]'));
      if (items.length < 2) continue;
      const first = (items[0].textContent || '').trim().slice(0, 24);
      const last = (items[items.length - 1].textContent || '').trim().slice(0, 24);
      const signature = items.length + '|' + first + '|' + last;
      const headers = String(menu.querySelectorAll('.melon-pick-group').length);
      if (menu.getAttribute('data-melon-picker') === signature && headers === menu.getAttribute('data-melon-picker-groups')) {
        continue;
      }
      menu.querySelectorAll('.melon-pick-group').forEach((node) => node.remove());
      let lastProvider = null;
      let groups = 0;
      for (const item of items) {
        const name = (item.textContent || '').trim().replace(/\s+/g, ' ');
        const model = providerOfName(name);
        if (!model) {
          item.removeAttribute('data-melon-provider');
          continue;
        }
        if (model.provider === 'openai') item.removeAttribute('data-melon-provider');
        else item.setAttribute('data-melon-provider', PROVIDERS[model.provider] || model.provider);
        if (model.provider !== lastProvider) {
          lastProvider = model.provider;
          groups += 1;
          const header = el('div', 'melon-pick-group', PROVIDERS[model.provider] || model.provider);
          header.setAttribute('role', 'presentation');
          if (item.parentElement) item.parentElement.insertBefore(header, item);
        }
      }
      menu.setAttribute('data-melon-picker', signature);
      menu.setAttribute('data-melon-picker-groups', String(groups));
    }
  }

  function clearPicker() {
    for (const node of document.querySelectorAll('.melon-pick-group')) node.remove();
    for (const node of document.querySelectorAll('[data-melon-picker]')) {
      node.removeAttribute('data-melon-picker');
      node.removeAttribute('data-melon-picker-groups');
    }
    for (const node of document.querySelectorAll('[data-melon-provider]')) node.removeAttribute('data-melon-provider');
  }

  // ---------------------------------------------------------------- boot

  function boot() {
    if (state.booted) return;
    if (!document.body) return;
    state.booted = true;
    // Wipe stale DOM left by crashed or replaced instances.
    for (const stale of document.querySelectorAll('.melon-chips, .melon-popover, #melon-composer-chips-style')) {
      stale.remove();
    }
    clearPicker();
    (document.head || document.documentElement).appendChild(style);
    document.documentElement.setAttribute('data-melon-chips', '1');
    document.body.appendChild(container);
    render();
    ensureAttached();
    addDocListener(window, 'resize', ensureAttached, true);
    addDocListener(document, 'scroll', ensureAttached, true);

    state.observer = new MutationObserver(() => {
      if (state.debounceTimer) return;
      state.debounceTimer = setTimeout(() => {
        state.debounceTimer = null;
        ensureAttached();
      }, 120);
    });
    state.observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
    state.timers.push(setInterval(ensureAttached, 1500));
    state.timers.push(setInterval(watchdog, 10000));
  }

  function dispose() {
    if (state.observer) state.observer.disconnect();
    if (state.debounceTimer) clearTimeout(state.debounceTimer);
    state.debounceTimer = null;
    for (const timer of state.timers) clearInterval(timer);
    state.timers = [];
    for (const [target, type, handler, capture] of state.docListeners) {
      target.removeEventListener(type, handler, capture);
    }
    state.docListeners = [];
    if (state.popover && state.popover.parentElement) state.popover.remove();
    state.popover = null;
    state.popoverOpen = false;
    clearPicker();
    if (container.parentElement) container.remove();
    if (style.parentElement) style.remove();
    if (window.__melonInstances) {
      window.__melonInstances = window.__melonInstances.filter((instance) => instance !== api);
    }
    delete window.__melonChipsSetStatus;
    delete window.__melonChipsSetOffline;
    delete window.__melonChipsPing;
    delete window.__melonChipsDispose;
    delete window.__melonChipsContext;
  }

  // ---------------------------------------------------------------- API

  const api = { dispose };

  const previousInstances = window.__melonInstances || [];
  window.__melonInstances = [];
  for (const instance of previousInstances) {
    try { instance.dispose(); } catch (error) { /* stale instance */ }
  }
  if (typeof window.__melonChipsDispose === 'function') {
    try { window.__melonChipsDispose(); } catch (error) { /* legacy instance */ }
  }
  window.__melonInstances.push(api);
  window.__melonChipsDispose = dispose;

  window.__melonChipsSetStatus = (data) => {
    try {
      state.status = typeof data === 'string' ? JSON.parse(data) : data;
    } catch (error) {
      return;
    }
    state.lastPushAt = Date.now();
    container.classList.remove('melon-offline');
    if (state.status && state.status.refreshing === true) {
      startSpin();
    } else {
      stopSpin();
    }
    render();
  };

  window.__melonChipsSetOffline = () => {
    state.lastPushAt = 0;
    container.classList.add('melon-offline');
  };

  window.__melonChipsContext = () => {
    const model = currentModel(true);
    return {
      model: model ? model.name : null,
      provider: model ? model.provider : null,
      threadId: activeThreadId(),
      mode: container.getAttribute('data-melon-mode'),
    };
  };

  window.__melonChipsPing = () => ({
    attached: container.isConnected,
    theme: container.getAttribute('data-melon-theme'),
    popoverOpen: state.popoverOpen,
    lastPushAt: state.lastPushAt,
    mode: container.getAttribute('data-melon-mode'),
    status: state.status,
  });

  if (document.body) {
    boot();
  } else {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
    const bootRetry = setInterval(() => {
      if (document.body) {
        clearInterval(bootRetry);
        boot();
      }
    }, 100);
    state.timers.push(bootRetry);
  }
})();
