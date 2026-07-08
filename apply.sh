#!/system/bin/sh
MODDIR="${0%/*}"
CONF="$MODDIR/settings.conf"
DETECTED="$MODDIR/detected.conf"   # written by customize.sh at install, read-only here
GMS_PKGS="com.google.android.gms com.google.android.gsf com.android.vending"
RESTRICT_CHG="/sys/class/qcom-battery/restrict_chg"

ram_tier_default_mb() {
  ram_mb=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024))
  if   [ "$ram_mb" -le 4096 ]; then echo 2048
  elif [ "$ram_mb" -le 6144 ]; then echo 4096
  elif [ "$ram_mb" -le 8192 ]; then echo 6144
  else                              echo 9216
  fi
}

# flat KEY=VAL, one file, one namespace. first-run defaults only
# never overwritten once the file exists, so a fresh install picks a sane
# RAM-tier zram size but a user's later change survives every future boot.
# algo default was hardcoded to lzo, silently downgrading a kernel that
# already shipped lz4 (or anything else) before we ever touched it — detect
# whatever's currently active and preserve it instead of assuming.
_default_algo="$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr ' ' '\n' | grep '\[' | tr -d '[]')"
[ -f "$CONF" ] || cat >"$CONF" <<EOF
zram_enabled=1
zram_size_mb=$(ram_tier_default_mb)
zram_algo=${_default_algo:-lzo}
gms_disabled=0
fastcharge_enabled=1
tcp_cong=westwood
EOF
. "$CONF"
[ -f "$DETECTED" ] && . "$DETECTED"

set_kv() {
  if grep -q "^$1=" "$CONF"; then sed -i "s/^$1=.*/$1=$2/" "$CONF"
  else echo "$1=$2" >>"$CONF"; fi
  eval "$1=\$2" # keep the in-memory copy in sync — file write alone left stale state for the rest of this invocation
}
write() { echo -n "$2" >"$1" 2>/dev/null; }

# zram + swappiness: sole owner, nobody else touches these two
# back to the guard's original approach — zram0 is a static block
# device, never torn down/recreated via hot_add/hot_remove. only resize if the
# current size doesn't match what's wanted, otherwise leave it alone. this is
# what worked reliably; hot_add has a create-on-read race that doesn't.
ZRAM=/dev/block/zram0
zram_current_mb() {
  b="$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)"
  awk -v b="$b" 'BEGIN{printf "%d", b/1048576}'
}
zram_apply() {
  [ -b "$ZRAM" ] || return
  if [ "$zram_enabled" != "1" ]; then
    [ "$(zram_current_mb)" = "0" ] || { swapoff "$ZRAM" 2>/dev/null; write /sys/block/zram0/reset 1; }
    write /proc/sys/vm/swappiness 60
    return
  fi
  # never trust a size of 0/empty/non-numeric from the caller
  # that's not a valid "enabled" state, fall back to the RAM-tier default
  # instead of silently creating a useless 0MB zram.
  case "$zram_size_mb" in
    ''|*[!0-9]*) zram_size_mb="$(ram_tier_default_mb)"; set_kv zram_size_mb "$zram_size_mb" ;;
  esac
  [ "$zram_size_mb" -gt 0 ] || { zram_size_mb="$(ram_tier_default_mb)"; set_kv zram_size_mb "$zram_size_mb"; }
  if [ "$(zram_current_mb)" != "$zram_size_mb" ]; then
    swapoff "$ZRAM" 2>/dev/null
    write /sys/block/zram0/reset 1
    write /sys/block/zram0/comp_algorithm "${zram_algo:-lzo}"
    write /sys/block/zram0/disksize "${zram_size_mb}M"
    mkswap "$ZRAM" >/dev/null 2>&1
    swapon "$ZRAM" 2>/dev/null
  fi
  write /proc/sys/vm/swappiness 100
}
zram_algo_current() {
  # current algo is the one in [brackets], e.g. "lzo [lz4] zstd"
  cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr ' ' '\n' | grep '\[' | tr -d '[]'
}
set_zram_algo() {
  # changing algo needs a reset regardless of size match, so force it here
  set_kv zram_algo "$1"
  [ "$zram_enabled" = "1" ] || return
  swapoff "$ZRAM" 2>/dev/null
  write /sys/block/zram0/reset 1
  write /sys/block/zram0/comp_algorithm "$1"
  write /sys/block/zram0/disksize "${zram_size_mb}M"
  mkswap "$ZRAM" >/dev/null 2>&1
  swapon "$ZRAM" 2>/dev/null
}

