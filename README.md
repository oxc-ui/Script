# NETWAY — Escape Kit

One animated installer that restores **full streaming internet** in
egress-restricted environments (Daytona Tier-1/2 sandboxes, locked-down
containers, QEMU VMs) by bridging all traffic through a WebSocket relay on a
host whose TLS SNI passes the allow-list (e.g. `*.railway.app`).

```
┌──────────────┐  wss://sudo:sudo@relay.up.railway.app:443
│   sandbox    │ ─────────────────────────────────────────►  ┌─────────────┐
│  gost :8796  │        (TLS with allowlisted SNI)            │ Railway Gost │──► open internet
└──────────────┘                                              └─────────────┘
```

## Why this works

Restricted egress usually means:
- TLS is filtered by **SNI / HTTP Host** against an allow-list
- UDP is dropped, ICMP is rate-limited, raw TCP is reset

A WebSocket tunnel whose outer connection carries an allow-listed SNI slips
straight past that layer. Everything inside (HTTP, HTTPS, TCP, streaming)
comes out the relay side unfiltered.

## Usage

```bash
curl -sS https://raw.githubusercontent.com/oxc-ui/netway-setup/main/setup.sh | sudo bash
```

Non-interactive / custom relay:

```bash
GOST_HOST=my-own-relay.up.railway.app \
GOST_PORT=8796 \
curl -sS https://raw.githubusercontent.com/oxc-ui/netway-setup/main/setup.sh | sudo bash
```

Env overrides: `GOST_HOST` (relay host), `GOST_URL` (full wss:// URL, takes
precedence), `GOST_PORT` (local listen port, default 8796).

## What it does

1. Detects/installs Docker
2. Installs qemu-system, wget, lsof, curl (adds a QEMU `-no-hpet` wrapper for QEMU 9+)
3. Runs `ginuerzh/gost` in Docker as a WSS bridge on `:8796`
4. Sets system-wide proxy (`/etc/profile.d/netway.sh`, `/etc/environment`,
   sudoers env_keep, apt mirror DIRECT bypass)
5. Installs **Cloudflare Tunnel** helper (`netway-cf-tunnel <token>`)
6. Verifies connectivity against previously-blocked sites
7. Persists across reboots via `/etc/rc.local`

## Cloudflare Tunnel

After the bridge is up:

```bash
sudo netway-cf-tunnel <your-cloudflared-token>
```

Runs `cloudflare/cloudflared` in a sibling container with host networking.

## After setup

```bash
source /etc/profile.d/netway.sh   # current shell
curl https://ifconfig.me          # confirm egress IP
```

## Managing

| Task    | Command                          |
|---------|----------------------------------|
| Logs    | `docker logs gost-bridge`        |
| Restart | `docker restart gost-bridge`     |
| Remove  | `docker rm -f gost-bridge`       |
| Status  | `docker ps --filter name=gost-bridge` |

## Notes

- The default relay is a shared public endpoint; for persistent/private use,
  deploy your own from a `ginuerzh/gost` image on Railway or any VPS and pass
  `GOST_URL`.
- Streaming confirmed: ~8 MB/s on 25 MB chunked download through the bridge.
