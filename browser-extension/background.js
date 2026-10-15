const HOST = "ai.typesafe.jevassist";
const SCRIPT_ID = "jev-assist-context";
const MAX_BYTES = 240 * 1024;
let sharing = false;
let port = null;
let timer = null;
let debounce = null;
let capturing = false;
let revision = 0;
let sequence = 0;
let sessionID = "";
let lastError = "";
let activeTabID = null;
let lastCapture = 0;

async function badge() {
  await chrome.action.setBadgeText({text: sharing ? "ON" : ""});
  await chrome.action.setBadgeBackgroundColor({color: "#285d52"});
}

function post(message) {
  if (!port) return false;
  const size = new TextEncoder().encode(JSON.stringify(message)).length;
  if (size > MAX_BYTES) throw new Error("Page context exceeds the local bridge limit.");
  port.postMessage(message);
  return true;
}

function clearContext(reason) {
  revision++;
  activeTabID = null;
  if (port) post({type: "clear", reason, sessionID});
}

async function stop(reason = "sharing-stopped", error = "") {
  sharing = false;
  revision++;
  clearInterval(timer);
  clearTimeout(debounce);
  timer = null;
  debounce = null;
  lastError = error;
  const previousPort = port;
  port = null;
  if (previousPort) {
    try { previousPort.postMessage({type: "stop", sessionID, reason}); } catch {}
    // Disconnect also makes the host remove its context file, even if stop was lost.
    previousPort.disconnect();
  }
  await chrome.scripting.unregisterContentScripts({ids: [SCRIPT_ID]}).catch(() => {});
  await badge();
}

async function start() {
  if (sharing) return;
  lastError = "";
  sessionID = crypto.randomUUID();
  sequence = 0;
  revision++;
  const connection = chrome.runtime.connectNative(HOST);
  port = connection;
  connection.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    if (port === connection) {
      port = null;
      void stop("bridge-disconnected", error ? "Mac bridge unavailable. Build the app and install its browser bridge first." : "Mac bridge disconnected. Start sharing again to reconnect.");
    }
  });
  connection.onMessage.addListener(message => {
    if (message?.ok === false) {
      lastError = "The local bridge rejected page context. Check that the app and extension versions match.";
    }
  });
  sharing = true;
  await chrome.scripting.unregisterContentScripts({ids: [SCRIPT_ID]}).catch(() => {});
  await chrome.scripting.registerContentScripts([{
    id: SCRIPT_ID,
    matches: ["http://*/*", "https://*/*"],
    js: ["content.js"],
    runAt: "document_idle",
    persistAcrossSessions: false,
    allFrames: false
  }]);
  if (!sharing || port !== connection) return;
  await badge();
  // A connected native messaging port keeps this service worker alive. Sharing
  // intentionally does not survive browser/extension restarts or bridge failures.
  timer = setInterval(() => void capture("freshness"), 1000);
  await capture("sharing-started");
}

async function capture(reason) {
  if (!sharing || !port || capturing) return;
  capturing = true;
  const token = revision;
  try {
    const window = await chrome.windows.getLastFocused();
    if (!window.focused || window.type !== "normal") {
      clearContext("browser-not-focused");
      return;
    }
    const [tab] = await chrome.tabs.query({active: true, windowId: window.id});
    if (!tab?.id || tab.incognito || !/^https?:\/\//.test(tab.url || "")) {
      clearContext("page-unavailable");
      return;
    }
    activeTabID = tab.id;
    let context;
    try {
      context = await chrome.tabs.sendMessage(tab.id, {type: "JEV_SNAPSHOT"}, {frameId: 0});
    } catch {
      // Registration affects future loads. Inject once into an already open tab.
      await chrome.scripting.executeScript({target: {tabId: tab.id, frameIds: [0]}, files: ["content.js"]});
      context = await chrome.tabs.sendMessage(tab.id, {type: "JEV_SNAPSHOT"}, {frameId: 0});
    }
    if (!sharing || !port || token !== revision) return;
    const current = await chrome.tabs.get(tab.id);
    const currentWindow = await chrome.windows.get(window.id);
    if (!current.active || !currentWindow.focused || current.url !== tab.url) {
      clearContext("page-changed-during-capture");
      return;
    }
    if (!context?.page || !context.viewport) throw new Error("Page context is unavailable.");
    const message = {
      type: "context", schemaVersion: 1, sharing: true,
      capturedAt: context.capturedAt, browser: "chrome", browserBundleID: "com.google.Chrome",
      sessionID, sequence: ++sequence, tabID: tab.id, windowID: window.id,
      page: context.page, viewport: context.viewport, reason
    };
    // Preserve a bounded useful subset if a page contains huge link URLs.
    while (new TextEncoder().encode(JSON.stringify(message)).length > MAX_BYTES && message.page.controls.length) {
      message.page.controls.pop();
      message.page.controlsTruncated = true;
    }
    post(message);
    lastCapture = Date.now();
    lastError = "";
  } catch {
    if (sharing && token === revision) {
      clearContext("page-capture-failed");
      lastError = "This page cannot share context. Jev Assist can still use its screenshot.";
    }
  } finally {
    capturing = false;
  }
}

function schedule(reason, invalidates = false) {
  if (!sharing) return;
  if (invalidates) clearContext(reason);
  clearTimeout(debounce);
  // Do not let continuous DOM changes starve updates forever.
  const delay = Math.max(0, Math.min(180, 500 - (Date.now() - lastCapture)));
  debounce = setTimeout(() => void capture(reason), delay);
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id) return false;
  if (message?.type === "JEV_PAGE_CHANGED") {
    if (sender.frameId === 0 && sender.tab?.id === activeTabID) schedule(message.reason === "scroll" ? "scroll" : "dom-change");
    return false;
  }
  // Only extension pages may start/stop sharing. Never accept control messages
  // originating from a content script, even though that script is ours.
  if (sender.tab || !sender.url?.startsWith(chrome.runtime.getURL(""))) return false;
  if (message?.type === "STATUS") {
    respond({sharing, error: lastError});
    return false;
  }
  if (message?.type === "START" || message?.type === "STOP") {
    (async () => {
      try {
        if (message.type === "START") await start(); else await stop();
        respond({sharing, error: lastError});
      } catch {
        await stop("start-failed", "Could not start browser sharing. Check site access and the Mac bridge installation.");
        respond({sharing: false, error: lastError});
      }
    })();
    return true;
  }
  return false;
});

chrome.tabs.onActivated.addListener(() => schedule("active-tab-changed", true));
chrome.tabs.onUpdated.addListener((tabID, change) => {
  if (tabID === activeTabID && (change.status || change.url)) schedule("navigation", true);
});
chrome.tabs.onRemoved.addListener(tabID => {
  if (tabID === activeTabID) schedule("tab-closed", true);
});
chrome.windows.onFocusChanged.addListener(() => schedule("window-focus-changed", true));
chrome.permissions.onRemoved.addListener(() => void stop("permission-removed"));
void badge();
