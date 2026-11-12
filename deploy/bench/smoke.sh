#!/usr/bin/env bash
# Pass/fail check of every endpoint the bot will use.
#   FC_URL=https://scrape.example.com FC_TOKEN=... ./smoke.sh
set -u
B="${FC_URL:?set FC_URL}"; B="${B%/}"
T="${FC_TOKEN:?set FC_TOKEN}"
EXTRA="${SCRAPE_EXTRA:-}"   # e.g. SCRAPE_EXTRA=',"skipTlsVerification":true'
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2', wanted '$3')"; fail=1; fi; }
post() { curl -s -m 120 -H "Authorization: Bearer $T" -H 'content-type: application/json' -d "$2" "$B$1"; }
py() { python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print('bad-json'); sys.exit()
$1"; }

check "rejects requests without the token" "$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$B/")" 401
check "accepts requests with the token" "$(curl -s -o /dev/null -w '%{http_code}' -m 20 -H "Authorization: Bearer $T" "$B/")" 200

check "scrape: static page to Markdown" "$(post /v2/scrape '{"url":"https://example.com","formats":["markdown"],"proxy":"basic"'"$EXTRA"'}' | py "print('ok' if 'documentation' in d.get('data',{}).get('markdown','') else 'no')")" ok
check "scrape: JavaScript-rendered page" "$(post /v2/scrape '{"url":"https://quotes.toscrape.com/js/","formats":["markdown"],"proxy":"basic","waitFor":2000'"$EXTRA"'}' | py "print('ok' if 'Einstein' in d.get('data',{}).get('markdown','') else 'no')")" ok
check "scrape: PDF" "$(post /v2/scrape '{"url":"https://arxiv.org/pdf/1706.03762","formats":["markdown"],"proxy":"basic"'"$EXTRA"'}' | py "print('ok' if 'Attention' in d.get('data',{}).get('markdown','') else 'no')")" ok
check "map: lists URLs from a sitemap" "$(post /v2/map '{"url":"https://docs.firecrawl.dev","limit":20}' | py "print('ok' if len(d.get('links',[]))>=10 else 'no')")" ok
check "search: returns results" "$(post /v2/search '{"query":"web scraping","limit":5}' | py "print('ok' if len(d.get('data',{}).get('web',[]))>=3 else 'no')")" ok

id="$(post /v2/crawl '{"url":"https://books.toscrape.com","limit":10,"scrapeOptions":{"formats":["markdown"],"proxy":"basic"'"$EXTRA"'}}' | py "print(d.get('id',''))")"
status=""
for _ in $(seq 1 40); do
  sleep 3
  status="$(curl -s -m 20 -H "Authorization: Bearer $T" "$B/v2/crawl/$id" | py "print(d.get('status'),d.get('completed'))")"
  case "$status" in completed*|failed*) break;; esac
done
check "crawl: 10 pages complete" "$status" "completed 10"

[ $fail = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
exit $fail
