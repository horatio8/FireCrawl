# Firecrawl: how it works, building it into a bot, and where to host it

Prepared 7 November 2026. Source reviewed: `github.com/firecrawl/firecrawl` (main branch, shallow clone). Prices were pulled from the vendors' public pricing pages on the same date.

## 1. Short answer

- Firecrawl is open source (AGPL-3.0). You can run the same API on your own server with Docker Compose and pay nothing per page.
- What you lose by self-hosting is **Fire-engine**, their closed-source scraping backend (stealth browsers, rotating proxies, anti-bot handling). Self-hosted Firecrawl falls back to plain Playwright plus a basic HTTP fetch. Easy sites work fine. Sites behind Cloudflare, DataDome and similar will fail more often unless you add your own proxy.
- **Vercel cannot run Firecrawl itself.** Firecrawl needs long-running workers, Redis, RabbitMQ, Postgres and a 4 GB Playwright container. Vercel only runs short-lived functions with no Docker support.
- **Cheapest option at almost every volume: one VPS running the official Docker Compose stack.** Vercel only wins if you write a much slimmer scraper yourself and your volume is low.

## 2. How Firecrawl works

### Services in the stack (`docker-compose.yaml`)

| Service | Job | Default resource limit |
| --- | --- | --- |
| `api` | Express API on port 3002 plus the queue workers (started by `harness.js`) | 4 CPU, 8 GB RAM |
| `playwright-service` | Headless Chromium for JavaScript-heavy pages | 2 CPU, 4 GB RAM |
| `nuq-postgres` | Job queue (NuQ) stored in Postgres with `pg_cron` | small |
| `redis` | Rate limiting, crawl state, caching | small |
| `rabbitmq` | Queue notifications between API and workers | small |
| `foundationdb` | Optional alternative queue backend; ignore it | n/a |

Realistic minimum for the whole stack: 4 vCPU and 8 GB RAM. Comfortable: 8 vCPU and 16 GB.

### Request flow for a scrape

1. `POST /v2/scrape` hits the API (`apps/api/src/routes/v2.ts`).
2. A job is put on the NuQ queue. A worker picks it up.
3. The worker runs a **waterfall of engines** (`apps/api/src/scraper/scrapeURL/engines/index.ts`). It tries the best available engine first and falls back if that fails. The engine list is built from environment variables:
   - `fire-engine;*` variants: only if `FIRE_ENGINE_BETA_URL` is set. This is the paid, closed service. **Not available to self-hosters.**
   - `playwright`: if `PLAYWRIGHT_MICROSERVICE_URL` is set (it is in the Compose file).
   - `fetch`: plain HTTP request, always on.
   - `pdf`, `document`: PDF and Office parsing, always on.
   - `image`, `wikipedia`, `x-twitter`, `index`: need extra paid keys or internal services. Skip them.
4. The raw HTML goes through transformers (`scraper/scrapeURL/transformers`): main-content extraction, HTML to Markdown (there is a Go service for this in `apps/go-html-to-md-service`), link extraction, screenshots.
5. If you ask for JSON extraction, `llmExtract.ts` sends the Markdown to an LLM. Self-hosted, that is your own OpenAI key, any OpenAI-compatible endpoint, or a local Ollama model (`OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OLLAMA_BASE_URL`, `MODEL_NAME`).

### Other endpoints

- **Crawl** (`/v2/crawl`): reads robots.txt and sitemaps, discovers links, and queues one scrape job per page. Concurrency is set by `CRAWL_CONCURRENT_REQUESTS` and `NUM_WORKERS_PER_QUEUE`.
- **Map** (`/v2/map`): returns the list of URLs on a site without scraping them.
- **Search** (`/v2/search`): in the cloud this uses Fire-engine. Self-hosted, it uses **SearXNG** if you set `SEARXNG_ENDPOINT`, otherwise a DuckDuckGo fallback (`apps/api/src/search/v2/index.ts`). Run your own SearXNG container for reliable results.
- **Extract / Agent**: multi-page LLM features. They work self-hosted, but every page costs you LLM tokens.

### What you give up compared to the paid cloud

| Feature | Cloud | Self-hosted |
| --- | --- | --- |
| Basic scrape, crawl, map | Yes | Yes |
| Markdown, HTML, links, screenshots | Yes | Yes |
| JSON / LLM extraction | Yes | Yes, with your own model |
| Stealth browser, anti-bot, proxy rotation | Yes (Fire-engine) | No. Bring your own proxy via `PROXY_SERVER` |
| Search | Their index | SearXNG or DuckDuckGo fallback |
| Image OCR, X/Twitter, Wikipedia enterprise, Alexandria data providers | Yes | No |
| Auth, billing, dashboards | Yes | Off by default; the API is open to anyone who can reach it |

### Licence

AGPL-3.0. Using it internally as the back end of your own bot is fine. If you modify Firecrawl and let outside users talk to that modified service over a network, you must publish your modified source. Calling the unmodified API from separate bot code does not make your bot AGPL.

## 3. Building it into a bot

### Option A: self-host the full stack (recommended)

```bash
git clone https://github.com/firecrawl/firecrawl.git
```

```bash
cd firecrawl
```

Create a `.env` next to `docker-compose.yaml`:

```
USE_DB_AUTHENTICATION=false
BULL_AUTH_KEY=pick-a-long-random-string
OPENAI_API_KEY=sk-...            # only if you want JSON extraction
SEARXNG_ENDPOINT=http://searxng:8080   # only if you add SearXNG
PROXY_SERVER=                    # optional residential proxy
```

```bash
docker compose up -d
```

Then point the official SDK at your server instead of the cloud:

