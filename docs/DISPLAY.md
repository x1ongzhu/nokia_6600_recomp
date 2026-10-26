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

## 3. 直接启动 FbServ（round 38）

kernel 路径仍卡在 `RThread::Resume(0x32)`，所以 harness 增加了直接启动
原始 `FbServ.exe` 的路径：

```
NK_ENTRY=0x506897d5 NK_SP=0x80580000 NK_CPSR=0x40000053
```

`FbServ` 的入口是 Thumb。`NK_CPSR=0x40000053` 不含 T 位，之前的
harness 会把 Thumb prologue 当 ARM 解码，只在函数中途才恢复。现在
**entry mode 是权威的**：Thumb `NK_ENTRY` 会强制 `CPSR.T=1`。

结果：**3,612 条指令、0 undefined、0 unbound IAT**，FbServ 跑到
`0x5068a572` 的对象初始化：

```
0x5068a572  ldr r0, [r5]
0x5068a574  ldr r2, [r0, #8]
0x5068a576  adds r0, r5, #0
0x5068a578  movs r1, #3
0x5068a57a  bl 0x5068b618        ; bx r2
```

对象 `0x80600018` 的 vtable 是 `0x50680000`，`[vtable+8]` 是
`0x068a0689`，所以 PC 逃到 `0x068a0688`。这说明直接入口路径没有跑
FbServ 的 C++ 构造函数/DLL import 初始化；下一步是补 constructors/
imports，或改用 kernel 的 process loader。

写 watch 现在也覆盖 byte/halfword store，能看到完整序列：

```
5038e2ec  allocator zeroes the 0x18-byte block
503993c8  EUser sets [object] = 0
5068a5c8  FbServ constructor sets [object] = 0x5068c0a4
5038bc6c  EUser descriptor code writes byte [object+1] = 0
```

最后一笔把 `0x5068c0a4` 变成 `0x50680000`；`[0x50680008]=0x068a0689`，
于是调用逃到 `0x068a0688`。

完整调用链（round 40）：

```
5068a4f6  movs r0,#0x14           ; allocate 20 bytes
5068a4f8  bl   operator new       ; -> 0x80600018
5068a502  bl   0x5068a5bc         ; construct, vtable 0x5068c0a4
5068a4ee  bl   0x5068b70c         ; EUser formatting path
5038bc38  EUser descriptor helper
5038bc6c  byte store to [r3+1]    ; r3 = 0x80600018, the object
```

同一个 `0x80600018` block 既是 CBase 对象又是格式化调用的 `TDes8`
缓冲区，所以 vtable 被破坏。`NK_APP_STACK_CLEAR=1` 清零用户栈也不改变
它：descriptor header 是 guest 自己构造的。直接入口因此缺少真实进程的
user-side descriptor/thread context。下一步要么补齐这部分，要么改用
kernel process loader。

直接 SWI gate（`NK_SWI_DIRECT=1`）只到 3,612 条：格式化调用会破坏
`0x80600018` 的 vtable。把 `NK_SWI_DIRECT=0` 后，vtable 破坏消失，
FbServ 跑到 **1,499,521 条**。但 round 43 发现：**这不是真实 SVC
路径**——`NK_SWI_DIRECT=0` 且没有 exception 模型时，`svc` 被当成
no-op，内核从未进入。1.5M 条是“所有系统调用被忽略”的运行：

```
- 切换到 kernel 分配的用户栈，sp 约 0x7fef....
- 进入重复的 EUser wait/scheduler 链：
  5039eddc -> 5039d9d0 -> 503998b4 -> 50392e00 -> 50392ec0
- 最后 null callback（lr=0, pc=0）
```

新增 `NK_SWI_EXCEPTION=1` 后才真正进入 SVC vector `0xffff0008` 和
kernel handler `0x50314f30`。handler 需要一个 mask-ROM 安装的
pre-handler `[0x80000f34]`；direct E32 entry 下它是 0，所以
`ldr pc,[r12,#-4]` 跳到 0。用 high-vector page 的零返回 hook 对象补上
后：

- kernel boot 跑 11,114 条，返回 boot sentinel `0xdead0000`（kernel 的
  EUser import stub 是 user-style SVC，需要 user-mode caller）；
- direct FbServ 只跑 56 条并 null-return，user-SVC 返回路径仍缺
  current-thread 状态。

所以 round 41 的 “1.5M 真实 SVC” 结论需要修正：它是 no-op SWI 运行。
真实 SVC 模型已经加入，但还没接到完整的 user thread/executive 上下文。

round 45 修了三处 boot state，real-SVC 路径现在能稳定跑满 2M 预算：

- USR bank 的 SP 初始化为 app 的 `NK_SP`（`0x80580000`），且
  `stack_in_ram()` 跟随实际映射的 6 MiB bank；SVC 返回不再把 app 栈
  换成 preset `0x80240000`。
- B7e current-thread hook 在初始 fake thread 发布**之前**安装，fake
  thread 也有 `+0x18/+0x5c/+0x64`。
- kernel DFC queue `0x80001c28` 初始化为空，第一条 SVC 的 DFC
  processor 不再调用垃圾 entry。

结果：direct FbServ + real SVC 跑满 **2,000,000 条**，停在
`0xffff0008` / `0x5039865c` 的 EUser `WaitForAnyRequest` 循环，
0 fault。direct-SWI 路径也到 500k 预算，但出现 `0x600000` 的
wild clear，是它自己的新 frontier。

