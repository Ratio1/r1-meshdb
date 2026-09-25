// Copyright 2026 Ratio1
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

(() => {
  'use strict';

  const root = document.getElementById('react-layout');
  if (!root) return;

  const storageKey = 'r1-meshdb-console-session-v1';
  const defaultQuery = 'SELECT current_timestamp AS now;';
  const state = {
    session: '',
    username: '',
    database: 'defaultdb',
    databaseRevision: 0,
    view: 'overview',
    busy: false,
    capabilities: {
      loaded: false,
      canViewAccess: false,
      canCreateUser: false,
      canCreateDatabase: false,
    },
    databases: [],
    tableResult: null,
    tableRequestRevision: 0,
    tablePage: 0,
    tablePageSize: 25,
    tableCreate: {
      open: false,
      schema: 'public',
      name: '',
      columns: [
        { name: 'id', type: 'UUID', nullable: false, primaryKey: true, default: 'uuid' },
      ],
    },
    queryResult: null,
    queryDraft: defaultQuery,
    queryPage: 0,
    queryPageSize: 25,
    manage: {
      activeSection: 'databases',
      users: [],
      databases: [],
      tablesByDatabase: {},
      selectedUser: '',
      selectedDatabase: '',
      selectedScope: 'database',
      selectedTable: '',
      selectedPreset: 'viewer',
      selectedPermissionUser: '',
      deleteUserStatus: '',
      deleteUserError: false,
      permissions: [],
      permissionsLoading: false,
      permissionError: '',
      permissionPage: 0,
      permissionPageSize: 25,
      userPage: 0,
      userPageSize: 25,
      usersRequestRevision: 0,
      permissionRequestRevision: 0,
      initialAccessRevision: 0,
      accessSelectionRevision: 0,
    },
  };

  const style = document.createElement('style');
  style.textContent = `
    :root {
      color-scheme: light;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f7f9fa;
      color: #172126;
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-width: 320px; min-height: 100vh; background: #f7f9fa; }
    button, input, textarea { font: inherit; letter-spacing: 0; }
    button { cursor: pointer; }
    button:disabled { cursor: not-allowed; opacity: 0.62; }
    button:focus-visible, select:focus-visible, input:focus-visible, textarea:focus-visible {
      outline: 2px solid #087f74;
      outline-offset: 2px;
    }
    [hidden] { display: none !important; }
    .mesh-app { min-height: 100vh; }
    .mesh-login {
      min-height: 100vh;
      display: grid;
      grid-template-rows: auto 1fr auto;
      background: #f7f9fa;
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
    .mesh-field { display: grid; align-content: start; gap: 7px; margin-bottom: 16px; }
    .mesh-field label, .mesh-field-label { font-size: 12px; font-weight: 690; color: #304047; }
    .mesh-input, .mesh-textarea {
      width: 100%;
      border: 1px solid #bdc8cc;
      border-radius: 4px;
      background: #ffffff;
      color: #172126;
      outline: none;
      transition: border-color 120ms ease, box-shadow 120ms ease;
    }
    .mesh-input { min-height: 38px; padding: 7px 10px; }
    .mesh-input[multiple] { min-height: 104px; }
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
      min-height: 36px;
      border: 1px solid transparent;
      border-radius: 4px;
      padding: 7px 12px;
      background: #087f74;
      color: #ffffff;
      font-weight: 660;
    }
    .mesh-button:hover:not(:disabled) { background: #066c63; }
    .mesh-button.secondary { border-color: #bdc8cc; background: #ffffff; color: #26353b; }
    .mesh-button.secondary:hover:not(:disabled) { background: #edf1f2; }
    .mesh-button.danger { border-color: #ba3b35; background: #ffffff; color: #a32d28; }
    .mesh-button.danger:hover:not(:disabled) { background: #fff0ef; }
    .mesh-button.danger.solid { background: #ba3b35; color: #ffffff; }
    .mesh-button.danger.solid:hover:not(:disabled) { background: #a32d28; }
    .mesh-button.quiet { min-height: 34px; background: transparent; color: #405158; padding: 6px 9px; }
    .mesh-button.quiet:hover:not(:disabled) { background: #e8edee; }
    #mesh-logout { flex: 0 0 auto; white-space: nowrap; }
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
    .mesh-top-actions { display: flex; align-items: center; gap: 14px; min-width: 0; }
    .mesh-db-switcher { display: flex; align-items: center; gap: 7px; min-width: 0; }
    .mesh-db-switcher-label { color: #68777d; font-size: 11px; font-weight: 760; text-transform: uppercase; }
    .mesh-db-select { min-height: 34px; max-width: 240px; padding: 5px 9px; }
    .mesh-identity {
      display: flex;
      align-items: center;
      gap: 8px;
      min-width: 0;
      color: #52636a;
      font-size: 13px;
    }
    .mesh-status-dot { width: 8px; height: 8px; border-radius: 50%; background: #178d55; flex: 0 0 auto; }
    .mesh-identity-text { max-width: 170px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mesh-layout { display: grid; grid-template-columns: 196px minmax(0, 1fr); min-height: 0; }
    .mesh-sidebar {
      border-right: 1px solid #d4dcde;
      background: #f7f9fa;
      padding: 25px 10px;
    }
    .mesh-nav-label { padding: 0 12px 11px; color: #7a878c; font-size: 11px; font-weight: 740; text-transform: uppercase; }
    .mesh-nav { display: grid; gap: 5px; }
    .mesh-nav button {
      min-height: 36px;
      border: 0;
      border-left: 3px solid transparent;
      border-radius: 0 4px 4px 0;
      background: transparent;
      color: #405158;
      padding: 7px 10px;
      text-align: left;
      font-weight: 570;
    }
    .mesh-nav button:hover { background: #edf1f2; }
    .mesh-nav button.active { border-left-color: #087f74; background: #e7f3f1; color: #075d55; font-weight: 680; }
    .mesh-main { min-width: 0; padding: 30px clamp(20px, 3vw, 42px) 64px; background: #ffffff; }
    .mesh-page { width: min(1240px, 100%); margin: 0 auto; }
    .mesh-page-header { display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; border-bottom: 1px solid #dfe5e7; padding-bottom: 18px; margin-bottom: 24px; }
    .mesh-page-header h1 { margin-bottom: 4px; font-size: 22px; line-height: 1.25; font-weight: 710; }
    .mesh-page-header p { margin-bottom: 0; font-size: 13px; }
    .mesh-header-actions { display: flex; align-items: center; gap: 8px; }
    .mesh-stats { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); border: 1px solid #dfe5e7; margin-bottom: 30px; }
    .mesh-stat {
      min-width: 0;
      border-right: 1px solid #dfe5e7;
      background: #f9fbfb;
      padding: 14px 16px;
    }
    .mesh-stat:last-child { border-right: 0; }
    .mesh-stat-label { margin-bottom: 7px; color: #68777d; font-size: 12px; font-weight: 700; text-transform: uppercase; }
    .mesh-stat-value { overflow: hidden; color: #172126; font-size: 17px; font-weight: 760; text-overflow: ellipsis; white-space: nowrap; }
    .mesh-panel { margin-bottom: 28px; }
    .mesh-panel-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      min-height: 36px;
      border-bottom: 1px solid #e0e6e8;
      padding: 0 0 10px;
    }
    .mesh-panel-head h2 { margin: 0; font-size: 15px; }
    .mesh-panel-body { min-width: 0; padding: 16px 0 0; }
    .mesh-table-wrap { width: 100%; max-height: 440px; overflow: auto; border: 1px solid #e0e6e8; border-top: 0; }
    .mesh-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    #mesh-permission-table .mesh-table { min-width: 720px; }
    .mesh-table th, .mesh-table td {
      max-width: 520px;
      border-bottom: 1px solid #e3e8e9;
      padding: 9px 12px;
      overflow-wrap: anywhere;
      text-align: left;
      vertical-align: top;
    }
    .mesh-table th { position: sticky; top: 0; z-index: 1; color: #52636a; background: #f7f9f9; font-size: 11px; font-weight: 740; }
    .mesh-table tbody tr:hover { background: #f8fbfa; }
    .mesh-table tr:last-child td { border-bottom: 0; }
    .mesh-code { font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace; }
    .mesh-empty { padding: 32px 16px; color: #6b797f; text-align: center; font-size: 13px; }
    .mesh-pagination { display: flex; align-items: center; justify-content: space-between; gap: 12px; border: 1px solid #e0e6e8; border-top: 0; padding: 8px 12px; color: #68777d; font-size: 12px; }
    .mesh-pagination-actions { display: flex; align-items: center; gap: 6px; }
    .mesh-pagination .mesh-button { min-height: 30px; padding: 5px 9px; font-size: 12px; }
    .mesh-page-size { display: inline-flex; align-items: center; gap: 6px; }
    .mesh-page-size select { min-height: 30px; border: 1px solid #bdc8cc; border-radius: 5px; background: #fff; padding: 4px 6px; color: #26353b; }
    .mesh-form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 14px; }
    .mesh-form-grid .mesh-field-full { grid-column: 1 / -1; }
    .mesh-form-actions { display: flex; align-items: center; justify-content: flex-end; gap: 10px; margin-top: 4px; }
    [data-manage-tab] { font: inherit; }
    .mesh-task-tabs { display: flex; gap: 20px; border-bottom: 1px solid #dfe5e7; margin-bottom: 27px; overflow-x: auto; }
    .mesh-task-tabs button { flex: 0 0 auto; min-height: 42px; border: 0; border-bottom: 2px solid transparent; background: transparent; color: #607078; padding: 9px 2px; font-size: 13px; font-weight: 620; }
    .mesh-task-tabs button[aria-selected="true"] { border-bottom-color: #087f74; color: #075d55; }
    .mesh-task-tabs button:hover:not([aria-selected="true"]) { color: #172126; }
    [role="tabpanel"] form { max-width: 850px; }
    .mesh-database-picker { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); align-content: start; gap: 2px; min-height: 90px; max-height: 154px; overflow: auto; border: 1px solid #bdc8cc; border-radius: 4px; padding: 4px; background: #ffffff; }
    #mesh-access-database { grid-template-columns: repeat(4, minmax(0, 1fr)); min-height: 46px; }
    .mesh-database-option { display: flex; align-items: center; gap: 8px; min-width: 0; min-height: 34px; margin: 0; padding: 5px 7px; border-radius: 3px; font-size: 12px; font-weight: 500; overflow-wrap: anywhere; cursor: pointer; }
    .mesh-database-option:hover { background: #f2f6f6; }
    .mesh-database-option:has(input:checked) { background: #e7f3f1; color: #075d55; }
    .mesh-database-option input { flex: 0 0 auto; margin: 0; accent-color: #087f74; }
    .mesh-database-option input:disabled { cursor: not-allowed; }
    .mesh-database-picker:has(input:disabled) { background: #f6f8f8; }
    #mesh-initial-access-fields { margin-top: 16px; }
    .mesh-user-actions { display: flex; align-items: end; gap: 12px; }
    .mesh-user-actions .mesh-field { flex: 1 1 auto; min-width: 0; }
    .mesh-user-actions .mesh-button { flex: 0 0 auto; margin-bottom: 16px; }
    .mesh-delete-confirm { border-top: 1px solid #e0e6e8; margin: 0 0 16px; padding-top: 16px; }
    .mesh-delete-confirm h3 { margin: 0 0 7px; font-size: 14px; }
    .mesh-delete-confirm p { color: #52636a; font-size: 13px; line-height: 1.45; }
    .mesh-column-editor { border-top: 1px solid #e0e6e8; margin-top: 4px; padding-top: 16px; }
    .mesh-column-editor-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
    .mesh-column-editor-head h3 { margin: 0; font-size: 14px; }
    .mesh-column-row { display: grid; grid-template-columns: minmax(150px, 1.3fr) minmax(125px, 1fr) minmax(130px, 1fr) auto auto auto; align-items: end; gap: 10px; border-bottom: 1px solid #edf0f1; padding: 10px 0; }
    .mesh-column-row:last-child { border-bottom: 0; }
    .mesh-column-row .mesh-field { margin-bottom: 0; }
    .mesh-column-row .mesh-checkbox { min-height: 42px; align-items: center; }
    .mesh-column-remove { min-height: 42px; padding: 8px 10px; }
    .mesh-column-add { margin-top: 12px; }
    .mesh-table-preview { border-top: 1px solid #e0e6e8; margin-top: 16px; padding-top: 16px; }
    .mesh-table-preview-head { margin-bottom: 8px; color: #52636a; font-size: 12px; font-weight: 740; }
    .mesh-table-preview pre { max-height: 220px; margin: 0; overflow: auto; }
    .mesh-fieldset { min-width: 0; border: 0; border-top: 1px solid #e0e6e8; margin: 6px 0 20px; padding: 16px 0 0; }
    .mesh-fieldset legend { padding: 0 8px 0 0; color: #304047; font-size: 13px; font-weight: 720; }
    .mesh-fieldset .mesh-field:last-child { margin-bottom: 0; }
    .mesh-checkbox { display: flex; align-items: flex-start; gap: 8px; color: #405158; font-size: 13px; line-height: 1.4; }
    .mesh-checkbox input { margin-top: 2px; accent-color: #087f74; }
    .mesh-access-note { margin: 0 0 14px; color: #68777d; font-size: 12px; line-height: 1.45; }
    .mesh-status { margin: 0 0 14px; border-left: 3px solid #087f74; background: #edf9f6; color: #05645d; padding: 10px 12px; font-size: 13px; line-height: 1.45; }
    .mesh-status.error { border-left-color: #ba3b35; background: #fff0ef; color: #7c2925; }
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
      .mesh-layout { grid-template-columns: minmax(0, 1fr); grid-template-rows: max-content minmax(0, 1fr); }
      .mesh-sidebar { position: sticky; top: 58px; z-index: 8; min-width: 0; border-right: 0; border-bottom: 1px solid #d4dcde; padding: 0 12px; }
      .mesh-nav-label { display: none; }
      .mesh-nav { display: flex; gap: 8px; overflow-x: auto; }
      .mesh-nav button { flex: 0 0 auto; min-height: 43px; border-left: 0; border-bottom: 2px solid transparent; border-radius: 0; padding: 9px 2px; white-space: nowrap; }
      .mesh-nav button.active { border-bottom-color: #087f74; background: transparent; }
      .mesh-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .mesh-stat { border-bottom: 1px solid #dfe5e7; }
      .mesh-main { padding-top: 23px; }
      .mesh-column-row { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .mesh-column-row .mesh-column-remove { width: 100%; }
    }
    @media (max-width: 560px) {
      .mesh-login-panel { padding: 23px 19px; }
      .mesh-topbar { gap: 8px; padding: 0 12px; }
      .mesh-top-actions { flex: 1 1 auto; gap: 8px; justify-content: flex-end; }
      .mesh-brand-name { display: none; }
      .mesh-identity-text { max-width: 50px; }
      .mesh-db-switcher { flex: 1 1 auto; }
      .mesh-db-switcher-label { display: none; }
      .mesh-db-select { min-width: 0; max-width: 130px; }
      #mesh-logout { padding: 6px 4px; font-size: 12px; }
      .mesh-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .mesh-page-header { align-items: stretch; flex-direction: column; }
      .mesh-header-actions { width: 100%; }
      .mesh-header-actions .mesh-button { flex: 1 1 auto; }
      .mesh-sql-actions { align-items: stretch; flex-direction: column-reverse; }
      .mesh-sql-actions .mesh-button { width: 100%; }
      .mesh-form-grid { grid-template-columns: 1fr; }
      .mesh-database-picker { grid-template-columns: 1fr; }
      #mesh-access-database { grid-template-columns: 1fr; }
      .mesh-user-actions { align-items: stretch; flex-direction: column; gap: 0; }
      .mesh-user-actions .mesh-button { align-self: flex-start; }
      .mesh-form-grid .mesh-field-full { grid-column: auto; }
      .mesh-column-row { grid-template-columns: 1fr; }
      .mesh-column-row .mesh-column-remove { width: 100%; }
      .mesh-pagination { align-items: stretch; flex-direction: column; }
      .mesh-pagination-actions { justify-content: space-between; }
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

  async function fetchPaged(path, key) {
    const values = [];
    let offset = 0;
    const separator = path.includes('?') ? '&' : '?';
    for (let page = 0; page < 20; page += 1) {
      const payload = await request(`${path}${separator}limit=500&offset=${offset}`);
      const batch = payload && payload[key];
      if (batch != null && !Array.isArray(batch)) throw new Error(`Invalid ${key} response.`);
      if (batch) values.push(...batch);
      const next = Number(payload && payload.next);
      if (!next) return values;
      if (!Number.isSafeInteger(next) || next <= offset) throw new Error(`Invalid ${key} pagination.`);
      offset = next;
    }
    const probe = await request(`${path}${separator}limit=1&offset=${offset}`);
    const extra = probe && probe[key];
    if (extra != null && !Array.isArray(extra)) throw new Error(`Invalid ${key} response.`);
    if (extra && extra.length) throw new Error(`Too many ${key} to display. The list exceeds 10,000 entries.`);
    return values;
  }

  async function fetchUsers() {
    const users = await fetchPaged('/api/v2/r1-meshdb/users/', 'users');
    return users.map((user) => {
      if (!user || typeof user.username !== 'string') throw new Error('Invalid users response.');
      return user.username;
    });
  }

  function renderDatabaseSelector(message = '') {
    const select = document.getElementById('mesh-database-select');
    if (!select) return;
    const databases = [...new Set(state.databases.filter(Boolean))];
    if (!databases.length) {
      select.innerHTML = `<option value="">${htmlEscape(message || 'No accessible databases')}</option>`;
      select.disabled = true;
      return;
    }
    select.innerHTML = databases.map((database) => `<option value="${htmlEscape(database)}">${htmlEscape(database)}</option>`).join('');
    select.value = databases.includes(state.database) ? state.database : databases[0];
    select.disabled = false;
  }

  async function loadDatabaseOptions() {
    try {
      state.databases = await fetchPaged('/api/v2/r1-meshdb/databases/', 'databases');
      let databaseChanged = false;
      if (!state.databases.includes(state.database) && state.databases.length) {
        state.database = state.databases[0];
        state.databaseRevision += 1;
        state.manage.selectedDatabase = state.database;
        state.manage.selectedTable = '';
        resetTableCreateState();
        databaseChanged = true;
      }
      setStoredSession();
      renderDatabaseSelector();
      updateDatabaseIdentity();
      if (databaseChanged) await selectView(state.view);
    } catch (error) {
      renderDatabaseSelector(readableError(error));
    }
  }

  function databaseRequestState() {
    return { database: state.database, revision: state.databaseRevision };
  }

  function isCurrentDatabase(requestState) {
    return requestState.database === state.database && requestState.revision === state.databaseRevision;
  }

  function updateDatabaseIdentity() {
    const identity = document.querySelector('.mesh-identity');
    const text = document.querySelector('.mesh-identity-text');
    if (!identity || !text) return;
    const value = `${state.username} / ${state.database}`;
    identity.title = value;
    text.textContent = state.username;
  }

  async function switchDatabase(event) {
    const database = String(event.currentTarget.value || '').trim();
    if (!database || database === state.database) return;
    state.databaseRevision += 1;
    state.database = database;
    state.manage.selectedDatabase = database;
    state.manage.selectedTable = '';
    resetTableCreateState();
    setStoredSession();
    updateDatabaseIdentity();
    await selectView(state.view);
  }

  function bindDatabaseSelector() {
    const select = document.getElementById('mesh-database-select');
    if (select) select.addEventListener('change', switchDatabase);
    renderDatabaseSelector('Loading databases...');
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
    state.queryDraft = defaultQuery;
    state.queryResult = null;
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
      state.capabilities = {
        loaded: false,
        canViewAccess: false,
        canCreateUser: false,
        canCreateDatabase: false,
      };
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
            <label class="mesh-db-switcher" for="mesh-database-select">
              <span class="mesh-db-switcher-label">Database</span>
              <select class="mesh-input mesh-db-select mesh-code" id="mesh-database-select" aria-label="Active database">
                <option value="">Loading databases...</option>
              </select>
            </label>
            <div class="mesh-identity" title="${htmlEscape(`${state.username} / ${state.database}`)}">
              <span class="mesh-status-dot" aria-hidden="true"></span>
              <span class="mesh-identity-text mesh-code">${htmlEscape(state.username)}</span>
            </div>
            <button class="mesh-button quiet" id="mesh-logout" type="button">Sign out</button>
          </div>
        </header>
        <div class="mesh-layout">
          <aside class="mesh-sidebar">
            <div class="mesh-nav-label">Workspace</div>
            <nav class="mesh-nav" aria-label="Console sections">
              <button type="button" data-view="overview">Overview</button>
              <button type="button" data-view="tables">Tables</button>
              <button type="button" data-view="sql">SQL</button>
              <button type="button" data-view="users" aria-label="Users and access" hidden>Users</button>
              <button type="button" data-view="manage" hidden>Manage</button>
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
    bindDatabaseSelector();
    void loadDatabaseOptions();
    void loadCapabilities();
    setActiveView(state.view);
  }

  function canAccessManage() {
    return state.capabilities.canViewAccess || state.capabilities.canCreateDatabase;
  }

  function updatePrivilegedNavigation() {
    const usersButton = document.querySelector('[data-view="users"]');
    const manageButton = document.querySelector('[data-view="manage"]');
    if (usersButton) usersButton.hidden = !state.capabilities.canViewAccess;
    if (manageButton) manageButton.hidden = !canAccessManage();
  }

  async function loadCapabilities() {
    try {
      const response = await request('/api/v2/r1-meshdb/capabilities/');
      state.capabilities = {
        loaded: true,
        canViewAccess: response.can_view_access === true,
        canCreateUser: response.can_create_user === true,
        canCreateDatabase: response.can_create_database === true,
      };
    } catch (_) {
      state.capabilities.loaded = true;
    }
    updatePrivilegedNavigation();
    if ((state.view === 'users' && !state.capabilities.canViewAccess) ||
        (state.view === 'manage' && !canAccessManage())) {
      state.view = 'overview';
      await loadOverview();
    }
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
    if (!['overview', 'tables', 'sql', 'users', 'manage'].includes(view)) return;
    if (view === 'users' && !state.capabilities.canViewAccess) return;
    if (view === 'manage' && !canAccessManage()) return;
    state.view = view;
    setActiveView(view);
    if (view === 'overview') await loadOverview();
    if (view === 'tables') await loadTables();
    if (view === 'sql') renderSql();
    if (view === 'users') await loadUsersAccess();
    if (view === 'manage') await loadManage();
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

  function renderDataTable(result, emptyText = 'No rows returned.', options = {}) {
    const rows = resultRows(result);
    const columnNames = Array.isArray(result && result.columns) && result.columns.length
      ? result.columns.map((column) => column.name)
      : rows.length ? Object.keys(rows[0]) : [];
    if (!rows.length || !columnNames.length) {
      return `<div class="mesh-empty">${htmlEscape(emptyText)}</div>`;
    }
    const pageSize = Math.max(1, Number(options.pageSize) || 25);
    const pageCount = Math.max(1, Math.ceil(rows.length / pageSize));
    const page = Math.min(Math.max(0, Number(options.page) || 0), pageCount - 1);
    const start = page * pageSize;
    const visibleRows = rows.slice(start, start + pageSize);
    const head = columnNames.map((name) => `<th scope="col">${htmlEscape(name)}</th>`).join('');
    const body = visibleRows.map((row) => `<tr>${columnNames.map((name) => {
      const value = valueText(row[name]);
      return `<td class="mesh-code" title="${htmlEscape(value)}">${htmlEscape(value)}</td>`;
    }).join('')}</tr>`).join('');
    const end = Math.min(rows.length, start + visibleRows.length);
    const pagination = pageCount > 1 || options.showPageSize ? `
      <div class="mesh-pagination" data-mesh-pagination>
        <span>Showing ${start + 1}-${end} of ${rows.length} rows</span>
        <div class="mesh-pagination-actions">
          <label class="mesh-page-size">Rows <select data-mesh-page-size aria-label="Rows per page">
            ${[25, 50, 100].map((size) => `<option value="${size}" ${size === pageSize ? 'selected' : ''}>${size}</option>`).join('')}
          </select></label>
          <button class="mesh-button secondary" type="button" data-mesh-page="${page - 1}" ${page === 0 ? 'disabled' : ''}>Previous</button>
          <span>Page ${page + 1} of ${pageCount}</span>
          <button class="mesh-button secondary" type="button" data-mesh-page="${page + 1}" ${page >= pageCount - 1 ? 'disabled' : ''}>Next</button>
        </div>
      </div>
    ` : '';
    return `<div class="mesh-table-wrap"><table class="mesh-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>${pagination}`;
  }

  function bindTablePagination(container, onPage, onPageSize) {
    if (!container) return;
    container.querySelectorAll('[data-mesh-page]').forEach((button) => {
      button.addEventListener('click', () => onPage(Number(button.dataset.meshPage)));
    });
    const pageSize = container.querySelector('[data-mesh-page-size]');
    if (pageSize && onPageSize) pageSize.addEventListener('change', () => onPageSize(Number(pageSize.value)));
  }

  async function loadOverview() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    const requestState = databaseRequestState();
    setActiveView('overview');
    page.innerHTML = pageHeader('Overview', state.database, '<button class="mesh-button secondary" id="mesh-refresh" type="button">Refresh</button>') + loadingPanel('Loading cluster data...');
    document.getElementById('mesh-refresh').addEventListener('click', loadOverview);
    try {
      const [identity, tables, health, imageVersionResponse, recentTables] = await Promise.all([
        executeSql('SELECT current_user AS username, current_database() AS database_name, version() AS engine_version'),
        executeSql("SELECT count(*) AS table_count FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema', 'crdb_internal')"),
        request('/api/v2/health/'),
        request('/api/v2/r1-meshdb/version/').catch((error) => {
          if (!state.session) throw error;
          return { version: '' };
        }),
        executeSql("SELECT table_schema AS schema, table_name AS table FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema', 'crdb_internal') ORDER BY table_schema, table_name LIMIT 6").catch((error) => {
          if (!state.session) throw error;
          return null;
        }),
      ]);
      if (!isCurrentDatabase(requestState) || state.view !== 'overview') return;
      const identityRow = firstRow(identity);
      const tableRow = firstRow(tables);
      state.username = valueText(identityRow.username || state.username);
      state.database = valueText(identityRow.database_name || state.database);
      setStoredSession();
      updateDatabaseIdentity();
      renderDatabaseSelector();
      const engineVersion = valueText(identityRow.engine_version || 'Unavailable');
      const imageVersion = valueText(imageVersionResponse && imageVersionResponse.version || 'Unavailable');
      page.innerHTML = pageHeader('Overview', state.database, '<button class="mesh-button secondary" id="mesh-refresh" type="button">Refresh</button>') + `
        <div class="mesh-stats">
          <div class="mesh-stat"><div class="mesh-stat-label">Local node</div><div class="mesh-stat-value">Responding</div></div>
          <div class="mesh-stat"><div class="mesh-stat-label">Database</div><div class="mesh-stat-value mesh-code">${htmlEscape(state.database)}</div></div>
          <div class="mesh-stat"><div class="mesh-stat-label">User</div><div class="mesh-stat-value mesh-code">${htmlEscape(state.username)}</div></div>
          <div class="mesh-stat"><div class="mesh-stat-label">Tables</div><div class="mesh-stat-value">${htmlEscape(valueText(tableRow.table_count || 0))}</div></div>
          <div class="mesh-stat"><div class="mesh-stat-label">Image</div><div class="mesh-stat-value mesh-code">${htmlEscape(imageVersion === 'Unavailable' ? imageVersion : `v${imageVersion}`)}</div></div>
        </div>
        ${recentTables ? `<section class="mesh-panel">
          <div class="mesh-panel-head"><h2>Tables</h2><button class="mesh-button secondary" id="mesh-open-tables" type="button">View all</button></div>
          ${renderDataTable(recentTables, 'No user tables found in this database.', { pageSize: 6 })}
        </section>` : ''}
        <section class="mesh-panel">
          <div class="mesh-panel-head"><h2>Engine</h2></div>
          <div class="mesh-panel-body"><p class="mesh-engine mesh-code">${htmlEscape(engineVersion)}</p></div>
        </section>
      `;
      void health;
      document.getElementById('mesh-refresh').addEventListener('click', loadOverview);
      document.getElementById('mesh-open-tables')?.addEventListener('click', () => { void selectView('tables'); });
    } catch (error) {
      if (!state.session || !isCurrentDatabase(requestState) || state.view !== 'overview') return;
      page.innerHTML = pageHeader('Overview', state.database, '<button class="mesh-button secondary" id="mesh-refresh" type="button">Retry</button>') + `<div class="mesh-error">${htmlEscape(readableError(error))}</div>`;
      document.getElementById('mesh-refresh').addEventListener('click', loadOverview);
    }
  }

  async function loadTables(refreshNotice = '') {
    const page = document.getElementById('mesh-page');
    if (!page) return false;
    const requestState = databaseRequestState();
    const requestRevision = ++state.tableRequestRevision;
    setActiveView('tables');
    page.innerHTML = pageHeader('Tables', state.database, '<button class="mesh-button secondary" id="mesh-refresh-tables" type="button">Refresh</button>') + loadingPanel('Loading tables...');
    document.getElementById('mesh-refresh-tables').addEventListener('click', () => { void loadTables(); });
    try {
      const result = await executeSql("SELECT table_schema AS schema, table_name AS table FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema', 'crdb_internal') ORDER BY table_schema, table_name");
      if (!isCurrentDatabase(requestState) || state.view !== 'tables' || requestRevision !== state.tableRequestRevision) return false;
      state.tableResult = result;
      state.tablePage = 0;
      renderTablesResult();
      return true;
    } catch (error) {
      if (!state.session || !isCurrentDatabase(requestState) || state.view !== 'tables' || requestRevision !== state.tableRequestRevision) return false;
      const notice = refreshNotice ? `${refreshNotice} ` : '';
      page.innerHTML = pageHeader('Tables', state.database, '<button class="mesh-button secondary" id="mesh-refresh-tables" type="button">Retry</button>') + `<div class="mesh-error">${htmlEscape(`${notice}${readableError(error)}`)}</div>`;
      document.getElementById('mesh-refresh-tables').addEventListener('click', () => { void loadTables(); });
      return false;
    }
  }

  function renderTablesResult() {
    const page = document.getElementById('mesh-page');
    if (!page || !state.tableResult) return;
    page.innerHTML = pageHeader('Tables', state.database, '<div class="mesh-header-actions"><button class="mesh-button secondary" id="mesh-refresh-tables" type="button">Refresh</button><button class="mesh-button" id="mesh-new-table" type="button">New table</button></div>') + `
      <section class="mesh-panel">
        <div class="mesh-panel-head"><h2>Tables</h2><span class="mesh-query-meta">${resultRows(state.tableResult).length} found</span></div>
        ${renderDataTable(state.tableResult, 'No user tables found in this database.', { page: state.tablePage, pageSize: state.tablePageSize, showPageSize: true })}
      </section>
      <section class="mesh-panel mesh-create-table-section" id="mesh-create-table-panel" ${state.tableCreate.open ? '' : 'hidden'}></section>
    `;
    document.getElementById('mesh-refresh-tables').addEventListener('click', () => { void loadTables(); });
    document.getElementById('mesh-new-table').addEventListener('click', () => {
      state.tableCreate.open = !state.tableCreate.open;
      document.getElementById('mesh-create-table-panel').hidden = !state.tableCreate.open;
      document.getElementById('mesh-new-table').textContent = state.tableCreate.open ? 'Close editor' : 'New table';
      if (state.tableCreate.open) document.getElementById('mesh-create-table-name').focus();
    });
    if (state.tableCreate.open) document.getElementById('mesh-new-table').textContent = 'Close editor';
    renderCreateTablePanel();
    bindTablePagination(page, (nextPage) => {
      state.tablePage = nextPage;
      renderTablesResult();
    }, (nextPageSize) => {
      state.tablePageSize = nextPageSize;
      state.tablePage = 0;
      renderTablesResult();
    });
  }

  const meshTableTypes = ['UUID', 'STRING', 'INT', 'INT8', 'DECIMAL', 'FLOAT', 'BOOL', 'DATE', 'TIMESTAMP', 'TIMESTAMPTZ', 'JSONB', 'BYTES'];

  function newTableColumn() {
    return { name: '', type: 'STRING', nullable: true, primaryKey: false, default: 'none' };
  }

  function resetTableCreateState() {
    state.tableCreate = {
      open: false,
      schema: 'public',
      name: '',
      columns: [{ name: 'id', type: 'UUID', nullable: false, primaryKey: true, default: 'uuid' }],
    };
  }

  function tableDefaultOptions(type, selected) {
    const options = [{ value: 'none', label: 'None' }];
    if (type === 'UUID') options.push({ value: 'uuid', label: 'Generated UUID' });
    if (type === 'DATE') options.push({ value: 'date', label: 'Current date' });
    if (type === 'TIMESTAMP' || type === 'TIMESTAMPTZ') options.push({ value: 'timestamp', label: 'Current timestamp' });
    if (['INT', 'INT8', 'DECIMAL', 'FLOAT'].includes(type)) options.push({ value: 'zero', label: 'Zero' });
    if (type === 'BOOL') options.push({ value: 'true', label: 'True' }, { value: 'false', label: 'False' });
    return options.map((option) => `<option value="${option.value}" ${option.value === selected ? 'selected' : ''}>${option.label}</option>`).join('');
  }

  function tablePreviewIdentifier(value, fallback) {
    const name = String(value || '').trim() || fallback;
    return `"${name.replaceAll('"', '""')}"`;
  }

  function tableCreatePreview() {
    const table = state.tableCreate;
    const qualifiedName = [
      tablePreviewIdentifier(state.database, 'database'),
      tablePreviewIdentifier(table.schema, 'public'),
      tablePreviewIdentifier(table.name, 'table_name'),
    ].join('.');
    const primaryKeys = table.columns.filter((column) => column.primaryKey).map((column) => tablePreviewIdentifier(column.name, 'column'));
    const definitions = table.columns.map((column) => {
      const type = meshTableTypes.includes(column.type) ? column.type : 'STRING';
      let definition = `${tablePreviewIdentifier(column.name, 'column')} ${type}`;
      if (!column.nullable || column.primaryKey) definition += ' NOT NULL';
      const defaults = {
        uuid: 'gen_random_uuid()',
        timestamp: 'current_timestamp()',
        date: 'current_date()',
        zero: '0',
        true: 'true',
        false: 'false',
      };
      if (defaults[column.default]) definition += ` DEFAULT ${defaults[column.default]}`;
      return definition;
    });
    if (primaryKeys.length) definitions.push(`PRIMARY KEY (${primaryKeys.join(', ')})`);
    return `CREATE TABLE ${qualifiedName} (\n  ${definitions.join(',\n  ')}\n);`;
  }

  function updateTableCreatePreview() {
    const preview = document.getElementById('mesh-create-table-preview');
    if (preview) preview.textContent = tableCreatePreview();
  }

  function renderCreateTablePanel() {
    const panel = document.getElementById('mesh-create-table-panel');
    if (!panel) return;
    const table = state.tableCreate;
    panel.innerHTML = `
      <div class="mesh-panel-head"><h2>Create table</h2><span class="mesh-query-meta">${htmlEscape(state.database)}</span></div>
      <div class="mesh-panel-body">
        <p class="mesh-access-note">Define the table structure below. The database will enforce whether this user has CREATE permission.</p>
        <div class="mesh-status" id="mesh-create-table-status" hidden></div>
        <form id="mesh-create-table-form">
          <div class="mesh-form-grid">
            <div class="mesh-field"><label for="mesh-create-table-schema">Schema</label><input class="mesh-input mesh-code" id="mesh-create-table-schema" data-table-form="schema" value="${htmlEscape(table.schema)}" required></div>
            <div class="mesh-field"><label for="mesh-create-table-name">Table name</label><input class="mesh-input mesh-code" id="mesh-create-table-name" data-table-form="name" value="${htmlEscape(table.name)}" required></div>
          </div>
          <div class="mesh-column-editor">
            <div class="mesh-column-editor-head"><h3>Columns</h3><span class="mesh-query-meta">${table.columns.length} defined</span></div>
            ${table.columns.map((column, index) => `
              <div class="mesh-column-row">
                <div class="mesh-field"><label for="mesh-table-column-name-${index}">Column ${index + 1}</label><input class="mesh-input mesh-code" id="mesh-table-column-name-${index}" data-table-column-index="${index}" data-table-column="name" value="${htmlEscape(column.name)}" required></div>
                <div class="mesh-field"><label for="mesh-table-column-type-${index}">Type</label><select class="mesh-input mesh-code" id="mesh-table-column-type-${index}" data-table-column-index="${index}" data-table-column="type">${meshTableTypes.map((type) => `<option value="${type}" ${type === column.type ? 'selected' : ''}>${type}</option>`).join('')}</select></div>
                <div class="mesh-field"><label for="mesh-table-column-default-${index}">Default</label><select class="mesh-input" id="mesh-table-column-default-${index}" data-table-column-index="${index}" data-table-column="default">${tableDefaultOptions(column.type, column.default)}</select></div>
                <label class="mesh-checkbox"><input type="checkbox" data-table-column-index="${index}" data-table-column="nullable" ${column.nullable ? 'checked' : ''} ${column.primaryKey ? 'disabled' : ''}> Nullable</label>
                <label class="mesh-checkbox"><input type="checkbox" data-table-column-index="${index}" data-table-column="primaryKey" ${column.primaryKey ? 'checked' : ''}> Primary key</label>
                <button class="mesh-button secondary mesh-column-remove" type="button" data-table-remove-column="${index}" ${table.columns.length === 1 ? 'disabled' : ''}>Remove</button>
              </div>
            `).join('')}
            <button class="mesh-button secondary mesh-column-add" type="button" data-table-add-column>Add column</button>
          </div>
          <div class="mesh-form-actions"><button class="mesh-button" type="submit">Create table</button></div>
        </form>
        <div class="mesh-table-preview">
          <div class="mesh-table-preview-head">SQL preview</div>
          <pre class="mesh-engine mesh-code" id="mesh-create-table-preview"></pre>
        </div>
      </div>
    `;
    const form = document.getElementById('mesh-create-table-form');
    form.addEventListener('submit', createTable);
    form.querySelectorAll('[data-table-form]').forEach((control) => {
      control.addEventListener(control.tagName === 'INPUT' ? 'input' : 'change', () => {
        state.tableCreate[control.dataset.tableForm] = control.value;
        updateTableCreatePreview();
      });
    });
    form.querySelectorAll('[data-table-column]').forEach((control) => {
      control.addEventListener(control.type === 'text' ? 'input' : 'change', () => {
        const index = Number(control.dataset.tableColumnIndex);
        const field = control.dataset.tableColumn;
        const value = control.type === 'checkbox' ? control.checked : control.value;
        state.tableCreate.columns[index][field] = value;
        if (field === 'type') state.tableCreate.columns[index].default = 'none';
        if (field === 'nullable' && state.tableCreate.columns[index].primaryKey) state.tableCreate.columns[index].nullable = false;
        if (field === 'primaryKey' && value) state.tableCreate.columns[index].nullable = false;
        if (field === 'type' || (field === 'primaryKey' && value)) renderCreateTablePanel();
        else updateTableCreatePreview();
      });
    });
    form.querySelector('[data-table-add-column]').addEventListener('click', () => {
      state.tableCreate.columns.push(newTableColumn());
      renderCreateTablePanel();
    });
    form.querySelectorAll('[data-table-remove-column]').forEach((button) => {
      button.addEventListener('click', () => {
        state.tableCreate.columns.splice(Number(button.dataset.tableRemoveColumn), 1);
        renderCreateTablePanel();
      });
    });
    updateTableCreatePreview();
  }

  function validateTableCreateState() {
    const table = state.tableCreate;
    if (!String(table.schema || '').trim()) return 'Schema is required.';
    if (!String(table.name || '').trim()) return 'Table name is required.';
    if (!table.columns.length) return 'Add at least one column.';
    const names = new Set();
    for (const column of table.columns) {
      const name = String(column.name || '').trim();
      if (!name) return 'Every column needs a name.';
      const key = name.toLowerCase();
      if (names.has(key)) return `Column ${name} is duplicated.`;
      names.add(key);
    }
    return '';
  }

  async function createTable(event) {
    event.preventDefault();
    const error = validateTableCreateState();
    if (error) {
      managementStatus('mesh-create-table-status', error, true);
      return;
    }
    const button = event.currentTarget.querySelector('button[type="submit"]');
    const payload = {
      database: state.database,
      schema: String(state.tableCreate.schema).trim(),
      name: String(state.tableCreate.name).trim(),
      columns: state.tableCreate.columns.map((column) => ({
        name: String(column.name).trim(),
        type: column.type,
        nullable: column.nullable === true,
        primary_key: column.primaryKey === true,
        default: column.default || 'none',
      })),
    };
    const requestState = databaseRequestState();
    if (button) button.disabled = true;
    managementStatus('mesh-create-table-status', 'Creating table...');
    try {
      const response = await request('/api/v2/r1-meshdb/tables/', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (!isCurrentDatabase(requestState) || state.view !== 'tables') return;
      resetTableCreateState();
      state.tableCreate.open = true;
      const createdMessage = `Table ${response.schema || payload.schema}.${response.table || payload.name} created.`;
      if (await loadTables(`${createdMessage} The table list could not be refreshed.`)) {
        managementStatus('mesh-create-table-status', createdMessage);
      }
    } catch (requestError) {
      managementStatus('mesh-create-table-status', readableError(requestError), true);
    } finally {
      if (button) button.disabled = false;
    }
  }

  function selectOptions(values, selected, emptyText) {
    if (!values.length) return `<option value="">${htmlEscape(emptyText || 'None available')}</option>`;
    return values.map((value) => `<option value="${htmlEscape(value)}" ${value === selected ? 'selected' : ''}>${htmlEscape(value)}</option>`).join('');
  }

  function databasePicker(id, databases, selected, multiple = true) {
    const choices = databases.length
      ? databases.map((database) => `<label class="mesh-database-option mesh-code"><input type="${multiple ? 'checkbox' : 'radio'}" name="${id}" value="${htmlEscape(database)}" ${database === selected ? 'checked' : ''}> <span>${htmlEscape(database)}</span></label>`).join('')
      : '<span class="mesh-muted">No databases available</span>';
    return `<div class="mesh-database-picker" id="${id}" role="group" aria-label="Databases">${choices}</div>`;
  }

  function selectedValues(id) {
    const picker = document.getElementById(id);
    if (!picker) return [];
    return Array.from(picker.querySelectorAll('input:checked')).map((input) => input.value);
  }

  function setDatabaseSelectionMode(id, multiple) {
    const picker = document.getElementById(id);
    if (!picker) return [];
    const inputs = Array.from(picker.querySelectorAll('input'));
    const selected = selectedValues(id);
    const first = selected[0] || inputs[0]?.value || '';
    inputs.forEach((input) => {
      input.type = multiple ? 'checkbox' : 'radio';
      if (!multiple) input.checked = input.value === first;
    });
    return multiple ? selected : (first ? [first] : []);
  }

  async function ensureManageTables(database) {
    if (!database) return [];
    if (!Object.prototype.hasOwnProperty.call(state.manage.tablesByDatabase, database)) {
      state.manage.tablesByDatabase[database] = await fetchPaged(`/api/v2/r1-meshdb/database-tables/?database=${encodeURIComponent(database)}`, 'table_names');
    }
    return state.manage.tablesByDatabase[database];
  }

  async function loadManage() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    const requestState = databaseRequestState();
    setActiveView('manage');
    page.innerHTML = pageHeader('Manage', 'Create resources and control focused database or table access.') + loadingPanel('Loading users and databases...');
    try {
      const usersRequest = state.capabilities.canViewAccess
        ? fetchUsers()
        : Promise.resolve([]);
      const [databases, users] = await Promise.all([
        fetchPaged('/api/v2/r1-meshdb/databases/', 'databases'),
        usersRequest,
      ]);
      if (!isCurrentDatabase(requestState) || state.view !== 'manage') return;
      state.manage.databases = databases;
      state.manage.users = users;
      state.databases = databases;
      if (!databases.includes(state.manage.selectedDatabase)) state.manage.selectedDatabase = databases.includes(state.database) ? state.database : (databases[0] || '');
      if (state.capabilities.canViewAccess && !users.includes(state.manage.selectedUser)) state.manage.selectedUser = users[0] || '';
      if (state.capabilities.canViewAccess && !users.includes(state.manage.selectedPermissionUser)) state.manage.selectedPermissionUser = users[0] || '';
      if (!state.manage.selectedDatabase) state.manage.selectedDatabase = state.database;
      if (state.capabilities.canViewAccess) await ensureManageTables(state.manage.selectedDatabase);
      if (!isCurrentDatabase(requestState) || state.view !== 'manage') return;
      renderManagePage();
    } catch (error) {
      if (!state.session || !isCurrentDatabase(requestState) || state.view !== 'manage') return;
      page.innerHTML = pageHeader('Manage', 'Create resources and control focused database or table access.', '<button class="mesh-button secondary" id="mesh-refresh-manage" type="button">Retry</button>') + `<div class="mesh-error">${htmlEscape(readableError(error))}</div>`;
      document.getElementById('mesh-refresh-manage').addEventListener('click', loadManage);
    }
  }

  async function loadUsersAccess() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    const requestState = databaseRequestState();
    const requestRevision = ++state.manage.usersRequestRevision;
    state.manage.permissionRequestRevision += 1;
    setActiveView('users');
    page.innerHTML = pageHeader('Users & access', 'Review database and table permissions for every SQL user.') + loadingPanel('Loading users and permissions...');
    try {
      state.manage.users = await fetchUsers();
      if (!isCurrentDatabase(requestState) || state.view !== 'users' || requestRevision !== state.manage.usersRequestRevision) return;
      if (!state.manage.selectedPermissionUser || !state.manage.users.includes(state.manage.selectedPermissionUser)) {
        state.manage.selectedPermissionUser = state.manage.users[0] || '';
      }
      state.manage.userPage = 0;
      state.manage.permissions = [];
      state.manage.permissionError = '';
      renderUsersAccessPage();
      await loadUserPermissions(state.manage.selectedPermissionUser);
    } catch (error) {
      if (!state.session || !isCurrentDatabase(requestState) || state.view !== 'users' || requestRevision !== state.manage.usersRequestRevision) return;
      page.innerHTML = pageHeader('Users & access', 'Review database and table permissions for every SQL user.', '<button class="mesh-button secondary" id="mesh-refresh-users" type="button">Retry</button>') + `<div class="mesh-error">${htmlEscape(readableError(error))}</div>`;
      document.getElementById('mesh-refresh-users').addEventListener('click', () => { void loadUsersAccess(); });
    }
  }

  function protectedUser(username) {
    return ['admin', 'node', 'root'].includes(String(username).toLowerCase());
  }

  function renderUsersAccessPage() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    const users = state.manage.users;
    const selectedUser = state.manage.selectedPermissionUser;
    const canDeleteUser = selectedUser && !protectedUser(selectedUser) && selectedUser.toLowerCase() !== state.username.toLowerCase();
    const userResult = {
      columns: [
        { name: 'username' },
        { name: 'account' },
        { name: 'selected' },
      ],
      rows: users.map((username) => ({
        username,
        account: protectedUser(username) ? 'Protected' : 'SQL user',
        selected: username === selectedUser ? 'Inspecting' : '',
      })),
    };
    page.innerHTML = pageHeader('Users & access', 'Review database and table permissions for every SQL user.', '<button class="mesh-button secondary" id="mesh-refresh-users" type="button">Refresh</button>') + `
      <section class="mesh-panel">
        <div class="mesh-panel-head"><h2>Users</h2><span class="mesh-query-meta">${users.length} visible</span></div>
        <div class="mesh-panel-body">
          <div class="mesh-user-actions">
            <div class="mesh-field"><label for="mesh-permission-user">Inspect user</label><select class="mesh-input mesh-code" id="mesh-permission-user">${selectOptions(users, selectedUser, 'No users available')}</select></div>
            <button class="mesh-button danger" id="mesh-delete-user" type="button" ${canDeleteUser ? '' : 'disabled'}>Delete user</button>
          </div>
          <div class="mesh-status" id="mesh-delete-user-status" role="status" aria-live="polite" hidden></div>
          <div class="mesh-delete-confirm" id="mesh-delete-confirm" hidden>
            <h3>Delete ${htmlEscape(selectedUser)}</h3>
            <p>This removes the login. The database will refuse deletion while the user still has grants or owns objects.</p>
            <div class="mesh-field"><label for="mesh-delete-username">Type ${htmlEscape(selectedUser)} to confirm</label><input class="mesh-input mesh-code" id="mesh-delete-username" autocomplete="off" spellcheck="false"></div>
            <div class="mesh-form-actions"><button class="mesh-button secondary" id="mesh-cancel-delete" type="button">Cancel</button><button class="mesh-button danger solid" id="mesh-confirm-delete" type="button" disabled>Delete user</button></div>
          </div>
          <p class="mesh-access-note">Protected accounts cannot be deleted here. Permission sources distinguish direct, role, and public grants.</p>
          <div id="mesh-user-table">${renderDataTable(userResult, 'No SQL users found.', { page: state.manage.userPage, pageSize: state.manage.userPageSize, showPageSize: true })}</div>
        </div>
      </section>
      <section class="mesh-panel">
        <div class="mesh-panel-head"><h2>Database, schema and table grants</h2><span class="mesh-query-meta">${htmlEscape(selectedUser || 'No user selected')}</span></div>
        <div class="mesh-panel-body" id="mesh-permission-body"></div>
      </section>
    `;
    document.getElementById('mesh-refresh-users').addEventListener('click', () => { void loadUsersAccess(); });
    managementStatus('mesh-delete-user-status', state.manage.deleteUserStatus, state.manage.deleteUserError);
    document.getElementById('mesh-delete-user').addEventListener('click', () => {
      document.getElementById('mesh-delete-confirm').hidden = false;
      document.getElementById('mesh-delete-username').focus();
    });
    document.getElementById('mesh-cancel-delete').addEventListener('click', () => {
      document.getElementById('mesh-delete-confirm').hidden = true;
      document.getElementById('mesh-delete-username').value = '';
      document.getElementById('mesh-confirm-delete').disabled = true;
    });
    document.getElementById('mesh-delete-username').addEventListener('input', (event) => {
      document.getElementById('mesh-confirm-delete').disabled = event.currentTarget.value !== state.manage.selectedPermissionUser;
    });
    document.getElementById('mesh-confirm-delete').addEventListener('click', () => { void deleteSelectedUser(); });
    document.getElementById('mesh-permission-user').addEventListener('change', (event) => {
      state.manage.selectedPermissionUser = event.currentTarget.value;
      state.manage.deleteUserStatus = '';
      state.manage.permissionPage = 0;
      state.manage.permissions = [];
      state.manage.permissionError = '';
      renderUsersAccessPage();
      void loadUserPermissions(state.manage.selectedPermissionUser);
    });
    bindTablePagination(document.getElementById('mesh-user-table'), (nextPage) => {
      state.manage.userPage = nextPage;
      renderUsersAccessPage();
    }, (nextPageSize) => {
      state.manage.userPageSize = nextPageSize;
      state.manage.userPage = 0;
      renderUsersAccessPage();
    });
    renderPermissionDetails();
  }

  async function deleteSelectedUser() {
    const username = state.manage.selectedPermissionUser;
    const confirmation = document.getElementById('mesh-delete-username');
    const button = document.getElementById('mesh-confirm-delete');
    if (!button || !confirmation || confirmation.value !== username || protectedUser(username) || username.toLowerCase() === state.username.toLowerCase()) return;
    button.disabled = true;
    button.textContent = 'Deleting...';
    try {
      await request('/api/v2/r1-meshdb/users/', {
        method: 'DELETE',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username }),
      });
      state.manage.deleteUserStatus = `User ${username} deleted.`;
      state.manage.deleteUserError = false;
      state.manage.selectedPermissionUser = '';
      if (state.manage.selectedUser === username) state.manage.selectedUser = '';
      if (state.view === 'users' && document.getElementById('mesh-confirm-delete') === button) {
        await loadUsersAccess();
      }
    } catch (error) {
      const detail = readableError(error);
      const dependencyHint = /grants still exist|owns|dependent|scheduled jobs/i.test(detail)
        ? ' Revoke the user\'s grants and transfer ownership before retrying.' : '';
      state.manage.deleteUserStatus = detail + dependencyHint;
      state.manage.deleteUserError = true;
      managementStatus('mesh-delete-user-status', state.manage.deleteUserStatus, true);
      button.disabled = false;
      button.textContent = 'Delete user';
    }
  }

  async function loadUserPermissions(username) {
    const selectedUser = String(username || '').trim();
    const requestState = databaseRequestState();
    const usersRequestRevision = state.manage.usersRequestRevision;
    const requestRevision = ++state.manage.permissionRequestRevision;
    const isCurrentRequest = () => isCurrentDatabase(requestState) && state.view === 'users' &&
      usersRequestRevision === state.manage.usersRequestRevision &&
      requestRevision === state.manage.permissionRequestRevision &&
      state.manage.selectedPermissionUser === selectedUser;
    if (!selectedUser) {
      if (!isCurrentRequest()) return;
      state.manage.permissionsLoading = false;
      renderPermissionDetails();
      return;
    }
    state.manage.permissionsLoading = true;
    state.manage.permissionError = '';
    renderPermissionDetails();
    try {
      state.manage.permissions = await fetchPaged(
        `/api/v2/r1-meshdb/permissions/?username=${encodeURIComponent(selectedUser)}`,
        'permissions',
      );
      if (!isCurrentRequest()) return;
    } catch (error) {
      if (!isCurrentRequest()) return;
      state.manage.permissions = [];
      state.manage.permissionError = readableError(error);
    } finally {
      if (!isCurrentRequest()) return;
      state.manage.permissionsLoading = false;
      renderPermissionDetails();
    }
  }

  function renderPermissionDetails() {
    const body = document.getElementById('mesh-permission-body');
    if (!body) return;
    if (state.manage.permissionsLoading) {
      body.innerHTML = '<span class="mesh-loading">Loading grants...</span>';
      return;
    }
    if (state.manage.permissionError) {
      body.innerHTML = `<div class="mesh-error">${htmlEscape(state.manage.permissionError)}</div>`;
      return;
    }
    const permissionResult = {
      columns: [
        { name: 'database' },
        { name: 'object' },
        { name: 'scope' },
        { name: 'privileges' },
        { name: 'source' },
        { name: 'grantable' },
      ],
      rows: state.manage.permissions.map((permission) => ({
        database: permission.database || 'Cluster',
        object: permission.table || permission.schema || permission.database || 'Database',
        scope: permission.scope || 'unknown',
        privileges: Array.isArray(permission.privileges) ? permission.privileges.join(', ') : '',
        source: permission.source_role ? `${permission.source} (${permission.source_role})` : (permission.source || 'direct'),
        grantable: permission.grantable ? 'Yes' : 'No',
      })),
    };
    body.innerHTML = `<div id="mesh-permission-table">${renderDataTable(permissionResult, 'No database, schema or table grants found.', { page: state.manage.permissionPage, pageSize: state.manage.permissionPageSize, showPageSize: true })}</div>`;
    bindTablePagination(document.getElementById('mesh-permission-table'), (nextPage) => {
      state.manage.permissionPage = nextPage;
      renderPermissionDetails();
    }, (nextPageSize) => {
      state.manage.permissionPageSize = nextPageSize;
      state.manage.permissionPage = 0;
      renderPermissionDetails();
    });
  }

  function managementStatus(id, message, error = false) {
    const box = document.getElementById(id);
    if (!box) return;
    box.textContent = message;
    box.hidden = !message;
    box.classList.toggle('error', error);
  }

  function renderManagePage() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    state.manage.initialAccessRevision += 1;
    state.manage.accessSelectionRevision += 1;
    const databases = state.manage.databases;
    const users = state.manage.users;
    const canViewAccess = state.capabilities.canViewAccess;
    const tabs = [
      ...(state.capabilities.canCreateDatabase ? [{ id: 'databases', label: 'Databases' }] : []),
      ...(canViewAccess ? [{ id: 'users', label: 'Create user' }, { id: 'access', label: 'Access' }] : []),
    ];
    if (!tabs.some((tab) => tab.id === state.manage.activeSection)) state.manage.activeSection = tabs[0]?.id || '';
    const selectedDatabase = state.manage.selectedDatabase || state.database;
    const tables = state.manage.tablesByDatabase[selectedDatabase] || [];
    const selectedTable = tables.includes(state.manage.selectedTable) ? state.manage.selectedTable : (tables[0] || '');
    state.manage.selectedTable = selectedTable;
    page.innerHTML = pageHeader('Manage', 'Create resources and manage user access.', '<button class="mesh-button secondary" id="mesh-refresh-manage" type="button">Refresh</button>') + `
      <div class="mesh-task-tabs" role="tablist" aria-label="Management tasks">
        ${tabs.map((tab) => `<button type="button" role="tab" id="mesh-tab-${tab.id}" data-manage-tab="${tab.id}" aria-controls="mesh-manage-${tab.id}" aria-selected="${tab.id === state.manage.activeSection}" tabindex="${tab.id === state.manage.activeSection ? 0 : -1}">${tab.label}</button>`).join('')}
      </div>
      ${state.capabilities.canCreateDatabase ? `
      <section class="mesh-panel" id="mesh-manage-databases" role="tabpanel" aria-labelledby="mesh-tab-databases" ${state.manage.activeSection === 'databases' ? '' : 'hidden'}>
        <div class="mesh-panel-head"><h2>Create database</h2><span class="mesh-query-meta">${databases.length} visible</span></div>
        <div class="mesh-panel-body">
          <div class="mesh-status" id="mesh-create-database-status" hidden></div>
          <form id="mesh-create-database-form">
            <p class="mesh-access-note">New databases start with public connection and schema creation disabled.</p>
            <div class="mesh-form-grid">
              <div class="mesh-field"><label for="mesh-new-database">Database name</label><input class="mesh-input mesh-code" id="mesh-new-database" name="name" autocomplete="off" required></div>
            </div>
            <div class="mesh-form-actions"><button class="mesh-button" type="submit">Create database</button></div>
          </form>
        </div>
      </section>
      ` : ''}
      ${canViewAccess ? `
      <section class="mesh-panel" id="mesh-manage-users" role="tabpanel" aria-labelledby="mesh-tab-users" ${state.manage.activeSection === 'users' ? '' : 'hidden'}>
        <div class="mesh-panel-head"><h2>Create user</h2><span class="mesh-query-meta">${users.length} visible</span></div>
        <div class="mesh-panel-body">
          <div class="mesh-status" id="mesh-create-user-status" hidden></div>
          <form id="mesh-create-user-form">
            <div class="mesh-form-grid">
              <div class="mesh-field mesh-field-full"><label for="mesh-new-username">Username</label><input class="mesh-input mesh-code" id="mesh-new-username" name="username" autocomplete="off" required></div>
              <div class="mesh-field"><label for="mesh-new-password">Password</label><input class="mesh-input" id="mesh-new-password" name="password" type="password" autocomplete="new-password" required></div>
              <div class="mesh-field"><label for="mesh-confirm-password">Confirm password</label><input class="mesh-input" id="mesh-confirm-password" name="confirm_password" type="password" autocomplete="new-password" required></div>
            </div>
            <fieldset class="mesh-fieldset">
              <legend>Initial access</legend>
              <p class="mesh-access-note">Creating a user only creates the login. Enable this step to grant access to one or more databases, or one table. Table access includes database connection.</p>
              <label class="mesh-checkbox"><input type="checkbox" id="mesh-create-user-grant"> <span>Grant the selected access after the user is created</span></label>
              <div class="mesh-form-grid" id="mesh-initial-access-fields">
                <div class="mesh-field"><span class="mesh-field-label">Databases</span>${databasePicker('mesh-create-user-database', databases, selectedDatabase)}</div>
                <div class="mesh-field"><label for="mesh-create-user-scope">Access scope</label><select class="mesh-input" id="mesh-create-user-scope"><option value="database">Database access</option><option value="table">One table</option></select></div>
                <div class="mesh-field" id="mesh-create-user-table-field"><label for="mesh-create-user-table">Table</label><select class="mesh-input mesh-code" id="mesh-create-user-table">${selectOptions(tables, selectedTable, 'No tables available')}</select></div>
                <div class="mesh-field"><label for="mesh-create-user-preset">Access level</label><select class="mesh-input" id="mesh-create-user-preset"><option value="viewer">Viewer</option><option value="editor">Editor</option></select></div>
              </div>
            </fieldset>
            <div class="mesh-form-actions"><button class="mesh-button" type="submit">Create user</button></div>
          </form>
        </div>
      </section>
      ` : ''}
      ${canViewAccess ? `
      <section class="mesh-panel" id="mesh-manage-access" role="tabpanel" aria-labelledby="mesh-tab-access" ${state.manage.activeSection === 'access' ? '' : 'hidden'}>
        <div class="mesh-panel-head"><h2>Manage existing access</h2><span class="mesh-query-meta">${users.length} users</span></div>
        <div class="mesh-panel-body">
          <p class="mesh-access-note">Database-scope changes apply to every selected database. Table grants include database connection; revoking table access leaves connection in place.</p>
          <form id="mesh-access-form">
            <div class="mesh-form-grid">
              <div class="mesh-field"><label for="mesh-access-user">User</label><select class="mesh-input mesh-code" id="mesh-access-user">${selectOptions(users, state.manage.selectedUser, 'No users available')}</select></div>
              <div class="mesh-field"><label for="mesh-access-scope">Access scope</label><select class="mesh-input" id="mesh-access-scope"><option value="database" ${state.manage.selectedScope === 'database' ? 'selected' : ''}>Database access</option><option value="table" ${state.manage.selectedScope === 'table' ? 'selected' : ''}>One table</option></select></div>
              <div class="mesh-field mesh-field-full"><span class="mesh-field-label">Databases</span>${databasePicker('mesh-access-database', databases, selectedDatabase, state.manage.selectedScope === 'database')}</div>
              <div class="mesh-field" id="mesh-access-table-field"><label for="mesh-access-table">Table</label><select class="mesh-input mesh-code" id="mesh-access-table">${selectOptions(tables, selectedTable, 'No tables available')}</select></div>
              <div class="mesh-field"><label for="mesh-access-preset">Access level</label><select class="mesh-input" id="mesh-access-preset"><option value="viewer" ${state.manage.selectedPreset === 'viewer' ? 'selected' : ''}>Viewer</option><option value="editor" ${state.manage.selectedPreset === 'editor' ? 'selected' : ''}>Editor</option></select></div>
            </div>
            <div class="mesh-status" id="mesh-access-current" hidden></div>
            <div class="mesh-form-actions"><button class="mesh-button secondary" id="mesh-revoke-access" type="button">Revoke selected access</button><button class="mesh-button" id="mesh-grant-access" type="submit">Grant selected access</button></div>
          </form>
        </div>
      </section>
      ` : ''}
    `;
    document.getElementById('mesh-refresh-manage').addEventListener('click', loadManage);
    document.querySelectorAll('[data-manage-tab]').forEach((button) => {
      button.addEventListener('click', () => activateManageSection(button.dataset.manageTab));
      button.addEventListener('keydown', (event) => {
        const keys = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
        if (!keys.includes(event.key)) return;
        event.preventDefault();
        const index = tabs.findIndex((tab) => tab.id === button.dataset.manageTab);
        const nextIndex = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1
          : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
        const next = document.getElementById(`mesh-tab-${tabs[nextIndex].id}`);
        activateManageSection(tabs[nextIndex].id);
        next.focus();
      });
    });
    const createDatabaseForm = document.getElementById('mesh-create-database-form');
    if (createDatabaseForm) createDatabaseForm.addEventListener('submit', createDatabase);
    if (canViewAccess) {
      document.getElementById('mesh-create-user-form').addEventListener('submit', createUser);
      document.getElementById('mesh-create-user-grant').addEventListener('change', syncInitialAccessControls);
      document.getElementById('mesh-create-user-database').addEventListener('change', () => { void refreshInitialAccessTable(); });
      document.getElementById('mesh-create-user-scope').addEventListener('change', () => { void refreshInitialAccessTable(); });
      document.getElementById('mesh-access-user').addEventListener('change', refreshAccessSelection);
      document.getElementById('mesh-access-database').addEventListener('change', refreshAccessSelection);
      document.getElementById('mesh-access-scope').addEventListener('change', refreshAccessSelection);
      document.getElementById('mesh-access-table').addEventListener('change', refreshAccessSelection);
      document.getElementById('mesh-access-preset').addEventListener('change', refreshAccessSelection);
      document.getElementById('mesh-access-form').addEventListener('submit', (event) => changeExistingAccess(event, 'grant'));
      document.getElementById('mesh-revoke-access').addEventListener('click', () => changeExistingAccess(null, 'revoke'));
    }
    syncInitialAccessControls();
    syncExistingAccessControls();
    void refreshAccessStatus();
  }

  function activateManageSection(section) {
    state.manage.activeSection = section;
    document.querySelectorAll('[data-manage-tab]').forEach((button) => {
      const active = button.dataset.manageTab === section;
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
      document.getElementById(`mesh-manage-${button.dataset.manageTab}`).hidden = !active;
    });
  }

  function populateTableSelect(id, tables, selected) {
    const select = document.getElementById(id);
    if (!select) return;
    select.innerHTML = selectOptions(tables, selected, 'No tables available');
    if (selected && tables.includes(selected)) select.value = selected;
  }

  function syncPresetOptions(id, scope) {
    const select = document.getElementById(id);
    if (!select) return;
    const selected = select.value || 'viewer';
    const labels = scope === 'database'
      ? { viewer: 'Connect', editor: 'Connect + create objects' }
      : { viewer: 'Viewer', editor: 'Editor' };
    select.innerHTML = Object.entries(labels).map(([value, label]) => `<option value="${value}">${label}</option>`).join('');
    select.value = selected in labels ? selected : 'viewer';
  }

  function syncInitialAccessControls() {
    const enabled = document.getElementById('mesh-create-user-grant')?.checked || false;
    const scope = document.getElementById('mesh-create-user-scope')?.value || 'database';
    const fields = document.getElementById('mesh-initial-access-fields');
    if (!fields) return;
    setDatabaseSelectionMode('mesh-create-user-database', scope === 'database');
    fields.hidden = !enabled;
    fields.querySelectorAll('select, input').forEach((control) => { control.disabled = !enabled; });
    const tableField = document.getElementById('mesh-create-user-table-field');
    if (tableField) tableField.hidden = scope !== 'table';
    const table = document.getElementById('mesh-create-user-table');
    if (table) table.disabled = !enabled || scope !== 'table';
    syncPresetOptions('mesh-create-user-preset', scope);
  }

  async function refreshInitialAccessTable() {
    const selectionRevision = ++state.manage.initialAccessRevision;
    const requestState = databaseRequestState();
    const scope = document.getElementById('mesh-create-user-scope')?.value || 'database';
    const databases = setDatabaseSelectionMode('mesh-create-user-database', scope === 'database');
    const database = databases[0] || '';
    if (database) state.manage.selectedDatabase = database;
    if (scope === 'table' && database) {
      const tables = await ensureManageTables(database);
      if (!isCurrentDatabase(requestState) || state.view !== 'manage' || selectionRevision !== state.manage.initialAccessRevision) return;
      populateTableSelect('mesh-create-user-table', tables, tables[0] || '');
      state.manage.selectedTable = tables[0] || '';
    }
    if (selectionRevision === state.manage.initialAccessRevision) syncInitialAccessControls();
  }

  function syncExistingAccessControls() {
    const scope = document.getElementById('mesh-access-scope')?.value || 'database';
    setDatabaseSelectionMode('mesh-access-database', scope === 'database');
    const tableField = document.getElementById('mesh-access-table-field');
    const table = document.getElementById('mesh-access-table');
    if (tableField) tableField.hidden = scope !== 'table';
    if (table) table.disabled = scope !== 'table';
    syncPresetOptions('mesh-access-preset', scope);
  }

  async function refreshAccessSelection(event) {
    const selectionRevision = ++state.manage.accessSelectionRevision;
    const requestState = databaseRequestState();
    const id = event && event.currentTarget ? event.currentTarget.id : '';
    if (id === 'mesh-access-user') state.manage.selectedUser = event.currentTarget.value;
    if (id === 'mesh-access-scope') state.manage.selectedScope = event.currentTarget.value;
    if (id === 'mesh-access-preset') state.manage.selectedPreset = event.currentTarget.value;
    if (id === 'mesh-access-table') state.manage.selectedTable = event.currentTarget.value;
    if (id === 'mesh-access-database' || id === 'mesh-access-scope') {
      const scope = document.getElementById('mesh-access-scope')?.value || 'database';
      const databases = setDatabaseSelectionMode('mesh-access-database', scope === 'database');
      const database = databases[0] || '';
      state.manage.selectedDatabase = database;
      if (scope === 'table' && database) {
        const tables = await ensureManageTables(database);
        if (!isCurrentDatabase(requestState) || state.view !== 'manage' || selectionRevision !== state.manage.accessSelectionRevision) return;
        populateTableSelect('mesh-access-table', tables, tables[0] || '');
        state.manage.selectedTable = tables[0] || '';
      }
    }
    if (selectionRevision !== state.manage.accessSelectionRevision) return;
    syncExistingAccessControls();
    await refreshAccessStatus();
  }

  function accessFormValues(action) {
    const scope = document.getElementById('mesh-access-scope')?.value || 'database';
    const databases = selectedValues('mesh-access-database');
    return {
      username: document.getElementById('mesh-access-user')?.value || '',
      database: databases[0] || '',
      databases,
      scope,
      table: scope === 'table' ? (document.getElementById('mesh-access-table')?.value || '') : '',
      preset: document.getElementById('mesh-access-preset')?.value || 'viewer',
      action,
    };
  }

  function accessSelectionKey(values) {
    return JSON.stringify({
      username: values.username,
      databases: values.databases,
      scope: values.scope,
      table: values.table,
      preset: values.preset,
    });
  }

  async function refreshAccessStatus() {
    const requestState = databaseRequestState();
    const box = document.getElementById('mesh-access-current');
    if (!box) return;
    const values = accessFormValues('grant');
    const selectionRevision = state.manage.accessSelectionRevision;
    const selectionKey = accessSelectionKey(values);
    if (!values.username || !values.databases.length || (values.scope === 'table' && !values.table)) {
      box.textContent = 'Select a user, database, and table when using table scope.';
      box.hidden = false;
      box.classList.remove('error');
      return;
    }
    if (values.scope === 'database' && values.databases.length > 1) {
      box.textContent = `${values.databases.length} databases selected. The next change will apply to all of them.`;
      box.hidden = false;
      box.classList.remove('error');
      return;
    }
    box.textContent = 'Checking current access...';
    box.hidden = false;
    try {
      const params = new URLSearchParams({ username: values.username, database: values.database });
      if (values.scope === 'table') params.set('table', values.table);
      const response = await request(`/api/v2/r1-meshdb/access/?${params.toString()}`);
      if (!isCurrentDatabase(requestState) || state.view !== 'manage' || selectionRevision !== state.manage.accessSelectionRevision || selectionKey !== accessSelectionKey(accessFormValues('grant'))) return;
      const privileges = Array.isArray(response.privileges) ? response.privileges : [];
      box.textContent = privileges.length ? `Current direct grants: ${privileges.join(', ')}` : 'No direct grants found for this selection.';
      box.hidden = false;
      box.classList.remove('error');
    } catch (error) {
      if (!isCurrentDatabase(requestState) || state.view !== 'manage' || selectionRevision !== state.manage.accessSelectionRevision || selectionKey !== accessSelectionKey(accessFormValues('grant'))) return;
      box.textContent = readableError(error);
      box.hidden = false;
      box.classList.add('error');
    }
  }

  async function changeExistingAccess(event, action) {
    if (event) event.preventDefault();
    const button = document.getElementById(action === 'grant' ? 'mesh-grant-access' : 'mesh-revoke-access');
    const values = accessFormValues(action);
    if (!values.username || !values.databases.length || (values.scope === 'table' && !values.table)) {
      managementStatus('mesh-access-current', 'Select all required access fields first.', true);
      return;
    }
    if (button) button.disabled = true;
    const requestState = databaseRequestState();
    const selectionRevision = state.manage.accessSelectionRevision;
    const selectionKey = accessSelectionKey(values);
    try {
      await applyAccess(values);
      if (!isCurrentDatabase(requestState) || state.view !== 'manage' || selectionRevision !== state.manage.accessSelectionRevision || selectionKey !== accessSelectionKey(accessFormValues('grant'))) return;
      await refreshAccessStatus();
    } catch (error) {
      if (!isCurrentDatabase(requestState) || state.view !== 'manage' || selectionRevision !== state.manage.accessSelectionRevision || selectionKey !== accessSelectionKey(accessFormValues('grant'))) return;
      managementStatus('mesh-access-current', readableError(error), true);
    } finally {
      if (button) button.disabled = false;
    }
  }

  async function applyAccess(values) {
    return request('/api/v2/r1-meshdb/access/', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(values),
    });
  }

  async function createDatabase(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const button = event.currentTarget.querySelector('button[type="submit"]');
    managementStatus('mesh-create-database-status', '');
    if (button) button.disabled = true;
    try {
      const response = await request('/api/v2/r1-meshdb/databases/', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ name: String(form.get('name') || '').trim() }),
      });
      const createdDatabase = response.database || state.database;
      if (createdDatabase !== state.database) state.databaseRevision += 1;
      state.database = createdDatabase;
      state.manage.selectedDatabase = state.database;
      state.manage.selectedTable = '';
      resetTableCreateState();
      state.manage.databases = await fetchPaged('/api/v2/r1-meshdb/databases/', 'databases');
      state.databases = state.manage.databases;
      setStoredSession();
      renderDatabaseSelector();
      updateDatabaseIdentity();
      renderManagePage();
      managementStatus('mesh-create-database-status', `Database ${state.database} created.`);
    } catch (error) {
      managementStatus('mesh-create-database-status', readableError(error), true);
    } finally {
      if (button) button.disabled = false;
    }
  }

  async function createUser(event) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const password = String(form.get('password') || '');
    const confirmation = String(form.get('confirm_password') || '');
    if (password !== confirmation) {
      managementStatus('mesh-create-user-status', 'Passwords do not match.', true);
      return;
    }
    const button = formElement.querySelector('button[type="submit"]');
    const grant = document.getElementById('mesh-create-user-grant')?.checked || false;
    const scope = document.getElementById('mesh-create-user-scope')?.value || 'database';
    const databases = selectedValues('mesh-create-user-database');
    if (grant && !databases.length) {
      managementStatus('mesh-create-user-status', 'Select at least one database for the initial access grant.', true);
      return;
    }
    const access = {
      username: String(form.get('username') || '').trim(),
      database: databases[0] || '',
      databases,
      scope,
      table: scope === 'table' ? (document.getElementById('mesh-create-user-table')?.value || '') : '',
      preset: document.getElementById('mesh-create-user-preset')?.value || 'viewer',
      action: 'grant',
    };
    managementStatus('mesh-create-user-status', '');
    if (button) button.disabled = true;
    try {
      const response = await request('/api/v2/r1-meshdb/users/', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username: access.username, password }),
      });
      let message = `User ${response.username || access.username} created.`;
      if (grant) {
        try {
          await applyAccess({ ...access, username: response.username || access.username });
          const databaseCount = access.databases.length;
          message += ` Access was applied to ${databaseCount} database${databaseCount === 1 ? '' : 's'}.`;
        } catch (error) {
          message += ` User created, but access was not applied: ${readableError(error)}`;
        }
      }
      state.manage.users = await fetchUsers();
      state.manage.selectedUser = response.username || access.username;
      state.manage.selectedPermissionUser = response.username || access.username;
      renderManagePage();
      managementStatus('mesh-create-user-status', message, message.includes('not applied'));
    } catch (error) {
      managementStatus('mesh-create-user-status', readableError(error), true);
    } finally {
      if (button) button.disabled = false;
    }
  }

  function renderSql() {
    const page = document.getElementById('mesh-page');
    if (!page) return;
    setActiveView('sql');
    state.queryResult = null;
    state.queryPage = 0;
    page.innerHTML = pageHeader('SQL', state.database) + `
      <section class="mesh-panel">
        <div class="mesh-panel-head"><h2>Query</h2></div>
        <div class="mesh-panel-body">
          <div class="mesh-error" id="mesh-sql-error" hidden></div>
          <label class="mesh-field" for="mesh-query"><span>Statement</span></label>
          <textarea class="mesh-textarea" id="mesh-query" spellcheck="false">${htmlEscape(state.queryDraft)}</textarea>
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
    document.getElementById('mesh-query').addEventListener('input', (event) => {
      state.queryDraft = event.currentTarget.value;
    });
    document.getElementById('mesh-query').focus();
  }

  function renderQueryResult() {
    const body = document.getElementById('mesh-result-body');
    if (!body || !state.queryResult) return;
    body.innerHTML = renderDataTable(state.queryResult, `${state.queryResult.rows_affected || 0} rows affected.`, {
      page: state.queryPage,
      pageSize: state.queryPageSize,
      showPageSize: true,
    });
    bindTablePagination(body, (nextPage) => {
      state.queryPage = nextPage;
      renderQueryResult();
    }, (nextPageSize) => {
      state.queryPageSize = nextPageSize;
      state.queryPage = 0;
      renderQueryResult();
    });
  }

  async function runQuery() {
    const editor = document.getElementById('mesh-query');
    const button = document.getElementById('mesh-run-query');
    const errorBox = document.getElementById('mesh-sql-error');
    const meta = document.getElementById('mesh-query-meta');
    const panel = document.getElementById('mesh-results');
    const requestState = databaseRequestState();
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
      if (!isCurrentDatabase(requestState) || state.view !== 'sql') return;
      const elapsed = Math.max(0, performance.now() - started);
      state.queryResult = result;
      state.queryPage = 0;
      renderQueryResult();
      document.getElementById('mesh-result-meta').textContent = `${result.tag || 'SQL'} / ${resultRows(result).length} rows / ${elapsed.toFixed(0)} ms / ${result.retries} retries`;
      meta.textContent = 'Completed';
      panel.hidden = false;
    } catch (error) {
      if (!state.session || !isCurrentDatabase(requestState) || state.view !== 'sql') return;
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
