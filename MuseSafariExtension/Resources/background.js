/*
 * background.js
 * MuseSafariExtension
 *
 * Persistent Safari Web Extension background coordinator for Muse Code.
 * Maintains the Muse agent's owned Safari tab (`ownedTabId`), updates the
 * Safari toolbar icon & badge per-tab so the claimed tab is unmistakably marked,
 * polls both native messaging (`SafariWebExtensionHandler`) and the local Muse
 * Safari Bridge HTTP server (`127.0.0.1:47635`), and dispatches navigation and
 * DOM commands to `content.js` inside the owned tab.
 */

const NATIVE_APP_ID = "xyz.hieunguyen.PiCode.SafariExtension";
const DEFAULT_BRIDGE_PORT = 47635;

let ownedTabId = null;
let bridgePort = DEFAULT_BRIDGE_PORT;
let isPolling = false;
let cachedIconData = null;

function buildActionIconImageData(isClaimed) {
  if (typeof OffscreenCanvas === "undefined") {
    return null;
  }
  if (!cachedIconData) {
    cachedIconData = { claimed: null, idle: null };
  }
  const key = isClaimed ? "claimed" : "idle";
  if (cachedIconData[key]) {
    return cachedIconData[key];
  }
  try {
    const result = {};
    for (const size of [16, 32, 64]) {
      const canvas = new OffscreenCanvas(size, size);
      const ctx = canvas.getContext("2d");
      const r = size * 0.44;
      const cx = size * 0.5;
      const cy = size * 0.5;

      ctx.clearRect(0, 0, size, size);
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.fillStyle = isClaimed ? "#10b981" : "#64748b";
      ctx.fill();

      ctx.lineWidth = Math.max(1.5, size * 0.08);
      ctx.strokeStyle = "#ffffff";
      ctx.stroke();

      if (isClaimed) {
        // Draw bold white checkmark inside the emerald circle
        ctx.beginPath();
        ctx.moveTo(size * 0.30, size * 0.52);
        ctx.lineTo(size * 0.45, size * 0.67);
        ctx.lineTo(size * 0.72, size * 0.36);
        ctx.strokeStyle = "#ffffff";
        ctx.lineWidth = Math.max(2, size * 0.11);
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        ctx.stroke();
      } else {
        // Draw "M" monogram for idle state
        ctx.beginPath();
        ctx.moveTo(size * 0.30, size * 0.66);
        ctx.lineTo(size * 0.30, size * 0.34);
        ctx.lineTo(size * 0.50, size * 0.54);
        ctx.lineTo(size * 0.70, size * 0.34);
        ctx.lineTo(size * 0.70, size * 0.66);
        ctx.strokeStyle = "#ffffff";
        ctx.lineWidth = Math.max(1.6, size * 0.09);
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        ctx.stroke();
      }
      result[size] = ctx.getImageData(0, 0, size, size);
    }
    cachedIconData[key] = result;
    return result;
  } catch (_) {
    return null;
  }
}

