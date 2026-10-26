# 开发进度与路线图 — Nokia 6600 (NHL-10)

最后更新：2026-10-26（round 94）
目标：把 **NHL-10 v5.53.0** 固件静态重编译成可在 macOS / Linux 上原生运行的
6600；最终里程碑是启动到 Nokia 开机画面 / 待机 UI。

> 本文只保留**当前事实、地址表与下一步**。逐轮开发细节在 git 历史中
> （提交信息为 `Round N: ...`），不再在文档里重复。

---

## 1. 当前基线

| 项 | 内容 |
|---|---|
| 原始固件 | `fw/NHL105530.C1`（WD2 BT2 / WD2 ALGORITHM，23.3 MB） |
| 原始 ROM | `6600_mcu.bin`（23,285,596 字节；`rom_size` = `0x1600000`，base `0x50000000`） |
| Kernel | code `0x50310000`，entry `0x50310054`（ARM），`text_size=0x28ac0`，header `0x5030ff9c` |
| Kernel 资源 | `iStackSize=0x4000`，`iHeapSizeMin=0x20000`，`iHeapSizeMax=0x1000000` |
| CPU | ARM920T / ARMv4T（ARM + Thumb），UPP_WD2 |
| OS | Symbian OS 7.0s / S60 2nd Edition |
| 打包格式 | flash `0x20b0` 起为 852 条 `0x20ec` 记录 = `0xec` page header + `0x2000` payload；去头 stream `0x1605ed8` 字节 |
| 扁平静像 | `romimage.py build`：**725 image / 1,847 section**（无重叠）；`--place-rodata` 为 726 / 2,335；174 个 ROMFS E32Image + 85 个 AIF/MBM |
| ROMFS | root / `\System` / `\System\Libs`（586）/ `\System\Programs`（55）/ `\System\Libs\Plugins`（171）/ 63 个 `\System\Apps` 目录 |

---

## 2. 当前状态

### 已打通

- **固件与镜像**：WD2 解包、EKA1 header、kernel E32Image、ROMFS 目录树、
  扁平 runtime image。
- **布局**：page-header 去除后 packed text 就是 linked text；kernel export
  469/478（98.1%）落在函数起点，EUser DLL 1757/1788（98.3%）。
- **解释器**（`runtime/src/nokia_interp.c`）：ARM + Thumb、条件码、移位、
  load/store、LDM/STM、MUL/MLA、**UMULL/UMLAL/SMULL/SMLAL**、MRS/MSR、BX/BLX、
  SWI call gate、banked 模式、CP15；带恢复、调用点修复、watch/spin/PC 守卫。
- **导入/IAT**：全镜像 1,111 个 stub；kernel 257 个（236 EUser + 21 ELocl）。
  kernel→EUser 是固定 **-3** 重定位（`K>=6` → ROM export `K-3`），
  boot profile 为 232 个 K-3 + 1 个 local exception（K=1361），ELocl 的唯一
  hole 由 `config/imports-6600.txt` 绑定。
- **启动状态**：super page hand-off、初始 TStack、初始 TTime、`CTrapCleanup`、
  thread→process→CObjectIx 图、HAL/RTC/allocator stand-in。
- **忠实启动到 idle loop**：`NK_SYSTEM_TIME=1` +
  `config/imports-r29-6600.txt` 运行 **3,000,000 条、0 undefined、
  0 unbound IAT、0 recoveries**，停在 `0x50310f84` 的 idle 等待循环。
- **真实 IRQ + UPP timer**（round 30）：`Kern::Init1` 自己把 UPP timer 0
  （`0x58120a00`）设为 periodic、reload `0x632ea`；到期后模型拉起 **IRQ 1**，
  ICU 当前中断号 `0x58120114` = 1。CPU 在 `CP15.V=1` 下进入
  `0xffff0018` → `Kern::Irq`（`0x50311194`）→ handler 表 `0x5d`
  （对象 `0x80000b5c`）→ `0x50310ee0` 置 `[0x8000000c]=1`。
  idle 在 **430,557 条**退出，**1 次 IRQ、0 fault**。
- **timer-queue 单例 `[0x80001c34]`**（round 31）：kernel export 451
  （`0x5032aff8`）是抽象基类构造，安装 vtable `0x503383bc`；`+0x1c`
  是纯虚槽（`User::Panic`，K=1610 → `0x50389848`），由 mask-ROM/HAL 的
  具体子类覆盖为硬件 tick getter。harness 在 `0x5031ef40` 之前用 kernel
  自己的构造器创建对象，并把 `+0x1c` 覆盖为零返回 getter；`Kern::Init1`
  因此跨过 round-30 的 null call，继续 **439,177 条**（1 IRQ、0
  undefined/unbound/recovery）。这是 round-31 的历史 frontier；round 32
  修正线程身份后继续到 439,534 条。

- **live thread 身份与 TTrap**（round 32）：`TTrap` 布局已对齐
  （`iState[0x10]` +0x00、`iNext` +0x40、`iResult` +0x44、`iHandler` +0x48），
  `0x503a6120` 是 `TTrap::UnTrap`。round-31 的 null call 根因不是布局，而是
  **线程对象选错**：bootstrap `SThread` 在 boot stack 的 `0x802ffd00`；
  `0x5031e594`（现有文档称 `Kern::Init1`）返回堆上的真实 `DThread`
  `0x80601078`，但 B7e 的
  live-pointer 上界硬编码为 `0x80400000`，把堆线程判成 transient，
  继续发布 `0x802ffd00`。随后 EUser 的 0x108 字节 `TFullName`
  （"Supervisor"，`0x802ffcec`）覆盖了栈上 SThread 的 `+0x38/+0x3c`，
  UnTrap 才弹出 ROM 文本 `0x503a43c4`。把上界改为实际映射堆顶
  `0x80a00000` 后，`[0x800017d4] = 0x80601078`，handler 为
  `0x80004200`，UnTrap 弹真实栈 frame `0x802fff94` 并成功返回。
- **第一个阻塞 executive call**（round 32）：cleanup frame 之后，
  kernel-start 路径把 `[0x80001784]` 指向栈上的 `TRequestStatus`
  （`KRequestPending = 0x80000001`），调用 EUser K=1208
  （`0x50398644`，`svc #0x4d`）等待任意 request。harness 的 SWI 0x4d
  完成 HLE 只是清 slot、不写状态，request 仍 pending；kernel 在
  `0x50330aa8` 触发 **KERN 6** panic，halt 于 `0x50312b88`。
  这是 round-32 的 exact frontier：没有 scheduler 去运行 `0x5032fa10` 创建的
  NULL 线程（对象 `0x80601830`）。

- **第一次调度切换**（round 33）：重新读取 `svc #0x4d` 的真实语义。
  kernel service table `[0x4d] = 0x503244e4` 不是“完成请求”，而是
  `CurrentThread()->[0x5c]->vtable[0x20]`，即请求信号量上的 Wait；
  `0x503311c8` 用构造器 `0x50320ac0` 在 `DThread+0x5c` 安装这个信号量。
  NULL 线程的真实入口是 `0x5031f144`（`0x5032faf4` 字面量），对象
  `0x80601830`，栈 0x2000。DThread vtable `+0x20`（`0x50321088`）→
  `0x50318398` 完成待决的 `TRequestStatus` 并发布新线程。
  `NK_SCHED=1` 在 Init2 的 wait（LR `0x50330a98`）保存 supervisor 上下文、
  在 0x2000 栈上从真实入口启动 NULL 线程、保持 `[0x80001784]` 有 pending
  status 让每次 `Kern::StartThread`（`svc #0x76` → `0x503312d4`）交接成功，
  并在交接唤醒 supervisor 后立刻抢占回来。supervisor 在 `0x50330a98`
  以 `[sp]==0` 恢复，**KERN 6 不再发生**；boot 前进到 **440,623 条**，
  新 stop 是 `0x503360d4`（LR）的 null call：Init2 继续用 EUser
  `RThread::Create`（`0x5032e300`）创建线程时，B7e 单线程
  `CObjectIx` 模型不足。

- **保留 kernel 自己的 live 对象图**（round 34）：round-33 的 null call
  是 B7e 自己造成的。每次发布 current thread 时，hook 都会覆盖
  `DThread+0x18`（真实 `DProcess`）、`+0x5c`（真实请求信号量）、
  `+0x64`（真实 `CObjectIx`）。`NK_B7E_LIVE=1` 只在字段为空时补
  stand-in；于是 `0x80600d48 / 0x806019e0 / 0x806019c0` 保留下来，
  `0x5033606c` 的 CObjectIx 关闭路径调用真实 vtable `0x503b36f8`，
  `0x503360d4` 的 null call 消失。
- **TRequestStatus 完成即唤醒**（round 34）：NULL 线程第二次
  `Kern::StartThread` 交接直接把 0 写进 supervisor 的
  `TRequestStatus`（`0x503183b4`），不再触碰 harness dummy 页。旧的
  “只有 dummy 页被写才抢占”模型漏掉这次唤醒，NULL 线程于是用空
  request 做第三次交接并 panic `PLAT 0x73`。scheduler 现在每条指令
  边界轮询保存的 status，完成后立即把 supervisor 置为 runnable 并
  抢占（日志 `supervisor status 0x802fff8c completed`）。
- **`Kern::Init3` 的 HAL gate**（round 34）：Init3 取 HAL object 3，
  发 `Request(0xd)`，然后轮询 `[0x800004cc]`。stand-in device 显式
  完成该请求（真实驱动在 mask ROM 中），boot 通过该 gate。
- **banked 异常栈不再与 SVC 栈重叠**（round 34）：supervisor 的 SVC
  栈会超过 0x30 KiB；历史布局把 IRQ 栈放在它下面，IRQ frame 会覆盖
  被中断函数的 saved LR，返回时 `PC=6`。live 模式把异常栈放在 RAM
  低地址（`irq=0x801c0000`），并让 preset bank stack 保持权威。
- **稳定 6M 指令运行**：`NK_B7E_LIVE=1 NK_SCHED=1 NK_BUDGET=6000000`
  运行 **5,999,982 条、14 次 timer IRQ、0 undefined、0 unbound IAT、
  0 recoveries**，停在 executive timing 循环 `0x5032211c`。

