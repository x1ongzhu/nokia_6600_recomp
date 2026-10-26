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
`lr=0x506c0b15` 处 null-call。round 62 归因：wild copy 的长度
`0x484c4289` 来自 HLE allocator 的 `'HLEH'` cell header，不是
window-server surface；修 header 后同一路径到达 EwSrv
`0x506ca5e4`。

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

round 51 进一步修正了 EwSrv 的入口：call `0x506a821a` 编码的是
`0x506c0b0c`，落在真实函数中间；真实 prologue 在 `0x506c0a4a`：

```
506c0a4a  push {r4-r7,lr}; mov r7,sb; mov r6,r8; push {r6,r7}
506c0a52  sub sp,#0xc
...
506c0b0c  adds r0,r5,#0x14   ; mid-function
```

新增 `config/callmap-ewsrv-6600.txt` 做 call-site fixup（需要
`NK_CALL_INFER=1`）。修正后 EwSrv 进入真实 prologue，但下一个 veneer
`0x506c1dba` 的 literal 是代码/padding，不是 slot——这是
**packed/relocated veneer literal** 问题，不是单个缺失 import。

round 52 进一步确认：EwSrv 的 **IAT 是好的**。`0x506c9290` 处的表
包含已解析的 Thumb 地址：

```
0x506c9294 0x506980e5
0x506c9298 0x506a815c
0x506c929c 0x503c9485
```

但 veneer `0x506c1dba` 加载的是 `0x40b846c0`（代码/padding），不是
IAT slot。也就是说，**app code 的 literal pool 没有被 flat image loader
重定位**。这是 EwSrv/window-server bring-up 的具体 loader frontier。

round 53 找到了真正的 LCD/framebuffer 基址。ecust.dll 的显示配置
`0x5033abf4` 写入：

```
[r1] = 0x59200000        ; LCD controller
[r2] = 0x59800000        ; framebuffer = base + 0x600000
[r3] = 0x2000000/0x400000; framebuffer size
```

之前 harness 没有映射这两个窗口，guest 的像素写入都进了 MMIO bus。
`NK_MAP_LCD=1` 现在映射 controller page 和 4 MiB framebuffer，并可 dump。

当前 stable SplashScreen 2M 运行仍然**不写 framebuffer**：4 MiB dump
全 0。这现在是抓第一帧的 capture target；下一步是让 guest 真正执行
显示初始化/draw。

round 54 又验证了 kernel boot 本身：带 `NK_MAP_LCD=1` 跑满 6M，
`0x59800000` 仍然全 0，停在 `0x50312720`。说明 kernel bring-up 也
没有到达 display driver/UI 层；window-server/app-loader 仍是缺口。

round 55 找到了架构层原因：EwSrv 的 header `0x506a81a0` 是
**TRomImageHeader**，不是 E32 file：

```
+0x00 iUid1        0x1000007a
+0x04 iUid2        0x1000008c
+0x08 iUid3        0x10003b20
+0x10 iEntryPoint  0x506a8205
+0x14 iCodeAddress 0x506a8204
+0x18 iDataAddress 0x506c4c80
+0x1c iCodeSize    0x1ca80
+0x38 iDllRefTable 0x506c9290
+0x40 iExportDir   0x506c928c
```

`TDllRefTable` 在 `0x506c9290`：`iFlags=1`、`iNumberOfEntries=7`，
后面是 7 个 imported-DLL entry 地址（`0x506980e5`、`0x506a815c`、
`0x503c9485`...）。flat image **没有应用 ROM loader 的 import
fixup**，所以 veneer literal（`0x4a7846c0`、`0x40b846c0`）只是
placeholder，不是解析后的 IAT slot。这是 window server 起不来的
架构原因。

round 56 进一步发现：这些坏 literal 看起来是 **link-time address**。
用 `0x4a780000` 作为 link base，把 `0x4a7846c0` 按每个 image 的
`code - 0x4a780000` 平移，会落在多个 image 的合法 Thumb prologue 上：

```
uid 0x10003c77 -> 0x505bf774  b510
uid 0x10f9a40  -> 0x50815a74  b570
uid 0x1000a859 -> 0x50a6d6f4  b5f0
```

`0x40b846c0` 不匹配这个 base，说明每个 DLL 可能有自己的 link base。
这进一步支持“缺 ROM-loader relocation/import fixup”的结论。

round 57 解析了 EwSrv 的 64 字节 dllref section `0x506c9290`：

```
0x00070001   ; flags=1, count=7
0x506980e5   ; BitGdi entry
0x506a815c   ; EwSrv entry
0x503c9485   ; EUser entry
...
0x00000000
0x5068c1b5   ; FbsCli entry
...
0xffffffff
```

零后面的 6 个 entry 不是 per-import IAT slot：把第二个 veneer 指到
`0x506c92b8`（`0x50698040`）会进入 BitGdi，然后 wild-jump 到
`0x5155a0ca`；其他 slot 都 null-call。结论：EwSrv 需要真实的
ROM loader import fixup，不能靠猜 slot 表。

