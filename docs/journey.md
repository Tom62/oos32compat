# 完整踩坑记录

从"完全装不上"到"完整可用"的八道关卡。按时间顺序，含失败的尝试。

---

## 背景

**设备**：一加 13S（CPH2723），Snapdragon 8 Elite（`sun` / SM8750），ColorOS 16 / Android 16

**目标**：运行一个 32 位（`armeabi-v7a`）的磁力下载应用

**前提发现**：设备固件里已有 `tango_translator`、`/dev/tango32` 内核模块、`zygote_tango` init 服务定义，
以及 `ro.vendor.oplus.tango_allow32=true` —— 厂商支持这条路，只是出厂没启用。

---

## 关卡 1：装不上

```
INSTALL_FAILED_NO_MATCHING_ABIS
```

**原因**：`ro.product.cpu.abilist` 没有 `armeabi-v7a`，`PackageManager` 直接拒绝。

**关键细节**：不能只改一个属性，需要 **6 个**，而且**必须在 system_server 启动之前**设置：

```sh
resetprop -n ro.product.cpu.abilist           "arm64-v8a,armeabi-v7a,armeabi"
resetprop -n ro.product.cpu.abilist32         "armeabi-v7a,armeabi"
resetprop -n ro.system.product.cpu.abilist    "arm64-v8a,armeabi-v7a,armeabi"
resetprop -n ro.system.product.cpu.abilist32  "armeabi-v7a,armeabi"
resetprop -n ro.vendor.product.cpu.abilist    "arm64-v8a,armeabi-v7a,armeabi"
resetprop -n ro.vendor.product.cpu.abilist32  "armeabi-v7a,armeabi"
```

**失败尝试**：运行时设置 + `setprop ctl.restart zygote`。
能装上，但重启后失效，且 zygote 热重启有副作用（见关卡 7）。

**最终方案**：写进 `post-fs-data.sh`（在 zygote 之前执行）。

**踩过的坑**：早期版本在 `post-fs-data.sh` 里加 ABI 属性导致**死循环**。
真因不是 ABI，而是同时给 `public.libraries.txt` 加了**没有 ABI 标记**的条目（见关卡 2）。

---

## 关卡 2：libstats_jni.so

```
java.lang.UnsatisfiedLinkError: dlopen failed: library "libstats_jni.so" not found
```

**根因分析**：`StatsLog` 类来自 **statsd APEX 的 jar**（`/apex/com.android.os.statsd/javalib/framework-statsd.jar`），
所以 `System.loadLibrary` 走的是 **APEX 命名空间**，搜索路径是 `/apex/com.android.os.statsd/lib`（32 位）——
**而该目录在纯 64 位设备上不存在**（APEX 里只有 `lib64/`）。

**解法**：复制整个 APEX 到可写位置，补一个 32 位 `lib/`，再 bind mount 回去。

```sh
cp -a /apex/com.android.os.statsd /data/tango/statsd_apex
mkdir -p /data/tango/statsd_apex/lib
cp /system/lib/libstats_jni.so /system/lib/libstatssocket.so /system/lib/libstatspull.so \
   /data/tango/statsd_apex/lib/
chcon -R u:object_r:system_file:s0 /data/tango/statsd_apex
mount --bind /data/tango/statsd_apex /apex/com.android.os.statsd
```

**⚠️ 差点砖的坑**：往 `/system/etc/public.libraries.txt` 加条目时：

```
libstats_jni.so          ← 错误！64 位 zygote 预加载时会崩，无限重启
libstats_jni.so 32 nopreload    ← 正确，必须带 ABI 标记
```

tombstone 证据：
```
Cmdline: zygote64
signal 6 (SIGABRT)
Abort message: 'Error preloading public library libstats_jni.so: dlopen failed'
```

**恢复方法**：Magisk 的 bootloop 保护会把所有模块打上 `disable` 标记，
`rm -f /data/adb/modules/*/disable` 后重启即可。`su` 可能不在 PATH，用 `/debug_ramdisk/su`。

---

## 关卡 3：libframework-connectivity-jni.so

同样的 APEX 问题，这次是 tethering APEX。

**需要补 4 个库**（漏一个就报下一个）：

```sh
apex_overlay.sh com.android.tethering /path/to/libs
#  libframework-connectivity-jni.so
#  libframework-connectivity-tiramisu-jni.so
#  libandroid_net.so
#  libnativehelper.so        ← 最容易漏
```

---

## 关卡 4：32 位 GPU 驱动

