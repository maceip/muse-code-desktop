const subtitleEl = document.getElementById("subtitle");
const claimBtn = document.getElementById("claimBtn");
const releaseBtn = document.getElementById("releaseBtn");

async function requestAllSitesPermissionIfNeeded() {
  try {
    const hasAll = await browser.permissions.contains({
      origins: ["*://*/*", "<all_urls>"]
    });
    if (!hasAll) {
      await browser.permissions.request({
        origins: ["*://*/*", "<all_urls>"]
      });
    }
  } catch (_) {
    try {
      await browser.permissions.request({
        origins: ["*://*/*"]
      });
    } catch (_) {}
  }
}

async function getActiveTab() {
  try {
    const tabs = await browser.tabs.query({ active: true, currentWindow: true });
    return tabs && tabs.length > 0 ? tabs[0] : null;
  } catch (_) {
    return null;
  }
}

async function refreshStatus() {
  const activeTab = await getActiveTab();
  const activeTabId = activeTab ? activeTab.id : null;

  let resp = await browser.runtime.sendMessage({
    target: "background",
    command: { action: "status" }
  });

  const isPaused = Boolean(resp && resp.data && resp.data.isPaused);
  let ownedTabId = resp && resp.data ? resp.data.ownedTabId : null;

  // Auto-claim active tab on popup open if not explicitly paused
  if (!isPaused && ownedTabId === null && activeTabId !== null) {
    resp = await browser.runtime.sendMessage({
      target: "background",
      command: { action: "claimTab", tabId: activeTabId }
    });
    ownedTabId = resp && resp.data ? resp.data.ownedTabId : activeTabId;
  }

  const isCurrentTabClaimed = !isPaused && ownedTabId !== null && activeTabId === ownedTabId;

  if (isCurrentTabClaimed) {
    subtitleEl.textContent = "Let Muse code drive Safari";
    claimBtn.textContent = "✓ Active on This Tab";
    claimBtn.classList.add("claimed-btn");
    claimBtn.disabled = true;
    releaseBtn.textContent = "Release";
    releaseBtn.disabled = false;
  } else if (!isPaused && ownedTabId !== null) {
    subtitleEl.textContent = "Let Muse code drive Safari";
    claimBtn.textContent = "Use This Tab";
    claimBtn.classList.remove("claimed-btn");
    claimBtn.disabled = false;
    releaseBtn.textContent = "Release";
    releaseBtn.disabled = false;
  } else {
    subtitleEl.textContent = "Let Muse code drive Safari";
    claimBtn.textContent = "Use This Tab";
    claimBtn.classList.remove("claimed-btn");
    claimBtn.disabled = false;
    releaseBtn.textContent = "Release";
    releaseBtn.disabled = true;
  }
}

claimBtn.addEventListener("click", async () => {
  if (claimBtn.disabled) return;
  claimBtn.disabled = true;
  claimBtn.textContent = "Connecting…";
  await requestAllSitesPermissionIfNeeded();
  const activeTab = await getActiveTab();
  const tabId = activeTab ? activeTab.id : undefined;
  await browser.runtime.sendMessage({
    target: "background",
    command: { action: "claimTab", tabId }
  });
  await refreshStatus();
});

releaseBtn.addEventListener("click", async () => {
  if (releaseBtn.disabled) return;
  releaseBtn.disabled = true;
  await browser.runtime.sendMessage({
    target: "background",
    command: { action: "releaseTab" }
  });
  await refreshStatus();
});

refreshStatus();