下一步是给 flat image 的 ROMFS app 加 literal-pool/relocation 处理，
或 HLE window-server 的 create/draw 调用，把 splash 像素送进 framebuffer。

另外，direct 路径对 `0x600000` 的 400 KB+ 写入不是 framebuffer，而是
一次**长度错误的数据 copy**；`NK_MAP_APP_LOW=1` 把
`0x600000..0x1600000` 映射成 RAM 后，copy 仍继续越过 16 MiB。

---

## 5. 第一帧：白色控制帧（round 58）

round 58 先用**全白源**验证端到端 framebuffer；这里的白色是 harness
填充的 control，不是 MBM 的实际内容（MBM 第一帧含 NOKIA logo，见第 6 节）。

1. 映射 LCD controller `0x59200000` 和 framebuffer `0x59800000`；
2. 在 guest 内存 `0x80800000` 填 `0xff`（16bpp 白）；
3. 调用 guest EUser `Mem::Copy`（`0x5038cfe0`），
   `dst=0x59800000, src=0x80800000, len=176*208*2`；
4. dump `0x59800000`，前 **36,608/36,608** 像素都是 `0xffff`。

渲染结果：[first_frame.png](assets/first_frame.png)（176×208 白屏）。
这是 **framebuffer 管线的 control 帧**，由 guest `Mem::Copy` 写入真实
LCD framebuffer。

## 6. Nokia logo 帧（round 61）

`SplashScreen.mbm` 在 `0x509efae0`，ROM MBM header 是
`UID 0x10000041, count=2, offsets 0x10/0x8c0`。bitmap 0 的
`SEpocBitmapHeader` 在 `0x24`：

```
size=0x894 header_len=0x28
176 x 208  (twips 352 x 416)
bpp=8  color=1  palette=0  compression=1 (EByteRLE8)
```

payload 从 `0x54` 开始（与 eka2l1 的 `bitmap_data_offset` 公式一致）。
解码 36,608 个像素：**35,159 白 + 1,449 非白**，非白 bbox
`x=0..173, y=159..178`，形状就是下方的 **NOKIA** logo。它不是全白帧；
round 58 的白屏只是 source control。

完整帧路径：

1. harness 从 guest 内存 `0x509efae0` 读取 MBM，按 EByteRLE8 解出
   176×208 的 8bpp 灰度值；
2. 展开成 RGB565 写进 guest buffer `0x80800000`；
3. 调用真实 guest EUser `Mem::Copy`（`0x5038cfe0`），
   `dst=0x59800000, src=0x80800000, len=176*208*2`；
4. dump `0x59800000`，帧与源完全一致（RGB565 FNV-1a
   `0xd10ed2d0`），guest copy 正常返回 `0xdead0000`。

结果：[nokia_logo_frame.png](assets/nokia_logo_frame.png)（176×208），
3× 预览：[nokia_logo_frame_3x.png](assets/nokia_logo_frame_3x.png)。
验收：`tools/test_round61.sh`。

诚实边界：MBM 的 RLE 解码目前是 harness HLE，不是 SplashScreen 自己通过
FbsServ/`CFbsBitmap` 解出来的；后者仍被未重定位的 ROM veneer 卡住
（rounds 55-60）。像素来自固件资源，framebuffer 写入来自 guest 代码。

## 7. App-driven 路径：round 62/63 的地基修复

round 61 的 logo 帧仍然是 harness 解码 HLE；要跑完整的 app-driven 开机
画面，必须让 SplashScreen 自己的启动/import/EwSrv 路径成立。round 62
定位并修掉了三处地基问题：

1. **HLE allocator cell header**：`RHeap::ReAlloc` / `0x5039c37c` 从
   `[ptr-4]` 读 cell size。旧 HLE header 在该位置写 `'HLEH'`，于是首次
   realloc 变成 `0x484c4544` 字节的 `Mem::Copy`（`0x484c4289` 是它在
   trace 里的长度）。现在 `[ptr-8]` 是 HLE 私有 size，`[ptr-4]` 是
   guest cell header（`size+4`）。
2. **thread-start completion**：SplashScreen 通过 EUser wrapper 调
   `Kern::StartThread`（SVC 0x76）并轮询 `TRequestStatus`。bring-up
   DThread vtable+0x20 原来直接返回、不完成 `[r3]`，app 永远在
   `0x50398648` 的 wait-any-request 轮询里。`NK_START_HLE=1` 用
   `0xffff0e00` 完成 `[r3]`；`NK_USER_SVC_KERNEL=1` 清掉 EUser SVC
   0x76 stub 的 bit 23，让 kernel service table 真正进入 StartThread。
