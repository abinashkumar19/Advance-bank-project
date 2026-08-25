/* ---------------- Goals — target-based savings with real contributions ---------------- */
async function renderGoals() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Goals", "Save toward something specific") + (mine ? `
    <div class="card fade-in">
      <h2>New goal</h2>
      <div class="grid cols-2" style="gap:12px;">
        <div><label>Goal name</label><input id="gl_name" placeholder="e.g. Emergency fund, New laptop" /></div>
        <div><label>Target amount</label><input id="gl_target" type="number" min="0.01" step="0.01" placeholder="0.00" /></div>
        <div><label>Target date (optional)</label><input id="gl_date" type="date" /></div>
      </div>
      <button class="btn" onclick="doCreateGoal()">Create goal</button>
      <div id="gl_msg"></div>
    </div>
    <div class="section-title">Your goals</div>
    <div id="gl_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("goals"));
  if (mine) loadGoals();
}
async function doCreateGoal() {
  const el = document.getElementById("gl_msg");
  try {
    const body = {
      user_id: currentUser.user_id,
      account_id: cachedAccounts[0].account_id,
      name: document.getElementById("gl_name").value,
      target_amount: Number(document.getElementById("gl_target").value),
      target_date: document.getElementById("gl_date").value || undefined,
    };
    await api("/goals/", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Goal created.</div>`; toast("Goal created.");
    loadGoals();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadGoals() {
  const box = document.getElementById("gl_list");
  try {
    const items = await api(`/goals/user/${currentUser.user_id}`);
    box.innerHTML = items.length ? `<div class="grid cols-2">${items.map(g => {
      const pct = Math.min(100, (Number(g.current_amount) / Number(g.target_amount)) * 100);
      return `
      <div class="card fade-in">
        <h2>${g.name} ${badge('', g.status)}</h2>
        <p class="hint">$${fmtMoney(g.current_amount)} of $${fmtMoney(g.target_amount)}${g.target_date ? ` · by ${g.target_date}` : ''}</p>
        <div style="height:8px; border-radius:4px; background:var(--panel); overflow:hidden; margin:10px 0;">
          <div style="height:100%; width:${pct}%; background:var(--accent);"></div>
        </div>
        ${g.status === 'in_progress' ? `
          <div class="split">
            <input id="gl_contrib_${g.id}" type="number" min="0.01" step="0.01" placeholder="Amount" style="max-width:120px;" />
            <button class="btn ghost sm" onclick="doContribute('${g.id}')">Contribute</button>
          </div>
        ` : ''}
      </div>`;
    }).join("")}</div>` : `<div class="empty"><div class="big">No goals yet</div>Create your first one above.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
async function doContribute(id) {
  try {
    const amount = Number(document.getElementById(`gl_contrib_${id}`).value);
    const g = await api(`/goals/${id}/contribute`, { method: "POST", body: JSON.stringify({ amount }) });
    toast(g.status === "completed" ? "Goal reached! 🎉" : "Contribution added.");
    loadGoals(); loadAccountsSilently();
  } catch (e) { toast(e.message, false); }
}
