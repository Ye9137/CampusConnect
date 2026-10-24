const {chromium}=require('playwright');
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const os=require('node:os');
const {execFileSync}=require('node:child_process');
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'campus-redirect-'));
let data;
try {
 const fixturePath=path.join(temporary,'fixture.json');
 execFileSync('dotnet',['run','--project',path.join(__dirname,'CampusConnect.Tests.csproj'),'--','--redirect-fixture',fixturePath],{stdio:'pipe'});
 data=JSON.parse(fs.readFileSync(fixturePath,'utf8'));
} finally {fs.rmSync(temporary,{recursive:true,force:true})}

const bootstrap=fs.readFileSync(path.join(__dirname,'../../macOS/source/PortalBootstrap.js'),'utf8');
const entryBootstrap=bootstrap.replace('/*CAMPUS_ORIGIN*/',JSON.stringify('http://1.1.1.1'));
const landingBootstrap=bootstrap.replace('/*CAMPUS_ORIGIN*/',JSON.stringify('http://10.129.1.1'));
(async()=>{
 // A loopback-only synthetic HTTP proxy answers every host itself. Redirect
 // requests cannot escape to a real campus server or the public Internet.
 const http=require('node:http');
 const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://'+req.headers.host);
  const html=body=>{res.writeHead(200,{'content-type':'text/html; charset=utf-8'});res.end(body)};
  if(url.host==='1.1.1.1'){res.writeHead(302,{location:'http://10.129.1.1/landing'});res.end();return}
  if(url.host==='other.test')return html('<input name=username><input type=password><button>连接</button>');
  if(url.host!=='10.129.1.1'){res.writeHead(403);res.end();return}
  if(url.pathname==='/landing')return html(`<script>location.replace(${JSON.stringify(data.finalUrl)})</script>`);
  if(url.pathname==='/spinner')return html('正在跳转…');
  if(url.pathname==='/zportal')return html(fs.readFileSync(path.join(__dirname,'fixtures/zportal-login.html'),'utf8'));
  if(url.pathname==='/haust')return html(fs.readFileSync(path.join(__dirname,'fixtures/haust-login.html'),'utf8'));
  return html(`<input name=username><input type=password><button type=button id=login onclick="window.clicks=(window.clicks||0)+1">连接</button>`);
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({headless:true,proxy:{server:'http://127.0.0.1:'+server.address().port},...(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH}:{})});
 try{
  const page=await browser.newPage();
  const requests=[];
  page.on('request',request=>requests.push({url:request.url(),body:request.postData()}));
  await page.addInitScript(entryBootstrap);
  await page.goto('http://1.1.1.1');
  await page.waitForURL(data.finalUrl);
  assert.equal(await page.locator('input[type=password]').inputValue(),'','redirect pages receive no password');
  assert.equal(await page.evaluate(data.entryProbe),false,'saved origin probe cannot authorize redirected page');
  assert.equal(await page.evaluate(data.wrongOriginFill),'wrong-origin','old origin gate is retained');
  assert.equal(await page.evaluate(data.probe),true,'approved final page recognized');
  assert.equal(await page.evaluate(()=>typeof window.__campusCollapseServiceMenu),'undefined','entry-scoped bootstrap does not run on arbitrary origin');
  await page.evaluate(landingBootstrap);
  await page.evaluate(landingBootstrap);
  assert.equal(await page.evaluate(()=>typeof window.__campusCollapseServiceMenu),'function','bootstrap installed on approved destination without reloading');
  assert.equal(await page.evaluate(data.fill),'submitted','redirect destination can fill and submit');
  assert.equal(await page.locator('[name=username]').inputValue(),'fixture-user');
  assert.equal(await page.locator('input[type=password]').inputValue(),'fixture-password');
  assert.equal(await page.evaluate(data.fill),'already-submitted');
  assert.equal(await page.evaluate(()=>clicks),1,'one login across HTTP and script redirects');
  assert.deepEqual(requests.map(request=>request.url),['http://1.1.1.1/','http://10.129.1.1/landing',data.finalUrl]);
  assert(requests.every(request=>!request.body&&!request.url.includes('fixture-password')),'redirect requests carry no saved password');
  await page.goto('http://10.129.1.1/spinner');
  assert.equal(await page.evaluate(data.probe),false,'loading/intermediate page does not pin credentials');
  await page.goto('http://10.129.1.1/zportal');
  assert.equal(await page.evaluate(data.probe),true,'native preflight preserves zPortal hidden-password support');
  assert.equal(await page.evaluate(data.fill),'submitted');
  assert.deepEqual(await page.evaluate(()=>[loginClicks,qrClicks]),[1,0],'redirect flow preserves school password reveal and excludes QR login');
  await page.goto('http://10.129.1.1/haust');
  assert.equal(await page.evaluate(data.probe),true,'redirected HAUST form recognized');
  assert.equal(await page.evaluate(data.fill),'submitted');
  assert.deepEqual(await page.evaluate(()=>[loginClicks,otherClicks,observed]),[1,0,['fixture-user','fixture-password']],'redirected HAUST button calls original checkForm');
  await page.goto('http://other.test/login');
  assert.equal(await page.evaluate(data.probe),false);
  assert.equal(await page.evaluate(data.fill),'wrong-origin','pinning preserves foreign-page denial');
  assert.equal(await page.locator('input[type=password]').inputValue(),'');
  console.log('PASS: offline 1.1.1.1 HTTP redirect + script redirect, query preservation, landing form probe, destination bootstrap, one login, credential-free intermediate requests, unrelated-origin denial.');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve))}
})().catch(error=>{console.error(error);process.exitCode=1});
