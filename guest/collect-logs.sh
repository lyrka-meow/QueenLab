#!/usr/bin/env bash

set -euo pipefail

out=/tmp/queenlab-diagnostics
archive=/tmp/queenlab-diagnostics.tar.gz

sudo rm -rf -- "$out"
install -d -m 0755 "$out"

capture()
{
    local file=$1
    shift
    "$@" >"$out/$file" 2>&1 || true
}

capture version.txt sh -c '
printf "expected: "; cat /var/lib/queenlab/expected-release 2>/dev/null || true
printf "installed: "; cat /opt/macqueende/VERSION 2>/dev/null || true
uname -a
'
capture packages.txt pacman -Q
capture display-manager.txt systemctl status display-manager.service
capture failed-units.txt systemctl --failed
capture sessions.txt loginctl list-sessions
capture session-details.txt loginctl session-status
capture processes.txt ps auxf
capture journal-system.txt sudo journalctl -b --no-pager
capture journal-user.txt journalctl --user -b --no-pager
capture coredump-list.txt sudo coredumpctl list -b --no-pager
capture coredumps.txt sudo coredumpctl info -b --no-pager
capture graphics.txt sh -c '
lspci -k
printf "\nDRM:\n"
ls -l /dev/dri 2>/dev/null || true
printf "\nOpenGL:\n"
command -v glxinfo >/dev/null && glxinfo -B || true
'
capture libraries.txt bash -c '
if [[ -x /opt/macqueende/build/compositor/bin/macqueen ]]; then
    LD_LIBRARY_PATH=/opt/macqueende/build/compositor/bin \
        ldd /opt/macqueende/build/compositor/bin/macqueen
fi
'
capture macqueen-session.txt sh -c '
printf "%s\n" "=== SDDM configuration ==="
find /etc/sddm.conf /etc/sddm.conf.d -maxdepth 1 -type f \
    -exec sh -c '"'"'echo "--- $1"; cat "$1"'"'"' sh {} \; 2>/dev/null || true
printf "%s\n" "=== Wayland sessions ==="
find /usr/share/wayland-sessions -maxdepth 1 -type f \
    -exec sh -c '"'"'echo "--- $1"; cat "$1"'"'"' sh {} \; 2>/dev/null || true
printf "%s\n" "=== Launcher ==="
sed -n "1,240p" /usr/bin/start-macqueende 2>/dev/null || true
'

for log in \
    "$HOME/.local/share/sddm/wayland-session.log" \
    /var/log/Xorg.0.log; do
    if [[ -f "$log" ]]; then
        destination="$out/$(basename -- "$log")"
        cp -a "$log" "$destination" 2>/dev/null ||
            sudo cat "$log" >"$destination"
    fi
done

tar -C /tmp -czf "$archive" queenlab-diagnostics
chmod 0644 "$archive"
printf '%s\n' "$archive"
