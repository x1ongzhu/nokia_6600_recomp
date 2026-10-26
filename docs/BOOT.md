# BOOT — Nokia 6600 启动链与运行时状态

本文记录**当前**可复现的启动路径、mask-ROM 交接状态、关键地址和调试开关。
逐轮探索过程见 git 历史；验收命令见
[`tools/test_round32.sh`](../tools/test_round32.sh)。

---

## 1. 输入与内存视图

```
fw/NHL105530.C1 (WD2 BT2)
  │  wd2.py extract
  ▼
6600_mcu.bin (23,285,596 B, 0x1634f5c)
  │  pagestream.py build: remove 852 × (0xec header + 0x2000 payload)
  ▼
packed stream (0x1605ed8 B)
  │  romimage.py build
  ▼
out/6600_runtime.bin (22 MiB, mapped at 0x50000000)
```

运行时地址：

| 区域 | 地址 | 说明 |
|---|---|---|
| ROM | `0x50000000..0x51600000` | code、ROMFS 目录、数据 |
| RAM | `0x80000000..0x80600000` | kernel data/bss + 6 MiB bank（`NK_RAM_EXTRA=0x300000`） |
| super page | `0x40000000..0x40010000` | mask-ROM 交接页 |
| high vectors | `0xffff0000` | kernel text 头 `0x64` 字节（`NK_KERNEL_VECTORS`） |
| low vectors | `0x00000000` | 同上；也用于 pre-MMU boot bank |
| MMIO | `0x58000000` 等 | UPP/UART/timer stub；timer 在 `0x58120a00`，ICU 在 `0x58120100` |

kernel：code `0x50310000`，entry `0x50310054`（ARM），
header `0x5030ff9c`，`iStackSize=0x4000`，`iHeapSizeMin=0x20000`，
`iHeapSizeMax=0x1000000`。

---

## 2. 启动阶段

### 2.1 Mask ROM → E32 entry（harness 模拟）

真实设备由 mask ROM 填好 super page 后才跳 kernel entry。直接跑 E32 entry
会缺这些状态；harness 用显式选项补齐：

| 交接 | 地址 | 选项 | 内容 |
|---|---|---|---|
| kernel TRomEntry | `[0x400000d0]` | `NK_BOOT_HANDOFF=1` | `0x50301ec4`（`ekern.exe`），`[entry+4]` = kernel header |
| primary RAM | `NK_PRIMARY_RAM=addr` | 64 KiB ROMFS 目录可写副本 | 只重指 `iPrimaryFile`（`0x5000009c`） |
| 初始 TTime | `[0x50000084]` | `NK_SYSTEM_TIME=1` | 从 TRomHeader `iTime`（`0x50000080`）安装 |
| HAL timer | vtable `+0x5c` | `NK_HAL_TIMER_HZ=4` | 非零频率，避免除零 |
| 初始 thread/process | `[0x800017d4]` | `NK_B7E=1` | thread→process→CObjectIx→array 图 |
| trap 图 | `thread+0x3c` | `NK_TRAPCLEAN=1` | 真实 `CTrapCleanup` |
| 扩展 export | high vector | `NK_EXT_STUB=1` | 无 export 的嵌套 image 给 export 1 |
| high vectors | CP15 c1 `V=1` | `NK_KERNEL_VECTORS=1` | mask ROM 的 `V` bit；向量装到 `0xffff0000` |
| IRQ 使能 | CPSR.I=0 | `NK_CPSR=0x40000053` | mask ROM 的 I=0 hand-off；默认 `0x400000d3` 屏蔽 IRQ |
| UPP timer/ICU | `0x58120a00` | `NK_TIMER=1` | 指令驱动的 timer 0/1 + ICU 当前中断号 |

这些是**显式 bring-up 模型**，不是从 mask ROM 解出的实现。

### 2.2 进入 kernel

```
0x50310054  push {r4,r5,r6,lr}    ; ARM entry
...
Kern::Init1
  0x5031e5a8  ldr r3,[0x400000d0] ; -> kernel TRomEntry
  0x5031e5ac  ldr sb,[r3,#4]      ; -> kernel TRomImageHeader
  0x5031ede4  ...                 ; 初始 TStack:
              r3 = iPrimaryFile
              r0 = r3 + iStackSize
              r1 = iHeapSizeMin
              bl 0x50321cf0        ; operator new(0x74, block)
              bl 0x503a023c        ; TStack/TBuf 基构造（K=1361）
  0x50321d84  TStack::Set          ; 断言 [obj] == iHeapSizeMin，否则 PLAT 0x51
```

### 2.3 系统时间

```
0x5031380c  ldr r2,[pc,#0x78]      ; -> 0x50000084
0x5031381c  ldm r2,{r5,r6}         ; 64-bit TTime hand-off
0x50313830  bl TTime::DateTime     ; K=294 -> 0x503a4020
0x50313858  bl TDateTime::Set      ; K=1069 -> 0x503a3900
0x50313874  bl TTime::TTime        ; K=1375 -> 0x503a3af8
0x5031388c  bl 0x503126d0          ; 与 [0x800017ec] 比较
0x503126e4  bl TTime::SecondsFrom  ; K=970 -> 0x503a4380
```

`NK_SYSTEM_TIME=1` 后这条路径返回 0，`Kern::Init1` 继续；否则在
`0x50310b30` panic **MKERN-WD2 24**。

### 2.4 进入 idle

```
Kern::Init1 尾声
  0x5031ef18  bl 0x50310f9c        ; b 0x50310f58: [0x8000000c] = 0
  0x5031ef1c  bl 0x50310fa0        ; b 0x50310f6c: idle()

0x50310f6c  push {r4,lr}
0x50310f70  ldr r3,[0x80000010]    ; 有 pending 工作则返回
0x50310f78  cmp r3,#0
0x50310f7c  popne {r4,pc}
0x50310f80  ldr r4,=0x8000000c
0x50310f84  bl 0x5031252c          ; 立即返回
0x50310f88  ldr r3,[r4]
0x50310f8c  cmp r3,#0
0x50310f90  beq 0x50310f84
```

`[0x8000000c]` 在进入 idle 前清零；round 30 起由真实的 IRQ 1
handler `0x50310ee0` 置位，idle 随即返回 `0x5031ef20`。

### 2.5 Timer IRQ 退出 idle（round 30）

`Kern::Init1` 在 idle 之前自己把 UPP timer 0 设成 periodic：

```
0x50310ff8  bl 0x50313250(0,2)       ; timer0 +0x04 control = 2
0x50311004  bl 0x503132c8(0,0x632ea) ; timer0 +0x18 reload  = 0x632ea
```

`0x58120a00` 的 unit 布局（回归自 kernel helper `0x50313240..0x5031333c`）：

| 偏移 | 含义 |
|---|---|
| `+0x00` | counter |
| `+0x04` | control（bit0 one-shot，bit1 periodic） |
| `+0x08` | status / ack（写 1 清 pending） |
| `+0x0c` | mode |
| `+0x10` | compare |
| `+0x14` | reload2 |
| `+0x18` | reload |

到期链：

```
timer0 reload 0x632ea 到期（host 只数 guest 指令，不设周期）
  -> status=1, ICU current IRQ=1, cpu.irq_pending=1

CPU: CP15.V=1, CPSR.I=0, 当前 mode UND
  0xffff0018  ldr pc,[...] -> 0x50315258
  0x50315258  IRQ entry（SPSR_irq=旧 CPSR, LR_irq=PC+4, T=0, I=1）
  0x50311194  Kern::Irq: [0x58120114]=1 -> handler table[0x5c+1]
  0x80000b5c  handler 对象 -> [0x50338a40+8] = 0x50310ee0
  0x50310ee0  ack timer0（write 0 to 0x58120a08）; [0x8000000c]=1
  0x50315284  IRQ return（ldm sp!,{...,pc}^ 恢复 SPSR/bank）
  0x50310f84  idle 退出 -> 0x5031ef20
```

结果：**430,557 条、1 IRQ、1 timer expiry、0 undefined/unbound/recovery**。
`NK_CPSR=0x400000d3`（I=1）是 control：timer 仍到期（7 次），但不进 IRQ，
idle 停在 `0x5031252c` 的预算边界。

### 2.6 idle 之后的 timer-queue 对象（round 31 已解）

