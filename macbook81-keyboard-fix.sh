#!/usr/bin/env bash
# MacBook8,1 (12-inch, Early 2015) internal keyboard/trackpad fix, any distro.
#
# The keyboard and trackpad sit on an Intel LPSS SPI bus (applespi driver).
# Two kernel problems make them die:
#  1. If dw_dmac_pci loads before spi_pxa2xx_pci, the SPI controller uses DMA,
#     and on this machine every DMA transfer times out: dead from boot, randomly.
#  2. S3 ("deep") sleep wipes the SPI controller's registers: dead after resume.
#     s2idle keeps the controller powered.
# Fix: kernel args mem_sleep_default=s2idle modprobe.blacklist=dw_dmac_pci,
# plus boot-loader-independent backups of both. Run with --help for usage.

set -euo pipefail
export LC_ALL=C

TAG=macbook81-keyboard-fix
ARGS=(mem_sleep_default=s2idle modprobe.blacklist=dw_dmac_pci)
BUILTIN_ARG=initcall_blacklist=dw_pci_driver_init
LUKS_MODULES=(spi_pxa2xx_platform spi_pxa2xx_pci applespi)
OLD_WORKAROUNDS=(
  /etc/modprobe.d/applespi-delay.conf
  /etc/systemd/system/applespi-recover.service
  /etc/systemd/system-sleep/applespi-resume
  /usr/lib/systemd/system-sleep/applespi-resume-fix
  /usr/local/sbin/applespi-recover
)

# Test hook: MB81_ROOT=<dir> edits files under <dir> and never runs system commands.
R=${MB81_ROOT:-}
F_GRUB=$R/etc/default/grub
F_GRUBD=$R/etc/default/grub.d/90-$TAG.cfg
F_KCMDLINE=$R/etc/kernel/cmdline
F_MODPROBE=$R/etc/modprobe.d/90-$TAG.conf
F_SLEEP=$R/etc/systemd/sleep.conf.d/90-$TAG.conf
F_DRACUT=$R/etc/dracut.conf.d/90-$TAG.conf
F_MKINITCPIO=$R/etc/mkinitcpio.conf.d/90-$TAG.conf
F_ITOOLS=$R/etc/initramfs-tools/modules
BEGIN="# BEGIN $TAG"
END="# END $TAG"

MODE=apply DRY_RUN=0 FORCE=0 FAILS=0 ANY_CHANGE=0
NEED_GRUB=0 NEED_INITRAMFS=0 NEED_KCMDLINE=0

