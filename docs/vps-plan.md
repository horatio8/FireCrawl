# Plan: self-hosted Firecrawl on one VPS, costed and proven

Written 12 November 2026. Everything under "Already proven" was run for real on 12 November in a 4 vCPU / 16 GB Linux sandbox using the files in `deploy/`. Raw results are in `docs/evidence/`. Prices are from hetzner.com and firecrawl.dev on the same day.

A note on wording: there is no such thing as a "serverless VPS". Firecrawl needs always-on workers, a queue and a browser, so this plan uses a plain always-on VPS. That is also the cheapest way to run it.

## 1. Cost

### Fixed monthly cost

| Item | Choice | Monthly |
| --- | --- | --- |
| Server | Hetzner CX43: 8 vCPU, 16 GB RAM, 160 GB disk, 20 TB traffic (Germany or Finland) | €16.49 |
| Automated backups | Hetzner backups, 20% of server price | €3.30 |
| Domain and TLS | Subdomain of a domain you own, certificate from Let's Encrypt via Caddy | €0 |
| Firecrawl licence | Open source (AGPL) | €0 |
| **Total** | | **€19.79 excl. tax** |

Per-page cost is zero. In the sandbox the stack sustained about 45 to 60 browser-rendered pages a minute, which is roughly 2 million pages a month, so the cost floor is under one euro cent per 1,000 pages.

Cheaper option: CX33 (4 vCPU, 8 GB) at €8.99. The whole stack used about 3 GB of RAM under load in testing, so it fits, but leaves little headroom for heavy pages.

If your targets are mostly Australian sites and latency matters, the nearest Hetzner region is Singapore, where the comparable server (CPX32, 4 vCPU, 8 GB) costs €49.49. Test from Germany first. Scraping is rarely latency-sensitive.

### Variable costs, only if you need them

| Item | When you need it | Cost |
| --- | --- | --- |
| Residential proxy | Only if phase 2 shows your target sites block the server | Typically $3 to $8 per GB, pay as you go |
| LLM tokens | Only for JSON extraction | Your model provider's rate. A small model is a fraction of a cent per page |
| Firecrawl cloud as fallback | Only for sites you can't get through yourself | Free tier (1,000 pages a month) or Hobby at $19 for 5,000 |

### Cost of the proof itself

Hetzner bills by the hour. Running the CX43 for a one-week trial costs about €4. The Firecrawl cloud side of the comparison fits inside the free tier.

### What it replaces

| Pages per month | Firecrawl cloud | This setup |
| --- | --- | --- |
| 5,000 | $19 | €19.79 |
| 100,000 | $99 | €19.79 |
| 500,000 | $399 | €19.79 |
| 1,000,000 | $749 | €19.79 |

Break-even is at roughly 5,000 pages a month. Below that, stay on Firecrawl's free or Hobby plan.

## 2. Already proven

| Test | Result |
| --- | --- |
| Whole stack starts from `deploy/docker-compose.yml` using published images, no build step | Pass |
| API refuses requests without the token (401) and accepts them with it (200) | Pass |
| Scrape to Markdown: static page, JavaScript-rendered page, PDF | Pass |
| Map (URL discovery from sitemap) | Pass, 50 links |
| Search through the bundled SearXNG | Pass |
| Crawl of 200 pages | Pass, 200 of 200 in 202 seconds |
| Load test, 200 scrapes at 10 in parallel | Pass, 200 of 200, no errors |
| Memory under load | API 2.3 GB, browser 0.4 GB, everything else under 0.4 GB |

`deploy/bench/smoke.sh` repeats the first seven rows in about a minute and prints PASS or FAIL per line.

### The result that matters: which sites it can and can't read

I ran 32 well-known sites through the local instance. Four were stopped by the sandbox's own network policy and are excluded. Of the remaining 28:

| Outcome | Count | Sites |
| --- | --- | --- |
| Clean content | 14 | Wikipedia, Hacker News, ABC News, gov.uk, GitHub, MDN, Python docs, react.dev, YouTube, LinkedIn company page, arXiv PDF, books.toscrape, example.com, a small test PDF |
| Thin or flaky | 2 | Airbnb (256 characters), quotes.toscrape JS page (fixed by adding `waitFor`) |
| Blocked by the site | 11 | Amazon AU, eBay AU, Seek, realestate.com.au, ATO, Indeed, Zillow, G2, Crunchbase, npm, Instagram |
| Not supported self-hosted | 1 | x.com (Firecrawl routes it to a paid engine) |

I then sent three of the blocked sites (Seek, eBay AU, G2) through Firecrawl cloud. All three came back with full content. That gap is the paid anti-bot backend, and it is the single thing you give up.

Caveat: these requests left from a shared cloud IP address. A Hetzner address may do somewhat better or worse. Phase 2 below measures it properly on your own target list.

### Things I found and already fixed in `deploy/`