```
0x5031ef20  ldr r0,=0x80001714
0x5031ef24  bl 0x50320aa8
0x5031ef28  bl 0x5031ece8
0x5031ef40  ldr r3,=0x80001c34
0x5031ef44  ldr r0,[r3]            ; object pointer
0x5031ef48  ldr r3,[r0]            ; vtable 0x503383bc
0x5031ef4c  mov lr,pc
0x5031ef50  ldr pc,[r3,#0xc]       ; 0x5032b024
```

`0x80001c34` 是 kernel 的 timer-queue 单例。kernel export 451
（`0x5032aff8`）是抽象基类构造，安装 vtable `0x503383bc`；export 344
（setter `0x5032b33c`）负责安装单例，但本 ROM 没有任何 image import
这两个 export，所以具体对象来自 mask-ROM/ASSP 启动状态。
`0x5032b024` 先调用 vtable `+0x1c` 取硬件 tick，再处理 `+0x10` 队列。
`+0x1c` 在基类里是纯虚函数（K=1610 → `0x50389848`，`User::Panic`），
必须由具体 HAL 子类覆盖；直接用基类 vtable 会在 430,945 条处 panic halt。

### 2.7 round 31：注入 timer-queue 并跨过 null call

harness 用 one-shot PC hook 在 `0x5031ef40` 之前执行注入：

```
NK_TIMERQ=1（默认 mode = override）
  1. 在 0x80500000 分配对象页和 scratch stack
  2. nk_interp_call(0x5032aff8)，r0=object
     -> 对象 vtable = 0x503383bc，+0x10 = TDblQue head
  3. 复制 0x503383bc 到 0x80500100
  4. vtable+0x1c -> 0xffff0a00（mov r0,#0; bx lr）
  5. [0x80001c34] = object
```

结果：**439,177 条、1 IRQ、0 undefined/unbound/recovery**。
`Kern::Init1` 返回后进入 kernel-start 路径（`0x50330a5c` 调用 EUser
K=1163），停在 `0x503a6148` 的 null call；该 frontier 在 round 32 被
证明是线程身份问题（见 2.8），可用 `NK_B7E_VALID_HI=0x80400000`
精确复现：

```
0x503a6120  push {lr}
0x503a6124  bl 0x50392ba0          ; SVC 0x73
0x503a6128  ldr r0,[r0,#0x48]      ; [frame+0x48] = 0xe21440ff
0x503a6138  ldr r3,[r0]            ; reads 0
0x503a613c  ldr ip,[r3,#0xc]       ; 0
0x503a6144  bx ip                  ; null call
```

control：`NK_TIMERQ_MODE=ctor` 只用基类 vtable，停在 `0x50312b88`
的 panic halt；`NK_TIMERQ_MODE=stub` 跳过 `+0xc` 方法，停在 438,731
条处的 KERN 6 panic。

### 2.8 round 32：bootstrap SThread vs 真实 DThread

`TTrap` 是 0x4c 字节：`iState[0x10]` +0x00、`iNext` +0x40、`iResult`
+0x44、`iHandler` +0x48。`0x503a6120` 就是 `TTrap::UnTrap()`；SVC 0x73
service `0x503187e8` 弹 `[thread+0x38]`，next 写回 `+0x38`。所以
round-31 的 `+0x48` 布局没有问题，错的是**当前线程对象**：

```
0x5031edc8  sub sp,#0x258
0x5031eddc  r0=sp+0x58                 ; bootstrap SThread (0x200 bytes)
0x5031ede0  [0x800017d4] = 0x802ffd00  ; stack object
...
0x5031ee70  bl 0x5031e594              ; docs call it Kern::Init1
0x5031ee7c  [sp] = 0x80601078          ; real heap DThread returned
0x5031ee90  [0x800017d4] = 0x80601078  ; would replace the stack thread
```

B7e 的 live-pointer 上界硬编码为 `0x80400000`，把 `0x80601078` 当成
scheduler transient，重新发布 `0x802ffd00`。随后 EUser 在
`0x802ffcec` 构造 0x108 字节 `TFullName`（"Supervisor"），覆盖了
`0x802ffcec..0x802ffdf4`，其中正好包括 SThread 的 `+0x38/+0x3c`，
`[thread+0x38]` 变成 ROM 地址 `0x503a43c4`。

把上界改为实际映射堆顶（`0x80a00000`，`NK_B7E_VALID_HI`）后：

```
B7e: current thread 0x80601078 -> process 0x80003200
B7e: thread 0x80601078 trap handler 0x80004200, cleanup 0x80004240
0x50330a5c  TTrap::UnTrap (K=1163) pops frame 0x802fff94
0x503187e8  [thread+0x38] = [frame+0x40]
0x503a6138  [frame+0x48] = 0x80004200 -> vtable 0x503b3518 +0xc
            = 0x50383c40 (TCleanupTrapHandler::UnTrap) -> returns

0x50330a8c  TRequestStatus = 0x80000001; [0x80001784] = &status
0x50330a94  EUser K=1208 (0x50398644) -> svc #0x4d
0x50330a9c  [sp] still 0x80000001?
0x50330aa8  yes -> Kern::Panic("KERN", 6)
0x50312b88  panic halt
```

结果：**439,534 条、1 IRQ、0 undefined/unbound/recovery**。
`0x5032fa10` 通过 `0x50320e44` 取得线程对象 `0x80601830`，在
`0x5032fa88` 调 `0x50330fb0` 完成创建（对象 vtable `0x503385b4`，
`+0x10` name 描述符 `0x806019a8` = "NULL"，0x2000 字节栈）；该线程
从未被调度。新 frontier 是第一个阻塞 executive call：`svc #0x4d` 的 HLE 只清
`[0x80001784]`，没有写 `TRequestStatus`，也没有 scheduler 去运行
`0x5032fa10` 创建的 NULL 线程（对象 `0x80601830`，name `"NULL"`，
0x2000 字节栈）。

### 2.9 round 33：第一次调度切换，跨过 KERN 6

重新读 `svc #0x4d`：kernel service table `[0x4d] = 0x503244e4` 取
`CurrentThread()->[0x5c]`，再调它的 `vtable+0x20`。`0x503311c8` 在
线程创建时用 `0x50320ac0` 在 `DThread+0x5c` 安装请求信号量，因此这是
`WaitForAnyRequest` 的 Wait，而不是“完成 request”。NULL 线程的真实入口
来自线程创建参数里的字面量 `0x5032faf4` = **`0x5031f144`**（对象
`0x80601830`，栈 0x2000）。

DThread vtable `+0x20`（`0x50321088`）→ `0x50318398` 是 kernel 的启动
交接：读 `[0x80001784]`，清 slot、把 0 写进该 `TRequestStatus`、发布
新的 current thread，并 Open `[thread+0x5c]`。Init2 自己先挂了一个
pending status；NULL 线程启动时也会走这条路径。

`NK_SCHED=1` 的模型：

```
0x50330a94  svc #0x4d
            sched: save supervisor context, block it
            选择 [0x80000400] = 0x80601830（NULL thread）
            0x80540000..0x80542000 上构造 SVC 上下文：
              pc = 0x5031f144, sp = 0x80541ff0, cpsr = ...0053
            完成 supervisor 的 status 0x802fff8c
            0x80530000 重新挂一个 KRequestPending 供 guest 交接
0x5031f144  NULL thread: Kern::Init3 ...
  0x50331308  [thread]->vtable+0x20 = 0x50321088
  0x50321098  -> 0x50318398: 消费 0x80530000 的 status
  0x50318398  [0x80001c90] = 0x1c, [0x80001ca4] = thread；Open 信号量
            sched: hand-off 完成 -> preempt 回 supervisor（更高优先级）
0x50330a98  supervisor: [sp] == 0 -> 不再 KERN 6
0x50330aac  Init2 继续（EUser RThread::Create 0x5032e300）
0x503360d4  null call：多线程 CObjectIx/B7e 模型不足
```

结果：**440,623 条、1 IRQ、0 undefined/unbound/recovery**。

### 2.10 round 34：保留 live 对象图、status 唤醒、Init3 HAL gate、异常栈

round 34 先证明 round-33 的 `0x503360d4` 是 B7e stand-in 自己造成的。
每次发布 current thread 时，hook 覆盖了 kernel 已经建好的三个字段：