usage() {
  cat <<EOF
Usage: sudo bash ${0##*/} [apply|check|revert] [--dry-run] [--force]

  apply      (default) install the fix; safe to run again
  check      show whether the fix is active (no root needed; sudo shows more)
  revert     remove everything this script added
  --dry-run  show what would change without changing anything
  --force    run on a machine that is not a MacBook8,1

What apply does, using whatever this distro has:
  Kernel args  ${ARGS[*]}
               -> GRUB (Debian/Ubuntu: /etc/default/grub.d drop-in, others:
                  block in /etc/default/grub), grubby boot entries (Fedora),
                  and /etc/kernel/cmdline if it exists.
  modprobe.d   blacklist dw_dmac_pci
  systemd      MemorySleepMode=s2idle (systemd 256 or newer)
  initramfs    keeps dw_dmac_pci out (dracut); with LUKS it adds the keyboard
               drivers so you can type the passphrase. Then rebuilds it.

First boot of a fresh install: if the keyboard is dead, reboot. In the GRUB
menu (hold Esc or Shift if it is hidden) press e, add the two kernel args to
the end of the line starting with "linux", and boot with Ctrl-X or F10.
Then run this script and reboot.
EOF
}

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
show() { printf '%s' "${1#"$R"}"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
bad()  { printf '[FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
note() { printf '[INFO] %s\n' "$*"; }

mark() {
  ANY_CHANGE=1
  if [[ -n ${1:-} ]]; then printf -v "$1" 1; fi
}

run() {
  if (( DRY_RUN )) || [[ -n $R ]]; then say "  would run: $*"; return 0; fi
  say "  running: $*"
  "$@"
}

have() {
  if [[ -n $R ]]; then
    [[ -x $R/usr/bin/$1 || -x $R/usr/sbin/$1 ]]
    return
  fi
  command -v "$1" >/dev/null 2>&1
}

is_debian()  { [[ -f $R/etc/debian_version ]]; }
use_grubby() { have grubby && ! is_debian && [[ -d $R/boot/loader/entries ]]; }

dw_builtin() {
  local f
  f=$R/lib/modules/$(uname -r)/modules.builtin
  [[ -f $f ]] && grep -q '/dw_dmac_pci\.ko$' "$f"
}

has_luks() {
  local line fstypes re='^[[:space:]]*(#|$)'
  if [[ -f $R/etc/crypttab ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ $re ]]; then continue; fi
      return 0
    done <"$R/etc/crypttab"
  fi
  if [[ -z $R ]]; then
    fstypes=$(lsblk -rno FSTYPE 2>/dev/null || true)
    if [[ $fstypes == *crypto_LUKS* ]]; then return 0; fi
  fi
  return 1
}

systemd_version() {
  local v
  if [[ -n $R ]]; then printf '%s' "${MB81_SYSTEMD_VERSION:-0}"; return; fi
  v=$(systemctl --version 2>/dev/null || true)
  v=${v%%$'\n'*}
  v=${v#systemd }
  v=${v%% *}
  if [[ $v =~ ^[0-9]+$ ]]; then printf '%s' "$v"; else printf '0'; fi
}

# put_file PATH CONTENT [FLAG]: write a file this script owns.
put_file() {
  local path=$1 content=$2
  if [[ -f $path && "$(<"$path")" == "$content" ]]; then
    say "  unchanged: $(show "$path")"
    return 0
  fi
  mark "${3:-}"
  if (( DRY_RUN )); then
    say "  would write: $(show "$path")"
    sed 's/^/    | /' <<<"$content"
    return 0
  fi
  mkdir -p "${path%/*}"
  printf '%s\n' "$content" >"$path"
  chmod 644 "$path"
  say "  wrote: $(show "$path")"
}

drop_file() {
  local path=$1
  if [[ ! -e $path ]]; then return 0; fi
  mark "${2:-}"
  if (( DRY_RUN )); then say "  would remove: $(show "$path")"; return 0; fi
  rm -f "$path"
  say "  removed: $(show "$path")"
}

# edit_file PATH NEW_CONTENT [FLAG]: rewrite a file this script doesn't own.
# Keeps one backup of the original next to it.
edit_file() {
  local path=$1 new=$2
  if [[ "$(<"$path")" == "$new" ]]; then
    say "  unchanged: $(show "$path")"
    return 0
  fi
  mark "${3:-}"
  if (( DRY_RUN )); then
    say "  would edit: $(show "$path")"
    diff -u "$path" <(printf '%s\n' "$new") | sed '1,2d; s/^/    /' || true
    return 0
  fi
  if [[ ! -e $path.bak-$TAG ]]; then
    cp -a "$path" "$path.bak-$TAG"
    say "  backup: $(show "$path").bak-$TAG"
  fi
  printf '%s\n' "$new" >"$path"
  say "  edited: $(show "$path")"
}

without_block() {
  awk -v b="$BEGIN" -v e="$END" '$0 == b {s = 1; next} $0 == e {s = 0; next} !s' "$1"
}

set_block() {
  local path=$1 body=$2 base
  base=$(without_block "$path")
  edit_file "$path" "${base:+$base$'\n'}$BEGIN"$'\n'"$body"$'\n'"$END" "${3:-}"
}

unset_block() {
  local path=$1
  if grep -qxF -- "$BEGIN" "$path"; then
    edit_file "$path" "$(without_block "$path")" "${2:-}"
  fi
}

# add_tokens LINE TOKEN... / del_tokens LINE TOKEN...: edit a one-line cmdline.
add_tokens() {
  local line=${1//$'\n'/ } t
  shift
  for t in "$@"; do
    if [[ " $line " != *" $t "* ]]; then line="${line:+$line }$t"; fi
  done
  printf '%s' "$line"
}

del_tokens() {
  local line=" ${1//$'\n'/ } " t
  local -a words
  shift
  for t in "$@"; do
    while [[ $line == *" $t "* ]]; do line=${line/" $t "/ }; done
  done
  read -r -a words <<<"$line" || true
  printf '%s' "${words[*]}"
}

# Sourced by grub-mkconfig with /bin/sh, so it must stay POSIX.
grub_body() {
  cat <<EOF
# MacBook8,1 SPI keyboard fix. Adds each argument unless it is already set.
for _mb81_arg in ${ARGS[*]}; do
  case " \$GRUB_CMDLINE_LINUX \$GRUB_CMDLINE_LINUX_DEFAULT " in
    *" \$_mb81_arg "*) ;;
    *) GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }\$_mb81_arg" ;;
  esac
done
unset _mb81_arg
EOF
}

# bls_state TOKEN...: prints all, none, some or unknown, depending on how many
# BLS boot entries (Fedora) carry every token on their options line.
bls_state() {
  local e line t n=0 full=0 empty=0 hits
  for e in "$R"/boot/loader/entries/*.conf; do
    if [[ ! -r $e ]]; then continue; fi
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line != options[[:space:]]* ]]; then continue; fi
      if [[ $line == *'$kernelopts'* ]]; then printf unknown; return; fi
      n=$((n + 1)) hits=0
      for t in "$@"; do
        if [[ " $line " == *" $t "* ]]; then hits=$((hits + 1)); fi
      done
      if (( hits == $# )); then full=$((full + 1)); fi
      if (( hits == 0 )); then empty=$((empty + 1)); fi
    done <"$e"
  done
  if (( n == 0 )); then printf unknown
  elif (( full == n )); then printf all
  elif (( empty == n )); then printf none
  else printf some; fi
}

regen_grub() {
  if have update-grub; then
    run update-grub
  elif have grub2-mkconfig && [[ -d $R/boot/grub2 ]]; then
    run grub2-mkconfig -o /boot/grub2/grub.cfg
  elif have grub-mkconfig && [[ -d $R/boot/grub ]]; then
    run grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "No grub-mkconfig found; regenerate your GRUB config by hand."
  fi
}

regen_initramfs() {
  if have dracut; then
    run dracut --regenerate-all --force
  elif have update-initramfs; then
    run update-initramfs -u -k all
  elif have mkinitcpio; then
    run mkinitcpio -P
  else
    warn "No initramfs tool found (dracut, update-initramfs, mkinitcpio); the kernel arguments still apply."
  fi
}

finish() {
  local help
  if (( NEED_KCMDLINE )) && [[ ! -f $F_GRUB ]] && ! use_grubby; then
    step "Updating boot entries from /etc/kernel/cmdline"
    help=$(kernel-install --help 2>&1 || true)
    if have kernel-install && [[ $help == *add-all* ]]; then
      run kernel-install add-all
    else
      warn "Regenerate your boot entries so they pick up /etc/kernel/cmdline."
    fi
  fi
  if (( NEED_INITRAMFS )); then step "Rebuilding initramfs"; regen_initramfs; fi
  if (( NEED_GRUB )); then step "Updating GRUB"; regen_grub; fi
}

report_conflicts() {
  local f files=() hits
  for f in "${OLD_WORKAROUNDS[@]}"; do
    if [[ -e $R$f ]]; then
      warn "$f is from an older rebind/delay workaround. It can't fix the root cause and can be removed."
    fi
  done
  for f in "$F_GRUB" "$R"/etc/default/grub.d/*.cfg "$F_KCMDLINE"; do
    if [[ -f $f ]]; then files+=("$f"); fi
  done
  if (( ${#files[@]} )); then
    hits=$(grep -ls -- 'mem_sleep_default=deep' "${files[@]}" || true)
    if [[ -n $hits ]]; then
      warn "mem_sleep_default=deep is set in: ${hits//$'\n'/ }. It overrides s2idle; remove it."
    fi
  fi
}

preflight() {
  local model
  model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if [[ $model != MacBook8,1 ]] && (( !FORCE )); then
    die "This machine is '${model:-unknown}', not a MacBook8,1. Use --force to run anyway."
  fi
  if [[ $MODE != check && -z $R ]] && (( !DRY_RUN && EUID != 0 )); then
    die "Run as root: sudo bash $0 $MODE"
  fi
}

do_apply() {
  local body luks=0 v
  preflight
  if has_luks; then luks=1; fi

  step "Kernel arguments: ${ARGS[*]}"
  if [[ -f $F_GRUB ]]; then
    if is_debian; then
      put_file "$F_GRUBD" "$(grub_body)" NEED_GRUB
    else
      set_block "$F_GRUB" "$(grub_body)" NEED_GRUB
    fi
  fi
  if use_grubby; then
    if [[ $(bls_state "${ARGS[@]}") == all ]]; then
      say "  unchanged: boot entries in /boot/loader/entries"
    else
      mark
      run grubby --update-kernel=ALL --args="${ARGS[*]}"
    fi
  fi
  if [[ -f $F_KCMDLINE ]]; then
    edit_file "$F_KCMDLINE" "$(add_tokens "$(<"$F_KCMDLINE")" "${ARGS[@]}")" NEED_KCMDLINE
  fi
  if [[ ! -f $F_GRUB && ! -f $F_KCMDLINE ]] && ! use_grubby; then
    warn "No GRUB, grubby or /etc/kernel/cmdline found. Add these kernel arguments to your boot loader by hand: ${ARGS[*]}"
  fi

  step "Module blacklist"
  put_file "$F_MODPROBE" "# MacBook8,1 SPI keyboard fix ($TAG).
# If dw_dmac_pci loads before spi_pxa2xx_pci, the SPI bus uses DMA and every transfer times out.
blacklist dw_dmac_pci" NEED_INITRAMFS

  step "Suspend mode"
  v=$(systemd_version)
  if (( v >= 256 )); then
    put_file "$F_SLEEP" "# MacBook8,1: S3 (deep) resets the SPI controller and kills the keyboard ($TAG).
[Sleep]
MemorySleepMode=s2idle"
  elif (( v > 0 )); then
    say "  systemd $v has no MemorySleepMode (needs 256+); the kernel argument covers it."
  else
    say "  systemd not found; the kernel argument covers it."
  fi

  if (( luks )); then step "Initramfs (LUKS found: adding keyboard drivers for the passphrase prompt)"
  else step "Initramfs"; fi
  if have dracut; then
    body="# MacBook8,1 SPI keyboard fix ($TAG).
omit_drivers+=\" dw_dmac_pci \""
    if (( luks )); then body+=$'\n'"add_drivers+=\" ${LUKS_MODULES[*]} \""; fi
    put_file "$F_DRACUT" "$body" NEED_INITRAMFS
  elif have update-initramfs && [[ -f $F_ITOOLS ]]; then
    say "  initramfs-tools copies /etc/modprobe.d into the image"
    if (( luks )); then
      set_block "$F_ITOOLS" "$(printf '%s\n' "${LUKS_MODULES[@]}")" NEED_INITRAMFS
    else
      unset_block "$F_ITOOLS" NEED_INITRAMFS
    fi
  elif have mkinitcpio; then
    say "  mkinitcpio copies /etc/modprobe.d into the image (modconf hook)"
    if (( luks )); then
      put_file "$F_MKINITCPIO" "MODULES+=(${LUKS_MODULES[*]})" NEED_INITRAMFS
    else
      drop_file "$F_MKINITCPIO" NEED_INITRAMFS
    fi
  else
    say "  no initramfs tool found; skipped"
  fi

  report_conflicts
  finish

  if (( !ANY_CHANGE )); then
    say $'\n'"Nothing to change; the fix is already in place."
  elif (( DRY_RUN )); then
    say $'\n'"Dry run: nothing was changed."
  else
    say $'\n'"Done. Reboot, then run:  bash $0 check"
  fi
}

do_revert() {
  local all=("${ARGS[@]}" "$BUILTIN_ARG") rest t
  preflight

  step "Kernel arguments"
  drop_file "$F_GRUBD" NEED_GRUB
  if [[ -f $F_GRUB ]]; then unset_block "$F_GRUB" NEED_GRUB; fi
  if use_grubby; then
    for t in "${all[@]}"; do
      if [[ $(bls_state "$t") != none ]]; then
        mark
        run grubby --update-kernel=ALL --remove-args="$t"
      fi
    done
  fi
  if [[ -f $F_KCMDLINE ]]; then
    edit_file "$F_KCMDLINE" "$(del_tokens "$(<"$F_KCMDLINE")" "${all[@]}")" NEED_KCMDLINE
  fi

  step "Module blacklist, suspend mode, initramfs"
  drop_file "$F_MODPROBE" NEED_INITRAMFS
  drop_file "$F_SLEEP"
  drop_file "$F_DRACUT" NEED_INITRAMFS
  drop_file "$F_MKINITCPIO" NEED_INITRAMFS
  if [[ -f $F_ITOOLS ]]; then unset_block "$F_ITOOLS" NEED_INITRAMFS; fi

  finish

  if [[ -f $F_GRUB ]]; then
    rest=$(without_block "$F_GRUB")
    for t in "${ARGS[@]}"; do
      if [[ $rest == *"$t"* ]]; then
        note "$t is also set directly in /etc/default/grub (not by this script); left as is."
      fi
    done
  fi
  if (( !ANY_CHANGE )); then say $'\n'"Nothing to revert."
  elif (( DRY_RUN )); then say $'\n'"Dry run: nothing was changed."
  else say $'\n'"Reverted. Reboot to go back to the default behaviour."; fi
}

check_next_boot() {
  local e f line t cfg found=0 missing=0 kc

  if use_grubby; then
    case $(bls_state "${ARGS[@]}") in
      all) ok "All boot entries have the kernel arguments" ;;
      unknown) note "Can't read the boot entries in /boot/loader/entries; run with sudo" ;;
      *) bad "Some boot entries lack the kernel arguments (run apply)" ;;
    esac
  else
    for cfg in "$R/boot/grub/grub.cfg" "$R/boot/grub2/grub.cfg"; do
      if [[ -f $cfg ]]; then found=1; break; fi
    done
    if (( !found )); then
      note "No GRUB config found"
    elif [[ ! -r $cfg ]]; then
      note "Can't read $(show "$cfg"); run with sudo to check it"
    else
      for t in "${ARGS[@]}"; do
        if ! grep -qF -- "$t" "$cfg"; then missing=1; fi
      done
      if (( missing )); then bad "$(show "$cfg") lacks the kernel arguments (run apply)"
      else ok "$(show "$cfg") has the kernel arguments"; fi
    fi
  fi

  if [[ -f $F_KCMDLINE ]]; then
    kc=$(<"$F_KCMDLINE")
    missing=0
    for t in "${ARGS[@]}"; do
      if [[ " ${kc//$'\n'/ } " != *" $t "* ]]; then missing=1; fi
    done
    if (( missing )); then bad "/etc/kernel/cmdline lacks the kernel arguments (new kernels won't get them)"
    else ok "/etc/kernel/cmdline has the kernel arguments"; fi
  fi

  for f in "$F_MODPROBE" "$F_SLEEP" "$F_DRACUT" "$F_MKINITCPIO" "$F_GRUBD"; do
    if [[ -f $f ]]; then note "Installed: $(show "$f")"; fi
  done
  if [[ -f $F_GRUB ]] && grep -qxF -- "$BEGIN" "$F_GRUB"; then note "Installed: block in /etc/default/grub"; fi
}

do_check() {
  local model cmdline t ms active klog n params

  model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if [[ $model == MacBook8,1 ]]; then ok "Model: $model"
  else bad "Model: ${model:-unknown} (this fix is for MacBook8,1)"; fi

  say $'\n'"Running system (kernel $(uname -r)):"
  cmdline=$(</proc/cmdline)
  for t in "${ARGS[@]}"; do
    if [[ " $cmdline " == *" $t "* ]]; then ok "Kernel argument $t"
    else bad "Kernel argument $t missing (not applied yet, or no reboot since)"; fi
  done

  ms=$(cat /sys/power/mem_sleep 2>/dev/null || true)
  active=${ms#*[}
  active=${active%%]*}
  if [[ $active == s2idle ]]; then ok "Suspend mode: s2idle"
  else bad "Suspend mode: ${active:-unknown} (should be s2idle)"; fi

  if grep -q '^dw_dmac_pci ' /proc/modules; then bad "dw_dmac_pci is loaded, so the SPI bus may use DMA"
  else ok "dw_dmac_pci not loaded"; fi
  if dw_builtin; then note "dw_dmac_pci is built into this kernel; relying on $BUILTIN_ARG"; fi

  if grep -q 'Name="Apple SPI Keyboard"' /proc/bus/input/devices; then ok "Apple SPI Keyboard present"
  else bad "Apple SPI Keyboard not found"; fi

  klog=$(journalctl -k -b 0 --no-pager -o cat 2>/dev/null || true)
  if [[ -z $klog ]]; then klog=$(dmesg 2>/dev/null || true); fi
  if [[ -z $klog ]]; then
    note "Can't read the kernel log; run with sudo for the SPI checks"
  else
    if [[ $klog == *"using PIO"* ]]; then ok "SPI controller is in PIO mode"
    else note "No 'using PIO' message this boot"; fi
    n=$(grep -c 'SPI transfer timed out' <<<"$klog" || true)
    if (( n == 0 )); then ok "No SPI timeouts this boot"
    else bad "$n SPI timeouts this boot"; fi
    n=$(grep -c 'PM: suspend exit' <<<"$klog" || true)
    note "Suspend/resume cycles this boot: $n"
  fi

  params=$(modinfo -p spi_pxa2xx_pci 2>/dev/null || true)
  if [[ $params == *force_pio* ]]; then
    note "This kernel has the upstream force_pio option; the dw_dmac_pci blacklist may no longer be needed"
  fi

  say $'\n'"Configured for next boot:"
  check_next_boot
  report_conflicts

  if (( FAILS )); then say $'\n'"$FAILS check(s) failed."; return 1; fi
  say $'\n'"All checks passed."
}

for a in "$@"; do
  case $a in
    apply|check|revert) MODE=$a ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if dw_builtin; then ARGS+=("$BUILTIN_ARG"); fi

case $MODE in
  apply) do_apply ;;
  check) do_check ;;
  revert) do_revert ;;
esac
