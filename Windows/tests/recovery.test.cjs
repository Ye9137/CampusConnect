const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');

(async()=>{
 const browser=await chromium.launch(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH,headless:true}:{headless:true});
 let checks=0;
 const equal=(actual,expected)=>{assert.deepEqual(actual,expected);checks++;};
 try{
  const page=await browser.newPage({viewport:{width:1280,height:860}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{window.commands=[];window.chrome={webview:{postMessage:m=>commands.push(m),addEventListener:()=>{}}};});
  const profile={ssid:'HNPI-STU',portalUrl:'http://192.0.2.1',username:'saved-user',serviceOption:'',useSavedWifiProfile:false,portalEnabled:true,autoSubmit:true,automatic:true};
  const state={target:'HNPI-STU',currentSsid:'HNPI-STU',campusConnected:true,internetOnline:true,connectionTitle:'已连接',automatic:true,busy:false,networks:[]};
  const hydrate=async(snapshot=null,target='dashboard',currentState=state)=>page.evaluate(({profile,state,snapshot,target})=>{
   campus.receive({kind:'profile',profile,password:'saved-dummy'});
   campus.receive({kind:'startup',enabled:true,available:true});
   campus.receive({kind:'state',state});
   campus.receive({kind:'restore',page:target,snapshot});
  },{profile,state:currentState,snapshot,target});
  await page.goto(pathToFileURL(path.resolve(__dirname,'../source/Desktop.html')).href);
  await hydrate();
  await page.locator('[data-page="settings"]').click();
  await page.locator('#username').fill('  unsaved user  ');
  await page.locator('#password').fill('dummy-recovery-<&"');
  await page.locator('#serviceOption').fill(' 联通接入服务 ');
  await page.locator('[data-mode="saved"]').click();
  await page.locator('#autoSubmit').uncheck();
  equal(await page.locator('#browser-advanced,#userSelector,#passwordSelector,#submitSelector').count(),0);
  const snapshot=await page.evaluate(()=>campus.snapshot());
  equal(snapshot.dirty,true);
  equal(await page.evaluate(()=>commands.filter(m=>m.command==='draft').at(-1).snapshot),snapshot);
  // Real document reload destroys the JS heap, just like WebView2.Reload().
  for(let i=0;i<5;i++){
   await page.reload();
   equal(await page.evaluate(()=>commands.filter(m=>m.command==='ready').length),1);
   // Host's automatic flag may change in the tray while the UI is hidden.
   await hydrate(snapshot,'settings',{...state,automatic:false});
   equal(await page.locator('#username').inputValue(),'  unsaved user  ');
   equal(await page.locator('#password').inputValue(),'dummy-recovery-<&"');
   equal(await page.locator('#serviceOption').inputValue(),' 联通接入服务 ');
   equal(await page.evaluate(()=>campus.snapshot().profile.userSelector),undefined);
   equal(await page.locator('#autoSubmit').isChecked(),false);
   equal(await page.evaluate(()=>campus.snapshot().advancedOpen),undefined);
   equal(await page.locator('[data-mode="saved"]').evaluate(e=>e.classList.contains('active')),true);
   equal(await page.locator('#password').getAttribute('type'),'password');
   equal(await page.locator('#startup').isChecked(),true);
   equal(await page.evaluate(()=>campus.snapshot().profile.automatic),false);
   equal(await page.evaluate(()=>commands.filter(m=>m.command==='hydrated').length),1);
   equal(await page.evaluate(()=>commands.filter(m=>['save','connect','openPortal','setAutomatic'].includes(m.command))),[]);
   equal(await page.evaluate(()=>({local:localStorage.length,session:sessionStorage.length})),{local:0,session:0});
  }
  // Last input checkpoint remains usable when a crashed renderer cannot run snapshot().
  const checkpoint=await page.evaluate(()=>commands.filter(m=>m.command==='draft').at(-1).snapshot);
  await page.reload();await hydrate(checkpoint,'portal');
  await page.waitForFunction(()=>commands.some(m=>m.command==='page'&&m.page==='portal'&&!m.transitioning));
  equal(await page.locator('#page-portal').isVisible(),true);
  const bounds=await page.evaluate(()=>commands.find(m=>m.command==='portalBounds'));
  assert(bounds.width>0&&bounds.height>0);checks++;
  equal(await page.evaluate(()=>commands.filter(m=>m.command==='openPortal').length),0);
  // A successful save clears stale drafts; new settings win on future restores.
  await page.evaluate(profile=>campus.receive({kind:'profile',profile,password:'saved-dummy'}),profile);
  const clean=await page.evaluate(()=>campus.snapshot());equal(clean.dirty,false);
  await page.reload();await hydrate({...clean,profile:{...clean.profile,username:'stale-snapshot'}},'settings');
  equal(await page.locator('#username').inputValue(),'saved-user');
  // Recovery works even when no checkpoint was delivered before a process failure.
  await page.reload();await hydrate(null,'dashboard');
  equal(await page.locator('#page-dashboard').isVisible(),true);
  equal(await page.locator('#username').inputValue(),'saved-user');
  equal(errors,[]);
  console.log(`PASS: ${checks} recovery checks (reload, draft checkpoints, page/bounds, host state, no auto-submit/storage).`);
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
