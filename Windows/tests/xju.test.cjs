const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const scripts=JSON.parse(fs.readFileSync(process.env.CAMPUS_XJU_SCRIPTS || path.join(__dirname,'../work/xju-scripts.json'),'utf8'));
const fixture=fs.readFileSync(path.join(__dirname,'fixtures/xju-account.html'),'utf8');
(async()=>{
 const browser=await chromium.launch({headless:true});let checks=0;
 const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 try{
  const page=await browser.newPage();
  await page.route('http://xju.test/**',r=>r.fulfill({contentType:'text/html; charset=utf-8',body:fixture}));
  const reset=()=>page.goto('http://xju.test/account');
  await reset();eq(await page.evaluate(scripts.fill),'submitted');
  eq(await page.evaluate(()=>received),['fixture-user','fixture-secret','1-@cucc','']);
  eq(await page.evaluate(()=>[clicks,unrelated,changes]),[1,0,1]);
  eq(await page.evaluate(scripts.fill),'already-submitted');eq(await page.evaluate(()=>clicks),1);
  await reset();eq(await page.evaluate(scripts.manual),'filled');eq(await page.evaluate(()=>[clicks,changes]),[0,1]);
  await reset();eq(await page.evaluate(scripts.noService),'service-required');eq(await page.evaluate(()=>clicks),0);
  // A manually selected route also works with a blank saved operator.
  await page.selectOption('#domain','1-@cucc');eq(await page.evaluate(scripts.noService),'submitted');eq(await page.evaluate(()=>clicks),1);
  await reset();eq(await page.evaluate(scripts.wrongService),'missing-service');eq(await page.evaluate(()=>clicks),0);
  await reset();eq(await page.evaluate(scripts.wrongOrigin),'wrong-origin');eq(await page.locator('#username').inputValue(),'');
  for(const attr of ['disabled','hidden']){
   await reset();await page.locator('#login-account').evaluate((e,a)=>e[a]=true,attr);
   eq(await page.evaluate(scripts.fill),'missing-submit');eq(await page.evaluate(()=>[clicks,unrelated]),[0,0]);
  }
  for(const attr of ['aria-disabled','visibility']){
   await reset();await page.locator('#login-account').evaluate((e,a)=>{if(a==='visibility')e.style.visibility='hidden';else e.setAttribute(a,'true')},attr);
   eq(await page.evaluate(scripts.fill),'missing-submit');eq(await page.evaluate(()=>[clicks,unrelated]),[0,0]);
  }
  await reset();await page.evaluate(()=>Object.defineProperty(document,'readyState',{configurable:true,value:'interactive'}));
  eq(await page.evaluate(scripts.fill),'waiting-ready');eq(await page.evaluate(()=>clicks),0);
  await page.evaluate(()=>delete document.readyState);eq(await page.evaluate(scripts.fill),'submitted');eq(await page.evaluate(()=>clicks),1);
  // Same ID alone must not admit an unknown or reset-account handler.
  for(const mutate of [()=>document.querySelector('#domain').remove(),
    ()=>document.querySelector('#login-account').classList.remove('btn-login'),
    ()=>document.querySelector('#login-account').setAttribute('onclick','unrelated++')]){
   await reset();await page.selectOption('#domain','1-@cucc');await page.evaluate(mutate);eq(await page.evaluate(scripts.noService),'missing-submit');eq(await page.evaluate(()=>[clicks,unrelated]),[0,0]);
  }
  // Visible challenge without an IMG stays manual; never submit an empty code.
  await reset();await page.locator('.panel-captcha').evaluate(e=>e.hidden=false);
  eq(await page.evaluate(scripts.fill),'manual-required');eq(await page.evaluate(()=>clicks),0);
  await page.locator('#captcha').fill('cD8Y');eq(await page.evaluate(scripts.fill),'submitted');eq(await page.evaluate(()=>received[3]),'cD8Y');
  // A displayed IMG uses the existing challenge flow and single commit.
  await reset();await page.evaluate(()=>{document.querySelector('.panel-captcha').hidden=false;const c=document.createElement('canvas');c.width=60;c.height=20;
   const image=document.createElement('img');image.src=c.toDataURL();document.querySelector('#captchaImg').append(image)});
  await page.waitForFunction(()=>document.querySelector('#captchaImg img').complete);
  eq(await page.evaluate(scripts.fill),'captcha-required');eq(await page.evaluate(()=>clicks),0);
  eq(await page.evaluate(()=>!!window.__campusCaptcha.read()),true);
  eq(await page.evaluate(scripts.commit),'submitted');eq(await page.evaluate(()=>received[3]),'aB7Z');eq(await page.evaluate(()=>clicks),1);
  eq(await page.evaluate(scripts.commit),'captcha-stale');eq(await page.evaluate(()=>clicks),1);
  console.log(`PASS: ${checks} XJU checks: production script, original click handler, domain change, placeholder, form guard, manual mode, origin, CAPTCHA and deduplication.`);
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