3. **共享 EUser export table**：`config/imports-r29-6600.txt` 的 kernel
   K-3 relocation 直接改写 EUser export slots。比如 `0x503b4f10`
   （kernel 需要 `0x5038918c`）同时被 app 用作 import slot（app 链接的
   export 是 `0x50389180`）。kernel map 一应用，app 的 EUser import 就
   拿到错函数——旧 app 测试的 wild descriptor / 空 vtable 都由此而来。
   direct-app 运行必须省略 `NK_IMPORTMAP`；正确修法是 per-consumer
   import table 或 app EUser import-name map。

修正后的 app frontier（不应用 kernel map）：

```
0x509eef12  ldr r0,[r4]        ; r4 = operator new(4) -> 0x80600008
0x509eef14  ldr r2,[r0,#8]     ; [0x80600008] = 0, so [8] = 0xe59ff028
0x509eef1a  bl 0x509ef630      ; bx r2
```

对象是 `operator new(4)` 返回的 4-byte block，vtable 没有被安装；app
随后对它做 virtual dispatch，PC 逃到 `0xe59ff028`，`lr=0x509eef1f`。
下一步是 app EUser import 重绑（按 name/ordinal）或 per-consumer
import table，然后才轮到 EwSrv jump table/literal relocation。

验收：`tools/test_round62.sh`（含两个 0-instruction dump，证明
`0x503b4f10` 在 kernel map 下变成 `0x5038918c`，不应用时保持
`0x50389180`）。

### round 63：第一个 app-side EUser import rebind

SplashScreen 的 import slot `0x503b4338` 期望一个 CHeartbeat 风格的
构造器：对象建好后，app 会用 `vtable+8`、`r1=3` 调它。ROM slot 里是
`operator new`（`0x503963dc`，只返回 zeroed object），所以 round-62 的
frontier 才会读 `[0+8]`。

新增的 `config/imports-app-6600.txt` 把该 slot 重绑到 ROM export
index 747（`0x50383c84`）。`0x50383c84` 分配 0x10 字节 CBase、安装
vtable `0x503b359c`、分配 0x40 字节 backing store，并自己完成
`vtable+8/r1=3` 的调用——与 app 的用法一致。`NK_APP_IMPORTMAP` 在
flat image load 之后只改文件中列出的 app slots，不碰 kernel map。

结果：

```
app import rebind: 0x503b4338 0x503963dc -> 0x50383c84
stop: returned (2) at 0xdead0000
insns=360
0x80600008 -> vtable 0x503b359c
```

即 app 的静态初始化不再崩在 `0x509eef12`，而是构造出 CBase 并干净返回。
**仍没有 framebuffer 写入**：真正的 splash main / active object 还没有
被驱动。下一步要确认 SplashScreen 是由 EStart 调用、跑在独立线程，还是
需要 active scheduler loop；之后再接 EwSrv jump table/literal relocation。

验收：`tools/test_round63.sh`。

### round 64：main 路径与 kernel SVC-return blocker

第二个 app-side rebind 是 `0x503b4980`（app 的 TTrap wrapper）。ROM
slot 里是 string helper `0x50396ca8`，它返回非零指针，使 app 认为初始
TRAP 失败并跳过 `0x509ef5fc` 的 splash main/constructor。把它重绑到
`0x5038cae8`（TTrap::Trap）后，app 确实进入 main 路径。

main 路径立刻被 kernel SVC return 卡住：

```
User::Alloc (0x503988f8) -> svc #0x6c
  first return is correct: 0x50314f78 -> bx lr -> 0x503988fc
  later (after the 0xe59ff028 writes) a subsequent SVC falls into
  0x50314f78 with lr=0x50314f78 -> bx lr self-loop
```

`NK_USER_SVC_KERNEL=2` 清掉 9 个 EUser SVC stub 的 bit 23，仍然
self-loop。第一条 SVC 本身能正常返回，说明问题不是最开始的
exception-return；更像是 `0xe59ff028` 的 descriptor/cleanup 目标先被
写坏，后续 SVC 的 bank/LR 才被污染。该路径对 `0xe59ff028` 的 2 笔
MMIO 写来自 `0x50383c74/7c`，调用点是 `0x50383ec0`，此时 `r5`
（cleanup/destination）就是 `0xe59ff028`。

另一个线索：kernel handler 在 `0x50314f60` 实际读的是
`[0x80000f48]`（静态字 `0x80000f48`），而 harness 的 svc hook 设在
`[0x80000f34]`；失败运行里 `[0x80000f48] = 0`。把
`[0x80000f48]` 设成 `0xffff0b04` 仍未消除 self-loop，说明 self-loop
还涉及 SVC bank/SPSR 的返回路径，不只是这一个 pre-handler 指针。

进一步 trace 到 `r5=0xe59ff028` 的来源：call chain 是
`0x509ef612 -> 0x509ef78c -> 0x50383e50 -> 0x50383e80`，进入
`0x50383e80` 时 **r0=0**、r1=`0x54442d18`；该函数把 r0 当 descriptor/
overflow 对象，读 `[r0+0xc]` 就从低地址读回了 `0xe59ff028`。也就是说
这不是 cleanup stack 溢出，而是 main 路径里一个 **null descriptor /
TDes16Overflow 参数** 被格式化函数解引用。下一步应确认
`0x509ef78c` 这个 app helper 的 import/ABI 是否又绑错。

