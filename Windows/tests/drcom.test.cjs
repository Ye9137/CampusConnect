const {chromium} = require('playwright');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const http = require('node:http'), assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'campus-drcom-'));
let scripts;
try {
  const file = path.join(dir, 'scripts.json');
  execFileSync('dotnet', ['run', '--project', path.join(__dirname, 'CampusConnect.Tests.csproj'), '--', '--drcom-fixture', file], {stdio:'pipe'});
  scripts = JSON.parse(fs.readFileSync(file, 'utf8'));
} finally { fs.rmSync(dir, {recursive:true, force:true}); }

const login = `<title>Drcom上网登录窗</title><form method=post action=/result onsubmit="return ee()">
<input id=username name=DDDDD><input id=password name=upass type=password>
<input id=submit type=submit name=0MKKey value="登　录" onclick="Clicked()">
<input id=submit type=reset value="重　置"></form><script>
function Clicked(){open('http://drcom.test:9002/In0','p99','width=360,height=160')}
function ee(){window.submits=(window.submits||0)+1;return true}
</script>`;
const logout = `<title>Logout</title><script>
s1=020;sec=20232;uf=297786;df=1224691;s2=0;
url1='http://drcom.test:9002/0';url2='http://drcom.test/F.htm';
function ee(){if(s2!=1){window.open(url1,'','width=360,height=160');window.close()}}
function wc(){if(confirm('关闭此窗口意味着结束本次连接，注销请按确定')){s2=1;window.open(url2);window.close()}}
</script><body onUnload="ee()"><a href="javascript:wc()">注 销</a>`;
(async () => {
  const requests = [];
  const server = http.createServer(async (req,res) => {
    const url = new URL(req.url, 'http://' + req.headers.host);
    let body = ''; for await (const part of req) body += part;
    requests.push({method:req.method,url:url.href,body});
    res.writeHead(200, {'Content-Type':'text/html; charset=utf-8'});
    if (url.pathname === '/result') res.end('<title>信息返回</title><script>Msg=15</script>登录成功');
    else if (url.port === '9002') res.end(logout);
    else if (url.pathname === '/F.htm') res.end('<title>信息返回</title><script>Msg=14</script>注销成功');
    else res.end(login);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({headless:true,proxy:{server:'http://127.0.0.1:'+server.address().port}});
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto('http://drcom.test/');
    assert.equal(await page.evaluate(scripts.manual), 'filled');
    assert.equal(requests.filter(r=>r.method==='POST').length, 0);
    const popupReady = page.waitForEvent('popup');
    // Navigation destroys the evaluation context after the real form POST.
    await page.evaluate(scripts.fill).catch(e => { if(!/context was destroyed/i.test(e.message))throw e; });
    const popup = await popupReady;
    await Promise.all([popup.waitForLoadState(), page.waitForURL('http://drcom.test/result')]);
    assert.equal(await page.evaluate(scripts.status), 'authenticated', 'Msg=15 is accepted');
    for (const title of ['信息返回窗', '信息返回窗口']) {
      await page.evaluate(text=>{document.title=text},title);
      assert.equal(await page.evaluate(scripts.status),'authenticated','result title variant is accepted');
    }
    await page.evaluate(()=>{document.title='信息返回'});
    assert.equal(await popup.evaluate(scripts.popup), 'authenticated', 'cross-port Logout page is accepted');
    assert.equal(await popup.evaluate(scripts.popupFill), 'authenticated', 'status page never receives another submit');
    assert.deepEqual(requests.filter(r=>r.method==='POST').map(r=>new URLSearchParams(r.body).get('DDDDD')), ['fixture-user']);
    assert(requests.find(r=>r.method==='POST').body.includes('upass=fixture-secret'));
    assert(!requests.some(r=>r.url.includes('/F.htm')), 'automatic login never requests logout');
    assert.equal(await popup.locator('input[type=password]').count(),0);
    for (const msg of [1,2,3,14,0]) {
      await page.evaluate(n=>{window.Msg=n}, msg);
      assert.equal(await page.evaluate(scripts.status), [0,14].includes(msg)?'not-submitted':'authentication-rejected:DRCOM_'+msg);
    }
    // All success branches in source are not success until the school executes one.
    await page.setContent('<title>信息返回</title><script>Msg=3;if(Msg===15)document.write("登录成功")</script>密码错误');
    assert.equal(await page.evaluate(scripts.status),'authentication-rejected:DRCOM_3');
    await page.setContent('<title>Logout</title>注销 登录成功 已使用流量<script>url2="http://drcom.test/F.htm"</script>');
    assert.equal(await page.evaluate(scripts.status),'not-submitted','title/text/URL alone are insufficient');
    await popup.evaluate(()=>{url2='http://other.test/F.htm'});
    assert.equal(await popup.evaluate(scripts.popup),'not-submitted','foreign logout URL is rejected');
    await popup.evaluate(()=>{url2='http://drcom.test/F.htm';document.querySelector('a').style.display='none'});
    assert.equal(await popup.evaluate(scripts.popup),'not-submitted','hidden status control is insufficient');
    await page.goto('http://drcom.test/');
    await page.evaluate(()=>{document.querySelector('[type=submit]').outerHTML='<button type=button onclick="window.spacedClicks=(window.spacedClicks||0)+1">登　录</button>'});
    assert.equal(await page.evaluate(scripts.fill),'submitted','full-width spaces work without a known submit ID');
    assert.equal(await page.evaluate(scripts.fill),'already-submitted');
    assert.equal(await page.evaluate(()=>spacedClicks),1);
    console.log('PASS: Dr.COM independent popup + real form POST, duplicate ID/reset, full-width login text, Msg success/rejection/logout, status-page deduplication, negative signatures, and no automatic logout.');
  } finally { await browser.close(); await new Promise(resolve=>server.close(resolve)); }
})().catch(e=>{console.error(e);process.exitCode=1});
