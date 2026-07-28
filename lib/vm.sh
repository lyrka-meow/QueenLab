#!/usr/bin/env bash

set -euo pipefail

ql_create_base()
{
    ql_need virsh
    ql_need virt-install
    ql_need qemu-img

    ql_fetch_iso
    ql_ensure_key

    if ql_domain_exists "$QL_BASE_DOMAIN"; then
        ql_die "domain $QL_BASE_DOMAIN already exists"
    fi

    if [[ -f "$QL_BASE_DISK" && ! -f "$QL_METADATA" ]]; then
        local actual_size
        actual_size=$(qemu-img info --output=json "$QL_BASE_DISK" |
            sed -n 's/^[[:space:]]*"actual-size":[[:space:]]*\\([0-9]*\\),*$/\1/p' |
            head -n1)
        if [[ "$actual_size" =~ ^[0-9]+$ ]] &&
            ((actual_size <= 1048576)); then
            ql_warn "removing an empty disk left by a failed create: $QL_BASE_DISK"
            rm -f -- "$QL_BASE_DISK"
        fi
    fi
    [[ ! -e "$QL_BASE_DISK" ]] ||
        ql_die "base disk already exists: $QL_BASE_DISK"

    qemu-img create -f qcow2 "$QL_BASE_DISK" "${QL_DISK_SIZE_GB}G"

    local graphics="spice,listen=none"
    local video="virtio"
    if [[ "$QL_ENABLE_3D" == "1" ]]; then
        graphics+=",gl.enable=yes"
        video+=",accel3d=yes"
    fi

    ql_info "creating the EndeavourOS installer VM"
    if ! virt-install \
        --connect "$QL_CONNECT_URI" \
        --name "$QL_BASE_DOMAIN" \
        --memory "$QL_MEMORY_MB" \
        --vcpus "$QL_VCPUS" \
        --cpu host-passthrough \
        --machine q35 \
        --boot uefi \
        --disk "path=$QL_BASE_DISK,format=qcow2,bus=virtio,cache=none" \
        --cdrom "$QL_ISO_PATH" \
        --network network=default,model=virtio \
        --graphics "$graphics" \
        --video "$video" \
        --sound ich9 \
        --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
        --os-variant archlinux \
        --noautoconsole \
        --wait 0; then
        if ! ql_domain_exists "$QL_BASE_DOMAIN"; then
            rm -f -- "$QL_BASE_DISK"
            ql_warn "removed the empty disk from the failed create"
        fi
        ql_die "failed to create the installer VM"
    fi

    ql_info "the installer is running"
    ql_info "finish the graphical EndeavourOS installation, create a user, then shut the VM down"
    ql_info "open it with: ./queenlab open base"
    ql_info "after shutdown run: ./queenlab seal --user YOUR_USERNAME"
}

ql_open()
{
    ql_need virt-viewer
    local target=${1:-latest}
    local domain
    case "$target" in
        base)
            domain=$QL_BASE_DOMAIN
            ;;
        latest)
            domain=$(ql_virsh list --all --name |
                awk '/^queenlab-test-/ {print}' |
                sort |
                tail -n1)
            [[ -n "$domain" ]] || domain=$QL_BASE_DOMAIN
            ;;
        *)
            domain=$target
            ;;
    esac

    ql_domain_exists "$domain" ||
        ql_die "domain does not exist: $domain"
    if ! ql_domain_running "$domain"; then
        ql_virsh start "$domain" >/dev/null
    fi
    exec virt-viewer --connect "$QL_CONNECT_URI" --attach "$domain"
}

ql_seal_base()
{
    ql_need virt-customize
    ql_need virsh
    ql_ensure_key

    local guest_user=
    while (($#)); do
        case "$1" in
            --user)
                [[ $# -ge 2 ]] || ql_die "--user requires a value"
                guest_user=$2
                shift 2
                ;;
            *)
                ql_die "unknown seal option: $1"
                ;;
        esac
    done
    [[ -n "$guest_user" ]] ||
        ql_die "usage: ./queenlab seal --user USERNAME"
    local username_pattern='^[a-z_][a-z0-9_-]*$'
    [[ "$guest_user" =~ $username_pattern ]] ||
        ql_die "invalid Linux username: $guest_user"
    [[ -f "$QL_BASE_DISK" ]] ||
        ql_die "base disk does not exist"
    ql_domain_exists "$QL_BASE_DOMAIN" ||
        ql_die "base domain does not exist"
    if ql_domain_running "$QL_BASE_DOMAIN"; then
        ql_die "shut down the EndeavourOS installer VM before sealing"
    fi

    chmod u+w "$QL_BASE_DISK"
    ql_info "preparing the offline base image for automated tests"
    sudo virt-customize \
        -a "$QL_BASE_DISK" \
        --network \
        --copy-in "$QL_ROOT/guest/prepare-base.sh:/root" \
        --run-command "bash /root/prepare-base.sh '$guest_user'" \
        --ssh-inject "$guest_user:file:$QL_KEY.pub" \
        --delete /root/prepare-base.sh

    local cdrom_target
    cdrom_target=$(ql_virsh domblklist "$QL_BASE_DOMAIN" --details |
        awk '$2 == "cdrom" && $4 != "-" {print $3; exit}')
    if [[ -n "$cdrom_target" ]]; then
        ql_virsh change-media "$QL_BASE_DOMAIN" "$cdrom_target" \
            --eject --config >/dev/null
    fi

    ql_virsh dumpxml "$QL_BASE_DOMAIN" >"$QL_STATE_DIR/base-domain.xml"
    ql_virsh undefine "$QL_BASE_DOMAIN" --keep-nvram >/dev/null
    chmod 0444 "$QL_BASE_DISK"

    {
        printf 'QL_GUEST_USER=%q\n' "$guest_user"
        printf 'QL_BASE_DISK=%q\n' "$QL_BASE_DISK"
        printf 'QL_SEALED_AT=%q\n' "$(date --iso-8601=seconds)"
    } >"$QL_METADATA"
    chmod 0600 "$QL_METADATA"

    ql_info "base image sealed"
    ql_info "run a clean test with: ./queenlab test v0.1.0-alpha.4"
}

ql_status()
{
    printf 'Base disk: %s\n' "$QL_BASE_DISK"
    if [[ -f "$QL_BASE_DISK" ]]; then
        qemu-img info "$QL_BASE_DISK" | sed -n '1,8p'
    else
        printf '  not created\n'
    fi

    printf '\nDomains:\n'
    ql_virsh list --all

    printf '\nArtifacts: %s\n' "$QL_ARTIFACTS_DIR"
    if [[ -d "$QL_ARTIFACTS_DIR" ]]; then
        find "$QL_ARTIFACTS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' |
            sort
    fi
}
