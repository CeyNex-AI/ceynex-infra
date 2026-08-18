#!/usr/bin/env bash
# Run once on EACH of the three VMs (frontend, backend, database) via SSH.
# For Debian 12 (bookworm).
set -euo pipefail

# Remove any conflicting packages Debian ships by default under different names.
# Harmless no-op if none of these are installed.
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" || true
done

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Let your non-root user run docker without sudo (log out/in after this)
sudo usermod -aG docker "$USER"

echo "Docker installed. Log out and back in (or run 'newgrp docker'), then verify:"
echo "  docker --version && docker compose version"