- **hand-off 完成与死锁定位**（round 35）：6M 的“稳定”其实是
  **死锁**。scheduler 在 `0x503183bc` 抢占 NULL 线程，位置在
  `Kern::StartThread` hand-off **内部**，因此 supervisor 的下一个
  `TRequestStatus` 永远没人消费。`NK_SCHED_DEFER=1` 把抢占推迟到
  hand-off 返回到 `0x5033130c`；supervisor 在两次 wait 之间从
  441,434 推进到 460,289，再到 463,666/464,336。最终状态仍死锁：
  - `pending-slot=0x802fff8c`
  - supervisor `state=3 status=0x802fff8c val=0x80000001`
  - NULL `state=2 pc=0x5033130c`
  - 只有两个 `DThread`（`0x80601078`、`0x80601830`）
  - timer queue `[0x80001c34]` 为空
  说明 CPU/显示路径没问题；缺的是 handle `0x32` 的 thread-start
  completion 或 DFC 线程。

- **MMIO 写来源**（round 36）：MMIO 写日志现在带 `pc`/`lr`，16-bit
  store 也能看到。`0x41080000..0x41083fff` 的 0xffff 填充不是 LCD
  framebuffer，而是 kernel 的 boot-region descriptor table：源表在
  `0x41000000`，复制到 `0x41080000`；写入点是 `0x503164cc`（来自
  `0x503163f4` 的扫描）。这条线索被排除，display driver 仍需从真正的
  UI/显示路径找。

- **显示链静态清单**（round 37）：ROMFS 的显示链已经固定：
  `FbServ.exe` @ `0x50689770`（uid3 `0x10003a16`）、
  `FbsCli.dll` @ `0x5068c150`、`BitGdi.dll` @ `0x50698080`、
  variant 驱动 `ecust.dll` @ `0x50339750`。`ecust.dll` 代码引用
  `0x59E00010` 与 `0x59200000` 两个硬件窗口，仍需确认是 LCD/DMA/
  audio/keypad。第一帧需要先启动 FbServ 进程，再做 LCD HLE；详见
  [DISPLAY.md](DISPLAY.md)。

- **直接启动 FbServ**（round 38）：kernel 路径仍卡在 handle `0x32`，
  harness 新增直接入口：`NK_ENTRY=0x506897d5 NK_SP=0x80580000`。Thumb
  `NK_ENTRY` 现在会强制 `CPSR.T=1`，不再被 `NK_CPSR=0x40000053` 清掉。
  FbServ 跑 **3,612 条、0 undefined、0 unbound IAT**，到
  `0x5068a572` 的对象初始化；对象 `0x80600018` 的 vtable 是
  `0x50680000`，`[vtable+8]=0x068a0689`，PC 逃到 `0x068a0688`。
  这说明直接入口没有跑 FbServ 的 constructors/DLL imports。下一步补
  这部分，或改用 kernel process loader。详见 [DISPLAY.md](DISPLAY.md)。

- **FbServ vtable 被覆盖**（round 39）：byte/halfword store 现在也进
  write watch。FbServ 构造函数在 `0x5068a5c8` 写入 vtable `0x5068c0a4`，
  随后 EUser descriptor 代码在 `0x5038bc6c` 写 `[object+1]=0`，把值变成
  `0x50680000`；`[0x50680008]=0x068a0689`，调用逃到 `0x068a0688`。
  对象构造后被当作 `TDes8` 缓冲区复用，直接入口仍缺真实进程的
  C++/descriptor 状态。

- **descriptor/object 重叠**（round 40）：`0x80600018` 是 20 字节对象，
  构造函数装 vtable `0x5068c0a4`；随后
  `0x5068a4ee -> 0x5068b70c -> EUser 0x5038bc38` 的格式化路径把同一
  block 当作 `TDes8` 缓冲区，在 `0x5038bc6c` 写 byte，破坏 vtable。
  `NK_APP_STACK_CLEAR=1` 无效，descriptor header 是 guest 构造的。
  直接 FbServ 入口因此缺少真实进程的 user-side descriptor/thread
  context。

- **FbServ 真实 SVC 路径**（round 41）：`NK_SWI_DIRECT=0 NK_BANKED=1`
  时 direct-SWI 的 vtable 破坏消失，FbServ 从 3,612 条推进到
  **1,499,521 条**；切换到 kernel 分配的用户栈（约 `0x7fef....`），
  进入重复的 EUser wait 链
  `5039eddc -> 5039d9d0 -> 503998b4 -> 50392e00 -> 50392ec0`，
  最后 null callback。说明 direct-SWI gate 可能未保存 `r4-r11`；当前
  blocker 是 kernel executive/thread 状态。

- **FbServ 返回上下文损坏**（round 42）：第一次 watch `0x5039ee14`
  的 pop 时，栈上仍有正确的 saved LR `0x5039edc8`；最终经过
  `0x5039b05c` executive call 后，pop 才读到 0。失败点是
  thread/context（栈）切换，不是 push/pop 或 vtable。把 wait SWI
  `0x76..0x7b` 内联完成也不能修复 direct 路径（仍 3,360 条 /
  `0x068a0688`）。

- **真实 SVC exception 模型**（round 43）：`NK_SWI_DIRECT=0` 之前把
  `svc` 当 no-op，round-41 的 1.5M FbServ 实际从未进入 kernel。
  `NK_SWI_EXCEPTION=1` 现在真的进入 SVC vector `0xffff0008`，由 kernel
  handler `0x50314f30` 分发；handler 需要 `[0x80000f34]` 的 mask-ROM
  pre-handler，用 high-vector page 的零返回 hook 补上。kernel boot 跑
  11,114 条后返回 boot sentinel `0xdead0000`；direct FbServ 只跑 56 条，
  user-SVC 返回仍缺 current-thread 状态。

- **user/kernel SVC selector**（round 44）：FbServ 第一条系统调用是
  `0x50392b88 ef00006c`（`svc #0x6c`）。kernel handler 用 bit 23 区分
  user/kernel；flat image 把 app import 绑到 kernel-side EUser stub，
  handler 走 kernel 路径，app 只跑 56 条。给 stub 标 bit 23 后 handler
  从 dispatch table 取到 `0xe59ff028` 并跳到指令字，说明 user path 的
  table/entry 格式仍不对。下一步是修 import 绑定或 user SVC table。

- **稳定 real-SVC FbServ**（round 45）：三处 boot-state 修复后，
  direct FbServ + real SVC 跑满 **2,000,000 条**、0 fault：
  - USR bank SP 用 app 的 `NK_SP`，`stack_in_ram()` 跟随映射的 6 MiB；
  - B7e hook 在初始 fake thread 发布前安装，`+0x18/+0x5c/+0x64` 存在；
  - DFC queue `0x80001c28` 初始化为空。
  当前停在 `0xffff0008` / `0x5039865c` 的 `WaitForAnyRequest` 循环（等待
  客户端请求），不是 fault。direct-SWI 路径到 500k 预算，新 frontier 是
  `0x600000` 的 wild clear。

- **开机画面链路**（round 46）：ROMFS 里有
  `SplashScreen.exe`（uid3 `0x100059de`，entry `0x509eee85`）+
  `SplashScreen.mbm`、`EwSrv.exe`（uid3 `0x10003b20`，entry
  `0x506a8205`）、`EStart.exe`（`0x503da440`）。直接跑 SplashScreen 会
  进入 EwSrv 代码，在 `0x506cbf1c` 遇到数据/未初始化函数指针
  （`lr=0x509ef1ab`），不是 CPU 解码问题。下一步是 EwSrv 的
  import/vtable 初始化。direct 路径的 `0x600000` copy 是长度错误的
  数据 copy，不是 framebuffer。

- **稳定 SplashScreen**（round 47）：export slot `0x506ce7d0` 存
  `0x506cbf1d`，真正 Thumb prologue 在 `0x506cbf1e`，差 2 字节。
  `NK_EWSRV_SNAP=1` 做 Thumb +2 fixup 后，SplashScreen 跑满
  **2,000,000 条**、0 undefined/unbound/recovery，停在
  request-semaphore Wait service `0x503244e4..f4`。下一步是完成该 request
  或 HLE window-server draw 路径。

- **Splash wait / EwSrv blocker**（round 48）：`NK_WAIT_HLE=1` 完成
  `[r5]` 后，SplashScreen 离开 `WaitForAnyRequest`，但进入
  `0x5038d2d4` 的 wild descriptor copy（8-word expansion），跑到预算
  也没有显示绘制。直接跑 `EwSrv.exe`（`0x506a8205`）在
  `lr=0x506c0b15` null-call。round 62 归因：wild copy 的
  `0x484c4289` 长度来自 HLE allocator 的 `'HLEH'` cell header，不是
  window-server surface；修 header 后同一路径到达 EwSrv
  `0x506ca5e4`。

- **Splash MBM / EwSrv relocation**（round 49）：`SplashScreen.mbm`
  是 0xd54 字节 MBM，header `0x509efae0`：UID `0x10000041`、offset
  `0x10/0x8c0`、176×208、像素主要 `0x7fff`。stable 2M 运行后的 RAM
  dump 没有 MBM signature，app 还没加载 splash。EwSrv null call 来自
  veneer `0x506c15ee` 的坏字面量 `0x4a7846c0`，是 relocation/veneer
  问题，不是未绑定 import。

- **EwSrv 第一个 missing-DLL call**（round 50）：veneer `0x506c15ee`
  从缺失 DLL 载入 stale pointer `0x4a7846c0`。`NK_FIX_4A78=1` 在
  `0x4a780000` 映射完整 64 KiB page（page size 是 64 KiB），并把
  `0x4a7846c0` 指向 high-vector 的零返回 stub。EwSrv 执行
  `0xffff0d00 -> 0xffff0d04 -> 0x506c0b14`，越过第一个 call，随后遇到
  下一个 null pointer。

- **EwSrv 真实 prologue / packed veneer**（round 51）：call
  `0x506a821a` 编码 `0x506c0b0c`（函数中间），真实 prologue 是
  `0x506c0a4a`。`config/callmap-ewsrv-6600.txt` 做 call-site fixup
  （`NK_CALL_INFER=1`）。修正后 EwSrv 进入 prologue，但下一个 veneer
  `0x506c1dba` 的 literal 是代码/padding，不是 slot，属于
  packed/relocated veneer literal 问题。

- **EwSrv IAT vs unrelocated literal**（round 52）：IAT
  `0x506c9290` 有已解析地址（`0x506980e5/0x506a815c/0x503c9485`），
  但 veneer `0x506c1dba` 加载 `0x40b846c0`（代码/padding），不是 IAT
  slot。IAT 正常，问题在 app code 的 literal pool 没有被 flat image
  loader 重定位。这是 window-server bring-up 的 loader frontier。

