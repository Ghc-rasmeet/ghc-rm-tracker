/* ===== GHC Hub — shared ===== */
const SUPABASE_URL = "https://smxmxrajahsajuwavzlb.supabase.co";
const SUPABASE_KEY = "sb_publishable_xQ6tkpeP0VVnp53eKVzqBw_UURnzkuW";
const APP_VERSION = "v4.0";
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const $ = id => document.getElementById(id);
const esc = s => (s ?? "").toString().replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmt = d => d ? new Date(d + "T00:00:00").toLocaleDateString("en-IN", {day:"2-digit", month:"short"}) : "—";
const fmtY = d => d ? new Date(d + "T00:00:00").toLocaleDateString("en-IN", {day:"2-digit", month:"short", year:"numeric"}) : "—";
const inr = n => n == null || n === "" ? "—" : "₹" + Number(n).toLocaleString("en-IN", { maximumFractionDigits: 0 });
const today = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`; };
const addDays = (iso, n) => { const d = new Date(iso + "T00:00:00"); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`; };
function toast(msg, ms = 2500){ let t = $("toast"); if (!t){ t = document.createElement("div"); t.id = "toast"; document.body.appendChild(t); } t.textContent = msg; t.classList.remove("hidden"); clearTimeout(t._h); t._h = setTimeout(() => t.classList.add("hidden"), ms); }

async function fetchAll(table, select, order){
  let out = [], from = 0, size = 1000;
  while (true){
    let q = sb.from(table).select(select).range(from, from + size - 1);
    if (order) q = q.order(order.col, { ascending: order.asc ?? true });
    const { data, error } = await q; if (error) throw error;
    out = out.concat(data); if (data.length < size) break; from += size;
  }
  return out;
}

/* Session + access. Returns { me, profile, profiles, access, isMgr, isSuper } or redirects. */
async function requireAuth(moduleKey){
  const { data: { session } } = await sb.auth.getSession();
  if (!session){ location.href = "index.html"; return null; }
  const me = session.user;
  const profiles = await fetchAll("profiles", "id, full_name, role, email");
  const profile = { ...(profiles.find(p => p.id === me.id) || { id: me.id, full_name: me.email, role: "rm" }) };
  const isMgr = profile.role === "manager" || profile.role === "admin";
  const isSuper = profile.role === "admin" || (me.email || "").toLowerCase() === "rasmeet.sethi@greenhedgecapital.com";
  let access = {};
  try { (await fetchAll("user_modules", "user_id, module, level")).filter(r => r.user_id === me.id).forEach(r => access[r.module] = r.level); } catch (e){}
  if (moduleKey && !isMgr && !access[moduleKey]){ alert("You don't have access to this module."); location.href = "index.html"; return null; }
  const level = isMgr ? "edit" : (access[moduleKey] || "view");
  return { me, profile, profiles, access, isMgr, isSuper, level };
}
function shellHeader(title, ctx){
  const el = document.querySelector("header .bar"); if (!el) return;
  el.innerHTML = `<div class="brand"><a href="index.html" style="color:var(--green);text-decoration:none">GHC Hub</a> <span style="color:var(--muted);font-weight:400">/</span> ${esc(title)} <span style="color:var(--muted);font-weight:400;font-size:12px">· ${APP_VERSION}</span></div>
    <div class="spacer"></div><div class="who">${esc(ctx.profile.full_name)} · ${ctx.isSuper ? "Super admin" : ctx.isMgr ? "Manager" : "User"}</div>
    <a class="btn ghost small" href="index.html" style="text-decoration:none">Home</a>
    <button class="btn ghost small" id="logout">Sign out</button>`;
  $("logout").onclick = async () => { await sb.auth.signOut(); location.href = "index.html"; };
}
