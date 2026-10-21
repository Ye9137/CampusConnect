const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const template = fs.readFileSync(path.join(__dirname, '../source/PortalTemplate.js'), 'utf8');
const agreements = fs.readFileSync(path.join(__dirname, '../source/PortalAgreements.js'), 'utf8');
const cfg = { origin: 'http://portal.test', username: 'test-user', password: 'dummy-password',
  userSelector: '', passwordSelector: '', submitSelector: '', submit: true };
const script = extra => template.replace('/*CAMPUS_CONFIG*/', JSON.stringify({ ...cfg, ...extra }))
  .replace('  /*CAMPUS_AGREEMENTS*/', agreements.trimEnd());
(async () => {
  const browser = await chromium.launch(process.env.CAMPUS_CHROME_PATH
    ? { executablePath: process.env.CAMPUS_CHROME_PATH, headless: true } : { headless: true });
  let checks = 0;
  const equal = (actual, expected) => { assert.equal(actual, expected); checks++; };
  try {
    const page = await browser.newPage();
    let html;
    await page.route('http://portal.test/**', route => route.fulfill({ contentType: 'text/html; charset=utf-8', body: html }));
    async function load(boxes, other = '') {
      html = `<!doctype html><html><body><form id="login"><input name="username"><input type="password">${boxes}<button type="button" onclick="submissions++">登录</button></form>${other}<script>window.submissions=0;window.agreementClicks=0;document.querySelectorAll('input[type=checkbox],[role=checkbox]').forEach(e=>e.addEventListener('click',()=>agreementClicks++));</script></body></html>`;
      await page.goto('http://portal.test/login');
    }
    await load('<input id="required" type="checkbox" required>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#required').isChecked(), true);
    equal(await page.evaluate(() => agreementClicks), 1);
    equal(await page.evaluate(script()), 'already-submitted');
    equal(await page.evaluate(() => agreementClicks), 1);
    await load('<label><input id="terms" type="checkbox">我已阅读并同意用户协议</label><label><input id="remember" type="checkbox">记住密码</label><label><input id="news" type="checkbox">订阅优惠广告</label>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#terms').isChecked(), true);
    equal(await page.locator('#remember').isChecked(), false);
    equal(await page.locator('#news').isChecked(), false);
    await load('<input id="remember" type="checkbox"><span>记住密码</span><input id="notice" type="checkbox"><span>本人承诺遵守网络安全法</span>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#notice').isChecked(), true);
    equal(await page.locator('#remember').isChecked(), false);
    await load('<label for="terms">Agree to terms</label><input id="terms" type="checkbox" checked>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.evaluate(() => agreementClicks), 0);
    await load('<input id="terms" type="checkbox" style="display:none"><label for="terms">同意服务协议</label>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#terms').isChecked(), true);
    await load('<label><input id="terms" type="checkbox" disabled required>同意服务协议</label>');
    equal(await page.evaluate(script()), 'agreement-required');
    equal(await page.evaluate(() => submissions), 0);
    await load('<label><input id="terms" type="checkbox" required onclick="event.preventDefault()">同意服务协议</label>');
    equal(await page.evaluate(script()), 'waiting-agreement');
    equal(await page.evaluate(() => submissions), 0);
    await page.evaluate(() => window.__campusAgreementAttempts.get(document.getElementById('terms')).started -= 3000);
    equal(await page.evaluate(script()), 'agreement-required');
    equal(await page.evaluate(() => agreementClicks), 1);
    equal(await page.evaluate(() => submissions), 0);
    await load('<span id="terms" role="checkbox" tabindex="0" aria-required="true" aria-checked="false" onclick="this.setAttribute(\'aria-checked\',\'true\')">同意条款</span>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#terms').getAttribute('aria-checked'), 'true');
    await load('<span id="terms" role="checkbox" tabindex="0" aria-required="true" aria-checked="false" onclick="setTimeout(()=>this.setAttribute(\'aria-checked\',\'true\'),100)">同意条款</span>');
    equal(await page.evaluate(script()), 'waiting-agreement');
    await page.waitForFunction(() => document.getElementById('terms').getAttribute('aria-checked') === 'true');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.evaluate(() => agreementClicks), 1);
    await load('<label><input id="terms" type="checkbox" required>同意条款</label>');
    equal(await page.evaluate(script({ origin: 'http://different.test' })), 'wrong-origin');
    equal(await page.locator('#terms').isChecked(), false);
    equal(await page.evaluate(script({ statusOnly: true })), 'not-submitted');
    equal(await page.locator('#terms').isChecked(), false);
    equal(await page.evaluate(script({ submit: false })), 'filled');
    equal(await page.locator('#terms').isChecked(), true);
    equal(await page.evaluate(() => submissions), 0);
    await load('<label><input id="terms" type="checkbox" required onchange="document.querySelector(\'input[type=password]\').value=\'\'">同意条款</label>');
    equal(await page.evaluate(script()), 'missing-fields');
    equal(await page.evaluate(() => submissions), 0);
    await load('', '<form><label><input id="other-form" type="checkbox" required>Agree to unrelated terms</label></form>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#other-form').isChecked(), false);
    html = fs.readFileSync(path.join(__dirname, 'fixtures/network-pledge.html'), 'utf8');
    await page.goto('http://portal.test/login');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#notice').isChecked(), true);
    equal(await page.evaluate(() => pledgeAtSubmit), true);
    equal(await page.locator('#remember').isChecked(), false);
    equal(await page.evaluate(() => pledgeEvents.join(',')), 'click,input,change');
    equal(await page.evaluate(script()), 'already-submitted');
    equal(await page.evaluate(() => submissions), 1);
    for (const markup of [
      '<label><input id="notice" type="checkbox">本人承诺遵守上网行为规范，文明上网</label>',
      '<input id="notice" type="checkbox"><font>本人承诺一切上网行为遵守网络管理规章制度</font>',
      '<div><span>本人承诺一切上网行为遵守网络管理规章制度</span><input id="notice" type="checkbox"></div>',
      '<input id="notice" type="checkbox">本人承诺一切上网行为遵守网络管理规章制度<br>',
      '<div><span><input id="notice" type="checkbox"></span><span>本人承诺遵守网络安全法</span></div>'
    ]) {
      await load(markup + '<label><input id="remember" type="checkbox">记住密码</label>');
      equal(await page.evaluate(script()), 'submitted');
      equal(await page.locator('#notice').isChecked(), true);
      equal(await page.locator('#remember').isChecked(), false);
    }
    // A shared form/container must not make the remember/marketing box look like terms.
    await load('<input id="remember" type="checkbox"><span>记住密码</span><br><input id="notice" type="checkbox"><span>本人承诺遵守网络安全法</span><br><input id="news" type="checkbox"><span>订阅优惠广告</span>');
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.locator('#notice').isChecked(), true);
    equal(await page.locator('#remember').isChecked(), false);
    equal(await page.locator('#news').isChecked(), false);
    await load('<input id="notice" type="checkbox"><span>本人承诺遵守网络安全法</span>');
    await page.locator('#notice').check();
    equal(await page.evaluate(script()), 'submitted');
    equal(await page.evaluate(() => agreementClicks), 1);
    await load('<input id="notice" type="checkbox" onclick="event.preventDefault()"><span>本人承诺遵守网络安全法</span>');
    equal(await page.evaluate(script()), 'waiting-agreement');
    equal(await page.evaluate(() => submissions), 0);
    // Screenshot regression: a missing service must not skip the pledge checkbox.
    html = fs.readFileSync(path.join(__dirname, 'fixtures/network-pledge.html'), 'utf8');
    await page.goto('http://portal.test/login');
    await page.locator('#remember').check();
    equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    equal(await page.locator('#notice').isChecked(), true);
    equal(await page.locator('#remember').isChecked(), true);
    equal(await page.evaluate(() => submissions), 0);
    equal(await page.evaluate(() => pledgeEvents.join(',')), 'click,input,change');
    equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    equal(await page.locator('#notice').isChecked(), true);
    equal(await page.evaluate(() => pledgeEvents.join(',')), 'click,input,change');
    equal(await page.evaluate(script({serviceOption:''})), 'submitted');
    equal(await page.evaluate(() => pledgeAtSubmit), true);
    equal(await page.evaluate(() => submissions), 1);
    // An unselected operator still waits, while the independent pledge is checked.
    await load('<select><option value="">选择运营商</option><option value="cmcc">中国移动</option></select><div><input id="notice" type="checkbox"><span>本人承诺遵守网络安全法</span></div><label><input id="remember" type="checkbox">记住密码</label>');
    equal(await page.evaluate(script()), 'service-required');
    equal(await page.locator('#notice').isChecked(), true);
    equal(await page.locator('#remember').isChecked(), false);
    equal(await page.evaluate(() => submissions), 0);
    equal(await page.evaluate(script()), 'service-required');
    equal(await page.evaluate(() => agreementClicks), 1);
    // Keep service-before-agreement order: page change handlers may reset consent.
    await load('<select onchange="document.getElementById(&quot;notice&quot;).checked=false"><option value="">选择运营商</option><option value="cmcc">中国移动</option></select><label><input id="notice" type="checkbox" checked>本人承诺遵守网络安全法</label>');
    equal(await page.evaluate(script({serviceOption:'中国移动'})), 'submitted');
    equal(await page.locator('#notice').isChecked(), true);
    equal(await page.evaluate(() => agreementClicks), 1);
    // Rejected or disabled consent never turns a service error into a login.
    await load('<label><input id="notice" type="checkbox" disabled>本人承诺遵守网络安全法</label>');
    equal(await page.evaluate(script({serviceOption:'中国移动'})), 'agreement-required');
    equal(await page.evaluate(() => submissions), 0);
    await load('<label><input id="notice" type="checkbox" onclick="event.preventDefault()">本人承诺遵守网络安全法</label>');
    equal(await page.evaluate(script({serviceOption:'中国移动'})), 'waiting-agreement');
    equal(await page.evaluate(() => submissions), 0);
    console.log(`PASS: ${checks} agreement checks (required, terms, hidden controls, event handlers, duplicate prevention, manual blockers, origin, and unrelated options).`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });
