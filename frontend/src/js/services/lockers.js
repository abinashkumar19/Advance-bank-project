/* ---------------- Lockers — safe deposit box booking ---------------- */
async function renderLockers() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Lockers", "Safe deposit box rental") + (mine ? `
    <div class="section-title">Availability</div>
    <div class="grid cols-3" id="lk_availability"><div class="empty">Loading…</div></div>
    <div class="section-title">Your lockers</div>
    <div id="lk_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("lockers"));
  if (mine) { loadAvailability(); loadMyLockers(); }
}
async function loadAvailability() {
  const box = document.getElementById("lk_availability");
  try {
    const items = await api("/lockers/availability");
    box.innerHTML = items.map(l => `
      <div class="card fade-in">
        <h2 style="text-transform:capitalize;">${l.size} — ${l.branch}</h2>
        <p class="hint">$${fmtMoney(l.annual_fee)}/yr · ${l.available} available</p>
        <button class="btn ghost sm" ${l.available <= 0 ? 'disabled' : ''} onclick="doRentLocker('${l.branch.replace(/'/g,"\\'")}','${l.size}')">Rent</button>
      </div>
    `).join("");
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function doRentLocker(branch, size) {
  try {
    const body = { user_id: currentUser.user_id, account_id: cachedAccounts[0].account_id, branch, size };
    const l = await api("/lockers/rent", { method: "POST", body: JSON.stringify(body) });
    toast(`Locker ${l.locker_number} rented.`); loadAvailability(); loadMyLockers(); loadAccountsSilently();
  } catch (e) { toast(e.message, false); }
}
async function loadMyLockers() {
  const box = document.getElementById("lk_list");
  try {
    const items = await api(`/lockers/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? items.map(l => `
      <div class="row fade-in">
        <div><b>${l.locker_number}</b><div class="hint">${l.branch} · ${l.size} · renews ${l.renewal_date}</div></div>
        <div>${badge('', l.status)}${l.status === 'active' ? `<button class="btn ghost sm" onclick="releaseLocker('${l.id}')">Release</button>` : ''}</div>
      </div>
    `).join("") : `<div class="empty">No lockers rented yet.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function releaseLocker(id) { try { await api(`/lockers/${id}/release`, { method: "PATCH" }); toast("Locker released."); loadAvailability(); loadMyLockers(); } catch (e) { toast(e.message, false); } }