round 44 进一步定位：FbServ 的第一条系统调用是
`0x50392b88 ef00006c`（`svc #0x6c`）。kernel handler 用 bit 23 区分
user/kernel；flat image 把 app 的 import 绑到 kernel-side EUser stub，
所以 handler 走 kernel 路径。给 stub 标 bit 23 后，handler 从
dispatch table 取到 `0xe59ff028` 并跳到指令字，说明 user path 的
table/entry 格式还不对。下一步是修 import 绑定或 user SVC table。

round 42 进一步确认：最终返回 0 **不是** vtable 调用。第一次在
`0x5039ee14` 观察 pop 时，栈上仍有正确的 saved LR `0x5039edc8`；只有
经过 executive call `0x5039b05c` 后，最终 pop 才读到 0。也就是说，
push/pop 本身没错，失败发生在 **thread/context（栈）切换** 上。
把 EUser wait SWI `0x76..0x7b` 用 direct gate 内联完成也不能修复：
direct 路径仍停在 3,360 条 / `0x068a0688`。

这条路径是目前离第一帧最近的路线，但下一步必须补 EUser thread/
executive 上下文，或改回 kernel scheduler。

这条路径绕过了 kernel 死锁，是目前离第一帧最近的路线。

---

## 4. 开机画面：SplashScreen / EwSrv

ROMFS 里的开机视觉链路：

| 文件 | uid3 | 地址 | 入口 |
|---|---|---|---|
| `SplashScreen.exe` | `0x100059de` | `0x509eee20` | `0x509eee85` (Thumb) |
| `SplashScreen.mbm` | — | `0x509efae0` | MBM 资源 |
| `EwSrv.exe` | `0x10003b20` | `0x506a81a0` | `0x506a8205` (Thumb) |
| `EStart.exe` | — | `0x503da440` | `0x503da4a5` |

在稳定 app harness 里直接跑 `SplashScreen.exe`，会进入 `EwSrv` 代码，
最初在 `0x506cbf1c` 遇到 undefined instruction：

```
509ef864 -> 0x506cbf1c, lr=0x509ef1ab
bytes: ec ff 20 1c ...
```

进一步检查发现 export slot `0x506ce7d0` 存的是 `0x506cbf1d`，而真正的
Thumb prologue 在 `0x506cbf1e`（`20 1c 10 bc 02 bc 08 47...`）。也就是
**ROM build 的 export 值差 2 字节**，不是 CPU 解码问题。`NK_EWSRV_SNAP=1`
按 E32 loader 的 Thumb +2 规则修正：

```
0x506cbf1d -> 0x506cbf1f
```

修正后 SplashScreen 跑满 **2,000,000 条**预算、0 undefined/unbound/
recovery，停在 request-semaphore 的 Wait service `0x503244e4..f4`，
在等客户端/消息，而不是崩溃。

round 48 用 `NK_WAIT_HLE=1`（semaphore Wait 完成 `[r5]` 并返回 0）让
它离开 Wait，但 app 立刻进入 `0x5038d2d4` 的 **wild descriptor copy**
（8-word expansion loop，source/dest 约 `0x80da....`），跑到预算也没有
显示绘制。直接运行 `EwSrv.exe`（entry `0x506a8205`）也在
`lr=0x506c0b15` 处 null-call。两个路径都指向缺失的
window-server/surface 状态，而不是 CPU。

round 49 又确认了两点：

- `SplashScreen.mbm` 是 0xd54 字节的 MBM，header 在 `0x509efae0`：
  UID `0x10000041`、bitmap offset `0x10`/`0x8c0`、宽 `0xb0`(176)、
  高 `0xd0`(208)，像素主要是 `0x7fff`（RGB555 白）。stable 2M 运行后
  的 RAM dump 里**没有 MBM signature**，说明 app 还没加载/解码 splash。
- EwSrv 的 null call 来自 Thumb veneer `0x506c15ee` 加载的字面量
  `0x4a7846c0`，它不是合法 IAT slot。这是 **relocation/veneer** 问题，
  不是简单未绑定 import。

round 50 用 `NK_FIX_4A78=1` 把 `0x4a7846c0` 指向 high-vector page 的
零返回 stub，EwSrv 于是执行：

```
506c15ee -> 0xffff0d00 -> 0xffff0d04 -> 506c0b14 ...
```

它越过了第一个 missing-DLL call，但很快遇到下一个 null pointer。
这是 window-server bring-up 的下一步，而不是完整启动。

下一步是补齐 EwSrv/FbsCli 的 relocation/surface 初始化，或 HLE
window-server 的 create/draw 调用，把 splash 像素送进 framebuffer。

另外，direct 路径对 `0x600000` 的 400 KB+ 写入不是 framebuffer，而是
一次**长度错误的数据 copy**；`NK_MAP_APP_LOW=1` 把
`0x600000..0x1600000` 映射成 RAM 后，copy 仍继续越过 16 MiB。

---

## 5. 还缺什么

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

## 6. 下一步

1. 修直接 FbServ 的对象初始化：跑 `.init_array`/constructors，或让
   kernel 的 process loader 正常启动 FbServ。
2. 修 `RThread::Resume(0x32)` / thread-start completer（见 BOOT.md
   2.11），让 kernel 路径也能继续 Init2/Init3。
3. 跟踪 `FbServ.exe` 的入口与 `FbsCli.dll` 的 `0x59200000` 引用，
   确认 variant 对象的 HAL id。
4. 确认 LCD 寄存器窗口后实现 HLE，并在 guest 第一次提交 framebuffer
   时抓帧（PPM/PNG），而不是用宿主图案代替。
