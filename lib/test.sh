#!/usr/bin/env bash

set -euo pipefail

ql_latest_test_domain()
{
    ql_virsh list --all --name |
        awk '/^queenlab-test-/ {
            print substr($0, length($0) - 14), $0
        }' |
        sort |
        tail -n1 |
        cut -d' ' -f2-
}

ql_create_test_domain()
{
    local release_tag=$1
    local stamp=$2
    local safe_tag domain overlay

    safe_tag=$(ql_safe_name "${release_tag#v}")
    domain="queenlab-test-${safe_tag:0:24}-$stamp"
    overlay="$QL_STORAGE_DIR/tests/$domain.qcow2"
    mkdir -p "$QL_STORAGE_DIR/tests"

    qemu-img create -f qcow2 -F qcow2 -b "$QL_BASE_DISK" "$overlay" >/dev/null

    if ! virt-clone \
        --connect "$QL_CONNECT_URI" \
        --original-xml "$QL_STATE_DIR/base-domain.xml" \
        --name "$domain" \
        --file "$overlay" \
        --preserve-data >/dev/null; then
        rm -f -- "$overlay"
        ql_die "failed to clone the base domain"
    fi
    if ! ql_virsh start "$domain" >/dev/null; then
        ql_virsh undefine "$domain" --nvram >/dev/null 2>&1 || true
        rm -f -- "$overlay"
        ql_die "failed to start test domain: $domain"
    fi

    printf '%s\n' "$domain"
}

ql_wait_for_ssh_cycle()
{
    local domain=$1
    local deadline=$((SECONDS + QL_BOOT_TIMEOUT))
    local went_down=0
    local ip

    while ((SECONDS < deadline)); do
        ip=$(ql_guest_ip "$domain" || true)
        if [[ -z "$ip" ]] || ! ql_ssh "$ip" true >/dev/null 2>&1; then
            went_down=1
        elif ((went_down)); then
            printf '%s\n' "$ip"
            return 0
        fi
        sleep 3
    done
    return 1
}

ql_collect_logs()
{
    local domain=$1
    local artifact_dir=$2
    local result=${3:-unknown}
    local ip archive

    mkdir -p "$artifact_dir"
    {
        printf 'domain=%s\n' "$domain"
        printf 'result=%s\n' "$result"
        printf 'collected_at=%s\n' "$(date --iso-8601=seconds)"
    } >"$artifact_dir/result.env"

    ql_virsh dumpxml "$domain" >"$artifact_dir/domain.xml" 2>&1 || true
    ql_virsh dominfo "$domain" >"$artifact_dir/domain-info.txt" 2>&1 || true
    ql_virsh domstate "$domain" --reason \
        >"$artifact_dir/domain-state.txt" 2>&1 || true
    ql_virsh domifaddr "$domain" \
        >"$artifact_dir/domain-addresses.txt" 2>&1 || true
    ql_virsh domblklist "$domain" --details \
        >"$artifact_dir/domain-storage.txt" 2>&1 || true
    ql_virsh screenshot "$domain" "$artifact_dir/screen.ppm" >/dev/null 2>&1 || true
    journalctl -b --no-pager \
        -u virtqemud.service \
        -u virtnetworkd.service \
        >"$artifact_dir/host-libvirt-journal.txt" 2>&1 || true
    if sudo -n test -r "/var/log/libvirt/qemu/$domain.log" 2>/dev/null; then
        sudo -n cp "/var/log/libvirt/qemu/$domain.log" \
            "$artifact_dir/host-qemu.log"
        sudo -n chown "$USER:" "$artifact_dir/host-qemu.log"
    else
        printf '%s\n' \
            "Run: sudo cp /var/log/libvirt/qemu/$domain.log $artifact_dir/host-qemu.log" \
            >"$artifact_dir/host-qemu-log-unavailable.txt"
    fi

    ip=$(ql_guest_ip "$domain" || true)
    if [[ -z "$ip" ]] || ! ql_ssh "$ip" true >/dev/null 2>&1; then
        ql_warn "guest SSH is unavailable; only host-side diagnostics were collected"
        return
    fi

    archive=$(ql_ssh "$ip" 'bash -s' <"$QL_ROOT/guest/collect-logs.sh" |
        tail -n1)
    if [[ -n "$archive" ]]; then
        ql_scp_from "$ip" "$archive" "$artifact_dir/guest.tar.gz" >/dev/null
        tar -xzf "$artifact_dir/guest.tar.gz" -C "$artifact_dir"
    fi
}

