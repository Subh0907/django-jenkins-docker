#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

apt-get update
apt-get install --yes ca-certificates curl gnupg nginx certbot python3-certbot-nginx

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

source /etc/os-release
cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPOSITORY
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPOSITORY

apt-get update
apt-get install --yes docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker nginx

if ! id deploy >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash deploy
fi
usermod --append --groups docker deploy

install -d -o root -g docker -m 0750 /opt/django-app
install -d -o root -g root -m 0700 /var/backups/django-app
install -o root -g root -m 0755 "${SCRIPT_DIR}/deploy-django" /usr/local/bin/deploy-django
install -o root -g root -m 0755 "${SCRIPT_DIR}/backup-django-db" /usr/local/bin/backup-django-db
install -o root -g root -m 0644 "${KIT_ROOT}/deploy/systemd/django-db-backup.service" /etc/systemd/system/django-db-backup.service
install -o root -g root -m 0644 "${KIT_ROOT}/deploy/systemd/django-db-backup.timer" /etc/systemd/system/django-db-backup.timer

if [[ ! -f /opt/django-app/.env ]]; then
    install -o root -g docker -m 0640 "${KIT_ROOT}/.env.example" /opt/django-app/.env
fi

install -o root -g docker -m 0640 "${KIT_ROOT}/deploy/compose.yaml" /opt/django-app/compose.yaml

cat > /etc/sudoers.d/django-deploy <<'SUDOERS'
deploy ALL=(root) NOPASSWD: /usr/local/bin/deploy-django
SUDOERS
chmod 0440 /etc/sudoers.d/django-deploy
visudo -cf /etc/sudoers.d/django-deploy

systemctl daemon-reload
systemctl enable --now django-db-backup.timer

echo "Application server bootstrap complete."
echo "Next: configure /opt/django-app/.env, SSH, registry login, Nginx, and TLS."

