const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

(async () => {
  const browser = await chromium.launch(process.env.CAMPUS_CHROME_PATH ? {executablePath:process.env.CAMPUS_CHROME_PATH,headless:true} : {headless:true});
  try {
    const page = await browser.newPage({viewport:{width:1280,height:860},colorScheme:'light'});
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.addInitScript(() => {window.commands=[];window.chrome={webview:{postMessage:m=>window.commands.push(m),addEventListener:()=>{}}};});
    await page.goto(pathToFileURL(path.resolve(__dirname,'../source/Desktop.html')).href);
    const profile = {ssid:'HNPI-STU',portalUrl:'http://192.168.0.123',username:'',useSavedWifiProfile:false,portalEnabled:true,autoSubmit:true,automatic:false,userSelector:'',passwordSelector:'',submitSelector:''};
    const state = {target:'HNPI-STU',currentSsid:null,campusConnected:false,connectionTitle:'当前未连接 Wi-Fi',automatic:false,busy:false,diagnosing:false,permissionNeeded:true,lastScan:'12:30',status:'请允许读取 Wi-Fi 名称，然后刷新网络。',portalStatus:'连接校园网后，在这里完成上网认证。',portalAddress:'',report:'回到校园网后点击“开始诊断”，对比网络接口、DNS 和代理结果。',networks:[],logs:[{time:'12:30:01',text:'已载入 HNPI-STU 配置。'}]};
    await page.evaluate(({profile,state})=>{campus.receive({kind:'profile',profile,password:''});campus.receive({kind:'state',state});},{profile,state});
    assert.equal(await page.locator('.nav button').count(),3);
    assert.equal(await page.locator('#permission-card').isVisible(),true);
    assert.equal(await page.locator('#page-diagnostics,#page-activity').count(),0);
    assert.equal(await page.locator('.author').textContent(),'By Ye');
    await page.evaluate(state=>campus.receive({kind:'state',state:{...state,campusConnected:true,internetOnline:false}}),state);
    assert.equal(await page.locator('#status-dot').evaluate(e=>e.classList.contains('online')),false);
    await page.evaluate(state=>campus.receive({kind:'state',state:{...state,campusConnected:true,internetOnline:true}}),state);
    assert.equal(await page.locator('#status-dot').evaluate(e=>e.classList.contains('online')),true);
    await page.evaluate(state=>campus.receive({kind:'state',state}),state);

    assert.equal(await page.locator('.license-note').textContent(),'MIT 开源项目');
    assert.deepEqual(await page.locator('.author').evaluate(e=>({align:getComputedStyle(e).textAlign,size:getComputedStyle(e).fontSize})),{align:'left',size:'11px'});
    assert.equal(await page.locator('.author').evaluate(e=>getComputedStyle(e).color),await page.locator('.license-note').evaluate(e=>getComputedStyle(e).color));
    // Real pointer movement switches without a click and preserves drafts.
    await page.locator('[data-page="settings"]').hover();
    await page.waitForFunction(()=>document.querySelector('[data-page="settings"]').classList.contains('active'));
    await page.locator('#username').fill('hover-draft');
    await page.locator('[data-page="portal"]').hover();
    await page.waitForFunction(()=>document.querySelector('[data-page="portal"]').classList.contains('active'));
    await page.locator('[data-page="settings"]').hover();
    await page.waitForFunction(()=>document.querySelector('[data-page="settings"]').classList.contains('active'));
    assert.equal(await page.locator('#username').inputValue(),'hover-draft');
    await page.locator('[data-page="dashboard"]').hover();
    await page.waitForFunction(()=>document.querySelector('[data-page="dashboard"]').classList.contains('active'));
    await page.mouse.move(400,40);
    await page.waitForFunction(()=>document.getAnimations().length===0);
    // Selection changes within the pointer event, without waiting for a timer or animation.
    await page.evaluate(()=>{const e=document.querySelector('[data-page="portal"]');e.dispatchEvent(new PointerEvent('pointerenter',{pointerType:'mouse'}));e.dispatchEvent(new PointerEvent('pointerleave',{pointerType:'mouse'}));});
    assert.equal(await page.locator('[data-page="portal"]').getAttribute('aria-current'),'page');
    await page.evaluate(()=>document.querySelector('[data-page="dashboard"]').dispatchEvent(new PointerEvent('pointerenter',{pointerType:'mouse'})));
    assert.equal(await page.locator('[data-page="dashboard"]').getAttribute('aria-current'),'page');
    // Both panels slide together; quick navigation cancels stale completion callbacks.
    const slides=await page.evaluate(()=>{
      document.querySelector('[data-page="settings"]').click();
      return ['dashboard','settings'].map(name=>document.getElementById('page-'+name).getAnimations()[0].effect.getKeyframes().map(frame=>frame.transform));
    });
    assert.deepEqual(slides,[['translateX(0px)','translateX(-100%)'],['translateX(100%)','translateX(0px)']]);
    await page.evaluate(()=>{document.querySelector('[data-page="portal"]').click();document.querySelector('[data-page="dashboard"]').click();});
    await page.waitForFunction(()=>document.getAnimations().length===0);
    assert.equal(await page.locator('.page:not([hidden])').count(),1);
    assert.equal(await page.locator('#page-dashboard').isVisible(),true);
    await page.evaluate(()=>{window.commands=[];document.querySelector('[data-page="portal"]').click();});
    assert.equal(await page.evaluate(()=>window.commands.some(m=>m.command==='portalBounds')),false);
    await page.waitForFunction(()=>window.commands.some(m=>m.command==='page'&&m.page==='portal'&&m.transitioning===false));
    const portalCommands=await page.evaluate(()=>window.commands);
    assert(portalCommands.findIndex(m=>m.command==='portalBounds')<portalCommands.findIndex(m=>m.command==='page'&&m.transitioning===false));
    await page.locator('[data-page="dashboard"]').click();
    const output=path.resolve(__dirname,'../../work/ui-preview');await fs.mkdir(output,{recursive:true});
    for(const name of ['dashboard','settings','portal']){
      await page.locator('[data-page="'+name+'"]').click();
      assert.equal(await page.locator('#page-'+name).isVisible(),true);
      await page.screenshot({animations:'disabled',path:path.join(output,name+'.png')});
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    }
    await page.locator('[data-page="settings"]').click();
    // Startup uses an independent immediate command; no campus credentials are required or sent.
    await page.evaluate(()=>campus.receive({kind:'startup',enabled:false,available:true}));
    await page.locator('#startup').check();
    assert.deepEqual(await page.evaluate(()=>window.commands.at(-1)),{command:'setStartup',enabled:true});
    assert.equal(await page.locator('#startup').isDisabled(),true);
    await page.evaluate(()=>campus.receive({kind:'startup',enabled:true,available:true}));
    assert.equal(await page.locator('#startup').isChecked(),true);
    await page.locator('#startup').uncheck();
    assert.deepEqual(await page.evaluate(()=>window.commands.at(-1)),{command:'setStartup',enabled:false});
    // A failed native write restores the actual checked state and allows retry.
    await page.evaluate(()=>campus.receive({kind:'startup',enabled:true,available:true}));
    assert.equal(await page.locator('#startup').isChecked(),true);
    await page.evaluate(()=>campus.receive({kind:'startup',enabled:false,available:false,error:'无法读取启动项'}));
    assert.equal(await page.locator('#startup').isDisabled(),true);
    await page.evaluate(()=>campus.receive({kind:'startup',enabled:false,available:true}));
    assert.equal(await page.locator('#loginMethod, #serviceName, [data-action="openBrowser"]').count(),0);
    assert.equal(await page.locator('#serviceOption').inputValue(),'');
    assert.equal(await page.locator('#browser-submit').isVisible(),true);
    assert.equal(await page.locator('#browser-advanced,#userSelector,#passwordSelector,#submitSelector').count(),0);
    // An old direct-auth profile loads its credentials into the sole browser workflow.
    await page.evaluate(() => campus.receive({kind:'profile',profile:{ssid:'HNPI-STU',portalUrl:'http://192.0.2.1',username:'legacy-account',portalEnabled:true,autoSubmit:true,automatic:false,loginMethod:'direct',serviceName:'old-service',userSelector:'#legacy-user',passwordSelector:'[',submitSelector:'#legacy-login'},password:'legacy-password'}));
    assert.equal(await page.locator('#username').inputValue(),'legacy-account');
    assert.equal(await page.locator('#password').inputValue(),'legacy-password');
    await page.locator('#save').click();
    const upgraded = await page.evaluate(()=>window.commands.filter(m=>m.command==='save').at(-1).profile);
    assert.equal(upgraded.userSelector,undefined);assert.equal(upgraded.passwordSelector,undefined);assert.equal(upgraded.submitSelector,undefined);
    assert.equal(upgraded.loginMethod,undefined);
    assert.equal(upgraded.serviceName,undefined);
    assert.equal(upgraded.autoSubmit,true);
    assert.equal(upgraded.serviceOption,'');
    await page.locator('#serviceOption').fill('  联通接入服务  ');
    await page.locator('#username').fill('test-user');
    await page.locator('#password').fill('password-test-only');
    await page.locator('#save-enable').click();
    let save = await page.evaluate(()=>window.commands.filter(m=>m.command==='save').at(-1));
    assert.equal(save.profile.username,'test-user');assert.equal(save.password,'password-test-only');assert.equal(save.profile.automatic,true);assert.equal(save.profile.serviceOption,'联通接入服务');
    await page.evaluate(save=>campus.receive({kind:'profile',profile:save.profile,password:save.password}),save);
    assert.equal(await page.locator('#serviceOption').inputValue(),'联通接入服务');
    // Periodic state updates must not overwrite an unsaved settings draft.
    await page.locator('#username').fill('unsaved-draft');
    await page.evaluate(state=>campus.receive({kind:'state',state}),state);
    assert.equal(await page.locator('#username').inputValue(),'unsaved-draft');
    assert.equal(await page.locator('#serviceOption').inputValue(),'联通接入服务');
    await page.locator('#serviceOption').fill('');
    await page.locator('#save').click();
    assert.equal(await page.evaluate(()=>window.commands.filter(m=>m.command==='save').at(-1).profile.serviceOption),'');
    await page.locator('[data-mode="saved"]').click();
    assert.equal(await page.locator('#wifi-settings').isVisible(),true);
    await page.locator('#portalEnabled').uncheck();assert.equal(await page.locator('#portal-fields').isVisible(),false);
    // Network names and diagnostic content are text, never executable markup.
    await page.evaluate(state=>campus.receive({kind:'state',state:{...state,permissionNeeded:false,networks:[{ssid:'<img src=x onerror="window.injected=1">',signal:90,secure:false}],report:'<script>window.injected=1</script>'}}),state);
    assert.equal(await page.evaluate(()=>window.injected),undefined);
    assert.equal(await page.locator('#networks img').count(),0);
    await page.locator('[data-page="dashboard"]').click();
    await page.locator('.network-row button').click();
    assert.equal(await page.locator('#page-settings').isVisible(),true);
    assert.equal(await page.locator('#username').inputValue(),'');
    assert.equal(await page.locator('#password').inputValue(),'');
    // Native portal placement needs logical bounds at every viewport size.
    await page.locator('[data-page="portal"]').click();
    await page.waitForFunction(()=>window.commands.some(m=>m.command==='portalBounds'&&m.page==='portal'&&m.width>0));
    const bounds=await page.evaluate(()=>window.commands.filter(m=>m.command==='portalBounds'&&m.page==='portal'&&m.width>0).at(-1));
    assert(bounds.x>=220 && bounds.x+bounds.width<=1280 && bounds.y+bounds.height<=860);
    await page.setViewportSize({width:980,height:700});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    await page.emulateMedia({colorScheme:'dark'});
    await page.locator('[data-page="dashboard"]').click();
    await page.screenshot({animations:'disabled',path:path.join(output,'dark.png')});
    await page.emulateMedia({reducedMotion:'reduce'});
    await page.locator('[data-page="settings"]').click();
    // Page motion is explicitly enabled even when Windows requests reduced system motion.
    assert.equal(await page.locator('#page-settings').evaluate(e=>e.getAnimations().length),1);
    assert.equal(await page.locator('#page-settings').evaluate(e=>e.getAnimations()[0].effect.getTiming().duration),280);
    const firstPosition=await page.locator('#page-settings').evaluate(e=>new DOMMatrixReadOnly(getComputedStyle(e).transform).m41);
    await page.waitForTimeout(120);
    const nextPosition=await page.locator('#page-settings').evaluate(e=>new DOMMatrixReadOnly(getComputedStyle(e).transform).m41);
    assert(firstPosition>nextPosition && nextPosition>0,'The visible page must actually move across frames.');
    await page.waitForFunction(()=>document.querySelectorAll('.page:not([hidden])').length===1);
    assert.equal(await page.locator('.toggle').first().evaluate(e=>getComputedStyle(e).transitionDuration),'0s');
    // The longer feedback note must open and fit in the minimum-size window.
    for (const colorScheme of ['light','dark']) {
      await page.emulateMedia({colorScheme});
      await page.locator('.feedback-help > summary').click();
      assert.equal(await page.locator('.feedback-note').isVisible(),true);
      const note=await page.locator('.feedback-note').textContent();
      assert(note.includes('如果使用正常') && note.includes('关注我的抖音') && note.includes('大学名称') && note.includes('帮助更多小伙伴使用小助手'));
      const rect=await page.locator('.feedback-note').boundingBox();
      assert(rect.x>=0 && rect.y>=0 && rect.x+rect.width<=980 && rect.y+rect.height<=700,'Feedback note clipped at minimum size.');
      await page.screenshot({animations:'disabled',path:path.join(output,'feedback-'+colorScheme+'.png')});
      await page.locator('.feedback-help > summary').click();
    }
    assert.deepEqual(errors,[]);
    console.log('PASS: hover navigation, draft retention, immediate hover, rapid switches, forced slide motion with reduced system motion, three pages, startup success/failure, attribution, settings actions, unsaved drafts, native bounds, text injection, minimum size and dark mode.');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
