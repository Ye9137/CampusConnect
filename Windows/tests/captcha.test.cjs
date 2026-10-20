const {chromium}=require('playwright');
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const template=fs.readFileSync(path.join(__dirname,'../source/PortalTemplate.js'),'utf8');
const captcha=fs.readFileSync(path.join(__dirname,'../source/PortalCaptcha.js'),'utf8');
const agreements=fs.readFileSync(path.join(__dirname,'../source/PortalAgreements.js'),'utf8');
const fixture=fs.readFileSync(path.join(__dirname,'fixtures/captcha.html'),'utf8');
const makeScript=(extra={})=>template.replace('/*CAMPUS_CONFIG*/',JSON.stringify({origin:'http://portal.test',username:'dummy-user',password:'dummy-password',submit:true,confirmSubmit:true,...extra}))
 .replace('  /*CAMPUS_AGREEMENTS*/',agreements.trimEnd()).replace('  /*CAMPUS_CAPTCHA*/',captcha.trimEnd());
(async()=>{
 const browser=await chromium.launch(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH,headless:true}:{headless:true});
 let checks=0;const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 try{
  const page=await browser.newPage();
  await page.route('http://portal.test/**',r=>r.fulfill({contentType:'text/html',body:fixture}));
  const load=async()=>{await page.goto('http://portal.test');await page.waitForFunction(()=>document.querySelector('img').complete&&document.querySelector('img').naturalWidth>0)};
  await load();
  eq(await page.evaluate(makeScript()),'captcha-required');
  eq(await page.locator('#username').inputValue(),'dummy-user');
  eq(await page.locator('#pwd').inputValue(),'dummy-password');
  eq(await page.evaluate(()=>loginCalls),0);
  const snapshot=await page.evaluate(()=>__campusCaptcha.read());
  eq(snapshot.length,4);eq(snapshot.autoSubmit,true);assert.match(snapshot.image,/^data:image\/png;base64,/);checks++;
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'12'),snapshot),'captcha-invalid');
  eq(snapshot.numericOnly,false);
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'ab-7'),snapshot),'captcha-invalid');
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'8042'),snapshot),'submitted');
  eq(await page.evaluate(()=>codes),['8042']);
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'8042'),snapshot),'captcha-stale');
  eq(await page.evaluate(()=>loginCalls),1);
  await load();eq(await page.evaluate(makeScript()),'captcha-required');
  const old=await page.evaluate(()=>__campusCaptcha.read());
  await page.evaluate(()=>changeImage('9201'));
  await page.waitForFunction(()=>__campusCaptcha.stale);
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'8042'),old),'captcha-stale');
  eq(await page.evaluate(()=>loginCalls),0);
  await load();eq(await page.evaluate(makeScript({submit:false})),'captcha-required');
  const manual=await page.evaluate(()=>__campusCaptcha.read());eq(manual.autoSubmit,false);
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'8042'),manual),'filled');
  eq(await page.locator('#validCode').inputValue(),'8042');eq(await page.evaluate(()=>loginCalls),0);
  for(const code of ['aB7Z','abcd','ABCD']) {
   await load();eq(await page.evaluate(makeScript()),'captcha-required');
   const letters=await page.evaluate(()=>__campusCaptcha.read());
   eq(await page.evaluate(({ticket,code})=>__campusCaptcha.commit(ticket,code),{...letters,code}),'submitted');
   eq(await page.evaluate(()=>codes),[code]);eq(await page.locator('#validCode').inputValue(),code);
  }
  await load();await page.locator('#validCode').evaluate(e=>e.inputMode='numeric');
  eq(await page.evaluate(makeScript()),'captcha-required');
  const numeric=await page.evaluate(()=>__campusCaptcha.read());eq(numeric.numericOnly,true);
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'aB7Z'),numeric),'captcha-invalid');
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'8042'),numeric),'submitted');
  await load();eq(await page.evaluate(makeScript({submit:false})),'captcha-required');
  const lettersManual=await page.evaluate(()=>__campusCaptcha.read());
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'aB7Z'),lettersManual),'filled');
  eq(await page.locator('#validCode').inputValue(),'aB7Z');eq(await page.evaluate(()=>loginCalls),0);
  await load();eq(await page.evaluate(makeScript({origin:'http://other.test'})),'wrong-origin');
  eq(await page.locator('#pwd').inputValue(),'');eq(await page.evaluate(()=>window.__campusCaptcha),undefined);
  await load();await page.locator('img').evaluate(e=>e.remove());
  eq(await page.evaluate(makeScript()),'manual-required');eq(await page.evaluate(()=>loginCalls),0);
  await load();await page.locator('#validCode').evaluate(e=>e.name='captcha');await page.locator('#validCode').evaluate(e=>e.id='customCaptcha');
  eq(await page.evaluate(makeScript()),'captcha-required');
  const removed=await page.evaluate(()=>__campusCaptcha.read());await page.locator('#customCaptcha').evaluate(e=>e.remove());
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'8042'),removed),'captcha-stale');
  eq(await page.evaluate(()=>loginCalls),0);
  console.log(`PASS: ${checks} CAPTCHA checks (invented image, native snapshot, manual confirmation, stale-image rejection, length, origin, deduplication, manual mode).`);
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
