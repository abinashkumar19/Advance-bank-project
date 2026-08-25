/* ---------------- Virtual Cards — single-use / merchant-locked cards ---------------- */
async function renderVirtualCards() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Virtual Cards", "One-time-use & merchant-locked cards") + (mine ? `
    <div class="card fade-in">
      <h2>Create a virtual card</h2>
      <div class="grid cols-2" style="gap:12px;">
        <div><label>Mode</label>
          <select id="vc_mode" onchange="onVcModeChange()">
            <option value="standard">Standard</option>
            <option value="single_use">Single use</option>
            <option value="merchant_locked">Merchant locked</option>
          </select>
        </div>
        <div id="vc_merchant_wrap" style="display:none;"><label>Merchant name</label><input id="vc_merchant" placeholder="e.g. Amazon" /></div>
      </div>
      <button class="btn" onclick="doCreateVirtualCard()">Create card</button>
      <div id="vc_msg"></div>
    </div>

    <div class="card fade-in" style="margin-top:18px;">
      <h2>Pay with a card number</h2>
      <p class="hint">Just the card number and where it's going — money moves for real into the recipient's account.</p>
      <div class="grid cols-2" style="gap:12px;">
        <div><label>Card number</label><input id="pay_card_number" inputmode="numeric" placeholder="4539 1234 5678 9012" /></div>
        <div><label>Amount</label><input id="pay_card_amount" type="number" min="0.01" step="0.01" placeholder="0.00" /></div>
      </div>
      <label>Recipient's account number</label>
      <input id="pay_to_account" inputmode="numeric" placeholder="e.g. 482190473311" />
      <label>Merchant name (optional — required if the card is merchant-locked)</label>
      <input id="pay_card_merchant" placeholder="e.g. Amazon" />
      <button class="btn ghost" onclick="doPayWithCard()">Pay</button>
      <div id="pay_card_msg"></div>
    </div>

    <div class="section-title">Your virtual cards</div>
    <div id="vc_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("virtual cards"));
  if (mine) loadVirtualCards();
}
function onVcModeChange() {
  document.getElementById("vc_merchant_wrap").style.display = document.getElementById("vc_mode").value === "merchant_locked" ? "" : "none";
}
async function doCreateVirtualCard() {
  const el = document.getElementById("vc_msg");
  try {
    const mode = document.getElementById("vc_mode").value;
    const body = { user_id: currentUser.user_id, account_id: cachedAccounts[0].account_id, mode };
    if (mode === "merchant_locked") body.merchant_name = document.getElementById("vc_merchant").value;
    const c = await api("/virtual-cards/", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `
      <div class="msg ok" style="margin-bottom:12px;">Card created — this is the only time the full number and CVV are shown.</div>
      <div class="bank-card fade-in">
        <div class="bank-card-top">
          <div class="bank-card-chip"></div>
          <div class="bank-card-mark"><span></span><span></span></div>
        </div>
        <div class="bank-card-number" onclick="navigator.clipboard.writeText('${c.card_number}'); toast('Card number copied.')" title="Click to copy">
          ${formatCardNumber(c.card_number)}
        </div>
        <div class="bank-card-bottom">
          <div class="bank-card-name">${currentUser.full_name}</div>
          <div class="bank-card-meta">
            <div class="label">Exp / CVV</div>
            <div class="value">${c.expiry_month}/${c.expiry_year} · ${c.cvv}</div>
          </div>
        </div>
      </div>
    `;
    toast("Virtual card created."); loadVirtualCards();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function doPayWithCard() {
  const el = document.getElementById("pay_card_msg");
  try {
    const cardNumber = document.getElementById("pay_card_number").value.replace(/\s+/g, "");
    const toAccount = document.getElementById("pay_to_account").value.trim();
    const amount = Number(document.getElementById("pay_card_amount").value);
    const merchantName = document.getElementById("pay_card_merchant").value.trim();
    if (!cardNumber) throw new Error("Enter the card number.");
    if (!toAccount) throw new Error("Enter the recipient's account number.");
    if (!amount || amount <= 0) throw new Error("Enter an amount.");

    const body = { card_number: cardNumber, to_account_number: toAccount, amount };
    if (merchantName) body.merchant_name = merchantName;

    const r = await api("/virtual-cards/pay", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Paid $${fmtMoney(r.amount)} with ${r.card_number_masked} to account ${r.to_account_number}${r.merchant_name ? ` at ${r.merchant_name}` : ""}.</div>`;
    toast("Payment successful.");
    document.getElementById("pay_card_number").value = "";
    document.getElementById("pay_to_account").value = "";
    document.getElementById("pay_card_amount").value = "";
    document.getElementById("pay_card_merchant").value = "";
    loadVirtualCards(); loadAccountsSilently();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadVirtualCards() {
  const box = document.getElementById("vc_list");
  try {
    const items = await api(`/virtual-cards/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? `<div class="grid cols-2">${items.map(c => `
      <div class="fade-in">
        <div class="bank-card ${c.status === 'frozen' ? 'frozen' : ''}">
          <div class="bank-card-top">
            <div class="bank-card-chip"></div>
            <div class="bank-card-mark"><span></span><span></span></div>
          </div>
          <div class="bank-card-number">${c.card_number_masked}</div>
          <div class="bank-card-bottom">
            <div class="bank-card-name">${c.merchant_name || currentUser.full_name}</div>
            <div class="bank-card-meta">
              <div class="label">Exp</div>
              <div class="value">${c.expiry_month}/${c.expiry_year}</div>
            </div>
          </div>
        </div>
        <div class="split" style="margin-top:10px;">
          ${badge('', c.status)}
          <span class="hint" style="text-transform:capitalize;">${c.mode.replace('_',' ')}</span>
        </div>
        <div class="split" style="margin-top:8px;">
          ${c.status === 'active' ? `<button class="btn ghost sm" onclick="freezeVc('${c.id}')">Freeze</button>` : ''}
          ${c.status === 'frozen' ? `<button class="btn ghost sm" onclick="unfreezeVc('${c.id}')">Unfreeze</button>` : ''}
          ${c.status !== 'voided' ? `<button class="btn ghost sm" onclick="voidVc('${c.id}')">Void</button>` : ''}
        </div>
      </div>
    `).join("")}</div>` : `<div class="empty"><div class="big">No virtual cards yet</div>Create one above.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function freezeVc(id) { try { await api(`/virtual-cards/${id}/freeze`, { method: "PATCH" }); toast("Frozen."); loadVirtualCards(); } catch (e) { toast(e.message, false); } }
async function unfreezeVc(id) { try { await api(`/virtual-cards/${id}/unfreeze`, { method: "PATCH" }); toast("Unfrozen."); loadVirtualCards(); } catch (e) { toast(e.message, false); } }
async function voidVc(id) { try { await api(`/virtual-cards/${id}`, { method: "DELETE" }); toast("Voided."); loadVirtualCards(); } catch (e) { toast(e.message, false); } }
