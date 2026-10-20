# Dockerized OpenVPN Server on Ubuntu

## 1. Introduction

`install-openvpn.sh` automates deployment of an OpenVPN server in Docker on a clean Ubuntu virtual machine. It also provides a separate mode to create additional client profiles without rerunning the full installation.

The script uses `lisenet/openvpn:2.6.11-build27`. Its default VPN subnet is `172.27.255.0/24`; the endpoint, port, DNS servers, client name, MSS setting, and outbound interface are configurable near the top of the script.

**Important:** Full installation mode is intended for a clean server. It stops if the configured container or Docker volume already exists, to protect an existing deployment. Use `--add-client NAME` to add a client to an existing server.

## 2. Requirements

- Ubuntu Server 22.04, 24.04, or 26.04.
- Root privileges, usually through `sudo`.
- Internet access to download Docker packages and the OpenVPN image.
- A public IP address or DNS name reachable by VPN clients.
- The configured UDP port allowed by the host firewall and cloud firewall/security list.
- A VPN subnet that does not overlap with networks used by the server or clients.

If Docker is not installed, the script installs Docker Engine from Docker's official Ubuntu repository. If Docker is already installed, it enables and starts the Docker service.

Client devices need an OpenVPN-compatible application, such as OpenVPN Connect.

## 3. What the Script Does

In full installation mode, the script:

1. Checks root privileges and the supported Ubuntu version.
2. Validates configuration values and detects the outbound network interface if one is not specified.
3. Installs or starts Docker.
4. Enables IPv4 forwarding through `/etc/sysctl.d/99-openvpn.conf`.
5. Refuses to proceed if the configured OpenVPN container or data volume already exists.
6. Creates the Docker volume for OpenVPN configuration, certificates, and keys.
7. Pulls the configured image and generates the server configuration.
8. adds `mssfix` to the server configuration.
9. Initializes the EasyRSA PKI. The CA initialization can prompt for a passphrase; store it securely.
10. Starts the OpenVPN container with `NET_ADMIN`, changes the container's `iptables` links to `iptables-nft`, and then executes `ovpn_run`.
11. Adds host NAT and forwarding rules.
12. Installs a systemd service to reapply the NAT rules after reboot.
13. Generates the initial client certificate and `.ovpn` profile.
14. Prints a deployment summary and runs basic checks.

Client-add mode reuses the existing running container and PKI. It creates a certificate if needed, exports the profile to a temporary file, validates it, and only then moves it into place.

## 4. Configuration Variables

Edit the variables near the top of `install-openvpn.sh` **before the first installation**.

| Variable | Default | Purpose |
|---|---|---|
| `OVPN_IMAGE` | `lisenet/openvpn:2.6.11-build27` | Docker image used by the server and helper commands. |
| `OVPN_DATA` | `ovpn-data` | Docker volume containing OpenVPN configuration and PKI. Keep it consistent for client management. |
| `CONTAINER_NAME` | `openvpn` | Name of the server container. |
| `OVPN_HOST` | `vpn.example.com` | Public DNS name or IP address clients use to reach the VPN. Change this to your endpoint. |
| `OVPN_PORT` | `1194` | Host UDP port exposed for OpenVPN. Allow it through the relevant firewalls. |
| `VPN_SUBNET` | `172.27.255.0/24` | VPN client address pool. Choose a private subnet without overlapping networks. |
| `CLIENT_NAME` | `notebook` | Initial client certificate and profile generated during installation. |
| `DNS1` | `8.8.8.8` | First DNS server pushed to clients. |
| `DNS2` | `8.8.4.4` | Second DNS server pushed to clients. |
| `MSSFIX` | `1372` | OpenVPN `mssfix` value; this default was tested for the target deployment. |
| `EXTERNAL_IFACE` | empty | Outbound host interface used for NAT. Empty means automatic detection; otherwise specify an interface such as `ens3`. |
| `NAT_SERVICE` | `openvpn-nat.service` | systemd unit name used to persist host NAT rules. |

### Configuration notes

- Change `OVPN_HOST` before installation if the default endpoint is not yours.
- Choose `VPN_SUBNET` carefully; it must not conflict with client or server networks.
- Keep `OVPN_DATA` and `CONTAINER_NAME` consistent when adding clients.
- The script maps the configured host UDP port to container port `1194`.
- Do not delete the existing container or data volume simply to bypass the clean-install guard. The volume contains the PKI and server configuration.

## 5. Install a New VPN Server

### 5.1 Review the configuration

Copy `install-openvpn.sh` to the new Ubuntu server and edit the variables above. In particular, set `OVPN_HOST`, `VPN_SUBNET`, and `CLIENT_NAME`.

Optionally set restrictive permissions:

```bash
chmod 700 install-openvpn.sh
```

