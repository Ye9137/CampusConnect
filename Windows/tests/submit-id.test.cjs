const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const scripts=JSON.parse(fs.readFileSync(path.join(__dirname,'../work/submit-id-script.json'),'utf8'));
// The reported school selector is #submit. No real school address or credentials are required.
const handler='event.preventDefault();window.clicks++;window.received=[document.querySelector("#account").value,document.querySelector("#secret").value]';
const account='<input id="account" name="username"><input id="secret" type="password">';
(async()=>{
 const browser=await chromium.launch({headless:true});let checks=0;
 const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 try{
  const page=await browser.newPage();let body='';
  await page.route('http://submit-id.test/**',r=>r.fulfill({contentType:'text/html; charset=utf-8',body:body+'<script>window.clicks=0;window.unrelated=0;</script>'}));
  const load=async(button,extra='',before='')=>{body=before+'<form id="login">'+account+extra+button+'</form>';await page.goto('http://submit-id.test/login')};
  for(const tag of ['<button type="button" id="submit"></button>','<input type="button" id="submit" value="">','<a id="submit" href="#"><span aria-hidden="true">➜</span></a>','<div id="submit" role="button"></div>']){
   await load(tag);await page.locator('#submit').evaluate((e,h)=>e.setAttribute('onclick',h),handler);
   eq(await page.evaluate(scripts.fill),'submitted');eq(await page.evaluate(()=>received),['fixture-user','fixture-secret']);
   eq(await page.evaluate(()=>clicks),1);eq(await page.evaluate(scripts.fill),'already-submitted');eq(await page.evaluate(()=>clicks),1);
  }
  body=account+'<a id="submit" href="#"></a>';await page.goto('http://submit-id.test/login');
  await page.locator('#submit').evaluate((e,h)=>e.setAttribute('onclick',h),handler);
  eq(await page.evaluate(scripts.fill),'submitted');eq(await page.evaluate(()=>clicks),1);
  await load('<button type="button" id="submit" onclick="'+handler.replaceAll('"','&quot;')+'"></button>');
  eq(await page.evaluate(scripts.manual),'filled');eq(await page.evaluate(()=>clicks),0);
  // A login-labelled secondary control must not take priority over confirmed #submit.
  await load('<button type="button" onclick="unrelated++">登录</button><button type="button" id="submit"></button>');
  await page.locator('#submit').evaluate((e,h)=>e.setAttribute('onclick',h),handler);
  eq(await page.evaluate(scripts.fill),'submitted');eq(await page.evaluate(()=>unrelated),0);eq(await page.evaluate(()=>clicks),1);
  for(const attrs of ['disabled','style="display:none"','aria-disabled="true"','style="visibility:hidden"','type="reset"']){
   await load('<button '+attrs+' id="submit" onclick="unrelated++"></button>');
   eq(await page.evaluate(scripts.fill),'missing-submit');eq(await page.evaluate(()=>unrelated),0);
  }
  await load('', '', '<form id="registration"><button type="button" id="submit" onclick="unrelated++"></button></form>');
  eq(await page.evaluate(scripts.fill),'missing-submit');eq(await page.evaluate(()=>unrelated),0);
  await load('<button type="button" id="submit" form="registration" onclick="unrelated++"></button>', '', '<form id="registration"></form>');
  eq(await page.evaluate(scripts.fill),'missing-submit');eq(await page.evaluate(()=>unrelated),0);
  await load('<button type="button" id="submit" onclick="unrelated++"></button><button type="button" id="submit" onclick="unrelated++"></button>');
  eq(await page.evaluate(scripts.fill),'missing-submit');eq(await page.evaluate(()=>unrelated),0);
  await load('<button type="button" id="submit"></button>','<input name="verifyCode" maxlength="4"><img id="captcha-image">');
  await page.locator('#submit').evaluate((e,h)=>e.setAttribute('onclick',h),handler);
  await page.locator('#captcha-image').evaluate(img=>{const c=document.createElement('canvas');c.width=20;c.height=10;img.src=c.toDataURL()});
  await page.waitForFunction(()=>document.querySelector('#captcha-image').complete);
  eq(await page.evaluate(scripts.fill),'captcha-required');eq(await page.evaluate(()=>clicks),0);
  await page.evaluate(()=>{delete window.__campusCaptcha});eq(await page.evaluate(scripts.captcha),'captcha-required');
  eq(await page.evaluate(()=>!!window.__campusCaptcha.read()),true);
  eq(await page.evaluate(scripts.commit),'submitted');eq(await page.evaluate(()=>clicks),1);
  eq(await page.locator('[name=verifyCode]').inputValue(),'aB7Z');
  console.log(`PASS: ${checks} submit-ID checks: production scripts, original handler, icon controls, priority, form isolation, disabled/hidden/reset/ambiguous controls, manual mode, deduplication and CAPTCHA commit.`);
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