# gms
# pm calls run in parallel — sequential was 3x slower for no reason.
# stderr no longer swallowed: a manual termux run now shows real pm errors.
gms_freeze()   { for p in $GMS_PKGS; do pm disable-user --user 0 "$p" >/dev/null & done; wait; }
gms_unfreeze() { for p in $GMS_PKGS; do pm enable       --user 0 "$p" >/dev/null & done; wait; }
# settings.conf only records intent, updated instantly on toggle
# it does NOT mean the pm call finished. gms disable/enable on a heavy
# package can take real seconds on Android's side. check actual package
# state instead of trusting the saved setting, so the UI can't lie about
# whether it's actually done.
gms_actual_disabled() { pm list packages -d 2>/dev/null | grep -q "com.google.android.gms" && echo 1 || echo 0; }

# fastcharge
# direction flipped per device-verified correction — on THIS
# hardware, writing 1 to restrict_chg is what actually disables fast charge,
# not 0. checkbox meaning (1=fast charge on) stays the same, only the sysfs
# write direction changed.
fastcharge_apply() {
  [ -f "$RESTRICT_CHG" ] || return
  chmod 644 "$RESTRICT_CHG" 2>/dev/null
  [ "$fastcharge_enabled" = "1" ] && write "$RESTRICT_CHG" 1 || write "$RESTRICT_CHG" 0
}

# sysctl guard: unique keys only, does NOT touch swappiness/zram
sysctl_apply() {
  write /proc/sys/vm/vfs_cache_pressure 100
  write /proc/sys/vm/watermark_scale_factor 30
  write /proc/sys/vm/page-cluster 0
  write /proc/sys/vm/dirty_background_ratio 10
  write /proc/sys/vm/dirty_ratio 20
  write /proc/sys/vm/stat_interval 10
  write /proc/sys/net/ipv4/tcp_congestion_control "$tcp_cong"
}
set_tcp() { set_kv tcp_cong "$1"; write /proc/sys/net/ipv4/tcp_congestion_control "$1"; }

# generic sysfs paths, not yet confirmed against your actual device output.
# same rule as kernel patch context — verify before trusting, swap the path string
# below if your termux probe shows something different.
GPU_GOV="/sys/class/kgsl/kgsl-3d0/devfreq/governor"
GPU_MINFREQ="/sys/class/kgsl/kgsl-3d0/devfreq/min_freq"
GPU_MAXFREQ="/sys/class/kgsl/kgsl-3d0/devfreq/max_freq"

# iterate policy* dirs, not cpuN — a "cluster" is a shared cpufreq
# policy. auto-detects however many clusters a device has, no hardcoded 4+4.
cpu_policy_path() {
  i=0
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ "$i" = "$1" ] && { echo "$p"; return; }
    i=$((i + 1))
  done
}
set_cpu_gov() {     # $1=cluster index (0,1,...) $2=governor
  p="$(cpu_policy_path "$1")"; [ -n "$p" ] || return
  set_kv "cpu${1}_gov" "$2"; write "$p/scaling_governor" "$2"
}
set_cpu_minfreq() { # $1=cluster index $2=khz
  p="$(cpu_policy_path "$1")"; [ -n "$p" ] || return
  set_kv "cpu${1}_minfreq" "$2"; write "$p/scaling_min_freq" "$2"
}
set_cpu_maxfreq() { # $1=cluster index $2=khz
  p="$(cpu_policy_path "$1")"; [ -n "$p" ] || return
  set_kv "cpu${1}_maxfreq" "$2"; write "$p/scaling_max_freq" "$2"
}
set_gpu_gov()     { set_kv gpu_gov "$1";     write "$GPU_GOV" "$1"; }
set_gpu_minfreq() { set_kv gpu_minfreq "$1"; write "$GPU_MINFREQ" "$1"; }
set_gpu_maxfreq() { set_kv gpu_maxfreq "$1"; write "$GPU_MAXFREQ" "$1"; }

