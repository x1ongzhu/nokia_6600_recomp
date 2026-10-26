# BOOT — Nokia 6600 启动链与运行时状态

本文记录**当前**可复现的启动路径、mask-ROM 交接状态、关键地址和调试开关。
逐轮探索过程见 git 历史；验收命令见
[`tools/test_round30.sh`](../tools/test_round30.sh)。

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
K=1163），新的 frontier 是：

```
0x503a6120  push {lr}
0x503a6124  bl 0x50392ba0          ; SVC 0x73
0x503a6128  ldr r0,[r0,#0x48]      ; [frame+0x48] = 0xe21440ff
0x503a6138  ldr r3,[r0]            ; reads 0
0x503a613c  ldr ip,[r3,#0xc]       ; 0
0x503a6144  bx ip                  ; null call
```

`SVC 0x73` 的 service `0x503187e8` 从 `[current_thread+0x38]` 弹出一个
trap/cleanup frame，next 写回 `+0x38`。当前 frame 指针是 `0x503a43c4`
——一个 ROM text 地址，不是可写栈 frame；它的 `+0x48` 读到该处指令字
`0xe21440ff`，所以下一次 `vtable+0xc` 落到 0。

该值来自 EUser 的一次 0x108 字节线程块复制：`0x5038d750` 的
`stmdb` 块写把 `[0x802ffd38]` 覆盖成 `0x503a43c4`（源块
`0x802ffc14`，目标 `0x802ffd54`）。也就是说 kernel 从某个
`SThread` 模板恢复 `iTrapHandler/iTrapFrame` 时，把 ROM 地址当成了
可写 frame。round 32 需要定位这个模板的来源和 `DThread` 的
`+0x38/+0x3c/+0x48` 真实布局。

control：`NK_TIMERQ_MODE=ctor` 只用基类 vtable，停在 `0x50312b88`
的 panic halt；`NK_TIMERQ_MODE=stub` 跳过 `+0xc` 方法，停在 438,731
条处的 KERN 6 panic。

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

round 31（NK_TIMERQ=1, 默认 HAL override）:
  439,177 insns, 1 IRQ, 1 timer expiry
  0 undefined / 0 unbound IAT / 0 recoveries
  ctor 0x5032aff8 -> object @ 0x80500000, vtable 0x503383bc
  vtable+0x1c（纯虚）-> 0xffff0a00 零返回 tick getter
  stop: null call @ 0x503a6148（[frame+0x48] invalid）

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
| `NK_ENTRY` / `NK_STOP_PC` | 覆盖入口/停止地址 |

---

## 6. 当前 frontier

Round 30 验证了 timer/IRQ；round 31 用 kernel 自己的构造器
`0x5032aff8` 注入 `[0x80001c34]`，并把抽象基类 vtable `0x503383bc`
的纯虚 `+0x1c` 覆盖为零返回 HAL tick getter。`Kern::Init1` 因此跨过
`0x5031ef50`，进入 kernel-start 路径。新 frontier：

```
0x503a6120  push {lr}
0x503a6124  bl 0x50392ba0          ; SVC 0x73
0x503a6128  ldr r0,[r0,#0x48]      ; [frame+0x48] = 0xe21440ff
0x503a6138  ldr r3,[r0]            ; 0
0x503a613c  ldr ip,[r3,#0xc]       ; 0
0x503a6144  bx ip                  ; null call @ 0x503a6148
```

`SVC 0x73` service `0x503187e8` 从 `[current_thread+0x38]` 弹出
trap/cleanup frame，next 写回 `+0x38`。当前 frame 的 `+0x48` 不是对象
指针，因此 `vtable+0xc` 落到 0。

下一步：

1. **对齐 `TTrap`/`CTrapCleanup` frame 布局**：确认 `+0x38` 是 cleanup
   stack top 还是 trap handler，`+0x48` 应指向什么对象；`Kern::Init2`
   在 kernel-server 线程上构造该 frame 时补上有效对象。
2. **补全 kernel-server 线程的 trap graph**：B7e 只为已发布线程建
   handler，kernel-server 线程的 `TTrap` 栈 frame 仍缺字段。
3. 观察 scheduler 是否切换到初始 thread，记录第一次上下文切换。
4. 给 timer queue 一个 pending timer，验证 IRQ 2 → `0x503113d8` → DFC。

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
- 当前 stop 是 `0x503a6148` 的 null call（trap/cleanup frame `+0x48`
  无效），不是 CPU fault。
- CP15.V=1 由 harness 以 mask-ROM 语义设置；低地址 `0x0` 在 kernel 启动中
  被覆盖，因此 IRQ 必须走 `0xffff0000`。
- timer unit 1 / IRQ 2 / DFC 路径尚未被真实 pending timer 触发。
- display/keypad/audio/file server/app launch 未实现。
- PeaK record codec 未解出；当前 hand-off 是 trampoline stand-in。
- `references/`、`fw/`、`out/` 均为本地材料，不随仓库分发。