- **LCD/framebuffer 基址**（round 53）：ecust 显示配置
  `0x5033abf4` 写入 LCD controller `0x59200000`、framebuffer
  `0x59800000`（+0x600000）。`NK_MAP_LCD=1` 映射 controller page +
  4 MiB framebuffer 并 dump。当前 stable SplashScreen 2M 运行不写
  framebuffer，dump 全 0；这是抓第一帧的 capture target。

- **kernel boot 也不写 LCD**（round 54）：带 `NK_MAP_LCD=1` 跑满
  6M，`0x59800000` 仍全 0，停在 `0x50312720`。kernel bring-up 没有
  到达 display driver/UI 层；window-server/app-loader 是缺口。

- **ROM image / DLL ref table**（round 55）：EwSrv header
  `0x506a81a0` 是 `TRomImageHeader`（entry `0x506a8205`、code
  `0x506a8204`、data `0x506c4c80`、iDllRefTable `0x506c9290`、
  iExportDir `0x506c928c`）。`TDllRefTable` flags=1、count=7，7 个
  imported-DLL entry 地址。flat image 没有应用 ROM loader 的 import
  fixup，veneer literal 是 placeholder。这是 window server 起不来的
  架构原因。

- **link-time literal relocation lead**（round 56）：坏 literal 看起来是
  link-time address。用 `0x4a780000` 作 link base，按每个 image 的
  `code - 0x4a780000` 平移 `0x4a7846c0`，会落在多个 image 的合法
  Thumb prologue 上（如 `uid 0x10003c77 -> 0x505bf774`）。`0x40b846c0`
  不匹配这个 base，说明每个 DLL 可能有自己的 link base。

- **EwSrv dllref section**（round 57）：`0x506c9290` 的 64 字节
  section 是 flags=1、count=7、7 个 DLL entry、0、6 个 DLL entry、
  `0xffffffff`。零后的 6 个 entry **不是** per-import IAT slot；
  指到 `0x506c92b8` 会进入 BitGdi 后 wild-jump 到 `0x5155a0ca`，
  其他 slot null-call。需要真实 ROM loader import fixup。

- **白色控制帧**（round 58）：harness 映射 LCD/framebuffer，guest
  `Mem::Copy`（`0x5038cfe0`）把 `0x80800000` 的 0xff 源复制到
  `0x59800000`，36,608/36,608 像素为 `0xffff`。渲染为
  [first_frame.png](assets/first_frame.png)。这是 framebuffer 管线的
  control 帧，不是 MBM 的实际内容。

- **BitGdi 导出符号表**（round 59）：ROM BitGdi export dir 有 185 个
  地址、无名字；匹配的 SDK `bitgdi.lib` 按 export 顺序保存 mangled
  名字。映射出 `Clear()` = `0x5069ec5d`、`Clear(TRect)` =
  `0x5069a029`、`DrawBitmap(TPoint, bitmap)` = `0x5069a991`。

- **bitmap 构造函数 blocker**（round 60）：`CFbsBitmap::Create`
  （FbsCli export 147，`0x5068cb91`）在 zeroed object 上调用，进入
  FbsCli 后撞到未解析 veneer `0x506dd80c`，加载 placeholder
  `0xe59ff028` 并跳过去（`lr=0x506dd80d`）。BitGdi/FbsCli 构造函数
  也需要同一个 ROM-loader import fixup。

- **Nokia logo 帧**（round 61）：真实 `SplashScreen.mbm` 的 bitmap 0
  不是全白，而是 176×208、8bpp EByteRLE8；解出 36,608 像素中有
  **1,449 个非白像素**，bbox `x=0..173, y=159..178`，即 NOKIA logo。
  harness 从 guest 内存 `0x509efae0` 读 MBM，解成 RGB565 写入 guest
  buffer `0x80800000`，再由真实 guest EUser `Mem::Copy` 写入
  `0x59800000`；帧的 RGB565 FNV-1a 为 `0xd10ed2d0`，copy 正常返回
  `0xdead0000`。结果：
  [nokia_logo_frame.png](assets/nokia_logo_frame.png)（3× 预览
  [nokia_logo_frame_3x.png](assets/nokia_logo_frame_3x.png)），
  验收 `tools/test_round61.sh`。MBM RLE 解码仍是 harness HLE；
  SplashScreen/FbsServ 自己的 `CFbsBitmap` 路径仍被 loader fixup 卡住。

- **app-driven 路径的三处地基修复**（round 62）：
  - HLE allocator 的 8-byte header 原来把 `'HLEH'` 放在 `[payload-4]`，
    而 guest `RHeap::ReAlloc`（`0x5039c37c` 的 `[ptr-4]` 读取）把
    它当成 cell size，产生 `0x484c4544` 字节的 wild `Mem::Copy`。
    现在 `[payload-8]` 是 HLE 私有 size，`[payload-4]` 是 guest cell
    header（`size+4`）。
  - SplashScreen 通过 EUser wrapper 调 `Kern::StartThread`（SVC 0x76）
    并轮询 `TRequestStatus`。bring-up DThread vtable+0x20 原来只返回、
    不完成 `[r3]`，app 永远 spin。`NK_START_HLE=1` 完成这个 status；
    `NK_USER_SVC_KERNEL=1` 清掉 EUser SVC 0x76 stub 的 bit 23，让
    kernel service table 真正 dispatch 到 StartThread。
  - `config/imports-r29-6600.txt` 的 kernel EUser relocation 会改写
    **共享** EUser export slots。例如 `0x503b4f10` 被 kernel 改成
    `0x5038918c`，而 app 链接的 export 是 `0x50389180`；app import
    因此拿到错误函数。这就是旧 app 测试（设置了 `NK_IMPORTMAP`）走到
    wild descriptor / 空 vtable 的根因。direct-app 运行不能应用 kernel
    map；需要 per-consumer import table 或 app EUser import-name map。
  - 修正后的 app frontier：static init 用 `operator new(4)` 在
    `0x80600008` 得到一个 vtable 为 0 的对象，随后 virtual dispatch
    读 `[0+8]` -> `0xe59ff028`，`lr=0x509eef1f`。下一步是 app EUser
    import 重绑（按 name/ordinal），或 per-consumer import table。
  - 验收 `tools/test_round62.sh`（含共享 slot 的 0-instruction dump）。

- **第一个 app-side EUser import rebind**（round 63）：SplashScreen 的
  import slot `0x503b4338` 期望一个 CHeartbeat 风格的构造器（对象建好后
  用 vtable+8、`r1=3` 调用），但 ROM slot 里是 `operator new`
  （`0x503963dc`，返回 zeroed object）。新增
  `config/imports-app-6600.txt` + `NK_APP_IMPORTMAP`，把该 slot 重绑到
  ROM export index 747（`0x50383c84`）。该函数分配 0x10 字节 CBase、
  安装 vtable `0x503b359c`、再分配 0x40 字节 backing store，并自己完成
  同样的 vtable+8/`r1=3` 调用。结果：app 静态初始化不再在
  `0x509eef12` 的零 vtable 上崩，构造出 `0x80600008`（vtable
  `0x503b359c`），360 条后干净返回 `0xdead0000`。仍无 framebuffer
  写入；真正的 splash main / active object 是下一步。
  验收 `tools/test_round63.sh`。

- **app main 路径与 kernel SVC-return blocker**（round 64）：
  - 第二个 app-side rebind：`0x503b4980`（app 的 TTrap wrapper）在
    ROM 里是 `0x50396ca8`（string helper），返回非零指针，使 app 认为
    初始 TRAP 失败并跳过 `0x509ef5fc` 的 splash main/constructor。
    把它重绑到 `0x5038cae8`（TTrap::Trap）后，app 确实进入 main 路径。
  - 该路径的**第一条** `User::Alloc` `svc #0x6c`（`0x503988f8`）其实
    正常返回：`0x50314f78 -> bx lr -> 0x503988fc`。真正的问题在后面：
    对 `0xe59ff028` 的 2 笔 MMIO 写（来自 `0x50383c74/7c`，调用点
    `0x50383ec0`，此时 cleanup/destination `r5=0xe59ff028`）之后，
    后续 SVC 才在 `0x50314f78` 形成 `bx lr` self-loop。
  - `NK_USER_SVC_KERNEL=2` 清掉 9 个 EUser SVC stub 的 bit 23，仍不能
    修复该 self-loop；它更像是 `0xe59ff028` descriptor/cleanup 目标先
    被写坏后污染了 SVC bank/LR，而不是第一条 SVC 的 return 语义。
  - 另外，kernel handler 实际读 `[0x80000f48]`（失败时为 0），而
    harness 的 svc hook 设在 `[0x80000f34]`；把 `[0x80000f48]` 设成
    `0xffff0b04` 仍未消除 self-loop，说明返回路径还有 SVC bank/SPSR
    问题。
  - `r5=0xe59ff028` 的来源已追到 main 路径的
    `0x509ef612 -> 0x509ef78c -> 0x50383e50 -> 0x50383e80`：
    进入 `0x50383e80` 时 **r0=0**、r1=`0x54442d18`，函数把 r0 当
    descriptor/TDes16Overflow 解引用 `[r0+0xc]`，从低地址读回
    `0xe59ff028`。所以问题不是 cleanup stack 溢出，而是 **null
    descriptor/overflow 参数**。

- **app low allocator rebind**（round 66）：null descriptor 的根因是
  `0x509ef5fc` 的 `operator new(0x68)` 走 EUser export index 2
  （slot `0x503b379c`）。app 链接的语义是 `User::Alloc`，但 ROM 原始
  slot 是另一个低 ordinal 函数并返回 0，于是 `r4=0`、格式化函数读到
  `[0+0xc]=0xe59ff028`。新增 `config/imports-app-main-alloc-6600.txt`，
  把 `0x503b379c` 重绑到 `0x503988f0`。结果：`0xe59ff028` 的 MMIO
  写完全消失，framebuffer 仍无像素；剩余 blocker 变成 app main 的
  StartThread/SVC 路径，仍在 `0x50314f78` self-loop。验收
  `tools/test_round66.sh`。

