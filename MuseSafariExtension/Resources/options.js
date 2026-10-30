const portInput = document.getElementById("portInput");
const saveBtn = document.getElementById("saveBtn");
const savedMsg = document.getElementById("savedMsg");

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
