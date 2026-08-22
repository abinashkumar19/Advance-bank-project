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
    el.innerHTML = `<div class="msg ok">Card created: ${c.card_number_masked} (CVV ${c.cvv})</div>`;
    toast("Virtual card created."); loadVirtualCards();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadVirtualCards() {
  const box = document.getElementById("vc_list");
  try {
    const items = await api(`/virtual-cards/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? `<div class="grid cols-2">${items.map(c => `
      <div class="card fade-in">
        <h2>${c.card_number_masked} ${badge('', c.status)}</h2>
        <p class="hint">${c.mode.replace('_',' ')}${c.merchant_name ? ` · ${c.merchant_name}` : ''} · exp ${c.expiry_month}/${c.expiry_year}</p>
        <div class="split">
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
