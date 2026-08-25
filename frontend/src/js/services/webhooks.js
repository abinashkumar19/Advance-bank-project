/* ---------------- Webhooks — outbound event delivery for developers ---------------- */
let _webhookEventTypes = [];
let _selectedEventTypes = new Set();

async function renderWebhooks() {
  const main = document.getElementById("main");
  main.innerHTML = pageHeader("Webhooks", "Send account events to your own endpoint") + `
    <div class="card fade-in">
      <h2>New subscription</h2>
      <label>Destination URL</label>
      <input id="wh_url" placeholder="https://your-server.com/hooks/veerabank" oninput="validateWebhookUrl()" />
      <div id="wh_url_hint" class="hint" style="margin:-10px 0 12px;"></div>

      <label>Events</label>
      <div id="wh_events" class="wh-event-pills"><div class="empty">Loading…</div></div>

      <label style="margin-top:14px;">Signing secret (optional)</label>
      <div class="wh-secret-row">
        <input id="wh_secret" type="password" placeholder="Sent as X-VeeraBank-Signature" />
        <button type="button" class="btn ghost sm" onclick="toggleSecretVisibility()">
          <svg id="wh_secret_eye" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" width="16" height="16"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>
        </button>
      </div>

      <button class="btn" style="margin-top:16px;" onclick="doCreateWebhook()">Subscribe</button>
      <div id="wh_msg"></div>
    </div>

    <div class="section-title">Your subscriptions</div>
    <div id="wh_list"><div class="empty">Loading…</div></div>

    <div class="section-title">Recent deliveries</div>
    <div id="wh_deliveries"><div class="empty">Loading…</div></div>
  `;
  _selectedEventTypes = new Set();
  await loadEventTypes();
  loadWebhooks();
  loadDeliveries();
}

function validateWebhookUrl() {
  const val = document.getElementById("wh_url").value.trim();
  const hint = document.getElementById("wh_url_hint");
  if (!val) { hint.textContent = ""; return; }
  const ok = /^https?:\/\/.+/i.test(val);
  hint.innerHTML = ok
    ? `<span style="color:var(--ledger);">Looks like a valid URL.</span>`
    : `<span style="color:var(--danger);">Must start with http:// or https://</span>`;
}

function toggleSecretVisibility() {
  const input = document.getElementById("wh_secret");
  const isHidden = input.type === "password";
  input.type = isHidden ? "text" : "password";
  document.getElementById("wh_secret_eye").innerHTML = isHidden
    ? `<path d="M3 3l18 18"/><path d="M10.6 10.6a3 3 0 0 0 4.24 4.24"/><path d="M6.6 6.6C4 8.2 2 12 2 12s3.5 7 10 7c1.9 0 3.5-.5 4.9-1.3"/><path d="M17.4 17.4C19.9 15.8 22 12 22 12s-1.3-2.6-3.5-4.6"/>`
    : `<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>`;
}

async function loadEventTypes() {
  const box = document.getElementById("wh_events");
  _webhookEventTypes = await api("/webhooks/event-types");
  renderEventPills();
}
function renderEventPills() {
  const box = document.getElementById("wh_events");
  box.innerHTML = _webhookEventTypes.map(t => `
    <button type="button" class="pill ${_selectedEventTypes.has(t) ? 'active' : ''}" onclick="toggleEventType('${t}')">
      <span class="dot ${_selectedEventTypes.has(t) ? 'on' : ''}"></span>${t.replace(/_/g, ' ')}
    </button>
  `).join("");
}
function toggleEventType(t) {
  if (_selectedEventTypes.has(t)) _selectedEventTypes.delete(t); else _selectedEventTypes.add(t);
  renderEventPills();
}

