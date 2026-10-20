const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
 const browser=await chromium.launch(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH,headless:true}:{headless:true});
 let checks=0;const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 try{
  const page=await browser.newPage({viewport:{width:1280,height:860}});
  await page.addInitScript(()=>{window.commands=[];window.chrome={webview:{postMessage:m=>commands.push(m),addEventListener:()=>{}}}});
  const url=pathToFileURL(path.resolve(__dirname,'../source/Desktop.html')).href;
  const wifi={connectionMode:'wifi',ssid:'Custom-University',portalUrl:'https://wifi.test/login',username:'wifi-user',serviceOption:'无线服务',useSavedWifiProfile:true,portalEnabled:true,autoSubmit:false,automatic:false};
  const wired={connectionMode:'wired',ssid:'',wiredAuth:'web',ethernetName:'Fixture Ethernet',portalUrl:'https://wired.test/login',username:'wired-user',serviceOption:'有线服务',portalEnabled:true,autoSubmit:true,automatic:false};
  const profiles={wifi:{profile:wifi,password:'wifi-secret'},wired:{profile:wired,password:'wired-secret'}};
  const hydrate=async(active='wired',snapshot=null,entries=profiles)=>{
   await page.evaluate(({active,snapshot,entries})=>{
    campus.receive({kind:'profile',...entries[active],profiles:entries});
    campus.receive({kind:'state',state:{target:'有线网络',wiredMode:true,automatic:false,busy:false,networks:[]}});
    campus.receive({kind:'restore',page:'settings',snapshot});
   },{active,snapshot,entries});
   await page.waitForFunction(()=>document.getAnimations().length===0);
  };
  const value=id=>page.locator('#'+id).inputValue();
  await page.goto(url);await hydrate();
  eq(await value('username'),'wired-user');eq(await value('password'),'wired-secret');
  await page.locator('[data-connection=wifi]').click();
  for(const [id,expected] of Object.entries({ssid:'Custom-University',username:'wifi-user',password:'wifi-secret',portalUrl:'https://wifi.test/login',serviceOption:'无线服务'}))eq(await value(id),expected);
  eq(await page.locator('[data-mode=saved]').evaluate(e=>e.classList.contains('active')),true);
  await page.locator('#username').fill('  unfinished wifi  ');await page.locator('#password').fill('wifi-draft-secret');
  await page.locator('[data-connection=wired]').click();
  eq(await value('username'),'wired-user');eq(await value('password'),'wired-secret');eq(await value('ethernetName'),'Fixture Ethernet');
  await page.locator('#username').fill('unfinished wired');await page.locator('#password').fill('wired-draft-secret');
  await page.locator('[data-connection=wifi]').click();
  eq(await value('username'),'  unfinished wifi  ');eq(await value('password'),'wifi-draft-secret');
  for(let i=0;i<10;i++)await page.evaluate(()=>campus.receive({kind:'state',state:{target:'有线网络',wiredMode:true,automatic:false,busy:false,networks:[]}}));
  eq(await value('username'),'  unfinished wifi  ');eq(await value('password'),'wifi-draft-secret');
  const snapshot=await page.evaluate(()=>campus.snapshot());
  await page.reload();await hydrate('wired',snapshot);
  eq(await value('ssid'),'Custom-University');eq(await value('username'),'  unfinished wifi  ');
  await page.locator('[data-connection=wired]').click();
  eq(await value('username'),'unfinished wired');eq(await value('password'),'wired-draft-secret');
  await page.locator('[data-connection=wifi]').click();await page.locator('#save').click();
  const saved=await page.evaluate(()=>commands.filter(m=>m.command==='save').at(-1));
  eq(saved.profile.connectionMode,'wifi');eq(saved.profile.username,'unfinished wifi');eq(saved.password,'wifi-draft-secret');
  const updated={...profiles,wifi:{profile:saved.profile,password:saved.password}};
  await page.evaluate(entries=>campus.receive({kind:'profile',...entries.wifi,profiles:entries}),updated);
  await page.locator('[data-connection=wired]').click();
  eq(await value('username'),'unfinished wired');eq(await value('password'),'wired-draft-secret');
  // A full app restart receives only the saved native catalog, not unsaved browser drafts.
  await page.reload();await hydrate('wifi',null,updated);
  eq(await value('ssid'),'Custom-University');eq(await value('password'),'wifi-draft-secret');
  await page.locator('[data-connection=wired]').click();eq(await value('username'),'wired-user');eq(await value('password'),'wired-secret');
  // An old wired-only installation has no previous Wi-Fi profile to recover.
  await page.reload();await hydrate('wired',null,{wired:profiles.wired});
  await page.locator('[data-connection=wifi]').click();
  for(const id of ['ssid','username','password','portalUrl','serviceOption'])eq(await value(id),'');
  eq(await page.locator('[data-connection=wifi]').getAttribute('aria-pressed'),'true');
  await page.locator('#ssid').fill('temporary');await page.locator('#ssid').fill('');
  eq(await page.locator('[data-connection=wifi]').getAttribute('aria-pressed'),'true');
  eq(await page.evaluate(()=>campus.snapshot().profile.connectionMode),'wifi');
  eq(await page.evaluate(()=>({local:localStorage.length,session:sessionStorage.length})),{local:0,session:0});
  eq(await page.evaluate(()=>commands.filter(m=>['connect','openPortal','setAutomatic'].includes(m.command)).length),0);
  console.log(`PASS: ${checks} connection profile checks (separate passwords, custom SSID, saved restart, drafts, renderer recovery, blank Wi-Fi mode, no automatic network changes).`);
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