- **direct app entry 不是 splash 绘制路径**（round 68）：把 EwSrv slot
  `0x506ce44c` HLE 成 zero-return stub（`0xffff0300`）后，direct
  SplashScreen 入口不再撞 `0xb5f00000`，而是干净返回
  `0xdead0000`（1,694 条），但 **framebuffer 仍 0 像素**。这说明
  `0x509ef1e4` 的 EwSrv 调用只是初始化/清理，不是绘制；真正的开机
  画面必须来自 EStart、kernel 创建的 process/thread，或 active
  object，而不是直接跑 SplashScreen 的 E32 entry。验收
  `tools/test_round68.sh`。
  - EStart.exe 直接入口（`0x503da4a5`）是下一步的候选：它 119 条后
    在 `lr=0x503da5b9` null-call，`r5=0xe59ff028`，经过
    `0x503db628` stub 到 slot `0x503b6b38`。这是 EStart 自己的 import
    未绑定，不是 EStart 逻辑本身。该 slot 属于 uid3 `0x100039e8`
    （export_dir `0x503b6b38`，ordinal 2）；实际函数表在
    `0x503b6b30`，前两项都是 `0x503b53f5`，而 `0x503b6b38` 为 0。
    这又是一个 header export_dir/import slot 需要 loader fixup 的洞。

- **EStart 第一个 import 绑定**（round 69）：`config/imports-estart-6600.txt`
  把 EStart slot `0x503b6b38` 重绑到 uid3 `0x100039e8` 的真实 export
  `0x503b53f5`。结果 EStart 不再在 119 条时 null-call，而是跑满
  **200,000 条**，停在 kernel SVC/pre-handler 路径
  `0x50314f68`；`mmio: 0 reads, 0 writes`，framebuffer 仍 0 像素。
  下一步是它等待的线程/信号量事件。验收 `tools/test_round69.sh`。

- **EStart wait HLE 与 zero-vtable frontier**（round 70）：加
  `NK_WAIT_HLE=1` 完成 EStart 的 wait-any-request 后，EStart 从 200k
  spin 推进到 **12,136 条 + 1,720 次 MMIO 读**，随后停在一个
  zero-vtable 对象：
  `r5=0x80600000`，`[r5]=0`，`vtable+8 -> 0xe59ff028`，
  `lr=0x503dac83`。对象来自 EStart constructor
  `0x503db640 -> slot 0x5034c638`（静态值 `0x5034c74d`）。把该 slot
  重绑到 EUser CBase constructor `0x50383c84` 没有改变结果，说明
  真正的 EStart 对象 constructor 还没找到。进一步看，
  `r5=0x80600000` 的分配来自
  `0x503dac48 -> 0x503db560 -> slot 0x503b4f14`（静态值
  `0x503a35b4`）；把这个 slot 也重绑到 `0x50383c84` 仍不改变，
  所以它不是 CBase-style constructor。framebuffer 仍 0 像素。
  验收 `tools/test_round70.sh`。

- **EStart global CBase rebind**（round 71）：`0x503b4338` 是 EStart
  的 global-object/CBase getter，ROM slot 是 `operator new`
  （`0x503963dc`），返回 zero-vtable 内存。把它也重绑到
  `0x50383c84` 后，EStart 从 12,136 推进到 **13,162 条**，越过
  zero-vtable 对象；新 frontier 是 `0x503ce69c` 的
  `bx r1`，`r1=0x00a04d08`（不是代码），`lr=0x503ce6a1`。说明
  forced generic CBase vtable 不是 EStart 真实 class vtable。
  `config/imports-estart-6600.txt` 现在含两个 rebind；
  `config/imports-estart-nocbase-6600.txt` 保留 round-70 历史路径。
  验收 `tools/test_round71.sh`。

- **app import slot / EUser export offset**（round 72）：确认 slot
  `0x503b4338` 不是 EUser export 745，而是对应 export **747**：
  - slot 静态值 = export 745 `0x503963dc`（operator new）；
  - app 期望 = export 747 `0x50383c84`（CBase constructor）；
  - 两者相差 2 个 entry。
  这解释了为什么 ROM slot 是 operator new、而 SplashScreen 和 EStart
  都需要重绑到 `0x50383c84`。验收 `tools/test_round72.sh`。

- **EStart bad dispatch 是服务启动握手，不是绘制**（round 73）：round-71
  的 `0x503ce69c` 调用来自 EStart `0x503da74a -> 0x503db3dc`，
  slot `0x503cf984` 的值是 `0x503ce691`；EStart 传的是 stack
  descriptor，而 ROM 函数把它当 CBase 对象读 `[obj+0x14] -> [0xc]`。
  把该 slot HLE 成 zero-return stub 后，EStart 又跑满 200k，回到
  `0x50314f78` 的 wait loop（handle `0x32`），framebuffer 仍 0 像素。
  说明这条 bad dispatch 属于 **service-start handshake**；下一步需要
  minimal scheduler/server model，而不是继续找绘制调用。验收
  `tools/test_round73.sh`。

- **nested SVC return fix**（round 74）：EStart 的 wait 从 **SVC mode**
  进入 SVC，`exception_enter` 把 SVC bank LR 覆盖成 PC+4，handler 的
  `mov lr,pc` 又覆盖寄存器，导致 `movs pc,lr` 在
  `0x50314f78` self-loop。新增 `NK_NESTED_SVC=1`：nested SVC 保留
  caller LR，`movs pc,lr` 直接返回 caller。结果 EStart 的 wait 返回，
  停在 `0x50398660`（wait-status check），不再撞 `0x50314f78`。
  framebuffer 仍 0；下一步是完成 wait status。验收
  `tools/test_round74.sh`。

- **wait 退出后立即重试 StartThread**（round 75）：把 wait-status
  loop 分支 `0x50398664` NOP 掉后，EStart 退出 wait，但立刻回到
  `0x503998b0` 的 `RThread::Resume/StartThread`（SVC 0x76，
  handle `0x32`）。说明这个 wait 等的是**真实启动的线程**，不是
  单纯 status 写完；下一步需要给 handle 0x32 一个 DThread/server
  对象，而不是继续 HLE status。验收 `tools/test_round75.sh`。

- **DThread clone 仍不能完成 wait**（round 76）：B7e 的 object-index
  fetch 对所有 handle 返回当前 DThread（`0x80003000`）。在
  `0x80004600` 克隆一个同 vtable/process/request/objidx 的线程并把它
  接到 fetch literal `0xffff041c`，EStart 仍停在 `0x50398660`，
  `[r5]=0x80000001`（KRequestPending）。说明缺的是 **真实 request/
  server completion**，不是另一个 DThread 形状的对象。验收
  `tools/test_round76.sh`。

- **direct dispatch 仍撞同一 EStart handshake**（round 77）：把 SVC
  模型切到 `NK_SWI_DIRECT=1`（并 model SVC 0x4d complete），EStart
  仍停在 `0x00a04d08`，12,305 条、1,719 次 MMIO 读、framebuffer 0。
  说明 EStart 的 blocker 是 **service-start handshake**，与 banked
  SVC/exception 模型无关；下一步仍是真实 request/server completion。
  验收 `tools/test_round77.sh`。

- **fake scheduler thread 进入 EStart server entry**（round 78）：新增
  `NK_SCHED_FAKE=1`，在 `0x80004600` 预建 scheduler slot 并把
  `[0x80000400]` 指向它；`NK_SCHED_ENTRY=0x503db158`、
  `NK_SCHED_STACK=0x80560000`。EStart wait 时 scheduler 不再报
  "no runnable thread"，而是切进 server entry。该 entry 跑约 100 条后
  在 `lr=0x503db18f` null-call，经由
  `0x503db454 -> slot 0x503b3d14 -> 0x503a2960`，pc=0。
  新 frontier 是该 server import/argument，不是 scheduler 切换。
  framebuffer 仍 0。验收 `tools/test_round78.sh`。

- **scheduler auto-complete 让 EStart server 跑满 200k**（round 79）：
  新增 `NK_SCHED_AUTOCOMPLETE=1`，切线程后完成 blocked thread 的
  status 并重新标 runnable。用 server body entry `0x503da675` +
  `NK_SCHED_R0=0x8057ffc8`，EStart server 在自己的线程里跑满
  200,000 条，最终停在 `0x5038d724` 的 LDMDB/STMDB copy loop，
  destination 明显非法（`0x65d8b834` / `0x4b6d61f8`），期间
  646,007 次 MMIO 读 / 642,561 次 MMIO 写。这是新 frontier：
  scheduler/server 路径已通，server 的 copy length/destination 坏了。
  framebuffer 仍 0。验收 `tools/test_round79.sh`。

- **Mem::Copy clamp 让 server 越过 wild copy**（round 80）：新增
  `NK_MEMCOPY_CLAMP=1`，在 Mem::Copy `0x5038cfe0` 把
  length > 0x100000 或 src/dst 在 `0x50000000..0x80a00000` 之外的
  copy clamp 成 0。server 不再陷入 200k MMIO storm，而是推进到
  **26,652 条 + 3,441 次 MMIO 读 / 22,928 次写**，停在新的
  null call：`lr=0x503da6d5`、`r3=0xe59ff028`。framebuffer 仍 0。
  验收 `tools/test_round80.sh`。

- **fake stack sentinel 不足**（round 81）：新增
  `NK_SCHED_STACK_FILL=0xdead0000`，把 fake thread stack 填成返回
  sentinel；但 EStart server 仍在 `0x503da6ee` 的 epilogue `bx r0`
  null-call（r0=0），因为 `sp=0x80562020` 已在
  `0x80560000..0x80562000` fake stack 之外。说明该 entry 需要真正的
  StartThread frame/callback，而不是 sentinel。framebuffer 仍 0。
  验收 `tools/test_round81.sh`。

- **server run/return cycle 完成**（round 82）：新增
  `NK_SCHED_STACK_EXTRA` 在初始 sp 之上额外映射/填充 sentinel，以及
  `NK_SCHED_EXIT` 在 fake thread 返回到 `0xdead0000` 时 retire 它并
  恢复 supervisor。结果：
  - server 干净返回到 `0xdead0000`（26,652 条）；
  - scheduler 恢复 supervisor；
  - supervisor 在 **29,295 条**时又撞 `0x00a04d08` bad dispatch，
    期间 3,441 次 MMIO 读 / 22,928 次写。
  framebuffer 仍 0。说明 server 运行/返回链路已通，下一 blocker 仍是
  supervisor 的 `0x00a04d08` 虚拟调用。验收 `tools/test_round82.sh`。

