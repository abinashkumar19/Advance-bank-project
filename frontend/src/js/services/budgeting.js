/* ---------------- Budgeting — category limits + spend insights ---------------- */
async function renderBudgeting() {
  const main = document.getElementById("main");
  main.innerHTML = pageHeader("Budgeting", "Category limits & spend insights") + `
    <div class="card fade-in">
      <h2>Set a category limit</h2>
      <div class="grid cols-2" style="gap:12px;">
        <div><label>Category</label>
          <select id="bg_category">
            <option value="food">Food</option>
            <option value="shopping">Shopping</option>
            <option value="utilities">Utilities</option>
            <option value="transport">Transport</option>
            <option value="entertainment">Entertainment</option>
            <option value="other">Other</option>
          </select>
        </div>
        <div><label>Monthly limit</label><input id="bg_limit" type="number" min="0" step="0.01" placeholder="0.00" /></div>
      </div>
      <button class="btn" onclick="doSetLimit()">Save limit</button>
      <div id="bg_msg"></div>
    </div>
    <div class="section-title">This month's spend</div>
    <div id="bg_insights"><div class="empty">Loading…</div></div>
  `;
  loadInsights();
}
async function doSetLimit() {
  const el = document.getElementById("bg_msg");
  try {
    const body = { user_id: currentUser.user_id, category: document.getElementById("bg_category").value, monthly_limit: Number(document.getElementById("bg_limit").value) };
    await api("/budgeting/limits", { method: "PUT", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Limit saved.</div>`; toast("Limit saved.");
    loadInsights();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadInsights() {
  const box = document.getElementById("bg_insights");
  try {
    const data = await api(`/budgeting/insights/user/${currentUser.user_id}`);
    box.innerHTML = data.breakdown.length ? `<div class="grid cols-2">${data.breakdown.map(b => `
      <div class="card fade-in">
        <h2 style="text-transform:capitalize;">${b.category} ${b.over_limit ? badge('', 'over limit') : ''}</h2>
        <p class="hint">Spent: $${fmtMoney(b.spent)}${b.limit ? ` of $${fmtMoney(b.limit)} limit` : ' (no limit set)'}</p>
      </div>
    `).join("")}</div>` : `<div class="empty">No spend recorded yet.</div>`;
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}
