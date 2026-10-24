// Offline fixture based on the supplied button; no real school requests are sent.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const read=p=>fs.readFileSync(path.join(__dirname,p),'utf8');
const template=read('../source/PortalTemplate.js').replace('  /*CAMPUS_ACCOUNT*/',fs.readFileSync(path.join(__dirname,'../source/PortalAccount.js'),'utf8').trimEnd())
 .replace('  /*CAMPUS_CAPTCHA*/',read('../source/PortalCaptcha.js'))
 .replace('  /*CAMPUS_AGREEMENTS*/',read('../source/PortalAgreements.js'));
const cfg={origin:'http://haust.test',username:'dummy-user',password:'dummy-password',submit:true,confirmSubmit:true,serviceOption:''};
const script=changes=>template.replace('/*CAMPUS_CONFIG*/',JSON.stringify({...cfg,...changes}));
(async()=>{
 const browser=await chromium.launch(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH,headless:true}:{headless:true});
 let checks=0;const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 try{
  const page=await browser.newPage();
  await page.route('http://haust.test/**',r=>r.fulfill({contentType:'text/html; charset=utf-8',body:read('fixtures/haust-login.html')}));
  const reset=()=>page.goto('http://haust.test/tpl/stu-ky/login_account.html');
  await reset();eq(await page.evaluate(script()),'submitted');
  eq(await page.evaluate(()=>[loginClicks,otherClicks,observed]),[1,0,[cfg.username,cfg.password]]);
  eq(await page.evaluate(script()),'already-submitted');eq(await page.evaluate(()=>loginClicks),1);
  await reset();eq(await page.evaluate(script({submit:false})),'filled');eq(await page.evaluate(()=>loginClicks),0);
  await reset();eq(await page.evaluate(script({origin:'http://foreign.test'})),'wrong-origin');
  eq(await page.locator('[name=password]').inputValue(),'');eq(await page.evaluate(()=>loginClicks),0);
  for(const mode of ['disabled','hidden']){
   await reset();await page.locator('#login-account').evaluate((e,mode)=>e[mode]=true,mode);
   eq(await page.evaluate(script()),'missing-submit');eq(await page.evaluate(()=>[loginClicks,otherClicks]),[0,0]);
  }
  await reset();await page.evaluate(()=>window.checkForm=undefined);
  eq(await page.evaluate(script()),'waiting-ready');eq(await page.evaluate(()=>[loginClicks,otherClicks]),[0,0]);
  await page.evaluate(()=>window.checkForm=function(){loginClicks++});
  eq(await page.evaluate(script()),'submitted');eq(await page.evaluate(()=>loginClicks),1);
  await reset();await page.locator('#login-account').evaluate(e=>e.remove());
  await page.locator('button[type=submit]').evaluate(e=>e.remove());
  eq(await page.evaluate(script()),'missing-submit');eq(await page.evaluate(()=>otherClicks),0);
  await reset();await page.evaluate(()=>{document.querySelector('#login-account').setAttribute('onclick','resetAccount()');document.querySelector('button[type=submit]').remove()});
  eq(await page.evaluate(script()),'missing-submit');eq(await page.evaluate(()=>[loginClicks,otherClicks]),[0,0]);
  console.log(`PASS: ${checks} HAUST checks (original checkForm click, correct account, no unrelated click, manual mode, origin, hidden/disabled/late handler, deduplication).`);
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