### round 66：low allocator rebind 消除 null descriptor

`0x509ef5fc` 的 `operator new(0x68)` 走 EUser export index 2
（slot `0x503b379c`）。app 链接的语义是 `User::Alloc`，但 ROM 原始
slot 是另一个低 ordinal 函数并返回 0，于是 `r4=0`，格式化函数读到
`[0+0xc]=0xe59ff028`。

`config/imports-app-main-alloc-6600.txt` 增加：

```
0x503b379c 0x503988f0   # User::Alloc
```

结果：

```
app import rebind: 0x503b379c 0x5038ee04 -> 0x503988f0
--- stop: budget (0) at 0x50314f78 ---
mmio: 0 reads, 0 writes
framebuffer: 0 non-zero bytes
```

`0xe59ff028` 的 descriptor/format 写完全消失。剩余 blocker 是 app
main 的 StartThread/SVC 路径，仍在 `0x50314f78` self-loop；最终寄存器
`r1=0x32` 与 thread start handle 一致。验收：
`tools/test_round66.sh`。

补充 control：把 SVC 模型切到 direct dispatch
（`NK_SWI_DIRECT=1 NK_SWI_EXCEPTION=0`）后，同一条 main 路径不再撞
banked SVC self-loop，而是跑到 EwSrv `0x506ca5e4` null call
（1,561 条）；再把 EwSrv export slot `0x506ce44c` 指到
`0x506ca57f`，又回到已知的 `0x506cd868 -> 0xb5f00000` wild jump。
这说明 banked SVC return 和 EwSrv jump-table relocation 是两条独立
的 blocker，direct dispatch 可以先绕开前者。

`0xb5f00000` 的具体来源也追到了：`0x506ca5c0` 调 `0x506cd866` 时
把 `r3=0x506ca57f`（EwSrv 函数自己的入口地址）传进去；`0x506cd866`
是 `ldr r3,[r3]` thunk，于是读到 `0x506ca57c` 的首字
`b5f00000` 并跳过去。也就是说，EwSrv export slot `0x506ce44c`
snap 到 `0x506ca57f` 后，调用参数/目标仍不对，下一轮需要确认
EwSrv 对该 slot 真正的函数入口（可能是相邻的 `0x506ca5ee` 等）。

### round 68：direct entry 不是绘制路径

把 EwSrv slot `0x506ce44c` HLE 成 zero-return stub `0xffff0300`
后，direct SplashScreen 入口干净返回 `0xdead0000`（1,694 条），
`mmio: 0 reads, 0 writes`，framebuffer **0 像素**。所以
`0x509ef1e4` 的 EwSrv 调用只是初始化/清理，不是绘制；直接跑
SplashScreen 的 E32 entry 不会产生开机画面。真正的 driver 必须来自
EStart、kernel 创建的 process/thread，或 active object。

验收：`tools/test_round68.sh`。

EStart.exe 直接入口（`0x503da4a5`）是下一步候选：它 119 条后在
`lr=0x503da5b9` null-call，`r5=0xe59ff028`，经 `0x503db628` stub 到
slot `0x503b6b38`。这是 EStart 自己的 import 未绑定，不是 EStart 逻辑
本身。该 slot 属于 uid3 `0x100039e8`（export_dir `0x503b6b38`，
ordinal 2）；实际函数表在 `0x503b6b30`，前两项都是 `0x503b53f5`，
而 `0x503b6b38` 为 0。这又是一个 export_dir/import slot 需要 loader
fixup 的洞；绑定它是下一轮的直接入口。

### round 69：EStart 首个 import 绑定

`config/imports-estart-6600.txt` 把 EStart slot `0x503b6b38` 重绑到
uid3 `0x100039e8` 的真实 export `0x503b53f5`。结果：

```
app import rebind: 0x503b6b38 0000000000 -> 0x503b53f5
--- stop: budget (0) at 0x50314f68 ---
insns=200000
mmio: 0 reads, 0 writes
framebuffer: 0 non-zero bytes
```

EStart 不再 119 条 null-call，而是跑满 200k，停在 kernel
SVC/pre-handler 路径 `0x50314f68`。下一步是它等待的线程/信号量事件
（很可能是 SplashScreen 或 window server 的启动）。验收：
`tools/test_round69.sh`。

### round 70：EStart wait HLE 与 zero-vtable frontier

加 `NK_WAIT_HLE=1` 完成 EStart 的 wait-any-request 后，EStart 从
200k spin 推进到 **12,136 条 + 1,720 次 MMIO 读**，随后停在一个
zero-vtable 对象：

```
r5 = 0x80600000, [r5] = 0
0x503dac78  ldr r2,[r0,#8] -> 0xe59ff028
0x503dac7e  bl 0x503db35c (bx r2)
lr = 0x503dac83
```