async function doCreateWebhook() {
  const el = document.getElementById("wh_msg");
  try {
    const url = document.getElementById("wh_url").value.trim();
    if (!/^https?:\/\/.+/i.test(url)) throw new Error("Enter a valid http(s) URL.");
    if (!_selectedEventTypes.size) throw new Error("Pick at least one event type.");
    const body = { user_id: currentUser.user_id, url, event_types: Array.from(_selectedEventTypes), secret: document.getElementById("wh_secret").value || undefined };
    await api("/webhooks/subscriptions", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Subscribed.</div>`; toast("Subscribed.");
    document.getElementById("wh_url").value = "";
    document.getElementById("wh_secret").value = "";
    document.getElementById("wh_url_hint").textContent = "";
    _selectedEventTypes = new Set();
    renderEventPills();
    loadWebhooks();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}

function copyWebhookUrl(url) {
  navigator.clipboard.writeText(url);
  toast("URL copied.");
}

async function loadWebhooks() {
  const box = document.getElementById("wh_list");
  try {
    const items = await api(`/webhooks/subscriptions/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? `<div class="grid cols-2">${items.map(w => `
      <div class="card fade-in wh-sub-card">
        <div class="wh-sub-url" onclick="copyWebhookUrl('${w.url.replace(/'/g, "\\'")}')" title="Click to copy">
          ${w.url}
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" width="13" height="13"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>
        </div>
        <div class="wh-event-tags">
          ${w.event_types.map(t => `<span class="tag">${t.replace(/_/g, ' ')}</span>`).join("")}
        </div>
        <div class="split" style="margin-top:12px;">
          ${badge('', w.status)}
          <span class="hint" style="margin:0;">Created ${fmtWhen(w.created_at)}</span>
        </div>
        <div class="split" style="margin-top:10px;">
          <button class="btn ghost sm" onclick="testWebhook('${w.id}')">Test</button>
          ${w.status === 'active'
            ? `<button class="btn ghost sm" onclick="pauseWebhook('${w.id}')">Pause</button>`
            : `<button class="btn ghost sm" onclick="resumeWebhook('${w.id}')">Resume</button>`}
          <button class="btn ghost sm" onclick="deleteWebhook('${w.id}')">Delete</button>
        </div>
      </div>
    `).join("")}</div>` : `<div class="empty"><div class="big">No subscriptions yet</div>Add a destination URL above to get started.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}

async function loadDeliveries() {
  const box = document.getElementById("wh_deliveries");
  try {
    const items = await api(`/webhooks/deliveries/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? items.slice(0, 20).map(d => `
      <div class="wh-delivery-row fade-in">
        <span class="wh-delivery-dot ${d.status === 'delivered' ? 'ok' : 'fail'}"></span>
        <div class="wh-delivery-main">
          <div class="wh-delivery-event">${d.event_type.replace(/_/g, ' ')}</div>
          <div class="hint" style="margin:2px 0 0;">${d.url}</div>
          ${d.status === 'failed' && d.error ? `<div class="wh-delivery-error">${d.error}</div>` : ""}
        </div>
        <div class="wh-delivery-meta">
          ${d.response_code ? `<span class="tag ${d.status === 'delivered' ? 'tag-ok' : 'tag-fail'}">${d.response_code}</span>` : `<span class="tag tag-fail">no response</span>`}
          <div class="hint" style="margin:4px 0 0;">${fmtWhen(d.created_at)}</div>
        </div>
      </div>
    `).join("") : `<div class="empty"><div class="big">No deliveries yet</div>Hit "Test" on a subscription to send one.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}

async function testWebhook(id) { try { await api(`/webhooks/subscriptions/${id}/test`, { method: "POST", body: JSON.stringify({}) }); toast("Test delivery sent."); loadDeliveries(); } catch (e) { toast(e.message, false); } }
async function pauseWebhook(id) { try { await api(`/webhooks/subscriptions/${id}/pause`, { method: "PATCH" }); toast("Paused — real events won't deliver until resumed."); loadWebhooks(); } catch (e) { toast(e.message, false); } }
async function resumeWebhook(id) { try { await api(`/webhooks/subscriptions/${id}/resume`, { method: "PATCH" }); toast("Resumed."); loadWebhooks(); } catch (e) { toast(e.message, false); } }
async function deleteWebhook(id) { try { await api(`/webhooks/subscriptions/${id}`, { method: "DELETE" }); toast("Subscription deleted."); loadWebhooks(); } catch (e) { toast(e.message, false); } }
