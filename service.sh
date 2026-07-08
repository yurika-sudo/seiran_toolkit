#!/system/bin/sh
MODDIR="${0%/*}"
# wait for boot to settle before touching pm/zram
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done
sh "$MODDIR/apply.sh" apply