- **supervisor bad dispatch 不能简单 HLE**（round 83）：把 slot
  `0x503cf984` HLE 成 zero-return stub 后，supervisor 从
  `0x00a04d08` 推进到 **30,815 条**，但进入 EUser TTrap/leave 路径，
  在 `lr=0x5038cb70`（`r1=0xfffffff8`）null-call。说明返回 0 不是
  有效路径；下一 blocker 是该 dispatch 需要的 supervisor
  object/argument，而不是 scheduler/server cycle。framebuffer 仍 0。
  验收 `tools/test_round83.sh`。

- **EUser slot neighbor sweep 也不绘制**（round 84）：把 slot
  `0x503cf984` 依次换成相邻表项 `0x503ce719`、`0x503c9e99`、
  `0x503c9c2d`，结果都在 30k–31k 条 null-call 或回到
  `0x00a04d08` leave，framebuffer 仍 0。说明 blocker 是 supervisor
  object/argument，不是单个 slot target 选错。验收
  `tools/test_round84.sh`。

- **supervisor 把 stack params 当 CBase**（round 85）：在
  `0x503ce69c` 处，`this=0x8057ffd8`，`[this+0x14]=0x503da4cd`
  —— 这是一个代码返回地址，不是 vtable；EUser 函数把 EStart 的
  stack params block 当成 CBase，读 `[this+0x14+0xc]` 得到
  `0x00a04d08`。所以下一 fix 是构造/传入真实 CBase，而不是换
  slot target。framebuffer 仍 0。验收 `tools/test_round85.sh`。

- **只换 vtable 指针仍会 leave**（round 86）：新增
  `NK_SUPERVISOR_OBJECT_FIX=1`，在 `0x503ce696` 把 `[this+0x14]`
  写成 B7e vtable `0x80003040`。`0x00a04d08` 消失了，但 `+0xc`
  变成 zero-return stub，supervisor 仍在 **30,988 条**进入
  EUser TTrap/leave，`lr=0x5038cb70`（`r1=0xfffffff8`）。
  说明需要真实 class vtable/method，而不只是一个合法指针。
  framebuffer 仍 0。验收 `tools/test_round86.sh`。

- **真实 vtable/method 也救不了 stack params**（round 87）：把
  `[this+0x14]` 指向 `0x503b36d0`（+0xc 是真实方法
  `0x5038681c`），supervisor 仍在 30,852 条 null-call；
  `0x503b3518`/`0x503b3410`/`0x503b35a0` 也失败，framebuffer 仍 0。
  问题不只是 vtable 指针：`this` 是 EStart 的 stack params block，
  不是 class 实例；需要真实对象实例（连同字段），而不只是 vtable。
  验收 `tools/test_round87.sh`。

- **global CBase 当 this 也失败**（round 88）：新增
  `NK_SUPERVISOR_THIS`。强制 `this=0x80600008` 时 supervisor 在
  29,295 条跳到数据地址 `0x80000500`；`this=0x80600000` 则
  null-call。两者都无 framebuffer 像素。说明 global CBase 也不是
  所需对象；必须恢复真实 class instance/server response。验收
  `tools/test_round88.sh`。

- **callback 收到 stack params，不是 CBase**（round 89）：watch
  `0x503da6f0` 显示
  `0x503db2dc -> 0x503da6f0`，`r0=0x8057ffc8`，`r1=0xd`；
  `[0x8057ffc8]` 是 EStart 的 stack params block（0、
  `0x28e59ff0`、9、…）。该函数期望 `this`，但回调传的是 params，
  于是后续 EUser 把 `[this+0x14]` 当 vtable，落到
  `0x00a04d08`。这是 callback/object ABI 不匹配，需要真实
  server/class instance。验收 `tools/test_round89.sh`。

- **更正：EStart 的真实 main 与 import map**（round 90，静态分析）：
  - **撤回 round 85–89 的结论**。EStart 的真实 main 是
    `0x503db29c`（由 `0x503da4a4` 的静态构造遍历器调用）。它在栈上
    建一个 **0x24 字节 params block**，以 `r0 = sp` 依次调用 14 个子
    步骤（共 21 处 `bl`）。这些是**接收 params 结构的自由函数**，
    不是 `CBase` 方法。所以“把 stack params 当 CBase”是 round 78 起
    fake scheduler 线程**伪造调用**的产物，不是 EStart 的 bug。
  - EStart 的 56 个 import thunk 分三组：30 个 EUser 槽
    （`0x503b3xxx..0x503b4fxx`）、**12 个 EFSrv.dll 槽**
    （`0x503cf918..0x503cfcdc` 是 EFSrv 的 `.edata`；uid3
    `0x100039e4`、241 exports、romfs 名 `EFSrv.dll`）、以及
    `0x5034c6xx` / `0x503b6b30` 的 kernel/其他槽。
  - 3 个槽**未解析**（`0xffffffff`）：`0x503cfcd8`、`0x50a1f06c`、
    `0x50a1f070`。
  - **30 处调用进入 EFSrv 槽**，集中在 `0x503da574`、`0x503da59c`、
    `0x503da60a`、`0x503da61e`、`0x503da65e`、`0x503da734` 等，
    即多个子步骤都在做 **文件 I/O**（open/write/read/mount）。
    EStart 是 params-block + 文件 I/O 程序，不是 CBase 客户端。
  - 因此真正的 blocker 是 **EFSrv（文件服务器）不可用**：`RFile`/`RFs`
    没连上 session，半初始化对象上的虚拟调用就落到 `0x00a04d08`。
  - 验收 `tools/test_round90.sh`（离线、确定性）。

- **ROM 启动链 + kernel object index 为空**（round 91）：确定方案 3
  （kernel process loader / 真 EFSrv）的事实基础。
  - ROMFS 启动链：`ekern.exe`(0x5030ff9c) → **`EFile.exe`**
    (0x503b70a0) → **`EFSrv.dll`**(0x503c9420, 241 exports) →
    **`EStart.exe`**(0x503da440) → `Starter.exe`(0x509e9ac0) →
    `SplashScreen.exe`(0x509eee20) + `SplashScreen.mbm`；另有
    `nosstarter.ext`(0x50341430)。
  - 所以 EStart 的 12 个 EFSrv 槽**必须等 EFile.exe 起来**才可能工作；
    单独驱动 EStart 永远画不出帧 —— 这解释了 round 63–89 的反复失败。
  - kernel 侧：600k 指令的 kernel boot 中，handle→object 查找走
    EUser slot `0x503b3948`；`config/imports-r29-6600.txt` 把它从 ROM
    的 `0x50380270` 重绑到 `0x5038e4b4`（kernel 的 K-3 构建）。
    查找用的 process object index 是 `0x80600e98`，其 `+8`
    **元素计数为 0**，`+0x14` 也是 0 → **所有 handle 查找返回 0**。
    因此 handle `0x32` 永远解析不到，Init3 的 thread-start 完成不了。
  - 方案 3 的第一项具体任务：**给 kernel 的 object index 填充真实
    条目**（按 `CObjectIx::AddL` 语义登记 DThread/DProcess），让
    handle `0x32` 解析到 supervisor DThread。
  - 验收 `tools/test_round91.sh`（离线、确定性）。

- **kernel 自己不会启动下一阶段**（round 92，实测）：方案 3 的关键
  结论。
  - HAL timer 只被设定**一次**：`reload = compare = 0x632ea`、
    `control = 0x2`，在 ~430k 指令处触发 **1 次** IRQ
    （`timer: on, 1 expiries`）。下一次要到 ~836k，超出预算 ——
    kernel 是**按设计进入 idle**，不是缺 tick。
  - timerq 对象的 `+0x1c` HAL tick getter 在这个窗口内**从未被调用**，
    所以新增的 `NK_HAL_TICK=1`（单调 tick）对现状没有影响。
  - `Kern::Init2` 尾部（`0x50330a88..0x50330aa8`）是一个**重试等待
    循环**：重新填 `[sp]`、调用 `0x50336da4` 的 wait、只有在 status 仍为
    `KRequestPending` 时才 panic KERN 6。harness 去“完成”该 status
    只会让 supervisor 在 `0x50330a98` **反复重新阻塞**（440,946 →
    442,511 之间约 11 次 ping-pong），没有任何新工作。
  - 全程只有 **2 个 DThread**（supervisor `0x80601078`、NULL
    `0x80601830`），**从未创建任何 DProcess / EFile / EStart**。
  - 结论：kernel 不会自己加载 EFile/EStart。缺的是 **mask ROM 的
    boot hand-off**（创建并启动第一个用户进程）。所以方案 3 要求
    **harness 自己执行这个 hand-off**，而不是等 kernel 去做。
  - 验收 `tools/test_round92.sh`。

- **线程入口的指令集（Thumb 位）修复 + EFile 跑进 kernel**（round 93）：
  - 首次切换原来把新线程 CPSR 固定成 `0x40000013`（ARM），忽略了
    E32 `iEntryPoint` 的 bit 0（Thumb 位）。以 ARM 模式执行 Thumb
    镜像的前几条指令会得到垃圾寄存器状态。
  - 对 `EFile.exe`（uid3 `0x100039e3`，code `0x503b7104`，
    entry `0x503b7105`）实测：修复前只跑 9 条 ARM 指令，
    `r4=r5=0`，在 `0x503b7104` 经 `bx r0` thunk `0x503c597c` 变成
    null call。
  - 修复（`sched_resume` 与首次切换都按入口 bit 0 置 `NK_CPSR_T`）后：
    `EFile` 执行 **1,120 条 Thumb 指令**，访问硬件寄存器
    `0x40000400`/`0x40000418`，最终停在 kernel panic halt
    `0x50312b88`（不再是 null call）—— 也就是**真的进到 kernel 里**。
  - 这是方案 3 第一个"真进程映像跑起来"的里程碑；下一 blocker 是
    EFile 触发的 kernel panic（`0x50312b88`，halt 时 `r0=0x40`）。
  - 验收 `tools/test_round93.sh`；`test_round78.sh` / `test_round92.sh`
    仍 PASS。

