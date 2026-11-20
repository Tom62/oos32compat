# 复现步骤

> ⚠️ **风险提示**：本流程会修改系统属性、挂载 APEX overlay、往 `/vendor/lib` 塞几百个库。
> **务必先做完整备份**，并在能承受变砖的设备上操作。

---

## 0. 前置条件

| 项 | 要求 |
|---|---|
| 设备 | 一加 13S（CPH2723）或同平台（`ro.board.platform=sun`）纯 64 位设备 |
| Root | Magisk / KernelSU（需要 `resetprop`、`mount --bind`） |
| 固件 | **同平台**且**保留 32 位物料**的固件（本项目用一加 13T PKX110） |
| 存储 | 至少 1 GB 空闲（模块约 400 MB） |

### 判定固件是否可用的三个条件

```sh
# 1) 平台必须相同
grep ro.board.platform <目标固件的 vendor/build.prop>
# 本机对比：getprop ro.board.platform
# 必须完全一致（本例：sun）

# 2) 固件必须真的带 32 位库
dump.erofs --path=/lib --ls vendor.img | grep -c '\.so'     # 应为几百个
dump.erofs --path=/lib/egl --ls vendor.img                  # 必须非空

# 3) 系统分区要有 32 位 ART/bionic
dump.erofs --path=/system/lib/libc.so --ls system.img
dump.erofs --path=/system/lib/libart.so --ls system.img
```

> **反面教材**：曾误判 13T 是 canoe 平台。实测 `ro.board.platform=sun`，与 13S 相同。
> **务必用 build.prop 验证，不要靠型号猜。**

---

## 1. 提取固件物料

### 1.1 从 OTA payload 提取分区

```bash
python3 dump_payload.py vendor     # → vendor.img
python3 dump_payload.py system     # → system.img
```

### 1.2 用 dump.erofs 提取文件

`dump.erofs` 是 AArch64 二进制，**必须在手机上运行**：

```bash
adb push dump.erofs /data/local/tmp/
adb push vendor.img /data/local/tmp/     # 手机上留一份

# 注意：镜像里的路径是「分区根」相对路径
#   vendor 分区 → /lib/egl，不是 /vendor/lib/egl
#   system 分区 → /etc/fonts.xml，/etc 是符号链接，要用 /system/etc

# 列目录
dump.erofs --path=/lib/egl --ls vendor.img

# 按 NID 提取（文件名有空格/特殊字符时用）
dump.erofs --nid=<NID> --cat vendor.img > out.so
```

### 1.3 需要提取的清单

```
vendor 分区:
  /lib/egl/*              → 模块 system/vendor/lib/egl/      （7 个 GPU 驱动）
  /lib/*.so               → 模块 system/vendor/lib/          （整个 32 位 vendor 库，约 500 个）
  /lib/hw/*               → 模块 system/vendor/lib/hw/       （mapper.qti.so 等 4 个）

system 分区:
  /system/lib/*.so        → 模块 system/lib/                 （32 位 ART/bionic/hwui，约 800 个）
```

---

## 2. 部署 Magisk 模块

```
/data/adb/modules/<name>/
├── module.prop
├── post-fs-data.sh      设 6 个 ABI 属性（必须在 system_server 之前）
├── service.sh           修 APEX + 启动 zygote_tango + 恢复 Enforcing
└── system/
    ├── lib/             831 个
    ├── vendor/lib/      518 个（含 egl/ 和 hw/）
    └── etc/public.libraries.txt
```

### ⚠️ public.libraries.txt 的致命细节

```
libstats_jni.so              ← ❌ 64 位 zygote 预加载崩溃 → 无限重启
libstats_jni.so 32 nopreload ← ✅ 必须带 ABI 标记
```

**一旦死循环**：Magisk 的 bootloop 保护会给所有模块打 `disable` 标记。

```sh
# su 可能不在 PATH
/debug_ramdisk/su -c 'rm -f /data/adb/modules/*/disable && reboot'
```

---

## 3. 验证

```sh
getprop ro.product.cpu.abilist        # arm64-v8a,armeabi-v7a,armeabi
getprop init.svc.zygote_tango         # running
getprop debug.hwui.renderer           # opengl
getenforce                            # Enforcing
ls /vendor/lib/egl | wc -l            # 7
ls /vendor/lib | wc -l                # 520
ls /apex/com.android.os.statsd/lib    # 3
ls /apex/com.android.tethering/lib    # 4
```

### 判断 GPU 是否真的工作了

```sh
logcat | grep -E 'libEGL.*find api call|HWUI.*GpuCompleted|SkiaOpenGLPipeline'
```

出现 `find api call glTexStorage2DEXT` 说明 EGL 驱动加载成功。

---

## 4. 安装 32 位应用

```sh
pm install -r -t --bypass-low-target-sdk-block app.apk
```

**`--bypass-low-target-sdk-block` 是老应用的钥匙**（Android 16 要求 targetSdk ≥ 24）。

验证：

```sh
dumpsys package <pkg> | grep primaryCpuAbi      # armeabi-v7a 或 armeabi
ps -A | grep <pkg>                              # 父进程应为 zygote_tango 的 pid
```

---

## 5. 排查清单

### zygote 一直重启

```sh
logcat | grep -E 'app_process32_z.* F |Fatal signal|CANNOT LINK|vndksupport'
```

**`vndksupport` 的报错是最有价值的** —— 它会明确告诉你缺哪个库：

```
E vndksupport: Could not load /vendor/lib/egl/libEGL_adreno.so from sphal namespace:
  dlopen failed: library "XXX.so" not found: needed by YYY.so in namespace sphal.
```

### 应用启动即退出（无崩溃信号）

```sh
dumpsys package <pkg> | grep -E 'targetSdk|primaryCpuAbi'
logcat | grep -i <pkg> | grep -E 'linker|ClassCast'
```

- **干净退出**（无 Fatal signal）→ 应用自己的 root/签名检测
- **`ClassCastException`** → 应用使用了与新版 Android 不兼容的热更新框架

---

## 6. 回滚

```sh
# 停止 32 位运行时
stop zygote_tango

# 恢复 ABI 属性
resetprop -n ro.product.cpu.abilist "arm64-v8a"

# 卸载模块
rm -rf /data/adb/modules/<name>
rm -f /data/adb/modules/*/disable
reboot
```

**最坏情况**：Magisk 的 bootloop 保护会自动禁用所有模块，设备能正常启动。
