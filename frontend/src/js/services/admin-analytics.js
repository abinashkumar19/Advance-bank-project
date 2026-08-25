/* ---------------- Admin Analytics — bank-wide staff dashboards ---------------- */
async function renderAdminAnalytics() {
  const main = document.getElementById("main");
  main.innerHTML = pageHeader("Admin Analytics", "Bank-wide overview") + `
    <div class="grid cols-3" id="aa_summary"><div class="empty">Loading…</div></div>
    <div class="section-title">Top account balances</div>
    <div id="aa_top"><div class="empty">Loading…</div></div>
  `;
  loadAnalytics();
}
async function loadAnalytics() {
  const summaryBox = document.getElementById("aa_summary");
  const topBox = document.getElementById("aa_top");
  try {
    const [s, top] = await Promise.all([api("/admin-analytics/summary"), api("/admin-analytics/top-accounts?limit=10")]);
    summaryBox.innerHTML = `
      <div class="card fade-in"><h2>Users</h2><p class="hint" style="font-size:22px;">${s.users.total}</p></div>
      <div class="card fade-in"><h2>Accounts</h2><p class="hint" style="font-size:22px;">${s.accounts.total}</p><p class="hint">Total balance: $${fmtMoney(s.accounts.total_balance)}</p></div>
      <div class="card fade-in"><h2>Transfers</h2><p class="hint" style="font-size:22px;">${s.transfers.total}</p><p class="hint">Volume: $${fmtMoney(s.transfers.total_volume)}</p></div>
      <div class="card fade-in"><h2>Loans</h2><p class="hint" style="font-size:22px;">${s.loans.total}</p><p class="hint">${Object.entries(s.loans.by_status).map(([k,v])=>`${k}: ${v}`).join(', ')}</p></div>
      <div class="card fade-in"><h2>Cards</h2><p class="hint" style="font-size:22px;">${s.cards.total}</p><p class="hint">${Object.entries(s.cards.by_type).map(([k,v])=>`${k}: ${v}`).join(', ')}</p></div>
      <div class="card fade-in"><h2>Fixed Deposits</h2><p class="hint" style="font-size:22px;">${s.fixed_deposits.total}</p></div>
      <div class="card fade-in"><h2>Disputes</h2><p class="hint" style="font-size:22px;">${s.disputes.total}</p><p class="hint">${Object.entries(s.disputes.by_status).map(([k,v])=>`${k}: ${v}`).join(', ')}</p></div>
      <div class="card fade-in"><h2>Support tickets</h2><p class="hint" style="font-size:22px;">${s.support_tickets.total}</p><p class="hint">${Object.entries(s.support_tickets.by_status).map(([k,v])=>`${k}: ${v}`).join(', ')}</p></div>
    `;
    topBox.innerHTML = top.length ? top.map((a, i) => `
      <div class="row fade-in">
        <div><b>#${i+1}</b> <span class="hint">${a.account_id}</span></div>
        <div>$${fmtMoney(a.balance)}</div>
      </div>
    `).join("") : `<div class="empty">No accounts yet.</div>`;
  } catch (e) { summaryBox.innerHTML = `<div class="empty">${e.message}</div>`; }
}