- Send `"proxy": "basic"` with every request. The API's default mode reacts to any 401, 403 or 429 by escalating to a stealth proxy that doesn't exist when self-hosted, and you get an unhelpful "all engines failed" error.
- The browser image downloads its package manager on every start. The compose file starts it directly instead, so a restart doesn't depend on the npm registry.
- JavaScript-heavy pages are more reliable with `"waitFor": 2000`.
- Map only finds URLs on sites that publish a sitemap. For others, use crawl.

### One open question

Throughput stayed at 45 to 60 pages a minute however many requests I sent in parallel, with the CPU almost idle. Plain HTTP fetches from the same container ran 30 pages in half a second, so the limit is in the browser path. The sandbox routes all traffic through an inspecting proxy, which is the likely cause, but I couldn't confirm it. Phase 3 measures the real figure on the VPS. Even the sandbox figure is about 2 million pages a month.

## 3. Setup (about 30 minutes)

1. Create a Hetzner Cloud account and a CX43 server with Ubuntu 24.04. Add your SSH key. Turn on backups.
2. In the Hetzner firewall, allow inbound ports 22, 80 and 443 only.
3. Point a DNS A record (for example `scrape.yourdomain.com`) at the server's IP.
4. On the server:

```bash
curl -fsSL https://get.docker.com | sh
```

```bash
git clone https://github.com/horatio8/FireCrawl.git && cd FireCrawl/deploy
```

```bash
cp .env.example .env
```

5. Edit `.env`: set `SITE_ADDRESS` to your subdomain, and fill `API_TOKEN`, `SEARXNG_SECRET` and `POSTGRES_PASSWORD` with the output of `openssl rand -hex 32`.
6. Start it:

```bash
docker compose up -d
```

7. From your laptop:

```bash
FC_URL=https://scrape.yourdomain.com FC_TOKEN=your-token ./bench/smoke.sh
```

**Gate 1:** every line says PASS.

## 4. Proving it out

### Phase 2: can it read *your* sites? (one hour, the decisive test)

1. Replace `deploy/bench/urls.txt` with 50 to 100 real URLs your bot needs, several per site.
2. Run it against your server:

```bash
FC_URL=https://scrape.yourdomain.com FC_TOKEN=your-token node bench.mjs --label self --monthly-cost 19.79
```

3. Run the same list against Firecrawl cloud with a free-tier key:

```bash
FC_URL=https://api.firecrawl.dev FC_TOKEN=fc-your-key node bench.mjs --label cloud --proxy auto
```

4. Compare the two CSV files in `bench/results/`. Open a handful of the "ok" rows and read the Markdown to confirm it is the real content.

**Gate 2:** at least 90% of your must-have URLs come back "ok" on the self-hosted run. For each site that fails, choose one: drop it, send only that site to Firecrawl cloud, or add a residential proxy (`PROXY_SERVER` in `.env`) and rerun to see whether it helps.

### Phase 3: does it hold up under load? (two hours, mostly waiting)

1. Work out your peak: pages per hour on your busiest day.
2. Run at twice that for an hour, using only URLs that passed phase 2. Adjust `--repeat` and `--concurrency`:

```bash
FC_URL=https://scrape.yourdomain.com FC_TOKEN=your-token node bench.mjs --repeat 40 --concurrency 10 --label load
```

3. While it runs, watch `docker stats` on the server.

**Gate 3:** zero errors, memory flat rather than climbing, 95th percentile latency under 20 seconds, and the measured pages per minute at least twice your peak need. If throughput is the problem, raise `CRAWL_CONCURRENT_REQUESTS` and `NUM_WORKERS_PER_QUEUE` in `.env` and rerun.

### Phase 4: does it survive a week? (one week, five minutes a day)

1. Point the bot at the server. With the official SDK this is one line: set `apiUrl` to your subdomain and `apiKey` to your `API_TOKEN`. Add `proxy: "basic"` to scrape options.
2. Keep the Firecrawl cloud key in the bot as a fallback: if the self-hosted call fails or returns under 200 characters, retry on cloud and log that it happened.
3. Schedule `smoke.sh` to run hourly from somewhere other than the server and alert you on failure.
4. Reboot the server once on purpose and confirm everything comes back by itself.

**Gate 4:** after seven days, the fallback fired on under 5% of requests, no manual intervention was needed, and the smoke test never failed for more than one consecutive run.

### Decision

| Outcome | Action |
| --- | --- |
| All four gates pass | Cancel or downgrade the Firecrawl plan. Pin the image tags in `.env` to the versions you tested |
| Gate 2 fails for a few sites only | Keep self-hosting, route just those sites to Firecrawl's cheapest plan |
| Gate 2 fails for most sites | Your targets need anti-bot handling. Price a residential proxy against Firecrawl cloud, and expect cloud to win |
| Gate 3 or 4 fails | Move up to the CX53 (16 vCPU, 32 GB, €29.99) and repeat |

## 5. Ongoing upkeep

- Monthly: `docker compose pull && docker compose up -d` after checking the Firecrawl release notes, then run `smoke.sh`.
- The queue database lives in a Docker volume and Hetzner backups cover the whole disk. Nothing in it is precious. A rebuilt server works as soon as `.env` is restored.
- Keep `.env` out of git. It is already in `deploy/.gitignore`.
