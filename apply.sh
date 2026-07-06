#!/system/bin/sh
MODDIR=${0%/*}
CONF="$MODDIR/user_config"
[ -f "$CONF" ] && . "$CONF"

write() { [ -w "$1" ] && echo "$2" > "$1"; }

apply_defaults() {
  write /proc/sys/vm/swappiness 100
  write /proc/sys/vm/vfs_cache_pressure 100
  write /proc/sys/vm/watermark_scale_factor 30
  write /proc/sys/vm/page-cluster 0
  write /proc/sys/vm/dirty_background_ratio 10
  write /proc/sys/vm/dirty_ratio 20
  write /proc/sys/vm/stat_interval 10
}

apply_zram() {
  RAM_MB=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024))
  if   [ "$RAM_MB" -le 4096 ]; then DISKSIZE=2048
  elif [ "$RAM_MB" -le 6144 ]; then DISKSIZE=4096
  elif [ "$RAM_MB" -le 8192 ]; then DISKSIZE=6144
  else                              DISKSIZE=9216
  fi
  ZRAM=/dev/block/zram0
  [ -b "$ZRAM" ] || return
  CURRENT=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
  WANT=$((DISKSIZE * 1024 * 1024))
  if [ "$CURRENT" != "$WANT" ]; then
    swapoff "$ZRAM" 2>/dev/null
    echo 1 > /sys/block/zram0/reset
    echo "${DISKSIZE}M" > /sys/block/zram0/disksize
    mkswap "$ZRAM" > /dev/null 2>&1
    swapon "$ZRAM" 2>/dev/null
  fi
}

apply_tcp() { write /proc/sys/net/ipv4/tcp_congestion_control "${TCP_CONG:-westwood}"; }

set_tcp() {
  grep -v '^TCP_CONG=' "$CONF" 2>/dev/null > "$CONF.tmp"
  echo "TCP_CONG=$1" >> "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
  write /proc/sys/net/ipv4/tcp_congestion_control "$1"
}

# note: "applied" just means live values match what boot() would have written;
# good enough signal for the UI, no need for a real diff engine.
status() {
  local swap vfs wsf tcp_cur applied=1
  swap=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  vfs=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
  wsf=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)
  tcp_cur=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)

  [ "$swap" = "100" ] || applied=0
  [ "$vfs" = "100" ] || applied=0
  [ "$wsf" = "30" ] || applied=0
  [ "$tcp_cur" = "${TCP_CONG:-westwood}" ] || applied=0

  echo "ram_mb=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024))"
  echo "zram_disksize_mb=$(($(cat /sys/block/zram0/disksize 2>/dev/null || echo 0) / 1024 / 1024))"
  echo "swappiness=$swap"
  echo "vfs_cache_pressure=$vfs"
  echo "watermark_scale_factor=$wsf"
  echo "tcp_current=$tcp_cur"
  echo "tcp_available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  echo "tcp_wanted=${TCP_CONG:-westwood}"
  echo "guard_applied=$applied"
}

case "$1" in
  boot)   apply_defaults; apply_zram; apply_tcp ;;
  tcp)    set_tcp "$2" ;;
  status) status ;;
esac