| 字段 | 真实值（NULL 线程） | 被覆盖成 |
|---|---|---|
| `DThread+0x18` `DProcess*` | `0x80600d48` | `0x80003200` (B7E_PROCESS) |
| `DThread+0x5c` 请求信号量 | `0x806019e0` | `0x80003f00` (TLS) |
| `DThread+0x64` `CObjectIx*` | `0x806019c0` | `0x80003300`（其 `[0]` 为 0） |

`0x5033606c` 是 CObjectIx 的 close/remove 路径：循环 `At()` 后，
在 `0x503360c4` 取 `[index]->vtable` 并调 `+8`。真实 index 的 vtable
是 `0x503b36f8`（`CObjectIx::NewL` `0x50384d24` 安装）；stand-in 没有
vtable，于是 `PC=0`。

`NK_B7E_LIVE=1` 只在字段为空/不是 live object 时补 stand-in：

```
B7e: thread 0x80601830 keeps live process 0x80600d48
B7e: thread 0x80601830 keeps request semaphore 0x806019e0
B7e: thread 0x80601830 keeps object index 0x806019c0
```

之后还暴露了三个问题：

1. **status 唤醒**：NULL 线程第二次 `Kern::StartThread` 交接在
   `0x503183b4` 直接把 0 写进 supervisor 的 `TRequestStatus`，
   不碰 harness dummy `0x80530000`。旧模型只在 dummy 被写时抢占，
   漏掉这次唤醒，NULL 线程继续第三次交接，`[0x80001784] == 0`，
   `0x503221e0` → `Kern::Panic("PLAT", 0x73)`。scheduler 现在每条
   指令边界检查保存的 status（`sched: supervisor status ... completed`）。
2. **Init3 HAL gate**：`0x5031f154` 取 HAL object 3（`[0x800003ac]`
   vtable+0x108，`r1=3`），对返回对象调用 `vtable+0x48`
   （`Request(0xd,0,0)`），然后轮询 `[0x800004cc]`。stand-in 在
   `B7E_HAL_REQ` 里置 1 并返回，boot 才能继续。
3. **异常栈重叠**：supervisor 的 SVC 栈会增长到 `0x802ff...`，历史
   布局的 IRQ 栈顶是 `0x802f4000`，IRQ frame 覆盖被中断函数的
   saved LR，返回时 `PC=6`。live 模式把 IRQ/UND/ABT/FIQ/USR 放到
   `0x80140000..0x80240000`；同时 `bank_load()` 不再用“栈必须在
   3 MiB 内”来否决 preset bank sp。

随后 boot 进入 `Kern::Init3` 的 executive timing 循环：

```
0x503343cc  push {r4,lr}
0x503343d0  bl 0x5032211c        ; 读 [0x40000800]
...
0x503343e4  ldr r2,[r0,#0x54]
0x503343e8  tst r3,r2
```

结果：**5,999,982 条、14 IRQ、0 undefined/unbound/recovery**，
`sp=0x802fffe0`，停在 `0x5032211c` 的预算边界。不是 CPU fault。

### 2.11 round 35：hand-off 完成与 Init3 死锁

round 34 的 6M 运行不是 idle，而是死锁。scheduler 在
`0x503183bc` 抢占 NULL 线程——这个位置在 `Kern::StartThread`
hand-off 内部，`0x503183b4/b8` 已经消费了**上一个** request，但
新的 supervisor request 还没被消费，于是：

```
pending-slot [0x80001784] = 0x802fff8c
supervisor 0x80601078 state=3 status=0x802fff8c val=0x80000001
NULL       0x80601830 state=2 pc=0x5033130c
```

`NK_SCHED_DEFER=1` 把抢占推迟到 hand-off 返回点 `0x5033130c`
（或 2000 条超时）。于是：

```
sched: switch #3 -> thread 0x80601830 pc 0x5033130c
sched: supervisor status 0x802fff8c completed; runnable again
sched: thread 0x80601078 blocks ... insns=460289
sched: thread 0x80601078 blocks ... insns=463666
sched: thread 0x80601078 blocks ... insns=464336
```

supervisor 在两次 wait 之间推进了约 20k 条（441,434 -> 460,289），
但最后一次 wait 仍是 pending。NULL 线程只在 `0x5031f1xx` 的
`Kern::Init3` timing loop 里计算 timeout，不再做 hand-off。堆里只有
两个 `DThread`（`0x80601078`、`0x80601830`），timer queue
`[0x80001c34]` 的 `+0x10/+0x14` 指向自己（空）。

结论：下一个阻塞不是 CPU/显示，而是 **handle `0x32` 的
thread-start completion / DFC 线程**。`RThread::Resume(0x32)` 经
`0x50334fc0 -> 0x50318410 -> CObjectIx::At(0x80601210, 0x32)` 得到
0（进程 index 没有 entry），于是走 `0x50334fdc` 的 fallback：
设一个 status、等 current thread 的 hand-off。没有第三个线程来
完成它，supervisor 就死锁。

结果：**5,999,983 条、14 IRQ、0 undefined/unbound/recovery**，
stop 在 `0x50312720` 的预算边界（defer 模式）。不是 fault。

### 2.12 round 36：MMIO 写来源，排除 0x41000000 的误导

MMIO 写日志现在包含 `pc`/`lr`。这能定位 16-bit store（`nk_w16` 不走
word write-watch）。在 2M 的运行里，`0x41080000..0x41083fff` 被
0xffff 填满，第一笔写在：

```
[mmio] write 0x41080000 = 0 (2) pc=0x503164cc lr=0x503163f4
[mmio] write 0x41000300 = 0xc000432 (4) pc=0x50310bc8 lr=0x50310bbc
```

这不是 LCD framebuffer。`0x503163f4` 起的循环读 `0x41000000` 的
region descriptor，并把 4-byte entry 复制到 `0x41080000`：
`0x41000000` 是源表，`0x41080000` 是目标表，`0x41000300/304` 是
descriptor 控制字。display driver 还要从真正的 UI/显示路径找。

---

### 2.13 round 43：真实 SVC exception 模型

`NK_SWI_DIRECT=0` 之前不是“真实 SVC”：解释器把 `svc` 打印后当
no-op，所以 1.5M 的 FbServ 运行没有进入 kernel。`NK_SWI_EXCEPTION=1`
现在调用 `exception_enter(NK_MODE_SVC, vector, lr=pc+4, spsr=cpsr)`，
进入 `0xffff0008`（CP15.V=1）或 `0x8`。kernel 的 SVC handler
`0x50314f30` 读 `[lr-4]` 的指令、索引 service table 并分发。

handler 先调 `[0x80000f34]` 的 mask-ROM pre-handler；direct E32 entry
下该全局为 0，`ldr pc,[r12,#-4]` 会跳 0。harness 在 high-vector page
安装一个零返回 hook 对象作为 boot state：

```
[0x80000f34] = 0xffff0b04
[0xffff0b00] = 0xffff0b10   ; ldr pc,[r12,#-4] 取到的函数指针
[0xffff0b10] = mov r0,#0; bx lr
```

结果：kernel boot 跑 **11,114 条**，返回 boot sentinel `0xdead0000`
（kernel 的 EUser import stub 是 user-style SVC，需要 user-mode caller）；
direct FbServ 只跑 **56 条**并 null-return，user-SVC 返回路径仍缺
current-thread 状态。

---

### 2.14 round 44：user/kernel SVC selector

真实 SVC 模型下，FbServ 的第一条系统调用是：

```
0x50392b88  ef00006c   svc #0x6c
```

kernel handler `0x50314f30` 用 immediate 的 **bit 23** 区分
user/kernel。`0x6c` 没有该位，handler 走 kernel-side 路径，返回
boot sentinel/0，而不是回 app。flat image 把 app 的 import 绑到了
kernel-side EUser stub 表，stub 缺少 user marker。

把 EUser stub 表的 SVC 都标上 bit 23（`NK_USER_SVC=1`）还不够：
handler 随后从 dispatch table 取到 `0xe59ff028` 并跳到这个指令字。
user path 期望的是另一种 table/entry 格式。这是下一个 loader/ABI
frontier。

---

