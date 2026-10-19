const {chromium} = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const bootstrap = fs.readFileSync(path.join(__dirname, '../../macOS/source/PortalBootstrap.js'), 'utf8')
  .replace('/*CAMPUS_ORIGIN*/', JSON.stringify('http://portal.test'));
const template = fs.readFileSync(path.join(__dirname, '../source/PortalTemplate.js'), 'utf8');
const script = extra => template.replace('/*CAMPUS_CONFIG*/', JSON.stringify({origin:'http://portal.test', username:'fixture-user', password:'fixture-password', submit:false, ...extra}));
// Synthetic reproduction of an operator popup covering the connection button.
const fixture = fs.readFileSync(path.join(__dirname, 'fixtures/operator-popup.html'), 'utf8');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH}:{})});
  try {
    const page=await browser.newPage({viewport:{width:680,height:500}});
    await page.addInitScript(bootstrap);
    await page.route('http://portal.test/**',route=>route.fulfill({contentType:'text/html; charset=utf-8',body:fixture}));
    page.on('pageerror',error=>console.error('PAGE ERROR:',error.message));
    const reset=()=>page.goto('http://portal.test/login');
    const hidden=selector=>page.waitForFunction(selector=>getComputedStyle(document.querySelector(selector)).display==='none',selector,{timeout:2000});
    const exposed=()=>page.locator('#loginLink').evaluate(button=>{const box=button.getBoundingClientRect();return button.contains(document.elementFromPoint(box.x+box.width/2,box.y+box.height/2))});
    await reset();
    await page.locator('#serviceShowHideTop').click();
    assert.equal(await exposed(),false,'reproduction really covers the connection button');
    await page.locator('#bch_service_1').click();
    await hidden('#serviceShowHide');
    assert.equal(await page.locator('#serviceShowHide').isVisible(),false,'manual choice collapses before autofill');
    assert.equal(await page.locator('#net_access_type').inputValue(),'1','school internal value preserved');
    assert.equal(await exposed(),true,'connection button uncovered');
    assert.equal(await page.locator('#serviceShowHideTop').getAttribute('aria-expanded'),'false');
    await page.locator('#serviceShowHideTop').click();
    assert.equal(await page.locator('#serviceShowHide').isVisible(),true,'can reopen after fallback');
    await page.locator('#bch_service_1').click();
    await hidden('#serviceShowHide');
    assert.equal(await page.locator('#serviceShowHide').isVisible(),false,'same choice also collapses');
    await page.locator('#loginLink').click();
    assert.equal(await page.evaluate(()=>clicks),1,'exposed button receives a real pointer click');
    assert.equal(await page.locator('#unrelated').isVisible(),true,'unrelated menu remains visible');
    await reset();
    assert.equal(await page.evaluate(script({serviceOption:'联通'})),'filled');
    assert.equal(await page.locator('#serviceShowHide').isVisible(),false,'automatic selection collapses');
    assert.equal(await page.locator('#net_access_type').inputValue(),'2');
    assert.equal(await page.evaluate(()=>serviceEvents),1,'original choice handler called once');
    await page.locator('#serviceShowHideTop').click();
    assert.equal(await page.locator('#serviceShowHide').isVisible(),true);
    await page.locator('#bch_service_3').click();
    await hidden('#serviceShowHide');
    assert.equal(await page.locator('#serviceShowHide').isVisible(),false,'manual change after filling collapses');
    assert.equal(await page.locator('#net_access_type').inputValue(),'3');
    await reset();
    await page.evaluate(()=>rejectChoice=true);
    assert.equal(await page.evaluate(script({serviceOption:'电信'})),'missing-service');
    assert.equal(await page.locator('#serviceShowHide').isVisible(),true,'rejected choice stays open');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset();
    await page.evaluate(()=>{serviceShowHideTop.addEventListener('keydown',event=>{if(event.key==='Escape'){window.escapes=(window.escapes||0)+1;serviceShowHide.style.display='none'}})});
    assert.equal(await page.evaluate(script({serviceOption:'电信'})),'filled');
    assert.equal(await page.evaluate(()=>escapes),1,'school Escape handler preferred');
    assert.equal(await page.locator('#serviceShowHide').evaluate(e=>e.style.getPropertyPriority('display')),'','no forced style when school dismisses');
    // Accessible custom operator popup, including lazy options and reopening.
    await reset();
    await page.route('http://portal.test/accessible', route=>route.fulfill({contentType:'text/html; charset=utf-8',body:`<input name=username><input type=password><button type=button id=connect>连接</button>
      <button role=combobox aria-controls=options aria-expanded=false id=choose>选择运营商</button>
      <ul role=listbox id=options style="display:none"><li role=option>校园专线 A</li><li role=option aria-disabled=true>禁用线路</li></ul>
      <script>choose.onclick=()=>{const open=choose.getAttribute('aria-expanded')!=='true';choose.setAttribute('aria-expanded',String(open));options.style.display=open?'block':'none'};
      document.querySelector('[role=option]').onclick=function(){choose.textContent=this.textContent;this.setAttribute('aria-selected','true')};</script>`}));
    await page.goto('http://portal.test/accessible');
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A'})),'filled');
    assert.equal(await page.locator('#options').isVisible(),false);
    await page.locator('#choose').click();
    assert.equal(await page.locator('#options').isVisible(),true);
    await page.locator('[aria-disabled=true]').click({force:true});
    assert.equal(await page.locator('#options').isVisible(),true,'disabled choice does not dismiss');
    await page.locator('[role=option]').first().click();
    await hidden('#options');
    assert.equal(await page.locator('#options').isVisible(),false,'accessible manual choice dismisses');
    const other=await browser.newPage();
    await other.addInitScript(bootstrap);
    await other.route('http://other.test/**',r=>r.fulfill({contentType:'text/html',body:fixture}));
    await other.goto('http://other.test/login');
    assert.equal(await other.evaluate(()=>typeof window.__campusCollapseServiceMenu),'undefined','origin gate preserved');
    if(process.env.CAMPUS_COLLAPSE_SCREENSHOT){
      await reset();await page.locator('#serviceShowHideTop').click();
      await page.screenshot({path:process.env.CAMPUS_COLLAPSE_SCREENSHOT+'-before.png'});
      await page.locator('#bch_service_2').click();await hidden('#serviceShowHide');
      await page.screenshot({path:process.env.CAMPUS_COLLAPSE_SCREENSHOT+'-after.png'});
    }
    console.log('PASS: operator popup pointer hit testing, manual/automatic/same selection, reopening, school handlers, rejected/disabled options, unrelated menus and origin isolation.');
  } finally {await browser.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
