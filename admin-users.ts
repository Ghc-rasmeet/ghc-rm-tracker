// Supabase Edge Function: admin-users
// Deploy: Supabase → Edge Functions → Deploy new function → Via Editor → name "admin-users" → paste → Deploy
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!, service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const caller = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
  const { data: { user } } = await caller.auth.getUser();
  if (!user) return json({ error: "not signed in" }, 401);
  const admin = createClient(url, service);
  const { data: prof } = await admin.from("profiles").select("role").eq("id", user.id).single();
  if (prof?.role !== "manager" && prof?.role !== "admin") return json({ error: "managers only" }, 403);
  const b = await req.json();
  try {
    if (b.action === "create") {
      const { data, error } = await admin.auth.admin.createUser({ email: b.email, password: b.password, email_confirm: true, user_metadata: { full_name: b.full_name } });
      if (error) throw error;
      await admin.from("profiles").update({ full_name: b.full_name, role: b.role || "rm", email: b.email }).eq("id", data.user.id);
      return json({ ok: true });
    }
    if (b.action === "password") { const { error } = await admin.auth.admin.updateUserById(b.id, { password: b.password }); if (error) throw error; return json({ ok: true }); }
    if (b.action === "update")   { const { error } = await admin.from("profiles").update({ full_name: b.full_name, role: b.role }).eq("id", b.id); if (error) throw error; return json({ ok: true }); }
    if (b.action === "delete") {
      await admin.from("clients").update({ rm_id: null }).eq("rm_id", b.id);
      await admin.from("touches").update({ rm_id: user.id }).eq("rm_id", b.id);
      await admin.from("reviews").update({ rm_id: user.id }).eq("rm_id", b.id);
      const { error } = await admin.auth.admin.deleteUser(b.id); if (error) throw error; return json({ ok: true });
    }
    return json({ error: "unknown action" }, 400);
  } catch (e) { return json({ error: (e as Error).message }, 400); }
});
