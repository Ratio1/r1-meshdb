// Copyright 2026 Ratio1
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

(() => {
  'use strict';

  const root = document.getElementById('react-layout');
  if (!root) return;

  const storageKey = 'r1-meshdb-console-session-v1';
  const state = {
    session: '',
    username: '',
    database: 'defaultdb',
    view: 'overview',
    busy: false,
  };

  const style = document.createElement('style');
  style.textContent = `
    :root {
      color-scheme: light;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f4f6f7;
      color: #172126;
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-width: 320px; min-height: 100vh; background: #f4f6f7; }
    button, input, textarea { font: inherit; letter-spacing: 0; }
    button { cursor: pointer; }
    button:disabled { cursor: wait; opacity: 0.62; }
    [hidden] { display: none !important; }
    .mesh-app { min-height: 100vh; }
    .mesh-login {
      min-height: 100vh;
      display: grid;
      grid-template-rows: auto 1fr auto;
      background: #f4f6f7;
    }
    .mesh-login-brand, .mesh-login-footer {
      width: min(1120px, calc(100% - 40px));
      margin: 0 auto;
    }
    .mesh-login-brand {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 26px 0;
      font-size: 16px;
      font-weight: 760;
    }
    .mesh-mark {
      display: grid;
      place-items: center;
      width: 32px;
      height: 32px;
      border-radius: 6px;
      background: #172126;
      color: #ffffff;
      font-size: 13px;
      font-weight: 800;
    }
    .mesh-login-main {
      display: grid;
      place-items: center;
      padding: 24px 20px 56px;
    }
    .mesh-login-panel {
      width: min(420px, 100%);
      border: 1px solid #d6dddf;
      border-radius: 8px;
      background: #ffffff;
      box-shadow: 0 18px 45px rgba(23, 33, 38, 0.09);
      padding: 30px;
    }
    .mesh-kicker {
      margin: 0 0 8px;
      color: #087f74;
      font-size: 12px;
      font-weight: 760;
      text-transform: uppercase;
    }
    h1, h2, h3, p { margin-top: 0; }
    .mesh-login-panel h1 { margin-bottom: 8px; font-size: 25px; line-height: 1.2; }
    .mesh-muted { color: #607078; }
    .mesh-login-panel .mesh-muted { margin-bottom: 24px; font-size: 14px; line-height: 1.55; }
    .mesh-field { display: grid; gap: 7px; margin-bottom: 16px; }
    .mesh-field label { font-size: 13px; font-weight: 680; color: #304047; }
    .mesh-input, .mesh-textarea {
      width: 100%;
      border: 1px solid #bdc8cc;
      border-radius: 6px;
      background: #ffffff;
      color: #172126;
      outline: none;
      transition: border-color 120ms ease, box-shadow 120ms ease;
    }
    .mesh-input { min-height: 42px; padding: 9px 11px; }
    .mesh-textarea {
      min-height: 180px;
      resize: vertical;
      padding: 14px;
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace;
      font-size: 13px;
      line-height: 1.55;
      tab-size: 2;
    }
    .mesh-input:focus, .mesh-textarea:focus {
      border-color: #087f74;
      box-shadow: 0 0 0 3px rgba(8, 127, 116, 0.13);
    }
    .mesh-button {
      min-height: 38px;
      border: 1px solid transparent;
      border-radius: 6px;
      padding: 8px 14px;
      background: #087f74;
      color: #ffffff;
      font-weight: 720;
    }
    .mesh-button:hover:not(:disabled) { background: #066c63; }
    .mesh-button.secondary { border-color: #bdc8cc; background: #ffffff; color: #26353b; }
    .mesh-button.secondary:hover:not(:disabled) { background: #edf1f2; }
    .mesh-button.quiet { min-height: 34px; background: transparent; color: #405158; padding: 6px 9px; }
    .mesh-button.quiet:hover:not(:disabled) { background: #e8edee; }
    .mesh-button.full { width: 100%; margin-top: 6px; }
    .mesh-error {
      border-left: 3px solid #ba3b35;
      background: #fff0ef;
      color: #7c2925;
      margin: 0 0 16px;
      padding: 10px 12px;
      font-size: 13px;
      line-height: 1.45;
    }
    .mesh-login-footer { padding: 22px 0; color: #748187; font-size: 12px; }
    .mesh-shell { min-height: 100vh; display: grid; grid-template-rows: 58px 1fr; }
    .mesh-topbar {
      position: sticky;
      top: 0;
      z-index: 10;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
      min-width: 0;
      border-bottom: 1px solid #d4dcde;
      background: #ffffff;
      padding: 0 20px;
    }
    .mesh-brand { display: flex; align-items: center; gap: 10px; min-width: 0; font-weight: 760; }
    .mesh-brand-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mesh-top-actions { display: flex; align-items: center; gap: 12px; min-width: 0; }
    .mesh-identity {
      display: flex;
      align-items: center;
      gap: 8px;
      min-width: 0;
      color: #52636a;
      font-size: 13px;
    }
    .mesh-status-dot { width: 8px; height: 8px; border-radius: 50%; background: #178d55; flex: 0 0 auto; }
    .mesh-identity-text { max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mesh-layout { display: grid; grid-template-columns: 210px minmax(0, 1fr); min-height: 0; }
    .mesh-sidebar {
      border-right: 1px solid #d4dcde;
      background: #ffffff;
      padding: 20px 12px;
    }
    .mesh-nav { display: grid; gap: 5px; }
    .mesh-nav button {
      min-height: 38px;
      border: 0;
      border-radius: 6px;
      background: transparent;
      color: #405158;
      padding: 8px 11px;
      text-align: left;
      font-weight: 650;
    }
    .mesh-nav button:hover { background: #edf1f2; }
    .mesh-nav button.active { background: #dff3ef; color: #05645d; }
    .mesh-main { min-width: 0; padding: 28px clamp(18px, 4vw, 52px) 52px; }
    .mesh-page { width: min(1180px, 100%); margin: 0 auto; }
    .mesh-page-header { display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; margin-bottom: 24px; }
    .mesh-page-header h1 { margin-bottom: 6px; font-size: 24px; line-height: 1.25; }
    .mesh-page-header p { margin-bottom: 0; font-size: 14px; }
    .mesh-stats { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin-bottom: 22px; }
    .mesh-stat {
      min-width: 0;
      border: 1px solid #d4dcde;
      border-radius: 6px;
      background: #ffffff;
      padding: 16px;
    }
    .mesh-stat-label { margin-bottom: 7px; color: #68777d; font-size: 12px; font-weight: 700; text-transform: uppercase; }
    .mesh-stat-value { overflow: hidden; color: #172126; font-size: 17px; font-weight: 760; text-overflow: ellipsis; white-space: nowrap; }
    .mesh-panel {
      border: 1px solid #d4dcde;
      border-radius: 6px;
      background: #ffffff;
      margin-bottom: 18px;
    }
    .mesh-panel-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      min-height: 52px;
      border-bottom: 1px solid #e0e6e8;
      padding: 10px 16px;
    }
    .mesh-panel-head h2 { margin: 0; font-size: 15px; }
    .mesh-panel-body { min-width: 0; padding: 16px; }
    .mesh-table-wrap { width: 100%; overflow: auto; }
    .mesh-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .mesh-table th, .mesh-table td {
      max-width: 520px;
      border-bottom: 1px solid #e3e8e9;
      padding: 10px 12px;
      overflow-wrap: anywhere;
      text-align: left;
      vertical-align: top;
    }
    .mesh-table th { color: #52636a; background: #f7f9f9; font-size: 12px; font-weight: 740; }
    .mesh-table tr:last-child td { border-bottom: 0; }
    .mesh-code { font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace; }
    .mesh-empty { padding: 28px 16px; color: #6b797f; text-align: center; font-size: 13px; }
    .mesh-sql-actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 12px; }
    .mesh-query-meta { color: #6b797f; font-size: 12px; }
    .mesh-engine { margin: 0; white-space: pre-wrap; word-break: break-word; color: #405158; font-size: 12px; line-height: 1.55; }
    .mesh-loading { display: inline-flex; align-items: center; gap: 8px; color: #607078; font-size: 13px; }
    .mesh-loading::before {
      content: '';
      width: 12px;
      height: 12px;
      border: 2px solid #c4ced1;
      border-top-color: #087f74;
      border-radius: 50%;
      animation: mesh-spin 700ms linear infinite;
    }
    @keyframes mesh-spin { to { transform: rotate(360deg); } }
    @media (max-width: 860px) {
      .mesh-layout { grid-template-columns: 1fr; }
      .mesh-sidebar { position: sticky; top: 58px; z-index: 8; border-right: 0; border-bottom: 1px solid #d4dcde; padding: 8px 12px; }
      .mesh-nav { grid-template-columns: repeat(3, 1fr); }
      .mesh-nav button { text-align: center; }
      .mesh-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .mesh-main { padding-top: 22px; }
    }
    @media (max-width: 560px) {
      .mesh-login-panel { padding: 23px 19px; }
      .mesh-topbar { padding: 0 12px; }
      .mesh-brand-name { display: none; }
      .mesh-identity-text { max-width: 145px; }
      .mesh-stats { grid-template-columns: 1fr; }
      .mesh-page-header { align-items: stretch; flex-direction: column; }
      .mesh-page-header .mesh-button { width: 100%; }
      .mesh-sql-actions { align-items: stretch; flex-direction: column-reverse; }
      .mesh-sql-actions .mesh-button { width: 100%; }
    }
  `;
  document.head.appendChild(style);

  function setStoredSession() {
    try {
      if (!state.session) {
        sessionStorage.removeItem(storageKey);
        return;
      }
      sessionStorage.setItem(storageKey, JSON.stringify({
        session: state.session,
        username: state.username,
        database: state.database,
      }));
    } catch (_) {
      // A functioning console does not depend on browser storage availability.
    }
  }

  function restoreSession() {
    try {
      const value = JSON.parse(sessionStorage.getItem(storageKey) || 'null');
      if (value && typeof value.session === 'string' && value.session) {
        state.session = value.session;
        state.username = typeof value.username === 'string' ? value.username : '';
        state.database = typeof value.database === 'string' && value.database ? value.database : 'defaultdb';
      }
    } catch (_) {
      sessionStorage.removeItem(storageKey);
    }
  }

  function htmlEscape(value) {
    return String(value)
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#039;');
  }

  function readableError(error) {
    if (error instanceof Error && error.message) return error.message;
    return String(error || 'Request failed');
  }

  async function request(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (state.session) headers.set('X-Cockroach-API-Session', state.session);
    const response = await fetch(path, { ...options, headers });
    if (response.status === 401 && path !== '/api/v2/login/') {
      state.session = '';
      setStoredSession();
      renderLogin('Your console session has expired.');
      throw new Error('Your console session has expired.');
    }
    if (!response.ok) {
      const message = (await response.text()).trim();
      throw new Error(message || `Request failed with status ${response.status}.`);
    }
    const contentType = response.headers.get('content-type') || '';
    return contentType.includes('application/json') ? response.json() : response.text();
  }

  async function executeSql(sql, timeout = '15s') {
    const payload = await request('/api/v2/sql/', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        execute: true,
        database: state.database,
        application_name: '$ r1-meshdb-console',
        timeout,
        max_result_size: 4 * 1024 * 1024,
        statements: [{ sql }],
      }),
    });
    if (payload.error) throw new Error(payload.error.message || 'SQL execution failed.');
    const result = payload.execution && payload.execution.txn_results && payload.execution.txn_results[0];
    if (!result) throw new Error('SQL execution returned no result.');
    if (result.error) throw new Error(result.error.message || 'SQL execution failed.');
    return { ...result, retries: payload.execution.retries || 0 };
  }

  function renderLogin(message = '') {
    state.view = 'overview';
    root.innerHTML = `
      <div class="mesh-app mesh-login" data-r1-meshdb-console="login">
        <header class="mesh-login-brand">
          <span class="mesh-mark" aria-hidden="true">R1</span>
          <span>R1 MeshDB</span>
        </header>
        <main class="mesh-login-main">
          <form class="mesh-login-panel" id="mesh-login-form">
            <p class="mesh-kicker">Database console</p>
            <h1>Sign in to your cluster</h1>
            <p class="mesh-muted">Secure access to this MeshDB deployment.</p>
            <div class="mesh-error" id="mesh-login-error" ${message ? '' : 'hidden'}>${htmlEscape(message)}</div>
            <div class="mesh-field">
              <label for="mesh-username">User</label>
              <input class="mesh-input" id="mesh-username" name="username" autocomplete="username" required>
            </div>
            <div class="mesh-field">
              <label for="mesh-password">Password</label>
              <input class="mesh-input" id="mesh-password" name="password" type="password" autocomplete="current-password" required>
            </div>
            <div class="mesh-field">
              <label for="mesh-database">Database</label>
              <input class="mesh-input mesh-code" id="mesh-database" name="database" value="${htmlEscape(state.database)}" autocomplete="off" required>
            </div>
            <button class="mesh-button full" id="mesh-login-button" type="submit">Sign in</button>
          </form>
        </main>
        <footer class="mesh-login-footer">R1 MeshDB Console</footer>
      </div>
    `;
    document.getElementById('mesh-login-form').addEventListener('submit', login);
    document.getElementById('mesh-username').focus();
  }

  async function login(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const username = String(form.get('username') || '').trim();
    const password = String(form.get('password') || '');
    const database = String(form.get('database') || '').trim();
    const errorBox = document.getElementById('mesh-login-error');
    const button = document.getElementById('mesh-login-button');
    errorBox.hidden = true;
    button.disabled = true;
    button.textContent = 'Signing in...';
    try {
      const body = new URLSearchParams({ username, password });
      const response = await request('/api/v2/login/', {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body,
      });
      if (!response.session) throw new Error('The server returned an invalid session.');
      state.session = response.session;
      state.username = username;
      state.database = database;
      setStoredSession();
      renderShell();
      await loadOverview();
    } catch (error) {
      state.session = '';
      setStoredSession();
      errorBox.textContent = readableError(error);
      errorBox.hidden = false;
      button.disabled = false;
      button.textContent = 'Sign in';
    }
  }

  function renderShell() {
    root.innerHTML = `
      <div class="mesh-app mesh-shell" data-r1-meshdb-console="authenticated">
        <header class="mesh-topbar">
          <div class="mesh-brand">
            <span class="mesh-mark" aria-hidden="true">R1</span>
            <span class="mesh-brand-name">R1 MeshDB Console</span>
          </div>
          <div class="mesh-top-actions">
            <div class="mesh-identity" title="${htmlEscape(`${state.username} / ${state.database}`)}">
              <span class="mesh-status-dot" aria-hidden="true"></span>
              <span class="mesh-identity-text mesh-code">${htmlEscape(state.username)} / ${htmlEscape(state.database)}</span>
            </div>
            <button class="mesh-button quiet" id="mesh-logout" type="button">Sign out</button>
          </div>
        </header>
        <div class="mesh-layout">
          <aside class="mesh-sidebar">
            <nav class="mesh-nav" aria-label="Console sections">
              <button type="button" data-view="overview">Overview</button>
              <button type="button" data-view="tables">Tables</button>
              <button type="button" data-view="sql">SQL</button>
            </nav>
          </aside>
          <main class="mesh-main"><div class="mesh-page" id="mesh-page"></div></main>
        </div>
      </div>
    `;
    document.getElementById('mesh-logout').addEventListener('click', logout);
    document.querySelectorAll('[data-view]').forEach((button) => {
      button.addEventListener('click', () => selectView(button.dataset.view));
    });
    setActiveView(state.view);
  }

  function setActiveView(view) {
    document.querySelectorAll('[data-view]').forEach((button) => {
      const active = button.dataset.view === view;
      button.classList.toggle('active', active);
      if (active) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    });
  }

  async function selectView(view) {
    if (!['overview', 'tables', 'sql'].includes(view)) return;
    state.view = view;
    setActiveView(view);
    if (view === 'overview') await loadOverview();
    if (view === 'tables') await loadTables();
    if (view === 'sql') renderSql();
  }

  function pageHeader(title, subtitle, action = '') {
    return `
      <div class="mesh-page-header">
        <div><h1>${htmlEscape(title)}</h1><p class="mesh-muted">${htmlEscape(subtitle)}</p></div>
        ${action}
      </div>
    `;
  }

  function loadingPanel(label) {
    return `<section class="mesh-panel"><div class="mesh-panel-body"><span class="mesh-loading">${htmlEscape(label)}</span></div></section>`;
  }

  function resultRows(result) {
    return Array.isArray(result && result.rows) ? result.rows : [];
  }

  function firstRow(result) {
    return resultRows(result)[0] || {};
  }

  function valueText(value) {
    if (value === null || value === undefined) return 'NULL';
    if (typeof value === 'object') return JSON.stringify(value);
    return String(value);
  }

  function renderDataTable(result, emptyText = 'No rows returned.') {
    const rows = resultRows(result);
    const columnNames = Array.isArray(result && result.columns) && result.columns.length
      ? result.columns.map((column) => column.name)
      : rows.length ? Object.keys(rows[0]) : [];
    if (!rows.length || !columnNames.length) {
      return `<div class="mesh-empty">${htmlEscape(emptyText)}</div>`;
    }
    const head = columnNames.map((name) => `<th scope="col">${htmlEscape(name)}</th>`).join('');
    const body = rows.map((row) => `<tr>${columnNames.map((name) => {
      const value = valueText(row[name]);
      return `<td class="mesh-code" title="${htmlEscape(value)}">${htmlEscape(value)}</td>`;
    }).join('')}</tr>`).join('');
    return `<div class="mesh-table-wrap"><table class="mesh-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }

  async function loadOverview() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    setActiveView('overview');
    page.innerHTML = pageHeader('Overview', state.database, '<button class="mesh-button secondary" id="mesh-refresh" type="button">Refresh</button>') + loadingPanel('Loading cluster data...');
    document.getElementById('mesh-refresh').addEventListener('click', loadOverview);
    try {
      const [identity, tables, health] = await Promise.all([
        executeSql('SELECT current_user AS username, current_database() AS database_name, version() AS engine_version'),
        executeSql("SELECT count(*) AS table_count FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema', 'crdb_internal')"),
        request('/api/v2/health/'),
      ]);
      const identityRow = firstRow(identity);
      const tableRow = firstRow(tables);
      state.username = valueText(identityRow.username || state.username);
      state.database = valueText(identityRow.database_name || state.database);
      setStoredSession();
      const engineVersion = valueText(identityRow.engine_version || 'Unavailable');
      page.innerHTML = pageHeader('Overview', state.database, '<button class="mesh-button secondary" id="mesh-refresh" type="button">Refresh</button>') + `
        <div class="mesh-stats">
          <div class="mesh-stat"><div class="mesh-stat-label">Status</div><div class="mesh-stat-value">Healthy</div></div>
          <div class="mesh-stat"><div class="mesh-stat-label">Database</div><div class="mesh-stat-value mesh-code">${htmlEscape(state.database)}</div></div>
          <div class="mesh-stat"><div class="mesh-stat-label">User</div><div class="mesh-stat-value mesh-code">${htmlEscape(state.username)}</div></div>
          <div class="mesh-stat"><div class="mesh-stat-label">Tables</div><div class="mesh-stat-value">${htmlEscape(valueText(tableRow.table_count || 0))}</div></div>
        </div>
        <section class="mesh-panel">
          <div class="mesh-panel-head"><h2>Engine</h2></div>
          <div class="mesh-panel-body"><p class="mesh-engine mesh-code">${htmlEscape(engineVersion)}</p></div>
        </section>
      `;
      void health;
      document.getElementById('mesh-refresh').addEventListener('click', loadOverview);
    } catch (error) {
      if (!state.session) return;
      page.innerHTML = pageHeader('Overview', state.database, '<button class="mesh-button secondary" id="mesh-refresh" type="button">Retry</button>') + `<div class="mesh-error">${htmlEscape(readableError(error))}</div>`;
      document.getElementById('mesh-refresh').addEventListener('click', loadOverview);
    }
  }

  async function loadTables() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    setActiveView('tables');
    page.innerHTML = pageHeader('Tables', state.database, '<button class="mesh-button secondary" id="mesh-refresh-tables" type="button">Refresh</button>') + loadingPanel('Loading tables...');
    document.getElementById('mesh-refresh-tables').addEventListener('click', loadTables);
    try {
      const result = await executeSql("SELECT table_schema AS schema, table_name AS table FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema', 'crdb_internal') ORDER BY table_schema, table_name LIMIT 500");
      page.innerHTML = pageHeader('Tables', state.database, '<button class="mesh-button secondary" id="mesh-refresh-tables" type="button">Refresh</button>') + `
        <section class="mesh-panel">
          <div class="mesh-panel-head"><h2>Objects</h2><span class="mesh-query-meta">${resultRows(result).length} rows</span></div>
          ${renderDataTable(result, 'No user tables found in this database.')}
        </section>
      `;
      document.getElementById('mesh-refresh-tables').addEventListener('click', loadTables);
    } catch (error) {
      if (!state.session) return;
      page.innerHTML = pageHeader('Tables', state.database, '<button class="mesh-button secondary" id="mesh-refresh-tables" type="button">Retry</button>') + `<div class="mesh-error">${htmlEscape(readableError(error))}</div>`;
      document.getElementById('mesh-refresh-tables').addEventListener('click', loadTables);
    }
  }

  function renderSql() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    setActiveView('sql');
    page.innerHTML = pageHeader('SQL', state.database) + `
      <section class="mesh-panel">
        <div class="mesh-panel-head"><h2>Query</h2></div>
        <div class="mesh-panel-body">
          <div class="mesh-error" id="mesh-sql-error" hidden></div>
          <label class="mesh-field" for="mesh-query"><span>Statement</span></label>
          <textarea class="mesh-textarea" id="mesh-query" spellcheck="false">SELECT current_timestamp AS now;</textarea>
          <div class="mesh-sql-actions">
            <span class="mesh-query-meta" id="mesh-query-meta">Ready</span>
            <button class="mesh-button" id="mesh-run-query" type="button">Run query</button>
          </div>
        </div>
      </section>
      <section class="mesh-panel" id="mesh-results" hidden>
        <div class="mesh-panel-head"><h2>Result</h2><span class="mesh-query-meta" id="mesh-result-meta"></span></div>
        <div id="mesh-result-body"></div>
      </section>
    `;
    document.getElementById('mesh-run-query').addEventListener('click', runQuery);
    document.getElementById('mesh-query').focus();
  }

  async function runQuery() {
    const editor = document.getElementById('mesh-query');
    const button = document.getElementById('mesh-run-query');
    const errorBox = document.getElementById('mesh-sql-error');
    const meta = document.getElementById('mesh-query-meta');
    const panel = document.getElementById('mesh-results');
    const sql = editor.value.trim();
    if (!sql) {
      errorBox.textContent = 'Enter a SQL statement.';
      errorBox.hidden = false;
      return;
    }
    errorBox.hidden = true;
    panel.hidden = true;
    button.disabled = true;
    button.textContent = 'Running...';
    meta.textContent = 'Executing';
    const started = performance.now();
    try {
      const result = await executeSql(sql, '30s');
      const elapsed = Math.max(0, performance.now() - started);
      document.getElementById('mesh-result-body').innerHTML = renderDataTable(result, `${result.rows_affected || 0} rows affected.`);
      document.getElementById('mesh-result-meta').textContent = `${result.tag || 'SQL'} / ${resultRows(result).length} rows / ${elapsed.toFixed(0)} ms / ${result.retries} retries`;
      meta.textContent = 'Completed';
      panel.hidden = false;
    } catch (error) {
      if (!state.session) return;
      errorBox.textContent = readableError(error);
      errorBox.hidden = false;
      meta.textContent = 'Failed';
    } finally {
      button.disabled = false;
      button.textContent = 'Run query';
    }
  }

  async function logout() {
    const session = state.session;
    state.session = '';
    setStoredSession();
    if (session) {
      state.session = session;
      try {
        await request('/api/v2/logout/', { method: 'POST' });
      } catch (_) {
        // Local session removal is authoritative for the browser.
      }
      state.session = '';
      setStoredSession();
    }
    renderLogin();
  }

  restoreSession();
  if (state.session) {
    renderShell();
    loadOverview();
  } else {
    renderLogin();
  }
})();
