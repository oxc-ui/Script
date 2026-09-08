#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#   NETWAY — Unified Escape Kit
#   Gost WSS bridge + Cloudflare Tunnel support for egress-restricted
#   environments (Daytona Tier-1/2 sandboxes, QEMU VMs, containers).
# ═══════════════════════════════════════════════════════════════
set -o pipefail
[[ -z "$BASH" ]] && exec bash "$0" "$@"

REPO="oxc-ui/netway-setup"
[[ -n "${GOST_HOST:-}" || -n "${GOST_URL:-}" || -n "${GOST_PORT:-}" ]] && CUSTOM_ENDPOINT=1 || CUSTOM_ENDPOINT=0
GOST_HOST="${GOST_HOST:-gost-docker-production.up.railway.app}"
FULL_URL="${GOST_URL:-wss://sudo:sudo@${GOST_HOST}:443}"
GOST_PORT="${GOST_PORT:-8796}"
VERSION="2.0"

# self-refresh from official repo (ensures users always run latest)
if [ -z "$NETWAY_REFRESHED" ]; then
  export NETWAY_REFRESHED=1
  SRC=$(curl -sS --max-time 15 "https://raw.githubusercontent.com/${REPO}/main/setup.sh?$(date +%s)" 2>/dev/null)
  if [[ -n "$SRC" && "$SRC" == *"NETWAY"* ]]; then
    exec bash <<< "$SRC"
  fi
fi

# ─── palette ─────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; B=$'\033[1;34m'
  C=$'\033[1;36m'; W=$'\033[1;37m'; P=$'\033[1;35m'; N=$'\033[0m'
  D=$'\033[2m'
else
  R=""; G=""; Y=""; B=""; C=""; W=""; P=""; N=""; D=""
fi

# ─── animation helpers ───────────────────────────────────────────
SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

