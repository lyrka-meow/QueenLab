#!/usr/bin/env bash

set -euo pipefail

release_tag=${1:?release tag is required}
guest_user=${2:?guest username is required}
macqueen_repo=${3:-lyrka-meow/MacqueenDE}

sudo pacman -Syu --needed --noconfirm
sudo pacman -S --needed --noconfirm sddm curl

installer_url="https://raw.githubusercontent.com/$macqueen_repo/main/installer/install-github.sh?queenlab=$(date +%s)"
MACQUEENDE_GITHUB_REPO="$macqueen_repo" \
MACQUEENDE_RELEASE_TAG="$release_tag" \
    bash -c "$(curl -fsSL "$installer_url")"

sudo install -d -m 0755 /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/90-queenlab.conf >/dev/null <<EOF
[Autologin]
User=$guest_user
Session=macqueende.desktop
Relogin=false
EOF

if systemctl list-unit-files --no-legend plasma-login-manager.service 2>/dev/null |
    grep -q '^plasma-login-manager.service'; then
    sudo systemctl disable plasma-login-manager.service 2>/dev/null || true
fi
sudo systemctl disable display-manager.service 2>/dev/null || true
sudo systemctl enable sddm.service
sudo systemctl set-default graphical.target

sudo install -d -m 0755 /var/lib/queenlab
printf '%s\n' "$release_tag" | sudo tee /var/lib/queenlab/expected-release >/dev/null
sudo systemd-run \
    --unit=queenlab-reboot \
    --on-active=2s \
    /usr/bin/systemctl reboot >/dev/null
