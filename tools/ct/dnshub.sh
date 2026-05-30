#!/usr/bin/env bash

# Copyright (c) 2026 Miguel Eduardo Gil Biraud
# Author: Miguel Eduardo Gil Biraud
# License: MIT
# Source: https://github.com/mgilbir/dnshub
#
# Creates a dnshub LXC from scratch on a Proxmox VE host: an unprivileged
# Debian container running the dnshub multi-homed DNS + mDNS resolver as an
# unprivileged systemd service.
#
# Run it ON the Proxmox VE host (interactive — use a real terminal):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mgilbir/proxmox-scripts/main/tools/ct/dnshub.sh)"

set -Eeuo pipefail
trap 'echo -e "\n[ERROR] in line $LINENO: exit code $?"' ERR

REPO="mgilbir/dnshub"
BT="Proxmox VE Helper Scripts"

function header_info() {
  clear
  cat <<"EOF"
     __           __        __
  ____/ /___  _____/ /_  __  __/ /_
 / __  / __ \/ ___/ __ \/ / / / __ \
/ /_/ / / / (__  ) / / / /_/ / /_/ /
\__,_/_/ /_/____/_/ /_/\__,_/_.___/   DNS + mDNS for segmented LANs

EOF
}

function msg_info() { echo -e " \e[1;36m➤\e[0m $1"; }
function msg_ok() { echo -e " \e[1;32m✔\e[0m $1"; }
function msg_error() { echo -e " \e[1;31m✖\e[0m $1"; }

# whiptail helpers — set REPLY_VAL; cancel aborts the script.
REPLY_VAL=""
function ask_text() { # title msg default
  REPLY_VAL=$(whiptail --backtitle "$BT" --title "$1" --inputbox "$2" 12 76 "${3:-}" 3>&1 1>&2 2>&3) || exit 0
}
function ask_menu() { # title msg tag1 item1 tag2 item2 ...
  local title=$1 msg=$2
  shift 2
  REPLY_VAL=$(whiptail --backtitle "$BT" --title "$title" --menu "$msg" 18 76 8 "$@" 3>&1 1>&2 2>&3) || exit 0
}

header_info

if ! command -v pveversion &>/dev/null; then
  msg_error "Run this on the Proxmox VE host, not inside a container."
  exit 1
fi

while true; do
  read -rp "Create a new dnshub LXC on this Proxmox host? (y/n) " yn
  case "$yn" in
  [Yy]*) break ;;
  [Nn]*) exit 0 ;;
  *) echo "Please answer y or n." ;;
  esac
done

# ---------------------------------------------------------------- container ---
header_info
ask_text "Container ID" "Numeric CTID for the new container." "$(pvesh get /cluster/nextid)"
CTID="$REPLY_VAL"
ask_text "Hostname" "Container hostname." "dnshub"
HOSTNAME="$REPLY_VAL"
ask_text "Cores" "vCPU cores." "1"
CORES="$REPLY_VAL"
ask_text "Memory (MB)" "RAM in MB." "768"
RAM="$REPLY_VAL"
ask_text "Disk (GB)" "Root disk in GB." "4"
DISK="$REPLY_VAL"

