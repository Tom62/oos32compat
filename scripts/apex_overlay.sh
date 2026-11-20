#!/system/bin/sh
# Generic helper: build+verify+mount an overlay for an APEX that lacks 32-bit lib/.
# Usage: apex_overlay.sh <apex_name> <src_lib_dir>
APEX_NAME=$1
SRC_LIB=$2
SRC=/apex/$APEX_NAME
DST=/dev/ov_$APEX_NAME

echo "=== $APEX_NAME ==="
if [ -z "$APEX_NAME" ] || [ -z "$SRC_LIB" ]; then echo "usage: $0 <apex> <srclib>"; exit 1; fi
if mount | grep -q "$DST"; then echo "  已挂载，跳过"; exit 0; fi

rm -rf $DST
mkdir -p $DST
cp -a $SRC/. $DST/ 2>/dev/null
echo "  copied files: $(find $DST -type f | wc -l)"

mkdir -p $DST/lib
n=0
for f in $SRC_LIB/*.so; do
  [ -f "$f" ] || continue
  cp -f "$f" $DST/lib/
  n=$((n+1))
done
echo "  lib/ : $n 个"

chcon u:object_r:system_file:s0 $DST
for d in bin etc javalib lib64 priv-app; do
  [ -d $SRC/$d ] && chcon "$(ls -Zd $SRC/$d | awk '{print $1}')" $DST/$d 2>/dev/null
done
chcon u:object_r:system_file:s0 $DST/lib
for f in $DST/lib/*; do chcon u:object_r:system_file:s0 "$f"; done
find $DST -mindepth 1 -maxdepth 3 2>/dev/null | while read f; do
  rel=${f#$DST/}
  [ -e "$SRC/$rel" ] && chcon -h "$(ls -Zd $SRC/$rel | awk '{print $1}')" "$f" 2>/dev/null
done

echo "  校验:"
find $SRC -type f 2>/dev/null | while read f; do
  rel=${f#$SRC/}
  A=$(stat -c %s "$f"); B=$(stat -c %s "$DST/$rel" 2>/dev/null)
  [ "$A" != "$B" ] && echo "    MISMATCH $rel"
done
echo "    (无输出=一致)"

mount --bind $DST $SRC
echo "  mount rc=$?"
echo "  lib 数量: $(ls $SRC/lib 2>/dev/null | wc -l)"
/system/bin/sh -c 'echo SPAWN_OK'