# core online/offline
core_count() { i=0; while [ -e "/sys/devices/system/cpu/cpu$i" ]; do i=$((i + 1)); done; echo "$i"; }
set_core() { # $1=core idx $2=0|1
  if [ "$1" = "0" ] && [ "$2" = "0" ]; then echo "refused: cpu0 cannot be offlined"; return 1; fi
  n="$(core_count)"
  # refuse leaving a whole cluster with zero online cores instead of
  # silently hanging the device — cluster boundary = every 4 cores on bengal,
  # good enough heuristic without reading related_cpus for this guard.
  if [ "$2" = "0" ]; then
    cluster_start=$(( (($1 / 4)) * 4 ))
    online_left=0
    j=$cluster_start
    while [ "$j" -lt $((cluster_start + 4)) ] && [ "$j" -lt "$n" ]; do
      [ "$j" != "$1" ] && [ "$(cat /sys/devices/system/cpu/cpu$j/online 2>/dev/null || echo 1)" = "1" ] && online_left=$((online_left + 1))
      j=$((j + 1))
    done
    [ "$online_left" -eq 0 ] && { echo "refused: would leave a cluster fully offline"; return 1; }
  fi
  [ -w "/sys/devices/system/cpu/cpu$1/online" ] || return 1
  set_kv "core${1}_online" "$2"
  write "/sys/devices/system/cpu/cpu$1/online" "$2"
}

batt_node() {
  for p in "/sys/class/power_supply/battery/$1" "/sys/class/power_supply/bms/$1"; do
    [ -f "$p" ] && { cat "$p" 2>/dev/null; return; }
  done
}

status() {
  cap="$(batt_node capacity)"
  volt_uv="$(batt_node voltage_now)"
  cur_ua="$(batt_node current_now)"
  cycles="$(batt_node cycle_count)"
  volt_mv="$(awk -v v="${volt_uv:-0}" 'BEGIN{printf "%d", v/1000}')"
  cur_ma="$(awk -v v="${cur_ua:-0}" 'BEGIN{printf "%d", v/1000}')"
  echo "zram_enabled=$zram_enabled"
  echo "zram_size_mb=$zram_size_mb"
  echo "zram_active_mb=$(zram_current_mb)"
  echo "zram_algo=${zram_algo:-lzo}"
  echo "zram_algo_current=$(zram_algo_current)"
  echo "zram_algo_available=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]')"
  echo "gms_disabled=$gms_disabled"
  echo "gms_disabled_actual=$(gms_actual_disabled)"
  echo "fastcharge_enabled=$fastcharge_enabled"
  echo "fastcharge_supported=$([ -f "$RESTRICT_CHG" ] && echo 1 || echo 0)"
  echo "tcp_cong=$tcp_cong"
  echo "tcp_current=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  echo "tcp_available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  echo "cpu_clusters=$(i=0; while [ -n "$(cpu_policy_path "$i")" ]; do i=$((i+1)); done; echo "$i")"
  i=0
  while p="$(cpu_policy_path "$i")" && [ -n "$p" ]; do
    echo "cpu${i}_gov_current=$(cat "$p/scaling_governor" 2>/dev/null)"
    echo "cpu${i}_gov_available=$(cat "$p/scaling_available_governors" 2>/dev/null)"
    echo "cpu${i}_minfreq_current=$(cat "$p/scaling_min_freq" 2>/dev/null)"
    echo "cpu${i}_maxfreq_current=$(cat "$p/scaling_max_freq" 2>/dev/null)"
    echo "cpu${i}_freqs_available=$(cat "$p/scaling_available_frequencies" 2>/dev/null)"
    i=$((i + 1))
  done
  echo "gpu_gov_current=$(cat "$GPU_GOV" 2>/dev/null)"
  echo "gpu_gov_available=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/available_governors 2>/dev/null)"
  echo "gpu_minfreq_current=$(cat "$GPU_MINFREQ" 2>/dev/null)"
  echo "gpu_maxfreq_current=$(cat "$GPU_MAXFREQ" 2>/dev/null)"
  echo "gpu_freqs_available=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies 2>/dev/null)"
  n="$(core_count)"; i=0
  while [ "$i" -lt "$n" ]; do
    echo "core${i}_online=$(cat /sys/devices/system/cpu/cpu$i/online 2>/dev/null || echo 1)"
    i=$((i + 1))
  done
  temp="$(batt_node temp)"
  echo "battery_temp_c=$(awk -v t="${temp:-0}" 'BEGIN{printf "%.1f", t/10}')"
  echo "battery_power_w=$(awk -v v="${volt_mv:-0}" -v c="${cur_ma:-0}" 'BEGIN{printf "%.2f", (v*c)/1000000}')"
  echo "battery_capacity=${cap:-NA}"
  echo "battery_voltage_mv=${volt_mv:-NA}"
  echo "battery_current_ma=${cur_ma:-NA}"
  echo "battery_cycles=${cycles:-NA}"
}

