````markdown
# Paperclip on Proxmox with Ubuntu 24.04

This guide explains how to create a fresh Ubuntu 24.04 VM on a Proxmox node and install Paperclip automatically.

It uses:

- Ubuntu 24.04 cloud image
- cloud-init
- Paperclip from source
- embedded PostgreSQL
- systemd service
- user `paper`
- default password `Test1234`

## Important note about PostgreSQL

This setup does **not** install Ubuntu's `postgresql` package.

That is intentional.

Paperclip uses **embedded PostgreSQL** by default when no external `DATABASE_URL` is configured. In the Paperclip logs this shows up as:

- `Using embedded PostgreSQL because no DATABASE_URL set`
- `Mode embedded-postgres`

So for this setup, **system PostgreSQL is not required**.

## What the script does

The Proxmox host script will:

- download the Ubuntu 24.04 cloud image
- create a VM on Proxmox
- attach a cloud-init drive
- create user `paper`
- set password `Test1234`
- install Node.js 22 and pnpm
- clone Paperclip into `/home/paper/paperclip-src`
- install dependencies
- create a `systemd` service
- run Paperclip on `0.0.0.0:3100`
- optionally allow a hostname such as `agents.example.com`
- print the latest board-claim URL

## Requirements

Run this on the **Proxmox host**, not inside a VM.

You need:

- Proxmox VE
- internet access from the Proxmox host and the VM
- a storage target such as `local-lvm`
- a bridge such as `vmbr0`

## Raw script URL

This setup uses this install script:

```text
https://raw.githubusercontent.com/Darkatek7/proxmox-lxc-scripts/refs/heads/main/Paperclip%20Ubuntu%20Machine/install.sh
````

## Example usage from the raw GitHub URL

Download and run:

```bash
curl -fsSL "https://raw.githubusercontent.com/Darkatek7/proxmox-lxc-scripts/refs/heads/main/Paperclip%20Ubuntu%20Machine/install.sh" -o /root/install.sh
chmod +x /root/install.sh
PUBLIC_HOST=agents.example.com /root/install.sh
```

Run directly without saving:

```bash
curl -fsSL "https://raw.githubusercontent.com/Darkatek7/proxmox-lxc-scripts/refs/heads/main/Paperclip%20Ubuntu%20Machine/install.sh" | \
PUBLIC_HOST=agents.example.com VMID=9001 VMNAME=paperclip-ubuntu2404 bash
```

## Example variables

```bash
PUBLIC_HOST=agents.example.com \
VMID=9001 \
VMNAME=paperclip-ubuntu2404 \
STORAGE=local-lvm \
CISTORAGE=local-lvm \
BRIDGE=vmbr0 \
CORES=4 \
MEMORY=8192 \
DISK_SIZE=40G \
CI_USER=paper \
CI_PASSWORD=Test1234 \
/root/install.sh
```

## Static IP example

```bash
IPCONFIG0='ip=192.168.1.50/24,gw=192.168.1.1' \
PUBLIC_HOST=agents.example.com \
/root/install.sh
```

## How to run it

### Option 1: Download first, then run

```bash
curl -fsSL "https://raw.githubusercontent.com/Darkatek7/proxmox-lxc-scripts/refs/heads/main/Paperclip%20Ubuntu%20Machine/install.sh" -o /root/install.sh
chmod +x /root/install.sh
PUBLIC_HOST=agents.example.com /root/install.sh
```

### Option 2: Run directly from GitHub

```bash
curl -fsSL "https://raw.githubusercontent.com/Darkatek7/proxmox-lxc-scripts/refs/heads/main/Paperclip%20Ubuntu%20Machine/install.sh" | \
PUBLIC_HOST=agents.example.com VMID=9001 VMNAME=paperclip-ubuntu2404 bash
```

## Recommended full example

```bash
curl -fsSL "https://raw.githubusercontent.com/Darkatek7/proxmox-lxc-scripts/refs/heads/main/Paperclip%20Ubuntu%20Machine/install.sh" -o /root/install.sh && \
chmod +x /root/install.sh && \
PUBLIC_HOST=agents.example.com \
VMID=9001 \
VMNAME=paperclip-ubuntu2404 \
STORAGE=local-lvm \
CISTORAGE=local-lvm \
BRIDGE=vmbr0 \
CORES=4 \
MEMORY=8192 \
DISK_SIZE=40G \
CI_USER=paper \
CI_PASSWORD=Test1234 \
/root/install.sh
```

## What happens during install

Inside the VM, cloud-init will:

1. create user `paper`
2. install system packages
3. install Node.js 22
4. enable pnpm
5. clone Paperclip
6. run `pnpm install`
7. create `/etc/systemd/system/paperclip.service`
8. start Paperclip
9. add the configured hostname to Paperclip allowed hostnames
10. print the latest board-claim link

## After the VM starts

Cloud-init needs a little time.

Then check the install result from the Proxmox host:

```bash
qm guest exec 9001 -- cat /root/paperclip-install-result.txt
```

Open a console:

```bash
qm terminal 9001
```

## Check Paperclip service in the VM

```bash
systemctl status paperclip --no-pager
journalctl -u paperclip -n 100 --no-pager
```

## Health check

Inside the VM:

```bash
curl http://127.0.0.1:3100/api/health
```

Expected output includes:

```json
{"status":"ok"}
```

## Hostname allowlist

If you use a hostname like `agents.example.com`, Paperclip must allow that hostname.

The installer does this automatically when `PUBLIC_HOST` is set.

Manual example inside the VM:

```bash
su - paper -c 'cd /home/paper/paperclip-src && pnpm paperclipai allowed-hostname agents.example.com'
systemctl restart paperclip
```

## Board claim link

Paperclip in authenticated/private mode may require a board-claim URL on first setup.

To print the latest board link inside the VM:

```bash
paperclip-board-link
```

If using a public hostname:

```bash
PUBLIC_HOST=agents.example.com paperclip-board-link
```

You can also get it from logs:

```bash
journalctl -u paperclip -n 200 --no-pager | grep -A3 'BOARD CLAIM REQUIRED'
```

Always use the **latest** claim link, because it may change after a restart.

## Service details

Paperclip runs as user `paper`.

Important paths:

* app directory: `/home/paper/paperclip-src`
* state directory: `/home/paper/.paperclip`
* example working directory: `/home/paper/arlberghosting`

Service file:

```text
/etc/systemd/system/paperclip.service
```

## Common problems

### 1. `claude` not found in PATH

If the UI says:

```text
Command not found in PATH: "claude"
```

check as user `paper`:

```bash
su - paper -c 'which claude'
su - paper -c 'claude --version'
```

The service PATH should include `/home/paper/.local/bin`.

Check service environment:

```bash
systemctl show paperclip -p Environment --no-pager
```

Expected PATH should contain:

```text
/home/paper/.local/bin
```

### 2. Hostname not allowed

If the UI says:

```text
Hostname 'agents.example.com' is not allowed
```

run:

```bash
su - paper -c 'cd /home/paper/paperclip-src && pnpm paperclipai allowed-hostname agents.example.com'
systemctl restart paperclip
```

### 3. Working directory permission denied

Use a directory owned by `paper`, for example:

```bash
mkdir -p /home/paper/arlberghosting
chown -R paper:paper /home/paper/arlberghosting
```

### 4. Board claim says challenge not found

Use the **latest** board claim URL from the journal. Do not use an old one from before a restart.

## Security note

The default password in this example is:

```text
Test1234
```

Change it immediately after setup:

```bash
passwd paper
```

Using SSH keys is strongly recommended.

```
```
