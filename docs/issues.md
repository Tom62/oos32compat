# 已知问题与排查证据

这份文档记录**所有尝试过但失败的方案**，避免后来者重复劳动。

---

## 一、中文部分字形显示为方框 ⭐

### 现象

同一个字符串里，**部分**汉字正常渲染，**部分**显示为 `.notdef` 方框：

```
输入:  "请输入磁力链接,目前仅支持magnet:?开头的链接"
渲染:  "□□入磁力□接,目前□支持magnet:?□□的□接"
        ↑↑        ↑     ↑            ↑↑    ↑
        请输      链    仅           开头   链
```

**正常的字**：入 磁 力 接 目 前 支 持 的
**缺的字**：请 输 链 仅 开 头 载

### 关键观察：所有已知设备上表现一致

- 磁力播（2019 年应用）
- Dead Space（2013 年，`armeabi`）
- 天天动听（2016 年）
- **我自己用 apktool 从零构建的测试应用**

**四个完全无关的应用，缺的是同一批字。** 这直接排除了"某个应用的字体设置问题"。

### 排查过程（全部失败）

| # | 假设 | 实验 | 结果 |
|---|---|---|---|
| 1 | 渲染器问题 | `debug.hwui.renderer=skiagl` | ❌ 无效 |
| 2 | 扩展字体是空壳 | 用 22 MB 完整字体重命名覆盖 `OSans-Ext-Regular.otf`（原 1.2 KB） | ❌ 无效 |
| 3 | 字体文件缺字 | 换成另一台设备（15T）的 `SysSans-Hans-Regular.ttf`（23.6 MB vs 23.0 MB） | ❌ 无效 |
| 4 | **验证字体本身** | **用 Python 解析 TTF 的 cmap + glyf 表** | ✅ **所有字形都有真实轮廓** |
| 5 | 可变字体 bug | 换成静态 `NotoSansCJK-Regular.ttc`（32 MB） | ❌ 无效 |
| 6 | fallback 文件缺失 | `NotoSansCJKjp-Regular.otc` 在 fonts.xml 里是**注释掉的** | 不是原因 |
| 7 | 字形偏移越界 | 计算所有字形的 `glyf` 表偏移 | 无截断边界（2.48M~8.30M 交错） |
| 8 | 应用层字符串错误 | `uiautomator dump` 取实际字符串 | ✅ **字节级完全正确** |
| 9 | 应用 locale 影响 | `cmd locale set-app-locales ... zh-CN` | ❌ 无效 |

### 决定性的对比实验

**与同平台固件逐项 md5 对比：**

| 文件 | 13S | 13T 固件 | 结论 |
|---|---|---|---|
| `fonts.xml` | `e21b12f8...` | `e21b12f8...` | ✅ 相同 |
| `font_fallback.xml` | `8567d4c5...` | `8567d4c5...` | ✅ 相同 |
| `SysSans-Hans-Regular.ttf` | `fc1c28c7...` | `fc1c28c7...` | ✅ 相同 |
| `libminikin.so` | ✅ | ✅ | ✅ 相同 |
| `libharfbuzz_ng.so` | ✅ | ✅ | ✅ 相同 |
| `libhwui.so` / `libft2.so` / `libandroidfw.so` | ✅ | ✅ | ✅ 相同 |

### 结论

> **输入全部相同（字符串、字体、配置、渲染库），输出却不同。**
> **唯一的变量是：这段代码跑在 Tango 的 JIT 翻译之下。**
>
> **bug 在 JIT 生成的 ARM64 代码里。**

### 为什么修不了

Tango 的可调空间：

```
--translator-config    只有 strict_neon_fpcr 一项（针对浮点，非字形查找）
tango.debug=on         不产生日志文件
tango.use_pretrans=0   无变化（本来就没有 .tango 缓存）
```

要真正修复需要反汇编 1.1 MB 的闭源 Rust 二进制 + 理解其 JIT 生成器。

---

## 二、音频失真（3D 游戏场景）

### 现象

