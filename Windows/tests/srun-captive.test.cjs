const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
let origin='';
const template=fs.readFileSync(path.join(__dirname,'../source/PortalTemplate.js'),'utf8')
 .replace('  /*CAMPUS_ACCOUNT*/',fs.readFileSync(path.join(__dirname,'../source/PortalAccount.js'),'utf8').trimEnd());
// Captured SRun form IDs and hidden fields, with invented values and an offline
// school-handler substitute; no real school bundle, encryption or API is replayed.
const form='<form id="login-form"><input type="hidden" id="ac_id" name="ac_id" value="fixture"><input type="hidden" id="user_ip" name="user_ip" value="192.0.2.10"><input type="hidden" id="nas_ip" name="nas_ip"><input type="hidden" id="user_mac" name="user_mac"><input type="hidden" id="url" name="url"><input type="text" id="username" name="username" placeholder="请输入用户名"><input type="password" id="password" name="password" placeholder="请输入密码"><button type="button" id="login" disabled>登录</button></form><script>window.clicks=0;setTimeout(()=>{login.disabled=false;login.addEventListener("click",()=>{clicks++;window.sent=[username.value,password.value,ac_id.value,user_ip.value]})},120)</script>';
const script=(submit=true)=>template.replace('/*CAMPUS_CONFIG*/',JSON.stringify({origin,username:'fixture-user',password:'fixture-secret',submit,serviceOption:'',confirmSubmit:true}));
(async()=>{
 const server=http.createServer((req,res)=>{if(req.url==='/entry'){res.writeHead(302,{location:'/srun_portal_pc?ac_id=fixture&theme=basic'});res.end();return;}res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});res.end(form);});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage();
  await page.goto(origin+'/entry');await page.waitForFunction(()=>!!document.querySelector('#login')&&!document.querySelector('#login').disabled);
  assert.equal(await page.evaluate(script()),'submitted');
  assert.deepEqual(await page.evaluate(()=>sent),['fixture-user','fixture-secret','fixture','192.0.2.10']);
  assert.equal(await page.evaluate(script()),'already-submitted');assert.equal(await page.evaluate(()=>clicks),1);
  await page.reload();await page.waitForFunction(()=>!!document.querySelector("#login")&&!document.querySelector("#login").disabled);
  assert.equal(await page.evaluate(script(false)),'filled');assert.equal(await page.locator('#username').inputValue(),'fixture-user');assert.equal(await page.evaluate(()=>clicks),0);
  console.log('PASS: captured SRun form structure, live-entry redirect, async button readiness, correct fields, hidden parameters, school click handler, single submit and manual mode.');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve))}
})().catch(e=>{console.error(e);process.exitCode=1});
