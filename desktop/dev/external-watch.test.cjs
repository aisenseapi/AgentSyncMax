const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../src/external-watch.js'), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));
const status = overrides => ({enabled:true, state:'active', note:'Confirmed check-in', lastConfirmed:100, expiresAt:5000, ...overrides});
function fixture(handler) {
  class Element {
    constructor(tag) { this.tagName=tag.toUpperCase(); this.children=[]; this.parent=null; this.events={}; this.attributes={}; this.textContent=''; this.disabled=false; }
    get isConnected() { return this === body || !!this.parent?.isConnected; }
    append(...children) { children.forEach(c=>{c.parent=this;this.children.push(c);}); }
    replaceChildren(...children) { this.children.forEach(c=>{c.parent=null;});this.children=[];this.textContent='';this.append(...children); }
    setAttribute(k,v) { this.attributes[k]=v; }
    addEventListener(k,v) { this.events[k]=v; }
    querySelectorAll(tag) { return this.children.flatMap(c=>[...(c.tagName===tag.toUpperCase()?[c]:[]),...c.querySelectorAll(tag)]); }
    contains(node) { return this===node || this.children.some(c=>c.contains(node)); }
  }
  const body = new Element('body'); const timers = new Map(); let serial=0;
  const calls=[];
  const document={createElement:tag=>new Element(tag),hidden:false,activeElement:null,getElementById:()=>({hidden:false})};
  const window={confirm:()=>true,__TAURI__:{core:{invoke:async(command,args)=>{calls.push([command,args]);return handler(command,args);}}}};
  vm.runInNewContext(code,{window,document,Date,setInterval:fn=>{timers.set(++serial,fn);return serial;},clearInterval:id=>timers.delete(id)});
  return {body,calls,timers,document,mount:()=>window.AgentSyncExternalWatch.mount(body),text:()=>{const walk=n=>n.textContent+' '+n.children.map(walk).join(' ');return walk(body);}};
}

test('opening reads local status only; off is persisted in the backend before the label changes', async()=>{
  let resolve;
  const f=fixture((command)=> command==='get_external_watch'?status():new Promise(r=>resolve=r));
  assert.equal(f.calls.length,0); f.mount(); await settle();
  const toggle=f.body.querySelectorAll('button')[0]; toggle.events.click(); await settle();
  assert.equal(toggle.disabled,true); assert.equal(toggle.attributes['aria-checked'],'true');
  assert.equal(f.calls[1][0],'set_external_watch'); assert.equal(f.calls[1][1].enabled,false);
  resolve(status({enabled:false,state:'disabled'})); await settle();
  assert.equal(f.body.querySelectorAll('button')[0].attributes['aria-checked'],'false');
});
test('a missing backend never claims active protection',async()=>{
  const f=fixture(()=>Promise.reject(new Error('unavailable')));f.mount();await settle();
  assert.match(f.text(),/Status er ikke bekreftet/);assert.equal(f.body.querySelectorAll('button').length,0);
});
test('late reads cannot overwrite a remounted panel and only one poller survives',async()=>{
  let resolve; let n=0;
  const f=fixture(()=>++n===1?new Promise(r=>resolve=r):status({enabled:false,state:'disabled'}));
  f.mount(); f.body.replaceChildren(); f.mount(); await settle();
  resolve(status()); await settle(); assert.equal(f.body.querySelectorAll('button')[0].attributes['aria-checked'],'false');
  assert.equal(f.timers.size,1);
});
test('only canonical service links are shown and editing focus is preserved',async()=>{
  const f=fixture(()=>status({readUrl:'https://evil.example/secret',statusUrl:'https://aisenseapi.com/services/v1/heartbeat/'+'a'.repeat(64)}));
  f.mount();await settle();const inputs=f.body.querySelectorAll('input');assert.equal(inputs.length,1);
  f.document.activeElement=inputs[0];const before=f.calls.length;for(const timer of f.timers.values())timer();await settle();
  assert.equal(f.calls.length,before);
});
test('a terminal monitor has an explicit new-window action, never automatic provisioning from the UI',async()=>{
  const f=fixture(()=>status({state:'attention'}));f.mount();await settle();
  assert.match(f.text(),/Opprett nytt 24-timersvindu/);assert.deepEqual(f.calls.map(c=>c[0]),['get_external_watch']);
});
