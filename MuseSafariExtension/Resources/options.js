const portInput = document.getElementById("portInput");
const saveBtn = document.getElementById("saveBtn");
const savedMsg = document.getElementById("savedMsg");
const allowAllBtn = document.getElementById("allowAllBtn");
const permText = document.getElementById("permText");

async function refreshPermissions() {
  try {
    const granted = await browser.permissions.contains({
      origins: ["*://*/*", "<all_urls>"]
    });
    if (granted) {
      permText.textContent = "Access to all websites (*://*/*) is enabled.";
      allowAllBtn.textContent = "All Websites Enabled ✓";
    }
  } catch (_) {}
}

allowAllBtn.addEventListener("click", async () => {
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
  await refreshPermissions();
});

browser.storage.local.get(["bridgePort"]).then((res) => {
  if (typeof res.bridgePort === "number") {
    portInput.value = String(res.bridgePort);
  }
});

saveBtn.addEventListener("click", async () => {
  const port = parseInt(portInput.value, 10) || 47635;
  await browser.storage.local.set({ bridgePort: port });
  savedMsg.style.display = "inline";
  setTimeout(() => { savedMsg.style.display = "none"; }, 1800);
});

refreshPermissions();
