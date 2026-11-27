// Loads the served app.js against a DOM stub and dispatches stub events through the
// document-level capture listeners it registers. Prints one JSON object of results.
// Usage: node confirm_interlock_harness.js <path to app.js>
const fs = require("fs");
const vm = require("vm");

function el(tag, attrs, parent) {
  const node = {
    tagName: tag.toUpperCase(),
    attrs: attrs || {},
    parent: parent || null,
    getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
    hasAttribute(n) { return n in this.attrs; },
    querySelectorAll() { return []; },
    closest(sel) {
      const m = /^\[([a-z-]+)\]$/.exec(sel);
      for (let n = this; n; n = n.parent) if (m && n.hasAttribute(m[1])) return n;
      return null;
    },
  };
  return node;
}

function run(scenario) {
  const listeners = [];
  const asked = [];
  const document = {
    addEventListener(type, fn, capture) { listeners.push({ type, fn, capture: capture === true }); },
    querySelector() { return null; },
    getElementById() { return null; },
  };
  const window = { confirm(text) { asked.push(text); return scenario.answer; } };
  const ctx = vm.createContext({ window, document });
  vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), ctx);

  const ev = { target: scenario.target, defaultPrevented: false, stopped: false,
    preventDefault() { this.defaultPrevented = true; },
    stopImmediatePropagation() { this.stopped = true; } };
  let reached = false;
  for (const l of listeners.filter((l) => l.type === scenario.type && l.capture)) {
    if (ev.stopped) break;
    l.fn(ev);
  }
  // LiveView binds on window in the bubble phase: reached only if nothing stopped the event.
  reached = !ev.stopped;
  return { asked, prevented: ev.defaultPrevented, stopped: ev.stopped, reached };
}

const btn = () => el("button", { "phx-click": "kill", "data-confirm": "Kill it?" });
const out = {};
out.refuse_click = run({ type: "click", answer: false, target: btn() });
out.accept_click = run({ type: "click", answer: true, target: btn() });
const plain = el("button", { "phx-click": "go" });
out.plain_click = run({ type: "click", answer: false, target: plain });
const inner = el("span", {}, btn());
out.inner_click_refused = run({ type: "click", answer: false, target: inner });
out.link_refused = run({ type: "click", answer: false, target: el("a", { href: "/x", "data-confirm": "Leave?" }) });
const form = el("form", { "data-confirm": "Send it?" });
out.form_refuse = run({ type: "submit", answer: false, target: form });
out.form_accept = run({ type: "submit", answer: true, target: form });
out.form_button_click = run({ type: "click", answer: false, target: el("button", {}, form) });
out.plain_submit = run({ type: "submit", answer: false, target: el("form", {}) });
console.log(JSON.stringify(out));