### 5.2 Run the installation

```bash
sudo bash ./install-openvpn.sh
```

Or, if executable:

```bash
sudo ./install-openvpn.sh
```

The script installs/configures Docker as needed, initializes the OpenVPN server, configures NAT persistence, and generates the initial client profile.

During PKI initialization, follow the prompts and securely retain the CA passphrase. Do not interrupt the script during PKI creation or server startup.

### 5.3 Cloud-init

The script can be invoked by cloud-init after it has been placed on the VM. For example, if it is already present at `/root/install-openvpn.sh`:

```yaml
#cloud-config
runcmd:
  - [bash, /root/install-openvpn.sh]
```

**Unattended deployment caveat:** PKI initialization is interactive. A fully unattended cloud-init deployment needs a deliberate, secure method for handling CA initialization; do not assume prompts can be answered automatically.

## 6. Generate a Client Profile

### 6.1 Display help

```bash
sudo bash ./install-openvpn.sh --help
```

This exits without running the installation.

### 6.2 Add a client to an existing server

```bash
sudo bash ./install-openvpn.sh --add-client winclient
```

Replace `winclient` with the desired client name. Names must start with a letter or number and may contain letters, numbers, periods, hyphens, and underscores, up to 64 characters.

This mode:
- Does not run the full installation.
- Requires Docker, the existing `ovpn-data` volume, and a running `openvpn` container.
- Reuses the existing PKI.
- Creates the certificate and key if they do not already exist.
- Exports `<client-name>.ovpn` in the current working directory.
- Uses a temporary file and checks the output before replacing the final profile.
- Sets the profile's permissions to `600`.

For example:

```bash
sudo bash ./install-openvpn.sh --add-client tablet
```

This creates `tablet.ovpn` in the current directory. Because the script runs as root, the file may be owned by root. Transfer it securely or adjust ownership only as needed.

### 6.3 Import the profile

Transfer the `.ovpn` file securely to the target device and import it into OpenVPN Connect or another compatible OpenVPN client.

A profile contains private key material. Treat it as a credential:
- Do not share it through public or untrusted channels.
- Do not commit it to source control.
- Restrict access and keep backups encrypted.
- Use a separate profile for each device or user, so access can be revoked individually.

## 7. Operations and Troubleshooting

### Check container status and logs

```bash
sudo docker ps --filter name=openvpn
sudo docker logs --tail 100 openvpn
```

### Check NAT persistence

```bash
sudo systemctl status openvpn-nat.service
sudo iptables -t nat -L POSTROUTING -n -v
sudo iptables -L DOCKER-USER -n -v
```

### Check the container's iptables backend

```bash
sudo docker exec openvpn iptables -V
sudo docker exec openvpn iptables -t nat -L -n
```

The container should report `nf_tables` and should be able to list the NAT table.

### Common issues

- **Container or volume already exists:** This is an intentional safety check. Do not delete existing resources unless you intend to replace the deployment. Use `--add-client NAME` for an existing server.
- **Client cannot connect:** Verify `OVPN_HOST`, the configured UDP port, cloud security rules, and host firewall rules.
- **Profile is missing or empty:** Review command output. The script should stop rather than replace the final profile with an empty file. Check that the server container is running and the client's certificate exists.
- **Websites load inconsistently through the VPN:** Check MTU/MSS behavior. The script uses `mssfix 1372 mtu` by default because this value was tested for the deployment.
- **EasyRSA prints literal version placeholders:** The script attempts to replace `~VER~`, `~DATE~`, and `~GITHEAD~` in the container's EasyRSA script with fallback text. This affects displayed metadata, not certificate cryptography.

### Reboot behavior

The OpenVPN container uses Docker's `unless-stopped` restart policy. The systemd oneshot service reapplies host NAT rules after boot. After reboot, verify both the container and `openvpn-nat.service`.

## 8. Security and Maintenance

- Protect the CA passphrase, the `ovpn-data` volume, and every client `.ovpn` file.
- Use a unique client profile for each device or user.
- Revoke client certificates when devices are lost or access is no longer required. The script does not currently provide a dedicated client-revocation mode.
- Back up the OpenVPN data volume securely before making changes.
- Review image versions before upgrading and test upgrades on a disposable VM.
- Do not expose the Docker daemon to untrusted networks.
- Confirm that the cloud firewall/security list permits the OpenVPN UDP port.

## 9. Summary

Install a server on a clean supported Ubuntu VM:

```bash
sudo bash ./install-openvpn.sh
```

Generate another client profile on an existing server:

```bash
sudo bash ./install-openvpn.sh --add-client winclient2
```

The first command installs the server and generates the initial client profile. The second reuses the existing server and PKI to create an additional profile. Review the variables before installation and protect all generated credentials and the `ovpn-data` volume.
