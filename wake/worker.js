// Wakes the Fly machine when the Cloudflare Tunnel is down.
//
// Route this Worker on the same hostname as the tunnel (see wrangler.toml), with a
// Cloudflare Access policy on that hostname. Requests pass straight through to the
// tunnel while the app is up. When the tunnel is down (Cloudflare answers 530, or
// 502/503/504), the Worker asks Fly to start the machine and returns a small page
// that reloads itself until the app is back.
//
// Variables: FLY_APP (plain var), FLY_API_TOKEN (secret, see README.md).

const DOWN = new Set([502, 503, 504, 530]);
const API = "https://api.machines.dev/v1";

async function startMachine(env) {
  const headers = { Authorization: `Bearer ${env.FLY_API_TOKEN}` };
  const res = await fetch(`${API}/apps/${env.FLY_APP}/machines`, { headers });
  if (!res.ok) return `fly list failed: ${res.status}`;
  const machines = await res.json();
  // One machine only (SQLite + one volume). Start it if it is stopped or suspended.
  const m = machines.find((x) => x.state === "stopped" || x.state === "suspended");
  if (!m) return "no stopped machine (already starting?)";
  const start = await fetch(`${API}/apps/${env.FLY_APP}/machines/${m.id}/start`, {
    method: "POST",
    headers,
  });
  return start.ok ? "started" : `fly start failed: ${start.status}`;
}

const WAKING_PAGE = `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>Waking up</title>
<body style="font-family: system-ui, sans-serif; max-width: 28rem; margin: 20vh auto; padding: 0 1rem; text-align: center">
<h1>Waking up…</h1>
<p>Audiobookshelf was asleep. This page reloads every few seconds and takes about a minute.</p>
</body>`;

export default {
  async fetch(request, env) {
    let res;
    try {
      res = await fetch(request);
    } catch {
      res = new Response(null, { status: 530 });
    }
    if (!DOWN.has(res.status)) return res;

    // Only wake for requests that came through Cloudflare Access. This is a cheap
    // extra check; the Access policy on the hostname is what keeps strangers out.
    if (!request.headers.get("Cf-Access-Jwt-Assertion")) return res;

    const result = await startMachine(env);
    console.log(`wake: ${result}`);
    return new Response(WAKING_PAGE, {
      status: 503,
      headers: { "Content-Type": "text/html; charset=utf-8", "Retry-After": "5" },
    });
  },
};
