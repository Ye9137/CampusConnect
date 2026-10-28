const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const read=n=>fs.readFileSync(path.join(__dirname,n),'utf8');
let template=read('../source/PortalTemplate.js')
 .replace('  /*CAMPUS_ACCOUNT*/',read('../source/PortalAccount.js'))
 .replace('  /*CAMPUS_AGREEMENTS*/',read('../source/PortalAgreements.js'))
 .replace('  /*CAMPUS_CAPTCHA*/',read('../source/PortalCaptcha.js'));
if(template.includes('/*CAMPUS_GPORTAL*/'))template=template.replace('  /*CAMPUS_GPORTAL*/',read('../source/PortalGportal.js'));
const produced=JSON.parse(read('../work/gportal-script.json'));
const jquery=read('node_modules/jquery/dist/jquery.min.js');
const original=read('fixtures/gportal-login-handler.js');
const cfg={origin:'http://gportal.test',username:'fixture-user',password:'fixture-secret',submit:true,confirmSubmit:true,serviceOption:''};
const script=changes=>template.replace('/*CAMPUS_CONFIG*/',JSON.stringify({...cfg,...changes}));
const form='<form id="frmLogin"><input type="hidden" name="sign" value="fixture-session"><input type="hidden" name="iv" id="iv" value="fixture-iv"><input type="hidden" name="portalTemplateId" value="20"><input type="hidden" id="redirectUrl" name="redirectUrl" value="/done"><input id="first_name" name="name" type="text" placeholder="请输入学工号"><input id="first_password" name="password" type="password"><input id="first_button" type="button" onclick="javascript:login()" value="登&nbsp;录"></form>';
// Include other forms to verify strict login-form selection.
const other='<form id="frmReg"><input id="register_name" name="name"><input id="register_password" name="password" type="password"><input type="button" value="注册" onclick="window.unrelated++"></form>';
const setup=`window.requests=[];window.messages=[];window.unrelated=0;window.encryptCalls=0;window.reply={status:1,info:'fixture-ok',data:{redirectUrl:'/done'}};window.httpStatus=200;window.CryptoJS={AES:{encrypt(){}}};function cryptoEncode(s){encryptCalls++;window.serialized=s;return {data:'fixture-ciphertext',iv:$('#frmLogin [name=iv]').val()}}function showWait(){}function closeWait(){}function showmessage(...args){messages.push(args)}function offlinepage(){}function resetpage(){}function bindpage(){};$.ajaxTransport('+*',options=>({send(_headers,done){requests.push({url:options.url,body:options.data,method:options.type});done(httpStatus,httpStatus===200?'OK':'Error',{text:JSON.stringify(reply)},'Content-Type: application/json')},abort(){}}));`;
(async()=>{
 const browser=await chromium.launch({headless:true});let checks=0;const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
 try{
  const page=await browser.newPage();await page.route('http://gportal.test/**',r=>r.fulfill({contentType:'text/html; charset=utf-8',body:form+other+'<script>'+jquery+'</script><script>'+setup+'</script><script>'+original+'</script>'}));
  const reset=()=>page.goto('http://gportal.test/gportal/web/index?fixture=1');
  await reset();eq(await page.locator('#first_button').inputValue(),'登\u00a0录');
  eq(await page.evaluate(produced.fill),'submitted');
  eq(await page.locator('#first_name').inputValue(),cfg.username);eq(await page.locator('#first_password').inputValue(),cfg.password);
  eq(await page.locator('#register_name').inputValue(),'');eq(await page.locator('#register_password').inputValue(),'');
  eq(await page.evaluate(()=>requests.length),1);eq(await page.evaluate(()=>encryptCalls),1);
  const values=new URLSearchParams(await page.evaluate(()=>serialized));eq(values.get('name'),cfg.username);eq(values.get('password'),cfg.password);eq(values.get('sign'),'fixture-session');eq(values.get('iv'),'fixture-iv');
  eq(await page.evaluate(produced.status),'authenticated');eq(await page.evaluate(script()),'authenticated');eq(await page.evaluate(()=>requests.length),1);
  await reset();await page.evaluate(()=>document.body.prepend(document.getElementById('frmReg')));eq(await page.evaluate(script()),'submitted');eq(await page.locator('#register_name').inputValue(),'');
  await reset();eq(await page.evaluate(produced.manual),'filled');eq(await page.evaluate(()=>requests.length),0);
  for(const reason of ['bad-password','32','40','41','43']){
   await reset();await page.evaluate(code=>{reply={status:0,info:'fixture-reject',data:{reasoncode:code,name:'fixture-user',password:'fixture-reply-secret'}};window.art={dialog(){return {}}};},reason);
   eq(await page.evaluate(script()),'submitted');eq(await page.evaluate(script({statusOnly:true})),'authentication-rejected');eq(await page.evaluate(()=>requests.length),1);
  }
  for(const status of [0,503]){await reset();await page.evaluate(n=>httpStatus=n,status);eq(await page.evaluate(script()),'submitted');eq(await page.evaluate(script({statusOnly:true})),'authentication-request-failed');}
  await reset();await page.evaluate(()=>CryptoJS=null);eq(await page.evaluate(script()),'waiting-ready');eq(await page.evaluate(()=>requests.length),0);
  await reset();await page.locator('#frmLogin [name=iv]').evaluate(e=>e.value='');eq(await page.evaluate(script()),'waiting-ready');
  await reset();await page.locator('#frmLogin').evaluate(e=>e.style.display='none');eq(await page.evaluate(script()),'missing-fields');eq(await page.locator('#register_name').inputValue(),'');
  await reset();await page.locator('#first_button').evaluate(e=>e.setAttribute('onclick','unrelated++'));eq(await page.evaluate(script()),'missing-submit');eq(await page.evaluate(()=>requests.length),0);eq(await page.evaluate(()=>unrelated),0);
  await reset();await page.evaluate(()=>document.body.insertAdjacentHTML('beforeend','<input type="checkbox" id="serverAgreement">'));eq(await page.evaluate(script()),'agreement-required');eq(await page.evaluate(()=>requests.length),0);
  await reset();await page.evaluate(()=>document.body.insertAdjacentHTML('beforeend','<div id="login-protocol" data-selected="1"></div>'));eq(await page.evaluate(script()),'agreement-required');eq(await page.evaluate(()=>requests.length),0);
  await page.evaluate(()=>$('#login-protocol').data('selected',2));eq(await page.evaluate(script()),'submitted');eq(await page.evaluate(()=>requests.length),1);
  await reset();eq(await page.evaluate(script({origin:'http://foreign.test'})),'wrong-origin');eq(await page.locator('#first_password').inputValue(),'');
  await reset();await page.locator('#first_name').evaluate(e=>e.readOnly=true);eq(await page.evaluate(script()),'missing-fields');eq(await page.locator('#register_name').inputValue(),'');
  console.log('PASS:',checks,'Gportal checks: supplied NBSP login input, strict login-form scope, original login()/encryption call, hidden fields, success/rejection/network errors, readiness, agreement and manual-mode gates.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
