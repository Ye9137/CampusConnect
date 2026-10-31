const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');

// The received artifact contains the complete BODY and inline school scripts,
// but no HEAD, external JavaScript implementations, or external stylesheet.
// Keep that real markup intact; serve every missing dependency as an explicit
// test mock. These tests establish DOM compatibility, not live authentication.
const fixture = fs.readFileSync(path.join(__dirname, 'fixtures/jiangnong-eportal.html'), 'utf8');
const jquery = fs.readFileSync(require.resolve('jquery/dist/jquery.min.js'), 'utf8');
const origin = 'http://gateway.test';
const entry = origin + '/eportal/index.jsp?t=wireless-v2&wlanuserip=fixture-wlanuserip&mac=fixture-mac';
const config = {origin, username:'fixture-account', password:'fixture-secret', userSelector:'',
  passwordSelector:'', submitSelector:'', submit:true, confirmSubmit:true, serviceOption:''};
const sources = [{name:'current', read:name => fs.readFileSync(path.join(__dirname, '../..', name), 'utf8')}];
// Optional analyst comparison; normal CI needs only the checked-out sources.
// No reference-client executable or extracted private JavaScript is required.
if (process.env.CAMPUS_COMPARE_BASELINE === '1') {
  sources.push({name:'baseline-65fc0e6', read:name => execFileSync('git', ['show', '65fc0e6:' + name],
    {cwd:path.join(__dirname, '../..'), encoding:'utf8'})});
}
function production(source, overrides = {}) {
  let template = source.read('Windows/source/PortalTemplate.js');
  for (const [marker, name] of Object.entries({ACCOUNT:'PortalAccount', GPORTAL:'PortalGportal',
    AGREEMENTS:'PortalAgreements', CAPTCHA:'PortalCaptcha'})) {
    template = template.replace(`/*CAMPUS_${marker}*/`, source.read(`Windows/source/${name}.js`));
  }
  return template.replace('/*CAMPUS_CONFIG*/', JSON.stringify({...config, ...overrides}));
}
function mockMissingExternalJavaScript(withLogin) {
  // AuthInterFace, doauthen, getQueryString, and jqueryBind were not supplied.
  // Exercise both possible API shapes without claiming which the school uses.
  window.__fixtureCalls = {init:0, pageInfo:0, services:0, onlineInfo:0, bindings:0, loginApi:0, transport:0, clicks:[]};
  window.getQueryString = () => location.search.slice(1);
  window.jqueryBind = () => { window.__fixtureCalls.bindings++; };
  window.AuthInterFace = {
    init(base) { window.__fixtureCalls.init++; if (base !== './') throw Error('unexpected school API base'); },
    pageInfo(query, callback) {
      window.__fixtureCalls.pageInfo++;
      callback({successPage:'false', passwordEncrypt:'false', publicKeyExponent:'10001',
        publicKeyModulus:'fixture-public-key', isToCasPage:'false', validCodeUrl:''});
    },
    getServices(query, callback) {
      window.__fixtureCalls.services++;
      callback({isService:'false', defaultService:'', serviceContent:'', serviceJson:'[]'});
    },
    getOnlineUserInfo(query, callback) {
      window.__fixtureCalls.onlineInfo++;
      callback({result:'fail', userIndex:''});
    }
  };
  if (withLogin) window.AuthInterFace.login = function (record, callback) {
    window.__fixtureCalls.loginApi++;
    if (callback) callback({result:'success'});
  };
  window.doauthen = function fixtureDoauthen() {
    const calls = window.__fixtureCalls;
    const record = {username:document.getElementById('username').value,
      password:document.getElementById('pwd').value, initialized:calls.pageInfo > 0 && calls.services > 0};
    calls.clicks.push(record);
    if (typeof window.AuthInterFace.login === 'function') window.AuthInterFace.login(record, () => {});
    else calls.transport++;
  };
}
// Only supplies dimensions missing from the received CSS. It does not override
// inline display:none on the actual service, operator and CAPTCHA containers.
const missingStylesheetMock = '#loginLink{display:inline-block}#loginLink_div{width:275px;height:54px}';
let checks = 0;
function check(actual, expected, label) { assert.deepEqual(actual, expected, label); checks++; }

