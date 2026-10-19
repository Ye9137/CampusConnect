const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CAMPUS_CHROME_PATH?{executablePath:process.env.CAMPUS_CHROME_PATH}:{})});
 try{
  const page=await browser.newPage({viewport:{width:1280,height:860}});
  await page.addInitScript(()=>{window.commands=[];window.chrome={webview:{postMessage:message=>commands.push(message),addEventListener:()=>{}}}});
  await page.goto(pathToFileURL(path.resolve(__dirname,'../source/Desktop.html')).href);
  const result=await page.evaluate(async()=>{
   const assert=(condition,message)=>{if(!condition)throw Error(message)};
   const state={target:'Campus',currentSsid:'Campus',campusConnected:true,automatic:true,busy:false,lastScan:'10:00',status:'就绪',portalStatus:'等待认证',networks:[{ssid:'Campus',secure:false,signal:80},{ssid:'Other',secure:false,signal:40}]};
   const update=extra=>campus.receive({kind:'state',state:{...state,...extra}});
   update({});
   window.pollState=state;
   const buttons=[...document.querySelectorAll('button')],rows=[...document.querySelectorAll('.network-row')];
   const focused=rows[0].querySelector('button');focused.focus();
   let disabledMutations=0,removedButtons=0;
   const observer=new MutationObserver(records=>{
    for(const r of records){
     if(r.type==='attributes'&&r.attributeName==='disabled'&&(r.target.tagName==='BUTTON'||r.target.classList.contains('toggle')))disabledMutations++;
     for(const node of r.removedNodes){if(node.nodeType===1&&(node.tagName==='BUTTON'||node.querySelector('button')))removedButtons++;}
    }
   });
   observer.observe(document.body,{subtree:true,attributes:true,attributeFilter:['disabled'],childList:true});
   // Native background polls and automatic reconnects publish busy=false.
   // Change signal, target, and connected badges across 60 polling snapshots.
   for(let i=0;i<60;i++)update({target:i%2?'Campus':'Other',currentSsid:i%2?'Campus':'Other',lastScan:'10:'+String(i).padStart(2,'0'),networks:state.networks.map(n=>({...n,signal:(n.signal+i)%100,secure:i%2===0}))});
   await new Promise(resolve=>setTimeout(resolve,0));observer.disconnect();
   assert(disabledMutations===0,'polling rewrote button disabled attributes');
   assert(removedButtons===0,'polling removed button nodes');
   assert(buttons.every(button=>button.isConnected),'polling replaced buttons');
   assert(rows.every(row=>row.isConnected),'signal changes replaced network rows');
   assert(document.activeElement===focused,'polling discarded keyboard focus');
   // Reordering preserves the button and its focus as well.
   update({networks:[...state.networks].reverse()});
   assert(document.activeElement===focused,'reordering discarded focus');
   assert(document.querySelector('.network-row:last-child button')===focused,'reordering replaced the button');
   for(const name of ['settings','portal','dashboard']){
    document.querySelector('[data-page='+name+']').click();
    const control=document.querySelector(name==='settings'?'#save':name==='portal'?'[data-action=openPortal]':'[data-action=connect]');
    for(let i=0;i<10;i++)update({lastScan:'11:'+i});
    assert(!control.disabled,'polling blocked '+name+' controls');
   }
   update({busy:true});
   assert(document.getElementById('save').disabled,'explicit operation lost lock');
   assert(document.querySelector('[data-action=openPortal]').disabled,'explicit operation lost portal lock');
   update({busy:false});
   assert(!document.getElementById('save').disabled,'explicit operation did not unlock');
   return {disabledMutations,removedButtons,stableButtons:buttons.length};
  });
  // Hold a real pointer press while another signal update arrives.
  const button=page.locator('.network-row').first().locator('button');
  await button.hover();const box=await button.boundingBox();
  await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();
  await page.evaluate(()=>campus.receive({kind:'state',state:{...pollState,networks:pollState.networks.map(n=>({...n,signal:n.signal+1}))}}));
  assert.equal(await button.evaluate(e=>e.matches(':active')),true,'polling lost pressed state');
  assert.equal(await button.evaluate(e=>e.matches(':hover')),true,'polling lost hover');
  await page.mouse.up();
  await page.waitForFunction(()=>document.querySelector('[data-page=settings]').classList.contains('active'));
  assert.equal(await page.locator('#ssid').inputValue(),'Campus','click during refresh was lost');
  console.log('PASS: polling keeps all buttons stable, no disabled mutations/removals, keyboard focus and pressed/hover/click preserved, explicit locks retained.');
  console.log(JSON.stringify(result));
 }finally{await browser.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
