#!/usr/bin/env bash
set -euo pipefail

VMID="${VMID:-9001}"
VMNAME="${VMNAME:-paperclip-ubuntu2404}"
STORAGE="${STORAGE:-local-lvm}"
CISTORAGE="${CISTORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
DISK_SIZE="${DISK_SIZE:-40G}"
CI_USER="${CI_USER:-paper}"
CI_PASSWORD="${CI_PASSWORD:-Test1234}"
IPCONFIG0="${IPCONFIG0:-ip=dhcp}"
CIUPGRADE="${CIUPGRADE:-1}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"

IMG_DIR="/var/lib/vz/template/qcow2"
IMG_FILE="${IMG_DIR}/noble-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"

SNIPPET_DIR="/var/lib/vz/snippets"
USERDATA_FILE="${SNIPPET_DIR}/paperclip-userdata-${VMID}.yaml"

command -v qm >/dev/null || { echo "qm not found. Run this on a Proxmox host."; exit 1; }
mkdir -p "$IMG_DIR" "$SNIPPET_DIR"

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists."
  exit 1
fi

if [[ ! -f "$IMG_FILE" ]]; then
  echo "Downloading Ubuntu 24.04 cloud image..."
  wget -O "$IMG_FILE" "$IMG_URL"
fi

SSH_KEYS_BLOCK=""
if [[ -n "$SSH_PUBKEY_FILE" && -f "$SSH_PUBKEY_FILE" ]]; then
  SSH_KEY_CONTENT="$(sed 's/[[:space:]]*$//' "$SSH_PUBKEY_FILE")"
  SSH_KEYS_BLOCK=$(cat <<EOF
ssh_authorized_keys:
  - ${SSH_KEY_CONTENT}
EOF
)
fi

cat > "$USERDATA_FILE" <<EOF
#cloud-config
hostname: ${VMNAME}
manage_etc_hosts: true
package_update: true
package_upgrade: true

users:
  - default
  - name: ${CI_USER}
    gecos: Paperclip Admin
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "${CI_PASSWORD}"
    sudo: ALL=(ALL) NOPASSWD:ALL
${SSH_KEYS_BLOCK}

