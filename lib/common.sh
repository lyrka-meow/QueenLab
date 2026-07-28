#!/usr/bin/env bash

set -euo pipefail

QL_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
QL_USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/queenlab/config.env"
QL_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/queenlab"
QL_ARTIFACTS_DIR="${QL_ARTIFACTS_DIR:-$QL_ROOT/artifacts}"

# shellcheck source=../config/defaults.env
source "$QL_ROOT/config/defaults.env"
if [[ -f "$QL_USER_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$QL_USER_CONFIG"
fi

QL_BASE_DISK="$QL_STORAGE_DIR/$QL_BASE_DISK_NAME"
QL_ISO_PATH="$QL_STORAGE_DIR/iso/$QL_ISO_NAME"
QL_KEY="$QL_STATE_DIR/id_ed25519"
QL_METADATA="$QL_STATE_DIR/base.env"

ql_info()
{
    printf 'QueenLab: %s\n' "$*"
}

ql_warn()
{
    printf 'QueenLab warning: %s\n' "$*" >&2
}

ql_die()
{
    printf 'QueenLab error: %s\n' "$*" >&2
    exit 1
}

ql_need()
{
    command -v "$1" >/dev/null 2>&1 ||
        ql_die "missing command '$1'; run: ./queenlab setup"
}

ql_virsh()
{
    virsh --connect "$QL_CONNECT_URI" "$@"
}

ql_domain_exists()
{
    ql_virsh dominfo "$1" >/dev/null 2>&1
}

ql_domain_running()
{
    [[ $(ql_virsh domstate "$1" 2>/dev/null || true) == "running" ]]
}

ql_ensure_state()
{
    mkdir -p "$QL_STATE_DIR" "$QL_ARTIFACTS_DIR"
    chmod 700 "$QL_STATE_DIR"
}

ql_ensure_key()
{
    ql_ensure_state
    if [[ ! -f "$QL_KEY" ]]; then
        ssh-keygen -q -t ed25519 -N '' -C queenlab -f "$QL_KEY"
    fi
}

ql_guest_ip()
{
    local domain=$1
    local source ip
    for source in agent lease arp; do
        ip=$(ql_virsh domifaddr "$domain" --source "$source" 2>/dev/null |
            awk '$3 == "ipv4" && $4 !~ /^127\\./ {sub(/\\/.*/, "", $4); print $4; exit}')
        if [[ -n "$ip" ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

ql_wait_for_ip()
{
    local domain=$1
    local timeout=${2:-$QL_BOOT_TIMEOUT}
    local deadline=$((SECONDS + timeout))
    local ip
    while ((SECONDS < deadline)); do
        ip=$(ql_guest_ip "$domain" || true)
        if [[ -n "$ip" ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
        sleep 2
    done
    return 1
}

ql_ssh()
{
    local ip=$1
    shift
    ssh \
        -i "$QL_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$QL_STATE_DIR/known_hosts" \
        "$QL_GUEST_USER@$ip" "$@"
}

ql_scp_from()
{
    local ip=$1
    local remote=$2
    local local_path=$3
    scp \
        -i "$QL_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$QL_STATE_DIR/known_hosts" \
        "$QL_GUEST_USER@$ip:$remote" "$local_path"
}

ql_wait_for_ssh()
{
    local domain=$1
    local timeout=${2:-$QL_BOOT_TIMEOUT}
    local deadline=$((SECONDS + timeout))
    local ip
    while ((SECONDS < deadline)); do
        ip=$(ql_guest_ip "$domain" || true)
        if [[ -n "$ip" ]] && ql_ssh "$ip" true >/dev/null 2>&1; then
            printf '%s\n' "$ip"
            return 0
        fi
        sleep 3
    done
    return 1
}

ql_load_metadata()
{
    [[ -f "$QL_METADATA" ]] ||
        ql_die "the base image is not sealed; run: ./queenlab seal --user USER"
    # shellcheck disable=SC1090
    source "$QL_METADATA"
    [[ -n ${QL_GUEST_USER:-} ]] ||
        ql_die "guest user is missing from $QL_METADATA"
}

ql_safe_name()
{
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}
