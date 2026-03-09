bash -c "$(cat <<'EOF'
set -euo pipefail

echo "Finde freie Container-ID..."
CTID="$(pvesh get /cluster/nextid)"

HOSTNAME="openclaw"
DISK_SIZE="24"
CORES="4"
MEMORY="4096"
SWAP="1024"
BRIDGE="vmbr0"

echo
echo "Verfügbare Storages:"
mapfile -t STORAGES < <(pvesm status -content rootdir,images,vztmpl | awk 'NR>1 {print $1}' | sort -u)

if [ "${#STORAGES[@]}" -eq 0 ]; then
  echo "Keine passenden Storages gefunden."
  exit 1
fi

for i in "${!STORAGES[@]}"; do
  printf "%2d) %s\n" "$((i+1))" "${STORAGES[$i]}"
done

echo
read -rp "Wähle Storage für den LXC-RootFS [1-${#STORAGES[@]}]: " ROOTFS_IDX
if ! [[ "$ROOTFS_IDX" =~ ^[0-9]+$ ]] || [ "$ROOTFS_IDX" -lt 1 ] || [ "$ROOTFS_IDX" -gt "${#STORAGES[@]}" ]; then
  echo "Ungültige Auswahl für RootFS-Storage."
  exit 1
fi
STORAGE="${STORAGES[$((ROOTFS_IDX-1))]}"

echo
read -rp "Wähle Storage für das Ubuntu-Template [1-${#STORAGES[@]}]: " TEMPLATE_IDX
if ! [[ "$TEMPLATE_IDX" =~ ^[0-9]+$ ]] || [ "$TEMPLATE_IDX" -lt 1 ] || [ "$TEMPLATE_IDX" -gt "${#STORAGES[@]}" ]; then
  echo "Ungültige Auswahl für Template-Storage."
  exit 1
fi
TEMPLATE_STORAGE="${STORAGES[$((TEMPLATE_IDX-1))]}"

echo
echo "Gewählt:"
echo "  RootFS-Storage:   ${STORAGE}"
echo "  Template-Storage: ${TEMPLATE_STORAGE}"
echo

echo "Update Templates..."
pveam update >/dev/null

echo "Suche Ubuntu 24.04 Template..."
TEMPLATE="$(pveam available -section system | awk '/ubuntu-24\.04-standard/ {print $2}' | sort -V | tail -n 1)"

if [[ -z "${TEMPLATE:-}" ]]; then
  echo "Kein Ubuntu 24.04 LXC-Template gefunden."
  exit 1
fi

TEMPLATE_FILE="${TEMPLATE##*/}"

echo "Prüfe, ob Template bereits auf ${TEMPLATE_STORAGE} existiert..."
if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | awk '{print $2}' | grep -qx "${TEMPLATE_FILE}"; then
  echo "Lade Template ${TEMPLATE_FILE} nach ${TEMPLATE_STORAGE}..."
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
else
  echo "Template bereits vorhanden: ${TEMPLATE_FILE}"
fi

echo "Erstelle LXC Container (ID: ${CTID})..."
pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "${HOSTNAME}" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --features "nesting=1,keyctl=1,fuse=1,mknod=1" \
  --unprivileged 1 \
  --onboot 1 \
  --start 0

echo "Setze LXC-Parameter für Docker/AppArmor-Kompatibilität..."
cat >> "/etc/pve/lxc/${CTID}.conf" <<EOCONF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.mount.auto: proc:rw sys:rw
lxc.mount.entry: /dev/null sys/module/apparmor/parameters/enabled none bind 0 0
EOCONF

echo "Starte Container ${CTID}..."
pct start "${CTID}"

echo "Warte auf Boot..."
sleep 15

echo "Installiere Basis-Pakete..."
pct exec "${CTID}" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y ca-certificates curl git sudo gnupg lsb-release apt-transport-https jq
'

echo "Installiere Docker aus offizieller Docker-Repo..."
pct exec "${CTID}" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF_DOCKER
{
  "features": {
    "buildkit": true
  },
  "iptables": false,
  "storage-driver": "overlay2"
}
EOF_DOCKER

  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf <<EOF_SERVICE
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --host=unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
EOF_SERVICE

  systemctl daemon-reload
  systemctl disable --now docker.socket || true
  systemctl enable --now containerd
  systemctl enable --now docker
  systemctl restart docker
'

echo "Prüfe Docker..."
pct exec "${CTID}" -- bash -lc '
  set -euo pipefail
  docker --version
  docker compose version
  docker buildx version
  docker info >/dev/null
'

echo "Klone OpenClaw Repo..."
pct exec "${CTID}" -- bash -lc '
  set -euo pipefail
  rm -rf /opt/openclaw
  git clone https://github.com/openclaw/openclaw.git /opt/openclaw
  chmod +x /opt/openclaw/docker-setup.sh
'

echo "Bereite persistente OpenClaw-Ordner mit korrekten Rechten vor..."
pct exec "${CTID}" -- bash -lc '
  set -euo pipefail
  mkdir -p /root/.openclaw
  chown -R 1000:1000 /root/.openclaw
  chmod -R u+rwX,g+rwX /root/.openclaw
'

echo "Schreibe OpenClaw-Umgebung..."
pct exec "${CTID}" -- bash -lc '
  set -euo pipefail
  cd /opt/openclaw

  if grep -q "^OPENCLAW_IMAGE=" .env 2>/dev/null; then
    sed -i "s#^OPENCLAW_IMAGE=.*#OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest#" .env
  else
    echo "OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest" >> .env
  fi

  # Kein OPENCLAW_GATEWAY_BIND erzwingen.
  # Falls vorhanden, entfernen, damit Onboarding/Config entscheidet.
  sed -i "/^OPENCLAW_GATEWAY_BIND=/d" .env
'

echo
echo "=========================================================="
echo "FERTIG. Container ${CTID} läuft."
echo "=========================================================="
echo "RootFS-Storage:   ${STORAGE}"
echo "Template-Storage: ${TEMPLATE_STORAGE}"
echo
echo "Konsole öffnen:"
echo "  pct console ${CTID}"
echo
echo "Dann IM CONTAINER ausführen:"
echo "  cd /opt/openclaw"
echo "  DOCKER_BUILDKIT=1 ./docker-setup.sh"
echo
echo "WICHTIG:"
echo "  - Im Onboarding am besten Loopback wählen."
echo "  - Für LAN später allowedOrigins sauber setzen."
echo
echo "Danach prüfen mit:"
echo "  docker compose ps"
echo "  docker compose logs --tail=100 openclaw-gateway"
echo "  curl -I http://127.0.0.1:18789"
echo "=========================================================="
EOF
)"