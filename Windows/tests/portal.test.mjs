import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const template = readFileSync(new URL('../source/PortalTemplate.js', import.meta.url), 'utf8');
const cfg = { origin: 'http://192.168.0.123', username: 'account\'"\\\n', password: 'secret\'"\\\n</script>',
  userSelector: '', passwordSelector: '', submitSelector: '', submit: true };
const context = vm.createContext({});
vm.runInContext(`
var clicks = 0, window = {}, location = {origin: 'http://192.168.0.123'};
class Event { constructor(type) { this.type = type; } }
class HTMLInputElement {
  constructor(name,type) { this.name=name; this.type=type; this.form=null; this.disabled=false; this._value=''; }
  get value() { return this._value; } set value(value) { this._value=value; }
  getClientRects() { return this.hidden ? [] : [1]; } dispatchEvent() {}
}
var user = new HTMLInputElement('username','text'), pass = new HTMLInputElement('password','password');
var submit = {type:'button', innerText:'连接 Login', disabled:false, getClientRects(){return [1]}, click(){clicks++}};
var document = {
  querySelectorAll(s) { if(s==='select'||s==='[id=\"submit\"]'||s.startsWith('[role='))return []; if(s==='input[type="password"]')return [pass]; if(s.startsWith('button'))return [submit]; return [user]; },
  querySelector(s) { if(s==='[')throw Error('selector'); if(s==='#user')return user; if(s==='#pass')return pass; if(s==='#submit')return submit; return null; }
};
`, context);
let checks = 0;
function equal(actual, expected) { assert.equal(actual, expected); checks++; }
function run(overrides = {}) { return vm.runInContext(template.replace('/*CAMPUS_CONFIG*/', JSON.stringify({...cfg, ...overrides})), context); }
function evaluate(code) { return vm.runInContext(code, context); }
equal(run(), 'submitted');
equal(evaluate('clicks'), 1);
equal(evaluate('user.value'), cfg.username);
equal(evaluate('pass.value'), cfg.password);
equal(run(), 'already-submitted');
equal(evaluate('clicks'), 1);
evaluate("window={};location.origin='http://192.168.0.123:8080';user.value='';pass.value=''");
equal(run(), 'wrong-origin');
equal(evaluate('pass.value'), '');
evaluate("location.origin='https://192.168.0.123'"); equal(run(), 'wrong-origin');
evaluate("location.origin='http://evil.example'"); equal(run(), 'wrong-origin');
evaluate("location.origin='http://192.168.0.123'");
equal(run({userSelector:'['}), 'invalid-selector');
equal(run({submit:false}), 'filled');
equal(evaluate('clicks'), 1);
evaluate('pass.hidden=true'); equal(run(), 'missing-fields');
evaluate('pass.hidden=false;user.disabled=true'); equal(run(), 'missing-fields');
evaluate('user.disabled=false;submit.disabled=true'); equal(run(), 'missing-submit');
evaluate('submit.disabled=false');
equal(run({userSelector:'#user',passwordSelector:'#pass',submitSelector:'#submit'}), 'submitted');
equal(evaluate('clicks'), 2);
console.log(`PASS: ${checks} browser-script checks (origin, escaping, visibility, selectors, submit deduplication).`);
