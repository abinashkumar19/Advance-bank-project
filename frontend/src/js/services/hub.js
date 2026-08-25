/* ---------------- Services hub — categorized directory of all 26 pages ---------------- */
const SERVICE_PAGES = {
  cards: renderCards, loans: renderLoans, payments: renderPayments, beneficiaries: renderBeneficiaries,
  statements: renderStatements, notifications: renderNotifications, kyc: renderKyc, "fixed-deposits": renderFixedDeposits,
  cheques: renderCheques, disputes: renderDisputes, "audit-log": renderAuditLog, "fraud-detection": renderFraudDetection,
  "support-tickets": renderSupportTickets, rewards: renderRewards, admin: renderAdmin, reports: renderReports,
  "recurring-payments": renderRecurringPayments, "bill-payments": renderBillPayments, insurance: renderInsurance,
  budgeting: renderBudgeting, "virtual-cards": renderVirtualCards, goals: renderGoals, webhooks: renderWebhooks,
  "admin-analytics": renderAdminAnalytics, lockers: renderLockers, forex: renderForex,
};
const SERVICE_GROUPS = {
  "Banking": ["cards","loans","fixed-deposits","cheques","virtual-cards","lockers"],
  "Money movement": ["payments","beneficiaries","statements","recurring-payments","bill-payments","forex"],
  "Grow & protect": ["goals","insurance","budgeting","rewards"],
  "Account care": ["notifications","kyc","disputes","support-tickets"],
  "Operations": ["audit-log","fraud-detection","admin","admin-analytics","reports","webhooks"],
};
const SERVICE_GROUP_DESC = {
  "Banking": "Cards, loans, deposits and secure storage",
  "Money movement": "Send, pay and convert money across accounts",
  "Grow & protect": "Save toward goals and cover what matters",
  "Account care": "Identity, alerts and issue resolution",
  "Operations": "Logs, risk monitoring and admin controls",
};
/* Real label + one-line description per service, instead of deriving
   text from the URL key (that approach mangled acronyms like KYC into
   "Kyc" via CSS text-transform:capitalize, and gave every tile the same
   generic "Open <name>" description). */
const SERVICE_META = {
  cards: { label: "Cards", desc: "Manage your debit and credit cards" },
  loans: { label: "Loans", desc: "Apply for and track personal loans" },
  payments: { label: "Payments", desc: "Send one-off payments to a payee" },
  beneficiaries: { label: "Beneficiaries", desc: "Saved payees for faster transfers" },
  statements: { label: "Statements", desc: "Download monthly account statements" },
  notifications: { label: "Notifications", desc: "Account activity and alerts" },
  kyc: { label: "KYC", desc: "Identity verification status and documents" },
  "fixed-deposits": { label: "Fixed Deposits", desc: "Lock in savings at a fixed interest rate" },
  cheques: { label: "Cheques", desc: "Request and track cheque books" },
  disputes: { label: "Disputes", desc: "Flag and follow up on incorrect charges" },
  "audit-log": { label: "Audit Log", desc: "Full history of account changes" },
  "fraud-detection": { label: "Fraud Detection", desc: "Flagged transactions and risk alerts" },
  "support-tickets": { label: "Support Tickets", desc: "Get help from the Cloud Bank team" },
  rewards: { label: "Rewards", desc: "Points balance and redeemable perks" },
  admin: { label: "Admin", desc: "Account and user management (staff)" },
  reports: { label: "Reports", desc: "Spending and balance summaries" },
  "recurring-payments": { label: "Recurring Payments", desc: "Autopay for rent, SIPs and EMIs" },
  "bill-payments": { label: "Bill Payments", desc: "Electricity, mobile, DTH and broadband" },
  insurance: { label: "Insurance", desc: "Life, health, vehicle and home cover" },
  budgeting: { label: "Budgeting", desc: "Category limits and monthly spend insights" },
  "virtual-cards": { label: "Virtual Cards", desc: "Single-use and merchant-locked cards" },
  goals: { label: "Goals", desc: "Save toward something specific" },
  webhooks: { label: "Webhooks", desc: "Send account events to your own endpoint" },
  "admin-analytics": { label: "Admin Analytics", desc: "Bank-wide overview for staff" },
  lockers: { label: "Lockers", desc: "Reserve a safe deposit box at a branch" },
  forex: { label: "Forex", desc: "Buy foreign currency at today's rate" },
};
function renderServices() {
  const main = document.getElementById("main");
  main.innerHTML = pageHeader("Services", "Every Cloud Bank feature") +
    Object.entries(SERVICE_GROUPS).map(([group, list]) => `
      <div class="section-title" style="margin-top:28px;">${group}<span class="section-subtitle">${SERVICE_GROUP_DESC[group] || ""}</span></div>
      <div class="grid cols-3">
        ${list.map(s => {
          const meta = SERVICE_META[s] || { label: s, desc: `Open ${s.replace(/-/g, " ")}` };
          return `
          <button class="card fade-in svc-tile" onclick="currentTab='${s}'; render();">
            <div class="icon">${SERVICE_ICONS[s] || '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3l9 9-9 9-9-9 9-9Z"/></svg>'}</div>
            <h2>${meta.label}</h2>
            <p class="hint">${meta.desc}</p>
            <span class="svc-tile-arrow">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12h14M13 6l6 6-6 6"/></svg>
            </span>
          </button>
        `;}).join("")}
      </div>
    `).join("");
}
