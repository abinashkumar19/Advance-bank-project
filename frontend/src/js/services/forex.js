/* ---------------- Forex — currency conversion orders ---------------- */
async function renderForex() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Forex", "Buy foreign currency at today's rate") + (mine ? `
    <div class="card fade-in">
      <h2>Convert</h2>
      <div class="grid cols-2" style="gap:12px;">
        <div><label>Currency</label>
          <select id="fx_currency" onchange="updateFxPreview()">
            <option value="USD">USD</option><option value="EUR">EUR</option><option value="GBP">GBP</option>
            <option value="AED">AED</option><option value="SGD">SGD</option><option value="AUD">AUD</option><option value="JPY">JPY</option>
          </select>
        </div>
        <div><label>Amount to buy</label><input id="fx_amount" type="number" min="0.01" step="0.01" placeholder="0.00" oninput="updateFxPreview()" /></div>
      </div>
      <p class="hint" id="fx_preview">Enter an amount to see the INR cost.</p>
      <button class="btn" onclick="doConvertFx()">Convert</button>
      <div id="fx_msg"></div>
    </div>
    <div class="section-title">Your orders</div>
    <div id="fx_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("forex"));
  if (mine) { await loadFxRates(); loadFxOrders(); }
}
let _fxRates = {};
async function loadFxRates() { _fxRates = await api("/forex/rates"); updateFxPreview(); }
function updateFxPreview() {
  const currency = document.getElementById("fx_currency").value;
  const amount = Number(document.getElementById("fx_amount").value || 0);
  const rate = Number(_fxRates[currency] || 0);
  document.getElementById("fx_preview").textContent = amount > 0 ? `≈ $${fmtMoney(amount * rate)} @ rate ${rate}` : `Rate: ₹${rate} per ${currency}`;
}
async function doConvertFx() {
  const el = document.getElementById("fx_msg");
  try {
    const body = { user_id: currentUser.user_id, account_id: cachedAccounts[0].account_id, currency: document.getElementById("fx_currency").value, foreign_amount: Number(document.getElementById("fx_amount").value) };
    const o = await api("/forex/convert", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Converted: $${fmtMoney(o.inr_amount)} → ${o.foreign_amount} ${o.currency}</div>`;
    toast("Converted."); loadFxOrders(); loadAccountsSilently();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadFxOrders() {
  const box = document.getElementById("fx_list");
  try {
    const items = await api(`/forex/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? items.map(o => `
      <div class="row fade-in">
        <div><b>${o.foreign_amount} ${o.currency}</b><div class="hint">@ ₹${o.rate} · ${fmtWhen(o.created_at)}</div></div>
        <div>$${fmtMoney(o.inr_amount)}</div>
      </div>
    `).join("") : `<div class="empty">No orders yet.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