- **EFile 越过 kernel start hand-off**（round 94）：两个 harness 修复。
  - **`NK_HANDOFF_ARM=1`**：`DThread::StartThread`（vtable+0x20 =
    `0x50321088`）把参数存到 `this+0xf8` 后跳到 kernel 的 start
    hand-off `0x50318398`，后者消费 `[0x80001784]` 的 pending
    `TRequestStatus`。首次切换后该槽已被消费，于是 hand-off 抛
    **PLAT fault（reason `0x73`）**，kernel 在 `0x50312b88` halt。
    在 hand-off 前重新 armed 该槽即可消除该 fault。
  - **`NK_ALLOC_MAX`（默认 `0x100000`）**：EFile 调用 `ReAlloc` 时把
    字节数传成了 `0x503c7168`（它自己 rodata 表地址），原来会污染
    bump heap 并被误报成 "undefined instruction"。现在这类请求
    **干净地失败**（guest 看到 null）。
  - 修复后 EFile 跑进 EUser 堆代码，随后跟着 null 指针在 `0x2c`
    离开 image —— 这是新的 frontier。
  - 附带：新增 `pc_hook3`（handoff arm）/`pc_hook4`（supervisor
    object fix）；memcopy clamp 移到 `pc_hook2`，使 clamp + `NK_TIMERQ`
    + supervisor fix 可以共存；新增 `NK_SCHED_MODE=auto|arm|thumb`
    （默认 auto，按 `iEntryPoint` bit0），round 79/81–83/85–89 固定
    为 `arm` 以保留其历史 frontier；**round 80 的预期已更新**：Thumb
    修复后 `0x503da675` 入口按 Thumb 执行，服务器跑 19,262 条后从
    `0x503da6ee` 的正常尾声返回到 sentinel `0xdead0000`，原来的
    `0x503da6d5` null call 是 ARM 误解码的产物。
  - 验收 `tools/test_round94.sh`。
  - direct-dispatch control（`NK_SWI_DIRECT=1 NK_SWI_EXCEPTION=0`）不再
    撞 banked SVC self-loop，而是到 EwSrv `0x506ca5e4`（1,561 条）；
    加 EwSrv slot `0x506ce44c -> 0x506ca57f` 后到已知的
    `0x506cd868 -> 0xb5f00000` wild jump。说明 banked SVC return 和
    EwSrv jump-table relocation 是两条独立 blocker。
  - `0xb5f00000` 的机制：`0x506ca5c0` 调 `0x506cd866` 时 r3 是
    EwSrv 函数自身入口 `0x506ca57f`；`0x506cd866` 的
    `ldr r3,[r3]` 从 `0x506ca57c` 读到首字 `b5f00000` 并跳过去。
    snap 目标/调用参数仍不对，需要找该 slot 真正的 EwSrv 入口。
  - 该实验放在 `config/imports-app-main-6600.txt`，默认 app map
    （`imports-app-6600.txt`）仍只做 round-63 的 CBase rebind，保持
    干净返回。framebuffer 仍无 app 像素。
  验收 `tools/test_round64.sh`。

### 未完成

- **handle `0x32` / DFC 线程**：supervisor 的 `RThread::Resume(0x32)`
  在进程 `CObjectIx`（`0x80601210`）里查不到对象（`At` 返回 0），
  于是落到“启动 current thread 并等待 request”的回退路径；NULL 线程
  只跑 Init3 的 timing loop，不再做 hand-off。需要按真实
  `CObjectIx::AddL` 语义登记线程 handle，或创建 mask-ROM 的 DFC
  线程，让 supervisor 的最后一次 wait 有真正的 completer。
- **DFC / WSERV 线程启动**：display/UI server 线程还没有被创建和
  调度。当前 run queue 只真正跑 supervisor 与 NULL 两个线程。
- **完整 ready queue 与优先级**：当前在 Init2 的 wait（LR
  `0x50330a98`）和线程启动交接点切换；尚未实现真正的优先级队列、
  抢占时间片与 DFC 线程。
- **`svc #0x4d` 的通用语义**：Init2 的 wait 已按信号量阻塞实现；
  更早的 EUser wait 循环仍走 `NK_SWI_COMPLETE=0x4d` 的内联 HLE，
  尚未在每条等待路径上做真实的 TRequestStatus 完成。
- **Timer unit 1 / DFC 队列**：IRQ 2 的 handler `0x503113d8` 已注册，
  但系统 tick 队列尚未启动（没有 pending timer）。
- **显示/键盘/音频/文件服务/应用启动**（P3）；display controller 与
  第一帧是下一步的最终目标。
- **Mask-ROM PeaK record codec**：当前 hand-off 是显式 stand-in，不是解包实现。
- **真实硬件 HLE**：display controller、DSP/radio、RTC 仍是最小模型。

---

## 3. 关键地址与 ABI

| 地址 / 值 | 含义 |
|---|---|
| `0x50000000` | ROM base；ROM header 在 `0x50000000..0x50000100` |
| `0x50000080` | TRomHeader `iTime`（64-bit） |
| `0x50000084` | kernel 读取的初始 **TTime hand-off**（`NK_SYSTEM_TIME`） |
| `0x5000009c` | `iPrimaryFile`（`ekern.exe` TRomEntry `0x50301ec4`） |
| `0x500000cc` / `0xd0` | variant / extension TRomEntry（`ecust.dll` / `rtc.dll`） |
| `0x50300000` | ROMFS 目录块（64 KiB） |
| `0x50310000` | kernel code；entry `0x50310054` |
| `0x5030ff9c` | kernel `TRomImageHeader` |
| `0x40000000` | kernel super page；`+0xd0` = kernel TRomEntry；`+0x800` = `TMachineConfig` |
| `0x80000000` | RAM base；kernel data / `.bss` |
| `0x8000000c` | idle/DFC 等待标志（idle loop 轮询） |
| `0x800017d4` | kernel current-thread 全局 |
| `0x800017ec` | 系统 TTime 全局（`TTime::SecondsFrom` 的旧值） |
| `0x5031380c` | RTC/系统时间初始化（读 `0x50000084` 的 TTime） |
| `0x503126d0` | 系统时间比较/设置（调用 `TTime::SecondsFrom`） |
| `0x50310f6c` | idle 函数；循环在 `0x50310f84` |
| `0x50310b30` | `Kern::Init1` 失败的 MKERN-WD2 24 panic 入口 |
| `0x50315258` | kernel IRQ handler（vector `0x18`） |
| `0xffff0018` | high-vector IRQ 入口（`CP15.V=1`；harness 同时复制到 `0x0`） |
| `0x50311194` | `Kern::Irq`：读 `0x58120114`，按 `0x5c+irq` 查 handler 表 |
| `0x80000b80` | interrupt handler table（186 项，`[0x80001774]/[0x80001778]`） |
| `0x80000b5c` | IRQ 1 handler 对象；vtable `0x50338a40` → `0x50310ee0` |
| `0x50310ee0` | 置 `[0x8000000c]=1` 的 scheduler-wake handler |
| `0x80000574` | IRQ 2 / IrqTimer1 handler 对象；vtable `0x50338a34` → `0x503113d8` |
| `0x503113d8` | ack timer unit 1（`0x58120a28`）并进入 timer DFC |
| `0x58120a00` | UPP timer 0（`IrqTimer0`，IRQ 1）；`+4` control，`+0x18` reload |
| `0x58120a20` | UPP timer 1（`IrqTimer1`，IRQ 2）；`+8` status/ack，`+0x10` compare |
| `0x58120114` | UPP ICU current-IRQ register |
| `0x5031ef40` | idle 返回后的 `[0x80001c34] -> vtable+0xc` 调用点 |
| `0x80001c34` | timer-queue 单例指针；round 31 由 harness 在 `0x5031ef40` 注入 |
| `0x5032b33c` | kernel export 344：`[0x80001c34]` 的 setter（已存在则 panic 0x22） |
| `0x5032aff8` | kernel export 451：timer-queue 抽象基类构造；安装 vtable `0x503383bc` |
| `0x503383bc` | 抽象基类 vtable；`+0xc` = `0x5032b024`，`+0x1c` = 纯虚 `User::Panic` |
| `0x5032b024` | vtable `+0xc`：先调 `+0x1c` 取 tick，再处理 `+0x10` 队列 |
| `0x5032b3c8` | Init1 在 timer 对象之后调用的队列/定时器启动辅助 |
| `0x50336858` | K=1610 的 IAT stub（纯虚槽）；boot profile 实际指向 `0x50389848`（`User::Panic`） |
| `0x503a6120` | EUser K=1163：`TTrap::UnTrap()`；`SVC 0x73` 弹 frame，再调 `[frame+0x48]->vtable+0xc` |
| `0x503187e8` | SVC 0x73 service：`r0=[thread+0x38]`，`[thread+0x38]=[r0+0x40]` |
| `0x503187c8` | SVC 0x72 service（push）：新 frame `+0x40`=old frame，`+0x48`=old handler |
| `0x802ffd00` | bootstrap `SThread`（boot stack 内，`0x5031edc8` 的 `sp+0x58`） |
| `0x802ffcec` | EUser `TFullName`（"Supervisor"，0x108 字节）覆盖 SThread 的缓冲区 |
| `0x80601078` | `0x5031e594`（Kern::Init1）返回的真实堆 `DThread`；`+0x38` frame，`+0x3c` handler |
| `0x80004200` | round 32 为 `0x80601078` 安装的 `TCleanupTrapHandler`（slot 1） |
| `0x80004240` | 对应的 `CCleanup`（slot 1） |
| `0x80001784` | kernel-start 的 wait-any-request 状态槽（初始指向栈上的 `TRequestStatus`） |
| `0x503244e4` | kernel service table `[0x4d]`：`CurrentThread()->[0x5c]->vtable[0x20]`（请求信号量 Wait） |
| `0x50320ac0` | `DThread+0x5c` 请求信号量构造器（`0x503311c8` 调用） |
| `0x503311c8` | 线程创建时安装 `[thread+0x5c]` 的信号量对象 |
| `0x50321088` | DThread vtable `+0x20`：启动/切换 hand-off，转 `0x50318398` |
| `0x50318398` | 完成 `[0x80001784]` 指向的 `TRequestStatus`、发布新 current thread |
| `0x503312d4` | `Kern::StartThread`（`svc #0x76`），调用 `[thread]->vtable+0x20` |
| `0x5031f144` | kernel NULL 线程入口（`0x5032faf4` 字面量） |
| `0x5032faf4` | 线程创建参数里的入口函数字面量 = `0x5031f144` |
| `0x503360d4` | round-33 frontier：多线程 `CObjectIx`/B7e 路径的 null call（LR）；round 34 已关闭 |
| `0x5033606c` | `CObjectIx` 关闭/移除路径（`0x50332cc0` 从 `DThread+0x64` 调用）；`[index]->vtable+8` |
| `0x503b36f8` | 真实 `CObjectIx` vtable（`CObjectIx::NewL` `0x50384d24` 安装） |
| `0x806019c0` | NULL 线程自己的 `CObjectIx`（round 34 保留，不再被 B7E_OBJIDX 覆盖） |
| `0x806019e0` | NULL 线程的请求信号量（`0x503311c8` 创建；round 34 保留） |
| `0x80600d48` | supervisor / NULL 线程的真实 `DProcess`（round 34 保留） |
| `0x503183b4` | hand-off 真正完成 `TRequestStatus` 的 store（写 0 到 `[0x80001784]` 与 status） |
| `0x50321a74` | `PLAT` panic 入口；`0x73` = thread-start 没有 pending request |
| `0x5031f144` | NULL 线程入口；`Kern::Init3` 在其中运行 |
| `0x5031f154` | Init3 轮询 HAL object 3 的循环 |
| `0x800003ac` | `Kern::TheKernel`/HAL 全局；stand-in vtable `0x80003c00` |
| `0x5031f19c` | 对 HAL device 调用 `vtable+0x48`（`Request(0xd,0,0)`） |
| `0x800004cc` | Init3 gate：`Request(0xd)` 完成后置非零；round 34 由 HAL stub 置 1 |
| `0x50336284` | kernel export 331（index；ordinal 332）：`[0x800004cc] = r0` setter |
| `0x5032211c` | 6M 预算停止处的 executive timing 辅助（读 `[0x40000800]`） |
| `0x80530000` | harness 线程启动 hand-off status 页（`NK_SCHED=1`） |
| `0x80540000` | harness NULL 线程内核栈（0x2000，`NK_SCHED_STACK` 可改） |
| `0x50330a8c` | 初始化 `TRequestStatus`（`0x80000001`）并挂到 `[0x80001784]` |
| `0x50330a94` | 调 EUser K=1208（`0x50398644`，`svc #0x4d`） |
| `0x50330aa8` | `[sp] == KRequestPending` 时的 **KERN 6** panic 调用点 |
| `0x5032fa10` | kernel-start 创建 NULL 线程（对象 `0x80601830`，栈 0x2000） |
| `0x80601830` | NULL 线程对象；vtable `0x503385b4`，name 描述符 `0x806019a8`（"NULL"） |
| `0x50312b88` | panic halt 自跳转点（round 32 的停止位置） |
| `0x80500000` | harness 注入的 timer-queue 对象（默认；`NK_TIMERQ_ADDR` 可改） |
| `0xffff0a00` | 覆盖纯虚 `+0x1c` 的零返回 HAL tick stub |

