import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {webcrypto} from "node:crypto";
import vm from "node:vm";
import test from "node:test";

const source = readFileSync(new URL("../browser-extension/background.js", import.meta.url), "utf8");

function event() {
  const listeners = [];
  return {addListener: listener => listeners.push(listener), fire: (...args) => listeners.forEach(listener => listener(...args))};
}

function snapshot() {
  return {
    capturedAt: new Date().toISOString(),
    page: {url: "https://example.test", title: "Mail", loadedText: "Hello", controls: [], scope: "loaded-top-frame", untrusted: true},
    viewport: {width: 1000, height: 800, scrollX: 0, scrollY: 0, devicePixelRatio: 2}
  };
}

function harness() {
  const messages = [];
  let snapshotProvider = async () => snapshot();
  let captureCount = 0;
  let focused = true;
  const timers = new Map();
  let timerID = 0;
  const native = {
    onDisconnect: event(), onMessage: event(),
    postMessage: message => messages.push(structuredClone(message)),
    disconnect: () => native.onDisconnect.fire()
  };
  const tab = {id: 7, windowId: 3, active: true, url: "https://example.test", incognito: false};
  const chrome = {
    action: {setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {}},
    runtime: {
      id: "a".repeat(32), connectNative: () => native, onMessage: event(),
      getURL: path => `chrome-extension://${"a".repeat(32)}/${path}`
    },
    scripting: {registerContentScripts: async () => {}, unregisterContentScripts: async () => {}, executeScript: async () => {}},
    windows: {getLastFocused: async () => ({id: 3, type: "normal", focused}), get: async () => ({focused}), onFocusChanged: event()},
    tabs: {
      query: async () => [tab], get: async () => tab,
      sendMessage: async () => { captureCount++; return snapshotProvider(); },
      onActivated: event(), onUpdated: event(), onRemoved: event()
    },
    permissions: {onRemoved: event()}
  };
  const context = vm.createContext({
    chrome, crypto: webcrypto, TextEncoder,
    setInterval: fn => { timers.set(++timerID, fn); return timerID; },
    setTimeout: fn => { timers.set(++timerID, fn); return timerID; },
    clearInterval: id => timers.delete(id), clearTimeout: id => timers.delete(id)
  });
  vm.runInContext(source + "\nglobalThis.hooks = {start, stop, capture};", context);
  return {
    ...context.hooks, messages, chrome, timers,
    setSnapshot: provider => { snapshotProvider = provider; },
    setFocused: value => { focused = value; },
    captureCount: () => captureCount
  };
}

test("sharing is explicit and stop disconnects, clears, and cancels timers", async () => {
  const h = harness();
  assert.equal(h.messages.length, 0);
  await h.start();
  assert.equal(h.messages.filter(m => m.type === "context").length, 1);
  await h.stop();
  assert.equal(h.messages.at(-1).type, "stop");
  assert.equal(h.timers.size, 0);
  await h.capture("after-stop");
  assert.equal(h.messages.filter(m => m.type === "context").length, 1);
});

test("tab change invalidates an in-flight snapshot instead of forwarding stale context", async () => {
  const h = harness();
  await h.start();
  let finish;
  h.setSnapshot(() => new Promise(resolve => { finish = resolve; }));
  const capture = h.capture("pending");
  await new Promise(resolve => setImmediate(resolve));
  h.chrome.tabs.onActivated.fire({tabId: 8});
  finish(snapshot());
  await capture;
  assert.equal(h.messages.filter(m => m.type === "context").length, 1);
  assert.equal(h.messages.at(-1).type, "clear");
  await h.stop();
});

test("only one extraction is in flight even when frequent triggers arrive", async () => {
  const h = harness();
  await h.start();
  let finish;
  h.setSnapshot(() => new Promise(resolve => { finish = resolve; }));
  const first = h.capture("first");
  await new Promise(resolve => setImmediate(resolve));
  await h.capture("second");
  await h.capture("third");
  assert.equal(h.captureCount(), 2);
  finish(snapshot());
  await first;
  await h.stop();
});

test("background Chrome windows clear context instead of reading tabs", async () => {
  const h = harness();
  await h.start();
  h.setFocused(false);
  await h.capture("not-frontmost");
  assert.equal(h.captureCount(), 1);
  assert.equal(h.messages.at(-1).type, "clear");
  await h.stop();
});

test("large link collections are bounded before native messaging", async () => {
  const h = harness();
  h.setSnapshot(async () => {
    const value = snapshot();
    value.page.controls = Array.from({length: 180}, (_, i) => ({id: String(i), href: "https://example.test/" + "a".repeat(4000)}));
    return value;
  });
  await h.start();
  const sent = h.messages.find(m => m.type === "context");
  assert.ok(sent);
  assert.ok(Buffer.byteLength(JSON.stringify(sent)) <= 240 * 1024);
  assert.equal(sent.page.controlsTruncated, true);
  await h.stop();
});