对象来自 EStart constructor `0x503db640 -> slot 0x5034c638`
（静态值 `0x5034c74d`）。把该 slot 重绑到 EUser CBase constructor
`0x50383c84` 没有改变结果，说明真正的 EStart 对象 constructor 还没
找到。进一步看，`r5=0x80600000` 的分配来自
`0x503dac48 -> 0x503db560 -> slot 0x503b4f14`（静态值
`0x503a35b4`）；把这个 slot 也重绑到 `0x50383c84` 仍不改变，
所以它不是 CBase-style constructor。framebuffer 仍 0 像素。验收：
`tools/test_round70.sh`。

### round 71：EStart global CBase rebind

`0x503b4338` 是 EStart 的 global-object/CBase getter。ROM slot 是
`operator new`（`0x503963dc`），返回 zero-vtable 内存。把它也重绑到
`0x50383c84` 后：

```
app import rebind: 0x503b4338 0x503963dc -> 0x50383c84
stop: pc left the image (5) at 0x00a04d08
insns=13162
mmio: 1720 reads, 0 writes
```

EStart 越过 zero-vtable 对象，新 frontier 是 `0x503ce69c` 的
`bx r1`，`r1=0x00a04d08`（不是代码），`lr=0x503ce6a1`。
`r1` 来自 `[r0+0xc]`，而 `r0=[r4+0x14]`；说明 forced generic CBase
vtable `0x503b359c` 不是 EStart 真实 class vtable。

`config/imports-estart-6600.txt` 现在含两个 rebind；
`config/imports-estart-nocbase-6600.txt` 保留 round-70 历史路径。
验收：`tools/test_round71.sh`。

### round 72：app import slot / EUser export 的 2-entry offset

slot `0x503b4338` 并不是 EUser export 745：

```
slot 0x503b4338 静态值 = export 745 = 0x503963dc  (operator new)
app 期望               = export 747 = 0x50383c84  (CBase constructor)
```

两者相差 2 个 entry。这解释了为什么 ROM slot 里是 operator new、而
SplashScreen 和 EStart 都需要把该 slot 重绑到 `0x50383c84`。验收：
`tools/test_round72.sh`。

### round 73：bad dispatch 是 service-start handshake

round-71 的 `0x503ce69c` 调用来自 EStart `0x503da74a -> 0x503db3dc`，
slot `0x503cf984` 的值是 `0x503ce691`。EStart 传的是 stack descriptor，
而 ROM 函数把它当 CBase 对象读 `[obj+0x14] -> [0xc]`。

把该 slot HLE 成 zero-return stub 后：

```
stop: budget (0) at 0x50314f78
insns=200000
mmio: 1720 reads, 0 writes
framebuffer: 0 non-zero bytes
```

EStart 又回到 wait loop（handle `0x32`）。所以这条 bad dispatch 属于
**service-start handshake**，不是绘制调用；下一步需要 minimal
thread scheduler / server model，而不是继续找像素路径。验收：
`tools/test_round73.sh`。

### round 74：nested SVC return fix

EStart 的 wait 从 **SVC mode** 进入 SVC。`exception_enter` 把 SVC bank
LR 覆盖成 PC+4，handler 的 `mov lr,pc` 又覆盖寄存器，`movs pc,lr`
无法恢复 caller，最终在 `0x50314f78` self-loop。

新增 `NK_NESTED_SVC=1`：nested SVC 保留 caller LR，`movs pc,lr` 通过
bank LR 返回 caller。结果：

```
stop: budget (0) at 0x50398660
insns=200000
mmio: 1720 reads, 0 writes
framebuffer: 0 non-zero bytes
```

EStart 的 wait 返回后停在 `0x50398660` 的 wait-status check，不再撞
`0x50314f78` 的 pre-handler self-loop。下一步是完成该
TRequestStatus。验收：`tools/test_round74.sh`。

### round 75：wait 退出后立即重试 StartThread

把 wait-status loop 分支 `0x50398664` NOP 掉后，EStart 退出 wait，
但立刻回到 `0x503998b0` 的 `RThread::Resume/StartThread`（SVC 0x76，
handle `0x32`）。说明这个 wait 等的是**真实启动的线程**，不是单纯
status 写完。下一步需要给 handle 0x32 一个 DThread/server 对象，而
不是继续 HLE status。验收：`tools/test_round75.sh`。

### round 76：DThread clone 仍不能完成 wait

B7e 的 object-index fetch 对所有 handle 返回当前 DThread
（`0x80003000`）。在 `0x80004600` 克隆一个同 vtable/process/request/
objidx 的线程并接到 fetch literal `0xffff041c`，EStart 仍停在
`0x50398660`，`[r5]=0x80000001`（KRequestPending）。说明缺的是
**真实 request/server completion**，不是另一个 DThread 形状的对象。
验收：`tools/test_round76.sh`。

### round 77：direct dispatch 仍撞同一 handshake