type_line() { # typewriter reveal
  local line="$1" i
  if [[ -t 1 ]]; then
    for ((i=0;i<${#line};i++)); do
      printf '%s' "${line:i:1}"
      sleep 0.006
    done
  else
    printf '%s' "$line"
  fi
  printf '\n'
}

bar_msg() { # full-width gradient-ish banner line
  local msg="$1"
  printf '%s%s%s\n' "$C" "║   $msg" "$N"
}

banner() {
  clear 2>/dev/null || printf '\033[2J\033[H'
  printf '%s\n' "  ${C}╔═══════════════════════════════════════════════════════════╗${N}"
  printf '%s\n' "  ${C}║${N}                                                             ${C}║${N}"
  type_line  "      ${W}███╗   ██╗███████╗████████╗███████╗    ██╗    ██╗ █████╗ ██╗   ██╗${N} "
  type_line  "      ${W}████╗  ██║██╔════╝╚══██╔══╝██╔════╝    ██║    ██║██╔══██╗╚██╗ ██╔╝${N} "
  type_line  "      ${C}██╔██╗ ██║█████╗     ██║   █████╗      ██║ █╗ ██║███████║ ╚████╔╝ ${N} "
  type_line  "      ${C}██║╚██╗██║██╔══╝     ██║   ██╔══╝      ██║███╗██║██╔══██║  ╚██╔╝  ${N} "
  type_line  "      ${B}██║ ╚████║███████╗   ██║   ███████╗    ╚███╔███╔╝██║  ██║   ██║   ${N} "
  type_line  "      ${B}╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚══════╝     ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝   ${N} "
  printf '%s\n' "  ${C}║${N}                                                             ${C}║${N}"
  printf '%s\n' "  ${C}║${N}    ${Y}Netway${N} ${W}v${VERSION}${D} — egress escape kit${N}                            ${C}║${N}"
  printf '%s\n' "  ${C}║${N}    ${C}Gost WSS bridge · Cloudflare Tunnel · auto-persist${N}       ${C}║${N}"
  printf '%s\n' "  ${C}║${N}                                                             ${C}║${N}"
  printf '%s\n' "  ${C}╚═══════════════════════════════════════════════════════════╝${N}"
  printf '\n'
}

hr() { printf '%s\n' "  ${D}──────────────────────────────────────────────────────────${N}"; }

step_box() { # step number, total, title
  printf '\n'
  printf '%s\n' "  ${W}┌─[${C}STEP $1/$2${W}]─────────────────────────────────────── ${C}$3${W}${N}"
  printf '%s\n' "  ${W}└${N}"
}

spinner() { # <pid> <msg> [timeout]
  local pid=$1 msg=$2 ttl=${3:-180} i=0 rc
  if [[ ! -t 1 ]]; then
    printf '  %s ...\n' "$msg"
    wait "$pid"; rc=$?
    if (( rc == 0 )); then ok "done"; else err "failed (rc $rc)"; fi
    return "$rc"
  fi
  printf '  %s%s%s ' "$C" "$msg" "$N"
  while kill -0 "$pid" 2>/dev/null; do
    printf '\b%s' "${SPIN:i%${#SPIN}:1}"
    ((i++))
    sleep 0.08
    if (( i >= ttl/8*100 )); then
      kill "$pid" 2>/dev/null
      printf '\b%s✗ timeout (%ss)%s\n' "$R" "$ttl" "$N"
      return 1
    fi
  done
  wait "$pid"
  local rc=$?
  if (( rc == 0 )); then printf '\b%s✓%s\n' "$G" "$N"
  else printf '\b%s✗%s\n' "$R" "$N"; fi
  return $rc
}

progress() { # <pid> <msg> — growing block bar
  local pid=$1 msg=$2 width=32 i=0 rc
  if [[ ! -t 1 ]]; then
    printf '  %s ...\n' "$msg"
    wait "$pid"; rc=$?
    if (( rc == 0 )); then ok "done"; else err "failed (rc $rc)"; fi
    return "$rc"
  fi
  printf '  %s%s%s [' "$C" "$msg" "$N"
  while kill -0 "$pid" 2>/dev/null; do
    ((i++)); sleep 0.10
    local fill=$(( i % (width + 1) ))
    printf '\r  %s%s%s [%s%s%s]' "$C" "$msg" "$N" "$P" "$(printf '█%.0s' $(seq 1 $(( fill > 0 ? fill : 1 ))) 2>/dev/null)" "$N"
    if (( i >= 1800 )); then kill "$pid" 2>/dev/null; break; fi
  done
  wait "$pid"; rc=$?
  printf '\r  %s%s%s [%s%s%s]' "$C" "$msg" "$N" "$P" "$(printf '█%.0s' $(seq 1 "$width"))" "$N"
  if (( rc == 0 )); then printf ' %s✓%s\n' "$G" "$N"; else printf ' %s✗%s\n' "$R" "$N"; fi
  return $rc
}

countdown() { # brief 3-2-1 pulse before an action
  local n
  for n in 3 2 1; do
    printf '  %s▶ %s%s' "$Y" "$n" "$N"
    printf '\b\b\b\b'
    sleep 0.15
  done
  printf '    \b\b\b\b'
}

ok()  { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
err() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }

ensure_dockerd() { # make sure docker answers; start dockerd when it is missing
  local tries=0
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v dockerd >/dev/null 2>&1; then
    err "dockerd not found (docker install incomplete?)"
    return 1
  fi
  pgrep -x dockerd >/dev/null 2>&1 || { warn "dockerd not running — starting it"; dockerd >/tmp/dockerd.log 2>&1 & }
  while ! docker info >/dev/null 2>&1; do
    (( tries += 1 ))
    if (( tries >= 30 )); then
      err "docker daemon failed to start within 30s"
      sed 's/^/    /' /tmp/dockerd.log 2>/dev/null | tail -15
      warn "hint: dockerd may need a privileged container (--privileged) or a different storage driver"
      return 1
    fi
    sleep 1
  done
  ok "docker daemon ready: $(docker --version 2>/dev/null)"
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "${R}[!]${N} need root — re-run with ${W}sudo${N}"
    exit 1
  fi
}

# ═══════════════════════════════════════════════════════════════
banner
require_root

TOTAL=7

# ─── Step 1: URL ─────────────────────────────────────────────────
step_box 1 $TOTAL "Tunnel endpoint"
hr
printf '  %sRelay :%s %s\n' "$Y" "$N" "$FULL_URL"
printf '  %sListen:%s 127.0.0.1:%s\n' "$Y" "$N" "$GOST_PORT"
ok "endpoint configured"
(( CUSTOM_ENDPOINT )) || warn "using the shared public relay — set GOST_URL for a private endpoint"

# ─── Step 2: Docker ──────────────────────────────────────────────
step_box 2 $TOTAL "Docker engine"
hr
if command -v docker >/dev/null 2>&1; then
  ok "docker cli present"
else
  ( curl -fsSL https://get.docker.com | sh >/tmp/netway-docker-install.log 2>&1 ) &
  progress $! "Installing docker engine" || { err "docker install failed"; tail -5 /tmp/netway-docker-install.log; exit 1; }
fi
ensure_dockerd || exit 1

# ─── Step 3: Packages ────────────────────────────────────────────
step_box 3 $TOTAL "System packages"
hr
( apt-get update -y >/tmp/netway-apt-update.log 2>&1 ) &
progress $! "apt-get update" || warn "apt update had issues (continuing)"
( apt-get install -y --no-install-recommends qemu-system cloud-image-utils wget lsof curl ca-certificates >/tmp/netway-apt-install.log 2>&1 ) &
progress $! "Installing qemu, wget, lsof, curl" || warn "apt install had issues (continuing)"
ok "toolchain ready"

# ─── Step 4: QEMU wrapper + Gost bridge ─────────────────────────
step_box 4 $TOTAL "Gost WSS bridge"
hr
cat > /usr/local/bin/qemu-system-x86_64 <<'QWRAP'
#!/bin/bash
args=()
for arg in "$@"; do [[ "$arg" == "-no-hpet" ]] && continue; args+=("$arg"); done
exec /usr/bin/qemu-system-x86_64 "${args[@]}"
QWRAP
chmod +x /usr/local/bin/qemu-system-x86_64
ok "qemu -no-hpet wrapper"

ensure_dockerd || exit 1

docker rm -f gost-bridge >/dev/null 2>&1 || true
( docker pull ginuerzh/gost:latest >/tmp/netway-gost-pull.log 2>&1 ) &
progress $! "Pulling ginuerzh/gost:latest" || { err "gost image pull failed"; tail -3 /tmp/netway-gost-pull.log; exit 1; }

docker run -d --restart unless-stopped \
  --name gost-bridge \
  -p "127.0.0.1:${GOST_PORT}:${GOST_PORT}" \
  ginuerzh/gost:latest \
  -L=:$GOST_PORT \
  -F="$FULL_URL" >/dev/null 2>&1
tries=0
until docker ps --format '{{.Names}}' | grep -qx gost-bridge; do
  (( tries += 1 ))
  if (( tries >= 15 )); then
    err "gost-bridge failed to start"; docker logs gost-bridge 2>&1 | tail -5; exit 1
  fi
  sleep 1
done
ok "gost-bridge up on 127.0.0.1:$GOST_PORT"

# ─── Step 5: System proxy ────────────────────────────────────────
step_box 5 $TOTAL "System-wide proxy"
hr
NP="localhost,127.0.0.1,::1,deb.debian.org,security.debian.org,snapshot.debian.org,archive.ubuntu.com,security.ubuntu.com,ppas.launchpadcontent.net,launchpad.net,download.docker.com,pkg.cloudflare.com,github.com,githubusercontent.com,dl.google.com,packages.microsoft.com,apt.postgresql.org,nginx.org,nodejs.org"

cat > /etc/profile.d/netway.sh <<EOF
export HTTP_PROXY=http://127.0.0.1:${GOST_PORT}
export HTTPS_PROXY=http://127.0.0.1:${GOST_PORT}
export http_proxy=http://127.0.0.1:${GOST_PORT}
export https_proxy=http://127.0.0.1:${GOST_PORT}
export NO_PROXY=${NP}
export no_proxy=${NP}
EOF
chmod +x /etc/profile.d/netway.sh
ok "/etc/profile.d/netway.sh"

{ printf 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n'
  printf 'HTTP_PROXY=http://127.0.0.1:%s\nHTTPS_PROXY=http://127.0.0.1:%s\nhttp_proxy=http://127.0.0.1:%s\nhttps_proxy=http://127.0.0.1:%s\n' \
      "$GOST_PORT" "$GOST_PORT" "$GOST_PORT" "$GOST_PORT"
  printf 'NO_PROXY=%s\nno_proxy=%s\n' "$NP" "$NP"; } > /etc/environment
ok "/etc/environment"

# apt DIRECT for allowlisted mirrors
{
  printf 'Acquire::http::Proxy "http://127.0.0.1:%s";\nAcquire::https::Proxy "http://127.0.0.1:%s";\n' "$GOST_PORT" "$GOST_PORT"
  for m in archive.ubuntu.com security.ubuntu.com deb.debian.org security.debian.org snapshot.debian.org ppa.launchpadcontent.net launchpad.net download.docker.com pkg.cloudflare.com github.com githubusercontent.com dl.google.com packages.microsoft.com apt.postgresql.org nginx.org nodejs.org; do
    printf 'Acquire::http::Proxy::%s "DIRECT";\nAcquire::https::Proxy::%s "DIRECT";\n' "$m" "$m"
  done
} > /etc/apt/apt.conf.d/90-netway
ok "apt bypass mirror list"

cat > /etc/sudoers.d/netway-proxy <<'EOFP'
Defaults env_keep += "HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy GOST_HOST GOST_URL GOST_PORT"
EOFP
chmod 440 /etc/sudoers.d/netway-proxy
ok "sudoers preserves proxy env"

# auto-start: a boot hook that waits for dockerd, then restores the bridge
cat > /usr/local/bin/netway-boot.sh <<BOOT
#!/bin/bash
# Started by /etc/rc.local: wait for the docker daemon, then start gost-bridge.
for _ in \$(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  command -v dockerd >/dev/null 2>&1 && { pgrep -x dockerd >/dev/null || dockerd >/tmp/dockerd.log 2>&1 & }
  sleep 1
done
docker info >/dev/null 2>&1 || exit 1
for _ in \$(seq 1 5); do
  docker start gost-bridge >/dev/null 2>&1 && exit 0
  docker run -d --restart unless-stopped -p 127.0.0.1:${GOST_PORT}:${GOST_PORT} --name gost-bridge ginuerzh/gost:latest -L=:${GOST_PORT} -F="${FULL_URL}" >/dev/null 2>&1 && exit 0
  sleep 2
done
exit 1
BOOT
chmod +x /usr/local/bin/netway-boot.sh
if [ -f /etc/rc.local ]; then
  sed -i '/gost-bridge/d; /dockerd/d; /netway-boot/d' /etc/rc.local 2>/dev/null || true
else
  printf '#!/bin/sh\n' > /etc/rc.local
  chmod +x /etc/rc.local
fi
sed -i '/^exit 0/i nohup /usr/local/bin/netway-boot.sh >>/var/log/netway-boot.log 2>&1 &' /etc/rc.local 2>/dev/null || true
ok "rc.local auto-start"

# ─── Step 6: Optional Cloudflare Tunnel hook ────────────────────
step_box 6 $TOTAL "Cloudflare Tunnel hook (optional)"
hr
cat > /usr/local/bin/netway-cf-tunnel <<'CFT'
#!/bin/bash
# netway-cf-tunnel <cloudflared-token>
# Runs cloudflared inside Docker. Note: cloudflared does not support proxying
# its edge connection, so it must reach the Cloudflare edge directly.
set -e
TOK="$1"
[[ -z "$TOK" ]] && { echo "usage: netway-cf-tunnel <cloudflared-token>"; exit 1; }
docker rm -f cf-tunnel >/dev/null 2>&1 || true
docker run -d --restart unless-stopped --name cf-tunnel --network host \
  --entrypoint sh \
  cloudflare/cloudflared:latest \
  -c "cloudflared tunnel --no-autoupdate --post-quantum run --token \"$TOK\""
echo "cloudflare tunnel started as 'cf-tunnel'"
CFT
chmod +x /usr/local/bin/netway-cf-tunnel
ok "installed netway-cf-tunnel helper"
warn "pass a cloudflared token to enable: ${W}netway-cf-tunnel <token>$N"

# ─── Step 7: Verify ──────────────────────────────────────────────
step_box 7 $TOTAL "Connectivity check"
hr
export HTTP_PROXY="http://127.0.0.1:${GOST_PORT}" HTTPS_PROXY="http://127.0.0.1:${GOST_PORT}"
http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"
sleep 2

ALL_OK=1
for url in https://github.com https://google.com https://discord.com https://ifconfig.me; do
  printf '  %s%s%s' "$Y" "$(printf '%-32s' "$url")" "$N"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$url" 2>/dev/null) || true
  if [[ "$code" =~ ^(200|301|302|403)$ ]]; then
    printf '%s✓ %s%s\n' "$G" "$code" "$N"
  else
    printf '%s✗ %s%s\n' "$R" "${code:-000}" "$N"
    ALL_OK=0
  fi
done

IP=$(curl -s --max-time 15 https://ifconfig.me 2>/dev/null)
[[ -n "$IP" ]] && ok "egress IP: ${W}$IP" || warn "egress IP unknown"

# ─── Summary ─────────────────────────────────────────────────────
printf '\n'
printf '%s\n' "  ${B}┌─────────────────────────────────────────────────────────┐${N}"
printf '%s\n' "  ${B}│${N}  ${G}✔  NETWAY READY${N}                                        ${B}│${N}"
printf '%s\n' "  ${B}│${N}                                                         ${B}│${N}"
printf '%s\n' "  ${B}│${N}  ${C}relay ${N} ${FULL_URL}$(printf '%*s' $(( 48 - ${#FULL_URL} )) ' ')${B}│${N}"
printf '%s\n' "  ${B}│${N}  ${C}proxy ${N} http://127.0.0.1:${GOST_PORT}$(printf '%*s' $(( 26 )) ' ')${B}│${N}"
printf '%s\n' "  ${B}│${N}                                                         ${B}│${N}"
printf '%s\n' "  ${B}│${N}  ${Y}use     ${N}  source /etc/profile.d/netway.sh             ${B}│${N}"
printf '%s\n' "  ${B}│${N}  ${Y}test    ${N}  curl https://ifconfig.me                    ${B}│${N}"
printf '%s\n' "  ${B}│${N}  ${Y}restart ${N}  docker restart gost-bridge                  ${B}│${N}"
printf '%s\n' "  ${B}│${N}  ${Y}logs    ${N}  docker logs gost-bridge                     ${B}│${N}"
printf '%s\n' "  ${B}│${N}  ${Y}cf tun  ${N}  netway-cf-tunnel <token>                    ${B}│${N}"
printf '%s\n' "  ${B}└─────────────────────────────────────────────────────────┘${N}"
printf '\n'
(( ALL_OK == 0 )) && { warn "some checks failed — see: docker logs gost-bridge"; } || ok "all checks passed"
exit $(( ALL_OK == 0 ))
