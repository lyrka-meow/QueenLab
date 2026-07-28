#!/usr/bin/env bash

set -euo pipefail

guest_user=${1:?guest username is required}
id "$guest_user" >/dev/null

required_packages=(
    openssh
    qemu-guest-agent
    sudo
    curl
    tar
    sddm
)
missing_packages=()
for package in "${required_packages[@]}"; do
    pacman -Q "$package" >/dev/null 2>&1 ||
        missing_packages+=("$package")
done

if ((${#missing_packages[@]})); then
    printf 'QueenLab: install these packages in the base VM before sealing: %s\n' \
        "${missing_packages[*]}" >&2
    exit 20
fi

if ! systemctl is-enabled sddm.service >/dev/null 2>&1; then
    printf '%s\n' \
        'QueenLab: enable SDDM in the base VM before sealing: sudo systemctl enable sddm.service' >&2
    exit 21
fi

if [[ $(systemctl get-default) != graphical.target ]]; then
    printf '%s\n' \
        'QueenLab: select graphical.target in the base VM before sealing: sudo systemctl set-default graphical.target' >&2
    exit 22
fi

# SDDM and the graphical target belong to the manually prepared base. QueenLab
# only enables the services required to control disposable test guests.
systemctl enable sshd.service qemu-guest-agent.service

install -d -m 0750 /etc/sudoers.d
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$guest_user" \
    >/etc/sudoers.d/90-queenlab
chmod 0440 /etc/sudoers.d/90-queenlab

install -d -m 0755 /etc/queenlab
printf '%s\n' "$guest_user" >/etc/queenlab/user
