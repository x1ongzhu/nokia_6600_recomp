# DISPLAY — 从 ROMFS 到第一帧的链路

本文记录 **6600 显示链的实际文件、地址和已经排除的误导**。目标是
176×208、16bpp、无 GPU 的 LCD；像素最终来自 guest 写入的 framebuffer，
不允许用宿主演示画面代替。

---

## 1. 已知链路（ROMFS 静态事实）

| 文件 | uid3 | 运行时地址 | 入口 | 说明 |
|---|---|---|---|---|
| `FbServ.exe` | `0x10003a16` | `0x50689770` | `0x506897d5`（Thumb） | Font & Bitmap Server，显示服务进程 |
| `FbsCli.dll` | `0x10003a15` | `0x5068c150` | `0x5068c1b5`（Thumb） | FbServ 客户端 DLL；引用 `0x59200000` |
| `BitGdi.dll` | `0x10003b18` | `0x50698080` | `0x506980e5`（Thumb） | 位图/GDI 绘制 |
| `ecust.dll` | `0x100058e7` | `0x50339750` | `0x503397b4`（ARM） | 客户/variant 硬件驱动；代码 `0x22f4` 字节，引用 `0x59E00010` / `0x59200000` |

这些地址来自 `out/6600_runtime_layout.json` 与 ROMFS 解析，不是猜测。
`FbServ.exe` / `FbsCli.dll` / `BitGdi.dll` 都是 E32Image（uid1
`0x1000007a`/`0x10000079`）。

`ecust.dll` 的代码里有两处硬件常量：

```
0x5033a940  ldr r4, =0x59E00010
0x5033ac00  ldr r3, =0x59200000
0x5033ac08  add r3, r3, #0x600000      ; -> 0x59800000
```

`0x59E00010` / `0x59200000` 是当前最可疑的 variant 硬件寄存器窗口；
还需要确认它属于 LCD、DMA、音频还是 keypad，不能仅凭地址下结论。

---

## 2. 已排除的误导

### 2.1 `0x41000000` / `0x41080000` 不是 framebuffer

MMIO 写日志（round 36）显示 `0x41080000..0x41083fff` 被 0xffff 填充，
第一笔是：

```
[mmio] write 0x41080000 = 0 (2) pc=0x503164cc lr=0x503163f4
[mmio] write 0x41000300 = 0xc000432 (4) pc=0x50310bc8
```

`0x503163f4` 的循环扫描 `0x41000000` 的 **boot-region descriptor**，
把 4 字节 entry 复制到 `0x41080000`。`0x41000300/304` 是 descriptor
控制字。它是 kernel 的 boot-region 表，不是 LCD。

### 2.2 `FiqLCDBuffer` 是 FIQ 名称，不是寄存器基址

kernel 字符串 `0x503372f0` = `"FiqLCDBuffer"`，位于
`0x50311978` 的一个名称/描述符表里。它说明 kernel 有一个 LCD FIQ
handler 名称，但没有给出 framebuffer 或控制寄存器地址。

### 2.3 Java `lcdui.dll` / `lcdgr.dll` 不是原生显示驱动

`0x510354c0` / `0x5104d430` 里的 LCD 字符串属于 MIDP/Java UI，
不是 kernel 的 display driver。`midp2.exe` 里的 "Display" 同样是 Java 类。

---

## 3. 还缺什么

1. **进程启动**：`FbServ.exe` 还没有被 kernel 作为进程加载。当前
   supervisor 死在 `RThread::Resume(0x32)` 的 thread-start 等待上
   （见 [BOOT.md](BOOT.md) 2.11），NULL 线程在 `Kern::Init3` timing
   loop 里。没有进程，就没有 FbServ，也就没有第一帧。
2. **FbServ 的显示初始化**：需要确认它通过 `FbsCli` 调用哪个 HAL /
   variant 对象，以及最终写哪个 framebuffer/寄存器。
3. **LCD HLE**：在确认寄存器窗口后实现 176×208 16bpp framebuffer、
   stride、palette/CLUT 和 frame commit；窗口尺寸必须来自 guest 的
   HAL/DisplayMode，而不是硬编码。

---

## 4. 下一步

1. 修 `RThread::Resume(0x32)` / thread-start completer（见 BOOT.md
   2.11），让 supervisor 继续 Init2/Init3。
2. 跟踪 `FbServ.exe` 的入口与 `FbsCli.dll` 的 `0x59200000` 引用，
   确认 variant 对象的 HAL id。
3. 确认 LCD 寄存器窗口后实现 HLE，并在 guest 第一次提交 framebuffer
   时抓帧（PPM/PNG），而不是用宿主图案代替。
