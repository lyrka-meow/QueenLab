# QueenLab

QueenLab creates disposable EndeavourOS virtual machines for full-session
MacqueenDE tests. It boots a real guest kernel with systemd, SDDM, logind,
PipeWire, desktop portals, a virtual DRM device, and the Macqueen compositor.

It intentionally does not use containers. A container cannot reproduce the
display-manager, seat, DRM, and system-session failures this project is meant
to catch.

## What it does

- downloads the pinned official EndeavourOS ISO and verifies its SHA-512;
- creates a KVM/libvirt VM with UEFI, VirtIO storage/network, and VirtIO GPU;
- turns one manual EndeavourOS installation into a read-only base image;
- clones its UEFI state and creates a fresh qcow2 overlay for every test;
- installs the requested GitHub release and configures SDDM autologin;
- detects whether Macqueen remains alive for a stability window;
- always keeps the VM available for visual inspection;
- collects the system journal, user journal, coredumps, SDDM session log,
  package list, library resolution, process tree, domain XML, and screenshot.

## Host requirements

The automatic setup targets an Arch Linux host with hardware virtualization
enabled. QueenLab uses the system libvirt connection (`qemu:///system`).

Check the host:

```bash
./queenlab doctor
```

Install and configure the required packages:

```bash
./queenlab setup
```

Log out and back in if setup adds the current user to the `libvirt` group.
The command is safe to rerun after an interrupted setup. It enables the
modular libvirt storage socket and can rebuild a stale firewalld nftables
state while preserving Docker bridge zone assignments. If a full system
upgrade replaces the running kernel modules, setup stops with an explicit
request to reboot before it configures virtual networking.

If another network manager leaves the firewalld, Docker, and libvirt rules out
of sync, rebuild only the host virtual-network state:

```bash
./queenlab repair-network
```

The repair refuses to interrupt running containers. With an idle Docker
daemon, it restarts firewalld in a clean order, restores Docker, and asks the
libvirt network daemon to reload its NAT rules. It also enables Docker's
`ip-forward-no-drop` option so Docker does not replace host forwarding with a
blanket `DROP` policy. Filtering remains with firewalld and libvirt. Host VPN
processes are not stopped.

## First-time base installation

Create and open the installer VM:

```bash
./queenlab create
./queenlab open base
```

Complete the normal graphical EndeavourOS installation:

1. Choose the recommended **online** installation.
2. Select **No Desktop** so the base contains no Plasma/GNOME state.
3. Install to the whole virtual disk.
4. Create a normal user.
5. Finish the installer.
6. Boot the installed system and log in on its text console.
7. Install the small test baseline:

   ```bash
   sudo pacman -Syu --needed sddm openssh qemu-guest-agent sudo curl tar
   sudo systemctl enable sddm.service
   sudo systemctl set-default graphical.target
   ```

8. Configure SDDM exactly as you want the clean pre-Macqueen system to look.
   Do not create a Macqueen session or Macqueen autologin.
9. Shut the virtual machine down completely with `sudo poweroff`.

Then convert it to an immutable test base:

```bash
./queenlab seal --user YOUR_USERNAME
```

`seal` works completely offline on the powered-off disk. It does not download,
install, upgrade, or configure SDDM. It verifies the manually installed baseline,
injects QueenLab's dedicated SSH key, enables only SSH and QEMU Guest Agent, and
records the guest username. The base disk is then made read-only. Its domain
template and UEFI variables are retained so every disposable VM starts from this
exact pre-Macqueen state.

## Test MacqueenDE

### Manual installer test

Start with this mode when testing the same public command that a real user runs:

```bash
./queenlab test --manual
./queenlab console latest
```

Log in to the disposable guest and run:

```bash
curl -fsSL https://raw.githubusercontent.com/lyrka-meow/MacqueenDE/main/installer/install-github.sh | bash
```

QueenLab does not install packages, edit SDDM, or enable autologin in manual mode.
After the installer finishes, reboot the guest and select MacqueenDE in SDDM
exactly as a normal user would. To return to the frozen pre-Macqueen state, remove
the disposable VM with `./queenlab destroy latest` and start another manual test.

### Automated release test

Run an exact release in a fresh VM:

```bash
./queenlab test v0.1.0-alpha.4
```

The test runs the public MacqueenDE installer for the exact requested tag without
preinstalling its dependencies. After the installer succeeds, QueenLab adds an
autologin into `macqueende.desktop` only to that disposable overlay, reboots it,
and watches the compositor. The sealed base and its SDDM configuration are never
modified.

Open the most recent test visually:

```bash
./queenlab open
```

Collect another diagnostic bundle:

```bash
./queenlab logs
```

Results are written under `artifacts/`:

```text
artifacts/0.1.0-alpha.4-YYYYMMDD-HHMMSS/
├── result.env
├── domain.xml
├── domain-info.txt
├── domain-state.txt
├── screen.ppm
└── queenlab-diagnostics/
    ├── journal-system.txt
    ├── journal-user.txt
    ├── coredumps.txt
    ├── macqueen-session.txt
    ├── wayland-session.log
    ├── libraries.txt
    ├── packages.txt
    └── processes.txt
```

## VM lifecycle

Show the base, test domains, and artifacts:

```bash
./queenlab status
```

Remove the latest disposable test domain and its overlay:

```bash
./queenlab destroy
```

Or remove a specific test:

```bash
./queenlab destroy queenlab-test-0.1.0-alpha.4-YYYYMMDD-HHMMSS
```

The read-only base image is never removed by `destroy`.

## Configuration

Copy the defaults and edit the copy:

```bash
mkdir -p ~/.config/queenlab
cp config/defaults.env ~/.config/queenlab/config.env
```

Common overrides include VM memory, CPU count, disk size, 3D acceleration,
render node, storage directory, boot timeout, and the pinned EndeavourOS ISO.
QueenLab prefers the first PCI render node for VirGL and retries with software
rendering when the host EGL implementation cannot initialize it.

The current default is the official EndeavourOS Titan Neo 2026.04.27 image.
The checksum is pinned in [`config/defaults.env`](config/defaults.env) and can
be compared with the [EndeavourOS download page](https://endeavouros.com/).

## Commands

```text
doctor                 Check KVM, libvirt, and required tools
setup                  Install and configure host dependencies
repair-network         Rebuild firewalld/libvirt NAT without stopping VPN
fetch                  Download and verify the EndeavourOS ISO
create                 Create the one-time installer VM
open [target]          Open base, latest, or a named domain
console [target]       Open a paste-friendly serial terminal (exit with Ctrl+])
seal --user USER       Prepare and freeze the installed base disk
test RELEASE_TAG       Run an automated MacqueenDE release test
test --manual          Start an untouched disposable VM for manual installation
logs [domain]          Collect diagnostics from an existing test
status                 Show disks, domains, and artifacts
destroy [domain]       Remove a disposable test and its overlay
```

QueenLab uses [libvirt](https://libvirt.org/), QEMU
[VirtIO GPU](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html),
and [libguestfs](https://libguestfs.org/virt-customize.1.html).
