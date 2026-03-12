#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

require_root_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required but not installed."
    exit 1
  fi
}

get_real_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  else
    echo "$(id -un)"
  fi
}

run_as_real_user() {
  local real_user
  real_user="$(get_real_user)"
  if [[ "$real_user" = "root" ]]; then
    bash -lc "$1"
  else
    sudo -u "$real_user" -H bash -lc "$1"
  fi
}

ubuntu_release_check() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Cannot determine OS version."
    exit 1
  fi

  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "This script is intended for Ubuntu."
    exit 1
  fi

  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    echo "Warning: this script was designed for Ubuntu 24.04 LTS."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    sleep 3
  fi
}

log "Checking environment"
require_root_sudo
ubuntu_release_check

REAL_USER="$(get_real_user)"
REAL_HOME="$(eval echo "~${REAL_USER}")"

log "Updating system"
sudo apt update
sudo apt upgrade -y

log "Installing base packages"
sudo apt install -y \
  ca-certificates \
  curl \
  wget \
  gnupg \
  gpg \
  lsb-release \
  software-properties-common \
  apt-transport-https \
  git \
  git-lfs \
  build-essential \
  make \
  cmake \
  pkg-config \
  unzip \
  zip \
  tar \
  xz-utils \
  jq \
  ripgrep \
  fd-find \
  tree \
  htop \
  tmux \
  neovim \
  openssh-server \
  ufw \
  sqlite3 \
  redis-tools \
  shellcheck \
  pipx \
  python3-pip \
  python3.12 \
  python3.12-venv \
  python3.12-dev \
  cockpit \
  cockpit-machines \
  fonts-firacode

log "Enabling services"
sudo systemctl enable --now ssh
sudo systemctl enable --now cockpit.socket

log "Opening Cockpit in firewall if UFW is active"
if sudo ufw status | grep -qi "Status: active"; then
  sudo ufw allow 9090/tcp || true
fi

log "Removing conflicting Docker packages if present"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt remove -y "$pkg" || true
done

log "Setting up Docker repository"
sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

log "Installing Docker Engine + Compose plugin"
sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

log "Adding ${REAL_USER} to docker group"
sudo usermod -aG docker "${REAL_USER}"

log "Setting up GitHub CLI repository"
if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
fi
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
  sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

log "Installing GitHub CLI"
sudo apt update
sudo apt install -y gh

log "Installing .NET 9 SDK"
if sudo apt-cache show dotnet-sdk-9.0 >/dev/null 2>&1; then
  sudo apt install -y dotnet-sdk-9.0
else
  log ".NET 9 not found in current apt sources, adding Microsoft repository"
  wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
  sudo dpkg -i /tmp/packages-microsoft-prod.deb
  rm -f /tmp/packages-microsoft-prod.deb
  sudo apt update
  sudo apt install -y dotnet-sdk-9.0
fi

log "Installing NVM for ${REAL_USER}"
run_as_real_user 'export PROFILE="$HOME/.bashrc"; curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'

log "Installing latest Node.js LTS via NVM"
run_as_real_user '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
  nvm alias default "lts/*"
  nvm use default
'

log "Ensuring pipx path"
run_as_real_user 'python3.12 -m pip install --user --upgrade pip || true'
run_as_real_user 'pipx ensurepath || true'

log "Configuring useful shell aliases for ${REAL_USER}"
BASHRC="${REAL_HOME}/.bashrc"

append_if_missing() {
  local line="$1"
  if ! grep -Fqx "$line" "$BASHRC" 2>/dev/null; then
    echo "$line" | sudo tee -a "$BASHRC" > /dev/null
  fi
}

append_block_if_missing() {
  local marker="$1"
  local content="$2"
  if ! grep -Fq "$marker" "$BASHRC" 2>/dev/null; then
    printf '\n%s\n' "$content" | sudo tee -a "$BASHRC" > /dev/null
  fi
}

append_if_missing 'alias python=python3.12'
append_if_missing 'alias pip="python3.12 -m pip"'
append_if_missing 'alias dc="docker compose"'

append_block_if_missing '# NVM bootstrap' '# NVM bootstrap
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

log "Fixing ownership of ${REAL_HOME}"
sudo chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.nvm" "${REAL_HOME}/.local" 2>/dev/null || true

log "Verifying installed tooling"
echo
echo "===== VERSIONS ====="
python3.12 --version || true
pip3 --version || true
sudo docker --version || true
sudo docker compose version || true
dotnet --info | sed -n '1,12p' || true
gh --version | head -n 1 || true
run_as_real_user '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  node -v
  npm -v
' || true

echo
echo "===== DONE ====="
echo "Installed:"
echo " - Docker Engine"
echo " - Docker Compose plugin"
echo " - Python 3.12 + venv + pipx"
echo " - Node.js LTS + npm via nvm"
echo " - Cockpit"
echo " - .NET 9 SDK"
echo " - GitHub CLI"
echo " - Common dev tools"
echo
echo "Cockpit: https://<server-ip>:9090"
echo
echo "Important:"
echo " - Log out and back in so Docker group membership applies to user: ${REAL_USER}"
echo " - Then test with: docker run hello-world"
echo " - Start GitHub auth with: gh auth login"
echo
