const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const fixture=fs.readFileSync(path.join(__dirname,'fixtures/cmcc-union.html'),'utf8');
const scripts=JSON.parse(fs.readFileSync(path.join(__dirname,'../work/frame-scripts.json'),'utf8'));
const context=fs.readFileSync(path.join(__dirname,'../source/PortalContext.js'),'utf8');
const swift=fs.readFileSync(path.join(__dirname,'../../macOS/source/Core.swift'),'utf8');
assert.equal(swift.split('    static let contextScript = #"""\n')[1].split('    """#')[0].split('\n').map(l=>l.startsWith('    ')?l.slice(4):l).join('\n').trim(),context.trim());
const wrap=(script,fallback="'missing-fields'")=>context.replace('/*CONTEXT_ORIGIN*/','"http://portal.test"').replace('/*CONTEXT_FALLBACK*/',fallback).replace('/*CONTEXT_PASSWORD_SELECTOR*/','""').replace('/*CONTEXT_SCRIPT*/',script);
(async()=>{
const browser=await chromium.launch(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH,headless:true}:{headless:true});let checks=1;
const eq=(a,b)=>{assert.deepEqual(a,b);checks++};
try{
 const page=await browser.newPage();let outer;
 await page.route('**/*',r=>{
  const u=new URL(r.request().url());
  return r.fulfill({contentType:'text/html',body:u.pathname==='/login'?fixture:u.pathname==='/nested'?'<iframe src="/login" width="900" height="650"></iframe>':outer});
 });
 const load=async html=>{outer=html;await page.goto('http://portal.test/');};
 const loginFrame=()=>page.frames().find(f=>f.url()==='http://portal.test/login');
 const empty=async()=>{for(const f of page.frames())if(f.url().endsWith('/login')){eq(await f.locator('#pwd').inputValue(),'');eq(await f.evaluate(()=>loginCalls),0)}};
 await load('<frameset rows="*"><frame src="/login" id="topFrame1"></frameset>');
 eq(await page.evaluate(scripts.probe),true);eq(await page.evaluate(scripts.fill),'captcha-required');
 eq(await loginFrame().locator('#username').inputValue(),'dummy-user');eq(await loginFrame().locator('#pwd').inputValue(),'dummy-password');
 eq(await loginFrame().evaluate(()=>reveals),1);eq(await loginFrame().evaluate(()=>handlerCalls),0);eq(await loginFrame().locator('#autocheckbox').isChecked(),false);
 eq(await page.evaluate(scripts.captcha),'captcha-required');
 const challenge=JSON.parse(await page.evaluate(scripts.read));eq(challenge.length,0);eq(challenge.numericOnly,false);eq(challenge.autoSubmit,true);assert.match(challenge.image,/^data:image\/png;base64,/);checks++;
 eq(await page.evaluate(scripts.commit),'submitted');eq(await loginFrame().evaluate(()=>handlerCalls),1);eq(await loginFrame().evaluate(()=>loginCalls),1);
 eq(await page.evaluate(scripts.fill),'already-submitted');eq(await page.evaluate(scripts.commit),'captcha-stale');eq(await loginFrame().evaluate(()=>loginCalls),1);
 // maxlength is an upper bound on this page; shorter challenges remain valid.
 await load('<iframe src="/login" width="900" height="650"></iframe>');eq(await page.evaluate(scripts.fill),'captcha-required');await page.evaluate(scripts.read);
 eq(await page.evaluate(wrap("window.__campusCaptcha.commit(window.__campusCaptcha.ticket, 'aB7Z123')")),'captcha-invalid');
 eq(await page.evaluate(wrap("window.__campusCaptcha.commit(window.__campusCaptcha.ticket, 'aB7Z')")),'submitted');eq(await loginFrame().evaluate(()=>loginCalls),1);
 // Stale challenges, replaced frames and navigation must not reuse a challenge.
 await load('<iframe src="/login" width="900" height="650"></iframe>');eq(await page.evaluate(scripts.fill),'captcha-required');await page.evaluate(scripts.read);
 await loginFrame().locator('#username').fill('changed');eq(await page.evaluate(scripts.commit),'captcha-stale');eq(await loginFrame().evaluate(()=>handlerCalls),0);
 await load('<iframe src="/login" width="900" height="650"></iframe>');eq(await page.evaluate(scripts.fill),'captcha-required');await page.evaluate(scripts.read);
 await page.locator('iframe').evaluate(e=>e.src='http://foreign.test/login');await page.waitForFunction(()=>document.querySelector('iframe').contentDocument===null);
 eq(await page.evaluate(scripts.commit),'captcha-stale');eq(await page.evaluate(scripts.probe),false);
 await load('<iframe src="/nested" width="1000" height="750"></iframe>');eq(await page.evaluate(scripts.fill),'captcha-required');eq(await loginFrame().locator('#pwd').inputValue(),'dummy-password');
 await load('<iframe src="http://foreign.test/login" width="900" height="650"></iframe>');eq(await page.evaluate(scripts.probe),false);eq(await page.evaluate(scripts.fill),'wrong-origin');await empty();
 await load('<iframe sandbox="allow-scripts" src="/login" width="900" height="650"></iframe>');eq(await page.evaluate(scripts.probe),false);await empty();
 for(const style of ['display:none','visibility:hidden','width:0;height:0;border:0']){
  await load(`<iframe src="/login" style="${style}"></iframe>`);eq(await page.evaluate(scripts.probe),false);await empty();
 }
 await load('<iframe src="/login" width="900" height="650"></iframe><iframe src="/login" width="900" height="650"></iframe>');eq(await page.evaluate(scripts.probe),false);eq(await page.evaluate(scripts.fill),'wrong-origin');await empty();
 // Generic top-level pages and the original legacy prompt still work.
 await load(fixture);eq(await page.evaluate(scripts.fill),'captcha-required');eq(await page.locator('#pwd').inputValue(),'dummy-password');
 await load('<iframe src="/login" width="900" height="650"></iframe>');eq(await page.evaluate(scripts.manual),'captcha-required');const manual=JSON.parse(await page.evaluate(scripts.read));eq(manual.autoSubmit,false);eq(await page.evaluate(scripts.commit),'filled');eq(await loginFrame().evaluate(()=>loginCalls),0);
 // The macOS build uses the same frame context and leaves the challenge manual.
 const macPath=path.join(__dirname,'../work/mac-frame-script.js');
 if(fs.existsSync(macPath)){
  const mac=fs.readFileSync(macPath,'utf8');await load('<frameset rows="*"><frame src="/login"></frameset>');eq(await page.evaluate(mac),'manual-required');eq(await loginFrame().locator('#username').inputValue(),'dummy-user');eq(await loginFrame().locator('#pwd').inputValue(),'dummy-password');eq(await loginFrame().evaluate(()=>loginCalls),0);
  await loginFrame().locator('#ps').fill('aB7Z12');eq(await page.evaluate(mac),'submitted');eq(await loginFrame().evaluate(()=>loginCalls),1);
 }
 console.log(`PASS: ${checks} frame/union checks (generated Windows scripts, native-realm inputs, nested frames, foreign/sandbox/hidden/ambiguous denial, CAPTCHA placeholder/read/commit/staleness, manual mode, Swift parity).`);
}finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
