#!/usr/bin/env node
// Benchmark a Firecrawl endpoint (self-hosted or cloud) against a list of URLs.
// No dependencies. Needs Node 18+.
//
//   FC_URL=https://scrape.example.com FC_TOKEN=... node bench.mjs --urls urls.txt
//
// Options:
//   --urls <file>         one URL per line, "#" comments allowed (default urls.txt)
//   --concurrency <n>     parallel requests (default 5)
//   --repeat <n>          run the list n times, for load testing (default 1)
//   --label <name>        name used in the output file (default "self")
//   --monthly-cost <n>    server cost per month, to print cost per 1,000 pages
//   --timeout <ms>        per-request timeout (default 60000)
//   --proxy <mode>        Firecrawl proxy mode (default "basic"). Self-hosted has no stealth proxy, and the
//                         API default "auto" turns every 401/403/429 into an opaque "all engines failed"
//                         error. Use "auto" when benchmarking Firecrawl cloud.
//   --insecure            ask the browser to skip TLS checks (only for networks that intercept TLS)
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? def : args[i + 1];
};
const flag = name => args.includes(`--${name}`);

const base = (process.env.FC_URL || "http://localhost:3002").replace(/\/$/, "");
const token = process.env.FC_TOKEN || "unused";
const concurrency = Number(opt("concurrency", 5));
const repeat = Number(opt("repeat", 1));
const label = opt("label", "self");
const timeout = Number(opt("timeout", 60000));
const monthlyCost = opt("monthly-cost") ? Number(opt("monthly-cost")) : null;

const list = readFileSync(opt("urls", "urls.txt"), "utf8")
  .split("\n")
  .map(l => l.trim())
  .filter(l => l && !l.startsWith("#"));
const jobs = Array.from({ length: repeat }, () => list).flat();

// Text that shows up when a site served a challenge or refusal instead of content.
const BLOCK_SIGNS = [
  /just a moment/i,
  /verify(ing)? (that )?you are (a )?human/i,
  /are you a robot/i,
  /checking your browser/i,
  /attention required/i,
  /access denied/i,
  /captcha/i,
  /unusual traffic/i,
  /enable javascript and cookies/i,
  /request blocked/i,
  /pardon our interruption/i,
];

function classify(httpStatus, body) {
  if (httpStatus !== 200 || !body?.success) return "error";
  const md = body.data?.markdown || "";
  const pageStatus = body.data?.metadata?.statusCode;
  const looksBlocked = md.length < 3000 && BLOCK_SIGNS.some(r => r.test(md));
  if ([401, 403, 407, 429, 503].includes(pageStatus) || looksBlocked) return "blocked";
  if (pageStatus >= 400) return "error";
  if (md.length < 200) return "thin";
  return "ok";
}

async function scrape(url) {
  const started = Date.now();
  let httpStatus = 0, body = null, err = "";
  try {
    const res = await fetch(`${base}/v2/scrape`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({
        url,
        formats: ["markdown"],
        proxy: opt("proxy", "basic"),
        ...(flag("insecure") ? { skipTlsVerification: true } : {}),
      }),
      signal: AbortSignal.timeout(timeout),
    });
    httpStatus = res.status;
    body = await res.json().catch(() => null);
    if (!body?.success) err = String(body?.error || body?.code || "").slice(0, 160);
  } catch (e) {
    err = e.name === "TimeoutError" ? "timeout" : String(e.message).slice(0, 160);
  }
  return {
    url,
    result: classify(httpStatus, body),
    ms: Date.now() - started,
    apiStatus: httpStatus,
    pageStatus: body?.data?.metadata?.statusCode ?? "",
    chars: (body?.data?.markdown || "").length,
    title: (body?.data?.metadata?.title || "").slice(0, 60),
    error: err,
  };
}

const rows = [];
let next = 0;
const wallStart = Date.now();
await Promise.all(
  Array.from({ length: concurrency }, async () => {
    while (next < jobs.length) {
      const row = await scrape(jobs[next++]);
      rows.push(row);
      console.log(
        `${row.result.padEnd(7)} ${String(row.ms).padStart(6)}ms ${String(row.chars).padStart(7)} chars  ${row.url}` +
          (row.error ? `  [${row.error}]` : ""),
      );
    }
  }),
);
const wallSec = (Date.now() - wallStart) / 1000;

const count = k => rows.filter(r => r.result === k).length;
const okMs = rows.filter(r => r.result === "ok").map(r => r.ms).sort((a, b) => a - b);
const pct = p => (okMs.length ? okMs[Math.min(okMs.length - 1, Math.floor(okMs.length * p))] : 0);
const perMin = (rows.length / wallSec) * 60;

console.log(`
Endpoint        ${base}
Pages           ${rows.length} (concurrency ${concurrency})
OK              ${count("ok")} (${((count("ok") / rows.length) * 100).toFixed(0)}%)
Blocked         ${count("blocked")}
Thin (<200 ch)  ${count("thin")}
Error           ${count("error")}
Latency (ok)    p50 ${pct(0.5)}ms  p95 ${pct(0.95)}ms
Throughput      ${perMin.toFixed(0)} pages/min  =  ${((perMin * 60 * 24 * 30) / 1e6).toFixed(2)}M pages/month if run flat out`);
if (monthlyCost !== null) {
  const maxPages = perMin * 60 * 24 * 30;
  console.log(`Cost floor      ${((monthlyCost / maxPages) * 1000).toFixed(4)} per 1,000 pages at full utilisation of a ${monthlyCost}/month server`);
}

mkdirSync("results", { recursive: true });
const file = `results/${label}-${new Date().toISOString().replace(/[:.]/g, "-")}.csv`;
const cols = ["url", "result", "ms", "apiStatus", "pageStatus", "chars", "title", "error"];
const esc = v => `"${String(v).replace(/"/g, '""')}"`;
writeFileSync(file, [cols.join(","), ...rows.map(r => cols.map(c => esc(r[c])).join(","))].join("\n") + "\n");
console.log(`\nSaved ${file}`);
