const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
// Reconstruct only the visible controls and Angular-style input/click events.
// No school bundle, real account, API request or flow-session value is included.
const template=fs.readFileSync(path.join(__dirname,'../source/PortalTemplate.js'),'utf8')
 .replace('  /*CAMPUS_ACCOUNT*/',fs.readFileSync(path.join(__dirname,'../source/PortalAccount.js'),'utf8').trimEnd());
const cfg={origin:'http://portal.test',username:'fixture-user',password:'fixture-secret',submit:true,confirmSubmit:true};
const script=options=>template.replace('/*CAMPUS_CONFIG*/',JSON.stringify({...cfg,...options}));
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH}:{})});
 try{
  const page=await browser.newPage();
  await page.route('http://portal.test/**',r=>r.fulfill({contentType:'text/html; charset=utf-8',body:'<main id="app"></main>'}));
  await page.goto('http://portal.test/portal/entry/pc/authenticate;flowParams=undefined;from=');
  assert.equal(await page.evaluate(script()),'missing-fields');
  await page.evaluate(()=>{
   app.innerHTML='<input formcontrolname="userName" placeholder="用户名"><input type="password" formcontrolname="userPassword"><button type="button" id="login"><span>立即登录</span></button>';
   window.model={};window.clicks=0;
   for(const input of document.querySelectorAll('input'))input.addEventListener('input',()=>model[input.getAttribute('formcontrolname')]=input.value);
   login.addEventListener('click',()=>{clicks++;window.received=[model.userName,model.userPassword]});
  });
  assert.equal(await page.evaluate(script({submit:false})),'filled');
  assert.equal(await page.evaluate(()=>clicks),0);
  assert.equal(await page.evaluate(script()),'submitted');
  assert.deepEqual(await page.evaluate(()=>received),['fixture-user','fixture-secret']);
  assert.equal(await page.evaluate(script()),'already-submitted');
  assert.equal(await page.evaluate(()=>clicks),1);
  // Similar informational text must not become a login button.
  await page.reload();
  await page.evaluate(()=>{app.innerHTML='<input name="username"><input type="password"><button type="button">立即登录帮助</button>'});
  assert.equal(await page.evaluate(script()),'missing-submit');
  console.log('PASS: dynamic telecom-style form, matrix URL, framework input events, immediate-login button, manual mode and single submission.');
 }finally{await browser.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
