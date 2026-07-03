#!/system/bin/sh
# runs at late_start service — after rom init.rc has already written its
# own values, so calling apply.sh here always wins.
MODDIR=${0%/*}
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
sleep 5   # buffer — some rom still poke sysctl a few seconds after boot_completed
sh "$MODDIR/apply.sh" boot
log -t seiran_sysctl_guard "applied boot defaults + persisted overrides"
