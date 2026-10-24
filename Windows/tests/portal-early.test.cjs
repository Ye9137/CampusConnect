const {chromium}=require('playwright');
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const bootstrap=fs.readFileSync(path.join(__dirname,'../../macOS/source/PortalBootstrap.js'),'utf8').replace('/*CAMPUS_ORIGIN*/','"http://portal.test"');
const template=fs.readFileSync(path.join(__dirname,'../source/PortalTemplate.js'),'utf8').replace('  /*CAMPUS_ACCOUNT*/',fs.readFileSync(path.join(__dirname,'../source/PortalAccount.js'),'utf8').trimEnd());
const cfg={origin:'http://portal.test',username:'dummy-user',password:'dummy-password',userSelector:'',passwordSelector:'',submitSelector:'',submit:true};
const script=template.replace('/*CAMPUS_CONFIG*/',JSON.stringify(cfg));
// Mirrors the inspected school's onload + asynchronous API callback contracts.
// A withheld decorative image prevents load while both initialization APIs run.
const fixture=`<html><body><img src="/slow.png"><input id="username"><input id="pwd" type="password"><a id="loginLink" onclick="doauthen()">登录</a><script>
window.calls={fill:0,services:0,size:0,login:0};window.callbacks={};window.AuthInterFace={pageInfo(q,cb){callbacks.pageInfo=cb},getServices(q,cb){callbacks.getServices=cb}};
function fillData(){calls.fill++;AuthInterFace.pageInfo('',()=>{window.encryptionReady=true})}
function getServices(){calls.services++;AuthInterFace.getServices('',()=>{window.serviceReady=true})}
function autosize(){calls.size++}
function doauthen(){if(!encryptionReady || !serviceReady)throw Error('premature login');calls.login++}
window.onload=function () {fillData();getServices();autosize();}
</script></body></html>`;
(async()=>{
 const browser=await chromium.launch(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH,headless:true}:{headless:true});
 try{
  const page=await browser.newPage();let imageRoute;
  await page.addInitScript(bootstrap);
  await page.route('http://portal.test/**',r=>r.request().url().endsWith('slow.png')?(imageRoute=r):r.fulfill({contentType:'text/html',body:fixture}));
  await page.goto('http://portal.test/',{waitUntil:'domcontentloaded'});
  assert.equal(await page.evaluate(()=>document.readyState),'interactive');
  assert.equal(await page.evaluate(script),'waiting-ready');
  assert.equal(await page.locator('#pwd').inputValue(),'');
  await page.evaluate(()=>callbacks.getServices({}));
  assert.equal(await page.evaluate(script),'waiting-ready');
  await page.evaluate(()=>callbacks.pageInfo({}));
  assert.equal(await page.evaluate(script),'submitted');
  assert.equal(await page.evaluate(script),'already-submitted');
  assert.equal(await page.evaluate(()=>document.readyState),'interactive');
  await imageRoute.fulfill({status:204});await page.waitForLoadState('load');
  assert.deepEqual(await page.evaluate(()=>calls),{fill:1,services:1,size:1,login:1});
  assert.equal(await page.locator('#pwd').inputValue(),cfg.password);
  // Failed school callbacks never release credentials / submit.
  await page.goto('http://portal.test/',{waitUntil:'domcontentloaded'});
  await page.evaluate(()=>{__campusReady.failed=true;callbacks.pageInfo({});callbacks.getServices({});});
  assert.equal(await page.evaluate(script),'waiting-ready');
  assert.equal(await page.locator('#pwd').inputValue(),'');
  // Extra required fields retain manual interaction and do not count as submitted.
  await page.evaluate(()=>{__campusReady.failed=false;document.body.insertAdjacentHTML('beforeend','<input id="validCode">');});
  assert.equal(await page.evaluate(script),'manual-required');
  assert.equal(await page.evaluate(()=>calls.login),0);
  // No school-specific initialization runs on a different origin.
  const other=await browser.newPage();await other.addInitScript(bootstrap);
  await other.route('http://other.test/**',r=>r.request().url().endsWith('.png')?r.fulfill({status:204}):r.fulfill({contentType:'text/html',body:fixture}));
  await other.goto('http://other.test/',{waitUntil:'domcontentloaded'});
  assert.equal(await other.evaluate(()=>window.__campusReady),undefined);
  assert.equal(await other.evaluate(script),'wrong-origin');
  assert.equal(await other.locator('#pwd').inputValue(),'');
  console.log('PASS: early initialization, delayed image, encryption/service barriers, one submission, late load deduplication, failed callback, captcha/manual gate and foreign-origin denial.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
