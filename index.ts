// Sends one queued text through Telnyx. Called by a Database Webhook whenever a row is inserted into sms_queue.
// Secrets needed (Edge Functions -> Secrets): TELNYX_API_KEY, TELNYX_FROM (e.g. +16195550123), WEBHOOK_SECRET.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// Turns "(619) 555-0123", "619-555-0123" or "1 619 555 0123" into +16195550123.
function toE164(raw: string): string | null {
  const digits = (raw ?? "").replace(/\D/g, "");
  if (digits.length === 10) return "+1" + digits;
  if (digits.length === 11 && digits.startsWith("1")) return "+" + digits;
  return null;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  const { record } = await req.json();
  if (!record?.id || record.sent_at) return new Response("nothing to send");

  let error: string | null = null;
  const to = toE164(record.phone);
  if (!to) {
    error = "Not a valid US phone number: " + record.phone;
  } else {
    const res = await fetch("https://api.telnyx.com/v2/messages", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${Deno.env.get("TELNYX_API_KEY")}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from: Deno.env.get("TELNYX_FROM"), to, text: record.body }),
    });
    if (!res.ok) error = `Telnyx ${res.status}: ${(await res.text()).slice(0, 300)}`;
  }

  // Record the outcome so failures are visible in the sms_queue table.
  await sb.from("sms_queue")
    .update(error ? { error } : { sent_at: new Date().toISOString(), error: null })
    .eq("id", record.id);
  return new Response(error ?? "sent");
});