### 2.15 round 45：app 路径的 USR 栈、B7e 顺序与 DFC queue

直接运行 FbServ 时，三处 boot state 必须补齐：

1. **USR bank SP**：初始化为 app 的 `NK_SP`（`0x80580000`），且
   `stack_in_ram()` 使用 harness 实际映射的 RAM top（`NK_RAM_EXTRA`），
   否则 SVC 返回会把 app 栈换成 preset `0x80240000`。
2. **B7e hook 顺序**：先安装 `[0x800017d4]` 的 watch，再发布初始 fake
   thread，否则 fake thread 没有 `+0x18/+0x5c/+0x64`，第一个 executive
   call 读到 null request semaphore。
3. **DFC queue**：`[0x80001c28]` 初始化为空 TDblQue（`NK_DFC_EMPTY=1`），
   否则第一条 SVC 的 DFC processor 会调用垃圾 entry。

结果：direct FbServ + real SVC 跑满 **2,000,000 条**，停在
`0xffff0008` / `0x5039865c` 的 `WaitForAnyRequest` 循环，0 fault。
direct-SWI 路径也到 500k 预算，但出现 `0x600000` wild clear。

---

### 2.16 round 47：EwSrv export 的 Thumb +2 修正

`SplashScreen.exe` 调用 EwSrv 的 export slot `0x506ce7d0`，ROM build 存
的是 `0x506cbf1d`，而真正 Thumb prologue 从 `0x506cbf1e` 开始：

```
506cbf1c: ec ff          ; 前一条指令的尾部/填充
506cbf1e: 20 1c 10 bc ... ; adds r0,r4; pop {r4}; ...
```

`NK_EWSRV_SNAP=1` 把它改成 `0x506cbf1f`（Thumb bit + 正确入口），
等价于 E32 loader 的 export fixup。修正后 SplashScreen 跑满
**2,000,000 条**，停在 request-semaphore Wait service
`0x503244e4..f4`，0 fault。

### 2.17 round 62：app entry 的 allocator / StartThread / 共享 EUser 表

三条与 app-driven 路径直接相关的结论：

1. **HLE allocator cell header**：guest `RHeap::ReAlloc` 从 `[ptr-4]`
   读 cell size。旧 HLE allocator 在该 word 写 `'HLEH'`，导致
   `0x484c4544` 字节的 wild `Mem::Copy`。现在 `[ptr-8]` 是 HLE
   private size，`[ptr-4]` 是 `size+4`。
2. **StartThread completion**：SplashScreen 的 EUser wrapper 发
   `svc #0x76`（bit 23 置位，走 mask-ROM user path），然后轮询
   `TRequestStatus`。`NK_USER_SVC_KERNEL=1` 清掉该 stub 的 bit 23，
   让 kernel service table 进入 `0x5032557c -> 0x503312d4`；
   `NK_START_HLE=1` 让 bring-up DThread vtable+0x20 完成 `[r3]`。
3. **共享 EUser export table**：`config/imports-r29-6600.txt` 直接写
   EUser .edata slots（例如 `0x503b4f10`），kernel 需要 K-3 目标，
   但 app 的同一 import slot 链接的是原 export。kernel map 应用后
   app 会拿到错函数。direct-app 运行必须省略 `NK_IMPORTMAP`。

修正后的 app frontier：`operator new(4)` 返回 `0x80600008`，vtable
仍为 0；`0x509eef14 ldr r2,[r0,#8]` 读到 `0xe59ff028`，
`0x509eef1a` 跳过去，`lr=0x509eef1f`。下一步是 per-consumer EUser
import table 或 app import-name map。

### 2.18 round 63：第一个 app-side EUser import rebind

SplashScreen 的 `0x503b4338` slot 期望 CHeartbeat 风格构造器（对象建好
后用 vtable+8、`r1=3` 调用），ROM slot 却是 `operator new`
（`0x503963dc`，zeroed object）。`config/imports-app-6600.txt` +
`NK_APP_IMPORTMAP` 把该 slot 重绑到 ROM export index 747
（`0x50383c84`）。该函数分配 0x10 字节 CBase、安装 vtable
`0x503b359c`、分配 0x40 字节 backing store，并自己完成同样的
vtable+8/`r1=3` 调用。

结果：静态初始化不再崩在 `0x509eef12`，`0x80600008` 得到 vtable
`0x503b359c`，360 条后干净返回 `0xdead0000`。仍无 framebuffer 写入；
下一步是 splash main/active object 的驱动方式（EStart / 线程 /
active scheduler）。

### 2.19 round 64：TTrap rebind 进入 app main，SVC return self-loop

第二个 app-side rebind：`0x503b4980` 是 app 的 TTrap wrapper，ROM slot
里是 string helper `0x50396ca8`，返回非零指针，导致 app 认为初始 TRAP
失败、跳过 `0x509ef5fc`。重绑到 `0x5038cae8`（TTrap::Trap）后，app
进入 main/constructor 路径。

该路径第一条 `User::Alloc` 的 `svc #0x6c`（`0x503988f8`）其实正常
返回（`0x50314f78 -> bx lr -> 0x503988fc`）。真正的问题在后面：
`0x50383c74/7c` 对 `0xe59ff028` 写 2 笔 MMIO（调用点 `0x50383ec0`，
destination `r5=0xe59ff028`），之后某个 SVC 才在 `0x50314f78` 形成
`bx lr` self-loop（lr=0x50314f78）。清掉全部 9 个 EUser SVC stub 的
bit 23（`NK_USER_SVC_KERNEL=2`）仍不解决。

`r5` 的来源是 `0x509ef612 -> 0x509ef78c -> 0x50383e50 -> 0x50383e80`
调用链；进入 `0x50383e80` 时 r0=0、r1=`0x54442d18`，函数把 r0 当
descriptor/TDes16Overflow 解引用 `[r0+0xc]`，从低地址读回
`0xe59ff028`。因此是 **null descriptor/overflow 参数**，不是 cleanup
stack 溢出；下一步查 `0x509ef78c` 的 import/ABI。

实验 map 在 `config/imports-app-main-6600.txt`；默认 app map 仍只做
CBase rebind。验收 `tools/test_round64.sh`。

### 2.20 round 66：low allocator rebind 消除 null descriptor

根因是 `0x509ef5fc` 的 `operator new(0x68)` 走 EUser export index 2
（slot `0x503b379c`）。app 期望 `User::Alloc`，ROM 原始 slot 却是另一个
低 ordinal 函数并返回 0。把该 slot 重绑到 `0x503988f0`
（`config/imports-app-main-alloc-6600.txt`）后，`0xe59ff028` 的 MMIO
写完全消失；framebuffer 仍无像素。剩余 blocker 是 app main 的
StartThread/SVC 路径，仍在 `0x50314f78` self-loop，最终寄存器
`r1=0x32` 与 thread start handle 一致。验收 `tools/test_round66.sh`。

### 2.21 round 68：direct entry 只做初始化，不绘制

把 EwSrv slot `0x506ce44c` HLE 成 zero-return stub `0xffff0300` 后，
direct SplashScreen 入口干净返回 `0xdead0000`（1,694 条），
`mmio: 0 reads, 0 writes`，framebuffer 0 像素。`0x509ef1e4` 的 EwSrv
调用只是初始化/清理，不是绘制。真正的 driver 必须来自 EStart、kernel
创建的 process/thread，或 active object。验收 `tools/test_round68.sh`。

EStart.exe 直接入口（`0x503da4a5`）是候选 driver：119 条后在
`lr=0x503da5b9` null-call（`r5=0xe59ff028`），经 `0x503db628` stub
到 slot `0x503b6b38`；这是 EStart 的 import 未绑定。该 slot 属于
uid3 `0x100039e8`（export_dir `0x503b6b38`，ordinal 2）；实际函数表在
`0x503b6b30`（两项都是 `0x503b53f5`），`0x503b6b38` 为 0，需要
export_dir/import fixup。

### 2.22 round 69：EStart 首个 import 绑定

`config/imports-estart-6600.txt` 把 EStart slot `0x503b6b38` 重绑到
`0x503b53f5`。EStart 不再 119 条 null-call，而是跑满 **200,000 条**，
停在 kernel SVC/pre-handler 路径 `0x50314f68`；`mmio: 0 reads,
0 writes`，framebuffer 仍 0 像素。下一步是它等待的线程/信号量事件。
验收 `tools/test_round69.sh`。

