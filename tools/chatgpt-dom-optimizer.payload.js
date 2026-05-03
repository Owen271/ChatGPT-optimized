(function installChatGptDomOptimizer(initialOptions) {
  const KEY = "__chatgptDomOptimizer";
  const VERSION = "0.2.0";
  const STYLE_ID = "__chatgpt-dom-optimizer-style";
  const CONTAINED_CLASS = "__cgpt_dom_optimizer_contained";
  const HIDDEN_CLASS = "__cgpt_dom_optimizer_hidden";
  const PLACEHOLDER_CLASS = "__cgpt_dom_optimizer_placeholder";

  const defaults = {
    recentLimit: 40,
    intrinsicSize: 520,
    mode: "auto",
    aggressive: false,
    aggressiveKeep: 120,
    debug: false,
  };

  if (window[KEY] && window[KEY].version === VERSION && typeof window[KEY].configure === "function") {
    window[KEY].configure(initialOptions || {});
    window[KEY].enable();
    return window[KEY].status();
  }
  if (window[KEY] && typeof window[KEY].disable === "function") {
    try {
      window[KEY].disable();
    } catch (error) {
      console.warn("[ChatGPT DOM optimizer] failed to disable previous version", error);
    }
  }

  const state = {
    options: Object.assign({}, defaults, initialOptions || {}),
    enabled: false,
    observer: null,
    touched: new Set(),
    placeholderized: new Map(),
    scheduled: 0,
    runs: 0,
    lastMessageCount: 0,
    lastAppliedCount: 0,
    lastError: null,
  };

  function log(...args) {
    if (state.options.debug) {
      console.debug("[ChatGPT DOM optimizer]", ...args);
    }
  }

  function ensureStyle() {
    let style = document.getElementById(STYLE_ID);
    if (style) return style;

    style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      .${CONTAINED_CLASS} {
        content-visibility: auto !important;
        contain: layout paint style !important;
        contain-intrinsic-size: auto var(--cgpt-dom-optimizer-intrinsic-size, 520px) !important;
      }

      .${HIDDEN_CLASS} {
        content-visibility: hidden !important;
        contain: layout paint style !important;
        contain-intrinsic-size: auto var(--cgpt-dom-optimizer-intrinsic-size, 520px) !important;
      }

      .${PLACEHOLDER_CLASS} {
        min-height: var(--cgpt-dom-optimizer-placeholder-height, 180px);
        padding: 16px;
        border: 1px dashed color-mix(in srgb, currentColor 22%, transparent);
        border-radius: 8px;
        opacity: 0.72;
        content-visibility: auto;
        contain: layout paint style;
      }
    `;
    document.documentElement.appendChild(style);
    return style;
  }

  function getRoot() {
    return (
      document.querySelector("main") ||
      document.querySelector('[role="main"]') ||
      document.body
    );
  }

  function isComposerOrChrome(node) {
    if (!(node instanceof Element)) return true;
    if (node.closest("form textarea, form [contenteditable='true'], textarea, [contenteditable='true']")) return true;
    if (node.closest("nav, aside, header, footer")) return true;
    return false;
  }

  function normalizeMessageNode(node) {
    if (!(node instanceof Element)) return null;
    const turn = node.closest('[class*="group/turn-messages"], [class*="agent-turn"]');
    if (turn && getRoot().contains(turn)) return turn;
    const article = node.closest("article");
    if (article && getRoot().contains(article)) return article;
    return node;
  }

  function findMessages() {
    const root = getRoot();
    const raw = Array.from(
      root.querySelectorAll("article, [data-message-author-role]")
    );
    const seen = new Set();
    const messages = [];

    for (const item of raw) {
      const node = normalizeMessageNode(item);
      if (!node || seen.has(node) || isComposerOrChrome(node)) continue;
      if (!root.contains(node)) continue;
      seen.add(node);
      messages.push(node);
    }

    return messages;
  }

  function setContained(node, contained) {
    if (!(node instanceof HTMLElement)) return;
    if (contained) {
      const hiddenMode = String(state.options.mode || "auto").toLowerCase() === "hidden";
      node.style.setProperty(
        "--cgpt-dom-optimizer-intrinsic-size",
        `${Number(state.options.intrinsicSize) || defaults.intrinsicSize}px`
      );
      node.classList.toggle(CONTAINED_CLASS, !hiddenMode);
      node.classList.toggle(HIDDEN_CLASS, hiddenMode);
      state.touched.add(node);
    } else {
      node.classList.remove(CONTAINED_CLASS);
      node.classList.remove(HIDDEN_CLASS);
      node.style.removeProperty("--cgpt-dom-optimizer-intrinsic-size");
    }
  }

  function maybePlaceholderize(messages) {
    if (!state.options.aggressive) return;

    const keep = Math.max(
      Number(state.options.aggressiveKeep) || defaults.aggressiveKeep,
      Number(state.options.recentLimit) || defaults.recentLimit
    );
    const cutoff = Math.max(0, messages.length - keep);

    for (let index = 0; index < cutoff; index += 1) {
      const node = messages[index];
      if (!(node instanceof HTMLElement)) continue;
      if (state.placeholderized.has(node)) continue;
      if (node.querySelector("textarea, [contenteditable='true']")) continue;

      const height = Math.max(120, Math.min(700, Math.round(node.getBoundingClientRect().height || 180)));
      state.placeholderized.set(node, {
        html: node.innerHTML,
        ariaLabel: node.getAttribute("aria-label"),
      });
      node.style.setProperty("--cgpt-dom-optimizer-placeholder-height", `${height}px`);
      node.classList.add(PLACEHOLDER_CLASS);
      node.setAttribute("data-cgpt-dom-optimizer-placeholder", "true");
      node.setAttribute("aria-label", "Older ChatGPT message compacted by local DOM optimizer. Reload the conversation to fully restore interactive controls.");
      node.innerHTML = `<div>Older message compacted by local DOM optimizer.</div>`;
    }
  }

  function restorePlaceholders() {
    for (const [node, original] of state.placeholderized.entries()) {
      if (!(node instanceof HTMLElement)) continue;
      node.innerHTML = original.html;
      node.classList.remove(PLACEHOLDER_CLASS);
      node.style.removeProperty("--cgpt-dom-optimizer-placeholder-height");
      node.removeAttribute("data-cgpt-dom-optimizer-placeholder");
      if (original.ariaLabel == null) {
        node.removeAttribute("aria-label");
      } else {
        node.setAttribute("aria-label", original.ariaLabel);
      }
    }
    state.placeholderized.clear();
  }

  function apply() {
    if (!state.enabled) return;
    state.scheduled = 0;
    state.runs += 1;

    try {
      ensureStyle();
      const messages = findMessages();
      const recentLimit = Math.max(1, Number(state.options.recentLimit) || defaults.recentLimit);
      const cutoff = Math.max(0, messages.length - recentLimit);
      const current = new Set(messages);
      let applied = 0;

      for (const node of Array.from(state.touched)) {
        if (!current.has(node)) {
          setContained(node, false);
          state.touched.delete(node);
        }
      }

      messages.forEach((node, index) => {
        const shouldContain = index < cutoff;
        setContained(node, shouldContain);
        if (shouldContain) applied += 1;
      });

      maybePlaceholderize(messages);

      state.lastMessageCount = messages.length;
      state.lastAppliedCount = applied;
      state.lastError = null;
      log("applied", { messages: messages.length, contained: applied });
    } catch (error) {
      state.lastError = error && error.message ? error.message : String(error);
      console.warn("[ChatGPT DOM optimizer] apply failed", error);
    }
  }

  function scheduleApply() {
    if (!state.enabled || state.scheduled) return;
    state.scheduled = window.setTimeout(apply, 120);
  }

  function enable(options) {
    if (options) configure(options);
    if (state.enabled) {
      scheduleApply();
      return status();
    }

    state.enabled = true;
    ensureStyle();
    state.observer = new MutationObserver(scheduleApply);
    state.observer.observe(document.body, {
      childList: true,
      subtree: true,
    });
    window.addEventListener("resize", scheduleApply, { passive: true });
    window.addEventListener("scroll", scheduleApply, { passive: true, capture: true });
    apply();
    console.info("ChatGPT DOM optimizer active", status());
    return status();
  }

  function disable() {
    state.enabled = false;
    if (state.scheduled) {
      window.clearTimeout(state.scheduled);
      state.scheduled = 0;
    }
    if (state.observer) {
      state.observer.disconnect();
      state.observer = null;
    }
    window.removeEventListener("resize", scheduleApply);
    window.removeEventListener("scroll", scheduleApply, true);
    restorePlaceholders();
    for (const node of Array.from(state.touched)) {
      setContained(node, false);
    }
    state.touched.clear();
    const style = document.getElementById(STYLE_ID);
    if (style) style.remove();
    console.info("ChatGPT DOM optimizer disabled");
    return status();
  }

  function configure(options) {
    Object.assign(state.options, options || {});
    if (!["auto", "hidden"].includes(String(state.options.mode || "auto").toLowerCase())) {
      state.options.mode = "auto";
    }
    if (state.enabled) scheduleApply();
    return status();
  }

  function setRecentLimit(limit) {
    state.options.recentLimit = Math.max(1, Number(limit) || defaults.recentLimit);
    if (state.enabled) apply();
    return status();
  }

  function status() {
    return {
      version: VERSION,
      enabled: state.enabled,
      options: Object.assign({}, state.options),
      messageCount: state.lastMessageCount,
      containedCount: state.lastAppliedCount,
      placeholderCount: state.placeholderized.size,
      runs: state.runs,
      lastError: state.lastError,
    };
  }

  window[KEY] = {
    version: VERSION,
    enable,
    disable,
    configure,
    setRecentLimit,
    status,
  };

  return enable();
})({ recentLimit: 40 });
