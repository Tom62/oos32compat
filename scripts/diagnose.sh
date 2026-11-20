#!/system/bin/sh
echo "=== 1) 基本状态 ==="
getprop sys.boot_completed
cat /proc/uptime | awk '{print "  uptime: "$1" 秒"}'
echo "  abilist = $(getprop ro.product.cpu.abilist)"

echo ""
echo "=== 2) 模块状态 ==="
ls /data/adb/modules/tango32_cph2723/disable 2>/dev/null && echo "  ✗ 模块被禁用" || echo "  ✓ 模块启用"
echo "  system/lib: $(ls /data/adb/modules/tango32_cph2723/system/lib/*.so 2>/dev/null | wc -l) 个"
echo "  system/vendor/lib: $(ls /data/adb/modules/tango32_cph2723/system/vendor/lib/ 2>/dev/null | wc -l) 个"
echo "  system/vendor/lib/egl: $(ls /data/adb/modules/tango32_cph2723/system/vendor/lib/egl/ 2>/dev/null | wc -l) 个"
echo "  system/vendor/lib/hw: $(ls /data/adb/modules/tango32_cph2723/system/vendor/lib/hw/ 2>/dev/null | wc -l) 个"

echo ""
echo "=== 3) 运行时状态 ==="
echo "  zygote_tango = $(getprop init.svc.zygote_tango)"
echo "  /vendor/lib/egl: $(ls /vendor/lib/egl/ 2>/dev/null | wc -l) 个"
echo "  /vendor/lib: $(ls /vendor/lib/ 2>/dev/null | wc -l) 个"
echo "  APEX statsd lib: $(ls /apex/com.android.os.statsd/lib/ 2>/dev/null | wc -l) 个"
echo "  tethering lib: $(ls /apex/com.android.tethering/lib/ 2>/dev/null | wc -l) 个"

echo ""
echo "=== 4) 应用状态 ==="
dumpsys package com.laisi.magent.player 2>/dev/null | grep -iE 'primaryCpuAbi' | head -1
ps -A 2>/dev/null | grep -c laisi

echo ""
echo "=== 5) 字体情况 ==="
ls /system/fonts/ 2>/dev/null | grep -iE 'cjk|noto.*sc|droidsansfallback' | head -5
echo "  字体文件总数: $(ls /system/fonts/ 2>/dev/null | wc -l)"
