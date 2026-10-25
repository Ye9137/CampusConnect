const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const read=p=>fs.readFileSync(path.join(__dirname,p),'utf8');
const template=read('../source/PortalTemplate.js')
 .replace('  /*CAMPUS_ACCOUNT*/',read('../source/PortalAccount.js').trimEnd())
 .replace('  /*CAMPUS_CAPTCHA*/',read('../source/PortalCaptcha.js').trimEnd())
 .replace('  /*CAMPUS_AGREEMENTS*/',read('../source/PortalAgreements.js').trimEnd());
const cfg={origin:'http://haust.test',username:'dummy-user',password:'dummy-password',submit:true,confirmSubmit:true,serviceOption:''};
const script=extra=>template.replace('/*CAMPUS_CONFIG*/',JSON.stringify({...cfg,...extra}));
(async()=>{
 const browser=await chromium.launch(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH,headless:true}:{headless:true});
 let checks=0;const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 const requests=[],errors=[];let configRelease,releaseConfig,holdConfig=false,replies={};
 const page=await browser.newPage();page.on('pageerror',e=>errors.push(e.message));
 const jquery=fs.readFileSync(require.resolve('jquery/dist/jquery.min.js'),'utf8');
 try{
  await page.route('http://haust.test/**',async route=>{
   const req=route.request(),url=new URL(req.url());
   if(url.pathname==='/jquery.js')return route.fulfill({contentType:'text/javascript',body:jquery});
   if(url.pathname.startsWith('/tpl/'))return route.fulfill({contentType:'text/html; charset=utf-8',body:read('fixtures/haust-account.html')});
   if(url.pathname==='/api/config'){
    if(holdConfig)await configRelease;
    return route.fulfill({json:{data:{password_config:{},password_rule_scope:{portal_auth:'1'}}}});
   }
   requests.push({path:url.pathname,method:req.method(),data:Object.fromEntries(new URLSearchParams(req.postData()||''))});
   const result=replies[url.pathname]||{code:0,online:{Username:'dummy-user',Name:'',UserMac:'',AddTime:''},msg:''};
   if(result.abort)return route.abort();
   return route.fulfill({status:result.httpStatus||200,json:result});
  });
  const reset=async(extra={})=>{
   requests.length=0;errors.length=0;replies=extra;holdConfig=false;
   await page.goto('http://haust.test/tpl/stu-ky/login_account.html?ip=10.0.0.8&mac=00%3A11%3A22%3A33%3A44%3A55&nasId=7&switchip=10.0.0.1');
   await page.waitForFunction(()=>!!window.passwordRuleScope);
  };
  const result=async()=>{await page.waitForFunction(()=>['success','fail','captcha','request-error'].includes(window.__campusSubmitAttempt?.result));return page.evaluate(script({statusOnly:true,password:''}))};
  // Reproduce the old race: the form exists while /config has not completed.
  holdConfig=true;configRelease=new Promise(r=>releaseConfig=r);
  await page.goto('http://haust.test/tpl/stu-ky/login_account.html?ip=10.0.0.8&mac=00:11:22:33:44:55',{waitUntil:'domcontentloaded'});
  eq(await page.evaluate(script()),'waiting-ready');eq(requests.length,0);eq(errors,[]);
  releaseConfig();await page.waitForFunction(()=>!!window.passwordRuleScope);
  eq(await page.evaluate(script()),'submitted');eq(await result(),'authenticated');
  eq(requests.map(r=>r.path),['/api/account/check','/api/account/login']);eq(await page.evaluate(script()),'authenticated');
  eq(await page.evaluate(()=>window.__campusSubmitAttempt.accountObserved),true);eq(errors,[]);
  // Preserve all school context and optional fields; one click follows both school prechecks.
  await reset();await page.evaluate(()=>{window.dxzAuthApiUrl='/preauth';window.dxzCheckApiUrl='/precheck'});
  replies['/preauth']={code:1};replies['/precheck']={code:-1};
  eq(await page.evaluate(script()),'submitted');eq(await result(),'authenticated');
  eq(requests.map(r=>r.path),['/preauth','/precheck','/api/account/check','/api/account/login']);
  const data=requests.at(-1).data;
  eq([data.username,data.password,data.userIpv4,data.userMac,data.nasId,data.switchip,data.isp,data.timeLimit],['dummy-user','dummy-password','10.0.0.8','00:11:22:33:44:55','7','10.0.0.1','local','0']);
  eq(errors,[]);
  for(const stage of ['/preauth','/precheck','/api/account/check','/api/account/login']){
   await reset({[stage]:{code:stage.startsWith('/api/')?1:0,msg:'E20027'}});
   if(stage==='/preauth')await page.evaluate(()=>window.dxzAuthApiUrl='/preauth');
   if(stage==='/precheck')await page.evaluate(()=>window.dxzCheckApiUrl='/precheck');
   eq(await page.evaluate(script()),'submitted');eq(await result(),'authentication-rejected:E20027');
   const count=requests.length;eq(await page.evaluate(script()),'authentication-rejected:E20027');eq(requests.length,count);
   eq(requests.at(-1).path,stage);eq(errors,[]);
  }
  await reset({'/api/account/login':{code:1,msg:'dummy-password Account dummy-user E20027'}});
  eq(await page.evaluate(script()),'submitted');eq(await result(),'authentication-rejected:E20027');
  const state=await page.evaluate(()=>JSON.stringify(window.__campusSubmitAttempt));
  eq(state.includes('dummy-password'),false);eq(state.includes('dummy-user'),false);
  await reset({'/api/account/login':{abort:true}});eq(await page.evaluate(script()),'submitted');eq(await result(),'authentication-request-failed');
  for(const httpStatus of [400,401,403,404]){
   await reset({'/api/account/login':{httpStatus}});
   eq(await page.evaluate(script()),'submitted');eq(await result(),'authentication-rejected');
   const count=requests.length;eq(await page.evaluate(script()),'authentication-rejected');eq(requests.length,count);
  }
  for(const httpStatus of [408,429,500,503]){
   await reset({'/api/account/login':{httpStatus}});
   eq(await page.evaluate(script()),'submitted');eq(await result(),'authentication-request-failed');
  }
  await reset();await page.evaluate(()=>window.dxzAuthApiUrl='/preauth');replies['/preauth']={abort:true};
  eq(await page.evaluate(script()),'submitted');eq(await result(),'authenticated');
  await reset();eq(await page.evaluate(script({submit:false})),'filled');eq(requests.length,0);
  await reset();eq(await page.evaluate(script({password:'blocked-password'})),'submission-unconfirmed');
  eq(requests.length,0);eq(await page.evaluate(()=>messages.at(-1)),'本地密码校验失败');
  // A server challenge is detected after the first attempt; do not submit again without the code.
  await reset({'/api/account/login':{code:2,captcha:{picPath:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',captchaId:'offline-ticket'}}});
  eq(await page.evaluate(script()),'submitted');await result();
  await page.waitForFunction(()=>document.querySelector('#codeImg').complete);
  // Probe follows the production Windows controller, which checks for CAPTCHA independently of the submission latch.
  const probe=script({submit:false}).replace("if (window.__campusSubmitted) return 'already-submitted';",'');
  eq(await page.evaluate(probe),'captcha-required');eq(requests.length,2);
  const challenge=await page.evaluate(()=>__campusCaptcha.read());eq(challenge.source,'page');
  replies['/api/account/login']={code:0,online:{Username:'dummy-user',Name:'',UserMac:'',AddTime:''}};
  // Production commits with autoSubmit=true; exercise the same original school handler after confirming the code.
  await page.evaluate(()=>{window.__campusSubmitted=false;window.__campusCaptcha=null});
  eq(await page.evaluate(script()),'captcha-required');
  const ready=await page.evaluate(()=>__campusCaptcha.read());
  eq(await page.evaluate(({ticket})=>__campusCaptcha.commit(ticket,'aB7Z'),ready),'submitted');eq(await result(),'authenticated');
  eq(requests.at(-1).data.captcha,'aB7Z');eq(requests.at(-1).data.captchaId,'offline-ticket');eq(errors,[]);
  console.log(`PASS: ${checks} account portal checks (delayed config, original full school flow, context, prechecks, E20027, no retries, bounded diagnostics, network errors, CAPTCHA).`);
 }finally{releaseConfig?.();await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