### 时间簇（EUser `edata[K-3]`）

| K | 符号 | 目标 |
|---|---|---|
| 294 | `TTime::DateTime()` | `0x503a4020` |
| 970 | `TTime::SecondsFrom(...)` | `0x503a4380` |
| 1069 | `TDateTime::Set(...)` | `0x503a3900` |
| 1375 | `TTime::TTime(const TDateTime&)` | `0x503a3af8` |
| 1361 | TStack/TBuf 构造（唯一 local exception） | `0x503a023c` |

### 解释器语义（round 29 修正）

- `SMULL/UMULL/UMLAL/SMLAL`：`00001 U A S RdHi RdLo Rs 1001 Rm`；
  `RdHi==Rs` 是 firmware 实际用法，先读操作数再写回。
- S=0 的 SUB/RSC/ADD/ADC/SBC/RSC **不得**写 N/Z/C/V。
  否则 EUser 64-bit 除法循环的 `adc r3,r3,r3` 会清借位，`movhs` 余数更新失效。

### Timer / IRQ 链（round 30）

```
Kern::Init1
  0x50310ff8  bl 0x50313250(0,2)     ; timer0 control = 2 (periodic)
  0x50311004  bl 0x503132c8(0,0x632ea); timer0 reload  = 0x632ea
  0x50310f6c  idle()                 ; polls [0x8000000c]

UPP timer 0 expires (guest-programmed reload, no host period)
  model: status=1, ICU current IRQ=1, cpu.irq_pending=1

CPU (CP15.V=1, CPSR.I=0)
  0xffff0018  kernel vector table -> 0x50315258
  0x50315258  IRQ entry: sub lr,#4, save r0-r3/ip/lr on the IRQ bank
  0x50311194  Kern::Irq: [0x58120114]=1 -> handler table[0x5c+1]
  0x80000b5c  handler object -> vtable[0x50338a40]+8 = 0x50310ee0
  0x50310ee0  ack timer0 (write 0 to 0x58120a08); [0x8000000c] = 1
  0x50310f84  idle sees 1, returns to 0x5031ef20
  0x5031ef40  [0x80001c34] -> vtable+0xc = 0x5032b024 (round 31)
  0x5032b024  HAL tick getter (vtable+0x1c, overridden) -> queue at +0x10
  0x5031ef54  starts the queue/timer helper 0x5032b3c8
  0x50330a5c  kernel-start path: EUser K=1163 (0x503a6120)
  0x503a6124  SVC 0x73 -> 0x503187e8 pops [thread+0x38]
  0x503a6128  [frame+0x48] = handler -> vtable+0xc = UnTrap (round 32)
  0x50330a8c  TRequestStatus = KRequestPending; [0x80001784] = &status
  0x50330a94  EUser K=1208 -> svc #0x4d (wait any request)
  0x50330aa8  request still pending -> KERN 6 panic
  0x50312b88  panic halt (no scheduler to complete the request)
```

### TTrap / 线程身份（round 32）

`TTrap`（SDK `e32std.h`，0x4c 字节）：

| 偏移 | 字段 |
|---|---|
| `+0x00..+0x3f` | `iState[0x10]`（EUser 保存的上下文） |
| `+0x40` | `iNext`（前一个 TTrap） |
| `+0x44` | `iResult`（`TInt*`） |
| `+0x48` | `iHandler`（`TTrapHandler*`） |

`SVC 0x72`（`0x503187c8`）把新 frame 的 `+0x40/+0x48` 设成线程当前的
frame/handler，再把 `[thread+0x38]` 指向新 frame；`SVC 0x73`
（`0x503187e8`）弹出 `[thread+0x38]` 并把 `[frame+0x40]` 写回。
`vtable 0x503b3518`：`+8` Trap `0x50383c38`、`+0xc` UnTrap
`0x50383c40`、`+0x10` Leave `0x50383c48`。

round-31 的 frame `0x503a43c4` 不是 frame，而是 SThread 被覆盖后的字段。
bootstrap `SThread` 位于 `0x5031edc8` 的 `sp+0x58`（即 boot stack 顶附近），
`0x5031e594` 在 `0x5031ee7c` 返回堆上的真实 `DThread 0x80601078`；
`0x5031ee90` 本应把它写回 `[0x800017d4]`。B7e 旧的 live-pointer 上界
`0x80400000` 拒绝了 `0x80601078`，把 `0x802ffd00` 重新发布，于是后续
TFullName 缓冲区覆盖了“当前线程”。

修复后 `[0x800017d4] = 0x80601078`，`+0x38` 的 frame `0x802fff94` 是
真实栈 frame，handler `0x80004200` 走 EUser 自己的 UnTrap 实现。
control：`NK_B7E_VALID_HI=0x80400000` 精确复现 round 31（439,177 条，
`0x503a6148` null call）。

- timer 单元 stride `0x20`：`+0x00` counter、`+0x04` control、
  `+0x08` status/ack、`+0x0c` mode、`+0x10` compare、`+0x14` reload2、
  `+0x18` reload。
- IRQ 编号 = 1 + unit；`0x58120114` 直接给出当前编号，`Kern::Irq`
  用 `0x5c + irq` 作为 handler 表下标。
- IRQ 入口：`SPSR_irq` 保存旧 CPSR，`LR_irq = PC + 4`，T bit 清零；
  返回由 `subs pc,lr,#4` / `ldm {...,pc}^` 恢复 SPSR、bank 和模式。
- `NK_TIMER=1` 才启用设备模型；默认关闭，round-29 的 3,000,000 条
  control 保持不变。`NK_CPSR=0x40000053` 提供 mask-ROM 的 I=0 hand-off；
  `NK_CPSR=0x400000d3`（I=1）是“timer 到期但不进 IRQ”的 control。

### timer-queue / kernel-start（round 31）

```
Kern::Init1 (continued after idle)
  0x5031ef40  ldr r0,[0x80001c34]      ; harness-injected object
  0x5031ef50  ldr pc,[vtable+0xc]      ; 0x5032b024
  0x5032b034  ldr pc,[vtable+0x1c]     ; abstract base: User::Panic
                                       ; concrete HAL: tick getter
  0x5031ef54  bl 0x5032b3c8            ; queue/timer helper
  0x50318768  current-thread field update
  0x50330a5c  bl 0x503a6120            ; EUser K=1163 (cleanup/trap pop)
```

- export 451 `0x5032aff8` 的构造器只安装抽象基类 vtable `0x503383bc`；
  `+0x1c` 槽是纯虚函数 `User::Panic`（K=1610 stub `0x50336858`，
  boot profile 实际指向 `0x50389848`），所以直接使用基类 vtable 会在
  **430,945 条**处 halt 到 `0x50312b88`。
- round 31 复制基类 vtable 到 `0x80500100`，把 `+0x1c` 换成高地址
  `0xffff0a00` 的零返回 stub，模拟具体 HAL 子类的 tick getter。kernel
  自己的 `0x5032b024` 因此能运行，boot 前进到 **439,177 条**（round-31
  历史值；round 32 修正线程身份后为 **439,534 条**）。
- `NK_TIMERQ_MODE=ctor` 是上面的 control；`NK_TIMERQ_MODE=stub` 则跳过
  整个 `+0xc` 方法，停在 438,731 条处的 KERN 6 panic（另一条路径）。

---

## 4. 复现命令

