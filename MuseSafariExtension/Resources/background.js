/*
 * background.js
 * MuseSafariExtension
 *
 * Persistent Safari Web Extension background coordinator for Muse Code.
 * Maintains the Muse agent's owned Safari tab (`ownedTabId`), polls both
 * native messaging (`SafariWebExtensionHandler`) and the local Muse Safari
 * Bridge HTTP server (`127.0.0.1:47635`), and dispatches navigation and DOM
 * commands to `content.js` inside the owned tab.
 */

const NATIVE_APP_ID = "com.musecode.Pie.SafariExtension";
const DEFAULT_BRIDGE_PORT = 47635;

let ownedTabId = null;
let bridgePort = DEFAULT_BRIDGE_PORT;
let isPolling = false;

async function loadStoredState() {
  try {
    const stored = await browser.storage.local.get(["ownedTabId", "bridgePort"]);
    if (typeof stored.ownedTabId === "number") {
      ownedTabId = stored.ownedTabId;
    }
    if (typeof stored.bridgePort === "number" && stored.bridgePort > 0) {
      bridgePort = stored.bridgePort;
    }
  } catch (_) {}
}

async function saveOwnedTabId(tabId) {
  ownedTabId = tabId;
  try {
    await browser.storage.local.set({ ownedTabId: tabId });
  } catch (_) {}
}

async function getOwnedOrActiveTab(autoClaim = true) {
  if (ownedTabId !== null) {
    try {
      const tab = await browser.tabs.get(ownedTabId);
      if (tab && tab.id) {
        return tab;
      }
    } catch (_) {
      await saveOwnedTabId(null);
    }
  }

  if (!autoClaim) {
    return null;
  }

  const activeTabs = await browser.tabs.query({ active: true, currentWindow: true });
  if (activeTabs && activeTabs.length > 0 && activeTabs[0].id) {
    await saveOwnedTabId(activeTabs[0].id);
    return activeTabs[0];
  }

  const allTabs = await browser.tabs.query({});
  if (allTabs && allTabs.length > 0 && allTabs[0].id) {
    await saveOwnedTabId(allTabs[0].id);
    return allTabs[0];
  }

  const created = await browser.tabs.create({ url: "https://www.google.com", active: true });
  await saveOwnedTabId(created.id);
  return created;
}

async function waitForTabLoad(tabId, timeoutMs = 12000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const tab = await browser.tabs.get(tabId);
      if (tab && tab.status === "complete") {
        return tab;
      }
    } catch (_) {
      break;
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  try {
    return await browser.tabs.get(tabId);
  } catch (_) {
    return null;
  }
}

async function buildTabStateSummary() {
  const tab = await getOwnedOrActiveTab(false);
  return {
    ownedTabId: tab ? tab.id : null,
    url: tab ? tab.url || "" : "",
    title: tab ? tab.title || "" : "",
    status: tab ? tab.status || "unknown" : "unclaimed",
    bridgePort
  };
}

async function sendToContentScript(tabId, payload) {
  try {
    const response = await browser.tabs.sendMessage(tabId, payload);
    if (response) {
      return response;
    }
  } catch (_) {
    // Inject content.js on demand if the tab was opened before the extension loaded
    try {
      await browser.scripting.executeScript({
        target: { tabId },
        files: ["content.js"]
      });
      return await browser.tabs.sendMessage(tabId, payload);
    } catch (err) {
      return { ok: false, error: String(err && err.message ? err.message : err) };
    }
  }
  return { ok: false, error: "No response from content script" };
}

