# Seiran Sysctl Guard

Companion enforcement module for [Seiran Kernel](https://github.com/superuseryu/kernel_sapphire_SM6225).

Seiran Kernel patches several `vm.*` and scheduler defaults directly at the
source level. However, some ROM `init.rc` scripts and vendor `perf-hal`
configs write competing sysctl values *after* the kernel has already booted,
silently overriding the intended defaults.

Confirmed real-world case: `init.qti.kernel.rc` writes `vm.swappiness = 180`
on some ROMs, overriding the kernel's built-in `100`. A source patch alone
can't win this fight — something has to write *after* the ROM does.

This module runs at `late_start service` (after ROM init has already run,
plus a buffer for late vendor writes) and re-asserts the kernel's intended
values, so they win regardless of ROM strictness.

## What it enforces

- `vm.swappiness`, `vm.vfs_cache_pressure`, `vm.watermark_scale_factor`
- `vm.dirty_background_ratio`, `vm.dirty_ratio`, `vm.page-cluster`, `vm.stat_interval`
- `memory.swappiness` cgroup (background group)
- ZRAM disksize, auto-tiered by detected RAM (2G/4G/6G/9G buckets)

## Why not just patch the kernel source?

Most of the above **is** patched at the source level in Seiran Kernel.
This module exists specifically for the subset that gets overwritten by
userspace init scripts after boot — a kernel patch alone isn't enough for
those, since userspace always runs after kernel init.

## Install

Flash via Magisk or KernelSU-Next → reboot. No configuration needed.