(async () => {
  const browser = await chromium.launch(process.env.CAMPUS_CHROME_PATH
    ? {executablePath:process.env.CAMPUS_CHROME_PATH, headless:true} : {headless:true});
  try {
    for (const source of sources) {
      const baseline = source.name.startsWith('baseline-');
      const expectedReady = baseline ? undefined : {pageInfo:true, getServices:true, failed:false};
      async function open({withLogin = true, holdBackground = false, unknownInit = false} = {}) {
        const page = await browser.newPage();
        const errors = [];
        const network = [];
        let background;
        page.on('pageerror', error => errors.push(error.message));
        page.on('request', request => network.push(request.url()));
        await page.addInitScript(source.read('macOS/source/PortalBootstrap.js')
          .replace('/*CAMPUS_ORIGIN*/', JSON.stringify(origin)));
        await page.route('**/*', async route => {
          const url = new URL(route.request().url());
          if (url.origin === origin && url.pathname === '/eportal/index.jsp') {
            const dependencies = '<link rel="stylesheet" href="/__fixture__/missing.css">' +
              '<script src="/__fixture__/jquery.js"></script><script src="/__fixture__/missing.js"></script>';
            // Negative control only: a different initialization contract must
            // keep its load-event timing. The stored real fixture is unchanged.
            const body = unknownInit ? fixture.replace('function initPage() {',
              'function initPage() { window.__fixtureUnknownInit = (window.__fixtureUnknownInit || 0) + 1;') : fixture;
            return route.fulfill({contentType:'text/html; charset=utf-8', body:dependencies + body});
          }
          if (url.pathname === '/__fixture__/jquery.js')
            return route.fulfill({contentType:'application/javascript', body:jquery});
          if (url.pathname === '/__fixture__/missing.js')
            return route.fulfill({contentType:'application/javascript',
              body:`(${mockMissingExternalJavaScript.toString()})(${JSON.stringify(withLogin)})`});
          if (url.pathname === '/__fixture__/missing.css')
            return route.fulfill({contentType:'text/css', body:missingStylesheetMock});
          if (url.port === '8080' && url.pathname.endsWith('/bg.jpg') && holdBackground) {
            background = route; return;
          }
          // Logos, background images and ancillary resources are unavailable;
          // no request is allowed to reach a real school or public server.
          return route.fulfill({status:204});
        });
        await page.goto(entry, {waitUntil:holdBackground ? 'domcontentloaded' : 'load'});
        return {page, errors, network, releaseBackground:async () => {
          assert.ok(background, 'actual 8080 background request is held');
          await background.fulfill({status:204});
          await page.waitForLoadState('load');
        }};
      }
      for (const withLogin of [true, false]) {
        const {page, errors, network} = await open({withLogin});
        try {
          check(await page.evaluate(() => ({pageInfo:__fixtureCalls.pageInfo, services:__fixtureCalls.services,
            bindings:__fixtureCalls.bindings, onload:window.onload, bootstrapReady:window.__campusReady})),
          {pageInfo:1, services:1, bindings:1, onload:null, bootstrapReady:expectedReady},
          'known original initialization runs once, with current callback readiness tracking');
          check(await page.locator('#isDisplayServicesTip').isVisible(), false, 'actual services are hidden');
          check(await page.locator('#isDisplayValidCode').isVisible(), false, 'actual CAPTCHA is hidden');
          check(await page.locator('#isNoOperatorUserIdFrameId').isVisible(), false, 'actual operator account is hidden');
          check(await page.locator('#isNoOperatorPasswordFrameId').isVisible(), false, 'actual operator password is hidden');
          const results = [];
          for (let attempt = 0; attempt < 4; attempt++) {
            results.push(await page.evaluate(production(source)));
            if (results.at(-1) === 'submitted' || results.at(-1) === 'authenticated') break;
          }
          const blockedByBaselineApiGuard = baseline && !withLogin;
          if (blockedByBaselineApiGuard) {
            check(results, ['waiting-ready','waiting-ready','waiting-ready','waiting-ready'],
              'baseline requires AuthInterFace.login even though the original click handler exists');
            check(await page.evaluate(() => __fixtureCalls.clicks.length), 0, 'baseline API-shape guard prevents the original handler');
          } else {
            check(results.at(-1), 'submitted', 'current production script reaches the original page click handler');
            check(await page.evaluate(() => __fixtureCalls.clicks),
              [{username:config.username, password:config.password, initialized:true}],
              'mocked original handler receives exactly the configured credentials after initialization');
            check(await page.locator('#loginLink').getAttribute('class'), 'loginButtonHKClicked_1',
              'the received inline onclick is executed, including its class assignment');
            check(await page.evaluate(() => __fixtureCalls.loginApi), withLogin ? 1 : 0, 'mock API call count matches the explicitly modeled API shape');
            check(await page.evaluate(() => __fixtureCalls.transport), withLogin ? 0 : 1, 'only the mock alternative transport is used without login API');
            const repeat = await page.evaluate(production(source));
            check(['already-submitted','authenticated'].includes(repeat), true, 'repeat evaluation does not resubmit');
            check(await page.evaluate(() => __fixtureCalls.clicks.length), 1, 'original handler is activated once');
          }
          check(errors, [], 'all received inline scripts run under the explicitly modeled dependencies');
          check(network.every(url => new URL(url).hostname.endsWith('.test')), true, 'every resource request remains in the offline fixture hosts');
          console.log(`${source.name} AuthInterFace.login=${withLogin}: ${results.join(' -> ')} (mock dependencies)`);
        } finally { await page.close(); }
      }
      const manual = await open({withLogin:false});
      try {
        check(await manual.page.evaluate(production(source, {submit:false})), 'filled', 'manual mode still fills actual DOM without an API-shape dependency');
        check(await manual.page.evaluate(() => __fixtureCalls.clicks.length), 0, 'manual mode does not activate the page handler');
        check(await manual.page.evaluate(production(source, {origin:'http://other.test'})), 'wrong-origin', 'actual DOM retains the cross-origin credential guard');
        await manual.page.evaluate(() => { delete window.doauthen; });
        check(await manual.page.evaluate(production(source)), 'waiting-ready', 'missing original page handler remains a readiness failure');
      } finally { await manual.page.close(); }
      const pending = await open({holdBackground:true});
      try {
        check(await pending.page.evaluate(() => ({readyState:document.readyState, pageInfo:__fixtureCalls.pageInfo,
          services:__fixtureCalls.services, bindings:__fixtureCalls.bindings, bootstrapReady:window.__campusReady})),
        {readyState:'interactive', pageInfo:baseline ? 0 : 1, services:baseline ? 0 : 1,
          bindings:baseline ? 0 : 1, bootstrapReady:expectedReady},
        'current recognizes the exact named three-call initializer while baseline waits for the 8080 image');
        if (baseline) {
          check(await pending.page.evaluate(production(source)), 'waiting-ready',
            'baseline cannot reach this known login form while the background blocks load');
          check(await pending.page.evaluate(() => __fixtureCalls.clicks.length), 0, 'baseline waiting-ready does not activate the original handler');
        } else {
          check(await pending.page.evaluate(production(source)), 'waiting-submit', 'current prepares the original handler before the background finishes');
          check(await pending.page.evaluate(production(source)), 'submitted', 'current triggers the page handler while decorative background remains pending');
          check(await pending.page.evaluate(() => ({readyState:document.readyState, clicks:__fixtureCalls.clicks})),
            {readyState:'interactive', clicks:[{username:config.username, password:config.password, initialized:true}]},
            'pre-load activation waits for the explicitly modeled pageInfo/services callbacks');
        }
        await pending.releaseBackground();
        check(await pending.page.evaluate(() => [__fixtureCalls.pageInfo, __fixtureCalls.services, __fixtureCalls.bindings]), [1,1,1],
          'late image completion never repeats initialization or binding');
        check(await pending.page.locator('#username').inputValue(), baseline ? '' : config.username, 'late load preserves the current filled account');
        check(await pending.page.locator('#pwd').inputValue(), baseline ? '' : config.password, 'late load preserves the current filled password');
      } finally { await pending.page.close(); }
      const unknown = await open({holdBackground:true, unknownInit:true});
      try {
        check(await unknown.page.evaluate(() => ({pageInfo:__fixtureCalls.pageInfo, services:__fixtureCalls.services,
          ready:window.__campusReady, customRuns:window.__fixtureUnknownInit})),
        {pageInfo:0, services:0, ready:undefined, customRuns:undefined},
        'unknown named initialization with an extra statement is not executed early');
        check(await unknown.page.evaluate(production(source)), 'waiting-ready', 'unknown initialization retains the full-load guard');
        await unknown.releaseBackground();
        check(await unknown.page.evaluate(() => [__fixtureCalls.pageInfo, __fixtureCalls.services,
          __fixtureCalls.bindings, window.__fixtureUnknownInit]), [1,1,1,1],
        'unknown initializer keeps its original once-per-load behavior');
      } finally { await unknown.page.close(); }
    }
    console.log(`PASS: ${checks} Jiangnong actual-DOM checks; missing external code/CSS explicitly mocked, no live campus authentication.`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
