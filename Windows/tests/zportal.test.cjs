// Offline regression prepared for the inspected DOM. Not a native/network/OCR test.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=name=>fs.readFileSync(path.join(__dirname,name),'utf8');
const template=read('../source/PortalTemplate.js').replace('  /*CAMPUS_CAPTCHA*/',read('../source/PortalCaptcha.js')).replace('  /*CAMPUS_AGREEMENTS*/',read('../source/PortalAgreements.js'));
const cfg={origin:'http://zportal.test',username:'fixture-user',password:'fixture-password',userSelector:'',passwordSelector:'',submitSelector:'',serviceOption:'',submit:true};
const script=overrides=>template.replace('/*CAMPUS_CONFIG*/',JSON.stringify({...cfg,...overrides}));
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage();
  await page.route('http://zportal.test/**',route=>route.fulfill({contentType:'text/html; charset=utf-8',body:read('fixtures/zportal-login.html')}));
  const reset=()=>page.goto('http://zportal.test/zportal/login');
  await reset();assert.equal(await page.evaluate(script()),'submitted');
  assert.equal(await page.locator('#password').inputValue(),cfg.password);
  assert.deepEqual(await page.evaluate(()=>[loginClicks,qrClicks,reveals]),[1,0,1]);
  assert.equal(await page.evaluate(script()),'already-submitted');
  await reset();await page.locator('#tx').evaluate(e=>e.focus=()=>{});
  assert.equal(await page.evaluate(script()),'submitted');
  assert.deepEqual(await page.evaluate(()=>[loginClicks,qrClicks]),[1,0]);
  await reset();assert.equal(await page.evaluate(script({submit:false})),'filled');
  assert.equal(await page.evaluate(()=>loginClicks),0);
  await reset();await page.locator('#tx').evaluate(e=>e.onfocus=null);
  assert.equal(await page.evaluate(script()),'missing-fields');
  assert.equal(await page.evaluate(()=>loginClicks),0);
  await reset();await page.evaluate(()=>{validcode_div.style.display='';signin_validcode_flag.value='true';});
  assert.equal(await page.evaluate(script()),'captcha-required');
  assert.equal(await page.evaluate(()=>loginClicks),0);
  const challenge=await page.evaluate(()=>window.__campusCaptcha.read());assert(challenge?.image.startsWith('data:image/png;base64,'));
  assert.equal(await page.evaluate(({ticket})=>window.__campusCaptcha.commit(ticket,'1234'),challenge),'submitted');
  assert.equal(await page.locator('#valid_code').inputValue(),'1234');
  assert.deepEqual(await page.evaluate(()=>[loginClicks,qrClicks]),[1,0]);
  await reset();assert.equal(await page.evaluate(script({origin:'http://different.test'})),'wrong-origin');
  assert.equal(await page.locator('#user_name').inputValue(),'用户名');
  await page.goto('http://zportal.test/zportal/goToAuthResult');
  await page.setContent('<a id="logout_submit">我要下线</a><form id="hidden_form" action="/zportal/logout" method="post"><input type="hidden" name="userName"><input type="hidden" name="userIp"><input type="hidden" name="deviceIp"></form>');
  assert.equal(await page.evaluate(script({statusOnly:true})),'authenticated');
  await page.locator('[name=deviceIp]').evaluate(e=>e.remove());
  assert.equal(await page.evaluate(script({statusOnly:true})),'not-submitted');
  console.log('PASS: zPortal reveal, QR-button exclusion, captcha placeholder, native page event and result structure.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
