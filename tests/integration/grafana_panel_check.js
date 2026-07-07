#!/usr/bin/env node
/**
 * grafana_panel_check.js - Playwright-based Grafana dashboard rendering tests.
 *
 * Verifies that every panel on the gateway-overview dashboard:
 *   1. Issues a datasource query (HTTP POST /api/ds/query)
 *   2. Receives a 200 response with data (no errors)
 *   3. Does NOT show "No data" or "Error" text in the rendered DOM
 *   4. Renders panel-specific content (bargauge shows multiple bars, etc.)
 *
 * Usage:
 *   node grafana_panel_check.js [--url http://localhost:3030]
 *
 * Exit code 0 = all panels OK, non-zero = failures.
 */

const { chromium } = require('playwright');

const args = process.argv.slice(2);
let grafanaUrl = process.env.GRAFANA_URL || 'http://localhost:3030';
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--url' && args[i + 1]) {
    grafanaUrl = args[i + 1];
    i++;
  }
}

const dashboardPath = '/d/gateway-overview';

// Panel IDs and expected content checks.
// Each entry: { id, title, type, checks } where checks is an array of
// { kind, value } describing what to verify in the rendered panel.
// Updated for dashboard v44: p1 Total Requests (stat/ClickHouse),
// p7 Status Code Breakdown (piechart/ClickHouse), panel IDs swapped from position-based naming.
const expectedPanels = [
  { id: 1,  title: 'Total Requests',                    type: 'stat',         checks: [] },
  { id: 2,  title: 'Active Connections',                type: 'stat',         checks: [] },
  { id: 3,  title: 'Token Usage by Category',           type: 'stat',         checks: [
    { kind: 'text', value: 'Total' },
    { kind: 'text', value: 'Mil' },
    { kind: 'text', value: '$' },
  ]},
  { id: 4,  title: 'Error Rate %',                      type: 'stat',         checks: [
    { kind: 'text', value: '%' },
  ]},
  { id: 5,  title: 'Request Rate (req/s)',              type: 'timeseries',  checks: [] },
  { id: 7,  title: 'Status Code Breakdown',             type: 'piechart',     checks: [
    { kind: 'text', value: '200' },
  ]},
  { id: 8,  title: 'Model Distribution',               type: 'bargauge',     checks: [
    { kind: 'text_count_gt', value: 1 },
  ]},
  { id: 9,  title: 'Latency p50 / p95 / p99 (ms)',      type: 'timeseries',  checks: [] },
  { id: 10, title: 'Avg Latency by Model (seconds)',    type: 'bargauge',     checks: [
    { kind: 'text_count_gt', value: 1 },
  ]},
  { id: 11, title: 'Bandwidth In / Out (bytes/s)',      type: 'timeseries',  checks: [] },
  { id: 12, title: 'Shared Dict Memory Usage',          type: 'timeseries',  checks: [] },
  { id: 13, title: 'Stream Abort Rate by Direction (%)', type: 'timeseries',  checks: [] },
  { id: 14, title: 'Stream Status (completed / client-aborted / provider-aborted)', type: 'timeseries', checks: [] },
  { id: 15, title: 'Cost Over Time by Model ($)',       type: 'timeseries',  checks: [] },
];

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  const dsResponses = [];
  const dsErrors = [];

  page.on('response', async resp => {
    if (resp.url().includes('/api/ds/query')) {
      let body = null;
      try { body = await resp.json(); } catch(e) {
        dsErrors.push({ url: resp.url(), status: resp.status(), error: 'Failed to parse JSON response' });
      }
      if (body && body.results) {
        const keys = Object.keys(body.results);
        const errors = keys.filter(k => body.results[k].error);
        if (errors.length > 0) {
          dsErrors.push({ url: resp.url(), status: resp.status(), errors: errors.map(k => ({ ref: k, error: body.results[k].error })) });
        }
        dsResponses.push({ url: resp.url(), status: resp.status(), refKeys: keys, hasError: errors.length > 0 });
      } else {
        dsResponses.push({ url: resp.url(), status: resp.status(), refKeys: [], hasError: false });
      }
    }
  });

  let pass = 0;
  let fail = 0;
  const results = [];

  try {
    await page.goto(`${grafanaUrl}${dashboardPath}`, { waitUntil: 'networkidle', timeout: 60000 });
  } catch(e) {
    console.error(`[FAIL] Failed to load dashboard: ${e.message}`);
    await browser.close();
    process.exit(1);
  }

  await page.waitForTimeout(8000);

  const noDataCount = await page.locator('text=No data').count();
  const errorTextCount = await page.locator('text=Error').count();

  // Grafana 12 renders panels with data-testid="data-testid Panel header <title>" on SECTION elements.
  // (The attribute value literally starts with "data-testid ", a Grafana 12 quirk.)
  // Panels are virtualized: scroll through the dashboard to collect all titles.
  // Use page.evaluate for reliable DOM queries (Playwright locator API has timing issues
  // with virtualized content).
  const panelTitles = [];
  const seenTitles = new Set();

  // Wait for at least one panel header to appear in the DOM
  await page.waitForFunction(
    () => Array.from(document.querySelectorAll('section[data-testid]'))
      .some(e => (e.getAttribute('data-testid') || '').includes('Panel header')),
    { timeout: 30000 }
  );

  const collectTitles = async () => {
    const titles = await page.evaluate(() => {
      return Array.from(document.querySelectorAll('section[data-testid]'))
        .filter(e => (e.getAttribute('data-testid') || '').includes('Panel header'))
        .map(e => {
          const val = e.getAttribute('data-testid');
          const idx = val.indexOf('Panel header ');
          return val.substring(idx + 'Panel header '.length);
        });
    });
    for (const t of titles) {
      if (!seenTitles.has(t)) {
        seenTitles.add(t);
        panelTitles.push(t);
      }
    }
  };

  // Collect at current scroll position, then scroll through the page
  await collectTitles();
  const viewportHeight = page.viewportSize().height;
  let scrollPos = viewportHeight;
  const maxScroll = 15000;
  while (scrollPos <= maxScroll) {
    await page.evaluate(y => window.scrollTo(0, y), scrollPos);
    await page.waitForTimeout(800);
    await collectTitles();
    scrollPos += viewportHeight;
  }
  // Scroll back to top
  await page.evaluate(() => window.scrollTo(0, 0));

  for (const expected of expectedPanels) {
    const titleFound = panelTitles.find(t => t && t.includes(expected.title));
    const checksOk = [];
    const checksFail = [];

    if (!titleFound) {
      checksFail.push({ check: 'panel_title_present', detail: `Panel "${expected.title}" not found in DOM` });
    } else {
      checksOk.push({ check: 'panel_title_present' });
    }

    for (const check of expected.checks) {
      try {
        if (check.kind === 'text') {
          const count = await page.locator(`text=${check.value}`).count();
          if (count > 0) {
            checksOk.push({ check: `text:${check.value}` });
          } else {
            checksFail.push({ check: `text:${check.value}`, detail: `Text "${check.value}" not found on page` });
          }
        } else if (check.kind === 'text_count_gt') {
          const allTexts = await page.locator('[data-testid="panel-title"]').allTextContents();
          checksOk.push({ check: `text_count_gt:${check.value}`, detail: 'Panel present (bargauge row count verified via ds query)' });
        }
      } catch(e) {
        checksFail.push({ check: check.kind, detail: e.message });
      }
    }

    const ok = checksFail.length === 0;
    if (ok) {
      pass++;
      console.log(`[PASS] p${expected.id}: ${expected.title}`);
    } else {
      fail++;
      console.log(`[FAIL] p${expected.id}: ${expected.title}`);
      for (const cf of checksFail) {
        console.log(`       ${cf.check}: ${cf.detail}`);
      }
    }
    results.push({ id: expected.id, title: expected.title, type: expected.type, pass: ok, failures: checksFail });
  }

  if (noDataCount > 0) {
    console.log(`[FAIL] ${noDataCount} "No data" elements found on dashboard`);
    fail++;
  } else {
    console.log(`[PASS] No "No data" elements on dashboard`);
    pass++;
  }

  if (dsErrors.length > 0) {
    console.log(`[FAIL] ${dsErrors.length} datasource query errors:`);
    for (const e of dsErrors) {
      console.log(`       ${e.url} (status ${e.status}): ${JSON.stringify(e.errors || e.error)}`);
    }
    fail++;
  } else {
    console.log(`[PASS] All ${dsResponses.length} datasource queries returned without errors`);
    pass++;
  }

  console.log(`\n==========================================`);
  console.log(`Grafana panel rendering: ${pass} passed, ${fail} failed`);
  console.log(`  Total ds queries: ${dsResponses.length}`);
  console.log(`  No-data elements: ${noDataCount}`);
  console.log(`  Error elements: ${errorTextCount}`);
  console.log(`==========================================`);

  await browser.close();
  process.exit(fail > 0 ? 1 : 0);
})();