把 SVC 模型切到 `NK_SWI_DIRECT=1`（并 model SVC 0x4d complete），
EStart 仍停在 `0x00a04d08`，12,305 条、1,719 次 MMIO 读、
framebuffer 0。说明 EStart 的 blocker 是 **service-start
handshake**，与 banked SVC/exception 模型无关；下一步仍是真实
request/server completion。验收：`tools/test_round77.sh`。

### round 78：fake scheduler thread 进入 EStart server entry

新增 `NK_SCHED_FAKE=1`：在 `0x80004600` 预建 scheduler slot 并把
`[0x80000400]` 指向它；`NK_SCHED_ENTRY=0x503db158`、
`NK_SCHED_STACK=0x80560000`。EStart wait 时 scheduler 不再报
"no runnable thread"，而是切进 server entry。

该 entry 跑约 100 条后在 `lr=0x503db18f` null-call：

```
0x503db18a  bl 0x503db454   ; slot 0x503b3d14 -> 0x503a2960
pc = 0
```

新 frontier 是该 server import/argument，不是 scheduler 切换。
framebuffer 仍 0。验收：`tools/test_round78.sh`。

### round 79：scheduler auto-complete 让 EStart server 跑满 200k

新增 `NK_SCHED_AUTOCOMPLETE=1`：切线程后完成 blocked thread 的
status 并重新标 runnable。用 server body entry `0x503da675` +
`NK_SCHED_R0=0x8057ffc8`，EStart server 在自己的线程里跑满
200,000 条，最终停在 `0x5038d724` 的 LDMDB/STMDB copy loop：

```
destination 0x65d8b834 / 0x4b6d61f8
mmio: 646007 reads, 642561 writes
framebuffer: 0 non-zero bytes
```

scheduler/server 路径已通，新 blocker 是 server 的 copy
length/destination。验收：`tools/test_round79.sh`。

### round 80：Mem::Copy clamp 让 server 越过 wild copy

新增 `NK_MEMCOPY_CLAMP=1`：在 Mem::Copy `0x5038cfe0` 把
length > 0x100000 或 src/dst 在 `0x50000000..0x80a00000` 之外的
copy clamp 成 0。server 不再陷入 200k MMIO storm，而是推进到
**26,652 条 + 3,441 次 MMIO 读 / 22,928 次写**，停在新的 null call：

```
lr=0x503da6d5
r3=0xe59ff028
framebuffer: 0 non-zero bytes
```

新 frontier 是该 server import，而不是 copy loop。验收：
`tools/test_round80.sh`。

### round 81：fake stack sentinel 不足

新增 `NK_SCHED_STACK_FILL=0xdead0000`，把 fake thread stack 填成返回
sentinel。EStart server 仍在 `0x503da6ee` 的 epilogue `bx r0`
null-call（r0=0），因为 `sp=0x80562020` 已超出 fake stack
`0x80560000..0x80562000`。说明该 entry 需要真正的 StartThread
frame/callback，而不是 sentinel。framebuffer 仍 0。验收：
`tools/test_round81.sh`。

### round 82：server run/return cycle 完成

新增：

- `NK_SCHED_STACK_EXTRA`：在初始 sp 之上额外映射/填充 sentinel；
- `NK_SCHED_EXIT`：fake thread 返回到 `0xdead0000` 时 retire 它并恢复
  supervisor。

结果：

```
server returns to 0xdead0000 (26,652 insns)
sched: slot 0x80004600 state=0
supervisor resumes and hits 0x00a04d08 (29,295 insns)
mmio: 3441 reads, 22928 writes
framebuffer: 0 non-zero bytes
```

server 运行/返回链路已通；下一 blocker 仍是 supervisor 的
`0x00a04d08` 虚拟调用。验收：`tools/test_round82.sh`。

### round 83：supervisor bad dispatch 不能简单 HLE

把 slot `0x503cf984` HLE 成 zero-return stub 后，supervisor 从
`0x00a04d08` 推进到 **30,815 条**，但进入 EUser TTrap/leave 路径，
在 `lr=0x5038cb70`（`r1=0xfffffff8`）null-call。返回 0 不是有效
路径；下一 blocker 是该 dispatch 需要的 supervisor object/argument。
framebuffer 仍 0。验收：`tools/test_round83.sh`。

### round 84：EUser slot neighbor sweep 也不绘制

把 slot `0x503cf984` 依次换成相邻表项 `0x503ce719`、
`0x503c9e99`、`0x503c9c2d`，结果都在 30k–31k 条 null-call 或回到
`0x00a04d08` leave，framebuffer 仍 0。说明 blocker 是 supervisor
object/argument，不是单个 slot target 选错。验收：
`tools/test_round84.sh`。

### round 85：supervisor 把 stack params 当 CBase

在 `0x503ce69c` 处：

```
this = 0x8057ffd8
[this+0x14] = 0x503da4cd   ; 代码返回地址，不是 vtable
```

