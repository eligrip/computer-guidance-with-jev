const toggle = document.querySelector("#toggle");
const status = document.querySelector("#status");
let sharing = false;

async function refresh() {
  const state = await chrome.runtime.sendMessage({type: "STATUS"});
  sharing = Boolean(state?.sharing);
  toggle.textContent = sharing ? "Stop sharing" : "Share during this help session";
  status.textContent = state?.error || (sharing ? "Sharing the active Chrome page." : "Browser sharing is off.");
  toggle.disabled = false;
}

toggle.addEventListener("click", async () => {
  toggle.disabled = true;
  try {
    if (!sharing) {
      // Optional host access is requested only from this explicit user gesture.
      const granted = await chrome.permissions.request({origins: ["http://*/*", "https://*/*"]});
      if (!granted) {
        status.textContent = "Page access was not granted. Sharing remains off.";
        toggle.disabled = false;
        return;
      }
    }
    const result = await chrome.runtime.sendMessage({type: sharing ? "STOP" : "START"});
    if (result?.error) throw new Error(result.error);
    await refresh();
  } catch (error) {
    status.textContent = error.message || "Unable to connect to Jev Assist.";
    toggle.disabled = false;
  }
});

refresh().catch(() => { status.textContent = "Reload the extension and try again."; });