### 2.23 round 70：EStart wait HLE 与 zero-vtable frontier

加 `NK_WAIT_HLE=1` 后，EStart 从 200k wait spin 推进到 **12,136 条 +
1,720 次 MMIO 读**，随后停在 zero-vtable 对象：

```
r5 = 0x80600000, [r5] = 0
0x503dac78  ldr r2,[r0,#8] -> 0xe59ff028
0x503dac7e  bl 0x503db35c (bx r2)
lr = 0x503dac83
```

对象来自 EStart constructor `0x503db640 -> slot 0x5034c638`
（静态值 `0x5034c74d`）。重绑该 slot 到 `0x50383c84` 未改变结果。
`r5=0x80600000` 的分配实际来自
`0x503dac48 -> 0x503db560 -> slot 0x503b4f14`（静态
`0x503a35b4`）；把该 slot 也重绑到 `0x50383c84` 仍不改变，说明它
不是 CBase-style constructor。framebuffer 仍 0 像素。验收
`tools/test_round70.sh`。

### 2.24 round 71：EStart global CBase rebind

`0x503b4338` 是 EStart 的 global-object/CBase getter。ROM slot 是
`operator new`（`0x503963dc`），返回 zero-vtable 内存。把它也重绑到
`0x50383c84` 后，EStart 从 12,136 推进到 **13,162 条**，越过
zero-vtable 对象；新 frontier 是 `0x503ce69c` 的 `bx r1`，
`r1=0x00a04d08`（不是代码），`lr=0x503ce6a1`。`r1` 来自
`[r0+0xc]`，而 `r0=[r4+0x14]`；说明 generic CBase vtable
`0x503b359c` 不是 EStart 真实 class vtable。验收：
`tools/test_round71.sh`。

### 2.25 round 72：app import slot / EUser export 的 2-entry offset

slot `0x503b4338` 不是 EUser export 745，而是对应 export **747**：

```
slot 静态值 = export 745 = 0x503963dc  (operator new)
app 期望   = export 747 = 0x50383c84  (CBase constructor)
```

两者相差 2 个 entry。这就是为什么 ROM slot 是 operator new、而
SplashScreen 和 EStart 都需要重绑到 `0x50383c84`。验收：
`tools/test_round72.sh`。

### 2.26 round 73：bad dispatch 是 service-start handshake

round-71 的 `0x503ce69c` 调用来自 EStart `0x503da74a ->
0x503db3dc`，slot `0x503cf984` 的值是 `0x503ce691`。EStart 传的是
stack descriptor，而 ROM 函数把它当 CBase 对象读
`[obj+0x14] -> [0xc]`。把该 slot HLE 成 zero-return stub 后，EStart
又跑满 200k，回到 `0x50314f78` wait loop（handle `0x32`），
framebuffer 仍 0 像素。说明这是 **service-start handshake**；下一步
需要 minimal scheduler/server model。验收 `tools/test_round73.sh`。

### 2.27 round 74：nested SVC return fix

EStart 的 wait 从 SVC mode 进入 SVC。`exception_enter` 把 SVC bank LR
覆盖成 PC+4，handler 的 `mov lr,pc` 又覆盖寄存器，`movs pc,lr` 无法
恢复 caller，最终在 `0x50314f78` self-loop。新增 `NK_NESTED_SVC=1`：
nested SVC 保留 caller LR，`movs pc,lr` 通过 bank LR 返回 caller。
EStart 的 wait 返回后停在 `0x50398660` 的 wait-status check，不再撞
`0x50314f78`；framebuffer 仍 0 像素。验收 `tools/test_round74.sh`。

### 2.28 round 75：wait 退出后立即重试 StartThread

把 wait-status loop 分支 `0x50398664` NOP 掉后，EStart 退出 wait，
但立刻回到 `0x503998b0` 的 `RThread::Resume/StartThread`（SVC 0x76，
handle `0x32`）。说明这个 wait 等的是**真实启动的线程**；下一步需要
给 handle 0x32 一个 DThread/server 对象，而不是继续 HLE status。
验收 `tools/test_round75.sh`。

### 2.29 round 76：DThread clone 仍不能完成 wait

在 `0x80004600` 克隆一个同 vtable/process/request/objidx 的 DThread，
并接到 object-index fetch literal `0xffff041c`，EStart 仍停在
`0x50398660`，`[r5]=0x80000001`（KRequestPending）。说明缺的是
**真实 request/server completion**，不是另一个 DThread 形状的对象。
验收 `tools/test_round76.sh`。

### 2.30 round 77：direct dispatch 仍撞同一 handshake

`NK_SWI_DIRECT=1` + `NK_SWI_COMPLETE=0x4d` 下，EStart 仍停在
`0x00a04d08`（12,305 条、1,719 次 MMIO 读、framebuffer 0）。说明
EStart 的 blocker 是 service-start handshake，与 SVC 模型无关。
验收 `tools/test_round77.sh`。

### 2.31 round 78：fake scheduler thread 进入 EStart server entry

`NK_SCHED_FAKE=1` 在 `0x80004600` 预建 scheduler slot 并把
`[0x80000400]` 指向它；`NK_SCHED_ENTRY=0x503db158`、
`NK_SCHED_STACK=0x80560000`。EStart wait 时 scheduler 切进 server
entry。entry 跑约 100 条后在 `lr=0x503db18f` null-call（经由
`0x503db454 -> slot 0x503b3d14 -> 0x503a2960`，pc=0）。
framebuffer 仍 0 像素。验收 `tools/test_round78.sh`。

### 2.32 round 79：scheduler auto-complete 让 EStart server 跑满 200k

`NK_SCHED_AUTOCOMPLETE=1` 在切线程后完成 blocked thread 的 status
并重新标 runnable。server body entry `0x503da675` +
`NK_SCHED_R0=0x8057ffc8` 下，EStart server 跑满 200,000 条，最终停在
`0x5038d724` 的 LDMDB/STMDB copy loop（destination
`0x65d8b834`/`0x4b6d61f8`），期间 646,007 次 MMIO 读 / 642,561 次
写。framebuffer 仍 0 像素。验收 `tools/test_round79.sh`。

### 2.33 round 80：Mem::Copy clamp 越过 wild copy

`NK_MEMCOPY_CLAMP=1` 在 Mem::Copy `0x5038cfe0` 把 length > 0x100000
或 src/dst 越界的 copy clamp 成 0。server 从 200k MMIO storm 推进到
**26,652 条 + 3,441 次 MMIO 读 / 22,928 次写**，停在
`lr=0x503da6d5` 的 null call（`r3=0xe59ff028`）。framebuffer 仍
0 像素。验收 `tools/test_round80.sh`。

### 2.34 round 81：fake stack sentinel 不足

`NK_SCHED_STACK_FILL=0xdead0000` 把 fake thread stack 填成返回
sentinel，但 EStart server 仍在 `0x503da6ee` 的 epilogue `bx r0`
null-call（r0=0），因为 `sp=0x80562020` 超出 fake stack
`0x80560000..0x80562000`。该 entry 需要真正的 StartThread
frame/callback。验收 `tools/test_round81.sh`。

### 2.35 round 82：server run/return cycle 完成

`NK_SCHED_STACK_EXTRA` 在初始 sp 之上额外映射/填充 sentinel；
`NK_SCHED_EXIT` 在 fake thread 返回 `0xdead0000` 时 retire 并恢复
supervisor。server 干净返回（26,652 条），supervisor 恢复后在
29,295 条时又撞 `0x00a04d08`（3,441 次 MMIO 读 / 22,928 次写），
framebuffer 仍 0。验收 `tools/test_round82.sh`。

### 2.36 round 83：supervisor bad dispatch 不能简单 HLE

把 slot `0x503cf984` HLE 成 zero-return stub，supervisor 从
`0x00a04d08` 推进到 30,815 条，但进入 EUser TTrap/leave 路径，在
`lr=0x5038cb70`（`r1=0xfffffff8`）null-call。返回 0 不是有效路径；
下一 blocker 是该 dispatch 需要的真实 object/argument。
验收 `tools/test_round83.sh`。

### 2.37 round 84：EUser slot neighbor sweep 也不绘制

