#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/tango_service.log
exec >>"$LOG" 2>&1
echo "===== $(date) service.sh ====="

# 等待系统起来
for i in $(seq 1 30); do
  [ "$(getprop sys.boot_completed)" = "1" ] && break
  sleep 2
done
sleep 3

# --- 1) statsd APEX 补 32 位 lib ---
A=/apex/com.android.os.statsd
D=/data/tango/statsd_apex
if [ -d "$A" ] && [ ! -d "$A/lib" ]; then
  rm -rf $D; mkdir -p $D
  cp -a $A/. $D/ 2>/dev/null
  rm -rf $D/lost+found 2>/dev/null
  mkdir -p $D/lib
  for f in libstats_jni.so libstatssocket.so libstatspull.so; do
    [ -f /system/lib/$f ] && cp -f /system/lib/$f $D/lib/
  done
  chmod 644 $D/lib/*.so 2>/dev/null
  chown system:system $D/lib/*.so 2>/dev/null
  chcon -R u:object_r:system_file:s0 $D 2>/dev/null
  mount --bind $D $A && echo "  statsd APEX ok" || echo "  statsd APEX FAILED"
fi

# --- 2) tethering APEX 补 32 位 lib ---
sh /data/local/tmp/apex_overlay.sh com.android.tethering /data/local/tmp/thlib2 >/dev/null 2>&1
if [ -f /system/lib/libnativehelper.so ]; then
  cp -f /system/lib/libnativehelper.so /dev/ov_com.android.tethering/lib/ 2>/dev/null
  chcon u:object_r:system_file:s0 /dev/ov_com.android.tethering/lib/libnativehelper.so 2>/dev/null
fi
echo "  tethering lib: $(ls /apex/com.android.tethering/lib/ 2>/dev/null | wc -l)"

# --- 3) 渲染器 ---
setprop debug.hwui.renderer opengl

# --- 4) binfmt_misc ---
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
if [ -f /proc/sys/fs/binfmt_misc/register ] && [ ! -f /proc/sys/fs/binfmt_misc/arm ]; then
  echo ':arm:M::\x7fELF\x01\x01\x01:\xff\xff\xff\xff\xff\xff\xff:/system/bin/tango_translator:POCF' > /proc/sys/fs/binfmt_misc/register 2>/dev/null
fi
echo "  binfmt: $(head -1 /proc/sys/fs/binfmt_misc/arm 2>/dev/null)"

# --- 5) 启动 32 位 zygote ---
setenforce 0
stop zygote_tango 2>/dev/null
sleep 1
start zygote_tango
sleep 8
echo "  zygote_tango = $(getprop init.svc.zygote_tango)"

# --- 6) 健康检查 ---
P=$(ps -A 2>/dev/null | grep ' zygote$' | awk '{print $2}' | head -1)
if [ -n "$P" ]; then
  echo "  ✓ zygote pid=$P"
  setenforce 1
  echo "  ✓ 已恢复 Enforcing"
else
  echo "  ✗ zygote 未启动"
fi
echo "===== done ====="
