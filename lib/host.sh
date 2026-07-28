#!/usr/bin/env bash

set -euo pipefail

ql_doctor()
{
    local failed=0
    local command

    printf 'QueenLab host check\n\n'
    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        printf '  [ok] KVM device: /dev/kvm\n'
    else
        printf '  [!!] /dev/kvm is unavailable to this user\n'
        failed=1
    fi

    for command in virsh virt-install virt-clone virt-viewer qemu-img \
        virt-customize curl ssh scp; do
        if command -v "$command" >/dev/null 2>&1; then
            printf '  [ok] %s\n' "$command"
        else
            printf '  [--] %s is missing\n' "$command"
            failed=1
        fi
    done

    if command -v virsh >/dev/null 2>&1 &&
        ql_virsh uri >/dev/null 2>&1; then
        printf '  [ok] libvirt connection: %s\n' "$QL_CONNECT_URI"
    else
        printf '  [--] cannot connect to %s\n' "$QL_CONNECT_URI"
        failed=1
    fi

    if [[ -f "$QL_BASE_DISK" ]]; then
        printf '  [ok] base disk: %s\n' "$QL_BASE_DISK"
    else
        printf '  [--] base disk has not been created\n'
    fi

    if [[ -f "$QL_METADATA" ]]; then
        printf '  [ok] base metadata: %s\n' "$QL_METADATA"
    else
        printf '  [--] base image has not been sealed\n'
    fi

    if ((failed)); then
        printf '\nRun ./queenlab setup to install and configure the host.\n'
        return 1
    fi
}

ql_setup()
{
    [[ -f /etc/arch-release ]] ||
        ql_die "automatic host setup currently supports Arch Linux"
    [[ -c /dev/kvm ]] ||
        ql_die "/dev/kvm is missing; enable VT-x/AMD-V in firmware"

    ql_info "installing the KVM/libvirt toolchain"
    sudo pacman -Syu --needed --noconfirm \
        qemu-desktop libvirt virt-install virt-viewer \
        edk2-ovmf dnsmasq guestfs-tools openssh curl

    if systemctl list-unit-files --no-legend virtqemud.socket 2>/dev/null |
        grep -q '^virtqemud.socket'; then
        sudo systemctl enable --now \
            virtqemud.socket virtnetworkd.socket virtstoraged.socket \
            virtlogd.socket
    else
        sudo systemctl enable --now libvirtd.service
    fi

    if getent group libvirt >/dev/null; then
        sudo usermod -aG libvirt "$USER"
    fi

    sudo install -d -m 0775 -o "$USER" -g libvirt "$QL_STORAGE_DIR"
    sudo install -d -m 0775 -o "$USER" -g libvirt "$QL_STORAGE_DIR/iso"
    ql_ensure_key

    if systemctl is-active --quiet firewalld.service; then
        if ! firewall-cmd --get-zones 2>/dev/null |
            tr ' ' '\n' |
            grep -qx libvirt; then
            [[ -f /usr/lib/firewalld/zones/libvirt.xml ]] ||
                ql_die "firewalld is active, but its libvirt zone is missing"
            ql_info "reloading firewalld to discover the installed libvirt zone"
            sudo firewall-cmd --reload >/dev/null
        fi
        firewall-cmd --get-zones 2>/dev/null |
            tr ' ' '\n' |
            grep -qx libvirt ||
            ql_die "firewalld did not load the libvirt zone"
    fi

    if ! sudo virsh --connect "$QL_CONNECT_URI" net-info default >/dev/null 2>&1; then
        [[ -f /usr/share/libvirt/networks/default.xml ]] ||
            ql_die "libvirt default network template is missing"
        sudo virsh --connect "$QL_CONNECT_URI" \
            net-define /usr/share/libvirt/networks/default.xml >/dev/null
    fi
    if [[ $(sudo virsh --connect "$QL_CONNECT_URI" net-info default |
        awk '/Active:/ {print $2}') != "yes" ]]; then
        sudo virsh --connect "$QL_CONNECT_URI" net-start default >/dev/null
    fi
    sudo virsh --connect "$QL_CONNECT_URI" net-autostart default >/dev/null

    ql_info "host setup completed"
    if ! id -nG | tr ' ' '\n' | grep -qx libvirt; then
        ql_warn "log out and back in once so the libvirt group becomes active"
    fi
}

ql_fetch_iso()
{
    ql_need curl
    mkdir -p "$(dirname -- "$QL_ISO_PATH")"

    if [[ -f "$QL_ISO_PATH" ]]; then
        local current
        current=$(sha512sum "$QL_ISO_PATH" | awk '{print $1}')
        if [[ "$current" == "$QL_ISO_SHA512" ]]; then
            ql_info "verified ISO already exists: $QL_ISO_PATH"
            return
        fi
        ql_die "existing ISO has the wrong SHA512: $QL_ISO_PATH"
    fi

    ql_info "downloading $QL_ISO_NAME"
    curl -fL --progress-bar "$QL_ISO_URL" -o "$QL_ISO_PATH.part"
    local downloaded
    downloaded=$(sha512sum "$QL_ISO_PATH.part" | awk '{print $1}')
    if [[ "$downloaded" != "$QL_ISO_SHA512" ]]; then
        ql_die "ISO checksum mismatch; partial file kept at $QL_ISO_PATH.part"
    fi
    mv -- "$QL_ISO_PATH.part" "$QL_ISO_PATH"
    chmod 0644 "$QL_ISO_PATH"
    ql_info "ISO verified: $QL_ISO_PATH"
}
