// background.js — proxy localhost calls from content scripts via sendResponse
const BASE = "http://127.0.0.1:18427";

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.type !== "jiraNotes.api") return; // ignore other messages

  const { path, method = "GET", body = null } = msg;

  fetch(BASE + path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
    cache: "no-store",
  })
    .then(async (res) => {
      const ct = res.headers.get("content-type") || "";
      const payload = ct.includes("application/json") ? await res.json() : await res.text();
      sendResponse({ ok: res.ok, status: res.status, payload });
    })
    .catch((e) => {
      sendResponse({ ok: false, status: 0, error: String(e) });
    });

  // IMPORTANT for Safari MV3: keep the message channel open until sendResponse is called
  return true;
});
