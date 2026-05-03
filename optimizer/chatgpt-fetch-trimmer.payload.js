(function installChatGptFetchTrimmer(initialOptions) {
  const KEY = "__chatgptFetchTrimmer";
  const VERSION = "0.3.1";
  const defaults = {
    keepMessages: 40,
    pageSize: 40,
    scrollThreshold: 96,
    minExpandIntervalMs: 700,
    debug: false,
  };

  if (window[KEY] && window[KEY].version === VERSION) {
    window[KEY].configure(initialOptions || {});
    return window[KEY].status();
  }
  if (window[KEY] && typeof window[KEY].disable === "function") {
    try {
      window[KEY].disable();
    } catch (error) {
      console.warn("[ChatGPT fetch trimmer] failed to disable previous version", error);
    }
  }

  const state = {
    options: Object.assign({}, defaults, initialOptions || {}),
    originalFetch: window.fetch.bind(window),
    enabled: true,
    trimCount: 0,
    last: null,
    userRequestedOlder: false,
    waitingForTopReset: false,
    lastArchiveExpandAt: 0,
    archive: null,
    archiveStats: null,
    renderedArchiveCount: 0,
  };

  function isConversationUrl(value) {
    try {
      const url = new URL(typeof value === "string" ? value : value.url, location.href);
      return (
        url.origin === location.origin &&
        /^\/backend-api\/conversation\/[0-9a-f-]{20,}$/i.test(url.pathname)
      );
    } catch {
      return false;
    }
  }

  function getConversationIdFromUrl(value) {
    try {
      const url = new URL(typeof value === "string" ? value : value.url, location.href);
      const match = url.pathname.match(/^\/backend-api\/conversation\/([0-9a-f-]{20,})$/i);
      return match ? match[1] : null;
    } catch {
      return null;
    }
  }

  function getStorageKey(conversationId) {
    return `__chatgptFetchTrimmer.keep.${conversationId}`;
  }

  function getStoredKeepMessages(conversationId) {
    if (!conversationId) return null;
    try {
      const value = Number(sessionStorage.getItem(getStorageKey(conversationId)));
      return Number.isFinite(value) && value > 0 ? value : null;
    } catch {
      return null;
    }
  }

  function setStoredKeepMessages(conversationId, value) {
    if (!conversationId) return;
    try {
      sessionStorage.setItem(getStorageKey(conversationId), String(value));
    } catch {
      // Ignore storage failures. The trimmer still works with the default window.
    }
  }

  function getEffectiveKeepMessages(conversationId, originalMessages) {
    const base = Math.max(10, Number(state.options.keepMessages) || defaults.keepMessages);
    return Math.min(originalMessages || base, base);
  }

  function extractMessageText(message) {
    const content = message && message.content;
    if (!content) return "";
    if (typeof content.text === "string") return cleanMessageText(content.text);
    if (Array.isArray(content.parts)) {
      const text = content.parts
        .map((part) => extractTextValue(part))
        .filter(Boolean)
        .join("\n\n");
      return cleanMessageText(text);
    }
    return cleanMessageText(extractTextValue(content));
  }

  function extractTextValue(value, depth) {
    const currentDepth = depth || 0;
    if (typeof value === "string") return value;
    if (!value || typeof value !== "object" || currentDepth > 3) return "";

    const textKeys = ["text", "content", "value", "markdown", "plain_text"];
    for (const key of textKeys) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        const extracted = extractTextValue(value[key], currentDepth + 1);
        if (extracted) return extracted;
      }
    }

    if (Array.isArray(value.parts)) {
      return value.parts
        .map((part) => extractTextValue(part, currentDepth + 1))
        .filter(Boolean)
        .join("\n\n");
    }

    return "";
  }

  function cleanMessageText(text) {
    return String(text || "")
      .replace(/\uE200entity\uE202(\[[^\uE201]+\])\uE201/g, (match, raw) => {
        try {
          const values = JSON.parse(raw);
          return values && (values[1] || values[0]) ? String(values[1] || values[0]) : "";
        } catch {
          return "";
        }
      })
      .replace(/\uE200[^\uE201]*\uE201/g, "")
      .replace(/[ \t]+\n/g, "\n")
      .trim();
  }

  function getMessageRole(message) {
    return (message && message.author && message.author.role) || "message";
  }

  function getMessageVisibilitySkipReason(message, text) {
    const role = getMessageRole(message);
    if (!["user", "assistant"].includes(role)) return `role:${role}`;
    const contentType = message && message.content && message.content.content_type;
    if (role === "assistant") {
      if (message.channel !== "final") return `channel:${message.channel || "none"}`;
      if (contentType && contentType !== "text") return `content:${contentType}`;
    } else if (message && message.channel && !["final", "all"].includes(message.channel)) {
      return `channel:${message.channel}`;
    }
    if (message && message.recipient && !["all", "assistant", "user"].includes(message.recipient)) return `recipient:${message.recipient}`;

    const metadata = (message && message.metadata) || {};
    if (
      metadata.is_visually_hidden_from_conversation ||
      metadata.hidden ||
      metadata.message_type === "system_context"
    ) {
      return `metadata:${metadata.message_type || "hidden"}`;
    }
    if (
      metadata.message_type === "next" &&
      !(role === "assistant" && message.channel === "final" && contentType === "text")
    ) {
      return "metadata:next";
    }

    if (role === "assistant" && /^\s*[{[]/.test(text)) {
      return "assistant-json";
    }

    return null;
  }

  function incrementCount(collection, key) {
    collection[key] = (collection[key] || 0) + 1;
  }

  function rememberArchive(conversationId, mapping, archivedMessageIds) {
    const previousArchive = state.archive;
    const sameConversation = previousArchive && previousArchive.conversationId === conversationId;
    const existingContainer = document.getElementById("__chatgpt-fetch-trimmer-archive");
    const existingRenderedCount = sameConversation && existingContainer
      ? existingContainer.querySelectorAll(".__chatgpt-fetch-trimmer-message").length
      : 0;

    if (!sameConversation) {
      removeArchiveContainer();
      state.waitingForTopReset = false;
      state.userRequestedOlder = false;
    }

    const stats = {
      sourceMessages: archivedMessageIds.length,
      acceptedByRole: {},
      skipped: {},
    };
    const archivedMessages = [];

    for (const nodeId of archivedMessageIds) {
      const message = mapping[nodeId] && mapping[nodeId].message;
      const text = extractMessageText(message).trim();
      if (!message) {
        incrementCount(stats.skipped, "missing-message");
        continue;
      }
      if (!text) {
        incrementCount(stats.skipped, `empty:${getMessageRole(message)}`);
        continue;
      }
      const skipReason = getMessageVisibilitySkipReason(message, text);
      if (skipReason) {
        incrementCount(stats.skipped, skipReason);
        continue;
      }
      const role = getMessageRole(message);
      incrementCount(stats.acceptedByRole, role);
      archivedMessages.push({
        id: message.id || nodeId,
        role,
        text,
      });
    }

    state.archive = {
      conversationId,
      messages: archivedMessages,
    };
    state.archiveStats = stats;
    state.renderedArchiveCount = Math.min(existingRenderedCount, state.archive.messages.length);
  }

  function trimConversation(data, conversationId) {
    const mapping = data && data.mapping;
    const currentNode = data && data.current_node;
    if (!mapping || !currentNode || !mapping[currentNode]) {
      return { data, changed: false, originalNodes: 0, keptNodes: 0, originalMessages: 0, keptMessages: 0 };
    }

    const originalNodes = Object.keys(mapping).length;
    const originalMessages = Object.values(mapping).filter((node) => node && node.message).length;
    const keepMessages = getEffectiveKeepMessages(conversationId || data.conversation_id, originalMessages);
    if (originalMessages <= keepMessages) {
      return { data, changed: false, originalNodes, keptNodes: originalNodes, originalMessages, keptMessages: originalMessages };
    }

    const chain = [];
    const seen = new Set();
    let id = currentNode;
    while (id && mapping[id] && !seen.has(id) && chain.length < 10000) {
      seen.add(id);
      chain.push(id);
      id = mapping[id].parent;
    }
    chain.reverse();

    const rootId = chain.find((nodeId) => mapping[nodeId] && !mapping[nodeId].message) || chain[0];
    const messageIds = chain.filter((nodeId) => mapping[nodeId] && mapping[nodeId].message);
    const keptMessageIds = messageIds.slice(-keepMessages);
    const archivedMessageIds = messageIds.slice(0, Math.max(0, messageIds.length - keptMessageIds.length));
    rememberArchive(conversationId || data.conversation_id, mapping, archivedMessageIds);
    const keepIds = new Set([rootId, ...keptMessageIds]);
    const newMapping = {};

    for (const nodeId of keepIds) {
      const node = mapping[nodeId];
      if (!node) continue;
      const copy = Object.assign({}, node);
      copy.children = Array.isArray(node.children)
        ? node.children.filter((child) => keepIds.has(child))
        : [];
      if (copy.parent && !keepIds.has(copy.parent)) {
        copy.parent = rootId;
      }
      newMapping[nodeId] = copy;
    }

    if (newMapping[rootId]) {
      newMapping[rootId].children = keptMessageIds.length ? [keptMessageIds[0]] : [];
      newMapping[rootId].parent = null;
    }

    data.mapping = newMapping;
    data.codex_trimmed_conversation = {
      original_nodes: originalNodes,
      kept_nodes: Object.keys(newMapping).length,
      original_messages: originalMessages,
      kept_messages: keptMessageIds.length,
      can_expand: keptMessageIds.length < originalMessages,
    };

    return {
      data,
      changed: true,
      originalNodes,
      keptNodes: Object.keys(newMapping).length,
      originalMessages,
      keptMessages: keptMessageIds.length,
    };
  }

  function makeTrimmedResponse(response, data, trim) {
    const headers = new Headers(response.headers);
    headers.set("content-type", "application/json");
    headers.set("x-codex-chatgpt-trimmed", trim.changed ? "true" : "false");
    return new Response(JSON.stringify(data), {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  }

  window.fetch = async function codexTrimmedFetch(input, init) {
    const response = await state.originalFetch(input, init);
    if (!state.enabled || !isConversationUrl(input)) {
      return response;
    }

    try {
      const conversationId = getConversationIdFromUrl(input);
      const data = await response.clone().json();
      const trim = trimConversation(data, conversationId);
      state.last = {
        url: typeof input === "string" ? new URL(input, location.href).href : input.url,
        conversationId,
        changed: trim.changed,
        originalNodes: trim.originalNodes,
        keptNodes: trim.keptNodes,
        originalMessages: trim.originalMessages,
        keptMessages: trim.keptMessages,
        canExpand: trim.keptMessages < trim.originalMessages,
        at: new Date().toISOString(),
      };
      if (trim.changed) state.trimCount += 1;
      if (state.options.debug) console.info("[ChatGPT fetch trimmer]", state.last);
      return makeTrimmedResponse(response, trim.data, trim);
    } catch (error) {
      console.warn("[ChatGPT fetch trimmer] failed, returning original response", error);
      return response;
    }
  };

  function configure(options) {
    Object.assign(state.options, options || {});
    return status();
  }

  function expandOlderMessages() {
    if (!state.enabled || !state.archive || !state.archive.messages.length) {
      return false;
    }

    const pageSize = Math.max(10, Number(state.options.pageSize) || defaults.pageSize);
    const remaining = state.archive.messages.length - state.renderedArchiveCount;
    if (remaining <= 0) {
      return false;
    }

    const count = Math.min(pageSize, remaining);
    const end = state.archive.messages.length - state.renderedArchiveCount;
    const start = Math.max(0, end - count);
    const messages = state.archive.messages.slice(start, end);
    const container = ensureArchiveContainer();
    if (!container) {
      return false;
    }

    const note = container.querySelector(".__chatgpt-fetch-trimmer-note");
    const insertionPoint = note ? note.nextSibling : container.firstChild;
    const anchor = insertionPoint || getFirstRenderedMessageAnchor();
    const scroller = getScrollContainer(anchor || container);
    const anchorTopBefore = anchor ? anchor.getBoundingClientRect().top : null;

    const fragment = document.createDocumentFragment();
    for (const message of messages) {
      fragment.appendChild(renderArchiveMessage(message));
    }
    container.insertBefore(fragment, insertionPoint);

    if (anchor && anchorTopBefore !== null) {
      const delta = anchor.getBoundingClientRect().top - anchorTopBefore;
      adjustScroll(scroller, delta);
    }

    state.renderedArchiveCount += messages.length;
    state.lastArchiveExpandAt = Date.now();
    console.info(`[ChatGPT fetch trimmer] rendered ${state.renderedArchiveCount}/${state.archive.messages.length} archived messages`);
    return true;
  }

  function resetProgress() {
    if (state.last && state.last.conversationId) {
      try {
        sessionStorage.removeItem(getStorageKey(state.last.conversationId));
      } catch {
        // Ignore storage failures.
      }
    }
    location.reload();
  }

  function ensureArchiveStyle() {
    if (document.getElementById("__chatgpt-fetch-trimmer-style")) return;
    const style = document.createElement("style");
    style.id = "__chatgpt-fetch-trimmer-style";
    style.textContent = `
      #__chatgpt-fetch-trimmer-archive {
        max-width: min(48rem, calc(100vw - 32px));
        margin: 24px auto;
        color: var(--text-primary, inherit);
      }
      .__chatgpt-fetch-trimmer-note {
        font-size: 12px;
        opacity: 0.7;
        margin: 8px 0 16px;
      }
      .__chatgpt-fetch-trimmer-message {
        display: flex;
        width: 100%;
        margin: 18px 0;
      }
      .__chatgpt-fetch-trimmer-message[data-role="user"] {
        justify-content: flex-end;
      }
      .__chatgpt-fetch-trimmer-message[data-role="assistant"],
      .__chatgpt-fetch-trimmer-message[data-role="tool"],
      .__chatgpt-fetch-trimmer-message[data-role="system"] {
        justify-content: flex-start;
      }
      .__chatgpt-fetch-trimmer-content {
        max-width: min(42rem, 100%);
        line-height: 1.55;
        overflow-wrap: anywhere;
      }
      .__chatgpt-fetch-trimmer-content p {
        margin: 0 0 0.85em;
      }
      .__chatgpt-fetch-trimmer-content h3,
      .__chatgpt-fetch-trimmer-content h4 {
        margin: 1em 0 0.45em;
        font-weight: 600;
        line-height: 1.3;
      }
      .__chatgpt-fetch-trimmer-content h3 {
        font-size: 1.08em;
      }
      .__chatgpt-fetch-trimmer-content h4 {
        font-size: 1em;
      }
      .__chatgpt-fetch-trimmer-content p:last-child,
      .__chatgpt-fetch-trimmer-content pre:last-child,
      .__chatgpt-fetch-trimmer-content ul:last-child,
      .__chatgpt-fetch-trimmer-content ol:last-child,
      .__chatgpt-fetch-trimmer-content h3:last-child,
      .__chatgpt-fetch-trimmer-content h4:last-child {
        margin-bottom: 0;
      }
      .__chatgpt-fetch-trimmer-content hr {
        border: 0;
        border-top: 1px solid color-mix(in srgb, currentColor 16%, transparent);
        margin: 1em 0;
      }
      .__chatgpt-fetch-trimmer-content pre {
        margin: 0.85em 0;
        padding: 12px;
        border-radius: 8px;
        overflow: auto;
        background: var(--main-surface-secondary, rgba(127, 127, 127, 0.12));
        white-space: pre;
      }
      .__chatgpt-fetch-trimmer-content code {
        font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
        font-size: 0.9em;
      }
      .__chatgpt-fetch-trimmer-content p code,
      .__chatgpt-fetch-trimmer-content li code {
        padding: 0.08em 0.28em;
        border-radius: 4px;
        background: var(--main-surface-secondary, rgba(127, 127, 127, 0.12));
      }
      .__chatgpt-fetch-trimmer-content ul,
      .__chatgpt-fetch-trimmer-content ol {
        margin: 0.7em 0;
        padding-left: 1.35em;
      }
      .__chatgpt-fetch-trimmer-content li {
        margin: 0.28em 0;
      }
      .__chatgpt-fetch-trimmer-content blockquote {
        margin: 0.85em 0;
        padding-left: 0.9em;
        border-left: 3px solid color-mix(in srgb, currentColor 24%, transparent);
        opacity: 0.86;
      }
      .__chatgpt-fetch-trimmer-content table {
        width: 100%;
        border-collapse: collapse;
        margin: 0.85em 0;
        font-size: 0.94em;
      }
      .__chatgpt-fetch-trimmer-content th,
      .__chatgpt-fetch-trimmer-content td {
        border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
        padding: 6px 8px;
        vertical-align: top;
      }
      .__chatgpt-fetch-trimmer-content th {
        font-weight: 600;
        background: var(--main-surface-secondary, rgba(127, 127, 127, 0.08));
      }
      .__chatgpt-fetch-trimmer-content a {
        color: var(--link, #0b57d0);
        text-decoration: underline;
        text-underline-offset: 2px;
      }
      .__chatgpt-fetch-trimmer-message[data-role="user"] .__chatgpt-fetch-trimmer-content {
        max-width: min(34rem, 85%);
        border-radius: 18px;
        padding: 10px 14px;
        background: var(--message-surface, var(--main-surface-secondary, rgba(127, 127, 127, 0.12)));
      }
      .__chatgpt-fetch-trimmer-role {
        display: none;
      }
    `;
    document.documentElement.appendChild(style);
  }

  function removeArchiveContainer() {
    const container = document.getElementById("__chatgpt-fetch-trimmer-archive");
    if (container) {
      container.remove();
    }
  }

  function getConversationRoot() {
    return document.querySelector("main") || document.querySelector('[role="main"]') || document.body;
  }

  function getMessageAnchor(node) {
    if (!node) return null;
    return node.closest("article") || node.closest('[data-testid*="conversation-turn"]') || node.closest('[class*="group/turn-messages"]') || node;
  }

  function getFirstRenderedMessageAnchor() {
    const root = getConversationRoot();
    const firstMessage = root && root.querySelector('[data-message-author-role]');
    return getMessageAnchor(firstMessage);
  }

  function getScrollContainer(element) {
    let current = element instanceof Element ? element.parentElement : null;
    while (current && current !== document.body && current !== document.documentElement) {
      const style = window.getComputedStyle(current);
      if (isScrollableElement(current, 1) && /(auto|scroll|overlay)/.test(style.overflowY)) {
        return current;
      }
      current = current.parentElement;
    }
    return document.scrollingElement || document.documentElement;
  }

  function adjustScroll(scroller, delta) {
    if (!delta) return;
    if (scroller === document.scrollingElement || scroller === document.documentElement || scroller === document.body) {
      window.scrollBy(0, delta);
      return;
    }
    scroller.scrollTop += delta;
  }

  function ensureArchiveContainer() {
    ensureArchiveStyle();
    let container = document.getElementById("__chatgpt-fetch-trimmer-archive");
    if (container) return container;

    const root = getConversationRoot();
    const firstMessage = root.querySelector('[data-message-author-role]');
    const anchor = getMessageAnchor(firstMessage);
    if (!root || !anchor || !anchor.parentElement) return null;

    container = document.createElement("section");
    container.id = "__chatgpt-fetch-trimmer-archive";
    container.setAttribute("aria-label", "Older messages loaded by ChatGPT Optimized");

    const note = document.createElement("div");
    note.className = "__chatgpt-fetch-trimmer-note";
    note.textContent = "Older messages loaded by ChatGPT Optimized. These are read-only reconstructions from the trimmed conversation payload.";
    container.appendChild(note);

    anchor.parentElement.insertBefore(container, anchor);
    return container;
  }

  function renderArchiveMessage(message) {
    const wrapper = document.createElement("article");
    wrapper.className = "__chatgpt-fetch-trimmer-message";
    wrapper.dataset.archiveMessageId = message.id;
    wrapper.dataset.role = message.role;
    wrapper.setAttribute("aria-label", `Older ${message.role} message`);

    const content = document.createElement("div");
    content.className = "__chatgpt-fetch-trimmer-content";

    renderMessageText(content, message.text);
    wrapper.appendChild(content);
    return wrapper;
  }

  function appendInlineText(parent, value) {
    const pattern = /`([^`\n]+)`|\*\*([^*\n]+)\*\*|\[([^\]\n]+)\]\(([^)\s]+)\)|\*([^*\n]+)\*/g;
    let lastIndex = 0;
    let match;
    while ((match = pattern.exec(value)) !== null) {
      if (match.index > lastIndex) {
        parent.appendChild(document.createTextNode(value.slice(lastIndex, match.index)));
      }
      if (match[1]) {
        const code = document.createElement("code");
        code.textContent = match[1];
        parent.appendChild(code);
      } else if (match[2]) {
        const strong = document.createElement("strong");
        appendInlineText(strong, match[2]);
        parent.appendChild(strong);
      } else if (match[3] && match[4]) {
        appendLinkOrText(parent, match[3], match[4]);
      } else if (match[5]) {
        const emphasis = document.createElement("em");
        appendInlineText(emphasis, match[5]);
        parent.appendChild(emphasis);
      }
      lastIndex = pattern.lastIndex;
    }
    if (lastIndex < value.length) {
      parent.appendChild(document.createTextNode(value.slice(lastIndex)));
    }
  }

  function appendLinkOrText(parent, label, href) {
    if (/^(https?:|mailto:)/i.test(href)) {
      const link = document.createElement("a");
      link.textContent = label;
      link.href = href;
      link.rel = "noreferrer noopener";
      link.target = "_blank";
      parent.appendChild(link);
      return;
    }
    parent.appendChild(document.createTextNode(`[${label}](${href})`));
  }

  function appendParagraph(parent, lines) {
    if (!lines.length) return;
    const paragraph = document.createElement("p");
    appendInlineText(paragraph, lines.join(" "));
    parent.appendChild(paragraph);
  }

  function appendList(parent, items, ordered) {
    if (!items.length) return;
    const list = document.createElement(ordered ? "ol" : "ul");
    for (const item of items) {
      const li = document.createElement("li");
      appendInlineText(li, item.text);
      list.appendChild(li);
    }
    parent.appendChild(list);
  }

  function appendBlockquote(parent, lines) {
    if (!lines.length) return;
    const blockquote = document.createElement("blockquote");
    const paragraph = document.createElement("p");
    appendInlineText(paragraph, lines.join(" "));
    blockquote.appendChild(paragraph);
    parent.appendChild(blockquote);
  }

  function splitTableRow(line) {
    const trimmed = line.trim();
    if (!trimmed.includes("|")) return null;
    const withoutOuter = trimmed.replace(/^\|/, "").replace(/\|$/, "");
    return withoutOuter.split("|").map((cell) => cell.trim());
  }

  function isTableSeparator(line) {
    const cells = splitTableRow(line);
    return Boolean(cells && cells.length > 1 && cells.every((cell) => /^:?-{3,}:?$/.test(cell)));
  }

  function appendTable(parent, rows) {
    if (rows.length < 2 || !isTableSeparator(rows[1])) return false;
    const header = splitTableRow(rows[0]);
    const bodyRows = rows.slice(2).map(splitTableRow).filter((row) => row && row.length);
    if (!header || !bodyRows.length) return false;

    const table = document.createElement("table");
    const thead = document.createElement("thead");
    const headerRow = document.createElement("tr");
    for (const cell of header) {
      const th = document.createElement("th");
      appendInlineText(th, cell);
      headerRow.appendChild(th);
    }
    thead.appendChild(headerRow);
    table.appendChild(thead);

    const tbody = document.createElement("tbody");
    for (const row of bodyRows) {
      const tr = document.createElement("tr");
      for (let i = 0; i < header.length; i += 1) {
        const td = document.createElement("td");
        appendInlineText(td, row[i] || "");
        tr.appendChild(td);
      }
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    parent.appendChild(table);
    return true;
  }

  function renderMessageText(parent, value) {
    const lines = String(value || "").replace(/\r\n/g, "\n").split("\n");
    let paragraph = [];
    let list = [];
    let orderedList = false;
    let blockquote = [];
    let table = [];
    let inCode = false;
    let codeLang = "";
    let codeLines = [];

    function flushParagraph() {
      appendParagraph(parent, paragraph);
      paragraph = [];
    }

    function flushList() {
      appendList(parent, list, orderedList);
      list = [];
      orderedList = false;
    }

    function flushBlockquote() {
      appendBlockquote(parent, blockquote);
      blockquote = [];
    }

    function flushTable() {
      if (table.length) {
        if (!appendTable(parent, table)) {
          for (const row of table) paragraph.push(row);
        }
      }
      table = [];
    }

    function flushCode() {
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      if (codeLang) code.dataset.language = codeLang;
      code.textContent = codeLines.join("\n");
      pre.appendChild(code);
      parent.appendChild(pre);
      codeLines = [];
      codeLang = "";
    }

    for (const line of lines) {
      const fence = line.match(/^```\s*([A-Za-z0-9_-]+)?(?:\s+.*)?$/);
      if (fence) {
        if (inCode) {
          flushCode();
          inCode = false;
        } else {
          flushParagraph();
          flushList();
          flushBlockquote();
          flushTable();
          inCode = true;
          codeLang = fence[1] || "";
        }
        continue;
      }

      if (inCode) {
        codeLines.push(line);
        continue;
      }

      if (!line.trim()) {
        flushParagraph();
        flushList();
        flushBlockquote();
        flushTable();
        continue;
      }

      if (splitTableRow(line)) {
        flushParagraph();
        flushList();
        flushBlockquote();
        table.push(line);
        continue;
      }

      flushTable();

      const quote = line.match(/^\s{0,3}>\s?(.*)$/);
      if (quote) {
        flushParagraph();
        flushList();
        blockquote.push(quote[1]);
        continue;
      }

      flushBlockquote();

      const heading = line.match(/^\s{0,3}(#{1,4})\s+(.+)$/);
      if (heading) {
        flushParagraph();
        flushList();
        flushBlockquote();
        const element = document.createElement(heading[1].length <= 2 ? "h3" : "h4");
        appendInlineText(element, heading[2]);
        parent.appendChild(element);
        continue;
      }

      if (/^\s*-{3,}\s*$/.test(line)) {
        flushParagraph();
        flushList();
        flushBlockquote();
        parent.appendChild(document.createElement("hr"));
        continue;
      }

      const bullet = line.match(/^(\s*)[-*]\s+(.+)$/);
      const ordered = line.match(/^(\s*)\d+[.)]\s+(.+)$/);
      if (bullet || ordered) {
        flushParagraph();
        const isOrdered = Boolean(ordered);
        if (list.length && orderedList !== isOrdered) flushList();
        orderedList = isOrdered;
        list.push({ indent: (bullet || ordered)[1].length, text: (bullet || ordered)[2] });
        continue;
      }

      flushList();
      paragraph.push(line);
    }

    if (inCode) flushCode();
    flushParagraph();
    flushList();
    flushBlockquote();
    flushTable();
  }

  function isNearTop(target) {
    const threshold = Math.max(16, Number(state.options.scrollThreshold) || defaults.scrollThreshold);
    const scroller = getRelevantScrollTarget(target, threshold);
    if (!scroller || !isScrollableElement(scroller, threshold)) {
      return false;
    }
    return scroller.scrollTop <= threshold;
  }

  function isScrollableElement(element, threshold) {
    return Boolean(element && element.scrollHeight > element.clientHeight + threshold);
  }

  function getRelevantScrollTarget(target, threshold) {
    if (target === window || target === document || target === document.body || target === document.documentElement) {
      const pageScroller = document.scrollingElement || document.documentElement;
      return isScrollableElement(pageScroller, threshold) ? pageScroller : null;
    }

    if (target instanceof Element) {
      let current = target;
      while (current && current !== document.body && current !== document.documentElement) {
        const style = window.getComputedStyle(current);
        if (isScrollableElement(current, threshold) && /(auto|scroll|overlay)/.test(style.overflowY)) {
          return current;
        }
        current = current.parentElement;
      }
    }

    const pageScroller = document.scrollingElement || document.documentElement;
    return isScrollableElement(pageScroller, threshold) ? pageScroller : null;
  }

  function handleScroll(event) {
    const nearTop = isNearTop(event.target);
    if (state.waitingForTopReset) {
      if (!nearTop) {
        state.waitingForTopReset = false;
      }
      return;
    }
    if (!state.userRequestedOlder || !state.last || !state.last.canExpand) {
      return;
    }
    const minInterval = Math.max(0, Number(state.options.minExpandIntervalMs) || defaults.minExpandIntervalMs);
    if (Date.now() - state.lastArchiveExpandAt < minInterval) {
      return;
    }
    if (nearTop) {
      state.userRequestedOlder = false;
      if (expandOlderMessages()) {
        state.waitingForTopReset = true;
      }
    }
  }

  function handleWheel(event) {
    if (event.deltaY > 0) {
      state.waitingForTopReset = false;
      state.userRequestedOlder = false;
      return;
    }
    if (event.deltaY < 0 && !state.waitingForTopReset) {
      state.userRequestedOlder = true;
    }
  }

  function handleKeydown(event) {
    if (["ArrowUp", "PageUp", "Home"].includes(event.key)) {
      state.userRequestedOlder = true;
    }
  }

  function disable() {
    state.enabled = false;
    window.fetch = state.originalFetch;
    window.removeEventListener("scroll", handleScroll, true);
    window.removeEventListener("wheel", handleWheel, true);
    window.removeEventListener("keydown", handleKeydown, true);
    return status();
  }

  function status() {
    return {
      version: VERSION,
      enabled: state.enabled,
      options: Object.assign({}, state.options),
      trimCount: state.trimCount,
      last: state.last,
      userRequestedOlder: state.userRequestedOlder,
      waitingForTopReset: state.waitingForTopReset,
      archive: state.archive
        ? {
            totalMessages: state.archive.messages.length,
            renderedMessages: state.renderedArchiveCount,
            remainingMessages: Math.max(0, state.archive.messages.length - state.renderedArchiveCount),
            stats: state.archiveStats,
          }
        : null,
    };
  }

  window[KEY] = {
    version: VERSION,
    configure,
    disable,
    expandOlderMessages,
    resetProgress,
    status,
  };

  window.addEventListener("scroll", handleScroll, true);
  window.addEventListener("wheel", handleWheel, true);
  window.addEventListener("keydown", handleKeydown, true);
  console.info("ChatGPT fetch trimmer active", status());
  return status();
})({ keepMessages: 40 });
