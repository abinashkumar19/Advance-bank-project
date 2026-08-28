let gateScreen = "auth"; // "auth" (login/register tabs) | "verify" (its own standalone screen)

function renderGate() {
  if (gateScreen === "verify") return renderVerifyGate();

  document.getElementById("app").innerHTML = `
    <div class="gate">
      <div class="gate-orbit o1" style="color:var(--violet)"><div class="dot" style="background:var(--violet)"></div></div>
      <div class="gate-orbit o2" style="color:var(--ledger)"><div class="dot" style="background:var(--ledger)"></div></div>
      <div class="gate-card">
        <div class="gate-badge">C</div>
        <div class="gate-heading">
          <h1>Cloud<span style="background:linear-gradient(90deg, var(--violet), var(--ledger)); -webkit-background-clip:text; background-clip:text; color:transparent;">Bank</span></h1>
          <p>${authTab === 'login' ? 'Sign in to your account' : 'Open a Cloud Bank account'}</p>
        </div>
        <div class="gate-chips">
          <span>Cloud-native</span><span>31 services</span><span>EKS-secured</span>
        </div>
        <div class="tabs">
          <button class="${authTab==='login'?'active':''}" onclick="setAuthTab('login')">Login</button>
          <button class="${authTab==='register'?'active':''}" onclick="setAuthTab('register')">Register</button>
        </div>
        <div class="gate-form" id="auth-body"></div>
      </div>
    </div>
  `;
  renderAuthBody();
  if (hasGsap()) gsap.fromTo(".gate-card", { opacity: 0, y: 26, scale: .97 }, { opacity: 1, y: 0, scale: 1, duration: .6, ease: "power3.out" });
}

function renderVerifyGate() {
  document.getElementById("app").innerHTML = `
    <div class="gate">
      <div class="gate-orbit o1" style="color:var(--violet)"><div class="dot" style="background:var(--violet)"></div></div>
      <div class="gate-orbit o2" style="color:var(--ledger)"><div class="dot" style="background:var(--ledger)"></div></div>
      <div class="gate-card">
        <div class="otp-envelope">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="2.5" y="5" width="19" height="14" rx="2.5"/><path d="M3 6.5l9 6.2 9-6.2"/></svg>
          <div class="otp-envelope-pulse"></div>
          <div class="otp-envelope-pulse p2"></div>
        </div>
        <div class="gate-heading">
          <h1>Verify your <span style="background:linear-gradient(90deg, var(--violet), var(--ledger)); -webkit-background-clip:text; background-clip:text; color:transparent;">email</span></h1>
          <p>Enter the 6-digit code we sent to <strong>${regDraft.email}</strong></p>
        </div>
        <div class="gate-form">
          <div class="otp-boxes" id="otp-boxes">
            ${[0,1,2,3,4,5].map(i => `<input class="otp-digit" id="r_otp_${i}" data-i="${i}" inputmode="numeric" maxlength="1" autocomplete="one-time-code" placeholder=" " />`).join("")}
          </div>
          <div id="r_msg"></div>
          <button class="btn gold" id="otp-verify-btn" style="width:100%; margin-top:18px;" onclick="verifyRegistrationOtp()">Verify & create account</button>
          <div class="otp-resend" id="otp-resend"></div>
          <button type="button" class="btn ghost sm" style="width:100%; margin-top:10px;" onclick="resetRegistrationOtp()">Use a different email</button>
        </div>
      </div>
    </div>
  `;
  if (hasGsap()) {
    gsap.fromTo(".gate-card", { opacity: 0, y: 26, scale: .97 }, { opacity: 1, y: 0, scale: 1, duration: .6, ease: "power3.out" });
    gsap.fromTo(".otp-digit", { opacity: 0, y: 10 }, { opacity: 1, y: 0, duration: .35, stagger: .05, delay: .15, ease: "power2.out" });
  }
  initOtpBoxes();
  startResendTimer();
}