把 slot `0x503cf984` 换成相邻表项 `0x503ce719`、`0x503c9e99`、
`0x503c9c2d`，都在 30k–31k 条 null-call 或回到 `0x00a04d08`
leave，framebuffer 仍 0。blocker 是 supervisor object/argument，不是
单个 slot target。验收 `tools/test_round84.sh`。

### 2.38 round 85：supervisor 把 stack params 当 CBase

在 `0x503ce69c` 处 `this=0x8057ffd8`，`[this+0x14]=0x503da4cd`
（代码返回地址，不是 vtable）。EUser 函数把 EStart 的 stack params
block 当成 CBase，读 `[this+0x14+0xc]` 得到 `0x00a04d08`。下一 fix
是构造/传入真实 CBase，而不是换 slot。验收 `tools/test_round85.sh`。

### 2.39 round 86：只换 vtable 指针仍会 leave

`NK_SUPERVISOR_OBJECT_FIX=1` 在 `0x503ce696` 把 `[this+0x14]` 写成
B7e vtable `0x80003040`。`0x00a04d08` 消失，但 `+0xc` 变成
zero-return stub，supervisor 在 30,988 条进入 EUser TTrap/leave
（`lr=0x5038cb70`，`r1=0xfffffff8`）。需要真实 class
vtable/method，而不只是一个合法指针。验收 `tools/test_round86.sh`。

### 2.40 round 87：真实 vtable/method 也救不了 stack params

把 `[this+0x14]` 指向 `0x503b36d0`（+0xc 是真实方法
`0x5038681c`），supervisor 仍在 30,852 条 null-call；其他候选
vtable 也失败，framebuffer 仍 0。`this` 是 EStart 的 stack params
block，不是 class 实例；需要真实对象实例（连同字段）。验收
`tools/test_round87.sh`。

### 2.41 round 88：global CBase 当 this 也失败

`NK_SUPERVISOR_THIS` 强制 `this=0x80600008` 时 supervisor 在 29,295
条跳到数据地址 `0x80000500`；`this=0x80600000` 则 null-call。两者都
无 framebuffer。global CBase 也不是所需对象；必须恢复真实 class
instance/server response。验收 `tools/test_round88.sh`。

### 2.42 round 89：callback 收到 stack params，不是 CBase

watch `0x503da6f0`：`0x503db2dc -> 0x503da6f0`，`r0=0x8057ffc8`
（EStart stack params），`r1=0xd`。该函数期望 `this`，但回调传的是
params，后续 EUser 把 `[this+0x14]` 当 vtable，落到
`0x00a04d08`。callback/object ABI 不匹配；需要真实
server/class instance。验收 `tools/test_round89.sh`。

### 2.43 round 90：更正 —— EStart 真实 main 与 import map

`0x503da4a4`（静态构造遍历器）调用真实 main `0x503db29c`。main 在栈
上建 **0x24 字节 params block**，以 `r0 = sp` 调用 14 个子步骤
（21 处 `bl`）；这些是接收 params 的自由函数，不是 CBase 方法。
round 78 起 fake scheduler 伪造调用，才出现“stack params as CBase”，
round 85–89 的结论撤回。

EStart 的 56 个 thunk：30 个 EUser + **12 个 EFSrv.dll**
（`0x503cf918..0x503cfcdc`，uid3 `0x100039e4`，241 exports）+
`0x5034c6xx`/`0x503b6b30`；3 个未解析（`0x503cfcd8`、
`0x50a1f06c`、`0x50a1f070`）。**30 处调用进入 EFSrv 槽**
（open/write/read/mount）。真正 blocker 是 EFSrv 文件服务器不可用。
验收 `tools/test_round90.sh`。

---

## 3. EUser 导入映射

EKA1 import stub：

```
ldr ip,[pc]      ; e59fc000
ldr pc,[ip]      ; e59cf000
.word <slot>     ; 指向导出 image 的 .edata entry
```

kernel 链接时使用的 EUser `.def` 比通用 7.0 列表少 1 个导出，ROM 里的
EUser 少 4 个，因此 **K>=6 时 ROM 导出 = K-3**。boot profile：

```
config/imports-r29-6600.txt
  236 overrides = 232 K-3 + 1 local exception (K=1361)
                + 2 low specials + 1 kept
```

时间簇（round 29 起走 K-3）：

| K | 符号 | 目标 |
|---|---|---|
| 294 | `TTime::DateTime()` | `0x503a4020` |
| 970 | `TTime::SecondsFrom(...)` | `0x503a4380` |
| 1069 | `TDateTime::Set(...)` | `0x503a3900` |
| 1375 | `TTime::TTime(const TDateTime&)` | `0x503a3af8` |
| 1361 | TStack/TBuf 构造（local exception） | `0x503a023c` |

ELocl 的唯一 export hole（ord 20）由
[`config/imports-6600.txt`](../config/imports-6600.txt) 绑定。

解释器语义要点（round 29）：

- `SMULL/UMULL/UMLAL/SMLAL` 必须解码（`00001 U A S RdHi RdLo Rs 1001 Rm`）。
- S=0 的 SUB/RSC/ADD/ADC/SBC/RSC 不得写 N/Z/C/V。

---

## 4. 结果与对照

```
忠实 + NK_SYSTEM_TIME（timer off）:
  3,000,000 insns
  0 undefined / 0 unbound IAT / 0 recoveries
  idle loop 0x50310f84（预算停在 0x5031252c）

round 30（NK_TIMER=1, NK_CPSR=0x40000053, I=0）:
  430,557 insns, 1 IRQ, 1 timer expiry
  0 undefined / 0 unbound IAT / 0 recoveries
  IRQ 0xffff0018 -> 0x50310ee0 -> [0x8000000c]=1 -> idle 退出
  stop: null call @ 0x5031ef50（caller lr=0x5031ef54）

round 31（NK_TIMERQ=1, 默认 HAL override, NK_B7E_VALID_HI=0x80400000）:
  439,177 insns, 1 IRQ, 1 timer expiry
  0 undefined / 0 unbound IAT / 0 recoveries
  ctor 0x5032aff8 -> object @ 0x80500000, vtable 0x503383bc
  vtable+0x1c（纯虚）-> 0xffff0a00 零返回 tick getter
  stop: null call @ 0x503a6148（[frame+0x48] invalid）

round 32（NK_TIMERQ=1, NK_B7E_VALID_HI=0x80a00000）:
  439,534 insns, 1 IRQ, 1 timer expiry
  0 undefined / 0 unbound IAT / 0 recoveries
  [0x800017d4] = 0x80601078（heap DThread，bootstrap SThread 已死）
  TTrap::UnTrap -> handler 0x80004200 -> 0x50383c40
  stop: KERN 6 panic @ 0x50330aa8 / halt 0x50312b88（wait 未完成）

round 33（NK_SCHED=1，其余同 round 32）:
  440,623 insns, 1 IRQ, 1 timer expiry
  0 undefined / 0 unbound IAT / 0 recoveries
  svc #0x4d -> Wait(current_thread+0x5c request semaphore)
  first switch -> NULL thread 0x80601830 @ 0x5031f144, stack 0x80540000
  0x50318398 hand-off -> supervisor 恢复 @ 0x50330a98, [sp] == 0
  stop: null call @ 0x503360d4（多线程 CObjectIx/B7e；不再是 KERN 6）

round 34（NK_B7E_LIVE=1 NK_SCHED=1，budget 6,000,000）:
  5,999,982 insns, 14 IRQ, 14 timer expiry
  0 undefined / 0 unbound IAT / 0 recoveries
  保留 DProcess 0x80600d48 / semaphore 0x806019e0 / CObjectIx 0x806019c0
  CObjectIx close -> vtable 0x503b36f8；0x503360d4 null call 消失
  supervisor status 0x802fff8c completed -> 抢占回 supervisor
  Init3 HAL object 3 Request(0xd) -> [0x800004cc]=1
  stop: budget @ 0x5032211c（executive timing 循环；sp=0x802fffe0）

round 31 control（NK_TIMERQ_MODE=ctor，仅基类 vtable）:
  430,945 insns, 1 IRQ
  vtable+0x1c = User::Panic -> panic halt @ 0x50312b88

round 31 control（NK_TIMERQ_MODE=stub，跳过 +0xc 方法）:
  438,731 insns, 1 IRQ
  KERN 6 panic @ 0x50330aa8

round 30 control（NK_TIMER=1, NK_CPSR=0x400000d3, I=1）:
  3,000,000 insns, 7 timer expiries, 0 IRQ
  idle 仍停在 0x5031252c

不装 NK_SYSTEM_TIME:
  133,950 insns
  MKERN-WD2 24 @ 0x50310b30，panic halt @ 0x50312b88
```