```ts
import Firecrawl from "@mendable/firecrawl-js";

const fc = new Firecrawl({ apiKey: "unused", apiUrl: "http://YOUR_SERVER:3002" });
const page = await fc.scrape("https://example.com", { formats: ["markdown"] });
```

```python
from firecrawl import Firecrawl
fc = Firecrawl(api_key="unused", api_url="http://YOUR_SERVER:3002")
page = fc.scrape("https://example.com", formats=["markdown"])
```

Before exposing it to the internet: put it behind a reverse proxy with TLS and an auth header (Caddy or Nginx), or keep port 3002 private and let only your bot reach it. The default API has no authentication.

### Option B: write a slim scraper yourself

If the bot only needs "give me this page as clean Markdown", you do not need the full stack. The core of what Firecrawl does for a single page is about 100 lines:

1. Fetch the URL with a normal HTTP client.
2. If the result looks empty or JavaScript-gated, retry with headless Chromium (Playwright locally, or `@sparticuz/chromium` + `playwright-core` on serverless).
3. Strip boilerplate with Mozilla Readability.
4. Convert to Markdown with Turndown.
5. Optional: pass the Markdown to an LLM with a JSON schema.

This version is the only one that fits on Vercel. You lose crawling at scale, queues, retries and the engine waterfall unless you build them.

## 4. Cost comparison

### Assumptions

- A "page" is one scrape. Firecrawl charges 1 credit per scrape or crawled page, 2 credits per 10 search results, and an extra 4 credits per page for JSON extraction.
- Vercel Pro: $20/month per seat with $20 of usage included. Fluid compute: $0.128 per active CPU hour, $0.0106 per GB-hour of provisioned memory, $0.60 per million invocations (lowest-cost regions; others cost more). Function limits: 800 s max duration, 4 GB memory, 250 MB bundle, no Docker, no persistent workers. Hobby is not allowed for commercial use.
- Browser scrape on Vercel: about 2 s of active CPU and 2 GB held for 5 s. That works out to roughly **$0.0001 per page**. A fetch-only scrape (no browser) is about **$0.00001 per page**.
- VPS: Hetzner raised prices in June 2026. Current figures are roughly €12-20/month for 4 vCPU / 8 GB and about €41/month for the Arm CAX41 (16 vCPU / 32 GB). DigitalOcean, Vultr and similar cost two to three times more for the same spec.
- Proxy and LLM costs are the same whether you use a VPS or Vercel, so they are listed separately.

### Monthly cost by volume (scrapes only, no JSON extraction)

| Pages per month | Firecrawl cloud | Vercel (slim DIY scraper, all pages in a browser) | VPS (full Firecrawl stack) |
| --- | --- | --- | --- |
| 1,000 | $0 (free tier) | $20 (seat fee) | ~€12 |
| 5,000 | $19 (Hobby) | $20 | ~€12 |
| 100,000 | $99 (Standard) | ~$20 (fits inside included credit) | ~€12-20 |
| 500,000 | $399 (Growth) | ~$50 | ~€20-41 |
| 1,000,000 | $749 (Scale) | ~$100-120 | ~€41 |
| 1,000,000 with JSON extraction | ~5M credits, enterprise pricing | ~$110 + LLM tokens | ~€41 + LLM tokens |

If most pages can be fetched without a browser, the Vercel column drops by up to 90%, and Vercel becomes cost-competitive with a VPS up to a few hundred thousand pages.

### Costs the table does not show

| Item | Firecrawl cloud | Vercel DIY | VPS self-host |
| --- | --- | --- | --- |
| Anti-bot and proxies | Included | You buy a proxy. Residential runs about $3-8 per GB, and a browser page is often 1-3 MB unless you block media | Same as Vercel |
| LLM extraction | 4 extra credits per page | Your model bill. A small model costs a fraction of a cent per page | Same as Vercel |
| Search | 2 credits per 10 results | You need a SERP API (paid) because SearXNG cannot run on Vercel | Free with a SearXNG container |
| Crawling large sites | Built in | You must build queueing yourself (Vercel Queues, Upstash QStash) because functions cap at 800 s | Built in |
| Engineering time | None | Highest. You are writing and maintaining the scraper | Medium. Initial setup plus upgrades, backups and monitoring |
| Blocked IPs | Their problem | Vercel runs on AWS IPs, which many sites already block | VPS IPs are also datacenter IPs. Same problem |

## 5. Verdict

**Self-host on a VPS, not on Vercel.**

- Vercel cannot run Firecrawl. Hosting there means writing and maintaining your own reduced scraper. You also give up crawling, the engine waterfall and free search.
- A single Hetzner-class VPS at about €12-41/month runs the real Firecrawl stack with no per-page charge. It beats Firecrawl cloud from around 5,000 pages a month and beats Vercel above a few hundred thousand browser pages.
- Vercel only comes out ahead if you scrape fewer than about 100,000 pages a month, most pages don't need a browser, you already pay for Vercel Pro, and you are happy to own the scraper code.

**The real risk with self-hosting is the sites, not the hosting.** Without Fire-engine, protected sites will block you. Before you commit, run your actual target URLs through a self-hosted instance and measure the success rate. If it is low, the honest comparison becomes "VPS plus a residential proxy" against Firecrawl's price, and a paid plan may still win for that subset.

### Suggested setup

1. Run your bot wherever you like (Vercel is fine for the bot's own front end or webhook).
2. Run Firecrawl on one VPS with Docker Compose, plus a SearXNG container for search.
3. Keep port 3002 private or put it behind Caddy with a shared-secret header.
4. Point the Firecrawl SDK at `apiUrl` on that VPS.
5. Optionally keep a Firecrawl cloud free or Hobby key as a fallback for the few sites your instance can't get through.
