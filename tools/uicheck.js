// tools/uicheck.js - load every page script the way a browser does.
//
//     node tools/uicheck.js
//
// `node --check` on each file separately is not enough, and that is the whole
// reason this exists. Classic <script> tags share ONE global lexical scope, so
// two files each declaring `let inFlight` at top level is a SyntaxError that
// kills whichever loads second. Checked one at a time both files are perfect.
//
// That exact collision shipped: the console UI never ran in a browser for a
// whole day while every check said it was fine -- the HTML was served, the IDs
// were unique, each file parsed. What nobody checked was the four of them
// together, which is what a browser actually does.
//
// The DOM here is a stub built from the real index.html, so asking for an id
// that is not in the page returns null exactly as a browser would.
const fs = require('fs');
const html = fs.readFileSync('web/index.html', 'utf8');
const ids = new Set([...html.matchAll(/id="([^"]+)"/g)].map(m => m[1]));
const classes = new Set([...html.matchAll(/class="([^"]+)"/g)]
  .flatMap(m => m[1].split(/\s+/)));

const mkEl = (id) => {
  const el = {
    id, textContent: '', innerHTML: '', value: '', checked: false, disabled: false,
    style: {}, dataset: {}, files: [],
    classList: { add(){}, remove(){}, toggle(){}, contains(){ return false; } },
    addEventListener(){}, removeEventListener(){}, appendChild(){}, focus(){}, click(){},
    insertAdjacentHTML(){}, setAttribute(){}, getAttribute(){ return null; },
    remove(){}, scrollIntoView(){}, getBoundingClientRect(){
      return { left:0, top:0, width:256, height:240 }; },
    querySelector(){ return mkEl('sub'); },
    querySelectorAll(){ return []; },
    getContext(){ return { createImageData: () => ({ data: new Uint8ClampedArray(4) }),
                           putImageData(){}, fillRect(){}, clearRect(){},
                           beginPath(){}, moveTo(){}, lineTo(){}, stroke(){},
                           fillText(){}, save(){}, restore(){}, translate(){},
                           scale(){}, arc(){}, fill(){}, closePath(){} }; },
    get children(){ return [mkEl('c0'), mkEl('c1'), mkEl('c2'), mkEl('c3')]; },
    requestFullscreen(){},
  };
  return el;
};

const cache = new Map();
global.document = {
  getElementById: (id) => {
    if (!ids.has(id)) return null;            // exactly what a browser does
    if (!cache.has(id)) cache.set(id, mkEl(id));
    return cache.get(id);
  },
  querySelectorAll: (sel) => {
    const cls = sel.replace(/^[.#]/, '').split(/[ .:\[]/)[0];
    return classes.has(cls) || sel.includes('nav button') || sel.includes('section')
      ? [mkEl('q1'), mkEl('q2')] : [];
  },
  querySelector: () => mkEl('q'),
  createElement: (t) => mkEl('new-' + t),
  createElementNS: (ns, t) => mkEl('new-' + t),
  createTextNode: () => mkEl('text'),
  body: mkEl('body'),
  addEventListener(){},
  fullscreenElement: null,
  exitFullscreen(){},
};
global.window = { addEventListener(){}, AudioContext: function(){ return {
  createGain: () => ({ gain: {}, connect(){} }), createBuffer: () => ({
    getChannelData: () => new Float32Array(1), duration: 0 }),
  createBufferSource: () => ({ connect(){}, start(){} }),
  destination: {}, resume: async()=>{}, currentTime: 0 }; } };
global.navigator = { getGamepads: () => [] };
global.localStorage = { getItem: () => null, setItem(){}, removeItem(){} };
global.performance = { now: () => 0 };
global.requestAnimationFrame = () => 0;
global.setInterval = () => 0;
global.setTimeout = () => 0;
global.fetch = async () => ({ ok: true, json: async () => ({}),
                              arrayBuffer: async () => new ArrayBuffer(0),
                              statusText: '' });

let src = '';
for (const f of ['app.js', 'video.js', 'synth.js', 'console.js', 'shell.js']) {
  src += `\n//==== ${f} ====\n` + fs.readFileSync('web/' + f, 'utf8');
}
try {
  new Function(src)();
  console.log('every page script ran with no error');
} catch (e) {
  console.log('THREW:', e.message);
  const line = (e.stack || '').split('\n')[1] || '';
  console.log(line.trim());
}
