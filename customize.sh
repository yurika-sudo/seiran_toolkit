#!/system/bin/sh
ui_print "Seiran Sysctl Guard v0.2.0"
ui_print "device : $(getprop ro.product.device)"
ui_print "kernel : $(uname -r)"
set_perm_recursive "$MODPATH" root root 0755 0644
set_perm "$MODPATH/service.sh" root root 0755
set_perm "$MODPATH/apply.sh"   root root 0755
set_perm "$MODPATH/action.sh"  root root 0755
ui_print "reboot to apply. open WebUI in KSU Manager to configure TCP."
