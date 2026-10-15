(() => {
  if (globalThis.__jevAssistContextInstalled) return;
  globalThis.__jevAssistContextInstalled = true;

  const EXCLUDED = "script,style,noscript,template,input,textarea,select,option,[contenteditable]:not([contenteditable='false']),[data-private],[data-sensitive],[autocomplete='one-time-code']";
  const CONTROL_SELECTOR = "a[href],button,input:not([type='hidden']),textarea,select,summary,[role='button'],[role='link'],[role='menuitem'],[role='tab'],[role='checkbox'],[role='combobox'],[tabindex]";
  const SECRET_PARAM = /^(?:access[_-]?token|refresh[_-]?token|id[_-]?token|token|auth|authorization|api[_-]?key|key|secret|password|passwd|code|credential|signature|sig|x-amz-.+|session[_-]?id)$/i;
  let lastRequested = 0;
  let noticeTimer = null;

  function clean(value, max = 240) {
    return String(value || "")
      .replace(/\b(?:sk-(?:proj-)?|ts_live_|ts_test_)[A-Za-z0-9_-]{16,}\b/g, "[redacted]")
      .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, "Bearer [redacted]")
      .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[redacted]")
      .replace(/\s+/g, " ").trim().slice(0, max);
  }

  function safeURL(value) {
    try {
      const url = new URL(value, location.href);
      if (!/^https?:$/.test(url.protocol)) return undefined;
      url.username = "";
      url.password = "";
      for (const key of [...url.searchParams.keys()]) {
        if (SECRET_PARAM.test(key)) url.searchParams.set(key, "[redacted]");
      }
      if (url.hash.includes("=")) {
        const fragments = new URLSearchParams(url.hash.slice(1));
        let redacted = false;
        for (const key of [...fragments.keys()]) {
          if (SECRET_PARAM.test(key)) { fragments.set(key, "[redacted]"); redacted = true; }
        }
        if (redacted) url.hash = fragments.toString();
      }
      return clean(url.href, 4096);
    } catch { return undefined; }
  }

  function visible(element) {
    if (element.closest("[hidden],[aria-hidden='true']")) return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && style.visibility !== "collapse" && style.opacity !== "0" && element.getClientRects().length > 0;
  }

  function textFrom(root, max) {
    if (!root || root.closest?.(EXCLUDED)) return "";
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const parts = [];
    let length = 0;
    let visited = 0;
    while (walker.nextNode() && visited++ < 12000 && length < max) {
      const node = walker.currentNode;
      const element = node.parentElement;
      if (!element || element.closest(EXCLUDED) || !visible(element)) continue;
      const part = clean(node.textContent, Math.min(1000, max - length));
      if (part) { parts.push(part); length += part.length + 1; }
    }
    return parts.join(" ").slice(0, max);
  }

  function labelFor(element) {
    if (element.type === "password") return "Password field";
    // Labels describe controls; the control's value is never read.
    const explicit = element.getAttribute("aria-label");
    if (explicit) return clean(explicit);
    const labelledBy = element.getAttribute("aria-labelledby");
    if (labelledBy) {
      const text = labelledBy.split(/\s+/).slice(0, 6).map(id => textFrom(document.getElementById(id), 240)).join(" ");
      if (text.trim()) return clean(text);
    }
    if (element.labels?.length) return clean([...element.labels].map(label => textFrom(label, 240)).join(" "));
    return clean(textFrom(element, 240) || element.getAttribute("title") || element.getAttribute("placeholder") || element.getAttribute("alt") || element.tagName.toLowerCase());
  }

  function snapshot() {
    lastRequested = Date.now();
    const allControls = [...document.querySelectorAll(CONTROL_SELECTOR)].slice(0, 2500);
    const controls = allControls.map((element, index) => {
      if (element.closest("[data-private],[data-sensitive]")) return null;
      const rect = element.getBoundingClientRect();
      const isVisible = visible(element);
      const tag = element.tagName.toLowerCase();
      return {
        id: `control-${index}`, tag,
        role: clean(element.getAttribute("role") || ({a: "link", button: "button", input: "textbox", select: "combobox", textarea: "textbox", summary: "button"}[tag] || "control"), 40),
        label: labelFor(element),
        ...(tag === "a" && safeURL(element.href) ? {href: safeURL(element.href)} : {}),
        rect: {x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height)},
        visible: isVisible,
        inViewport: isVisible && rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth,
        disabled: Boolean(element.disabled || element.getAttribute("aria-disabled") === "true")
      };
    }).filter(Boolean);
    controls.sort((a, b) => Number(b.inViewport) - Number(a.inViewport) || Number(b.visible) - Number(a.visible));
    const loadedText = textFrom(document.body, 24000);
    return {
      capturedAt: new Date().toISOString(),
      page: {
        url: safeURL(location.href), title: clean(document.title, 500),
        scope: "loaded-top-frame", untrusted: true,
        loadedText, textTruncated: loadedText.length >= 24000,
        controls: controls.slice(0, 180), controlsTruncated: controls.length > 180 || allControls.length >= 2500,
        limitations: "Only loaded top-frame DOM; excludes field values, editable content, closed shadow roots, cross-origin frames, browser UI, and unloaded or virtualized content. Rectangles use viewport CSS pixels, not screen coordinates."
      },
      viewport: {width: innerWidth, height: innerHeight, scrollX, scrollY, devicePixelRatio}
    };
  }

  function changed(reason) {
    // Dormant scripts left on existing tabs after Stop never extract content.
    if (Date.now() - lastRequested > 2500 || document.visibilityState !== "visible" || noticeTimer) return;
    noticeTimer = setTimeout(() => {
      noticeTimer = null;
      chrome.runtime.sendMessage({type: "JEV_PAGE_CHANGED", reason}).catch(() => {});
    }, 160);
  }

  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id === chrome.runtime.id && message?.type === "JEV_SNAPSHOT") {
      respond(snapshot());
    }
    return false;
  });
  new MutationObserver(() => changed("mutation")).observe(document.documentElement, {subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["class", "style", "hidden", "aria-expanded", "aria-selected", "aria-disabled"]});
  addEventListener("scroll", () => changed("scroll"), {passive: true, capture: true});
  addEventListener("resize", () => changed("resize"), {passive: true});
  addEventListener("popstate", () => changed("navigation"));
})();
