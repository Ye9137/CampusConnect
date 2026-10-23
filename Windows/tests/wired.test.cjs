const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs/promises');
const { pathToFileURL } = require('node:url');
(async () => {
  const browser = await chromium.launch(process.env.CAMPUS_CHROME_PATH ? {executablePath:process.env.CAMPUS_CHROME_PATH,headless:true} : {headless:true});
  try {
    const page = await browser.newPage({viewport:{width:1280,height:860}});
    const errors=[]; page.on('pageerror',e=>errors.push(e.message));
    await page.addInitScript(()=>{window.commands=[];window.chrome={webview:{postMessage:m=>commands.push(m),addEventListener:()=>{}}};});
    await page.goto(pathToFileURL(path.resolve(__dirname,'../source/Desktop.html')).href);
    const profile={ssid:'Campus',useSavedWifiProfile:true,portalEnabled:true,portalUrl:'http://192.0.2.1',username:'test-account',autoSubmit:true,automatic:false};
    await page.evaluate(profile=>{campus.receive({kind:'profile',profile,password:'dummy-password'});campus.receive({kind:'page',page:'settings'});},profile);
    await page.waitForFunction(()=>document.getAnimations().length===0);
    assert(await page.locator('#wifi-settings').isVisible());
    await page.locator('[data-connection="wired"]').click();
    assert.equal(await page.locator('#ssid').inputValue(),'');
    assert.equal(await page.locator('#ssid-field').isVisible(),false);
    assert.equal(await page.locator('[data-connection="wired"]').getAttribute('aria-pressed'),'true');
    assert.equal(await page.locator('#wifi-mode').isVisible(),false);
    assert.equal(await page.locator('#wifi-settings').isVisible(),false);
    assert.match(await page.locator('#join-help').textContent(),/有线网页认证/);
    assert.equal(await page.locator('#username').inputValue(),'');
    assert.equal(await page.locator('#portalUrl').inputValue(),'');
    await page.locator('#username').fill('wired-account');
    await page.locator('#password').fill('wired-secret');
    await page.locator('#portalUrl').fill('http://192.0.2.2');
    await page.locator('#save-enable').click();
    const saved=await page.evaluate(()=>commands.filter(m=>m.command==='save').at(-1));
    assert.equal(saved.profile.ssid,''); assert.equal(saved.profile.automatic,true);
    assert.equal(saved.profile.username,'wired-account'); assert.equal(saved.password,'wired-secret');
    const state={target:'有线网络',wiredMode:true,campusConnected:true,internetOnline:false,busy:false,automatic:true,permissionNeeded:false,connectionTitle:'有线网络已连接 · 未联网',networks:[]};
    await page.evaluate(({saved,state})=>{campus.receive({kind:'profile',profile:saved.profile,password:saved.password});campus.receive({kind:'state',state});campus.receive({kind:'page',page:'dashboard'});},{saved,state});
    await page.waitForFunction(()=>document.getAnimations().length===0);
    assert.equal(await page.locator('#permission-card').isVisible(),false);
    assert.match(await page.locator('#networks').textContent(),/以太网/);
    assert.equal(await page.locator('.brand-name').textContent(),'校园Wi-Fi小助手');
    assert.equal(await page.locator('#connection-icon').getAttribute('data-icon'),'network');
    assert.equal(await page.locator('#dashboard-icon').getAttribute('data-icon'),'network');
    assert.equal(await page.locator('#settings-network-icon').getAttribute('data-icon'),'network');
    await page.evaluate(state=>campus.receive({kind:'state',state:{...state,networks:[{ssid:'Stale Wi-Fi',signal:90}]}}),state);
    assert.equal(await page.locator('.network-row').count(),0);
    assert.equal(await page.locator('#target').textContent(),'有线网络');
    assert.equal(await page.locator('#status-dot').evaluate(e=>e.classList.contains('online')),false);
    const out=path.resolve(__dirname,'../../work/ui-preview');await fs.mkdir(out,{recursive:true});
    await page.screenshot({path:path.join(out,'wired-dashboard.png')});
    await page.evaluate(()=>campus.receive({kind:'page',page:'portal'}));
    await page.waitForFunction(()=>document.getAnimations().length===0);
    assert.equal(await page.locator('#portal-connection-hint').textContent(),'请先接好网线并启用以太网');
    assert.equal(await page.locator('[data-action="openPortal"]').isEnabled(),true);
    await page.locator('[data-action="openPortal"]').click();
    assert(await page.evaluate(()=>commands.some(m=>m.command==='openPortal')));
    await page.evaluate(state=>campus.receive({kind:'state',state:{...state,campusConnected:false}}),state);
    assert.equal(await page.locator('[data-action="openPortal"]').isEnabled(),false);
    // Switching back restores the saved Wi-Fi connection options and keeps portal credentials.
    await page.evaluate(()=>campus.receive({kind:'page',page:'settings'}));
    await page.waitForFunction(()=>document.getAnimations().length===0);
    await page.screenshot({path:path.join(out,'wired-settings.png')});
    await page.locator('[data-connection="wifi"]').click();
    assert.equal(await page.locator('#ssid').inputValue(),'Campus');
    assert.equal(await page.locator('#wifi-mode').isVisible(),true);
    assert.equal(await page.locator('#wifi-settings').isVisible(),true);
    assert.equal(await page.locator('#username').inputValue(),'test-account');
    await page.locator('#save').click();
    assert.equal(await page.evaluate(()=>commands.filter(m=>m.command==='save').at(-1).profile.ssid),'Campus');
    // Each protocol saves its own method and only shows relevant configuration.
    await page.locator('[data-connection="wired"]').click();
    for(const method of ['pppoe','dot1x','client','web']){
      await page.locator('#wiredAuth').selectOption(method);
      assert.equal(await page.locator('#ethernet-field').isVisible(),method!=='pppoe');
      assert.equal(await page.locator('#portal-card').isVisible(),method==='web');
      assert.equal(await page.locator('#pppoe-fields').isVisible(),method==='pppoe');
      assert.equal(await page.locator('#dot1x-help').isVisible(),method==='dot1x');
      assert.equal(await page.locator('#client-fields').isVisible(),method==='client');
      if(method==='pppoe')await page.locator('#broadbandName').fill('School broadband');
      if(method==='client')await page.evaluate(()=>campus.receive({kind:'authClient',path:'C:\\School\\client.exe'}));
      await page.locator('#save').click();
      const value=await page.evaluate(()=>commands.filter(m=>m.command==='save').at(-1).profile);
      assert.equal(value.wiredAuth,method); assert.equal(value.ssid,'');
      assert.equal(value.username,'wired-account');
    }
    // The currently saved mode remains authoritative while a different draft is edited.
    await page.evaluate(state=>campus.receive({kind:'state',state:{...state,wiredAuth:'pppoe',webPortalEnabled:false}}),state);
    await page.evaluate(()=>campus.receive({kind:'page',page:'portal'}));
    await page.waitForFunction(()=>document.getAnimations().length===0);
    assert.equal(await page.locator('[data-action="openPortal"]').isEnabled(),false);
    assert.match(await page.locator('#portal-connection-hint').textContent(),/系统认证/);
    // Dirty wired mode and the previous SSID survive a renderer restart.
    const snapshot=await page.evaluate(()=>campus.snapshot());
    await page.reload();
    await page.evaluate(({profile,state,snapshot})=>{
      campus.receive({kind:'profile',profile,password:'dummy-password'});
      campus.receive({kind:'state',state});
      campus.receive({kind:'restore',page:'settings',snapshot});
    },{profile,state,snapshot});
    await page.waitForFunction(()=>document.getAnimations().length===0);
    assert.equal(await page.locator('[data-connection="wired"]').getAttribute('aria-pressed'),'true');
    await page.locator('[data-connection="wifi"]').click();
    assert.equal(await page.locator('#ssid').inputValue(),'Campus');
    // Explicit Wi-Fi mode remains selected when its SSID is cleared. Legacy blank SSIDs still migrate as wired.
    await page.locator('#ssid').fill('');
    assert.equal(await page.locator('[data-connection="wifi"]').getAttribute('aria-pressed'),'true');
    await page.evaluate(()=>campus.receive({kind:'profile',profile:{ssid:'',portalEnabled:true,autoSubmit:true},password:''}));
    assert.equal(await page.locator('[data-connection="wired"]').getAttribute('aria-pressed'),'true');
    assert.deepEqual(errors,[]);
    console.log('PASS: wired save/reload, Wi-Fi option hiding, no location prompt, connected/disconnected portal controls, and switching back to Wi-Fi.');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
