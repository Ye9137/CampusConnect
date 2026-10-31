const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const template = fs.readFileSync(path.join(__dirname, '../source/PortalTemplate.js'), 'utf8').replace('  /*CAMPUS_ACCOUNT*/',fs.readFileSync(path.join(__dirname,'../source/PortalAccount.js'),'utf8').trimEnd()).replace(/\r\n/g, '\n');
// Windows portal behavior is maintained and packaged independently of macOS.
const cfg = {origin:'http://portal.test', username:'test-account\'"', password:'test-password\'"',
  userSelector:'', passwordSelector:'', submitSelector:'', submit:true};
const script = overrides => template.replace('/*CAMPUS_CONFIG*/', JSON.stringify({...cfg, ...overrides}));
// Reduced from the school's ePortal markup: visible readonly tips, hidden
// inputs, blur re-hiding empty fields and an image-only anchor login control.
const fixture = `<!doctype html><html><body>
<input id="username_tip" name="username_tip" readonly value="用户名">
<input id="username" name="username" type="text" style="display:none">
<input id="pwd_tip" readonly value="密码">
<input id="pwd" type="password" style="display:none">
<a id="loginLink" tabindex="-1"><div style="width:275px;height:54px;background:blue"></div></a>
<script>
window.clicks = 0; window.events = [];
for (const id of ['username','pwd']) {
  const input = document.getElementById(id), tip = document.getElementById(id+'_tip');
  tip.onfocus = () => {input.style.display='';input.focus();tip.style.display='none';};
  input.onblur = () => {if (!input.value) {input.style.display='none';tip.style.display='';}};
  for (const event of ['input','change']) input.addEventListener(event,()=>events.push(id+':'+event));
}
document.getElementById('loginLink').onclick = () => clicks++;
</script></body></html>`;
(async () => {
  const browser = await chromium.launch(process.env.CAMPUS_CHROME_PATH ? {executablePath:process.env.CAMPUS_CHROME_PATH,headless:true} : {headless:true});
  try {
    const page = await browser.newPage();
    await page.route('http://portal.test/**', route => route.fulfill({contentType:'text/html; charset=utf-8',body:fixture}));
    const reset = () => page.goto('http://portal.test/eportal/index.jsp');
    await reset();
    assert.equal(await page.evaluate(script()), 'submitted');
    assert.equal(await page.locator('#username').inputValue(),cfg.username);
    assert.equal(await page.locator('#pwd').inputValue(),cfg.password);
    assert.equal(await page.locator('#username').isVisible(),true);
    assert.equal(await page.locator('#pwd').isVisible(),true);
    assert.equal(await page.locator('#username_tip').inputValue(),'用户名');
    assert.equal(await page.locator('#pwd_tip').inputValue(),'密码');
    assert.equal(await page.evaluate(script()), 'already-submitted');
    assert.equal(await page.evaluate(()=>clicks),1);
    assert.deepEqual(await page.evaluate(()=>events),['username:input','username:change','pwd:input','pwd:change']);
    // An inactive/hidden WebView can fail to deliver native focus events.
    await reset();
    await page.evaluate(() => {
      for (const id of ['username_tip','pwd_tip']) document.getElementById(id).focus = () => {};
    });
    assert.equal(await page.evaluate(script()), 'submitted');
    assert.equal(await page.locator('#pwd').inputValue(), cfg.password);
    assert.equal(await page.evaluate(() => clicks), 1);
    assert.equal(await page.evaluate(script()), 'already-submitted');
    // Some portal variants reveal the password only from a click handler.
    await reset();
    await page.evaluate(() => {
      const tip = document.getElementById('pwd_tip');
      tip.onclick = tip.onfocus; tip.onfocus = null;
    });
    assert.equal(await page.evaluate(script()), 'submitted');
    assert.equal(await page.locator('#pwd').inputValue(), cfg.password);
    assert.equal(await page.evaluate(() => clicks), 1);
    // Delegated focus handlers must also work without native focus.
    await reset();
    await page.evaluate(() => {
      const tip = document.getElementById('pwd_tip'), activate = tip.onfocus;
      tip.onfocus = null; tip.focus = () => {};
      document.addEventListener('focusin', event => { if (event.target === tip) activate(); });
    });
    assert.equal(await page.evaluate(script()), 'submitted');
    assert.equal(await page.locator('#pwd').inputValue(), cfg.password);
    // Do not submit if school input handlers discard the supplied password.
    await reset();
    await page.locator('#pwd').evaluate(input => input.onchange = () => { input.value = ''; });
    assert.equal(await page.evaluate(script()), 'missing-fields');
    assert.equal(await page.evaluate(() => clicks), 0);
    await page.locator('#pwd').evaluate(input => input.onchange = null);
    assert.equal(await page.evaluate(script()), 'submitted');
    await reset();
    assert.equal(await page.evaluate(script({submit:false})), 'filled');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset();
    assert.equal(await page.evaluate(script({origin:'http://different.test'})), 'wrong-origin');
    assert.equal(await page.locator('#pwd').inputValue(),'');
    assert.equal(await page.locator('#pwd').isVisible(),false);
    assert.equal(await page.evaluate(script({userSelector:'['})), 'invalid-selector');
    assert.equal(await page.locator('#username').inputValue(),'');
    assert.equal(await page.evaluate(script({userSelector:'#username_tip'})), 'missing-fields');
    assert.equal(await page.evaluate(script({userSelector:'#username',passwordSelector:'#pwd',submitSelector:'#loginLink'})), 'submitted');
    await reset();
    await page.locator('#loginLink').evaluate(e=>e.disabled=true);
    assert.equal(await page.evaluate(script()), 'missing-submit');
    assert.equal(await page.evaluate(()=>clicks),0);
    await page.locator('#loginLink').evaluate(e=>e.disabled=false);
    assert.equal(await page.evaluate(script()), 'submitted');
    assert.equal(await page.evaluate(()=>clicks),1);
    await reset();
    await page.locator('#pwd_tip').evaluate(e=>e.onfocus=null);
    assert.equal(await page.evaluate(script()), 'missing-fields');
    assert.equal(await page.locator('#pwd').inputValue(),'');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset();
    await page.locator('#pwd').evaluate(e=>e.disabled=true);
    assert.equal(await page.evaluate(script()), 'missing-fields');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset();
    await page.setContent('<input readonly name="username_tip" value="提示"><input name="account"><input type="password"><a href="#" onclick="window.genericClicks=(window.genericClicks||0)+1">认证</a>');
    assert.equal(await page.evaluate(script()),'submitted');
    assert.equal(await page.locator('[name=account]').inputValue(),cfg.username);
    assert.equal(await page.locator('[readonly]').inputValue(),'提示');
    assert.equal(await page.evaluate(()=>genericClicks),1);
    // Native select: exact visible name, events, no selection when blank, no wrong submission.
    const nativeService = '<input name="username"><input type="password"><select id="service"><option value="">请选择服务</option><option value="unicom">联通接入服务</option><option value="mobile">移动接入服务</option></select><button type="submit" onclick="window.clicks++">登录</button>';
    await reset();
    await page.setContent(nativeService);
    await page.evaluate(() => { window.clicks=0; window.serviceEvents=[]; for (const type of ['input','change']) document.querySelector('select').addEventListener(type,()=>serviceEvents.push(type)); });
    assert.equal(await page.evaluate(script({serviceOption:'  联通接入服务  '})), 'submitted');
    assert.equal(await page.locator('#service').inputValue(),'unicom');
    assert.deepEqual(await page.evaluate(()=>serviceEvents),['input','change']);
    assert.equal(await page.evaluate(()=>clicks),1);
    await reset(); await page.setContent(nativeService);
    assert.equal(await page.evaluate(script({serviceOption:''})), 'service-required');
    assert.equal(await page.locator('#service').inputValue(),'');
    assert.equal(await page.evaluate(()=>clicks),0);
    // Keep an existing valid selection when no service was configured.
    await page.selectOption('#service','mobile');
    assert.equal(await page.evaluate(script({serviceOption:''})), 'submitted');
    await reset(); await page.setContent(nativeService);
    assert.equal(await page.evaluate(script({serviceOption:'联通'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    assert.equal(await page.evaluate(script({serviceOption:'不存在'})), 'missing-service');
    await page.locator('option[value=unicom]').evaluate(e=>e.disabled=true);
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    await page.locator('option[value=unicom]').evaluate(e=>e.disabled=false);
    await page.locator('#service').evaluate(e=>e.onchange=()=>{e.value='';});
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset(); await page.setContent(nativeService + '<select><option>联通接入服务</option></select>');
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    // Delayed services can arrive between retries.
    await reset(); await page.setContent(nativeService.replace('<option value="unicom">联通接入服务</option>',''));
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    await page.locator('#service').evaluate(e=>e.add(new Option('联通接入服务','unicom')));
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务',submit:false})), 'filled');
    assert.equal(await page.locator('#service').inputValue(),'unicom');
    assert.equal(await page.evaluate(()=>clicks),0);
    // Screenshot regression: operator select is a sibling of the login form.
    const operatorPage = `<form id="login"><input name="username"><input type="password">
      <button type="button" onclick="window.selectionAtSubmit=document.querySelector('#operator').value;window.clicks++">登录</button></form>
      <select id="operator"><option value="">选择运营商</option><option value="cmcc">中国移动</option>
      <option value="unicom">中国联通</option><option value="telecom">中国电信</option></select>`;
    for (const [serviceOption, value] of [['中国移动','cmcc'],['中国联通','unicom'],['中国电信','telecom']]) {
      await reset(); await page.setContent(operatorPage);
      await page.evaluate(() => {window.serviceEvents=[];document.querySelector('#operator').onchange=()=>serviceEvents.push('change');});
      assert.equal(await page.evaluate(script({serviceOption})), 'submitted');
      assert.equal(await page.locator('#operator').inputValue(),value);
      assert.equal(await page.evaluate(()=>selectionAtSubmit),value);
      assert.deepEqual(await page.evaluate(()=>serviceEvents),['change']);
      assert.equal(await page.evaluate(script({serviceOption})), 'already-submitted');
      assert.equal(await page.evaluate(()=>clicks),1);
    }
    await reset(); await page.setContent(operatorPage);
    assert.equal(await page.evaluate(script({serviceOption:''})), 'service-required');
    assert.equal(await page.evaluate(()=>clicks),0);
    assert.equal(await page.locator('#operator').inputValue(),'');
    assert.equal(await page.evaluate(script({serviceOption:'中国电信',submit:false})), 'filled');
    assert.equal(await page.locator('#operator').inputValue(),'telecom');
    assert.equal(await page.evaluate(()=>clicks),0);
    // Other forms and hidden/disabled operator controls cannot supply a match.
    await reset(); await page.setContent(operatorPage.replace('<select id="operator">','<form id="other"><select id="operator">')+'</form>');
    assert.equal(await page.evaluate(script({serviceOption:'中国联通'})), 'missing-service');
    assert.equal(await page.locator('#operator').inputValue(),'');
    assert.equal(await page.evaluate(()=>clicks),0);
    for (const attribute of ['hidden','disabled']) {
      await reset(); await page.setContent(operatorPage.replace('<select id="operator">',`<select id="operator" ${attribute}>`));
      assert.equal(await page.evaluate(script({serviceOption:'中国联通'})), 'missing-service');
      assert.equal(await page.evaluate(()=>clicks),0);
    }
    await reset(); await page.setContent(operatorPage);
    await page.locator('#operator').evaluate(e=>e.onchange=()=>{e.value='';});
    assert.equal(await page.evaluate(script({serviceOption:'中国联通'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    // The list does not exist until the opener is clicked; names are unrestricted.
    const customOperator = async (lazy=false) => {
      await reset();
      await page.setContent(`<form><input name="username"><input type="password"><button type="button" onclick="window.clicks++">登录</button></form>
        <button id="choose" role="combobox" aria-expanded="false" aria-controls="operator-options">选择运营商</button>`);
      await page.evaluate(lazy => {
        window.opens=0; window.selectedService='';
        const opener=document.getElementById('choose');
        window.loadOperators=()=>{
          document.getElementById('operator-options')?.remove();
          document.body.insertAdjacentHTML('beforeend','<ul id="operator-options" role="listbox"></ul>');
          const popup=document.getElementById('operator-options');
          for (const name of ['中国移动','中国联通','中国电信','校园专线 A']) {
            const option=document.createElement('li');option.setAttribute('role','option');option.textContent=name;
            option.onclick=()=>{opener.textContent=name;opener.setAttribute('aria-expanded','false');popup.hidden=true;window.selectedService=name;};
            popup.append(option);
          }
        };
        opener.onclick=()=>{opens++;opener.setAttribute('aria-expanded','true');if(!lazy)loadOperators();};
      },lazy);
    };
    for (const name of ['中国移动','中国联通','中国电信','校园专线 A']) {
      await customOperator();
      assert.equal(await page.locator('[role=option]').count(),0);
      assert.equal(await page.evaluate(script({serviceOption:name})), 'submitted');
      assert.equal(await page.evaluate(()=>selectedService),name);
      assert.equal(await page.evaluate(()=>opens),1);
      assert.equal(await page.evaluate(()=>clicks),1);
    }
    await customOperator(true);
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A'})), 'missing-service');
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A'})), 'missing-service');
    assert.equal(await page.evaluate(()=>opens),1);
    assert.equal(await page.evaluate(()=>clicks),0);
    await page.evaluate(()=>loadOperators());
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A',submit:false})), 'filled');
    assert.equal(await page.evaluate(()=>selectedService),'校园专线 A');
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A'})), 'submitted');
    assert.equal(await page.evaluate(()=>opens),1);
    await customOperator();
    await page.locator('#choose').evaluate(e=>{e.textContent='中国联通';});
    assert.equal(await page.evaluate(script({serviceOption:'中国移动',submit:false})), 'filled');
    assert.equal(await page.evaluate(()=>selectedService),'中国移动');
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A',submit:false})), 'filled');
    assert.equal(await page.evaluate(()=>selectedService),'校园专线 A');
    assert.equal(await page.evaluate(()=>opens),2);
    await customOperator();
    assert.equal(await page.evaluate(script({serviceOption:''})), 'service-required');
    assert.equal(await page.evaluate(()=>opens),0);
    assert.equal(await page.evaluate(()=>clicks),0);
    await customOperator(true); await page.evaluate(script({serviceOption:'中国移动'}));
    await page.evaluate(()=>{loadOperators();document.querySelector('[role=option]').setAttribute('aria-disabled','true');});
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await customOperator(true); await page.evaluate(script({serviceOption:'中国移动'}));
    await page.evaluate(()=>{loadOperators();document.querySelector('[role=option]').onclick=()=>{};});
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await customOperator();
    assert.equal(await page.evaluate(script({serviceOption:'不存在的服务'})), 'missing-service');
    assert.equal(await page.evaluate(()=>selectedService),'');
    assert.equal(await page.evaluate(()=>clicks),0);
    await customOperator(true); await page.evaluate(script({serviceOption:'中国移动'}));
    await page.evaluate(()=>{loadOperators();const option=document.querySelector('[role=option]');option.after(option.cloneNode(true));});
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await customOperator(true); await page.evaluate(script({serviceOption:'中国移动'}));
    await page.evaluate(()=>{
      loadOperators();const option=document.querySelector('[role=option]'),commit=option.onclick;
      option.onclick=()=>{window.commitOperator=commit;document.getElementById('operator-options').hidden=true;};
    });
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await page.evaluate(()=>commitOperator());
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'submitted');
    assert.equal(await page.evaluate(()=>opens),1);
    // A simple placeholder button also retains its selection across retries.
    await customOperator();
    await page.locator('#choose').evaluate(e=>{e.removeAttribute('role');e.removeAttribute('aria-controls');e.removeAttribute('aria-expanded');e.textContent='选择选项';});
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A',submit:false})), 'filled');
    assert.equal(await page.evaluate(script({serviceOption:'校园专线 A'})), 'submitted');
    assert.equal(await page.evaluate(()=>opens),1);
    // Top-of-page radios, outside the login form, use the school's click flow.
    const radioNames = ['校园网','中国移动','中国电信','中国联通','校园专线 A'];
    const radioPage = `<div id="operators">${radioNames.map((name,index)=>`<label><input type="radio" name="operator" value="${index}" ${index===0?'checked':''}>${name}</label>`).join('')}</div>
      <form><input name="username"><input type="password"><button type="button" onclick="window.selectionAtSubmit=document.querySelector('[name=operator]:checked').value;window.clicks++">登录</button></form>`;
    const loadRadios = async (html=radioPage) => {
      await reset(); await page.setContent(html);
      await page.evaluate(()=>{
        window.operatorEvents=[];
        for(const radio of document.querySelectorAll('input[type=radio]'))
          radio.addEventListener('change',()=>operatorEvents.push(radio.value));
      });
    };
    for(const [index,name] of radioNames.entries()) {
      await loadRadios();
      assert.equal(await page.evaluate(script({serviceOption:name})), 'submitted');
      assert.equal(await page.evaluate(()=>selectionAtSubmit),String(index));
      assert.deepEqual(await page.evaluate(()=>operatorEvents),index===0?[]:[String(index)]);
      assert.equal(await page.evaluate(script({serviceOption:name})), 'already-submitted');
      assert.equal(await page.evaluate(()=>clicks),1);
    }
    await loadRadios(radioPage.replaceAll('<label>','').replaceAll('</label>',''));
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'submitted');
    assert.equal(await page.evaluate(()=>selectionAtSubmit),'1');
    // Combine the supplied localized FONT markup with a radio to cover discovery.
    const fontRadioPage = radioPage.replace(/<label>(<input[^>]+>)([^<]+)<\/label>/g,
      (_,input,name)=>`${input}\n<!-- localized operator -->\n<font style="padding-left:18px;" data-localize="pc.17522208445411">${name}</font>`);
    for (const [index,name] of radioNames.entries()) {
      await loadRadios(fontRadioPage);
      assert.equal(await page.evaluate(script({serviceOption:name})), 'submitted');
      assert.equal(await page.evaluate(()=>selectionAtSubmit),String(index));
      assert.deepEqual(await page.evaluate(()=>operatorEvents),index===0?[]:[String(index)]);
    }
    // Exact supplied SPAN/input[name=network][value=@cmcc]/FONT fragment.
    const cmccPage = fs.readFileSync(path.join(__dirname,'fixtures/cmcc-font-radio.html'),'utf8');
    await reset(); await page.setContent(cmccPage);
    assert.equal(await page.evaluate(script({serviceOption:'中国移动',confirmSubmit:true})), 'submitted');
    assert.equal(await page.locator('[name=network]:checked').inputValue(),'@cmcc');
    assert.equal(await page.evaluate(()=>selectionAtSubmit),'@cmcc');
    assert.deepEqual(await page.evaluate(()=>operatorEvents),['click','input','change']);
    assert.equal(await page.evaluate(script({serviceOption:'中国移动',confirmSubmit:true})), 'already-submitted');
    assert.equal(await page.evaluate(()=>clicks),1);
    await reset(); await page.setContent(cmccPage);
    assert.equal(await page.evaluate(script({serviceOption:'中国移动',submit:false,confirmSubmit:true})), 'filled');
    assert.equal(await page.locator('[name=network]:checked').inputValue(),'@cmcc');
    assert.equal(await page.evaluate(()=>clicks),0);
    // Rechecking a filled form must not fire the operator handler twice.
    assert.equal(await page.evaluate(script({serviceOption:'中国移动',submit:false,confirmSubmit:true})), 'filled');
    assert.deepEqual(await page.evaluate(()=>operatorEvents),['click','input','change']);
    await loadRadios(radioPage.replaceAll('type="radio"','type="radio" style="display:none"'));
    assert.equal(await page.evaluate(script({serviceOption:'中国联通'})), 'submitted');
    assert.equal(await page.evaluate(()=>selectionAtSubmit),'3');
    await loadRadios();
    await page.locator('[name=operator][value="1"]').evaluate(input=>{
      const label=input.parentElement;input.id='mobile';label.htmlFor='mobile';label.before(input);
    });
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'submitted');
    assert.equal(await page.evaluate(()=>selectionAtSubmit),'1');
    await loadRadios();
    await page.locator('[name=operator][value="1"]').evaluate(input=>{input.parentElement.setAttribute('role','radio');});
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'submitted');
    assert.equal(await page.evaluate(()=>selectionAtSubmit),'1');
    await loadRadios();
    assert.equal(await page.evaluate(script({serviceOption:''})), 'submitted');
    assert.equal(await page.evaluate(()=>selectionAtSubmit),'0');
    await loadRadios();
    assert.equal(await page.evaluate(script({serviceOption:'不存在'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await loadRadios(radioPage.replace('<div id="operators">','<fieldset disabled id="operators">').replace('</div>','</fieldset>'));
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await loadRadios(radioPage.replace('<div id="operators">','<form id="other">').replace('</div>','</form>'));
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await loadRadios(radioPage+'<label><input type="radio" name="other-operator">中国移动</label>');
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await loadRadios();
    await page.locator('[name=operator][value="1"]').evaluate(e=>e.onclick=event=>{window.radioAttempts=(window.radioAttempts||0)+1;event.preventDefault();});
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>radioAttempts),1);
    assert.equal(await page.evaluate(()=>clicks),0);
    await loadRadios();
    await page.locator('[name=operator][value="1"]').evaluate(e=>e.onchange=()=>{document.querySelector('input[type=password]').value='';});
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-fields');
    assert.equal(await page.evaluate(()=>clicks),0);
    // Accessible radio buttons may update aria-checked asynchronously.
    await reset();
    await page.setContent(`<div role="radiogroup"><div role="radio" aria-checked="true">校园网</div><div role="radio" aria-checked="false" id="mobile-radio">中国移动</div></div>
      <form><input name="username"><input type="password"><button type="button" onclick="window.clicks++">登录</button></form>`);
    await page.evaluate(()=>{
      window.radioAttempts=0;
      document.getElementById('mobile-radio').onclick=()=>{
        radioAttempts++;
        window.commitRadio=()=>{document.querySelectorAll('[role=radio]').forEach(e=>e.setAttribute('aria-checked',String(e.id==='mobile-radio')));};
      };
    });
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'missing-service');
    assert.equal(await page.evaluate(()=>radioAttempts),1);
    assert.equal(await page.evaluate(()=>clicks),0);
    await page.evaluate(()=>commitRadio());
    assert.equal(await page.evaluate(script({serviceOption:'中国移动',submit:false})), 'filled');
    assert.equal(await page.evaluate(script({serviceOption:'中国移动'})), 'submitted');
    assert.equal(await page.evaluate(()=>radioAttempts),1);
    // School ePortal uses clickable divs and a hidden value, not a native select.
    const addServiceMenu = async (lazy=false) => page.evaluate(lazy => {
      document.body.insertAdjacentHTML('beforeend', '<input type="hidden" id="net_access_type"><div id="serviceShowHideTop"><span id="selectDisname">请选择服务</span></div><div id="serviceShowHide" style="display:none"></div>');
      window.menuOpens=0; window.serviceClicks=0;
      window.populateServices = () => {
        const menu=document.getElementById('serviceShowHide');
        menu.innerHTML='<div id="bch_service_0"><div><div id="_service_0">联通接入服务</div></div></div>';
        document.getElementById('bch_service_0').onclick=()=>{
          window.serviceClicks++;
          document.getElementById('net_access_type').value='unicom-internal';
          document.getElementById('selectDisname').textContent='联通接入服务';
          menu.style.display='none';
          window.domainSelected='school.example';
        };
      };
      if(!lazy) populateServices();
      document.getElementById('serviceShowHideTop').onclick=()=>{
        window.menuOpens++; document.getElementById('serviceShowHide').style.display='block';
      };
    },lazy);
    await reset(); await addServiceMenu();
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'submitted');
    assert.equal(await page.locator('#net_access_type').inputValue(),'unicom-internal');
    assert.equal(await page.evaluate(()=>domainSelected),'school.example');
    assert.equal(await page.evaluate(()=>serviceClicks),1);
    assert.equal(await page.evaluate(()=>clicks),1);
    await reset(); await addServiceMenu(true);
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    assert.equal(await page.evaluate(()=>menuOpens),1);
    await page.evaluate(()=>populateServices());
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务',submit:false})), 'filled');
    assert.equal(await page.evaluate(()=>clicks),0);
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'submitted');
    assert.equal(await page.evaluate(()=>serviceClicks),1);
    await reset(); await addServiceMenu();
    await page.locator('#bch_service_0').evaluate(e=>e.onclick=()=>{});
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset(); await addServiceMenu();
    await page.locator('#bch_service_0').evaluate(e=>{
      const handler=e.onclick;
      e.onclick=()=>{handler();document.body.insertAdjacentHTML('beforeend','<input id="operatorPwd">');};
    });
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'manual-required');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset();
    assert.equal(await page.evaluate(script({serviceOption:'联通接入服务'})), 'missing-service');
    assert.equal(await page.evaluate(()=>clicks),0);
    await reset();
    assert.equal(await page.evaluate(script({serviceOption:''})), 'submitted');
    // ePortal implementations may keep their own request logic inside doauthen
    // without exposing AuthInterFace.login. The real handler must still run.
    await reset();
    await page.evaluate(() => {
      window.handlerCalls=0;
      window.doauthen=()=>{
        handlerCalls++;
        window.received=[document.getElementById('username').value,document.getElementById('pwd').value];
      };
      document.getElementById('loginLink').setAttribute('onclick','doauthen()');
    });
    assert.equal(await page.evaluate(script({confirmSubmit:true})), 'submitted');
    assert.equal(await page.evaluate(()=>handlerCalls),1);
    assert.deepEqual(await page.evaluate(()=>received),[cfg.username,cfg.password]);
    assert.equal(await page.evaluate(script({confirmSubmit:true})), 'already-submitted');
    assert.equal(await page.evaluate(script({confirmSubmit:true,statusOnly:true,password:''})), 'awaiting-authentication');
    assert.equal(await page.evaluate(()=>handlerCalls),1);
    // Keyup-driven credential models must be ready before the original click.
    await reset();
    await page.evaluate(() => {
      window.typed=[];window.received=null;
      for(const id of ['username','pwd']) document.getElementById(id).onkeyup=event=>{
        if(event.key==='Enter') throw new Error('Filling must not press Enter');
        typed.push(id);
      };
      document.getElementById('loginLink').onclick=()=>{
        if(typed.includes('username')&&typed.includes('pwd')){
          clicks++;received=[document.getElementById('username').value,document.getElementById('pwd').value];
        }
      };
    });
    assert.equal(await page.evaluate(script({confirmSubmit:true,submit:false})), 'filled');
    assert.deepEqual(await page.evaluate(()=>typed),['username','pwd']);
    assert.equal(await page.evaluate(()=>clicks),0);
    assert.equal(await page.evaluate(script({confirmSubmit:true})), 'submitted');
    assert.deepEqual(await page.evaluate(()=>received),[cfg.username,cfg.password]);
    assert.deepEqual(await page.evaluate(()=>typed),['username','pwd']);
    assert.equal(await page.evaluate(()=>clicks),1);
    // Confirmed submission is not authentication; preserve school callbacks.
    const setupAuth = async () => {
      await reset();
      await page.evaluate(() => {
        window.handlerCalls=0; window.loginCalls=0; window.callbackCalls=0;
        window.AuthInterFace={login(...args){loginCalls++;window.reply=args.at(-1)}};
        window.doauthen=function(){handlerCalls++;AuthInterFace.login('dummy',function(result){callbackCalls++;window.originalResult=result.result;return 42})};
        document.querySelector('#loginLink').setAttribute('onclick','doauthen()');
      });
    };
    const confirmed = extra => script({confirmSubmit:true,...extra});
    await setupAuth();
    assert.equal(await page.evaluate(confirmed()),'waiting-submit');
    assert.equal(await page.evaluate(confirmed()),'submitted');
    assert.equal(await page.evaluate(confirmed({statusOnly:true,password:''})),'awaiting-authentication');
    assert.equal(await page.evaluate(()=>reply({result:'success'})),42);
    assert.equal(await page.evaluate(confirmed({statusOnly:true,password:''})),'authenticated');
    assert.equal(await page.evaluate(()=>callbackCalls),1);
    assert.equal(await page.evaluate(()=>loginCalls),1);
    await setupAuth(); await page.evaluate(confirmed()); await page.evaluate(confirmed());
    await page.evaluate(()=>reply({result:'fail'}));
    assert.equal(await page.evaluate(confirmed()),'authentication-rejected');
    assert.equal(await page.evaluate(()=>originalResult),'fail');
    assert.equal(await page.evaluate(()=>loginCalls),1);
    await setupAuth();
    await page.evaluate(()=>{const button=document.querySelector('#loginLink');button.click=()=>{};button.dispatchEvent=()=>true;});
    assert.equal(await page.evaluate(confirmed()),'waiting-submit');
    assert.equal(await page.evaluate(confirmed()),'waiting-submit');
    assert.equal(await page.evaluate(confirmed()),'waiting-submit');
    assert.equal(await page.evaluate(confirmed()),'submitted');
    assert.equal(await page.evaluate(()=>handlerCalls),1);
    assert.equal(await page.evaluate(()=>loginCalls),1);
    assert.equal(await page.evaluate(confirmed()),'already-submitted');
    await reset();
    assert.equal(await page.evaluate(confirmed({statusOnly:true})),'not-submitted');
    assert.equal(await page.locator('#pwd').inputValue(),'');
    await page.goto('http://portal.test/eportal/success.jsp');
    assert.equal(await page.evaluate(confirmed({statusOnly:true})),'not-submitted');
    await page.goto('http://portal.test/eportal/success.jsp?userIndex=fixture');
    assert.equal(await page.evaluate(confirmed({statusOnly:true})),'authenticated');
    assert.equal(await page.evaluate(confirmed({statusOnly:true,origin:'http://other.test'})),'wrong-origin');
    console.log('PASS: FONT operator labels with whitespace/comments, Windows top-of-page native/hidden/accessible radios, arbitrary operator names, school change handlers, delayed selection, native/custom menus, open-before-load, selection before submission, other-form isolation, missing/disabled/ambiguous/rejected options, credential fields, origin and submission deduplication.');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