write_files:
  - path: /root/install-paperclip.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive

      PAPER_USER="${CI_USER}"
      PAPER_PASSWORD="${CI_PASSWORD}"
      PAPER_HOME="/home/\${PAPER_USER}"
      PAPERCLIP_HOME="\${PAPER_HOME}/.paperclip"
      PAPERCLIP_DIR="\${PAPER_HOME}/paperclip-src"
      PUBLIC_HOST="${PUBLIC_HOST}"
      AUTH_SECRET="\$(openssl rand -hex 32)"
      PAPERCLIP_ENV_FILE="/etc/paperclip/paperclip.env"

      apt-get update
      apt-get install -y ca-certificates curl git build-essential jq unzip openssl

      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y nodejs

      npm install -g corepack@latest
      corepack enable
      corepack prepare pnpm@latest-10 --activate

      mkdir -p "\${PAPER_HOME}/.local/bin" "\${PAPER_HOME}/arlberghosting" /etc/paperclip
      chown -R "\${PAPER_USER}:\${PAPER_USER}" "\${PAPER_HOME}"

      if [[ ! -d "\${PAPERCLIP_DIR}/.git" ]]; then
        su - "\${PAPER_USER}" -c "git clone https://github.com/paperclipai/paperclip.git '\${PAPERCLIP_DIR}'"
      fi

      su - "\${PAPER_USER}" -c "cd '\${PAPERCLIP_DIR}' && PATH=/usr/local/bin:/usr/bin:/bin pnpm install"

      cat > "\${PAPERCLIP_ENV_FILE}" <<ENVFILE
      BETTER_AUTH_SECRET=\${AUTH_SECRET}
      PAPERCLIP_AGENT_JWT_SECRET=\${AUTH_SECRET}
      HOST=0.0.0.0
      PORT=3100
      NODE_ENV=production
      PAPERCLIP_HOME=\${PAPERCLIP_HOME}
      ENVFILE
      chmod 600 "\${PAPERCLIP_ENV_FILE}"

      cat > /etc/systemd/system/paperclip.service <<SERVICE
      [Unit]
      Description=Paperclip
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      User=\${PAPER_USER}
      Group=\${PAPER_USER}
      WorkingDirectory=\${PAPERCLIP_DIR}
      EnvironmentFile=\${PAPERCLIP_ENV_FILE}
      Environment=PATH=\${PAPER_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
      ExecStart=/usr/bin/pnpm dev:once -- --tailscale-auth
      Restart=always
      RestartSec=5
      TimeoutStopSec=30

      [Install]
      WantedBy=multi-user.target
      SERVICE

      cat > /usr/local/bin/paperclip-board-link <<'HELPER'
      #!/usr/bin/env bash
      set -euo pipefail
      SERVICE_NAME="paperclip"
      PUBLIC_HOST="\${PUBLIC_HOST:-}"

      line="\$(journalctl -u "\${SERVICE_NAME}" -n 1000 --no-pager | grep -Eo 'http://localhost:3100/(board-claim|invite)/[^[:space:]]+' | tail -n 1 || true)"
      if [[ -z "\$line" ]]; then
        line="\$(journalctl -u "\${SERVICE_NAME}" -n 1000 --no-pager | grep -Eo 'http://localhost:3100[^[:space:]]+' | tail -n 1 || true)"
      fi

      [[ -n "\$line" ]] || { echo "No board/bootstrap link found."; exit 1; }

      if [[ -n "\$PUBLIC_HOST" ]]; then
        line="\${line/http:\\/\\/localhost:3100/https:\\/\\/\${PUBLIC_HOST}}"
      fi

      echo "\$line"
      HELPER
      chmod +x /usr/local/bin/paperclip-board-link

      systemctl daemon-reload
      systemctl enable --now paperclip

      echo "Waiting for Paperclip health..."
      for i in \$(seq 1 30); do
        if curl -fsS http://127.0.0.1:3100/api/health >/tmp/paperclip-health.json 2>/dev/null; then
          break
        fi
        sleep 2
      done

      if [[ -n "\${PUBLIC_HOST}" ]]; then
        su - "\${PAPER_USER}" -c "cd '\${PAPERCLIP_DIR}' && pnpm paperclipai allowed-hostname '\${PUBLIC_HOST}'" || true
        systemctl restart paperclip
        sleep 5
      fi

      {
        echo "==== PAPERCLIP INSTALL COMPLETE ===="
        echo "User: \${PAPER_USER}"
        echo "Password: \${PAPER_PASSWORD}"
        echo "Env file: \${PAPERCLIP_ENV_FILE}"
        echo "Health:"
        curl -fsS http://127.0.0.1:3100/api/health || true
        echo
        echo "Service:"
        systemctl is-active paperclip || true
        echo
        echo "Latest board/bootstrap link:"
        if [[ -n "\${PUBLIC_HOST}" ]]; then
          PUBLIC_HOST="\${PUBLIC_HOST}" /usr/local/bin/paperclip-board-link || true
        else
          /usr/local/bin/paperclip-board-link || true
        fi
      } | tee /root/paperclip-install-result.txt

runcmd:
  - [ bash, /root/install-paperclip.sh ]
final_message: "cloud-init finished"
EOF

echo "Creating VM $VMID..."
qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --agent 1 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge="$BRIDGE"

qm importdisk "$VMID" "$IMG_FILE" "$STORAGE"
qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0" \
  --boot order=scsi0 \
  --ide2 "${CISTORAGE}:cloudinit" \
  --serial0 socket \
  --vga serial0

qm resize "$VMID" scsi0 "$DISK_SIZE"
qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --cipassword "$CI_PASSWORD"
qm set "$VMID" --ipconfig0 "$IPCONFIG0"
qm set "$VMID" --ciupgrade "$CIUPGRADE"
qm set "$VMID" --cicustom "user=local:snippets/$(basename "$USERDATA_FILE")"

if [[ -n "$SSH_PUBKEY_FILE" && -f "$SSH_PUBKEY_FILE" ]]; then
  qm set "$VMID" --sshkeys "$SSH_PUBKEY_FILE"
fi

echo "Starting VM..."
qm start "$VMID"

echo
echo "VM created and started."
echo "VMID: $VMID"
echo "Name: $VMNAME"
echo "User: $CI_USER"
echo "Password: $CI_PASSWORD"
echo
echo "Useful commands:"
echo "  qm terminal $VMID"
echo "  qm guest exec $VMID -- cat /root/paperclip-install-result.txt"
echo "  qm guest exec $VMID -- systemctl status paperclip --no-pager"
echo "  qm guest exec $VMID -- journalctl -u paperclip -n 100 --no-pager"