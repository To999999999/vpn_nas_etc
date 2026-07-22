#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/$WG_IF.conf"

SERVER_PORT="51820"
SERVER_VPN_IP="10.7.0.1"
VPN_NET="10.7.0.0/24"
CLIENT_DNS="$SERVER_VPN_IP"

YES=0
missing=()

usage() {
  cat <<EOF
Usage:
  $0                 Install WireGuard server
  $0 -c USER [...]   Create one or more clients
  $0 -r USER [...]   Remove one or more clients
  $0 -u              List clients
  $0 -U              Uninstall WireGuard config
  $0 -y              Auto-confirm
  $0 -h              Show this help

Examples:
  $0
  $0 -y
  $0 -c boby
  $0 -c boby john albert
  $0 -c boby john -y
  $0 -r boby -y
  $0 -u
  $0 -U -y
EOF
}

die() {
  echo "Error: $*" >&2
  echo
  usage
  exit 1
}

confirm() {
  local message="$1"
  local answer

  echo "$message"

  if [[ "$YES" -eq 1 ]]; then
    echo "Auto-confirmed with -y."
    return 0
  fi

  read -rp "Are you sure? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

parse_global_flags() {
  local args=()

  for arg in "$@"; do
    case "$arg" in
      -y|--yes)
        YES=1
        ;;
      *)
        args+=("$arg")
        ;;
    esac
  done

  set -- "${args[@]}"
  ARGS=("$@")
}

check_requirements() {
  [[ $EUID -eq 0 ]] || die "Run as root."
  [[ -e /etc/debian_version ]] || die "Debian is required."
  [[ $(grep -oE '[0-9]+' /etc/debian_version | head -1) -ge 11 ]] || die "Debian 11+ is required."
  [[ $(uname -r | cut -d. -f1) -ge 3 ]] || die "Kernel too old."

  command -v systemd-detect-virt >/dev/null && \
    systemd-detect-virt -cq && die "Containers are not supported."

  for cmd in wg wg-quick nft qrencode systemctl ip awk grep sed sysctl; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done

  [[ ${#missing[@]} -eq 0 ]] || {
    echo "Missing requirements: ${missing[*]}"
    echo
    echo "Install them with:"
    echo "apt-get update && apt-get install -y wireguard wireguard-tools nftables qrencode"
    exit 1
  }
}

sanitize_name() {
  sed 's/[^0-9A-Za-z_-]/_/g' <<< "$1"
}

detect_endpoint() {
  local ipv6 ipv4

  ipv6="$(ip -6 addr show scope global \
    | awk '/inet6/ {print $2}' \
    | cut -d/ -f1 \
    | grep -vE '^(fc|fd)' \
    | head -1 || true)"

  if [[ -n "$ipv6" ]]; then
    echo "$ipv6"
    return
  fi

  ipv4="$(ip -4 route get 1.1.1.1 \
    | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
    | head -1 || true)"

  [[ -n "$ipv4" ]] || die "Could not detect endpoint IP."

  echo "$ipv4"
}

format_endpoint() {
  local endpoint="$1"

  if [[ "$endpoint" == *:* ]]; then
    echo "[$endpoint]"
  else
    echo "$endpoint"
  fi
}

detect_wan_if() {
  ip route get 1.1.1.1 \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
    | head -1
}

next_client_ip() {
  local i=2

  while grep -q "AllowedIPs = 10.7.0.$i/32" "$WG_CONF" 2>/dev/null; do
    ((i++))
    [[ "$i" -lt 255 ]] || die "VPN subnet is full."
  done

  echo "10.7.0.$i"
}

install_server() {
  local endpoint private wan_if

  [[ ! -e "$WG_CONF" ]] || {
    echo "WireGuard server already installed."
    return
  }

  endpoint="$(detect_endpoint)"
  wan_if="$(detect_wan_if)"
  [[ -n "$wan_if" ]] || die "Could not detect WAN interface."

  mkdir -p "$WG_DIR" /etc/nftables.d
  chmod 700 "$WG_DIR"

  private="$(wg genkey)"

  cat > "$WG_CONF" <<EOF
# ENDPOINT $endpoint

[Interface]
Address = $SERVER_VPN_IP/24
PrivateKey = $private
ListenPort = $SERVER_PORT
EOF

  chmod 600 "$WG_CONF"

  cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
EOF

  sysctl --system >/dev/null

  cat > /etc/nftables.d/wireguard.nft <<EOF
table inet wireguard {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $VPN_NET oifname "$wan_if" masquerade
  }
}
EOF

  grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf || \
    echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf

  systemctl enable --now nftables
  systemctl restart nftables

  systemctl enable --now "wg-quick@$WG_IF"

  echo "WireGuard server installed."
  echo "Detected endpoint: $endpoint"
}

