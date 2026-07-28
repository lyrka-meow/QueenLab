#!/usr/bin/env bash

set -euo pipefail

guest_user=${1:?guest username is required}
id "$guest_user" >/dev/null

pacman -Syu --needed --noconfirm \
    openssh qemu-guest-agent sudo curl tar sddm

systemctl enable sshd.service qemu-guest-agent.service sddm.service
systemctl set-default graphical.target

install -d -m 0750 /etc/sudoers.d
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$guest_user" \
    >/etc/sudoers.d/90-queenlab
chmod 0440 /etc/sudoers.d/90-queenlab

install -d -m 0755 /etc/queenlab
printf '%s\n' "$guest_user" >/etc/queenlab/user