```
F app_process32: at ZygoteInit.nativePreloadGraphicsDriver
```

zygote 预加载图形驱动时 abort —— 设备上根本没有 32 位 EGL 驱动。

**物料来源**：一加 13T（PKX110）ColorOS 全量 OTA。

**关键验证**：13T 固件的 build.prop 里 `ro.board.platform=sun`，
与 13S **完全相同** —— 同平台，驱动才可能通用。

> 曾有人（包括 AI 助手）判断"13T 是 canoe/Gen5 平台，驱动不匹配"。
> 实测 `ro.board.platform` 证明这是错的 —— **两边都是 `sun` / SM8750**。

**提取**（EROFS 镜像，`dump.erofs` 是 AArch64 二进制，必须在手机上跑）：

```sh
dump.erofs --path=/lib/egl --ls vendor.img        # 注意：路径相对 vendor 分区根
dump.erofs --nid=<NID> --cat vendor.img > out.so
```

---

## 关卡 5：EGL 仍然加载失败 ★ 最难的一关

驱动装好了，但还是 abort。**日志里藏着答案：**

```
E vndksupport: Could not load /vendor/lib/egl/libEGL_adreno.so from sphal namespace:
  dlopen failed: library "libcutils.so" not found:
  needed by /vendor/lib/egl/libEGL_adreno.so in namespace sphal.
```

**两个关键信息：**

1. **`sphal` 命名空间** —— AOSP 的 `libEGL` 用 `android_load_sphal_library()` 加载驱动，
   搜索路径是 `/vendor/${LIB}/egl`，**不是 `/system/lib/egl`**
2. 缺的库要在 **sphal 命名空间的可见范围**内

**失败尝试**（全部无效）：
- 放 `/system/lib/egl/` → 被 `[system]` 命名空间的 `permitted.paths` 拦截
- 放 `/system/lib/`（平铺）→ 加载器只按 `xxx/lib/egl/` 找
- 手动 `mount --bind` 整个 `/vendor/lib` → 破坏 vendor 库的 SELinux 上下文，反而更糟

**正确做法**：用 Magisk 模块的 `system/vendor/lib/egl/`，只挂载这几个文件，不动其他：

```
/data/adb/modules/<module>/system/vendor/lib/egl/
  libEGL_adreno.so
  libGLESv2_adreno.so
  ...
```

---

## 关卡 6：依赖链逐层缺失

EGL 驱动能加载了，但每解决一个依赖就冒出下一个：

```
libcutils.so
  → libdmabufheap.so
    → libvmmem.so
      → android.hardware.graphics.common@1.2.so
        → ...
```

**解法：不要一个个补，直接搬整个 32 位 `/vendor/lib`**（本例 459 个库，136 MB）。

判断依据：`binfmt` 拦截后，进程在 sphal 命名空间里找库，而 sphal 只搜 `/vendor/${LIB}`。

---

## 关卡 7：mapper.qti.so 等硬件 HAL

```
E vndksupport: Could not load mapper.qti.so from sphal namespace
F HWUI: Failed to get EGL_DEFAULT_DISPLAY! err=EGL_SUCCESS
```

`/vendor/lib/hw/` 在 13S 上是空的。从 13T 固件补：

```
mapper.qti.so
gralloc.default.so
android.hardware.graphics.mapper@4.0-impl-qti-display.so
vulkan.adreno.so
```

**补齐后，`libEGL: find api call glTexStorage2DEXT` 出现，GPU 真正工作了。**

---

## 关卡 8：装老应用

```
INSTALL_FAILED_DEPRECATED_SDK_VERSION:
  App package must target at least SDK version 24, but found 15
```

Android 16 拒绝 targetSdk < 24 的应用。

```sh
pm install -r -t --bypass-low-target-sdk-block app.apk
```

**这个参数是所有老应用能否安装的钥匙。**

---

## 最终状态

```
abilist        arm64-v8a,armeabi-v7a,armeabi
zygote_tango   running
SELinux        Enforcing（服务启动时短暂 permissive，之后自动恢复）
/vendor/lib    520 个 32 位库
/vendor/lib/egl  7 个 GPU 驱动
/vendor/lib/hw   4 个 HAL
```

**开机全自动**：`post-fs-data.sh` 设 ABI → `service.sh` 修 APEX + 启动 zygote + 恢复 Enforcing。

---

## 遗留问题

见 [issues.md](issues.md)。核心结论：

> **所有剩余问题（字体缺字、音频失真、性能损失）都来自 Tango 的 JIT 翻译本身，不是配置问题。**
