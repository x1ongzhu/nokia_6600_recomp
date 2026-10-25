# 开发进度与路线图 — Nokia 6600 (NHL-10)

最后更新：2026-10-26（round 30）
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

### 未完成

- **idle 之后的 timer-queue 对象 `[0x80001c34]`**：idle 返回后
  `Kern::Init1` 在 `0x5031ef40` 执行 `[0x80001c34] -> vtable+0xc`；该对象
  仍为 null，于是停在 **`0x5031ef50` 的 null call**。kernel export 344
  （setter `0x5032b33c`）负责安装它，但本 ROM 没有任何 image import 这个
  export，说明它来自 mask ROM/ASSP 启动状态。这是当前的 exact frontier，
  不是 CPU/解析错误。
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
| `0x80001c34` | **缺失的 timer-queue 对象**（当前为 0） |
| `0x5032b33c` | kernel export 344：`[0x80001c34]` 的 setter（已存在则 panic 0x22） |
| `0x5032b368` / `0x5032b37c` | kernel export 5 / 286：timer 队列操作 |

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
  0x5031ef40  [0x80001c34] -> null -> stop "null call" at 0x5031ef50
```

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

# 验收
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
| P2 | timer/IRQ、idle 退出、调度器/线程运行 | timer/IRQ **完成（round 30）**；调度器对象缺失，进行中 |
| P3 | 显示/键盘/音频、文件服务、S60 app 启动 | 未开始 |
| P4 | 待机 UI / 开机画面，跨设备验收 | 未开始 |

### 下一步（建议顺序）

1. **解出 `[0x80001c34]` 的 boot-state 对象**：idle 返回后
   `Kern::Init1` 必须通过 `[0x80001c34]->vtable+0xc`。优先确认它是否由
   variant `ecust.dll`（当前未加载）、HAL channel 或 mask-ROM super page
   创建；这是当前唯一阻塞点。
2. **让 scheduler/timer 对象真正创建**：如果它来自 HAL timer channel，
   补齐 vtable（不仅 `+0x5c` 频率），让 kernel 自己 new/注册。
3. **验证 scheduler 切换到初始 thread**：记录第一次线程运行/上下文切换，
   而不是停在 null call。
4. **Timer unit 1 / DFC**：给 timer queue 一个 pending timer，验证
   IRQ 2 → `0x503113d8` → DFC 路径。
5. 之后进入 display controller 与 UI 路径。

---

## 6. 已知限制

- `NK_SYSTEM_TIME`、`NK_BOOT_HANDOFF`、`NK_PRIMARY_RAM`、`NK_B7E` 等是
  **显式的 mask-ROM/HLE 状态模型**，不是从 mask ROM 解出的真实初始化。
- `[0x8000000c]` 的语义已在 round 30 验证：它由 IRQ 1 的 handler
  `0x50310ee0` 置位，idle 随即退出；I=1 时同一到期事件不会进 IRQ。
- `[0x80001c34]` 在启动结束时仍为 0；当前 stop 是 `0x5031ef50` 的
  null call，不是 CPU fault。该对象应由 mask-ROM/HAL/variant 启动状态创建。
- timer unit 1 / IRQ 2 / DFC 路径尚未被真实 pending timer 触发。
- 显示/键盘/音频/文件服务均未实现；app 二进制已放置，但无法启动。
- `references/` 与 `fw/` 是本地离线材料，不随仓库分发。
