// Single-machine append benchmark for durable-streams durability modes, with a
// CARDINALITY LADDER (scale the number of streams).
// Usage: BASE=http://127.0.0.1:4438 LABEL=wal CARD=1000,10000,100000 CONC=256 \
//        DURATION_MS=8000 node bench-durability.mjs
const BASE = process.env.BASE || "http://127.0.0.1:4438"
const LABEL = process.env.LABEL || "?"
const DURATION_MS = +(process.env.DURATION_MS || 8000)
const CONC = +(process.env.CONC || 256)
const CREATE_CONC = +(process.env.CREATE_CONC || 256)
const PAYLOAD = "x".repeat(+(process.env.PAYLOAD || 256))
const CARD = (process.env.CARD || "1000,10000,100000").split(",").map(s => +s.trim()).filter(Boolean)
const BODY = JSON.stringify({ p: PAYLOAD })

function pct(arr, p) { if (!arr.length) return 0; const s = [...arr].sort((a,b)=>a-b); return s[Math.min(s.length-1, Math.floor(s.length*p))] }

async function req(method, stream, body) {
  const ac = new AbortController(); const t = setTimeout(() => ac.abort(), 15000)
  try { return await fetch(`${BASE}/${stream}`, { method, headers: { "content-type": "application/json" }, body, signal: ac.signal }) }
  finally { clearTimeout(t) }
}

// Create `names` with a bounded-concurrency pool. Returns {ok, err, secs}.
async function createMany(names) {
  let i = 0, ok = 0, err = 0
  const t0 = Date.now()
  async function w() { while (i < names.length) { const n = names[i++]; try { const r = await req("PUT", n); (r.status < 500 ? ok++ : err++) } catch { err++ } } }
  await Promise.all(Array.from({ length: CREATE_CONC }, w))
  return { ok, err, secs: (Date.now() - t0) / 1000 }
}

async function appendLoad(names) {
  const lat = []; let ops = 0, errs = 0, rr = 0
  const end = Date.now() + DURATION_MS
  async function w() {
    while (Date.now() < end) {
      const s = names[(rr++) % names.length]
      const t0 = performance.now()
      try { const r = await req("POST", s, BODY); if (r.status >= 300) { errs++; continue } lat.push(performance.now() - t0); ops++ }
      catch { errs++ }
    }
  }
  const t0 = Date.now()
  await Promise.all(Array.from({ length: CONC }, w))
  const secs = (Date.now() - t0) / 1000
  return { ops, errs, ops_s: Math.round(ops / secs),
           p50: +pct(lat,0.5).toFixed(2), p99: +pct(lat,0.99).toFixed(2), max: +pct(lat,1).toFixed(2) }
}

console.log(`\n=== ${LABEL}  (${BASE}, conc=${CONC}, ${DURATION_MS/1000}s/scenario, payload=${PAYLOAD.length}B) ===`)
console.log(`card        create               |  append`)
const out = []
await createMany([`bench-${LABEL}-warm-${Date.now()}`])  // tiny warmup
for (const card of CARD) {
  const stamp = Date.now()
  const names = Array.from({ length: card }, (_, i) => `b-${LABEL}-${card}-${i}-${stamp}`)
  const c = await createMany(names)
  if (c.err > card * 0.02) { // >2% create failures → server choking at this cardinality; report + stop ladder
    console.log(`${String(card).padStart(7)}  CREATE FAILED ok=${c.ok} err=${c.err} in ${c.secs.toFixed(1)}s — stopping ladder (server can't hold ${card} streams)`)
    out.push({ card, create_failed: true, create_ok: c.ok, create_err: c.err }); break
  }
  const a = await appendLoad(names)
  console.log(`${String(card).padStart(7)}  ${String(c.ok).padStart(7)} ok in ${String(c.secs.toFixed(1)).padStart(5)}s (${String(Math.round(c.ok/c.secs)).padStart(6)}/s)  |  ${String(a.ops_s).padStart(8)} ops/s  p50=${String(a.p50).padStart(7)}ms  p99=${String(a.p99).padStart(8)}ms  max=${String(a.max).padStart(8)}ms  errs=${a.errs}`)
  out.push({ card, create_ok: c.ok, create_err: c.err, create_s: +c.secs.toFixed(1), ...a })
}
console.log(JSON.stringify({ label: LABEL, conc: CONC, card: CARD, results: out }))