async function updateToolbarActionVisuals() {
  if (!browser.action) return;
  try {
    const activeTabs = await browser.tabs.query({ active: true, currentWindow: true });
    const activeTab = activeTabs && activeTabs.length > 0 ? activeTabs[0] : null;
    const activeTabId = activeTab ? activeTab.id : null;
    const isFocusedOnClaimedTab = ownedTabId !== null && activeTabId === ownedTabId;

    const iconData = buildActionIconImageData(isFocusedOnClaimedTab);
    const iconPaths = isFocusedOnClaimedTab
      ? {
          16: "images/icon-claimed-16.png",
          32: "images/icon-claimed-32.png",
          64: "images/icon-claimed-64.png",
          128: "images/icon-claimed-128.png"
        }
      : {
          16: "images/icon-idle-16.png",
          32: "images/icon-idle-32.png",
          64: "images/icon-idle-64.png",
          128: "images/icon-idle-128.png"
        };

    // Update global default action state to reflect whether the currently focused tab is the claimed tab
    try {
      await browser.action.setIcon({ path: iconPaths });
    } catch (_) {
      try {
        if (iconData) await browser.action.setIcon({ imageData: iconData });
      } catch (_) {}
    }

    if (isFocusedOnClaimedTab) {
      try {
        await browser.action.setBadgeText({ text: "ON" });
        await browser.action.setBadgeBackgroundColor({ color: "#10b981" });
        await browser.action.setTitle({ title: `Muse on Safari — Claimed Tab (#${ownedTabId})` });
      } catch (_) {}
    } else if (ownedTabId !== null) {
      try {
        await browser.action.setBadgeText({ text: "" });
        await browser.action.setTitle({ title: `Muse on Safari (Tab #${ownedTabId} claimed)` });
      } catch (_) {}
    } else {
      try {
        await browser.action.setBadgeText({ text: "" });
        await browser.action.setTitle({ title: "Muse on Safari" });
      } catch (_) {}
    }

    // Also set tab-specific icon/badge on ownedTabId if present
    if (ownedTabId !== null) {
      try {
        await browser.action.setIcon({
          tabId: ownedTabId,
          path: {
            16: "images/icon-claimed-16.png",
            32: "images/icon-claimed-32.png",
            64: "images/icon-claimed-64.png",
            128: "images/icon-claimed-128.png"
          }
        });
        await browser.action.setBadgeText({ tabId: ownedTabId, text: "ON" });
        await browser.action.setBadgeBackgroundColor({ tabId: ownedTabId, color: "#10b981" });
      } catch (_) {}
    }
  } catch (_) {}
}

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
  await updateToolbarActionVisuals();
}

async function saveOwnedTabId(tabId) {
  const previousTabId = ownedTabId;
  ownedTabId = tabId;
  try {
    await browser.storage.local.set({ ownedTabId: tabId });
  } catch (_) {}
  if (previousTabId !== null && previousTabId !== tabId) {
    try {
      await sendToContentScript(previousTabId, { action: "markOwned", owned: false });
      if (browser.action) {
        await browser.action.setIcon({
          tabId: previousTabId,
          path: {
            16: "images/icon-idle-16.png",
            32: "images/icon-idle-32.png",
            64: "images/icon-idle-64.png",
            128: "images/icon-idle-128.png"
          }
        });
        await browser.action.setBadgeText({ tabId: previousTabId, text: "" });
      }
    } catch (_) {}
  }
  await updateToolbarActionVisuals();
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

async function executeBridgeCommand(command, senderTabId = null) {
  const action = command.action || "status";

  if (action === "checkIfThisTabOwned") {
    const isOwned = ownedTabId !== null && senderTabId === ownedTabId;
    return { ok: true, action, data: { owned: isOwned, ownedTabId } };
  }

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
    await updateToolbarActionVisuals();
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
    await updateToolbarActionVisuals();
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
    await updateToolbarActionVisuals();
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
    await sendToContentScript(tab.id, { action: "markOwned", owned: true });
    await updateToolbarActionVisuals();
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
    await sendToContentScript(tab.id, { action: "markOwned", owned: true });
    return resp;
  }

  // All DOM-level actions run in the owned tab via content.js
  const tab = await getOwnedOrActiveTab(true);
  await sendToContentScript(tab.id, { action: "markOwned", owned: true });
  await updateToolbarActionVisuals();
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
    const senderTabId = sender && sender.tab ? sender.tab.id : null;
    executeBridgeCommand(message.command || { action: "status" }, senderTabId).then(sendResponse);
    return true;
  }
  return false;
});

browser.tabs.onActivated.addListener(() => {
  updateToolbarActionVisuals();
});

browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (tabId === ownedTabId && changeInfo && changeInfo.status === "complete") {
    sendToContentScript(tabId, { action: "markOwned", owned: true });
  }
  updateToolbarActionVisuals();
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