create_client() {
  local raw client ip private public psk server_public endpoint port file

  raw="$1"
  client="$(sanitize_name "$raw")"

  [[ -n "$client" ]] || die "Invalid client name: $raw"
  [[ "$client" == "$raw" ]] || echo "Client name sanitized: $raw -> $client"

  grep -q "^# BEGIN_PEER $client$" "$WG_CONF" 2>/dev/null && die "Client already exists: $client"

  ip="$(next_client_ip)"
  private="$(wg genkey)"
  public="$(wg pubkey <<< "$private")"
  psk="$(wg genpsk)"

  server_public="$(grep '^PrivateKey' "$WG_CONF" | awk '{print $3}' | wg pubkey)"
  endpoint="$(grep '^# ENDPOINT' "$WG_CONF" | awk '{print $3}')"
  endpoint="$(format_endpoint "$endpoint")"
  port="$(grep '^ListenPort' "$WG_CONF" | awk '{print $3}')"

  file="$HOME/$client.conf"

  cat >> "$WG_CONF" <<EOF

# BEGIN_PEER $client
[Peer]
PublicKey = $public
PresharedKey = $psk
AllowedIPs = $ip/32
# END_PEER $client
EOF

  cat > "$file" <<EOF
[Interface]
PrivateKey = $private
Address = $ip/24
DNS = $CLIENT_DNS

[Peer]
PublicKey = $server_public
PresharedKey = $psk
Endpoint = $endpoint:$port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  echo
  echo "QR code for $client:"
  qrencode -t UTF8 < "$file" || true
  echo
  echo "Client created: $client"
  echo "Config: $file"
}

create_clients() {
  [[ -e "$WG_CONF" ]] || install_server

  for client in "$@"; do
    create_client "$client"
  done

  wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>/dev/null || true
}

remove_client() {
  local raw client pubkey

  raw="$1"
  client="$(sanitize_name "$raw")"

  [[ -e "$WG_CONF" ]] || die "WireGuard is not installed."
  grep -q "^# BEGIN_PEER $client$" "$WG_CONF" || die "Client not found: $client"

  pubkey="$(sed -n "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/p" "$WG_CONF" \
    | awk '/PublicKey/ {print $3}')"

  wg set "$WG_IF" peer "$pubkey" remove 2>/dev/null || true
  sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" "$WG_CONF"

  echo "Client removed: $client"
}

remove_clients() {
  for client in "$@"; do
    remove_client "$client"
  done
}

list_clients() {
  [[ -e "$WG_CONF" ]] || die "WireGuard is not installed."

  if ! grep -q '^# BEGIN_PEER' "$WG_CONF"; then
    echo "No clients."
    return
  fi

  grep '^# BEGIN_PEER' "$WG_CONF" | awk '{print $3}'
}

uninstall_wireguard() {
  [[ -e "$WG_CONF" ]] || die "WireGuard is not installed."

  systemctl disable --now "wg-quick@$WG_IF" || true

  rm -f /etc/sysctl.d/99-wireguard.conf
  rm -f /etc/nftables.d/wireguard.nft
  sed -i '/include "\/etc\/nftables.d\/\*.nft"/d' /etc/nftables.conf 2>/dev/null || true
  systemctl restart nftables || true

  rm -rf "$WG_DIR"

  echo "WireGuard removed."
}

main() {
  parse_global_flags "$@"
  set -- "${ARGS[@]}"

  check_requirements

  case "${1:-install}" in
    install)
      [[ $# -eq 0 ]] || die "Invalid request."
      confirm "WireGuard VPN server will be installed." || exit 0
      install_server
      ;;

    -c)
      shift
      [[ $# -gt 0 ]] || die "Missing client name."

      if [[ -e "$WG_CONF" ]]; then
        confirm "Client(s) will be created: $*" || exit 0
      else
        confirm "WireGuard VPN server will be installed and client(s) will be created: $*" || exit 0
      fi

      create_clients "$@"
      ;;

    -r)
      shift
      [[ $# -gt 0 ]] || die "Missing client name."
      confirm "Client(s) will be removed: $*" || exit 0
      remove_clients "$@"
      ;;

    -u)
      [[ $# -eq 1 ]] || die "Invalid request."
      list_clients
      ;;

    -U)
      [[ $# -eq 1 ]] || die "Invalid request."
      confirm "WireGuard VPN server and all clients will be removed." || exit 0
      uninstall_wireguard
      ;;

    -h|--help)
      usage
      ;;

    *)
      die "Invalid request."
      ;;
  esac
}

main "$@"
