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

Import the profile's QR code in the WireGuard app, or securely transfer the configuration file to the client device. Each profile contains a private key, so share it only with its intended user.

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
