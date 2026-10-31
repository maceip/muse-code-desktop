const statusEl = document.getElementById("status");
const statePillEl = document.getElementById("statePill");
const claimBtn = document.getElementById("claimBtn");
const releaseBtn = document.getElementById("releaseBtn");
const allowAllBtn = document.getElementById("allowAllBtn");

async function checkAllSitesPermission() {
  try {
    const hasAll = await browser.permissions.contains({
      origins: ["*://*/*", "<all_urls>"]
    });
    allowAllBtn.hidden = Boolean(hasAll);
    return hasAll;
  } catch (_) {
    allowAllBtn.hidden = true;
    return true;
  }
}

async function requestAllSitesPermission() {
  try {
    await browser.permissions.request({
      origins: ["*://*/*", "<all_urls>"]
    });
  } catch (_) {
    try {
      await browser.permissions.request({
        origins: ["*://*/*"]
      });
    } catch (_) {}
  }
  await checkAllSitesPermission();
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
  await checkAllSitesPermission();
  const activeTab = await getActiveTab();
  const activeTabId = activeTab ? activeTab.id : null;

  const resp = await browser.runtime.sendMessage({
    target: "background",
    command: { action: "status" }
  });

  const ownedTabId = resp && resp.data ? resp.data.ownedTabId : null;
  const isCurrentTabClaimed = ownedTabId !== null && activeTabId === ownedTabId;

  if (isCurrentTabClaimed) {
    // Current tab is already claimed: disable "Claim This Tab" and turn it emerald green
    const rawTitle = (resp.data.title || activeTab?.title || resp.data.url || "Active Tab").replace(/^🟢\s*/, "");
    statusEl.textContent = `● This Tab Is Claimed (#${ownedTabId}): ${rawTitle}`;
    statusEl.classList.add("claimed");

    statePillEl.textContent = "CLAIMED";
    statePillEl.classList.add("claimed");

    claimBtn.textContent = "✓ Tab Claimed";
    claimBtn.classList.add("claimed-btn");
    claimBtn.disabled = true;

    releaseBtn.textContent = "Release Tab";
    releaseBtn.classList.remove("secondary");
    releaseBtn.classList.add("release-active");
    releaseBtn.disabled = false;
  } else if (ownedTabId !== null) {
    // Another tab is claimed in the background
    const otherTitle = (resp.data.title || resp.data.url || `Tab #${ownedTabId}`).replace(/^🟢\s*/, "");
    statusEl.textContent = `Tab #${ownedTabId} is claimed (${otherTitle}). Click below to switch Muse to this tab.`;
    statusEl.classList.remove("claimed");

    statePillEl.textContent = `TAB #${ownedTabId}`;
    statePillEl.classList.add("claimed");

    claimBtn.textContent = "Claim This Tab Instead";
    claimBtn.classList.remove("claimed-btn");
    claimBtn.disabled = false;

    releaseBtn.textContent = "Release";
    releaseBtn.classList.remove("secondary");
    releaseBtn.classList.add("release-active");
    releaseBtn.disabled = false;
  } else {
    // No tab is claimed
    statusEl.textContent = "No tab currently claimed by Muse.";
    statusEl.classList.remove("claimed");

    statePillEl.textContent = "IDLE";
    statePillEl.classList.remove("claimed");

    claimBtn.textContent = "Claim This Tab";
    claimBtn.classList.remove("claimed-btn");
    claimBtn.disabled = false;

    releaseBtn.textContent = "Release";
    releaseBtn.classList.add("secondary");
    releaseBtn.classList.remove("release-active");
    releaseBtn.disabled = true;
  }
}

allowAllBtn.addEventListener("click", async () => {
  await requestAllSitesPermission();
});

claimBtn.addEventListener("click", async () => {
  if (claimBtn.disabled) return;
  claimBtn.disabled = true;
  claimBtn.textContent = "Claiming…";
  await requestAllSitesPermission();
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
