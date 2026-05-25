#!/usr/bin/env bash

# Copyright (c) 2026 Miguel Eduardo Gil Biraud
# Author: Miguel Eduardo Gil Biraud
# License: MIT
# Source: https://caddyserver.com/ | Github: https://github.com/caddyserver/caddy
#
# Adds Caddy to an existing LXC container and configures it as a reverse
# proxy for a given domain, forwarding to a local port inside the container.
#
# TLS is handled automatically by Caddy via Let's Encrypt. Two challenge
# methods are offered:
#   - HTTP/TLS-ALPN : for hosts publicly reachable on ports 80/443
#   - DNS-01        : for internal / Tailscale-only hosts whose A record is
#                     not reachable from the internet. A caddy-dns provider
#                     plugin (Cloudflare, DNSimple, Gandi, ...) solves the
#                     challenge over your DNS provider's API.

set -Eeuo pipefail
trap 'echo -e "\n[ERROR] in line $LINENO: exit code $?"' ERR

function header_info() {
  clear
  cat <<"EOF"
   ______          __    __
  / ____/___ _____/ /___/ /_  __
 / /   / __ `/ __  / __  / / / /
/ /___/ /_/ / /_/ / /_/ / /_/ /
\____/\__,_/\__,_/\__,_/\__, /
                       /____/   reverse proxy

EOF
}

function msg_info() { echo -e " \e[1;36m➤\e[0m $1"; }
function msg_ok() { echo -e " \e[1;32m✔\e[0m $1"; }
function msg_error() { echo -e " \e[1;31m✖\e[0m $1"; }

# whiptail prompt helpers — set REPLY_VAL; abort the whole script on cancel.
REPLY_VAL=""
function ask_secret() { # title msg
  REPLY_VAL=""
  while [[ -z "$REPLY_VAL" ]]; do
    REPLY_VAL=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "$1" \
      --passwordbox "$2" 14 72 3>&1 1>&2 2>&3) || exit 0
  done
}
function ask_text() { # title msg default
  REPLY_VAL=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "$1" \
    --inputbox "$2" 14 72 "${3:-}" 3>&1 1>&2 2>&3) || exit 0
}

header_info

if ! command -v pveversion &>/dev/null; then
  msg_error "This script must be run on the Proxmox VE host (not inside an LXC container)"
  exit 232
fi

while true; do
  read -rp "This will install/configure Caddy as a reverse proxy in an existing LXC Container ONLY. Proceed (y/n)? " yn
  case "$yn" in
  [Yy]*) break ;;
  [Nn]*) exit 0 ;;
  *) echo "Please answer yes or no." ;;
  esac
done

header_info
msg_info "Loading container list..."

NODE=$(hostname)
MSG_MAX_LENGTH=0
CTID_MENU=()

while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  ITEM=$(echo "$line" | awk '{print substr($0,36)}')
  OFFSET=2
  ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
  CTID_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pct list | awk 'NR>1')

CTID=""
while [[ -z "${CTID}" ]]; do
  CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Containers on $NODE" --radiolist \
    "\nSelect a container to configure as a Caddy reverse proxy:\n" \
    16 $((MSG_MAX_LENGTH + 23)) 6 \
    "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit 0
done

# Container must be running for pct exec to work
STATUS=$(pct status "$CTID" | awk '{print $2}')
if [[ "$STATUS" != "running" ]]; then
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Container not running" \
    --yesno "CT $CTID is currently '$STATUS'. Start it now to continue?" 10 60; then
    msg_info "Starting CT $CTID"
    pct start "$CTID"
    sleep 3
    msg_ok "CT $CTID started"
  else
    msg_error "CT $CTID must be running to configure Caddy. Aborting."
    exit 1
  fi
fi

# ── Collect reverse proxy settings ──
DOMAIN=""
while [[ -z "$DOMAIN" ]]; do
  DOMAIN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Domain" --inputbox \
    "\nEnter the domain Caddy should serve (e.g. app.example.com):" \
    11 70 3>&1 1>&2 2>&3) || exit 0
  if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    whiptail --title "Invalid domain" --msgbox "'$DOMAIN' does not look like a valid domain name." 8 60
    DOMAIN=""
  fi
done

PORT=""
while [[ -z "$PORT" ]]; do
  PORT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Local Port" --inputbox \
    "\nEnter the local port inside CT $CTID to reverse-proxy to (the service Caddy will forward $DOMAIN to):" \
    11 70 "8080" 3>&1 1>&2 2>&3) || exit 0
  if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
    whiptail --title "Invalid port" --msgbox "'$PORT' is not a valid port (1-65535)." 8 60
    PORT=""
  fi
done

# ── TLS / Let's Encrypt challenge method ──
CHALLENGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Let's Encrypt challenge" --menu \
  "\nHow should Caddy obtain the TLS certificate for $DOMAIN?\n" 15 78 2 \
  "dns" "DNS-01         internal / Tailscale-only (DNS provider API)" \
  "http" "HTTP/TLS-ALPN  host is publicly reachable on ports 80/443" \
  3>&1 1>&2 2>&3) || exit 0

# These describe the DNS-01 setup and are consumed, untouched, by the
# in-container script: DNS_TLS_BLOCK is the literal `tls { ... }` block (tabs
# and newlines included) and DNS_ENV is newline-separated KEY=VALUE pairs that
# back the {env.*} placeholders. All provider-specific knowledge lives here.
DNS_PROVIDER=""  # caddy module keyword, e.g. "cloudflare" (for plugin check)
DNS_MODULE=""    # full module path for `caddy add-package`
DNS_TLS_BLOCK=""
DNS_ENV=""

function configure_dns() {
  local choice
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DNS provider" --menu \
    "\nSelect the DNS provider that hosts $DOMAIN (used for the DNS-01 challenge):\n" 20 78 9 \
    "cloudflare" "Cloudflare" \
    "dnsimple" "DNSimple" \
    "gandi" "Gandi (Personal Access Token)" \
    "digitalocean" "DigitalOcean" \
    "hetzner" "Hetzner DNS" \
    "desec" "deSEC" \
    "porkbun" "Porkbun" \
    "route53" "AWS Route 53" \
    "manual" "Other (enter a caddy-dns module manually)" \
    3>&1 1>&2 2>&3) || exit 0

  case "$choice" in
  cloudflare)
    DNS_PROVIDER="cloudflare"
    DNS_MODULE="github.com/caddy-dns/cloudflare"
    ask_secret "Cloudflare API token" "\nEnter a Cloudflare API token with Zone:DNS:Edit permission for ${DOMAIN}:"
    DNS_ENV="CLOUDFLARE_API_TOKEN=${REPLY_VAL}"
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns cloudflare {env.CLOUDFLARE_API_TOKEN}\n\t}')
    ;;
  dnsimple)
    DNS_PROVIDER="dnsimple"
    DNS_MODULE="github.com/caddy-dns/dnsimple"
    ask_secret "DNSimple API token" "\nEnter your DNSimple API access token (an ACCOUNT token is recommended):"
    local token="$REPLY_VAL"
    ask_text "DNSimple Account ID (optional)" "\nOnly needed for a USER token. Leave blank when using an ACCOUNT token." ""
    if [[ -n "$REPLY_VAL" ]]; then
      DNS_ENV=$(printf 'DNSIMPLE_API_ACCESS_TOKEN=%s\nDNSIMPLE_ACCOUNT_ID=%s' "$token" "$REPLY_VAL")
      DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns dnsimple {\n\t\t\taccount_id {env.DNSIMPLE_ACCOUNT_ID}\n\t\t\tapi_access_token {env.DNSIMPLE_API_ACCESS_TOKEN}\n\t\t}\n\t}')
    else
      DNS_ENV="DNSIMPLE_API_ACCESS_TOKEN=${token}"
      DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns dnsimple {env.DNSIMPLE_API_ACCESS_TOKEN}\n\t}')
    fi
    ;;
  gandi)
    DNS_PROVIDER="gandi"
    DNS_MODULE="github.com/caddy-dns/gandi"
    ask_secret "Gandi Personal Access Token" "\nEnter your Gandi Personal Access Token (PAT). Legacy API keys are no longer supported:"
    DNS_ENV="GANDI_BEARER_TOKEN=${REPLY_VAL}"
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns gandi {env.GANDI_BEARER_TOKEN}\n\t}')
    ;;
  digitalocean)
    DNS_PROVIDER="digitalocean"
    DNS_MODULE="github.com/caddy-dns/digitalocean"
    ask_secret "DigitalOcean API token" "\nEnter a DigitalOcean personal access token with write scope:"
    DNS_ENV="DO_AUTH_TOKEN=${REPLY_VAL}"
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns digitalocean {env.DO_AUTH_TOKEN}\n\t}')
    ;;
  hetzner)
    DNS_PROVIDER="hetzner"
    DNS_MODULE="github.com/caddy-dns/hetzner"
    ask_secret "Hetzner DNS API token" "\nEnter your Hetzner DNS API token:"
    DNS_ENV="HETZNER_API_TOKEN=${REPLY_VAL}"
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns hetzner {env.HETZNER_API_TOKEN}\n\t}')
    ;;
  desec)
    DNS_PROVIDER="desec"
    DNS_MODULE="github.com/caddy-dns/desec"
    ask_secret "deSEC API token" "\nEnter your deSEC API token:"
    DNS_ENV="DESEC_TOKEN=${REPLY_VAL}"
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns desec {env.DESEC_TOKEN}\n\t}')
    ;;
  porkbun)
    DNS_PROVIDER="porkbun"
    DNS_MODULE="github.com/caddy-dns/porkbun"
    ask_secret "Porkbun API key" "\nEnter your Porkbun API key (pk1_...):"
    local pk="$REPLY_VAL"
    ask_secret "Porkbun secret key" "\nEnter your Porkbun secret API key (sk1_...):"
    DNS_ENV=$(printf 'PORKBUN_API_KEY=%s\nPORKBUN_API_SECRET_KEY=%s' "$pk" "$REPLY_VAL")
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns porkbun {\n\t\t\tapi_key {env.PORKBUN_API_KEY}\n\t\t\tapi_secret_key {env.PORKBUN_API_SECRET_KEY}\n\t\t}\n\t}')
    ;;
  route53)
    DNS_PROVIDER="route53"
    DNS_MODULE="github.com/caddy-dns/route53"
    ask_secret "AWS Access Key ID" "\nEnter an AWS Access Key ID with Route 53 record permissions:"
    local akid="$REPLY_VAL"
    ask_secret "AWS Secret Access Key" "\nEnter the matching AWS Secret Access Key:"
    DNS_ENV=$(printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s' "$akid" "$REPLY_VAL")
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns route53\n\t}')
    ;;
  manual)
    ask_text "caddy-dns module" "\nEnter the full module path, e.g. github.com/caddy-dns/njalla:" "github.com/caddy-dns/"
    DNS_MODULE="$REPLY_VAL"
    ask_text "Provider keyword" "\nThe Caddyfile 'dns' keyword for this provider:" "${DNS_MODULE##*/}"
    local kw="$REPLY_VAL"
    DNS_PROVIDER="$kw"
    local env_name
    env_name="$(echo "$kw" | tr '[:lower:]-' '[:upper:]_')_TOKEN"
    ask_secret "$kw API token" "\nEnter the API token for ${kw} (will be stored as env ${env_name}):"
    DNS_ENV="${env_name}=${REPLY_VAL}"
    DNS_TLS_BLOCK=$(printf '\ttls {\n\t\tdns %s {env.%s}\n\t}' "$kw" "$env_name")
    ;;
  *) exit 0 ;;
  esac
}

if [[ "$CHALLENGE" == "dns" ]]; then
  configure_dns
fi

EMAIL=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "ACME Email (optional)" --inputbox \
  "\nOptional: email address for the Let's Encrypt account / expiry notices. Leave blank to skip." \
  11 70 "" 3>&1 1>&2 2>&3) || exit 0

# Warn before overwriting an existing site definition
if pct exec "$CTID" -- test -f "/etc/caddy/sites/${DOMAIN}.caddy" 2>/dev/null; then
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "Site exists" \
    --yesno "A Caddy site for ${DOMAIN} already exists in CT ${CTID}.\n\nOverwrite it with localhost:${PORT}?" 10 60 || exit 0
fi

header_info
msg_info "Configuring Caddy reverse proxy in CT $CTID ($DOMAIN -> localhost:$PORT, ${CHALLENGE} challenge${DNS_PROVIDER:+/$DNS_PROVIDER})"

INSTALL_SCRIPT=$(
  cat <<'EOSCRIPT'
set -e

DOMAIN="$1"
PORT="$2"
EMAIL="$3"
CHALLENGE="$4"
DNS_PROVIDER="$5"
DNS_MODULE="$6"
DNS_TLS_BLOCK="$7"
DNS_ENV="$8"

UPSTREAM="localhost:${PORT}"
CADDYFILE="/etc/caddy/Caddyfile"
SITES_DIR="/etc/caddy/sites"
ENV_FILE="/etc/caddy/caddy.env"

is_alpine() { [ -f /etc/alpine-release ]; }

set_env_var() { # key value — upsert into ENV_FILE
  _k="$1"
  _v="$2"
  touch "$ENV_FILE"
  if grep -q "^${_k}=" "$ENV_FILE"; then
    _tmp=$(mktemp)
    grep -v "^${_k}=" "$ENV_FILE" >"$_tmp"
    mv "$_tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$_k" "$_v" >>"$ENV_FILE"
}

# ── 1. Install Caddy if missing ──
FRESH=0
if ! command -v caddy >/dev/null 2>&1; then
  FRESH=1
  if is_alpine; then
    echo "[INFO] Alpine Linux detected, installing Caddy via apk..."
    if ! grep -q "^[^#].*community" /etc/apk/repositories 2>/dev/null; then
      ALPINE_VERSION=$(cut -d. -f1,2 /etc/alpine-release)
      echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >>/etc/apk/repositories
    fi
    apk update
    apk add --no-cache caddy
    rc-update add caddy default 2>/dev/null || true
  else
    echo "[INFO] Debian/Ubuntu detected, installing Caddy from the official repo..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
      gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      >/etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null
  fi
fi

mkdir -p "$SITES_DIR"

# ── 2. Base Caddyfile (imports per-domain site files) ──
# Fresh install: write a clean Caddyfile. Existing install: keep the user's
# config and just ensure the import directive is present.
if [ "$FRESH" = 1 ] || [ ! -f "$CADDYFILE" ]; then
  {
    if [ -n "$EMAIL" ]; then
      printf '{\n\temail %s\n}\n\n' "$EMAIL"
    fi
    printf 'import %s/*.caddy\n' "$SITES_DIR"
  } >"$CADDYFILE"
else
  if ! grep -qF "import ${SITES_DIR}/*.caddy" "$CADDYFILE"; then
    printf '\nimport %s/*.caddy\n' "$SITES_DIR" >>"$CADDYFILE"
  fi
fi

# ── 3. DNS-01: credentials + provider plugin ──
if [ "$CHALLENGE" = "dns" ]; then
  if is_alpine; then
    echo "[ERROR] DNS-01 plugin auto-install is not supported on Alpine's caddy package."
    echo "[ERROR] Build caddy with: xcaddy build --with ${DNS_MODULE}"
    echo "[ERROR] then re-run this add-on (the existing plugin will be detected)."
    exit 1
  fi

  # Secrets go into a root-only env file, referenced from the Caddyfile via
  # {env.*} placeholders so they never appear in the per-domain site files.
  printf '%s\n' "$DNS_ENV" | while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    set_env_var "${pair%%=*}" "${pair#*=}"
  done
  chmod 600 "$ENV_FILE"

  # systemd reads EnvironmentFile only at start, so a restart (not reload) is
  # required further down for the variables to reach Caddy.
  if command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/caddy.service.d
    cat >/etc/systemd/system/caddy.service.d/override.conf <<'EOF'
[Service]
EnvironmentFile=-/etc/caddy/caddy.env
EOF
    systemctl daemon-reload
  fi

  # Install the DNS provider plugin into the official caddy binary if absent.
  if ! caddy list-modules 2>/dev/null | grep -q "dns.providers.${DNS_PROVIDER}"; then
    echo "[INFO] Installing Caddy DNS plugin: ${DNS_MODULE} (this rebuilds the caddy binary)..."
    caddy add-package "${DNS_MODULE}"
  else
    echo "[INFO] Caddy DNS plugin for ${DNS_PROVIDER} already present"
  fi
fi

# ── 4. Per-domain reverse proxy definition ──
SITE_FILE="${SITES_DIR}/${DOMAIN}.caddy"
{
  printf '%s {\n' "$DOMAIN"
  if [ -n "$DNS_TLS_BLOCK" ]; then
    printf '%s\n' "$DNS_TLS_BLOCK"
  fi
  printf '\treverse_proxy %s\n' "$UPSTREAM"
  printf '}\n'
} >"$SITE_FILE"

# ── 5. Validate, then apply ──
if ! caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
  echo "[ERROR] Caddy configuration is invalid; reverting changes for ${DOMAIN}"
  rm -f "$SITE_FILE"
  caddy validate --adapter caddyfile --config "$CADDYFILE" || true
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable caddy >/dev/null 2>&1 || true
  # DNS-01 just (re)wrote the EnvironmentFile, which only applies on start.
  if [ "$CHALLENGE" = "dns" ]; then
    systemctl restart caddy
  else
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
  fi
else
  rc-service caddy reload 2>/dev/null || rc-service caddy restart 2>/dev/null || rc-service caddy start
fi

echo "[INFO] Caddy is serving ${DOMAIN} -> ${UPSTREAM}"
EOSCRIPT
)

pct exec "$CTID" -- sh -c "$INSTALL_SCRIPT" caddy-addon \
  "$DOMAIN" "$PORT" "$EMAIL" "$CHALLENGE" "$DNS_PROVIDER" "$DNS_MODULE" "$DNS_TLS_BLOCK" "$DNS_ENV"

# Tag the container
CTID_CONFIG_PATH="/etc/pve/lxc/${CTID}.conf"
TAGS=$(awk -F': ' '/^tags:/ {print $2}' "$CTID_CONFIG_PATH")
case ";${TAGS};" in
*";caddy;"*) ;;
*) TAGS="${TAGS:+$TAGS; }caddy" && pct set "$CTID" -tags "$TAGS" ;;
esac

msg_ok "Caddy reverse proxy configured on CT $CTID"
echo
msg_info "Site:     https://${DOMAIN}"
msg_info "Upstream: localhost:${PORT} (inside CT $CTID)"
msg_info "Config:   /etc/caddy/sites/${DOMAIN}.caddy  (imported by /etc/caddy/Caddyfile)"
echo
if [[ "$CHALLENGE" == "dns" ]]; then
  msg_info "TLS via DNS-01 (${DNS_PROVIDER}). For certificate issuance to succeed:"
  echo "   • the API credentials must be allowed to edit DNS records for ${DOMAIN}"
  echo "   • the LXC needs outbound internet access (to Let's Encrypt + the ${DNS_PROVIDER} API)"
  echo "   • a service must be listening on localhost:${PORT} inside CT $CTID"
  echo "   • the host need NOT be reachable on ports 80/443 — works for Tailscale-only domains"
  echo
  msg_info "Secrets stored in /etc/caddy/caddy.env (chmod 600), loaded via a systemd EnvironmentFile drop-in."
else
  msg_info "TLS via HTTP/TLS-ALPN. For certificate issuance to succeed:"
  echo "   • ${DOMAIN} must resolve (DNS A/AAAA) to this host's public IP"
  echo "   • ports 80 and 443 must be forwarded/reachable from the internet"
  echo "   • a service must be listening on localhost:${PORT} inside CT $CTID"
fi
echo
msg_info "Re-run this script to proxy additional domains."
msg_info "To remove a proxy: delete /etc/caddy/sites/<domain>.caddy in the CT and reload Caddy."
