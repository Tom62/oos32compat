#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/tango32_module.log
exec >>"$LOG" 2>&1
echo "===== $(date) post-fs-data ====="

# 1) 声明 32 位 ABI（必须在 system_server 启动前）
#    注意：public.libraries.txt 里的条目必须带 ABI 标记，否则 64 位 zygote 会崩
resetprop -n ro.product.cpu.abilist           "arm64-v8a,armeabi-v7a,armeabi"
resetprop -n ro.product.cpu.abilist32         "armeabi-v7a,armeabi"
resetprop -n ro.system.product.cpu.abilist    "arm64-v8a,armeabi-v7a,armeabi"
resetprop -n ro.system.product.cpu.abilist32  "armeabi-v7a,armeabi"
resetprop -n ro.vendor.product.cpu.abilist    "arm64-v8a,armeabi-v7a,armeabi"
resetprop -n ro.vendor.product.cpu.abilist32  "armeabi-v7a,armeabi"
echo "  abilist = $(getprop ro.product.cpu.abilist)"

# 2) OPPO 的 32 位支持开关
resetprop -n ro.sys.oplus_support_app32_version 2
resetprop -n persist.sys.tango_zygote32.start 0
resetprop -n sys.tango_target_installed 0

# 3) Tango 缓存目录
mkdir -p /data/tango/log /data/tango/pretrans_log
chmod 0777 /data/tango/log /data/tango/pretrans_log

echo "===== done ====="
