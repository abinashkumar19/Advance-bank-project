/* ---------------- Cards ---------------- */
let revealedCards = {}; // cardId -> { card_number, cvv } once fetched, kept only in memory
let cardsCache = {};    // cardId -> last-loaded card record, used by the big-screen view modal

async function renderCards() {
  const main = document.getElementById("main");
  const mine = await myAccountOrNull();
  main.innerHTML = pageHeader("Cards", "Debit & credit cards") + (mine ? `
    <div class="grid cols-2">
      <div class="card fade-in">
        <h2>Issue a new card</h2>
        <p class="hint">Linked to your account · ${mine.account_number}</p>
        <label>Card type</label>
        <select id="cd_type"><option value="debit">Debit</option><option value="credit">Credit</option></select>
        <button class="btn" onclick="doIssueCard()">Issue card</button>
        <div id="cd_msg"></div>
      </div>
      <div class="card fade-in">
        <h2>How to view your card</h2>
        <p class="hint">Click a card to flip it and see the back (CVV). Click the eye icon to reveal the full number whenever you need it. Hit <b>View</b> for a big-screen version of any card.</p>
      </div>
    </div>
    <div class="section-title">Your cards</div>
    <div class="card-wall" id="cd_list"><div class="empty">Loading…</div></div>
  ` : noAccountCard("cards"));
  if (mine) loadCards();
}
async function doIssueCard() {
  const el = document.getElementById("cd_msg");
  try {
    const body = { user_id: currentUser.user_id, account_id: cachedAccounts[0].account_id, card_type: document.getElementById("cd_type").value };
    await api("/cards", { method: "POST", body: JSON.stringify(body) });
    el.innerHTML = `<div class="msg ok">Card issued.</div>`;
    toast("Card issued.");
    loadCards();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
async function loadCards() {
  const box = document.getElementById("cd_list");
  try {
    const cards = await api(`/cards/user/${currentUser.user_id}`);
    cardsCache = Object.fromEntries(cards.map(c => [c.id, c]));
    box.innerHTML = cards.length ? cards.map(c => renderVirtualCard(c)).join("") :
      `<div class="empty" style="width:100%"><div class="big">No cards yet</div>Issue your first one above.</div>`;
    playCardWallEnter();
    initCardTilt();
  } catch (e) { box.innerHTML = `<div class="empty">${e.message}</div>`; }
}

/* Bank branding used across the premium card faces. Change once, applies everywhere. */
const CARD_BANK_NAME = "Cloud Bank";

/* Shared premium card renderer — used by debit/credit (this file) and
   virtual cards (services/virtual-cards.js). Returns the inner front+back
   faces to be dropped inside a .vcard element.
   opts:
     type          "debit" | "credit" | "virtual"
     holder        card-holder name shown on the front (already display-cased)
     signature     name for the back signature strip (natural case)
     number        card number string (masked or revealed, may be pre-formatted)
     expiry        "MM/YY"
     cvv           cvv string or a placeholder like "•••"
     frozen        boolean — shows the Frozen flag + dims via .frozen scene
     network       short network mark, default "CB"
     tier          tier label under the bank name
     numberId      optional id for the number <span>
     revealBtnHtml optional HTML for the reveal button (real cards only)
     note          fine-print text on the back
*/
function premiumCardFaces(opts) {
  const o = opts || {};
  const type = o.type || "debit";
  const typeLabel = { debit: "Debit", credit: "Credit", virtual: "Virtual" }[type] || "Card";
  const network = o.network || "CB";
  const tier = o.tier || (type === "credit" ? "Platinum" : type === "virtual" ? "Virtual" : "Classic");
  const holder = o.holder || "";
  const signature = o.signature || holder;
  const numberIdAttr = o.numberId ? ` id="${o.numberId}"` : "";
  const number = o.number != null ? o.number : "";
  const revealBtnHtml = o.revealBtnHtml || "";
  const note = o.note || `This card is property of ${CARD_BANK_NAME} and must be returned upon request. Use of this card is subject to the cardholder agreement.`;
  return `
    <div class="vcard-face front premium ${type}">
      ${o.frozen ? `<div class="vcard-status-flag">Frozen</div>` : ""}
      <div class="pc-guilloche"></div>
      <div class="pc-sheen"></div>
      <div class="pc-inner">
        <div class="pc-top">
          <div class="pc-bank">
            <div class="pc-mark"><svg viewBox="0 0 24 24" fill="none"><path d="M4 15a5 5 0 0 1 1-9.9A6 6 0 0 1 17 7a4.5 4.5 0 0 1-1 8.9H4Z" fill="white" opacity=".92"/></svg></div>
            <div>
              <div class="pc-bank-name">${CARD_BANK_NAME}</div>
              <div class="pc-tier">${tier}</div>
            </div>
          </div>
          <div class="pc-top-right">
            <span class="pc-type-tag">${typeLabel}</span>
            <svg class="pc-contactless" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
              <path d="M7 18c3-5 3-11 0-14" opacity=".35"/>
              <path d="M10.6 18c2.2-4.6 2.2-9.4 0-14" opacity=".6"/>
              <path d="M14.2 18c1.4-4.6 1.4-9.4 0-14"/>
            </svg>
          </div>
        </div>
        <div class="pc-mid">
          <div class="pc-chip"></div>
          <div class="vcard-number"><span${numberIdAttr}>${number}</span>${revealBtnHtml}</div>
        </div>
        <div class="pc-bottom">
          <div class="pc-field"><div class="pc-label">Card holder</div><div class="pc-name">${holder}</div></div>
          <div class="pc-field right"><div class="pc-label">Valid thru</div><div class="pc-expiry">${o.expiry || ""}</div></div>
          <div class="pc-netwrap">
            <div class="pc-dual"><span class="c c1"></span><span class="c c2"></span></div>
            <div class="pc-network">${network}</div>
          </div>
        </div>
      </div>
    </div>
    <div class="vcard-face back premium">
      <div class="pc-back-inner">
        <div class="pc-magstripe"></div>
        <div class="pc-back-body">
          <div class="pc-sig-row">
            <div class="pc-sig-panel"><span class="pc-sig-script">${signature}</span></div>
            <div class="pc-cvv-box">${o.cvv != null ? o.cvv : "•••"}</div>
          </div>
          <p class="pc-fine">${note}</p>
          <div class="pc-back-footer">
            <div>
              <span class="pc-type-tag" style="display:inline-block; margin-bottom:6px;">${typeLabel} Card</span>
              <div class="pc-support">24/7 support&nbsp; +1 800 555 0134<br/>cloudbank.example / support</div>
            </div>
            <div style="display:flex; align-items:center; gap:10px;">
              <div class="pc-holo"></div>
              <div class="pc-dual"><span class="c c1"></span><span class="c c2"></span></div>
              <div class="pc-network" style="font-size:14px;">${network}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  `;
}

/* Pointer-follow tilt shared by every .vcard-scene on the page.
   Registered once; works for cards rendered later (delegated on document). */
function initCardTilt() {
  if (window.__cardTiltInit) return;
  window.__cardTiltInit = true;
  document.addEventListener("mousemove", (e) => {
    const scene = e.target.closest ? e.target.closest(".vcard-scene") : null;
    if (!scene || scene.classList.contains("frozen")) return;
    const card = scene.querySelector(".vcard");
    if (!card) return;
    const r = scene.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width - 0.5;
    const y = (e.clientY - r.top) / r.height - 0.5;
    card.style.setProperty("--ry", (x * 18) + "deg");
    card.style.setProperty("--rx", (y * -14) + "deg");
  });
  document.addEventListener("mouseout", (e) => {
    const scene = e.target.closest ? e.target.closest(".vcard-scene") : null;
    if (!scene || (e.relatedTarget && scene.contains(e.relatedTarget))) return;
    const card = scene.querySelector(".vcard");
    if (card) { card.style.setProperty("--ry", "0deg"); card.style.setProperty("--rx", "0deg"); }
  });
}

function cardFacesHtml(c, idPrefix) {
  const revealed = revealedCards[c.id];
  const number = revealed ? formatCardNumber(revealed.card_number) : c.card_number_masked;
  const cvv = revealed ? revealed.cvv : "•••";
  const frozen = c.status !== "active";
  const revealBtn = `<button class="vcard-reveal-btn" title="${revealed ? 'Hide number' : 'Reveal number'}" onclick="toggleReveal('${c.id}', event)">${revealed ? '🙈' : '👁'}</button>`;
  return premiumCardFaces({
    type: c.card_type,
    holder: (currentUser.full_name || "").toUpperCase(),
    signature: currentUser.full_name || "",
    number,
    expiry: c.expiry,
    cvv,
    frozen,
    network: "CB",
    tier: c.card_type === "credit" ? "Platinum" : "Classic",
    numberId: `${idPrefix}-number-${c.id}`,
    revealBtnHtml: revealBtn,
    note: `This card is property of ${CARD_BANK_NAME} and is issued to the account holder above. Tap the front to flip back. For lost or stolen cards, freeze it instantly from the app.`,
  });
}
function renderVirtualCard(c) {
  const frozen = c.status !== "active";
  return `
    <div>
      <div class="vcard-scene ${frozen ? 'frozen' : ''}">
        <div class="vcard" id="vcard-${c.id}" onclick="flipCard('${c.id}', event)">
          ${cardFacesHtml(c, "vcard")}
        </div>
      </div>
      <div class="vcard-meta-row">
        <span class="badge">${c.card_type}</span>
        <div class="split" style="gap:8px;">
          <button class="btn ghost sm" onclick="openCardView('${c.id}', event)">View</button>
          <button class="btn ghost sm" onclick="doToggleCard('${c.id}','${c.status}', event)">${frozen ? 'Unfreeze' : 'Freeze'}</button>
        </div>
      </div>
    </div>
  `;
}
function openCardView(id, evt) {
  if (evt) evt.stopPropagation();
  const c = cardsCache[id];
  if (!c) return;
  const wrap = document.createElement("div");
  wrap.className = "card-view-backdrop";
  wrap.id = "card-view-backdrop";
  wrap.onclick = (e) => { if (e.target === wrap) closeCardView(); };
  wrap.innerHTML = `
    <div class="card-view-inner">
      <button class="card-view-close" onclick="closeCardView()">✕</button>
      <div class="vcard-scene ${c.status !== 'active' ? 'frozen' : ''}">
        <div class="vcard" id="vcardview-${c.id}" onclick="this.classList.toggle('flipped')">
          ${cardFacesHtml(c, "vcardview")}
        </div>
      </div>
      <div class="card-view-actions">
        <button class="btn ghost sm" onclick="toggleReveal('${c.id}', event)">Reveal number</button>
        <button class="btn ghost sm" onclick="document.getElementById('vcardview-${c.id}').classList.toggle('flipped')">Flip card</button>
      </div>
    </div>
  `;
  document.body.appendChild(wrap);
  playModalIn("#card-view-backdrop");
  initCardTilt();
}
function refreshCardView(id) {
  // toggleReveal() re-renders the card wall (loadCards); after that
  // finishes, resync the big-screen view's faces with the same state.
  setTimeout(() => {
    const scene = document.getElementById(`vcardview-${id}`);
    const c = cardsCache[id];
    if (scene && c) scene.innerHTML = cardFacesHtml(c, "vcardview");
  }, 50);
}
function closeCardView() {
  const el = document.getElementById("card-view-backdrop");
  if (el) el.remove();
}
function formatCardNumber(n) {
  return (n || "").replace(/(.{4})/g, "$1 ").trim();
}
function flipCard(id, evt) {
  if (evt) evt.stopPropagation();
  document.getElementById(`vcard-${id}`).classList.toggle("flipped");
}
async function toggleReveal(id, evt) {
  if (evt) evt.stopPropagation();
  if (revealedCards[id]) {
    delete revealedCards[id];
    loadCards();
    refreshCardView(id);
    return;
  }
  try {
    const full = await api(`/cards/${id}/reveal/${currentUser.user_id}`);
    revealedCards[id] = full;
    loadCards();
    refreshCardView(id);
  } catch (e) { toast(e.message, false); }
}
async function doToggleCard(id, status, evt) {
  if (evt) evt.stopPropagation();
  try { await api(`/cards/${id}/${status === 'active' ? 'freeze' : 'unfreeze'}`, { method: "PATCH" }); toast("Card updated."); loadCards(); }
  catch (e) { toast(e.message, false); }
}
