// The issue board, an MCP App. It speaks the host's postMessage JSON-RPC
// directly: ui/initialize, then ui/notifications/initialized; the host
// sends the tool's input and result as notifications, and a click on a
// card calls the app-only issue_details tool through the host.
(() => {
  "use strict";

  let nextId = 1;
  const pending = new Map();

  const send = (message) => window.parent.postMessage({ jsonrpc: "2.0", ...message }, "*");
  const notify = (method, params) => send({ method, params });

  const request = (method, params) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      send({ id, method, params });
    });

  const $ = (id) => document.getElementById(id);

  function element(tag, text, className) {
    const el = document.createElement(tag);
    if (text !== undefined) el.textContent = text;
    if (className) el.className = className;
    return el;
  }

  function renderBoard(result) {
    const issues = (result.structuredContent && result.structuredContent.issues) || [];
    $("open").replaceChildren();
    $("closed").replaceChildren();

    for (const issue of issues) {
      const card = element("button", `#${issue.id} ${issue.title}`, "card");
      card.dataset.id = issue.id;
      card.addEventListener("click", () => openIssue(issue.id));
      $(issue.state === "closed" ? "closed" : "open").append(card);
    }

    $("status").textContent = result.isError
      ? "The board could not load."
      : `${issues.length} issue${issues.length === 1 ? "" : "s"}`;
  }

  async function openIssue(id) {
    $("details").textContent = "Loading…";

    try {
      const result = await request("tools/call", { name: "issue_details", arguments: { id } });
      const text = (result.content || []).map((c) => c.text).join("\n");
      const issue = result.structuredContent;

      $("details").replaceChildren(
        ...(result.isError || !issue
          ? [element("p", text)]
          : [element("h2", `#${issue.id} ${issue.title} (${issue.state})`), element("p", issue.body)])
      );
    } catch (error) {
      $("details").textContent = `The host refused: ${error.message}`;
    }
  }

  // The host's theme: its CSS variables override the defaults in :root.
  function applyContext(context) {
    const variables = (context.styles && context.styles.variables) || {};

    for (const [name, value] of Object.entries(variables)) {
      if (value) document.documentElement.style.setProperty(name, value);
    }

    if (context.theme) document.documentElement.style.colorScheme = context.theme;
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window.parent) return;
    const message = event.data;
    if (!message || message.jsonrpc !== "2.0") return;

    if (message.method === undefined) {
      const call = pending.get(message.id);
      if (!call) return;
      pending.delete(message.id);
      if (message.error) call.reject(new Error(message.error.message));
      else call.resolve(message.result);
      return;
    }

    switch (message.method) {
      case "ui/notifications/tool-input":
        $("status").textContent = "Loading the issues…";
        break;
      case "ui/notifications/tool-result":
        renderBoard(message.params);
        break;
      case "ui/notifications/tool-cancelled":
        $("status").textContent = "Cancelled.";
        break;
      case "ui/notifications/host-context-changed":
        applyContext(message.params || {});
        break;
      case "ui/resource-teardown":
      case "ping":
        send({ id: message.id, result: {} });
        break;
      default:
        if (message.id !== undefined) {
          send({ id: message.id, error: { code: -32601, message: "Method not found" } });
        }
    }
  });

  // The host sizes the frame to the document.
  new ResizeObserver(() => {
    const { width, height } = document.documentElement.getBoundingClientRect();
    notify("ui/notifications/size-changed", { width: Math.ceil(width), height: Math.ceil(height) });
  }).observe(document.documentElement);

  request("ui/initialize", {
    protocolVersion: "2026-01-26",
    appInfo: { name: "sake-dev issue board", version: "1.0.0" },
    appCapabilities: { availableDisplayModes: ["inline"] }
  }).then((result) => {
    applyContext(result.hostContext || {});
    notify("ui/notifications/initialized", {});
  });
})();
