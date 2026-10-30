#!/usr/bin/env bash
# driveit-server unexpected shutdown evidence collector
# Read-only diagnostics; writes only into its output directory.
set -uo pipefail
umask 077
export LC_ALL=C
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${1:-$PWD/driveit-shutdown-evidence-$STAMP}"
mkdir -p "$OUT"/{boot,kernel,hardware,storage,kvm,services,security,network,config,logs}
LOG="$OUT/collection.log"
exec 3>>"$LOG"
log(){ printf '%s %s\n' "$(date -Is)" "$*" | tee /dev/fd/3 >&2; }
run(){ local path="$1"; shift; mkdir -p "$(dirname "$OUT/$path")"; log "RUN $path :: $*"; { printf '# command:'; printf ' %q' "$@"; printf '\n# captured: %s\n\n' "$(date -Is)"; timeout --signal=TERM 45s "$@"; rc=$?; printf '\n# exit status: %s\n' "$rc"; } >"$OUT/$path" 2>&1 || true; }
shcmd(){ local path="$1"; shift; run "$path" bash -c "$*"; }
copy_file(){ local src="$1" dest="$2"; if [[ -f "$src" && -r "$src" ]]; then cp -- "$src" "$OUT/$dest" 2>>"$LOG" || true; fi; }
if [[ $EUID -ne 0 ]]; then echo 'Run as root: sudo bash driveit_shutdown_investigation.sh' >&2; exit 1; fi
log "Collecting to $OUT; no system configuration will be changed."
run boot/date.txt date -Is
run boot/uptime.txt uptime -s
run boot/uptime_detail.txt uptime
run boot/time.txt timedatectl
run boot/uname.txt uname -a
run boot/os-release.txt cat /etc/os-release
run boot/boot-id.txt cat /proc/sys/kernel/random/boot_id
run boot/boot-list.txt journalctl --list-boots --no-pager
run boot/last-reboots.txt last -x -F -n 100
run boot/who.txt who -a
run boot/loginctl.txt loginctl list-sessions --no-pager
run boot/current-boot-tail.txt journalctl -b 0 -n 350 --no-pager -o short-iso-precise
run boot/previous-boot-tail.txt journalctl -b -1 -n 1000 --no-pager -o short-iso-precise
run boot/previous-boot-first.txt journalctl -b -1 -n 150 --no-pager -o short-iso-precise
run boot/previous-boot-priority.txt journalctl -b -1 -p 0..4 --no-pager -o short-iso-precise
run boot/previous-boot-full.txt journalctl -b -1 --no-pager -o short-iso-precise
run boot/previous-previous-boot-tail.txt journalctl -b -2 -n 350 --no-pager -o short-iso-precise
run boot/shutdown-keywords.txt journalctl -b -1 --no-pager -o short-iso-precise -g 'shutdown|reboot|poweroff|power-off|halt|Reached target.*(Shutdown|Reboot|Power-Off)|systemd-shutdown|Stopping|watchdog|panic|thermal|critical temperature|power key|Power key|ACPI|SIGTERM|SIGKILL|oom|Out of memory|Killed process|lockup|hung task|rcu.*stall|Machine check|MCE|EDAC|AER|PCIe|nvme|I/O error|EXT4-fs error|BTRFS error|WRMSR|Xid|NVRM'
run kernel/current-kernel.txt journalctl -k -b 0 --no-pager -o short-iso-precise
run kernel/previous-kernel.txt journalctl -k -b -1 --no-pager -o short-iso-precise
run kernel/previous-kernel-errors.txt journalctl -k -b -1 -p 0..4 --no-pager -o short-iso-precise
run kernel/dmesg.txt dmesg --time-format iso
run kernel/cmdline.txt cat /proc/cmdline
run kernel/sysctl-panic.txt sysctl kernel.panic kernel.panic_on_oops kernel.softlockup_panic kernel.hardlockup_panic kernel.nmi_watchdog
run kernel/pstore-list.txt ls -la /sys/fs/pstore
shcmd kernel/pstore-contents.txt 'for f in /sys/fs/pstore/*; do [ -f "$f" ] || continue; echo "### $f"; head -c 200000 "$f"; echo; done'
run kernel/ras-logs.txt journalctl -b -1 --no-pager -g 'mce|MCE|machine check|hardware error|EDAC|rasdaemon|GHES|WHEA|microcode|amdgpu|NVRM|Xid|AER|pcieport|PCIe Bus Error'
run hardware/lscpu.txt lscpu
run hardware/free.txt free -h
run hardware/meminfo.txt cat /proc/meminfo
run hardware/swaps.txt swapon --show
run hardware/dmidecode-system.txt dmidecode -t system
run hardware/dmidecode-bios.txt dmidecode -t bios
run hardware/dmidecode-memory.txt dmidecode -t memory
run hardware/lspci.txt lspci -nnk
run hardware/lspci-verbose.txt lspci -vv
run hardware/lsusb.txt lsusb
run hardware/sensors.txt sensors
run hardware/hwmon.txt bash -c 'for d in /sys/class/hwmon/hwmon*; do echo "### $d"; cat "$d/name" 2>/dev/null; grep -H . "$d"/{temp*_input,temp*_crit,fan*_input,power*_input} 2>/dev/null; done'
run hardware/nvidia-smi.txt nvidia-smi -q
run hardware/nvidia-pcie.txt nvidia-smi --query-gpu=name,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv
run hardware/ipmi-sel.txt ipmitool sel elist
run hardware/ipmi-sensors.txt ipmitool sensor
run hardware/watchdog-devices.txt ls -l /dev/watchdog /dev/watchdog0
run hardware/watchdog-services.txt systemctl list-units --all '*watchdog*' --no-pager
run hardware/rasdaemon.txt systemctl status rasdaemon --no-pager
run storage/lsblk.txt lsblk -e7 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,TRAN
run storage/df.txt df -hT
run storage/mount.txt findmnt
run storage/fstab.txt cat /etc/fstab
run storage/nvme-list.txt nvme list
shcmd storage/smart-nvme.txt 'for d in /dev/nvme[0-9]*; do [[ "$d" =~ ^/dev/nvme[0-9]+$ ]] || continue; echo "### $d"; timeout 20 nvme smart-log "$d" 2>&1; timeout 20 smartctl -a "$d" 2>&1; done'
shcmd storage/smart-disks.txt 'for d in /dev/sd?; do [ -b "$d" ] || continue; echo "### $d"; timeout 20 smartctl -a "$d" 2>&1; done'
run storage/io-errors.txt journalctl -b -1 --no-pager -g 'I/O error|Buffer I/O|blk_update|nvme|ata[0-9]|reset controller|EXT4-fs|BTRFS|XFS|read-only file system|journal abort|filesystem error'
run kvm/virsh-list.txt virsh list --all
run kvm/virsh-nodeinfo.txt virsh nodeinfo
run kvm/libvirt-status.txt systemctl status libvirtd virtqemud --no-pager
run kvm/qemu-processes.txt ps -eo pid,ppid,lstart,etime,stat,%cpu,%mem,rss,cmd --sort=-rss
run kvm/kvm-kernel-messages.txt journalctl -k -b -1 --no-pager -g 'kvm|KVM|WRMSR|MSR|qemu|vfio|iommu|IOMMU'
run kvm/libvirt-previous-boot.txt journalctl -b -1 -u libvirtd -u virtqemud -u virtlogd -u virtlockd --no-pager -o short-iso-precise
shcmd kvm/domains.txt 'if command -v virsh >/dev/null; then while IFS= read -r name; do [ -n "$name" ] || continue; echo "=== $name ==="; virsh dominfo "$name" 2>&1; virsh domblklist "$name" --details 2>&1; virsh domiflist "$name" 2>&1; virsh domstate "$name" --reason 2>&1; done < <(virsh list --all --name); fi'
shcmd kvm/qemu-log-tails.txt 'for f in /var/log/libvirt/qemu/*.log; do [ -f "$f" ] || continue; echo "### $f"; tail -n 350 "$f"; done'
run services/failed.txt systemctl --failed --no-pager
run services/shutdown-target.txt systemctl status shutdown.target reboot.target poweroff.target --no-pager
run services/logind-previous.txt journalctl -b -1 -u systemd-logind -u systemd-oomd -u systemd-journald --no-pager -o short-iso-precise
run services/acpid-previous.txt journalctl -b -1 -u acpid -u upower -u thermald -u power-profiles-daemon --no-pager -o short-iso-precise
run services/oom-previous.txt journalctl -b -1 --no-pager -g 'oom-kill|Out of memory|Killed process|systemd-oomd|Memory cgroup out of memory|invoked oom-killer'
run services/sysstat.txt systemctl status sysstat sysstat-collect.timer --no-pager
shcmd services/sar-history.txt 'if command -v sar >/dev/null; then for f in $(find /var/log/sysstat -maxdepth 1 -type f -name "sa[0-9]*" -mtime -7 2>/dev/null | sort); do echo "### $f"; sar -u -r -S -q -b -d -f "$f" 2>&1 | tail -n 650; done; fi'
run security/sudo-previous.txt journalctl -b -1 _COMM=sudo --no-pager -o short-iso-precise
run security/polkit-previous.txt journalctl -b -1 -u polkit --no-pager -o short-iso-precise
run security/auth-shutdown-events.txt bash -c 'for f in /var/log/auth.log /var/log/auth.log.1; do [ -r "$f" ] && grep -Ei "sudo|shutdown|reboot|poweroff|halt|systemctl|pkexec|session opened|session closed" "$f" | tail -n 500; done'
run security/audit-status.txt auditctl -s
run security/audit-shutdown.txt ausearch -m USER_CMD,USER_AUTH,USER_LOGIN,SYSTEM_BOOT,SYSTEM_SHUTDOWN -ts recent
run security/cron-timers.txt systemctl list-timers --all --no-pager
run security/crontab-root.txt crontab -l
run security/cron-config.txt bash -c 'ls -la /etc/cron*; grep -RInE "shutdown|reboot|poweroff|halt|systemctl (reboot|poweroff)" /etc/cron* /etc/systemd/system 2>/dev/null | head -n 250'
run network/ip-addresses.txt ip -br address
run network/ip-routes.txt ip route
run network/bridge.txt bridge link show
run config/journal-storage.txt journalctl --disk-usage
run config/journald-config.txt systemd-analyze cat-config systemd/journald.conf
run config/journal-directories.txt ls -ld /var/log/journal /run/log/journal
run config/log-rotate.txt ls -lh /var/log/syslog* /var/log/kern.log* /var/log/auth.log* /var/log/libvirt/qemu/*.log
run config/grub-config.txt bash -c 'grep -E "GRUB_CMDLINE_LINUX|GRUB_TIMEOUT" /etc/default/grub 2>/dev/null'
run config/packages.txt bash -c 'dpkg-query -W -f="${Package} ${Version}\n" "linux-image*" "linux-firmware" "nvidia-driver*" "qemu-system*" "libvirt*" 2>/dev/null'
run logs/syslog-last.txt bash -c 'tail -n 1500 /var/log/syslog /var/log/syslog.1 2>/dev/null'
run logs/kern-last.txt bash -c 'tail -n 1500 /var/log/kern.log /var/log/kern.log.1 2>/dev/null'
# Preserve journal binary metadata and the previous boot's final timestamps in an easy-to-read summary.
{
 echo 'DRIVEIT-SERVER SHUTDOWN INVESTIGATION - AUTOMATED EVIDENCE INDEX'
 echo "Collected: $(date -Is)"
 echo "Hostname: $(hostname)"
 echo "Kernel: $(uname -r)"
 echo "Output: $OUT"
 echo
 echo 'Boot timeline:'
 journalctl --list-boots --no-pager 2>&1
 echo
 echo 'Prior boot last 30 lines:'
 journalctl -b -1 -n 30 --no-pager -o short-iso-precise 2>&1
 echo
 echo 'Current boot first 30 lines:'
 journalctl -b 0 -n 30 --no-pager -o short-iso-precise --reverse 2>&1
 echo
 echo 'Notes: absence of clean shutdown lines may indicate abrupt power loss/hang, but is not definitive.'
 echo 'Read collection.log for failed/unavailable commands; missing tools are not installed by this script.'
} >"$OUT/README-FIRST.txt" 2>&1
ARCHIVE="${OUT%/}.tar.gz"
log "Creating archive $ARCHIVE"
tar -czf "$ARCHIVE" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>>"$LOG" || true
chmod 600 "$ARCHIVE" 2>/dev/null || true
log "DONE. Evidence directory: $OUT"
log "DONE. Archive: $ARCHIVE"
echo "Review $OUT/README-FIRST.txt first."
echo 'CAUTION: archive may contain hostnames, usernames, IPs, serial numbers, and authentication-related log metadata. Review before sharing.'