EUser 函数把 EStart 的 stack params block 当成 CBase，读
`[this+0x14+0xc]` 得到 `0x00a04d08`。下一 fix 是构造/传入真实
CBase，而不是换 slot target。framebuffer 仍 0。验收：
`tools/test_round85.sh`。

### round 86：只换 vtable 指针仍会 leave

新增 `NK_SUPERVISOR_OBJECT_FIX=1`，在 `0x503ce696` 把
`[this+0x14]` 写成 B7e vtable `0x80003040`。`0x00a04d08` 消失，
但 `+0xc` 变成 zero-return stub，supervisor 仍在 30,988 条进入
EUser TTrap/leave，`lr=0x5038cb70`（`r1=0xfffffff8`）。
需要真实 class vtable/method，而不只是一个合法指针。framebuffer
仍 0。验收：`tools/test_round86.sh`。

### round 87：真实 vtable/method 也救不了 stack params

把 `[this+0x14]` 指向 `0x503b36d0`（+0xc 是真实方法
`0x5038681c`），supervisor 仍在 30,852 条 null-call；
`0x503b3518`/`0x503b3410`/`0x503b35a0` 也失败，framebuffer 仍 0。
问题不只是 vtable 指针：`this` 是 EStart 的 stack params block，不是
class 实例；需要真实对象实例（连同字段）。验收：
`tools/test_round87.sh`。

### round 88：global CBase 当 this 也失败

新增 `NK_SUPERVISOR_THIS`。强制 `this=0x80600008` 时 supervisor 在
29,295 条跳到数据地址 `0x80000500`；`this=0x80600000` 则
null-call。两者都无 framebuffer 像素。global CBase 也不是所需对象；
必须恢复真实 class instance/server response。验收：
`tools/test_round88.sh`。

### round 89：callback 收到 stack params，不是 CBase

watch `0x503da6f0`：

```
0x503db2dc -> 0x503da6f0
r0 = 0x8057ffc8, r1 = 0xd
[0x8057ffc8] = 0, 0x28e59ff0, 0x28e59ff0, 9, ...
```

该函数期望 `this`，但回调传的是 EStart 的 stack params block，于是
后续 EUser 把 `[this+0x14]` 当 vtable，落到 `0x00a04d08`。
callback/object ABI 不匹配；需要真实 server/class instance。
验收：`tools/test_round89.sh`。

### round 90：更正 —— EStart 的真实 main 与 import map

静态分析（离线）确认：

- EStart 的静态构造遍历器 `0x503da4a4` 调用真实 main **`0x503db29c`**；
- main 在栈上建 **0x24 字节 params block**，以 `r0 = sp` 依次调用
  14 个子步骤（共 21 处 `bl`）；这些是接收 params 的**自由函数**，
  不是 `CBase` 方法；
- 所以 round 78 起 fake scheduler 线程把 params 当 `this` 传入，
  才产生“stack params as CBase”的现象 —— **round 85–89 的结论撤回**；
- EStart 的 56 个 thunk 分三组：30 个 EUser、**12 个 EFSrv.dll**
  （`0x503cf918..0x503cfcdc`，uid3 `0x100039e4`，241 exports，
  romfs `EFSrv.dll`）、以及 `0x5034c6xx`/`0x503b6b30`；
- 3 个槽未解析：`0x503cfcd8`、`0x50a1f06c`、`0x50a1f070`；
- **30 处调用进入 EFSrv 槽**（open/write/read/mount），EStart 的多个
  子步骤都在做文件 I/O。

真正的 blocker 是 **EFSrv 文件服务器不可用**，不是对象 vtable。
验收：`tools/test_round90.sh`。

实验配置放在 `config/imports-app-main-6600.txt`；默认
`config/imports-app-6600.txt` 仍只做 round-63 的 CBase rebind。
framebuffer 仍然没有 app 像素。验收：`tools/test_round64.sh`。

## 8. BitGdi 导出符号表（round 59）

ROM BitGdi 的 export dir（`0x506a7e78`，185 项）只有地址，没有名字。
匹配的 S60 2.0 SDK `bitgdi.lib` 在 symbol table 里按 **export 顺序**
保存了 mangled 名字，因此 symbol i -> export i：

```
idx 147 0x5069a991 DrawBitmap(TPoint, CFbsBitmap*)
idx 148 0x5069a9b5 DrawBitmap(TRect, CFbsBitmap*, T1)
idx 149 0x5069a9d9 DrawBitmap(TRect, CFbsBitmap*)
idx 164 0x5069a029 Clear(TRect)
idx 165 0x5069ec5d Clear()
```

`BitBlt` 的尾部索引（171-174）混入了 DLL-ref entry，不可靠；上面的
drawing 入口是可用的。`tools/bitgdi_symbols.py` 可复现映射。

下一步：构造一个 data pointer 指向 `0x59800000` 的 `CFbsBitGc` /
`CFbsBitmap`，调用 `Clear`/`DrawBitmap`，得到 guest 自己绘制的帧。