async function executeBridgeCommand(command) {
  const action = command.action || "status";

  if (action === "status" || action === "ping") {
    const summary = await buildTabStateSummary();
    return { ok: true, action, data: summary };
  }

  if (action === "claimTab") {
    let tab = null;
    if (typeof command.tabId === "number") {
      tab = await browser.tabs.get(command.tabId);
      await saveOwnedTabId(tab.id);
    } else if (command.url) {
      tab = await browser.tabs.create({ url: command.url, active: true });
      await saveOwnedTabId(tab.id);
      tab = await waitForTabLoad(tab.id, command.timeoutMs || 12000);
    } else {
      tab = await getOwnedOrActiveTab(true);
    }
    await sendToContentScript(tab.id, { action: "markOwned", owned: true });
    return {
      ok: true,
      action,
      data: await buildTabStateSummary()
    };
  }

  if (action === "releaseTab") {
    if (ownedTabId !== null) {
      try {
        await sendToContentScript(ownedTabId, { action: "markOwned", owned: false });
      } catch (_) {}
    }
    await saveOwnedTabId(null);
    return {
      ok: true,
      action,
      data: await buildTabStateSummary()
    };
  }

  if (action === "navigate" || action === "openTab") {
    const targetUrl = command.url || "https://www.google.com";
    let tab = await getOwnedOrActiveTab(false);
    if (!tab || action === "openTab") {
      tab = await browser.tabs.create({ url: targetUrl, active: true });
      await saveOwnedTabId(tab.id);
    } else {
      tab = await browser.tabs.update(tab.id, { url: targetUrl, active: true });
    }
    const loaded = await waitForTabLoad(tab.id, command.timeoutMs || 15000);
    await sendToContentScript(tab.id, { action: "markOwned", owned: true });
    const domResult = await sendToContentScript(tab.id, { action: "inspectDOM" });
    return {
      ok: true,
      action,
      data: {
        tabId: tab.id,
        url: loaded ? loaded.url : targetUrl,
        title: loaded ? loaded.title : "",
        dom: domResult && domResult.data ? domResult.data : null
      }
    };
  }

  if (action === "reload") {
    const tab = await getOwnedOrActiveTab(true);
    await browser.tabs.reload(tab.id);
    const loaded = await waitForTabLoad(tab.id, command.timeoutMs || 12000);
    return {
      ok: true,
      action,
      data: { tabId: tab.id, url: loaded ? loaded.url : tab.url, title: loaded ? loaded.title : tab.title }
    };
  }

  if (action === "goBack" || action === "goForward") {
    const tab = await getOwnedOrActiveTab(true);
    const resp = await sendToContentScript(tab.id, { action });
    await waitForTabLoad(tab.id, 4000);
    return resp;
  }

  // All DOM-level actions run in the owned tab via content.js
  const tab = await getOwnedOrActiveTab(true);
  await sendToContentScript(tab.id, { action: "markOwned", owned: true });
  return await sendToContentScript(tab.id, command);
}

async function pollNativeAndLocalBridge() {
  if (isPolling) return;
  isPolling = true;
  try {
    const tabState = await buildTabStateSummary();

    // 1. Poll local HTTP bridge in Pie.app (`http://127.0.0.1:47635/api/v1/extension/poll`)
    try {
      const httpResp = await fetch(`http://127.0.0.1:${bridgePort}/api/v1/extension/poll`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ tabState })
      });
      if (httpResp.ok) {
        const payload = await httpResp.json();
        if (payload && payload.type === "command" && payload.command) {
          const cmd = payload.command;
          const execResult = await executeBridgeCommand(cmd);
          const updatedTab = await buildTabStateSummary();
          await fetch(`http://127.0.0.1:${bridgePort}/api/v1/extension/result`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              id: cmd.id,
              ok: Boolean(execResult && execResult.ok !== false),
              data: execResult ? execResult.data ?? execResult : null,
              error: execResult && execResult.error ? execResult.error : null,
              tabState: updatedTab
            })
          });
        }
      }
    } catch (_) {}

    // 2. Poll Safari native extension handler (`SafariWebExtensionHandler.swift`)
    try {
      const nativeResp = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, {
        type: "poll",
        tabState
      });
      if (nativeResp && nativeResp.type === "command" && nativeResp.command) {
        const cmd = nativeResp.command;
        const execResult = await executeBridgeCommand(cmd);
        const updatedTab = await buildTabStateSummary();
        await browser.runtime.sendNativeMessage(NATIVE_APP_ID, {
          type: "result",
          id: cmd.id,
          ok: Boolean(execResult && execResult.ok !== false),
          data: execResult ? execResult.data ?? execResult : null,
          error: execResult && execResult.error ? execResult.error : null,
          tabState: updatedTab
        });
      }
    } catch (_) {}
  } finally {
    isPolling = false;
  }
}

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.target === "background") {
    executeBridgeCommand(message.command || { action: "status" }).then(sendResponse);
    return true;
  }
  return false;
});

browser.tabs.onRemoved.addListener((tabId) => {
  if (tabId === ownedTabId) {
    saveOwnedTabId(null);
  }
});

loadStoredState().then(() => {
  setInterval(pollNativeAndLocalBridge, 350);
  pollNativeAndLocalBridge();
});