---

## 5. 调试开关速查

| 选项 | 作用 |
|---|---|
| `NK_BUDGET=n` | 指令预算 |
| `NK_WATCH=addr` / `NK_WATCH_HITS` / `NK_WATCH_LOG` | 命中 PC 时打印寄存器与调用环 |
| `NK_WATCH_MEM=rN:len` | watch 命中时 dump guest 内存 |
| `NK_WRITE_WATCH=addr` | 记录写入该地址的 store PC |
| `NK_TRACE=1` / `NK_TRACE_FROM` / `NK_TRACE_N` | 指令 trace |
| `NK_SPIN=1` / `NK_SPIN_MAX` | tight-loop 看门狗 |
| `NK_RECOVER=1` / `NK_RECOVER_MAX` | 故障 callee 回滚 |
| `NK_CALLMAP=path` | 调用点修复 / HLE stub |
| `NK_IMPORTMAP=path` | 绑定/重绑定 import slot |
| `NK_SWI_DIRECT=1` | EKA1 SWI call gate |
| `NK_BOOT_HANDOFF` / `NK_PRIMARY_RAM` / `NK_SYSTEM_TIME` | mask-ROM 交接 |
| `NK_B7E` / `NK_TRAPCLEAN` / `NK_EXT_STUB` | thread/process/trap/extension 模型 |
| `NK_ALLOC_HLE` / `NK_ALLOC_PC` | bump heap |
| `NK_HAL_TIMER_HZ` | fake HAL timer 频率 |
| `NK_BANKED=1` / `NK_BANK_LOG=1` | banked r13/r14/SPSR 模型 / 模式切换日志 |
| `NK_TIMER=1` | 启用 UPP timer+ICU 模型（隐含 `NK_BANKED`） |
| `NK_TIMER_LOG=n` | 打印 timer 寄存器写与到期 |
| `NK_IRQ_LOG=n` | 打印前 n 次 IRQ 入口（PC/LR/vector/CPSR） |
| `NK_CPSR=0x...` | 覆盖初始 CPSR；IRQ 测试用 `0x40000053`（I=0） |
| `NK_TIMERQ=1` | 在 `0x5031ef40` 注入 `[0x80001c34]` timer-queue 对象 |
| `NK_TIMERQ_MODE=ctor\|stub` | 仅基类 vtable / 全零返回 vtable |
| `NK_TIMERQ_ADDR=0x...` | 注入对象页（默认 `0x80500000`） |
| `NK_B7E_VALID_HI=0x...` | B7e 认为“活线程/进程”的地址上界（默认映射堆顶 `0x80a00000`；`0x80400000` 复现 round 31） |
| `NK_B7E_LIVE=1` | 保留 kernel 自己创建的 `DThread+0x18/+0x5c/+0x64`，只补缺失字段；启用 status 唤醒、低地址异常栈、HAL object 3 Request(0xd) stub（round 34） |
| `NK_SCHED=1` | 在 Init2 的 `svc #0x4d` 处阻塞并切换到 NULL 线程（round 33） |
| `NK_SCHED_LOG=n` | 打印前 n 条调度/切换/交接日志（默认 8） |
| `NK_SCHED_LR=0x...` | 触发切换的 wait 返回地址（默认 `0x50330a98`） |
| `NK_SCHED_ENTRY=0x...` | NULL 线程入口（默认 `0x5031f144`） |
| `NK_SCHED_STACK=0x...` | harness NULL 线程栈基址（默认 `0x80540000`） |
| `NK_SCHED_DEFER=1` | 把抢占推迟到 hand-off 返回点 `0x5033130c`（或 2000 条），round 35 |
| `NK_TRACE_AFTER=n` | 只从第 n 条指令后开始 trace（与 `NK_TRACE_FROM` 组合定位末期路径） |
| `NK_CALLS=1` | 停止时打印解释器 shadow call stack（LR 序列） |
| `NK_ENTRY` / `NK_STOP_PC` | 覆盖入口/停止地址 |

---

## 6. 当前 frontier

Round 34 从 round-33 的 `0x503360d4` 继续。保留 live 对象后，CObjectIx
关闭路径调用真实 vtable；status 完成唤醒 supervisor；Init3 的 HAL
object 3 / `Request(0xd)` 由显式 stub 完成；异常栈不再覆盖 SVC 栈。
Round 35 进一步把 6M 状态从“稳定 idle”纠正为“deadlock”，并用
`NK_SCHED_DEFER=1` 让 hand-off 先返回，supervisor 推进到 464,336。
现在 boot 在 6M 预算处停在 `0x50312720`，不是 fault：

```
pending-slot 0x802fff8c
supervisor state=3 status=0x802fff8c val=0x80000001
NULL       state=2 pc=0x5033130c
```

这说明还缺一个真正的 thread-start completer / DFC 线程；不是 CPU
或显示路径的问题。旧 frontier 的 timing loop：

```
0x503343cc  push {r4,lr}
0x503343d0  bl 0x5032211c        ; 读 [0x40000800]
0x503343d4  ldr r4,[r0,#4]
0x503343d8  bl 0x5032211c
0x503343dc  ldr r3,[r0,#0x58]
...
0x503343e8  tst r3,r2
0x503343f0  mov r0,r4
0x503343f4  pop {r4,pc}
```

stop 时：`sp=0x802fffe0`、`cpsr=0x80000053`、`irqs=14`、
`undefined=0`、`unbound IAT=0`、`recoveries=0`。这说明 kernel 已经
进入可运行的 executive/DFC 等待，但还没有 display/UI server 线程。

下一步：

1. **handle `0x32` / thread-start completer**：`RThread::Resume(0x32)`
   在进程 index `0x80601210` 的 `At(0x32)` 返回 0；要么按真实
   `CObjectIx::AddL` 语义登记线程，要么用 kernel 自己的
   `RThread::Create` 创建 mask-ROM 的 DFC 线程，让 supervisor 的最后
   一次 wait 有真正的 completer。
2. **DFC / WSERV 线程启动**：从 `[0x800003b8]`/`[0x800003bc]` 等
   对象表取出 DFC 与 WSERV 线程对象，给调度器真正的 ready queue，
   让 NULL 线程继续 `Kern::Init3` 并创建 UI server。
3. **真正的 ready queue/优先级**：把 `DThread+0x24` 状态、`+0x20`
   suspend 位、`+0x1c` 优先级纳入队列，允许线程被抢占后继续。
4. **`svc #0x4d` 的通用完成路径**：为请求信号量实现
   `RequestComplete` 的 signal，替换早期 wait 循环的
   `NK_SWI_COMPLETE=0x4d` 内联 HLE。
5. **Timer unit 1 / DFC**：给 timer queue 一个 pending timer，验证
   IRQ 2 → `0x503113d8` → DFC。
6. **Display controller HLE**：176×208 16bpp framebuffer、LCD 寄存器
   与 MBM/Sprite 读回，接窗口后验证第一帧。

kernel IRQ entry 的关键序列（round 30 已实际执行）：

```
0x50315258  sub lr,lr,#4
0x5031525c  push {r0,r1,r2,r3,ip,lr} ; IRQ bank
0x50315260  mcr p15,0,...            ; domain access
0x50315268  ldr ip,=0x80000f08
0x5031526c  ldr ip,[ip,#0xc]         ; optional pre-handler (currently 0)
0x50315270  cmp ip,#0
0x50315274  movne lr,pc
0x50315278  movne pc,ip
0x5031527c  bl Kern::Irq             ; 0x50311194
```

---

## 7. 限制

- 所有 `NK_*` 交接都是 harness 模型，不是真实 mask ROM 解密结果。
- `[0x80001c34]` 由 `NK_TIMERQ=1` 注入；对象用 kernel 构造器
  0x5032aff8，但 `+0x1c` 的 HAL tick getter 是零返回 stub。
