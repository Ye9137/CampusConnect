const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
let template=fs.readFileSync(process.env.CAMPUS_HTU_SCRIPT || path.join(__dirname,'../source/PortalTemplate.js'),'utf8');
for(const [slot,file] of [['ACCOUNT','PortalAccount.js'],['GPORTAL','PortalGportal.js'],['AGREEMENTS','PortalAgreements.js'],['CAPTCHA','PortalCaptcha.js']])
 template=template.replace('  /*CAMPUS_'+slot+'*/',fs.readFileSync(path.join(__dirname,'../source',file),'utf8').trimEnd());
const config={origin:'http://portal.test',username:'fixture-user',password:'fixture-secret',submit:true,confirmSubmit:true};
const script=extra=>template.replace(/const cfg = (?:\/\*CAMPUS_CONFIG\*\/|[^\n]+);/, 'const cfg = '+JSON.stringify({...config,...extra})+';');
const fixture=fs.readFileSync(path.join(__dirname,'fixtures/htu-icon-operator.html'),'utf8');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH}:{})});
 let checks=0; const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 try{
  const page=await browser.newPage();
  await page.route('http://portal.test/**',r=>r.fulfill({contentType:'text/html; charset=utf-8',body:fixture}));
  const reset=()=>page.goto('http://portal.test/portal/usertemp_computer/hsd_pyh_pc_portal_skin-2/');
  for(const [value,name] of [['yd','移动'],['lt','联通'],['dx','电信']]) for(const serviceOption of [name,'中国'+name]){
   await reset();eq(await page.evaluate(script({serviceOption})),'submitted');
   eq(await page.evaluate(()=>loginCalls),[['fixture-user','fixture-secret',value]]);
   eq(await page.evaluate(()=>operatorEvents),[value]);
   eq(await page.locator('#bindCtrlDxNo').inputValue(),'');
   eq(await page.locator('#quickName').inputValue(),'');
   eq(await page.evaluate(script({serviceOption})),'already-submitted');eq(await page.evaluate(()=>loginCalls.length),1);
  }
  await reset();eq(await page.evaluate(script({serviceOption:'中国联通',submit:false})),'filled');
  eq(await page.evaluate(()=>[loginCalls.length,operatorEvents]),[0,['lt']]);
  eq(await page.evaluate(script({serviceOption:'中国联通',submit:false})),'filled');eq(await page.evaluate(()=>operatorEvents),['lt']);
  // No configured operator permits a temporary account without selecting anything.
  await reset();eq(await page.evaluate(script({serviceOption:''})),'submitted');eq(await page.evaluate(()=>loginCalls[0][2]),'');
  // Preserve a manually selected operator when the saved preference is empty.
  await reset();await page.locator('[value=dx]').evaluate(e=>e.click());
  eq(await page.evaluate(script({serviceOption:''})),'submitted');eq(await page.evaluate(()=>loginCalls[0][2]),'dx');
  await reset();await page.locator('[value=yd]').evaluate(e=>e.click());
  eq(await page.evaluate(script({serviceOption:'中国电信'})),'submitted');eq(await page.evaluate(()=>loginCalls[0][2]),'dx');
  for(const mutate of [
   ()=>document.querySelector('[value=yd]').disabled=true,
   ()=>document.querySelector('[value=yd]').closest('span').hidden=true,
   ()=>document.querySelector('[value=yd]').closest('label').style.visibility='hidden',
   ()=>document.querySelector('[value=yd]').closest('span').setAttribute('inert',''),
   ()=>document.querySelector('[value=yd]').closest('label').setAttribute('aria-disabled','true'),
   ()=>document.querySelector('.yidong').className='unknown',
   ()=>document.querySelector('[value=yd]').value='other',
   ()=>document.querySelector('#account-login').id='other-panel',
   ()=>document.querySelector('#userName').id='other-user',
   ()=>document.querySelector('.loginWay').className='other-options',
   ()=>{const form=document.createElement('form');document.body.append(form);form.append(document.querySelector('.loginWay'));},
   ()=>document.querySelector('[value=yd]').onclick=e=>{window.radioAttempts=(window.radioAttempts||0)+1;e.preventDefault();},
   ()=>document.querySelector('.loginWay').insertAdjacentHTML('beforeend','<label><input type="radio" name="operator" value="yd"><i class="yidong"></i></label>')
  ]){
   await reset();await page.evaluate(mutate);eq(await page.evaluate(script({serviceOption:'中国移动'})),'missing-service');eq(await page.evaluate(()=>loginCalls.length),0);
  }
  await reset();eq(await page.evaluate(script({serviceOption:'未知运营商'})),'missing-service');eq(await page.evaluate(()=>loginCalls.length),0);
  await reset();eq(await page.evaluate(script({origin:'http://other.test',serviceOption:'中国移动'})),'wrong-origin');eq(await page.locator('#password').inputValue(),'');
  // Ordinary unlabeled radios using yd must not inherit the school-specific alias.
  await page.setContent('<input name="username"><input type="password"><label><input type="radio" name="operator" value="yd"><i class="yidong"></i></label><button>登录</button>');
  eq(await page.evaluate(script({serviceOption:'中国移动'})),'missing-service');
  console.log(`PASS: ${checks} HTU checks: CSS-only carrier icons, full/short names, original event flow, submission deduplication, temporary accounts, manual choice, disabled/hidden/ambiguous/rejected options, panel/form/value/icon guards and origin.`);
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
