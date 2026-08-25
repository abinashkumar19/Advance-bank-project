/* ---------------- Recurring Payments — standing instructions / autopay ---------------- */
async function renderRecurringPayments() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Recurring Payments", "Autopay & standing instructions") + (mine ? `
    <div class="card fade-in">
      <h2>New standing instruction</h2>
      <div class="grid cols-2" style="gap:12px;">
        <div><label>Payee name</label><input id="rp_payee" placeholder="e.g. Landlord, SIP - Mutual Fund" /></div>
        <div><label>Amount</label><input id="rp_amount" type="number" min="0.01" step="0.01" placeholder="0.00" /></div>
        <div><label>Frequency</label>
          <select id="rp_freq">
            <option value="monthly">Monthly</option>
            <option value="weekly">Weekly</option>
            <option value="daily">Daily</option>
          </select>
        </div>
        <div><label>Start date</label><input id="rp_start" type="date" /></div>
      </div>
      <label>Note (optional)</label><input id="rp_note" placeholder="e.g. Rent for 2BHK" />
      <button class="btn" onclick="doCreateRecurring()">Create</button>
      <div id="rp_msg"></div>
    </div>
    <div class="section-title">Your standing instructions</div>
    <div id="rp_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("recurring payments"));
  if (mine) loadRecurring();
}
async function doCreateRecurring() {
  const el = document.getElementById("rp_msg");
  try {
    const body = {
      user_id: currentUser.user_id,
      account_id: cachedAccounts[0].account_id,
      payee_name: document.getElementById("rp_payee").value,
      amount: Number(document.getElementById("rp_amount").value),
      frequency: document.getElementById("rp_freq").value,
      start_date: document.getElementById("rp_start").value || undefined,
      note: document.getElementById("rp_note").value,
    };
    await api("/recurring-payments/", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Standing instruction created.</div>`; toast("Standing instruction created.");
    loadRecurring();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadRecurring() {
  const box = document.getElementById("rp_list");
  try {
    const items = await api(`/recurring-payments/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? `<div class="grid cols-2">${items.map(r => `
      <div class="card fade-in">
        <h2>${r.payee_name} ${badge('', r.status)}</h2>
        <p class="hint">$${fmtMoney(r.amount)} · ${r.frequency} · next run ${r.next_run_date}</p>
        ${r.note ? `<p class="hint">${r.note}</p>` : ""}
        <div class="split">
          ${r.status === 'active' ? `<button class="btn ghost sm" onclick="pauseRecurring('${r.id}')">Pause</button>` : ''}
          ${r.status === 'paused' ? `<button class="btn ghost sm" onclick="resumeRecurring('${r.id}')">Resume</button>` : ''}
          <button class="btn ghost sm" onclick="cancelRecurring('${r.id}')">Cancel</button>
        </div>
      </div>
    `).join("")}</div>` : `<div class="empty"><div class="big">No standing instructions yet</div>Set up your first autopay above.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function pauseRecurring(id) { try { await api(`/recurring-payments/${id}/pause`, { method: "PATCH" }); toast("Paused."); loadRecurring(); } catch (e) { toast(e.message, false); } }
async function resumeRecurring(id) { try { await api(`/recurring-payments/${id}/resume`, { method: "PATCH" }); toast("Resumed."); loadRecurring(); } catch (e) { toast(e.message, false); } }
async function cancelRecurring(id) { try { await api(`/recurring-payments/${id}`, { method: "DELETE" }); toast("Cancelled."); loadRecurring(); } catch (e) { toast(e.message, false); } }