/* ---------------- OTP boxes: auto-advance, backspace nav, paste, auto-submit ---------------- */
function initOtpBoxes() {
  const boxes = Array.from(document.querySelectorAll(".otp-digit"));
  boxes.forEach((box, i) => {
    box.addEventListener("input", () => {
      clearOtpState();
      box.value = box.value.replace(/\D/g, "").slice(-1);
      if (box.value && i < boxes.length - 1) boxes[i + 1].focus();
      maybeAutoSubmit(boxes);
    });
    box.addEventListener("keydown", (e) => {
      if (e.key === "Backspace" && !box.value && i > 0) {
        boxes[i - 1].focus();
        boxes[i - 1].value = "";
      }
      if (e.key === "ArrowLeft" && i > 0) boxes[i - 1].focus();
      if (e.key === "ArrowRight" && i < boxes.length - 1) boxes[i + 1].focus();
      if (e.key === "Enter") verifyRegistrationOtp();
    });
    box.addEventListener("paste", (e) => {
      e.preventDefault();
      const digits = (e.clipboardData.getData("text") || "").replace(/\D/g, "").slice(0, boxes.length).split("");
      digits.forEach((d, j) => { if (boxes[j]) boxes[j].value = d; });
      const next = boxes[Math.min(digits.length, boxes.length - 1)];
      next.focus();
      maybeAutoSubmit(boxes);
    });
  });
  boxes[0].focus();
}
function otpCode() {
  return Array.from(document.querySelectorAll(".otp-digit")).map(b => b.value).join("");
}
function maybeAutoSubmit(boxes) {
  if (boxes.every(b => b.value)) verifyRegistrationOtp();
}
function shakeOtpBoxes() {
  const el = document.getElementById("otp-boxes");
  if (!el) return;
  el.classList.remove("shake");
  void el.offsetWidth; // restart animation
  el.classList.add("shake");
}
function markOtpError() {
  const el = document.getElementById("otp-boxes");
  if (!el) return;
  el.classList.remove("verified");
  el.classList.add("error");
  shakeOtpBoxes();
}
function markOtpVerified() {
  const el = document.getElementById("otp-boxes");
  if (!el) return;
  el.classList.remove("error", "shake");
  el.classList.add("verified");
}
function clearOtpState() {
  const el = document.getElementById("otp-boxes");
  if (!el) return;
  el.classList.remove("error", "verified", "shake");
}

