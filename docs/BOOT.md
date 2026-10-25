# BOOT — Nokia 6600 启动链与运行时状态

本文记录**当前**可复现的启动路径、mask-ROM 交接状态、关键地址和调试开关。
逐轮探索过程见 git 历史；验收命令见
[`tools/test_round29.sh`](../tools/test_round29.sh)。

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
| MMIO | `0x58000000` 等 | UPP/UART/timer stub |

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
  0x5031ef18  bl 0x50310f58        ; [0x8000000c] = 0
  0x5031ef1c  bl 0x50310f6c        ; idle()

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

`[0x8000000c]` 在进入 idle 前清零；只有 IRQ/DFC handler 会重新置位。
当前 3,000,000 条是预算耗尽，不是调度器离开 idle。

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
忠实 + NK_SYSTEM_TIME:
  3,000,000 insns
  0 undefined / 0 unbound IAT / 0 recoveries
  idle loop 0x50310f84（预算停在 0x5031252c）

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
| `NK_ENTRY` / `NK_STOP_PC` | 覆盖入口/停止地址 |

---

## 6. 当前 frontier

`[0x8000000c]` 的置位者是中断/DFC handler，当前未实现。下一步：

1. timer 设备（计数、到期、中断源）；
2. banked IRQ 入口：vector `0x18` → `0x50315258`，保存/恢复
   `SPSR_irq`/`LR_irq`；
3. 让 handler 置位 `[0x8000000c]`，观察 idle 退出后的调度器路径；
4. 再用关闭诊断的新进程复测。

kernel IRQ handler 的关键序列：

```
0x50315258  sub lr,lr,#4
0x5031525c  push {r0,r1,r2,r3,ip,lr}
0x50315260  mcr p15,0,...           ; domain access
0x50315268  ldr ip,[...]
0x5031526c  ldr ip,[ip,#0xc]        ; HAL/ISR 指针
0x50315270  cmp ip,#0
0x50315274  movne lr,pc
0x50315278  movne pc,ip
```

---

## 7. 限制

- 所有 `NK_*` 交接都是 harness 模型，不是真实 mask ROM 解密结果。
- display/keypad/audio/file server/app launch 未实现。
- PeaK record codec 未解出；当前 hand-off 是 trampoline stand-in。
- `references/`、`fw/`、`out/` 均为本地材料，不随仓库分发。