- round 32 的 KERN 6、round 33 的 `0x503360d4` null call 均已关闭；
  round 34 的 stop 是 6M 预算边界 `0x5032211c`，不是 CPU fault。
- `NK_B7E_LIVE=1` 才保留 live 的 `DThread+0x18/+0x5c/+0x64`；不设该开关
  时 B7e 仍按历史模型覆盖，round-33 control 保持不变。
- Init3 的 HAL object 3 / `Request(0xd)` 由 `B7E_HAL_REQ` stub 完成并置
  `[0x800004cc]=1`；真实驱动在 mask ROM 中，尚未解出。
- live 模式异常栈位于 `0x80140000..0x80240000`；SVC 栈从 `0x80300000`
  向下增长。这是 harness 布局，不是恢复的 mask-ROM 栈指针。
- `NK_SCHED=1` 的 NULL 线程栈（`0x80540000`）和 hand-off status
  （`0x80530000`）由 harness 分配；kernel 线程创建时实际分配的栈尚未
  从对象字段解出。
- `NK_SCHED=1` 只接管 Init2 wait（LR `0x50330a98`）；其他 `svc #0x4d`
  仍走 `NK_SWI_COMPLETE=0x4d` 的内联 HLE。
- B7e 的 live-pointer 上界必须覆盖 kernel 实际堆；`0x80400000` 会把
  真实 DThread `0x80601078` 判成 transient，重新发布 boot-stack 上的
  SThread `0x802ffd00`（round-31 control）。
- CP15.V=1 由 harness 以 mask-ROM 语义设置；低地址 `0x0` 在 kernel 启动中
  被覆盖，因此 IRQ 必须走 `0xffff0000`。
- timer unit 1 / IRQ 2 / DFC 路径尚未被真实 pending timer 触发。
- display/keypad/audio/file server/app launch 未实现。
- PeaK record codec 未解出；当前 hand-off 是 trampoline stand-in。
- `references/`、`fw/`、`out/` 均为本地材料，不随仓库分发。

### 2.44 round 91：ROM 启动链与 kernel object index 为空

方案 3（kernel process loader / 真 EFSrv）的事实基础：

```
ekern.exe   169804  0x5030ff9c
EFile.exe    74520  0x503b70a0   文件服务器
EFSrv.dll    26724  0x503c9420   客户端 API，241 exports
EStart.exe    5844  0x503da440   导入 EFSrv -> 必须在 EFile 之后
Starter.exe  18720  0x509e9ac0
SplashScreen.exe 3156 0x509eee20 (+ SplashScreen.mbm)
nosstarter.ext  148 0x50341430   kernel extension
```

真实开机链是 `ekern -> EFile -> EStart -> Starter -> SplashScreen`；
EStart 的 12 个 EFSrv 槽必须等 EFile 起来，单独驱动 EStart 画不出帧。

kernel 侧：600k 指令的 boot 中，handle→object 查找经 EUser slot
`0x503b3948`（`config/imports-r29-6600.txt` 从 ROM 的 `0x50380270`
重绑到 `0x5038e4b4`，kernel 的 K-3 构建）。该查找使用的 process
object index 位于 `0x80600e98`，其 `+8` 元素计数为 **0**、`+0x14`
也为 0，因此**所有 handle 查找返回 0**，handle `0x32` 永远解析不到，
Init3 的 thread-start 无法完成。

方案 3 的第一项任务：按 `CObjectIx::AddL` 语义给该 index 填充真实
DThread/DProcess 条目。验收 `tools/test_round91.sh`。

### 2.45 round 92：kernel 自己不会启动下一阶段

实测 460k 指令的 kernel boot：

- HAL timer 只设定一次（`reload = compare = 0x632ea`、`control = 0x2`），
  在 ~430k 触发 **1 次** IRQ；下一次要到 ~836k。kernel 是**按设计
  idle**，不是缺 tick。
- timerq 的 `+0x1c` HAL tick getter 在此窗口内**从未被调用**，新增的
  `NK_HAL_TICK=1` 对现状无影响。
- `Kern::Init2` 尾部（`0x50330a88..0x50330aa8`）是**重试等待循环**：
  重填 `[sp]` → 调 `0x50336da4` wait → 仅当 status 仍为
  `KRequestPending` 才 panic KERN 6。harness 完成该 status 只会让
  supervisor 在 `0x50330a98` 反复重阻塞（440,946→442,511 约 11 次
  ping-pong），没有新工作。
- 全程只有 2 个 DThread（supervisor `0x80601078`、NULL `0x80601830`），
  **从未创建 DProcess/EFile/EStart**。

结论：kernel 不会自己加载 EFile/EStart；缺的是 **mask ROM 的 boot
hand-off**。方案 3 要求 **harness 自己执行这个 hand-off**。
验收 `tools/test_round92.sh`。

### 2.46 round 93：线程入口的 Thumb 位与 EFile 跑进 kernel

首次切换原先把新线程 CPSR 固定为 `0x40000013`（ARM），忽略 E32
`iEntryPoint` 的 bit 0。以 ARM 执行 Thumb 镜像 = 垃圾寄存器状态。

对 `EFile.exe`（uid3 `0x100039e3`，code `0x503b7104`，entry
`0x503b7105`）实测：

- 修复前：9 条 ARM 指令，`r4=r5=0`，在 `0x503b7104` 经 `bx r0`
  thunk `0x503c597c` 变 null call；
- 修复后（`sched_resume`/首次切换按入口 bit0 置 T）：**1,120 条
  Thumb 指令**，访问 `0x40000400`/`0x40000418`，停在 kernel panic
  halt `0x50312b88`（halt 时 `r0=0x40`）。

这是"真进程映像跑起来"的第一个里程碑。下一 blocker 是该 panic。
验收 `tools/test_round93.sh`。

### 2.47 round 94：EFile 越过 kernel start hand-off

`DThread::StartThread`（vtable+0x20 = `0x50321088`）把参数写入
`this+0xf8`，然后跳到 kernel 的 start hand-off `0x50318398`；后者消费
`[0x80001784]` 的 pending `TRequestStatus`。首次切换后该槽已被消费，
于是 hand-off 抛 **PLAT fault（reason `0x73`）**，kernel 在
`0x50312b88` halt。

- `NK_HANDOFF_ARM=1`：在 hand-off 前重新 armed `[0x80001784]`，
  消除该 fault。
- `NK_ALLOC_MAX`（默认 `0x100000`）：EFile 曾把 `ReAlloc` 的字节数
  传成 `0x503c7168`（自己的 rodata 表地址），原来会污染 bump heap 并
  误报 "undefined instruction"；现在干净失败（guest 得到 null）。

修复后 EFile 跑进 EUser 堆代码，跟着 null 指针在 `0x2c` 离开 image。

配套：`pc_hook3`（handoff arm）、`pc_hook4`（supervisor object fix）；
memory clamp 移到 `pc_hook2`；`NK_SCHED_MODE=auto|arm|thumb`（默认
auto）。round 79/81–83/85–89 固定 `arm` 保留历史 frontier；round 80
的预期更新为 Thumb 正确执行后的 19,262 条 / 返回 `0xdead0000`。
验收 `tools/test_round94.sh`。

### 2.48 round 95：kernel 期 import rebind 不能泄漏到 app 线程

EUser 的导出表**同时就是所有 ROM 镜像的 import slot 表**：ROM importer
的 stub 是 `ldr rX,[pc]; ldr rX,[rX]; bx rX`，字面量直接指向 EUser
`.edata` 的某一项。`config/imports-r29-6600.txt` 为 kernel 重绑了其中
**236 个**槽；同一 boot 里的 app 也走这些槽，于是调到错误的 EUser 函数，
把自己的参数当长度：EFile 把 `0x503bfcf3`（代码地址）与 `0x503c7148`
（ctor 表）当描述符长度，缓冲区涨到 `0x503c7168` 字节。

`NK_IMPORTMAP_REVERT=1` 在打补丁时记录原值，在**第一个 app 线程恢复**
时全部写回。control 运行仍报 `HLE alloc rejected: 0x503c7168`；
revert 运行无异常分配，EFile 在 868 条 Thumb 指令后进入阻塞等待。
验收 `tools/test_round95.sh`。