Dead Space（282 MB 3D 游戏）运行时：
- **音乐**（连续压缩流）明显失真
- **音效**（短 PCM 采样）正常

### 数据

```
dumpsys media.audio_flinger:
  Normal mixer raw underrun counters: partial=0 empty=21    ← 缓冲区空过 21 次

/proc/loadavg: 14.59（8 核）
游戏 CPU: 18.5%
内存: 14581M / 15108M used（只剩 526 MB）
```

### 分析

```
音效路径：一次性写入 → 对实时性不敏感 → 写慢了听不出来
音乐路径：实时回调（每 10-20ms 必须交付一帧）→ 断一次就爆音

JIT 翻译后的代码跟不上实时节奏 → 缓冲区欠载
```

### 排除的可能

| 假设 | 验证 |
|---|---|
| 32 位音频库缺失 | ❌ 40+ 个音频库全部加载（`/proc/pid/maps` 可验证） |
| 解码器错误 | ❌ 音效正常说明解码链路是通的 |

### 缓解

- 腾内存（本例只剩 526 MB）
- 降低游戏画质
- 无法根治（JIT 开销是结构性的）

---

## 三、Tango 参数一览（挖完的）

| 类型 | 项 | 说明 |
|---|---|---|
| 属性 | `tango.debug` | **`on`/`off`**（不是 1/0） |
| | `tango.log_dir` | 日志目录（实测不产生文件） |
| | `tango.use_pretrans` | 预翻译缓存开关（本设备无缓存） |
| | `tango.jit_dump_dir` | JIT dump 目录 |
| 命令行 | `--translator-config` | **只有 `strict_neon_fpcr`** |
| | `--no-pretrans` | 禁用预翻译 |
| | `-d` / `--log-config` | 日志级别 |
| | `--jit-dump-dir` | 性能分析 |
| 日志类别 | `dbt::signal` `dbt::translate` `dbt::disasm` `dbt::vm` `dbt::dispatcher` `dbt::persist` | |

**注意**：13T 固件里**没有** `tango_translator` —— 它根本不启用 32 位。

---

## 四、应用级失败案例

| 应用 | 现象 | 原因 |
|---|---|---|
| SunPlayer (`com.iiplayer.sunplayer`) | 进程启动 → 显示启动画面 → **干净退出**（无崩溃信号） | 应用自己的 root 检测 |
| 阿里星球 9.0.4 | `ClassCastException: Long cannot be cast to Integer` | 阿里 Atlas 框架与 Android 16 不兼容（`getServiceInfo` 返回值类型变化） |
| 天天动听 8.4.1 | ✅ 可用 | —— |
| Dead Space | ✅ 可用 | 音频有失真 |
| Flappy Bird | ✅ 可用 | targetSdk 15 需 patch |

### 阿里星球的完整堆栈（有价值的案例）

```
java.lang.ClassCastException: java.lang.Long cannot be cast to java.lang.Integer
    at android.taobao.atlas.wrapper.AtlasApplicationDelegate$PackageManagerProxyhandler.invoke
    at java.lang.reflect.Proxy.invoke
    at $Proxy6.getServiceInfo
    at android.app.ApplicationPackageManager.getServiceInfo
    at WV.HE.<init>(chromium-TrichromeWebView...)
```

**纯 Java 层错误，与 32 位兼容层无关** —— 这个应用在**任何** Android 16 设备上都跑不了，
只是因为它装不上 64 位设备，所以一直没人发现。

---

## 五、桌面图标不显示

**现象**：通过 `adb install` 装的老应用，在 OPPO 桌面的"全部应用"里看不到，但**搜索能搜到**（图标也正常）。

**验证**：

```
cmd package query-activities -a MAIN -c LAUNCHER   → 能查到 ✓
dumpsys package ...                                → installed=true hidden=false ✓
```

**结论**：桌面数据库缓存问题，重启桌面或重启手机即可。

**patch 过 `targetSdk`（15→28）和 `minSdk`（8→21）无效** —— 不是 SDK 过滤。
