/* ---------------- Bill Payments — electricity, mobile, DTH, broadband ---------------- */
let _billersCache = null;
async function renderBillPayments() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Bill Payments", "Utilities, recharge & more") + (mine ? `
    <div class="card fade-in">
      <h2>Pay a bill</h2>
      <div class="grid cols-2" style="gap:12px;">
        <div><label>Bill type</label>
          <select id="bp_type" onchange="onBillerTypeChange()">
            <option value="electricity">Electricity</option>
            <option value="mobile">Mobile Recharge</option>
            <option value="dth">DTH</option>
            <option value="broadband">Broadband</option>
            <option value="gas">Gas</option>
            <option value="water">Water</option>
          </select>
        </div>
        <div><label>Biller</label><select id="bp_biller"></select></div>
        <div><label>Consumer / account number</label><input id="bp_consumer" placeholder="e.g. 100234567" /></div>
        <div><label>Amount</label><input id="bp_amount" type="number" min="0.01" step="0.01" placeholder="0.00" /></div>
      </div>
      <button class="btn" onclick="doPayBill()">Pay bill</button>
      <div id="bp_msg"></div>
    </div>
    <div class="section-title">Payment history</div>
    <div id="bp_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("bill payments"));
  if (mine) { await loadBillers(); loadBillHistory(); }
}
async function loadBillers() {
  _billersCache = await api("/bill-payments/billers");
  onBillerTypeChange();
}
function onBillerTypeChange() {
  const type = document.getElementById("bp_type").value;
  const sel = document.getElementById("bp_biller");
  const options = (_billersCache && _billersCache[type]) || [];
  sel.innerHTML = options.map(b => `<option value="${b}">${b}</option>`).join("");
}
async function doPayBill() {
  const el = document.getElementById("bp_msg");
  try {
    const body = {
      user_id: currentUser.user_id,
      account_id: cachedAccounts[0].account_id,
      biller_type: document.getElementById("bp_type").value,
      biller_name: document.getElementById("bp_biller").value,
      consumer_number: document.getElementById("bp_consumer").value,
      amount: Number(document.getElementById("bp_amount").value),
    };
    await api("/bill-payments/pay", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Bill paid.</div>`; toast("Bill paid.");
    loadBillHistory(); loadAccountsSilently();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadBillHistory() {
  const box = document.getElementById("bp_list");
  try {
    const items = await api(`/bill-payments/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? items.map(b => `
      <div class="row fade-in">
        <div><b>${b.biller_name}</b><div class="hint">${b.biller_type} · ${b.consumer_number} · ${fmtWhen(b.created_at)}</div></div>
        <div>$${fmtMoney(b.amount)} ${badge('', b.status)}</div>
      </div>
    `).join("") : `<div class="empty">No bill payments yet.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