# status() carries *_available lists too — the webui needs those
# to populate dropdowns. summary() is the human-quick-check view: current
# values only, no duplicate saved-vs-live pairs, no option lists.
summary() {
  echo "zram: $([ "$zram_enabled" = "1" ] && echo on || echo off), ${zram_size_mb}M set / $(zram_current_mb)M active, algo=$(zram_algo_current)"
  echo "gms_disabled=$gms_disabled"
  echo "fastcharge_enabled=$fastcharge_enabled (supported=$([ -f "$RESTRICT_CHG" ] && echo 1 || echo 0))"
  echo "tcp=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  i=0
  while p="$(cpu_policy_path "$i")" && [ -n "$p" ]; do
    echo "cluster$i: $(cat "$p/scaling_governor" 2>/dev/null) $(cat "$p/scaling_min_freq" 2>/dev/null)-$(cat "$p/scaling_max_freq" 2>/dev/null)"
    i=$((i + 1))
  done
  echo "gpu: $(cat "$GPU_GOV" 2>/dev/null) $(cat "$GPU_MINFREQ" 2>/dev/null)-$(cat "$GPU_MAXFREQ" 2>/dev/null)"
  n="$(core_count)"; i=0; off=""
  while [ "$i" -lt "$n" ]; do
    [ "$(cat /sys/devices/system/cpu/cpu$i/online 2>/dev/null || echo 1)" = "0" ] && off="$off $i"
    i=$((i + 1))
  done
  echo "cores offline:${off:- none}"
  cap="$(batt_node capacity)"; cur_ua="$(batt_node current_now)"; temp="$(batt_node temp)"
  echo "battery: ${cap:-NA}% $(awk -v v="${cur_ua:-0}" 'BEGIN{printf "%d", v/1000}')mA $(awk -v t="${temp:-0}" 'BEGIN{printf "%.1f", t/10}')°C"
}

# customize.sh writes detected.conf with detected_zram=1/0, detected_battery=1/0, etc.
detect() { [ -f "$DETECTED" ] && cat "$DETECTED" || echo "detected=missing_run_install_again"; }

# this IS the debug dump — kept separate from status() on purpose so
# switching action.sh from debug->status later is a one-line change, not a rewrite.
debug() {
  echo "== settings.conf =="; cat "$CONF" 2>/dev/null
  echo "== detected.conf =="; cat "$DETECTED" 2>/dev/null
  echo "== status =="; status
  echo "== /proc/swaps =="; cat /proc/swaps 2>/dev/null
  echo "== zram devices =="; ls /sys/block/ 2>/dev/null | grep zram
}