/* ---------------- Resend timer ---------------- */
let resendTimerId = null;
function startResendTimer() {
  clearInterval(resendTimerId);
  let secondsLeft = 45;
  const el = document.getElementById("otp-resend");
  const tick = () => {
    if (!el) return;
    if (secondsLeft > 0) {
      el.innerHTML = `Resend code in 0:${String(secondsLeft).padStart(2, "0")}`;
      secondsLeft--;
    } else {
      el.innerHTML = `<a href="javascript:void(0)" onclick="resendOtp()">Resend code</a>`;
      clearInterval(resendTimerId);
    }
  };
  tick();
  resendTimerId = setInterval(tick, 1000);
}
async function resendOtp() {
  const el = document.getElementById("r_msg");
  try {
    await api("/users/otp/send", { method: "POST", body: JSON.stringify({ email: regDraft.email, purpose: "signup" }) });
    toast("New code sent.");
    startResendTimer();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
function setAuthTab(t){ authTab = t; renderGate(); }

function renderAuthBody() {
  const el = document.getElementById("auth-body");
  if (authTab === "login") {
    el.innerHTML = `
      <label>Email</label><input id="l_email" type="email" placeholder="you@cloudbank.com" />
      <label>Password</label><input id="l_password" type="password" placeholder="••••••••" />
      <button class="btn" style="width:100%" onclick="doLogin()">Sign in</button>
      <div id="l_msg"></div>
    `;
  } else {
    el.innerHTML = `
      <label>Full name</label><input id="r_name" placeholder="Ada Lovelace" value="${regDraft.full_name || ""}" />
      <label>Email</label><input id="r_email" type="email" placeholder="you@cloudbank.com" value="${regDraft.email || ""}" />
      <label>Phone</label><input id="r_phone" placeholder="+1 555 000 1234" value="${regDraft.phone || ""}" />
      <label>Password</label><input id="r_password" type="password" placeholder="Create a password" value="${regDraft.password || ""}" />
      <button class="btn gold" style="width:100%" onclick="startRegistration()">Send verification code</button>
      <div id="r_msg"></div>
    `;
  }
}

let regDraft = {};

async function startRegistration() {
  const el = document.getElementById("r_msg");
  try {
    regDraft = {
      full_name: document.getElementById("r_name").value,
      email: document.getElementById("r_email").value,
      phone: document.getElementById("r_phone").value,
      password: document.getElementById("r_password").value,
    };
    if (!regDraft.full_name || !regDraft.email || !regDraft.phone || !regDraft.password) {
      throw new Error("Fill in every field first.");
    }
    await api("/users/otp/send", { method: "POST", body: JSON.stringify({ email: regDraft.email, purpose: "signup" }) });
    gateScreen = "verify";
    renderGate();
    toast("Verification code sent to your email.");
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}

function resetRegistrationOtp() {
  clearInterval(resendTimerId);
  gateScreen = "auth";
  renderGate();
}

async function verifyRegistrationOtp() {
  const el = document.getElementById("r_msg");
  const btn = document.getElementById("otp-verify-btn");
  const originalLabel = btn ? btn.innerHTML : "";
  if (btn) { btn.disabled = true; btn.innerHTML = `<span class="btn-spinner"></span>Verifying…`; }
  try {
    const code = otpCode();
    if (code.length < 6) throw new Error("Enter all 6 digits.");
    await api("/users/otp/verify", { method: "POST", body: JSON.stringify({ email: regDraft.email, code, purpose: "signup" }) });

    // OTP accepted — flip the boxes green before proceeding
    markOtpVerified();

    let user;
    try {
      user = await api("/users/register", { method: "POST", body: JSON.stringify(regDraft) });
    } catch (registerErr) {
      // The OTP is already verified and consumed at this point. If /register
      // fails after the account was actually created server-side (e.g. a
      // notification/email step throwing after the DB write succeeded),
      // retrying this same screen is a dead end: the OTP record is gone, so
      // a second click would only ever surface a confusing "No code was
      // sent to this email". Fall back to logging in with the credentials
      // the user just submitted before showing any error.
      try {
        user = await api("/users/login", { method: "POST", body: JSON.stringify({ email: regDraft.email, password: regDraft.password }) });
      } catch (loginErr) {
        throw registerErr; // account genuinely wasn't created - surface the original error
      }
    }

    clearInterval(resendTimerId);
    setUser(user);
    toast("Account created — welcome to Cloud Bank.");
    gateScreen = "auth";
    regDraft = {};
    currentTab = "dashboard";
    afterAuth();
  } catch (e) {
    el.innerHTML = `<div class="msg err">${e.message}</div>`;
    markOtpError();
    if (btn) { btn.disabled = false; btn.innerHTML = originalLabel; }
  }
}
async function doLogin() {
  const el = document.getElementById("l_msg");
  try {
    const body = {
      email: document.getElementById("l_email").value,
      password: document.getElementById("l_password").value,
    };
    const user = await api("/users/login", { method: "POST", body: JSON.stringify(body) });
    setUser(user);
    toast(`Welcome back, ${user.full_name.split(" ")[0]}.`);
    currentTab = "dashboard";
    afterAuth();
  } catch (e) { el.innerHTML = `<div class="msg err">${e.message}</div>`; }
}
function doLogout(){ setUser(null); render(); }

/* After every successful login/register, check whether this person has
   an account yet - if not, take them straight to the dashboard AND pop
   the "open your account" modal on top of it, instead of dropping them
   on an empty dashboard with no explanation. See js/onboarding.js. */
async function afterAuth() {
  await render();
  try {
    const accounts = await fetchMyAccounts();
    if (!accounts.length) openOnboarding();
  } catch (e) {}
}