ql_test_release()
{
    ql_need qemu-img
    ql_need virt-clone
    ql_need virsh
    ql_load_metadata

    local release_tag=${1:-}
    if [[ "$release_tag" == "--manual" ]]; then
        ql_start_manual_test
        return
    fi

    ql_need ssh
    [[ -n "$release_tag" ]] ||
        ql_die "usage: ./queenlab test rolling | ./queenlab test --manual"
    if [[ "$release_tag" != "rolling" &&
          ! "$release_tag" =~ ^v[0-9A-Za-z._-]+$ ]]; then
        ql_die "invalid release tag: $release_tag"
    fi
    [[ -f "$QL_BASE_DISK" ]] ||
        ql_die "sealed base disk is missing: $QL_BASE_DISK"
    [[ -f "$QL_STATE_DIR/base-domain.xml" ]] ||
        ql_die "base domain template is missing; run seal again"
    [[ ! -w "$QL_BASE_DISK" ]] ||
        ql_die "base disk is writable; run seal before testing"

    local stamp domain artifact_dir ip result first_seen deadline installed
    stamp=$(date +%Y%m%d-%H%M%S)
    artifact_dir="$QL_ARTIFACTS_DIR/${release_tag#v}-$stamp"
    mkdir -p "$artifact_dir"

    ql_info "creating a clean overlay for $release_tag"
    domain=$(ql_create_test_domain "$release_tag" "$stamp")
    ql_info "test VM started: $domain"

    ip=$(ql_wait_for_ssh "$domain" "$QL_BOOT_TIMEOUT" || true)
    if [[ -z "$ip" ]]; then
        ql_warn "guest did not become reachable"
        ql_collect_logs "$domain" "$artifact_dir" boot-timeout
        return 1
    fi

    ql_info "installing MacqueenDE $release_tag inside the clean guest"
    local install_rc
    set +e
    ql_ssh "$ip" \
        "bash -s -- '$release_tag' '$QL_GUEST_USER' '$QL_MACQUEEN_REPO'" \
        <"$QL_ROOT/guest/install-test.sh" 2>&1 |
        tee "$artifact_dir/install.log"
    install_rc=${PIPESTATUS[0]}
    set -e
    if ((install_rc != 0)); then
        ql_warn "guest installation command failed with status $install_rc"
        ql_collect_logs "$domain" "$artifact_dir" install-command-failed
        return 1
    fi

    ip=$(ql_wait_for_ssh_cycle "$domain" || true)
    if [[ -z "$ip" ]]; then
        ql_warn "guest did not return after installation"
        ql_collect_logs "$domain" "$artifact_dir" reboot-timeout
        return 1
    fi

    installed=$(ql_ssh "$ip" 'cat /opt/macqueende/VERSION 2>/dev/null || true')
    if [[ -z "$installed" ]]; then
        ql_warn "release installation failed: /opt/macqueende/VERSION is missing"
        ql_collect_logs "$domain" "$artifact_dir" install-failed
        return 1
    fi
    if [[ "$release_tag" != "rolling" &&
          "$installed" != "${release_tag#v}" ]]; then
        ql_warn "release installation failed: expected ${release_tag#v}, got ${installed:-nothing}"
        ql_collect_logs "$domain" "$artifact_dir" install-failed
        return 1
    fi

    ql_info "waiting for a stable Macqueen compositor"
    result=failed
    first_seen=0
    deadline=$((SECONDS + QL_BOOT_TIMEOUT))
    while ((SECONDS < deadline)); do
        if ql_ssh "$ip" "pgrep -u \$(id -u '$QL_GUEST_USER') -x macqueen >/dev/null" \
            >/dev/null 2>&1; then
            if ((first_seen == 0)); then
                first_seen=$SECONDS
            elif ((SECONDS - first_seen >= QL_STABILITY_SECONDS)); then
                result=passed
                break
            fi
        elif ((first_seen > 0)); then
            result=crashed
            break
        fi
        sleep 3
    done

    ql_collect_logs "$domain" "$artifact_dir" "$result"
    if [[ "$result" == "passed" ]]; then
        ql_info "PASS: Macqueen stayed alive for ${QL_STABILITY_SECONDS}s"
        ql_info "open the VM with: ./queenlab open '$domain'"
        ql_info "diagnostics: $artifact_dir"
        return 0
    fi

    ql_warn "FAIL: Macqueen did not stay alive (result: $result)"
    ql_warn "diagnostics: $artifact_dir"
    return 1
}

ql_start_manual_test()
{
    [[ -f "$QL_BASE_DISK" ]] ||
        ql_die "sealed base disk is missing: $QL_BASE_DISK"
    [[ -f "$QL_STATE_DIR/base-domain.xml" ]] ||
        ql_die "base domain template is missing; run seal again"
    [[ ! -w "$QL_BASE_DISK" ]] ||
        ql_die "base disk is writable; run seal before testing"

    local stamp domain
    stamp=$(date +%Y%m%d-%H%M%S)

    ql_info "creating a clean manual overlay"
    domain=$(ql_create_test_domain manual "$stamp")
    ql_info "manual test VM started: $domain"
    ql_info "terminal: ./queenlab console '$domain'"
    ql_info "display:  ./queenlab open '$domain'"
    ql_info "QueenLab will not install or configure anything inside this overlay"
}

ql_collect_existing()
{
    ql_load_metadata
    local domain=${1:-}
    [[ -n "$domain" ]] || domain=$(ql_latest_test_domain)
    [[ -n "$domain" ]] || ql_die "no test domains found"
    ql_domain_exists "$domain" || ql_die "domain does not exist: $domain"

    local artifact_dir
    artifact_dir="$QL_ARTIFACTS_DIR/manual-$(date +%Y%m%d-%H%M%S)"
    ql_collect_logs "$domain" "$artifact_dir" manual
    ql_info "diagnostics: $artifact_dir"
}

ql_destroy_test()
{
    local domain=${1:-latest}
    if [[ "$domain" == "latest" ]]; then
        domain=$(ql_latest_test_domain)
    fi
    [[ "$domain" == queenlab-test-* ]] ||
        ql_die "refusing to remove a non-test domain: ${domain:-empty}"
    ql_domain_exists "$domain" ||
        ql_die "domain does not exist: $domain"

    local disk
    disk=$(ql_virsh domblklist "$domain" --details |
        awk '$2 == "disk" {print $4; exit}')
    if ql_domain_running "$domain"; then
        ql_virsh destroy "$domain" >/dev/null
    fi
    ql_virsh undefine "$domain" --nvram >/dev/null

    case "$disk" in
        "$QL_STORAGE_DIR"/tests/queenlab-test-*.qcow2)
            rm -f -- "$disk"
            ;;
        *)
            ql_warn "domain removed, but unexpected disk path was kept: ${disk:-unknown}"
            ;;
    esac
    ql_info "removed test domain: $domain"
}
