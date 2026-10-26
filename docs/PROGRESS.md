# 开发进度与路线图 — Nokia 6600 (NHL-10)

最后更新：2026-10-26（round 33）
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

### 未完成

- **run queue / 多线程对象图**：round 33 已完成一次真实上下文切换并跨过
  KERN 6，但 Init2 继续创建线程时停在 `0x503360d4` 的 null call。
  B7e 目前只发布一个 live thread 和它的 `CObjectIx`；新线程的
  `CObjectIx` 仍取到同一个 harness 对象，随后调用空 vtable。需要按
  `DThread` 对象分别建立对象索引/句柄图。
- **完整 ready queue 与优先级**：当前只在 Init2 的 wait（LR
  `0x50330a98`）和线程启动交接点切换，尚未实现真正的优先级队列、
  抢占时间片与 DFC 线程。
- **`svc #0x4d` 的通用语义**：Init2 的 wait 已按信号量阻塞实现；
  更早的 EUser wait 循环仍走 `NK_SWI_COMPLETE=0x4d` 的内联 HLE，
  尚未在每条等待路径上做真实的 TRequestStatus 完成。
- **Timer unit 1 / DFC 队列**：IRQ 2 的 handler `0x503113d8` 已注册，
  但系统 tick 队列尚未启动（没有 pending timer）。
- **显示/键盘/音频/文件服务/应用启动**（P3）。
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
| `0x503360d4` | round-33 新 frontier：多线程 `CObjectIx`/B7e 路径的 null call（LR） |
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
| P2 | timer/IRQ、idle 退出、调度器/线程运行 | timer/IRQ **完成（round 30）**；timer-queue/kernel-start **完成（round 31）**；真实线程身份与 TTrap **完成（round 32）**；第一次调度切换/KERN 6 **完成（round 33）**；run queue 与 DFC 线程仍缺 |
| P3 | 显示/键盘/音频、文件服务、S60 app 启动 | 未开始 |
| P4 | 待机 UI / 开机画面，跨设备验收 | 未开始 |

### 下一步（建议顺序）

1. **修复新线程的 CObjectIx/句柄图**：round 33 的 stop 是
   `0x503360d4` 的 null call。B7e 的 `B7E_AT_STUB` 对所有句柄都返回
   同一个 harness CObject；Init2 继续创建线程后，新线程用该对象调用空
   vtable。需要按 `DThread` 对象分配各自的 `CObjectIx` 元素（至少让
   `At()` 按 handle 区分），再重跑 NK_SCHED。
2. **实现真正的 ready queue/优先级**：当前只在 Init2 wait 与线程启动
   交接点切换；下一步把 `DThread+0x24` 状态、`+0x20` suspend 位、
   优先级 `+0x1c` 纳入 run queue，并允许 NULL 线程被抢占后继续其
   `Kern::Init3`/DFC 创建。
3. **`svc #0x4d` 的通用完成语义**：给线程请求信号量实现
   `RequestComplete` 对应的 signal，替换早期 EUser wait 循环仍使用的
   `NK_SWI_COMPLETE=0x4d` 内联 HLE。
4. **Timer unit 1 / DFC**：给 timer queue 一个 pending timer，验证
   IRQ 2 → `0x503113d8` → DFC 路径。
5. 之后进入 display controller 与 UI 路径。

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
- round 32 的 **KERN 6** 已被 round 33 的调度切换关闭；当前 stop 是
  `0x503360d4` 的 null call（多线程 CObjectIx/B7e 模型），不是 CPU fault。
- `NK_SCHED=1` 的 NULL 线程内核栈（0x80540000）和启动 hand-off status
  （0x80530000）是 harness 分配的；kernel 自己分配的栈尚未从对象字段解出。
- `NK_SCHED=1` 只接管 Init2 wait（LR `0x50330a98`）；其他 `svc #0x4d`
  仍走 `NK_SWI_COMPLETE=0x4d` 内联 HLE。
- B7e 的 current-thread hook 仍把 `+0x5c` 覆盖成 TLS stand-in（`0x80003f00`），
  会替换掉本 round 识别出的请求信号量。round 33 不执行 NULL 线程自己的
  真实 Wait，所以切换可用；下一轮必须停止覆盖已是 live 指针的 `+0x5c`。
- timer unit 1 / IRQ 2 / DFC 路径尚未被真实 pending timer 触发。
- 显示/键盘/音频/文件服务均未实现；app 二进制已放置，但无法启动。
- `references/` 与 `fw/` 是本地离线材料，不随仓库分发。