# "back to stock" for cpu governor/tcp isn't knowable — we never
# recorded what the ROM shipped with, so we don't invent a number. nuke wipes
# the config (nothing gets re-forced from next boot) and live-reverts only the
# things with an unambiguous off-state: zram, gms, fastcharge, core online.
nuke() {
  rm -f "$CONF"
  swapoff "$ZRAM" 2>/dev/null
  write /sys/block/zram0/reset 1
  write /proc/sys/vm/swappiness 60
  gms_unfreeze
  [ -f "$RESTRICT_CHG" ] && write "$RESTRICT_CHG" 1
  n="$(core_count)"; i=1
  while [ "$i" -lt "$n" ]; do write "/sys/devices/system/cpu/cpu$i/online" 1; i=$((i + 1)); done
  echo "nuked: zram off, gms unfrozen, fastcharge on, all cores online, config wiped."
  echo "cpu governor/minfreq/tcp left as they currently are — no known stock value, but their keys are gone so nothing re-forces them from next boot."
  echo "add \$MODDIR/disable if you also want the module fully off at next boot."
}

apply() {
  [ "${detected_zram:-1}" = "1" ] && zram_apply
  if [ "$gms_disabled" = "1" ]; then gms_freeze; else gms_unfreeze; fi
  [ "${detected_fastcharge:-1}" = "1" ] && fastcharge_apply
  sysctl_apply
  i=0
  while [ -n "$(cpu_policy_path "$i")" ]; do
    eval "gov=\$cpu${i}_gov"; eval "mf=\$cpu${i}_minfreq"; eval "xf=\$cpu${i}_maxfreq"
    [ -n "$gov" ] && set_cpu_gov "$i" "$gov" >/dev/null 2>&1
    [ -n "$mf" ] && set_cpu_minfreq "$i" "$mf" >/dev/null 2>&1
    [ -n "$xf" ] && set_cpu_maxfreq "$i" "$xf" >/dev/null 2>&1
    i=$((i + 1))
  done
  [ -n "$gpu_gov" ] && set_gpu_gov "$gpu_gov" >/dev/null 2>&1
  [ -n "$gpu_minfreq" ] && set_gpu_minfreq "$gpu_minfreq" >/dev/null 2>&1
  [ -n "$gpu_maxfreq" ] && set_gpu_maxfreq "$gpu_maxfreq" >/dev/null 2>&1
  # core online is intentionally NOT reapplied at boot — always
  # comes back all-on. safety net requested explicitly: an offline cluster
  # should never survive a reboot regardless of what was live before.
}

case "$1" in
  apply) apply ;;
  status) status ;;
  detect) detect ;;
  set-zram) set_kv zram_enabled "$2"; set_kv zram_size_mb "${3:-$zram_size_mb}"; zram_apply ;;
  set-gms) set_kv gms_disabled "$2"; if [ "$2" = "1" ]; then gms_freeze; else gms_unfreeze; fi ;;
  set-fastcharge) set_kv fastcharge_enabled "$2"; fastcharge_apply ;;
  set-tcp) set_tcp "$2" ;;
  set-zram-algo) set_zram_algo "$2" ;;
  set-cpu-gov) set_cpu_gov "$2" "$3" ;;
  set-cpu-minfreq) set_cpu_minfreq "$2" "$3" ;;
  set-cpu-maxfreq) set_cpu_maxfreq "$2" "$3" ;;
  set-gpu-gov) set_gpu_gov "$2" ;;
  set-gpu-minfreq) set_gpu_minfreq "$2" ;;
  set-gpu-maxfreq) set_gpu_maxfreq "$2" ;;
  set-core) set_core "$2" "$3" ;;
  debug) debug ;;
  summary) summary ;;
  nuke) nuke ;;
  *) echo "usage: apply.sh {apply|status|debug|summary|detect|nuke|set-zram <0|1> [mb]|set-zram-algo <algo>|set-gms <0|1>|set-fastcharge <0|1>|set-tcp <algo>|set-cpu-gov <cluster> <gov>|set-cpu-minfreq <cluster> <khz>|set-cpu-maxfreq <cluster> <khz>|set-gpu-gov <gov>|set-gpu-minfreq <khz>|set-gpu-maxfreq <khz>|set-core <n> <0|1>}" ;;
esac
