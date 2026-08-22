/* ---------------- Insurance — browse catalog, purchase, track policies ---------------- */
async function renderInsurance() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Insurance", "Life, health, vehicle & home cover") + (mine ? `
    <div class="section-title">Plans</div>
    <div class="grid cols-3" id="ins_catalog"><div class="empty">Loading…</div></div>
    <div class="section-title">Your policies</div>
    <div id="ins_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("insurance"));
  if (mine) { loadCatalog(); loadPolicies(); }
}
async function loadCatalog() {
  const box = document.getElementById("ins_catalog");
  try {
    const plans = await api("/insurance/catalog");
    box.innerHTML = plans.map(p => `
      <div class="card fade-in">
        <h2>${p.name}</h2>
        <p class="hint">Cover: $${fmtMoney(p.coverage)}</p>
        <p class="hint">Annual premium: $${fmtMoney(p.annual_premium)}</p>
        <button class="btn ghost sm" onclick="doPurchasePolicy('${p.plan_id}')">Purchase</button>
      </div>
    `).join("");
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function doPurchasePolicy(planId) {
  try {
    const body = { user_id: currentUser.user_id, account_id: cachedAccounts[0].account_id, plan_id: planId };
    await api("/insurance/purchase", { method: "POST", body: JSON.stringify(body) });
    toast("Policy purchased."); loadPolicies(); loadAccountsSilently();
  } catch (e) { toast(e.message, false); }
}
async function loadPolicies() {
  const box = document.getElementById("ins_list");
  try {
    const items = await api(`/insurance/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? items.map(p => `
      <div class="row fade-in">
        <div><b>${p.plan_name}</b><div class="hint">${p.policy_number} · renews ${p.renewal_date}</div></div>
        <div>$${fmtMoney(p.annual_premium)}/yr ${badge('', p.status)}
          ${p.status === 'active' ? `<button class="btn ghost sm" onclick="doCancelPolicy('${p.id}')">Cancel</button>` : ''}
        </div>
      </div>
    `).join("") : `<div class="empty">No policies yet.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function doCancelPolicy(id) { try { await api(`/insurance/${id}/cancel`, { method: "PATCH" }); toast("Policy cancelled."); loadPolicies(); } catch (e) { toast(e.message, false); } }