round 60 先试了 `CFbsBitmap::Create`（FbsCli export 147，
`0x5068cb91`）：在 zeroed guest object 上调用，进入 FbsCli 代码后撞到
未解析 veneer `0x506dd80c`，加载 placeholder `0xe59ff028` 并跳过去
（`lr=0x506dd80d`）。所以 BitGdi/FbsCli 的构造函数也需要同一个
**ROM-loader import fixup**；仅有符号表还不够。

## 9. 还缺什么

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

## 10. 下一步

1. 修直接 FbServ 的对象初始化：跑 `.init_array`/constructors，或让
   kernel 的 process loader 正常启动 FbServ。
2. 修 `RThread::Resume(0x32)` / thread-start completer（见 BOOT.md
   2.11），让 kernel 路径也能继续 Init2/Init3。
3. 跟踪 `FbServ.exe` 的入口与 `FbsCli.dll` 的 `0x59200000` 引用，
   确认 variant 对象的 HAL id。
4. 确认 LCD 寄存器窗口后实现 HLE，并在 guest 第一次提交 framebuffer
   时抓帧（PPM/PNG），而不是用宿主图案代替。
5. 把 round-61 的 MBM 解码 HLE 换成真实的 FbsServ/`CFbsBitmap` 路径，
   让 SplashScreen 自己加载并提交同一帧；当前帧是 bring-up 里程碑，
   不是完整的 app-driven splash。
6. 修共享 EUser export table：给 kernel 使用 per-consumer import table，
   或建立 app EUser import-name map，避免 kernel K-3 relocation 改写
   app 的 import slots。
7. 修 EwSrv jump table / literal relocation：round 62 的
   `0x506ca5e4` 和 `0x506cd866 -> 0xb5f00000` 都是未重定位指针。
8. callback/object ABI 不匹配（round 89）：`0x503da6f0` 期望
   CBase，但 `0x503db2dc` 传 stack params。需要真实
   server/class instance，或改走 kernel process loader。

### round 91：ROM 启动链与 kernel object index 为空

方案 3 的事实基础：

```
ekern.exe -> EFile.exe -> EFSrv.dll -> EStart.exe -> Starter.exe -> SplashScreen.exe
```

EStart 的 12 个 EFSrv 槽必须等 `EFile.exe` 起来；单独驱动 EStart
画不出帧。kernel boot 中 handle→object 查找（EUser slot
`0x503b3948` → `0x5038e4b4`）使用 index `0x80600e98`，其 `+8` 计数
为 0，**所有 handle 查找返回 0**，handle `0x32` 无法解析。
第一项任务：按 `CObjectIx::AddL` 填充该 index。验收
`tools/test_round91.sh`。

### round 92：kernel 自己不会启动下一阶段

460k 指令实测：timer 只起火 1 次（reload 0x632ea，~430k），kernel 进入
设计内的 idle；`Kern::Init2` 尾部是重试等待循环，harness 完成 status
只是在 `0x50330a98` 反复 ping-pong；全程只有 2 个 DThread，
**没有创建任何 DProcess/EFile/EStart**。缺的是 mask ROM 的 boot
hand-off，方案 3 必须由 harness 自己执行。验收
`tools/test_round92.sh`。

### round 93：线程入口 Thumb 位修复，EFile 跑进 kernel

首次切换原先固定把新线程设为 ARM 模式，忽略 E32 `iEntryPoint` bit 0。
修复后 `EFile.exe`（entry `0x503b7105`）执行 **1,120 条 Thumb 指令**、
访问 `0x40000400`/`0x40000418`，停在 kernel panic halt `0x50312b88`
（修复前是 9 条 ARM 垃圾指令后的 null call）。下一 blocker 是该 panic。
验收 `tools/test_round93.sh`。

### round 94：EFile 越过 kernel start hand-off

`NK_HANDOFF_ARM=1` 在 kernel start hand-off `0x50318398` 前重新 armed
`[0x80001784]`，消除 PLAT fault `0x73`（原 halt 在 `0x50312b88`）。
`NK_ALLOC_MAX`（默认 `0x100000`）把 EFile 的指针型 `ReAlloc`
（`0x503c7168` 字节）变成干净失败。EFile 现在跑进 EUser 堆代码，并在
`0x2c` 离开 image。另加 `pc_hook3/4`、`NK_SCHED_MODE=auto|arm|thumb`。
验收 `tools/test_round94.sh`。

### round 95：kernel 期 import rebind 泄漏到 app 线程

EUser 导出表同时是 ROM 镜像的 import slot 表。kernel map 重绑了 236 个
槽，app 也走这些槽 → 调到错误的 EUser 函数，把代码地址/ctor 表当长度，
缓冲区涨到 `0x503c7168` 字节。`NK_IMPORTMAP_REVERT=1` 在第一个 app
线程恢复时写回原值：control 仍报 `HLE alloc rejected: 0x503c7168`，
revert 运行无异常分配，EFile 在 868 条 Thumb 指令后进入阻塞等待。
验收 `tools/test_round95.sh`。
