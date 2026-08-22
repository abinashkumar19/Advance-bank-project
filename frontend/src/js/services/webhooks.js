/* ---------------- Webhooks — outbound event delivery for developers ---------------- */
let _webhookEventTypes = [];
async function renderWebhooks() {
  const main = document.getElementById("main");
  main.innerHTML = pageHeader("Webhooks", "Send account events to your own endpoint") + `
    <div class="card fade-in">
      <h2>New subscription</h2>
      <label>Destination URL</label><input id="wh_url" placeholder="https://your-server.com/hooks/veerabank" />
      <label>Events</label>
      <div id="wh_events" class="grid cols-3" style="gap:6px;"><div class="empty">Loading…</div></div>
      <label>Signing secret (optional)</label><input id="wh_secret" placeholder="Sent as X-VeeraBank-Signature" />
      <button class="btn" onclick="doCreateWebhook()">Subscribe</button>
      <div id="wh_msg"></div>
    </div>
    <div class="section-title">Your subscriptions</div>
    <div id="wh_list"><div class="empty">Loading…</div></div>
    <div class="section-title">Recent deliveries</div>
    <div id="wh_deliveries"><div class="empty">Loading…</div></div>
  `;
  await loadEventTypes();
  loadWebhooks();
  loadDeliveries();
}
async function loadEventTypes() {
  const box = document.getElementById("wh_events");
  _webhookEventTypes = await api("/webhooks/event-types");
  box.innerHTML = _webhookEventTypes.map(t => `
    <label style="display:flex; align-items:center; gap:6px; font-weight:400;">
      <input type="checkbox" class="wh-event-cb" value="${t}" /> ${t.replace(/_/g, ' ')}
    </label>
  `).join("");
}
async function doCreateWebhook() {
  const el = document.getElementById("wh_msg");
  try {
    const eventTypes = Array.from(document.querySelectorAll(".wh-event-cb:checked")).map(cb => cb.value);
    if (!eventTypes.length) throw new Error("Pick at least one event type.");
    const body = { user_id: currentUser.user_id, url: document.getElementById("wh_url").value, event_types: eventTypes, secret: document.getElementById("wh_secret").value || undefined };
    await api("/webhooks/subscriptions", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Subscribed.</div>`; toast("Subscribed.");
    loadWebhooks();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadWebhooks() {
  const box = document.getElementById("wh_list");
  try {
    const items = await api(`/webhooks/subscriptions/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? items.map(w => `
      <div class="row fade-in">
        <div><b>${w.url}</b><div class="hint">${w.event_types.join(', ')}</div></div>
        <div>${badge('', w.status)}
          <button class="btn ghost sm" onclick="testWebhook('${w.id}')">Test</button>
          <button class="btn ghost sm" onclick="deleteWebhook('${w.id}')">Delete</button>
        </div>
      </div>
    `).join("") : `<div class="empty">No subscriptions yet.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function loadDeliveries() {
  const box = document.getElementById("wh_deliveries");
  try {
    const items = await api(`/webhooks/deliveries/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? items.slice(0, 20).map(d => `
      <div class="row fade-in">
        <div><b>${d.event_type}</b><div class="hint">${d.url} · ${fmtWhen(d.created_at)}</div></div>
        <div>${badge('', d.status)}${d.response_code ? ` (${d.response_code})` : ''}</div>
      </div>
    `).join("") : `<div class="empty">No deliveries yet.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function testWebhook(id) { try { await api(`/webhooks/subscriptions/${id}/test`, { method: "POST", body: JSON.stringify({}) }); toast("Test delivery sent."); loadDeliveries(); } catch (e) { toast(e.message, false); } }
async function deleteWebhook(id) { try { await api(`/webhooks/subscriptions/${id}`, { method: "DELETE" }); toast("Subscription deleted."); loadWebhooks(); } catch (e) { toast(e.message, false); } }
