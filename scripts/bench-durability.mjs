// Quick single-machine append benchmark for durable-streams durability modes.
// Usage: BASE=http://127.0.0.1:4438 LABEL=wal node bench-durability.mjs
// Drives: single-stream (per-op fsync tax) + multi-stream(10) (cardinality) append load.
const BASE = process.env.BASE || "http://127.0.0.1:4438"
const LABEL = process.env.LABEL || "?"
const DURATION_MS = +(process.env.DURATION_MS || 6000)
const PAYLOAD = "x".repeat(+(process.env.PAYLOAD || 256))

async function put(stream) {
  const r = await fetch(`${BASE}/${stream}`, { method: "PUT", headers: { "content-type": "application/json" } })
  if (r.status >= 500) throw new Error(`PUT ${stream} → ${r.status}`)
}
function pct(arr, p) { if (!arr.length) return 0; const s = [...arr].sort((a,b)=>a-b); return s[Math.min(s.length-1, Math.floor(s.length*p))] }

// One scenario: `streams` distinct streams, `conc` concurrent workers appending round-robin.
async function scenario(name, streams, conc) {
  const names = Array.from({length: streams}, (_,i) => `bench-${LABEL}-${name}-${i}-${Date.now()}`)
  for (const s of names) await put(s)
  const lat = []; let ops = 0; let errs = 0
  const end = Date.now() + DURATION_MS
  const body = JSON.stringify({ p: PAYLOAD })
  let rr = 0
  async function worker() {
    while (Date.now() < end) {
      const s = names[(rr++) % names.length]
      const t0 = performance.now()
      try {
        const r = await fetch(`${BASE}/${s}`, { method: "POST", headers: { "content-type": "application/json" }, body })
        if (r.status >= 300) { errs++; continue }
        lat.push(performance.now() - t0); ops++
      } catch { errs++ }
    }
  }
  const t0 = Date.now()
  await Promise.all(Array.from({length: conc}, worker))
  const secs = (Date.now() - t0) / 1000
  return { name, streams, conc, ops, errs, ops_s: Math.round(ops/secs),
           p50: +pct(lat,0.5).toFixed(2), p99: +pct(lat,0.99).toFixed(2), max: +pct(lat,1).toFixed(2) }
}

const out = []
// warmup
await scenario("warmup", 1, 16)
out.push(await scenario("single-stream-c1",  1, 1))   // per-op fsync tax, no concurrency (spec §14c micro)
out.push(await scenario("single-stream-c64", 1, 64))  // contended single stream
out.push(await scenario("multi-10-c64",     10, 64))  // 10-stream cardinality
out.push(await scenario("multi-100-c128",  100, 128)) // 100-stream cardinality
console.log(`\n=== ${LABEL}  (${BASE}, ${DURATION_MS/1000}s/scenario, payload=${PAYLOAD.length}B) ===`)
for (const r of out) console.log(
  `${r.name.padEnd(20)} streams=${String(r.streams).padStart(3)} conc=${String(r.conc).padStart(3)}  ` +
  `${String(r.ops_s).padStart(8)} ops/s  p50=${String(r.p50).padStart(6)}ms  p99=${String(r.p99).padStart(7)}ms  max=${String(r.max).padStart(7)}ms  errs=${r.errs}`)
console.log(JSON.stringify({ label: LABEL, results: out }))
