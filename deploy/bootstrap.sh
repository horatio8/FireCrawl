#!/usr/bin/env bash
# One-shot server setup for the self-hosted Firecrawl stack. Run as root on a fresh Ubuntu 24.04 box.
#
#   bootstrap.sh install <domain>   install Docker, clone the repo, write .env, open 22/80/443 only, start the stack
#   bootstrap.sh report             print a secret-free status report (ports, firewall, containers, docker stats log)
#
# Secrets are generated on the server and never printed. Read the token with:
#   grep ^API_TOKEN= /opt/firecrawl/deploy/.env
set -euo pipefail

REPO="${REPO:-https://github.com/horatio8/FireCrawl.git}"
BRANCH="${BRANCH:-claude/eager-fermi-3uby1c}"
DIR=/opt/firecrawl
STATS_LOG=/var/log/firecrawl-docker-stats.log

install() {
  local domain="${1:?usage: bootstrap.sh install <domain>}"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq
  apt-get install -y -qq git ufw curl openssl python3 >/dev/null
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker >/dev/null

  if [ -d "$DIR/.git" ]; then
    git -C "$DIR" fetch -q origin "$BRANCH" && git -C "$DIR" checkout -q "$BRANCH" && git -C "$DIR" pull -q --ff-only
  else
    git clone -q --branch "$BRANCH" "$REPO" "$DIR"
  fi

  cd "$DIR/deploy"
  if [ ! -f .env ]; then
    cp .env.example .env
    chmod 600 .env
    sed -i "s|^SITE_ADDRESS=.*|SITE_ADDRESS=$domain|" .env
    for key in API_TOKEN SEARXNG_SECRET POSTGRES_PASSWORD; do
      sed -i "s|^$key=.*|$key=$(openssl rand -hex 32)|" .env
    done
    echo "wrote $DIR/deploy/.env"
  else
    echo "$DIR/deploy/.env already exists, left untouched"
  fi

  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null
  ufw --force enable >/dev/null

  docker compose pull -q
  docker compose up -d

  # docker stats every 3 minutes, for the load test.
  cat >/etc/cron.d/firecrawl-stats <<EOF
*/3 * * * * root (date -u +\%FT\%TZ; docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}') >> $STATS_LOG 2>&1
EOF

  echo "waiting for the API to answer..."
  local token; token="$(grep '^API_TOKEN=' .env | cut -d= -f2)"
  for _ in $(seq 1 60); do
    [ "$(docker compose exec -T caddy wget -q -O /dev/null --header "Authorization: Bearer $token" http://api:3002/ 2>&1; echo $?)" = 0 ] && break
    sleep 5
  done

  echo "running the smoke test against https://$domain (needs DNS pointing here and a certificate)..."
  FC_URL="https://$domain" FC_TOKEN="$token" bash bench/smoke.sh || true
  echo
  report
}

report() {
  echo "== host =="; uname -r; uptime; nproc; free -m | sed -n 2p
  echo "== public IP =="; curl -s -m 10 https://api.ipify.org || true; echo
  echo "== firewall =="; ufw status | sed -n 1,12p
  echo "== listening on public interfaces =="; ss -tulnH | awk '$5 !~ /^(127\.|\[::1\])/ {print $1, $5}' | sort -u
  echo "== containers =="; (cd "$DIR/deploy" && docker compose ps --format '{{.Service}} {{.State}} {{.Status}}')
  echo "== restarts / OOM kills =="; docker ps -q | xargs -r docker inspect -f '{{.Name}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} started={{.State.StartedAt}}'
  echo "== docker stats now =="; docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}'
  echo "== docker stats log (last 400 lines of $STATS_LOG) =="; tail -n 400 "$STATS_LOG" 2>/dev/null || echo "no log yet"
}

case "${1:-}" in
  install) shift; install "$@";;
  report) report;;
  *) sed -n 2,9p "$0"; exit 1;;
esac
