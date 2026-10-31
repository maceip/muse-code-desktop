const statusEl = document.getElementById("status");
const permStatusEl = document.getElementById("permStatus");
const claimBtn = document.getElementById("claimBtn");
const releaseBtn = document.getElementById("releaseBtn");
const allowAllBtn = document.getElementById("allowAllBtn");

async function checkAllSitesPermission() {
  try {
    const hasAll = await browser.permissions.contains({
      origins: ["*://*/*", "<all_urls>"]
    });
    if (hasAll) {
      permStatusEl.textContent = "All Websites Access: Enabled (*://*/*)";
      permStatusEl.classList.remove("pending");
      allowAllBtn.textContent = "All Websites Enabled ✓";
    } else {
      permStatusEl.textContent = "Website Access: Click below to enable on all websites";
      permStatusEl.classList.add("pending");
      allowAllBtn.textContent = "Allow on All Websites…";
    }
    return hasAll;
  } catch (_) {
    return false;
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

async function refreshStatus() {
  await checkAllSitesPermission();
  const resp = await browser.runtime.sendMessage({
    target: "background",
    command: { action: "status" }
  });
  if (resp && resp.data && resp.data.ownedTabId) {
    statusEl.textContent = `Owned Tab #${resp.data.ownedTabId}: ${resp.data.title || resp.data.url || "Ready"}`;
  } else {
    statusEl.textContent = "No tab currently claimed by Muse.";
  }
}

allowAllBtn.addEventListener("click", async () => {
  await requestAllSitesPermission();
});

claimBtn.addEventListener("click", async () => {
  await requestAllSitesPermission();
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  const tabId = tabs && tabs[0] ? tabs[0].id : undefined;
  await browser.runtime.sendMessage({
    target: "background",
    command: { action: "claimTab", tabId }
  });
  await refreshStatus();
});

releaseBtn.addEventListener("click", async () => {
  await browser.runtime.sendMessage({
    target: "background",
    command: { action: "releaseTab" }
  });
  await refreshStatus();
});

refreshStatus();
