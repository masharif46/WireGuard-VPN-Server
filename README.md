<div align="center">

# WireGuard VPN Server

**A straightforward, self hosted WireGuard server for Ubuntu and Rocky Linux.**

Installs the VPN, configures the host firewall, and creates a ready to import client profile. Manage client access with a small command line tool.

![Ubuntu 24.04 and 26.04](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![Rocky Linux 10](https://img.shields.io/badge/Rocky%20Linux-10-10B981?logo=rockylinux&logoColor=white)
![WireGuard](https://img.shields.io/badge/VPN-WireGuard-88171A?logo=wireguard&logoColor=white)

</div>

## At a glance

| | |
| --- | --- |
| **Supported systems** | Ubuntu 24.04 or 26.04; Rocky Linux 10 |
| **Host firewall** | UFW or firewalld on Ubuntu; firewalld on Rocky Linux |
| **VPN network** | `10.8.0.0/24` |
| **Default VPN port** | UDP `51820` |
| **Client manager** | `wg-user` |

## What it does

- Installs WireGuard and the tools needed to create client profiles.
- Enables IPv4 forwarding and configures firewall forwarding and NAT.
- Creates the server interface and the first client profile.
- Adds, lists, exports, and revokes clients without restarting the VPN.
- Detects active SSH listener ports before starting or reloading firewalld.
- Provides an uninstall command for the VPN configuration and managed firewall rules.

## Install

Copy and extract the complete package on the server. Keep `setup-wireguard.sh` and `wg-user` in the same directory. Run the installer as root; it will prompt for a public IPv4 address or DDNS hostname.
Prepare the host firewall using the instructions for your operating system, then run the installer from the extracted directory.

### Ubuntu: UFW or firewalld

Use one host firewall manager at a time. For UFW, allow your SSH port and any other required services before enabling it. Replace `22/tcp` if SSH uses another port:

```bash
sudo apt-get update
sudo apt-get install -y ufw
sudo ufw allow 22/tcp
sudo ufw enable
```

After UFW is active, run the installer:

```bash
sudo WG_FIREWALL=ufw bash setup-wireguard.sh
```

To use firewalld on Ubuntu, select it explicitly. The installer installs firewalld and opens the detected SSH port before activating it:

```bash
sudo WG_FIREWALL=firewalld bash setup-wireguard.sh
```

The installer detects the active firewall when `WG_FIREWALL=auto` is used. If neither firewall is active, prepare UFW as shown above or choose firewalld explicitly.

Run the installer once. After a successful installation, another install run stops because `/etc/wireguard/wg0.conf` already exists. If a firewalld install fails after creating the `wg-wg0` zone but before creating that configuration, remove that partial zone before retrying. Only do this when the zone was created by the failed WireGuard install:

```bash
sudo firewall-cmd --permanent --delete-zone=wg-wg0
sudo firewall-cmd --check-config
sudo WG_FIREWALL=firewalld bash setup-wireguard.sh
```

### Rocky Linux 10: firewalld

Rocky uses DNF, not APT. You can install firewalld yourself:

```bash
sudo dnf install -y firewalld
```

Then run the installer:

```bash
sudo bash setup-wireguard.sh
```

Or run the installer directly; it installs EPEL, WireGuard tools, and firewalld with DNF. Firewalld can remain stopped until the installer detects the active SSH port, allows it, and starts the service.

Before activating firewalld, the installer checks for running SSH listeners and allows their TCP ports in the existing zones. It supports custom ports, multiple listeners, IPv6 listeners, and Ubuntu's systemd SSH sockets. If it cannot confirm a running SSH port or add its rule, installation stops before starting or reloading firewalld. Allow other services you need in firewalld before installation.

### Set the server endpoint

To skip the endpoint prompt, provide an IPv4 address or hostname as `WG_ENDPOINT_HOST`:

```bash
sudo WG_ENDPOINT_HOST=vpn.example.com bash setup-wireguard.sh
```

The installer stores this endpoint in each client profile. For a changing IP, configure a DDNS updater to keep the hostname current. Reconnect clients after DNS changes so they resolve the new address.

Rocky Linux installation enables the EPEL repository for required packages. The installer will not overwrite an existing `/etc/wireguard/wg0.conf`.

## Connect a client

The installer creates the first client profile here:

```text
/etc/wireguard/clients/client1.conf
```

Install the WireGuard app on the device, then import its profile from a QR code or a configuration file. The installer displays the initial `client1` profile as a QR code when setup finishes. Create a separate profile for every additional device; do not copy one profile to multiple devices. For example, create profiles for a phone and a laptop with:

```bash
sudo wg-user add alice-phone
sudo wg-user add alice-laptop
```

Each command prints a QR code. On a phone or tablet, open the WireGuard app, add a tunnel by scanning the QR code shown in the server terminal, and give the tunnel a recognizable name. For a computer, use `sudo wg-user show alice-laptop` to display the profile, then securely transfer its contents to that device and import the configuration file in the WireGuard app. Keep the file private and delete temporary copies after importing it.

Profiles are device-specific and each contains a private key. Anyone with a profile can connect as that device, so only share it with its intended user. If a device is lost or its profile is exposed, revoke that profile with `sudo wg-user remove NAME` and create a replacement for the device.

Client profiles route IPv4 traffic through the VPN by default (`AllowedIPs = 0.0.0.0/0`). The server setup does not configure IPv6 routing.

### Linux client

Install the WireGuard tools package for your distribution, then create a dedicated profile on the server:

```bash
sudo wg-user add linux-laptop
```

Copy `/etc/wireguard/clients/linux-laptop.conf` securely to the Linux device. On that device, save it as `/etc/wireguard/wg-client.conf`, restrict access to the private key, and start it at boot:

```bash
sudo install -m 600 linux-laptop.conf /etc/wireguard/wg-client.conf
sudo systemctl enable --now wg-quick@wg-client
sudo wg show wg-client
```

Stop and disable the tunnel with `sudo systemctl disable --now wg-quick@wg-client`. For a temporary session instead, run `sudo wg-quick up ./linux-laptop.conf` and later `sudo wg-quick down ./linux-laptop.conf`. `wg-quick` uses the profile's `AllowedIPs = 0.0.0.0/0` to route IPv4 traffic through the VPN. See the [WireGuard installation guide](https://www.wireguard.com/install/) for distribution-specific packages and the [quick start](https://www.wireguard.com/quickstart/) for Linux command details.

### MikroTik RouterOS client

Use RouterOS 7 with a separate profile generated on the WireGuard server:

```bash
sudo wg-user add mikrotik-home
sudo wg-user show mikrotik-home
```

RouterOS needs the profile values entered into its own interface and peer settings. In WinBox or the RouterOS terminal, create an interface and peer using the values from `mikrotik-home`'s profile:

```routeros
/interface wireguard add name=wg-vpn listen-port=13231 private-key="CLIENT_PRIVATE_KEY"
/ip address add address=CLIENT_ADDRESS interface=wg-vpn
/interface wireguard peers add interface=wg-vpn public-key="SERVER_PUBLIC_KEY" preshared-key="CLIENT_PRESHARED_KEY" endpoint-address=SERVER_HOST endpoint-port=51820 allowed-address=0.0.0.0/0 persistent-keepalive=25s
```

Replace the placeholders with the corresponding profile values: `CLIENT_PRIVATE_KEY` is `[Interface] PrivateKey`, `CLIENT_ADDRESS` is `[Interface] Address` (for example, `10.8.0.3/32`), and the peer key and endpoint values come from `[Peer]`. Split `[Peer] Endpoint` into its hostname or IP and port. Change `51820` if the profile uses a custom port, and choose a listen port that is not already in use on the router.

To route traffic to the VPN subnet through the tunnel, add:

```routeros
/ip route add dst-address=10.8.0.0/24 gateway=wg-vpn
```

This creates the WireGuard tunnel and a route to the VPN subnet. It does not send the router's default internet traffic or devices on the MikroTik LAN through the VPN. Full-tunnel routing on RouterOS needs routes that preserve the server endpoint's path through the normal WAN, plus appropriate forwarding and NAT for LAN clients. This server assigns each peer only its own `10.8.0.x/32` address; LAN traffic sent through the tunnel must be translated to that address, or the server's peer and firewall configuration must be extended. Configure RouterOS DNS separately if you want the router or its LAN clients to use a specific DNS server. See [MikroTik's RouterOS WireGuard documentation](https://help.mikrotik.com/docs/spaces/ROS/pages/69664792/WireGuard) for RouterOS peer, routing, and firewall settings.

## Manage clients

Run these commands on the server. Root privileges are required.

```bash
sudo wg-user add alice
sudo wg-user list
sudo wg-user show alice
sudo wg-user qr alice
sudo wg-user remove alice
```

`add` creates a profile and displays its QR code. `show` prints the full profile, including its private key. `remove` revokes the client's key on the running server and deletes its saved profile.

To inspect peer activity, run:

```bash
sudo wg show wg0
```

For each peer, check `latest handshake`, `transfer`, and `allowed ips`. WireGuard has no persistent connected/disconnected status: a recent handshake and increasing transfer counters indicate recent activity. `sudo wg-user list` shows every configured client profile, including clients that are currently offline; match its VPN address to a peer's `allowed ips` in `wg show`.

To disconnect and revoke one client, remove its profile by name:

```bash
sudo wg-user remove alice
```

The client loses access immediately and its saved profile is deleted. Remove a client from its device as well, so it does not keep trying to connect. To stop VPN access for everyone temporarily, stop the server interface with `sudo systemctl stop wg-quick@wg0`; restore service with `sudo systemctl start wg-quick@wg0`. Clients with valid profiles can reconnect when service returns.

WireGuard clients authenticate with cryptographic keys, not account passwords. To rotate a client's credentials, revoke its old key and create a replacement profile:

```bash
sudo wg-user remove alice
sudo wg-user add alice
```

Import the replacement profile on the client device; the old profile stops working as soon as it is revoked.

## Network access

The host firewall is only one part of network access. Also:

1. Allow inbound UDP `51820` in the cloud firewall or security group.
2. If the server is behind a router, forward UDP `51820` to the server.
3. If you set a custom `WG_PORT`, allow and forward that UDP port instead.

The installer does not change cloud firewall, security group, or router settings. This setup routes IPv4 VPN traffic; IPv6 routing is not configured.

UFW rules persist in UFW's configuration and include the VPN port, forwarding, and NAT. Firewalld rules persist in the VPN zone and policy and the outbound interface's zone. Firewalld reloads apply permanent rules, so save unrelated runtime-only rules before installing.

## Configuration

Set these environment variables before running the installer to customize common settings:

| Variable | Default | Description |
| --- | --- | --- |
| `WG_ENDPOINT_HOST` | Prompted | Server public IPv4 address or DDNS hostname |
| `WG_PORT` | `51820` | WireGuard UDP listen port |
| `WG_FIREWALL` | `auto` | Firewall selection: `auto`, `ufw`, or `firewalld` |
| `FIRST_CLIENT` | `client1` | Name of the initial client profile |
| `CLIENT_DNS` | `1.1.1.1` | DNS server assigned to clients |

Example:

```bash
sudo WG_ENDPOINT_HOST=vpn.example.com WG_PORT=51821 FIRST_CLIENT=phone bash setup-wireguard.sh
```

## Verify the server

```bash
sudo systemctl status wg-quick@wg0
sudo wg show
```

If a client cannot connect, confirm its endpoint and UDP port, then check the cloud firewall, router forwarding, and host firewall rules.

## Uninstall

Run the installer with the `uninstall` command:

```bash
sudo bash setup-wireguard.sh uninstall
```

This stops and disables `wg-quick@wg0`, removes its profiles and server configuration, removes managed VPN firewall rules, restores the original UFW rules file and removes its backup, and deletes the installed `wg-user` command when no other tunnel uses it. Firewalld or UFW must be active for cleanup. The firewall service, installed packages, SSH rules, other tunnels, and unrelated files are retained.

The uninstall restores a prior `99-wireguard.conf` if the installer backed one up. Runtime IPv4 forwarding remains unchanged to avoid disrupting other routing services. Older installations without uninstall metadata may leave untracked allow rules; installations made by the original iptables based script need manual firewall cleanup.
