#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

WG_IF="wg0"
WG_PORT="${WG_PORT:-51820}"
WG_ENDPOINT_HOST="${WG_ENDPOINT_HOST:-}"
WG_FIREWALL="${WG_FIREWALL:-auto}"
WG_NETWORK="10.8.0.0/24"
WG_SERVER_ADDR="10.8.0.1/24"
FIRST_CLIENT="${FIRST_CLIENT:-client1}"
FIRST_CLIENT_ADDR="10.8.0.2/32"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
WG_DIR="/etc/wireguard"
CLIENT_DIR="${WG_DIR}/clients"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
WG_ENV="${WG_DIR}/${WG_IF}.env"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

valid_ipv4() {
    local octet
    local -a octets
    [[ "${1:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "${1}"
    for octet in "${octets[@]}"; do
        (( 10#${octet} <= 255 )) || return 1
    done
}

if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0"
fi

uninstall_wireguard() {
    local firewall port zone field value name rules tmp number scope owned other_tunnel=0 path backup
    [[ -f "${WG_CONF}" && -f "${WG_ENV}" ]] || die "No installed wg0 configuration and environment file found."
    exec 9>/run/lock/wg-user.lock
    flock 9
    # Read data, never source a configuration file as executable shell code.
    firewall="$(awk -F= '$1=="WG_FIREWALL" {print $2; exit}' "${WG_ENV}")"
    if [[ -z "${firewall}" ]]; then
        firewall="$(sed -n 's/^# Forwarding and NAT are persisted in \(ufw\|firewalld\)\.$/\1/p' "${WG_CONF}")"
        [[ -n "${firewall}" ]] || die "This configuration predates managed firewalls; uninstall it manually."
        echo "Older installation: untracked UDP/forwarding allow rules will be retained."
    fi
    [[ "${firewall}" == ufw || "${firewall}" == firewalld ]] || die "Invalid recorded firewall."
    port="$(awk -F= '$1=="WG_PORT" {print $2; exit}' "${WG_ENV}")"
    [[ -n "${port}" ]] || port="$(awk -F ' *= *' '$1=="ListenPort" {print $2; exit}' "${WG_CONF}")"
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] || die "Invalid WireGuard listen port."
    port=$((10#${port}))
    (( port >= 1 && port <= 65535 )) || die "Invalid WireGuard listen port."
    if [[ "${firewall}" == firewalld ]]; then
        command -v firewall-cmd >/dev/null || die "firewall-cmd is required for firewall cleanup."
        firewall-cmd --state >/dev/null || die "firewalld must be running for cleanup; no changes made."
        zone="$(awk -F= '$1=="WG_FIREWALL_ZONE" {print $2; exit}' "${WG_ENV}")"
        [[ -z "${zone}" || "${zone}" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid recorded firewalld zone."
    else
        command -v ufw >/dev/null || die "ufw is required for firewall cleanup."
        LC_ALL=C ufw status | grep -qx 'Status: active' || die "UFW must be active for cleanup; no changes made."
    fi
    echo "Removing wg0 and its saved client profiles..."
    systemctl disable --now "wg-quick@${WG_IF}"
    if [[ "${firewall}" == ufw ]]; then
        rules=/etc/ufw/before.rules
        [[ -f "${rules}" ]] || die "Missing ${rules}; service stopped, configuration retained."
        backup="$(awk -F= '$1=="WG_UFW_BACKUP" {print substr($0,index($0,"=")+1); exit}' "${WG_ENV}")"
        if [[ -n "${backup}" ]]; then
            [[ "${backup}" == /etc/ufw/before.rules.wireguard-backup.* && -f "${backup}" ]] ||
                die "Recorded UFW backup is missing or has an invalid path; configuration retained."
            cp -p -- "${backup}" "${rules}"
            rm -f -- "${backup}"
        else
            tmp="$(mktemp /etc/ufw/before.rules.uninstall.XXXXXX)"
            if ! awk '
                $0=="# BEGIN WIREGUARD wg0" {if(skip) exit 1; skip=1; next}
                $0=="# END WIREGUARD wg0" {if(!skip) exit 1; skip=0; after_marker=1; next}
                after_marker {after_marker=0; if($0=="") next}
                !skip {print}
                END {if(skip) exit 1}
            ' "${rules}" > "${tmp}"; then
                rm -f -- "${tmp}"
                die "Malformed WireGuard NAT markers; ${rules} was left unchanged."
            fi
            cat "${tmp}" > "${rules}"
            rm -f -- "${tmp}"
        fi
        # Delete only installer-tagged rules, in descending order as numbers shift.
        value="$(LC_ALL=C ufw status numbered)"
        while read -r number; do
            ufw --force delete "${number}"
        done < <(awk '/# wireguard-wg0-(udp|route)( |$)/ {line=$0; sub(/^\[ */, "",line); sub(/\].*$/, "",line); print line}' <<< "${value}" | sort -rn)
        ufw reload
    else
        # Do not reload: deleting runtime objects preserves unrelated runtime-only rules.
        if firewall-cmd --get-policies | tr ' ' '\n' | grep -qx "wg-${WG_IF}"; then
            firewall-cmd --policy="wg-${WG_IF}" --remove-ingress-zone="wg-${WG_IF}"
        fi
        if firewall-cmd --get-zones | tr ' ' '\n' | grep -qx "wg-${WG_IF}"; then
            if firewall-cmd --zone="wg-${WG_IF}" --query-interface="${WG_IF}" >/dev/null; then
                firewall-cmd --zone="wg-${WG_IF}" --remove-interface="${WG_IF}"
            fi
        fi
        if firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -qx "wg-${WG_IF}"; then
            firewall-cmd --permanent --delete-policy="wg-${WG_IF}"
        fi
        if firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx "wg-${WG_IF}"; then
            firewall-cmd --permanent --delete-zone="wg-${WG_IF}"
        fi
        if [[ -n "${zone}" ]]; then
            for scope in runtime permanent; do
                local -a options=()
                [[ "${scope}" != permanent ]] || options+=(--permanent)
                field="WG_PORT_OWNED_${scope^^}"
                owned="$(awk -F= -v key="${field}" '$1==key {print $2; exit}' "${WG_ENV}")"
                if [[ "${owned}" == 1 ]] && firewall-cmd "${options[@]}" --zone="${zone}" --query-port="${port}/udp" >/dev/null; then
                    firewall-cmd "${options[@]}" --zone="${zone}" --remove-port="${port}/udp"
                fi
            done
        fi
        firewall-cmd --check-config
    fi
    while read -r name; do
        [[ "${name}" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid saved client name; configuration retained."
        rm -f -- "${CLIENT_DIR}/${name}.conf"
    done < <(awk '$1=="#" && $2=="BEGIN_PEER" {print $3}' "${WG_CONF}")
    if [[ -f /etc/sysctl.d/99-wireguard.conf ]] &&
        [[ "$(cat /etc/sysctl.d/99-wireguard.conf)" == 'net.ipv4.ip_forward=1' ]]; then
        if [[ -f "${WG_DIR}/${WG_IF}.sysctl-backup" ]]; then
            cp -p -- "${WG_DIR}/${WG_IF}.sysctl-backup" /etc/sysctl.d/99-wireguard.conf
            rm -f -- "${WG_DIR}/${WG_IF}.sysctl-backup"
        else
            rm -f -- /etc/sysctl.d/99-wireguard.conf
        fi
    fi
    for path in "${WG_DIR}"/*.conf; do
        [[ ! -f "${path}" || "${path}" == "${WG_CONF}" ]] || other_tunnel=1
    done
    if (( other_tunnel == 0 )) && [[ -f /usr/local/bin/wg-user ]] &&
        grep -qx '# Installed by setup-wireguard.sh' /usr/local/bin/wg-user; then
        rm -f -- /usr/local/bin/wg-user
    fi
    rm -f -- "${WG_CONF}" "${WG_ENV}"
    # Only remove empty directories, keeping other tunnels and unrelated files.
    rmdir -- "${CLIENT_DIR}" "${WG_DIR}" 2>/dev/null || true
    echo "WireGuard wg0 uninstalled. Packages, SSH rules, and the firewall service were retained."
    echo "Runtime IPv4 forwarding is unchanged; the next reboot applies remaining system settings."
    [[ "${firewall}" != firewalld ]] || echo "Inactive runtime zone/policy objects disappear when firewalld next reloads."
}

case "${1:-install}" in
    install) (( $# <= 1 )) || die "Usage: $0 [install|uninstall]" ;;
    uninstall) (( $# == 1 )) || die "Usage: $0 uninstall"; uninstall_wireguard; exit 0 ;;
    *) die "Usage: $0 [install|uninstall]" ;;
esac

[[ -r /etc/os-release ]] || die "Cannot detect the operating system."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:24.04|ubuntu:26.04) OS_FAMILY=ubuntu ;;
    rocky:10|rocky:10.*) OS_FAMILY=rocky ;;
    *) die "Supported systems: Ubuntu 24.04/26.04 and Rocky Linux 10. Detected ${PRETTY_NAME:-unknown}." ;;
esac
case "${WG_FIREWALL}" in
    auto|ufw|firewalld) ;;
    *) die "WG_FIREWALL must be auto, ufw, or firewalld." ;;
esac

UFW_ACTIVE=0
FIREWALLD_ACTIVE=0
if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -qx 'Status: active'; then
    UFW_ACTIVE=1
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FIREWALLD_ACTIVE=1
fi
(( UFW_ACTIVE == 0 || FIREWALLD_ACTIVE == 0 )) || die "Both UFW and firewalld are active. Keep only one firewall manager active before installing."
if [[ "${WG_FIREWALL}" == auto ]]; then
    if (( FIREWALLD_ACTIVE )); then
        WG_FIREWALL=firewalld
    elif (( UFW_ACTIVE )); then
        WG_FIREWALL=ufw
    elif [[ "${OS_FAMILY}" == ubuntu ]]; then
        WG_FIREWALL=ufw
    else
        WG_FIREWALL=firewalld
    fi
fi
[[ "${OS_FAMILY}:${WG_FIREWALL}" != rocky:ufw ]] || die "Rocky Linux 10 uses firewalld; UFW is supported on Ubuntu only."
if [[ "${WG_FIREWALL}" == ufw ]]; then
    (( FIREWALLD_ACTIVE == 0 )) || die "firewalld is active. Use WG_FIREWALL=firewalld or switch firewall managers first."
    (( UFW_ACTIVE )) || die "Enable UFW before installing (allow your SSH port first). Ubuntu can also use an active firewalld with WG_FIREWALL=firewalld."
else
    (( UFW_ACTIVE == 0 )) || die "UFW is active. Use WG_FIREWALL=ufw or switch firewall managers first."
fi

[[ "${WG_PORT}" =~ ^[0-9]+$ ]] || die "WG_PORT must be between 1 and 65535."
WG_PORT=$((10#${WG_PORT}))
(( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "WG_PORT must be between 1 and 65535."
valid_ipv4 "${CLIENT_DNS}" || die "CLIENT_DNS must be a valid IPv4 address."
[[ "${FIRST_CLIENT}" =~ ^[A-Za-z0-9_-]+$ ]] || die "FIRST_CLIENT may contain only letters, numbers, underscore, and hyphen."
[[ -f "${SCRIPT_DIR}/wg-user" ]] || die "wg-user must be beside this installer. Extract the full archive, then run this script again."
[[ ! -e "${WG_CONF}" ]] || die "${WG_CONF} already exists. This installer will not overwrite an existing WireGuard setup."
[[ ! -e "${WG_ENV}" ]] || die "${WG_ENV} already exists. Review the existing WireGuard setup before installing."
[[ ! -e "${CLIENT_DIR}/${FIRST_CLIENT}.conf" ]] || die "${CLIENT_DIR}/${FIRST_CLIENT}.conf already exists. Move it before installing."

PUBLIC_INTERFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
[[ -n "${PUBLIC_INTERFACE}" ]] || die "Could not determine the server's outbound network interface."
[[ "${PUBLIC_INTERFACE}" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Unsupported outbound interface name."

detect_ssh_ports() {
    local listeners socket listen port session_port
    local -a candidates=()
    command -v ss >/dev/null 2>&1 || die "ss is required to detect running SSH ports. Install iproute2 (Ubuntu) or iproute (Rocky)."
    listeners="$(ss -H -ltnp)" || die "Cannot inspect listening TCP sockets; firewalld will not be activated."
    # Inspect running sockets rather than sshd_config, which may have changed.
    mapfile -t candidates < <(awk '/"sshd"/ { n=split($4,a,":"); print a[n] }' <<< "${listeners}")
    # Ubuntu can listen through systemd socket activation instead of sshd.
    for socket in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "${socket}"; then
            listen="$(systemctl show --property=Listen --value "${socket}")" || die "Cannot inspect ${socket}."
            while read -r port; do
                candidates+=("${port}")
            done < <(awk '{ for(i=2;i<=NF;i++) if($i=="(Stream)") { n=split($(i-1),a,":"); print a[n] } }' <<< "${listen}")
        fi
    done
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ _ session_port <<< "${SSH_CONNECTION}"
        candidates+=("${session_port}")
    fi
    SSH_PORTS=()
    for port in "${candidates[@]}"; do
        [[ "${port}" =~ ^[0-9]{1,5}$ ]] || continue
        port=$((10#${port}))
        (( port >= 1 && port <= 65535 )) || continue
        if awk -v port="${port}" '{ n=split($4,a,":"); if(a[n]==port) found=1 } END { exit !found }' <<< "${listeners}"; then
            SSH_PORTS+=("${port}")
        fi
    done
    (( ${#SSH_PORTS[@]} > 0 )) || die "No running SSH listener detected. Refusing to activate or reload firewalld."
    mapfile -t SSH_PORTS < <(printf '%s\n' "${SSH_PORTS[@]}" | sort -nu)
    printf 'Running SSH TCP ports: %s\n' "${SSH_PORTS[*]}"
}

FIREWALLD_MASKED_BY_INSTALLER=0
cleanup_firewalld_mask() {
    if (( FIREWALLD_MASKED_BY_INSTALLER )); then
        systemctl unmask --runtime firewalld.service
    fi
}
if [[ "${WG_FIREWALL}" == firewalld ]]; then
    detect_ssh_ports
    if (( FIREWALLD_ACTIVE == 0 )); then
        SERVICE_STATE="$(systemctl is-enabled firewalld.service 2>/dev/null || true)"
        [[ "${SERVICE_STATE}" != masked* ]] || die "firewalld is masked. Unmask it explicitly before installing."
        # APT may start services during installation. Block startup until SSH rules exist.
        systemctl mask --runtime firewalld.service
        FIREWALLD_MASKED_BY_INSTALLER=1
        trap cleanup_firewalld_mask EXIT
    fi
fi

echo "Installing WireGuard packages..."
if [[ "${OS_FAMILY}" == ubuntu ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard-tools qrencode curl iproute2 util-linux "${WG_FIREWALL}"
else
    dnf install -y epel-release
    dnf install -y wireguard-tools qrencode curl iproute util-linux firewalld
fi

protect_ssh_and_start_firewalld() {
    local zone port zones scope
    local -a offline_zones
    # Refresh after package installation and the endpoint prompt.
    detect_ssh_ports
    if (( FIREWALLD_ACTIVE == 0 )); then
        zones="$(firewall-offline-cmd --get-zones)" || die "Cannot read offline firewalld zones."
        read -r -a offline_zones <<< "${zones}"
        (( ${#offline_zones[@]} > 0 )) || die "No offline firewalld zones found."
        # Cover interface and source-based zones, including non-default SSH interfaces.
        for zone in "${offline_zones[@]}"; do
            for port in "${SSH_PORTS[@]}"; do
                firewall-offline-cmd --zone="${zone}" --add-port="${port}/tcp"
                firewall-offline-cmd --zone="${zone}" --query-port="${port}/tcp" >/dev/null
            done
        done
        firewall-offline-cmd --check-config
        cleanup_firewalld_mask
        FIREWALLD_MASKED_BY_INSTALLER=0
        systemctl enable --now firewalld.service
        firewall-cmd --state >/dev/null || die "firewalld did not start successfully."
        FIREWALLD_ACTIVE=1
    fi
    # Protect existing firewalld installations before the later reload as well.
    for scope in runtime permanent; do
        local -a options=()
        [[ "${scope}" != permanent ]] || options+=(--permanent)
        zones="$(firewall-cmd "${options[@]}" --get-zones)" || die "Cannot read firewalld zones."
        local -a active_zones
        read -r -a active_zones <<< "${zones}"
        (( ${#active_zones[@]} > 0 )) || die "No firewalld zones found."
        for zone in "${active_zones[@]}"; do
            for port in "${SSH_PORTS[@]}"; do
                firewall-cmd "${options[@]}" --zone="${zone}" --add-port="${port}/tcp"
                firewall-cmd "${options[@]}" --zone="${zone}" --query-port="${port}/tcp" >/dev/null
            done
        done
    done
}

configure_firewall() {
    local zone policy="wg-${WG_IF}" vpn_zone="wg-${WG_IF}" scope
    if [[ "${WG_FIREWALL}" == ufw ]]; then
        local rules=/etc/ufw/before.rules backup
        [[ -f "${rules}" ]] || die "Missing ${rules}."
        ! grep -Fq '# BEGIN WIREGUARD wg0' "${rules}" || die "WireGuard NAT rules already exist in ${rules}."
        backup="$(mktemp /etc/ufw/before.rules.wireguard-backup.XXXXXX)"
        cp -p -- "${rules}" "${backup}"
        # A separate NAT section preserves existing UFW tables and rules.
        {
            printf '# BEGIN WIREGUARD wg0\n*nat\n:POSTROUTING ACCEPT [0:0]\n'
            printf -- '-A POSTROUTING -s %s -o %s -j MASQUERADE\n' "${WG_NETWORK}" "${PUBLIC_INTERFACE}"
            printf 'COMMIT\n# END WIREGUARD wg0\n\n'
            cat "${backup}"
        } > "${rules}"
        local existing
        existing="$(ufw show added | tr -d "'" | sed 's/ comment .*//')"
        if ! grep -Fxq "ufw allow ${WG_PORT}/udp" <<< "${existing}"; then
            ufw allow "${WG_PORT}/udp" comment 'wireguard-wg0-udp'
        fi
        if ! grep -Fxq "ufw route allow in on ${WG_IF} out on ${PUBLIC_INTERFACE} from ${WG_NETWORK}" <<< "${existing}"; then
            ufw route allow in on "${WG_IF}" out on "${PUBLIC_INTERFACE}" from "${WG_NETWORK}" comment 'wireguard-wg0-route'
        fi
        WG_UFW_BACKUP="${backup}"
        if ! ufw reload; then
            cp -p -- "${backup}" "${rules}"
            ufw reload || true
            die "UFW reload failed; restored ${rules} from ${backup}."
        fi
        echo "UFW rules backup: ${backup}"
    else
        protect_ssh_and_start_firewalld
        zone="$(firewall-cmd --get-zone-of-interface="${PUBLIC_INTERFACE}" 2>/dev/null || true)"
        if [[ -z "${zone}" || "${zone}" == 'no zone' ]]; then
            zone="$(firewall-cmd --get-default-zone)"
        fi
        # Dedicated zone/policy: forward only the VPN subnet to the outbound zone.
        if firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx "${vpn_zone}" ||
            firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -qx "${policy}"; then
            die "firewalld zone or policy ${vpn_zone} already exists. Review it before installing."
        fi
        firewall-cmd --permanent --new-zone="${vpn_zone}"
        firewall-cmd --permanent --zone="${vpn_zone}" --add-interface="${WG_IF}"
        firewall-cmd --permanent --new-policy="${policy}"
        firewall-cmd --permanent --policy="${policy}" --add-ingress-zone="${vpn_zone}"
        firewall-cmd --permanent --policy="${policy}" --add-egress-zone="${zone}"
        firewall-cmd --permanent --policy="${policy}" --add-rich-rule="rule family=\"ipv4\" source address=\"${WG_NETWORK}\" accept"
        firewall-cmd --permanent --policy="${policy}" --add-rich-rule="rule family=\"ipv4\" source address=\"${WG_NETWORK}\" masquerade"
        firewall-cmd --check-config
        # New zones and policies need a reload. Open the UDP port in both scopes.
        for scope in runtime permanent; do
            local -a options=()
            [[ "${scope}" != permanent ]] || options+=(--permanent)
            if firewall-cmd "${options[@]}" --zone="${zone}" --query-port="${WG_PORT}/udp" >/dev/null; then
                printf -v "WG_PORT_OWNED_${scope^^}" '%s' 0
            else
                printf -v "WG_PORT_OWNED_${scope^^}" '%s' 1
                firewall-cmd "${options[@]}" --zone="${zone}" --add-port="${WG_PORT}/udp"
            fi
        done
        WG_FIREWALL_ZONE="${zone}"
        firewall-cmd --reload
    fi
}

valid_host() {
    local host="$1" label
    local -a labels
    [[ -n "${host}" && ${#host} -le 253 ]] || return 1
    [[ "${host}" != .* && "${host}" != *. && "${host}" != *..* ]] || return 1
    [[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS='.' read -r -a labels <<< "${host}"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

if [[ -z "${WG_ENDPOINT_HOST}" ]]; then
    DEFAULT_ENDPOINT="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "${DEFAULT_ENDPOINT}" ]]; then
        read -r -p "Public IPv4 or DDNS hostname [${DEFAULT_ENDPOINT}]: " WG_ENDPOINT_HOST
        WG_ENDPOINT_HOST="${WG_ENDPOINT_HOST:-${DEFAULT_ENDPOINT}}"
    else
        read -r -p "Public IPv4 or DDNS hostname: " WG_ENDPOINT_HOST
    fi
fi
valid_host "${WG_ENDPOINT_HOST}" || die "Enter a valid IPv4 address or DNS hostname (IPv6 endpoints are not configured by this script)."

WG_ENDPOINT="${WG_ENDPOINT_HOST}:${WG_PORT}"

echo "Outbound interface: ${PUBLIC_INTERFACE}"
echo "Client endpoint:    ${WG_ENDPOINT}"
echo "Firewall:           ${WG_FIREWALL}"

configure_firewall

install -d -m 700 "${WG_DIR}" "${CLIENT_DIR}"

SERVER_PRIVATE_KEY="$(wg genkey)"
SERVER_PUBLIC_KEY="$(printf '%s' "${SERVER_PRIVATE_KEY}" | wg pubkey)"
CLIENT_PRIVATE_KEY="$(wg genkey)"
CLIENT_PUBLIC_KEY="$(printf '%s' "${CLIENT_PRIVATE_KEY}" | wg pubkey)"
CLIENT_PRESHARED_KEY="$(wg genpsk)"

if [[ -f /etc/sysctl.d/99-wireguard.conf ]]; then
    cp -p -- /etc/sysctl.d/99-wireguard.conf "${WG_DIR}/${WG_IF}.sysctl-backup"
fi
cat > /etc/sysctl.d/99-wireguard.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${WG_SERVER_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

# Forwarding and NAT are persisted in ${WG_FIREWALL}.

# BEGIN_PEER ${FIRST_CLIENT}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${FIRST_CLIENT_ADDR}
# END_PEER ${FIRST_CLIENT}
EOF
chmod 600 "${WG_CONF}"

cat > "${WG_ENV}" <<EOF
SERVER_ENDPOINT=${WG_ENDPOINT}
CLIENT_DNS=${CLIENT_DNS}
WG_FIREWALL=${WG_FIREWALL}
WG_PORT=${WG_PORT}
WG_UFW_BACKUP=${WG_UFW_BACKUP:-}
WG_FIREWALL_ZONE=${WG_FIREWALL_ZONE:-}
WG_PORT_OWNED_RUNTIME=${WG_PORT_OWNED_RUNTIME:-0}
WG_PORT_OWNED_PERMANENT=${WG_PORT_OWNED_PERMANENT:-0}
EOF
chmod 600 "${WG_ENV}"

cat > "${CLIENT_DIR}/${FIRST_CLIENT}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${FIRST_CLIENT_ADDR}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "${CLIENT_DIR}/${FIRST_CLIENT}.conf"

install -o root -g root -m 700 "${SCRIPT_DIR}/wg-user" /usr/local/bin/wg-user

if [[ "${OS_FAMILY}" == rocky ]] && command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "${WG_DIR}" /usr/local/bin/wg-user
fi

systemctl enable --now "wg-quick@${WG_IF}"

echo
echo "WireGuard server is ready."
echo "Interface:      ${WG_IF}"
echo "Endpoint:       ${WG_ENDPOINT}"
echo "Client profile: ${CLIENT_DIR}/${FIRST_CLIENT}.conf"
echo
echo "Client QR code:"
qrencode -t ansiutf8 < "${CLIENT_DIR}/${FIRST_CLIENT}.conf"
echo
echo "If the server is behind a router, forward UDP ${WG_PORT} to it."
echo "Also permit UDP ${WG_PORT} in the cloud firewall/security group, if applicable."
echo "For a changing public IP, point a DDNS hostname at the server and use it as the endpoint."
