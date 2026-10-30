const statusEl = document.getElementById("status");
const claimBtn = document.getElementById("claimBtn");
const releaseBtn = document.getElementById("releaseBtn");

async function refreshStatus() {
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

claimBtn.addEventListener("click", async () => {
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