# storage for the rootfs (container images)
mapfile -t STORES < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1{print $1}')
[[ ${#STORES[@]} -eq 0 ]] && { msg_error "No storage supports container rootfs."; exit 1; }
STORE_ARGS=(); for s in "${STORES[@]}"; do STORE_ARGS+=("$s" ""); done
ask_menu "Root storage" "Where to put the container disk." "${STORE_ARGS[@]}"
STORAGE="$REPLY_VAL"

# template — find a Debian one, offer to download if none
TEMPLATE="$(pveam list local 2>/dev/null | awk '/debian-1[0-9]-standard/{print $1; exit}')"
if [[ -z "$TEMPLATE" ]]; then
  TPL="$(pveam available --section system 2>/dev/null | awk '/debian-1[0-9]-standard/{t=$2} END{print t}')"
  [[ -z "$TPL" ]] && { msg_error "No Debian template available via pveam."; exit 1; }
  msg_info "Downloading template $TPL ..."
  pveam download local "$TPL" >/dev/null
  TEMPLATE="local:vztmpl/$TPL"
fi
msg_ok "Template: $TEMPLATE"

# ------------------------------------------------------------------ network ---
BRIDGES=()
for d in /sys/class/net/vmbr*; do [[ -e "$d" ]] && BRIDGES+=("$(basename "$d")"); done
[[ ${#BRIDGES[@]} -eq 0 ]] && BRIDGES=(vmbr0)
BR_ARGS=(); for b in "${BRIDGES[@]}"; do BR_ARGS+=("$b" ""); done
ask_menu "Bridge" "Bridge the container attaches to (must carry the VLAN tags if multi-homed)." "${BR_ARGS[@]}"
BRIDGE="$REPLY_VAL"

ask_menu "Network mode" "How dnshub attaches to your network." \
  single "One NIC on one network (simple / first test)" \
  multi  "Multi-homed: a NIC per VLAN at .<octet> (needs a VLAN-aware bridge + trunk)"
NETMODE="$REPLY_VAL"

NET_ARGS=()     # pct --netN args
declare -a VLAN_NAME VLAN_LISTEN  # for config generation
if [[ "$NETMODE" == "single" ]]; then
  ask_text "VLAN tag" "VLAN tag for this NIC (blank = untagged)." ""
  TAG="$REPLY_VAL"
  ask_text "IP / CIDR" "Static address (e.g. 10.0.0.30/24) or 'dhcp'." "dhcp"
  IPADDR="$REPLY_VAL"
  ask_text "Gateway" "Default gateway (blank for none / dhcp)." ""
  GW="$REPLY_VAL"
  net="name=eth0,bridge=${BRIDGE}"
  [[ -n "$TAG" ]] && net="${net},tag=${TAG}"
  net="${net},ip=${IPADDR}"
  [[ "$IPADDR" != "dhcp" && -n "$GW" ]] && net="${net},gw=${GW}"
  NET_ARGS+=(--net0 "$net")
  VLAN_NAME=(DEFAULT)
  VLAN_LISTEN=("${IPADDR%%/*}")
else
  ask_text "Host octet" "Last octet for dnshub on every VLAN (the .X resolver)." "30"
  OCTET="$REPLY_VAL"
  ask_text "VLANs" "Space-separated NAME:TAG:SUBNET entries, e.g.\nclients:20:10.0.20.0/24 lab:30:10.0.30.0/24" ""
  read -ra ENTRIES <<<"$REPLY_VAL"
  [[ ${#ENTRIES[@]} -eq 0 ]] && { msg_error "No VLANs entered."; exit 1; }
  # default-route VLAN
  GW_ARGS=(); for e in "${ENTRIES[@]}"; do GW_ARGS+=("${e%%:*}" ""); done
  ask_menu "Default route" "Which VLAN carries the default route (upstream egress)." "${GW_ARGS[@]}"
  GW_VLAN="$REPLY_VAL"
  i=0
  for e in "${ENTRIES[@]}"; do
    IFS=: read -r name tag subnet <<<"$e"
    base="${subnet%.*}"; mask="${subnet#*/}"; [[ "$mask" == "$subnet" ]] && mask=24
    listen="${base}.${OCTET}"
    net="name=eth${i},bridge=${BRIDGE},tag=${tag},ip=${listen}/${mask}"
    [[ "$name" == "$GW_VLAN" ]] && net="${net},gw=${base}.1"
    NET_ARGS+=("--net${i}" "$net")
    VLAN_NAME+=("$name"); VLAN_LISTEN+=("$listen")
    i=$((i + 1))
  done
fi

# ----------------------------------------------------------------- upstream ---
ask_menu "Upstream" "Where dnshub forwards queries." \
  nextdns    "NextDNS (DoT, per-profile)" \
  cloudflare "Cloudflare 1.1.1.1 (DoT)" \
  quad9      "Quad9 9.9.9.9 (DoT)" \
  google     "Google 8.8.8.8 (plain Do53)" \
  custom     "Custom server [+ TLS server name]"
UP="$REPLY_VAL"

UP_SERVERS=""   # global NextDNS servers block (nextdns only)
UP_SNI=""       # per-VLAN profile sni (nextdns only)
UP_OVERRIDE=""  # explicit per-VLAN upstream list (others)
case "$UP" in
nextdns)
  ask_text "NextDNS profile ID" "Your NextDNS profile id (the <id> in <id>.dns.nextdns.io)." ""
  UP_SNI="${REPLY_VAL}.dns.nextdns.io"
  UP_SERVERS="45.90.28.0:853, 45.90.30.0:853"
  ;;
cloudflare) UP_OVERRIDE='{server: "1.1.1.1:853", sni: cloudflare-dns.com}, {server: "1.0.0.1:853", sni: cloudflare-dns.com}' ;;
quad9)      UP_OVERRIDE='{server: "9.9.9.9:853", sni: dns.quad9.net}, {server: "149.112.112.112:853", sni: dns.quad9.net}' ;;
google)     UP_OVERRIDE='{server: "8.8.8.8:53"}, {server: "8.8.4.4:53"}' ;;
custom)
  ask_text "Server" "Upstream server as ip:port (e.g. 10.0.0.5:53)." ""
  cs="$REPLY_VAL"
  ask_text "TLS server name" "TLS server name for DoT (blank = plain Do53)." ""
  if [[ -n "$REPLY_VAL" ]]; then UP_OVERRIDE="{server: \"${cs}\", sni: ${REPLY_VAL}}"; else UP_OVERRIDE="{server: \"${cs}\"}"; fi
  ;;
esac

# ------------------------------------------------------------------- binary ---
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
BIN="/tmp/dnshub-${CTID}.bin"
URL="https://github.com/${REPO}/releases/latest/download/dnshub-linux-${ARCH}"
msg_info "Fetching dnshub binary ($ARCH) ..."
if ! curl -fsSL "$URL" -o "$BIN" 2>/dev/null; then
  msg_error "Could not download from the release (repo may be private / no release yet)."
  ask_text "Binary URL or local path" "Provide a URL or a path on this host to the linux-${ARCH} binary." ""
  src="$REPLY_VAL"
  if [[ -f "$src" ]]; then cp "$src" "$BIN"; else curl -fsSL "$src" -o "$BIN"; fi
fi
chmod +x "$BIN"
msg_ok "Binary ready ($(du -h "$BIN" | cut -f1))"

# ---------------------------------------------------------------- create CT ---
msg_info "Creating LXC $CTID ($HOSTNAME) ..."
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" --unprivileged 1 \
  --cores "$CORES" --memory "$RAM" --swap "$((RAM / 2))" \
  --rootfs "${STORAGE}:${DISK}" --onboot 1 --features nesting=1 \
  "${NET_ARGS[@]}" >/dev/null
pct start "$CTID"
sleep 3
msg_ok "Container started"

# ------------------------------------------------------------------ config ---
CONF="/tmp/dnshub-${CTID}.yaml"
{
  echo "upstream:"
  [[ -n "$UP_SERVERS" ]] && echo "  servers: [${UP_SERVERS}]"
  echo "  timeout: 5s"
  echo "cache: {}"
  echo "dns:"
  echo "  port: 53"
  echo "  lan_suffix: lan"
  echo "  vlans:"
  for idx in "${!VLAN_NAME[@]}"; do
    line="    - {name: ${VLAN_NAME[$idx]}, listen: ${VLAN_LISTEN[$idx]}"
    if [[ -n "$UP_SNI" ]]; then
      line="${line}, profile_sni: ${UP_SNI}"
    elif [[ -n "$UP_OVERRIDE" ]]; then
      line="${line}, upstream: [${UP_OVERRIDE}]"
    fi
    echo "${line}}"
  done
  echo "mdns: {enabled: false}"
  echo "metrics: {enabled: true, listen: \"0.0.0.0:9153\"}"
} >"$CONF"

# ------------------------------------------------------------ install in CT ---
msg_info "Installing dnshub in CT $CTID ..."
pct exec "$CTID" -- mkdir -p /etc/dnshub
pct push "$CTID" "$BIN" /usr/local/bin/dnshub --perms 0755
pct push "$CTID" "$CONF" /etc/dnshub/config.yaml --perms 0644
pct exec "$CTID" -- useradd --system --no-create-home --shell /usr/sbin/nologin --user-group dnshub 2>/dev/null || true
pct exec "$CTID" -- systemctl disable --now systemd-resolved 2>/dev/null || true

# multi-homed needs loose reverse-path filtering
if [[ "$NETMODE" == "multi" ]]; then
  pct exec "$CTID" -- sh -c 'printf "net.ipv4.conf.all.rp_filter = 2\nnet.ipv4.conf.default.rp_filter = 2\nnet.ipv4.ip_forward = 0\n" > /etc/sysctl.d/99-dnshub.conf && sysctl --system >/dev/null 2>&1 || true'
fi

# hardened systemd unit
pct exec "$CTID" -- sh -c 'cat > /etc/systemd/system/dnshub.service' <<'UNIT'
[Unit]
Description=dnshub multi-homed DNS + mDNS
Documentation=https://github.com/mgilbir/dnshub
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/dnshub serve -config /etc/dnshub/config.yaml
Restart=on-failure
RestartSec=2s
User=dnshub
Group=dnshub
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadOnlyPaths=/etc/dnshub

[Install]
WantedBy=multi-user.target
UNIT

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now dnshub
sleep 1

# tag the container
CFG="/etc/pve/lxc/${CTID}.conf"
TAGS="$(awk -F': ' '/^tags:/{print $2}' "$CFG" 2>/dev/null)"
case ";${TAGS};" in *";dnshub;"*) ;; *) pct set "$CTID" -tags "${TAGS:+$TAGS;}dnshub" ;; esac

rm -f "$BIN" "$CONF"

if pct exec "$CTID" -- systemctl is-active --quiet dnshub; then
  msg_ok "dnshub is running in CT $CTID"
else
  msg_error "dnshub failed to start — check: pct exec $CTID -- journalctl -u dnshub -n 30"
  exit 1
fi

echo
msg_ok "Done. Resolvers:"
for idx in "${!VLAN_NAME[@]}"; do
  echo "    ${VLAN_NAME[$idx]}: dig @${VLAN_LISTEN[$idx]} example.com"
done
mip="${VLAN_LISTEN[0]}"
[ "$mip" = "dhcp" ] && mip="<container-ip>"
echo "  Metrics: http://${mip}:9153/metrics"
[[ "$NETMODE" == "multi" ]] && echo "  Remember: vmbr0 must be VLAN-aware and the switch port a trunk carrying these tags."