```sh
# 提取
.venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 6600_mcu.bin
.venv/bin/python recompiler/wd2.py info 6600_mcu.bin
.venv/bin/python recompiler/wd2.py kernel 6600_mcu.bin fw/6600_kernel.bin

# stream / 布局 / 导入
.venv/bin/python recompiler/pagestream.py verify 6600_mcu.bin
.venv/bin/python recompiler/layout.py verify 6600_mcu.bin
.venv/bin/python recompiler/imports.py verify 6600_mcu.bin

# 扁平镜像 + boot
tools/build_rom_image.sh
NK_IMPORTMAP=config/imports-r29-6600.txt \
  NK_SYSTEM_TIME=1 NK_BOOT_HANDOFF=1 NK_SUPERPAGE=1 NK_B7E=1 \
  NK_TRAPCLEAN=1 NK_EXT_STUB=1 NK_HAL_TIMER_HZ=4 NK_PRIMARY_RAM=0x80900000 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_BUDGET=3000000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin

# round 30: 同一条命令加 timer / I=0 hand-off / IRQ 日志
NK_TIMER=1 NK_TIMER_LOG=8 NK_CPSR=0x40000053 NK_IRQ_LOG=4 \
  NK_IMPORTMAP=config/imports-r29-6600.txt \
  NK_SYSTEM_TIME=1 NK_BOOT_HANDOFF=1 NK_SUPERPAGE=1 NK_B7E=1 \
  NK_TRAPCLEAN=1 NK_EXT_STUB=1 NK_HAL_TIMER_HZ=4 NK_PRIMARY_RAM=0x80900000 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_BUDGET=3000000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin

# round 31: 在 round-30 命令上加 timer-queue 注入
NK_TIMERQ=1 \
  NK_TIMER=1 NK_TIMER_LOG=0 NK_CPSR=0x40000053 NK_IRQ_LOG=0 \
  NK_IMPORTMAP=config/imports-r29-6600.txt \
  NK_SYSTEM_TIME=1 NK_BOOT_HANDOFF=1 NK_SUPERPAGE=1 NK_B7E=1 \
  NK_TRAPCLEAN=1 NK_EXT_STUB=1 NK_HAL_TIMER_HZ=4 NK_PRIMARY_RAM=0x80900000 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_SWI_DIRECT=1 NK_SWI_COMPLETE=0x4d NK_BUDGET=3000000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin

# round 31 control: 只用抽象基类 vtable（+0x1c 纯虚 -> panic halt）
NK_TIMERQ=1 NK_TIMERQ_MODE=ctor ...（其余同上）

# round 32: 让 B7e 跟随堆上真实 DThread（0x80601078）
NK_B7E_VALID_HI=0x80a00000 ...（其余同 round 31）
# ... 439,534 条，1 IRQ；svc #0x4d 等待未完成 -> KERN 6 @ 0x50312b88

# round 32 control: 旧上界拒绝堆线程，复现 round 31
NK_B7E_VALID_HI=0x80400000 ...（其余同 round 31）
# ... 439,177 条，null call @ 0x503a6148

# round 33: 让 svc #0x4d 阻塞并切换到 NULL 线程
NK_SCHED=1 NK_SCHED_LOG=16 ...（其余同 round 32）
# ... 第一次切换 -> 0x80601830 @ 0x5031f144；0x50318398 交接完成 request；
# ... supervisor 在 0x50330a98 恢复（[sp]==0），KERN 6 消失；
# ... 440,623 条，新 null call @ 0x503360d4（多线程 CObjectIx/B7e）

# 验收
tools/test_round32.sh
tools/test_round31.sh
tools/test_round30.sh
tools/test_round29.sh
for t in tools/test_*.sh; do sh "$t" || exit 1; done
```

---

## 5. 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 固件/镜像/布局/解释器/导入/启动状态 | 完成 |
| P1 | kernel 进入 idle loop | **完成（round 29）** |
| P2 | timer/IRQ、idle 退出、调度器/线程运行 | timer/IRQ **完成（round 30）**；timer-queue/kernel-start **完成（round 31）**；真实线程身份与 TTrap **完成（round 32）**；第一次调度切换/KERN 6 **完成（round 33）**；live 对象图/TRequestStatus 唤醒/Init3 HAL gate/异常栈 **完成（round 34，稳定 6M）**；完整 run queue 与 DFC 线程仍缺 |
| P3 | 显示/键盘/音频、文件服务、S60 app 启动 | **Nokia logo 帧已可见（round 61，bring-up HLE）**；round 62/63 修通 app-entry 地基与 import rebind；round 66 修掉 null descriptor；round 68/69 转向 EStart；round 70/71 推进到 13k 条；round 72 钉住 slot/export offset；round 73 定位 service-start 握手；round 74 修 nested SVC return；round 75 证明 wait 等真实线程；round 76 证明 DThread clone 不足；round 77 证明 direct dispatch 绕不过 handshake；round 78/79 用 fake scheduler + auto-complete 让 EStart server 跑满 200k；round 80 用 Mem::Copy clamp 越过 wild copy；round 81 证明 fake stack sentinel 不足；round 82 完成 server run/return cycle；round 83 证明 0x00a04d08 不能简单 HLE；round 84 排除相邻 EUser slot target；round 85 诊断出 supervisor 把 stack params 当 CBase；round 86 证明只换 vtable 指针仍会 leave；round 87 证明真实 vtable/method 也救不了 stack params；round 88 证明 global CBase 当 this 也失败；round 89 追到 callback 收到 stack params 而非 CBase |
| P4 | 待机 UI / 开机画面，跨设备验收 | 未开始 |

### 下一步（建议顺序）

1. **解决 handle `0x32`**：先确认 `RThread::Resume(0x32)` 的 handle
   语义（低 15 位 index、bits 16+ instance），按真实 `CObjectIx::AddL`
   把 supervisor/NULL 线程登记到进程 index `0x80601210`；如果 `0x32`
   是 mask-ROM 的 DFC 线程，则需要用 kernel 自己的 `RThread::Create`
   创建它，而不是伪造索引。目标是让 supervisor 的最后一次 wait 由
   真正的 thread-start hand-off 完成。
2. **启动 DFC / WSERV 线程**：boot 停在 `0x5032211c` 的 executive
   timing 循环。handle 修好后，从 `[0x800003b8]`/`[0x800003bc]` 等
   对象表取出 DFC 与 WSERV 线程对象，给 `NK_SCHED` 一个真正的
   ready queue，让 NULL 线程继续 `Kern::Init3` 并创建 UI server。
3. **实现真正的 ready queue/优先级**：当前只在 Init2 wait 与线程启动
   交接点切换；下一步把 `DThread+0x24` 状态、`+0x20` suspend 位、
   优先级 `+0x1c` 纳入 run queue，并允许 NULL 线程被抢占后继续其
   `Kern::Init3`/DFC 创建。
4. **`svc #0x4d` 的通用完成语义**：给线程请求信号量实现
   `RequestComplete` 对应的 signal，替换早期 EUser wait 循环仍使用的
   `NK_SWI_COMPLETE=0x4d` 内联 HLE。
5. **Timer unit 1 / DFC**：给 timer queue 一个 pending timer，验证
   IRQ 2 → `0x503113d8` → DFC 路径。
6. **Display controller HLE**：`176x208` 16bpp framebuffer、LCD 控制
   寄存器与 MBM/Sprite 读回；接上窗口后即可验证第一帧。
7. 之后进入 WSERV / S60 app 启动与待机 UI。
8. 用真实 FbsServ/`CFbsBitmap` 路径替换 round-61 的 MBM 解码 HLE，
   让 SplashScreen 自己加载并提交 logo 帧。
9. 实现 per-consumer EUser import table（或 app EUser import-name map），
   让 kernel 的 K-3 relocation 不再改写 app 共享的 EUser export slots。
10. 修 EwSrv 的 jump table / literal relocation（round 62 的
    `0x506ca5e4`、`0x506cd866 -> 0xb5f00000`），再接 window server。
11. callback/object ABI 不匹配（round 89）：`0x503da6f0` 期望
    CBase，但 `0x503db2dc` 传 stack params。需要真实 server/class
    instance；当前 harness/对象图无法恢复。

---

## 6. 已知限制

- `NK_SYSTEM_TIME`、`NK_BOOT_HANDOFF`、`NK_PRIMARY_RAM`、`NK_B7E` 等是
  **显式的 mask-ROM/HLE 状态模型**，不是从 mask ROM 解出的真实初始化。
- `[0x8000000c]` 的语义已在 round 30 验证：它由 IRQ 1 的 handler
  `0x50310ee0` 置位，idle 随即退出；I=1 时同一到期事件不会进 IRQ。
- `[0x80001c34]` 已由 round 31 的 `NK_TIMERQ=1` 在 `0x5031ef40` 注入；
  对象使用 kernel 自己的构造器 0x5032aff8，但 `+0x1c` 的 HAL tick getter
  是零返回 stub，不是真实硬件实现。
- B7e 的 live-pointer 上界（`NK_B7E_VALID_HI`，默认 `0x80a00000`）必须覆盖
  kernel 实际分配的堆；旧值 `0x80400000` 会把真实 `DThread` 当成
  transient，并把 boot-stack 上的 SThread 重新发布（round-31 control）。
- round 32 的 **KERN 6**、round 33 的 `0x503360d4` null call 都已在
  round 34 关闭；round 35 证明 6M 状态是 **Init2 死锁**（不是 CPU
  fault），`NK_SCHED_DEFER=1` 让 hand-off 先返回并把 supervisor 推进到
  464,336，但最后一次 wait 仍 pending。
- `NK_B7E_LIVE=1` 才会保留 live 的 `DThread+0x18/+0x5c/+0x64`；不设该开关时
  B7e 仍按历史模型覆盖它们，round-33 control 因此保持不变。
- `NK_SCHED=1` 的 NULL 线程内核栈（0x80540000）和启动 hand-off status
  （0x80530000）是 harness 分配的；kernel 自己分配的栈尚未从对象字段解出。
- `NK_SCHED=1` 只接管 Init2 wait（LR `0x50330a98`）；其他 `svc #0x4d`
  仍走 `NK_SWI_COMPLETE=0x4d` 内联 HLE。
- Init3 的 HAL object 3 / `Request(0xd)` 由 `NK_B7E_LIVE=1` 的显式 stub
  完成并把 `[0x800004cc]` 置 1；真实驱动在 mask ROM 中，尚未解出。
- live 模式把 UND/ABT/IRQ/FIQ/USR 栈放在 `0x80140000..0x80240000`；
  SVC 栈仍从 `0x80300000` 向下增长。这是 harness 布局，不是从
  mask ROM 恢复的栈指针。
- timer unit 1 / IRQ 2 / DFC 路径尚未被真实 pending timer 触发。
- 显示/键盘/音频/文件服务均未实现；app 二进制已放置，但无法启动。
- `references/` 与 `fw/` 是本地离线材料，不随仓库分发。
