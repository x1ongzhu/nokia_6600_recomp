# 开发进度与路线图 — Nokia 6600 (NHL-10)

最后更新：2026-10-26（round 29）
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

### 未完成

- **Timer/DFC 中断**：kernel 在 `0x50310f84` 轮询 `[0x8000000c]`；该标志在进入
  idle 前被清零，只有 IRQ/DFC handler 会置位。需要 timer 设备 + 真实 IRQ 入口
  （kernel vector `0x18` → handler `0x50315258`）。
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

# 验收
tools/test_round29.sh
for t in tools/test_*.sh; do sh "$t" || exit 1; done
```

---

## 5. 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 固件/镜像/布局/解释器/导入/启动状态 | 完成 |
| P1 | kernel 进入 idle loop | **完成（round 29）** |
| P2 | timer/DFC IRQ、调度器离开 idle、线程运行 | 进行中 |
| P3 | 显示/键盘/音频、文件服务、S60 app 启动 | 未开始 |
| P4 | 待机 UI / 开机画面，跨设备验收 | 未开始 |

### 下一步（建议顺序）

1. **Timer 设备模型**：给 UPP timer 一个计数器与到期事件，接到 kernel 的
   timer/DFC 队列。
2. **真实 IRQ 入口**：用 banked IRQ 模式进入 vector `0x18`，保存/恢复
   `SPSR_irq`/`LR_irq`，让 handler 处理并返回 idle。
3. **验证**：idle 被第一次打断后，确认 `[0x8000000c]` 的语义、调度器是否
   切换到初始线程，并记录新的 frontier。
4. 之后再考虑 display controller 与 UI 路径。

---

## 6. 已知限制

- `NK_SYSTEM_TIME`、`NK_BOOT_HANDOFF`、`NK_PRIMARY_RAM`、`NK_B7E` 等是
  **显式的 mask-ROM/HLE 状态模型**，不是从 mask ROM 解出的真实初始化。
- `[0x8000000c]` 的 IRQ/DFC 语义尚未验证；当前 3,000,000 条是预算耗尽，
  不是“系统空闲”证明。
- 显示/键盘/音频/文件服务均未实现；app 二进制已放置，但无法启动。
- `references/` 与 `fw/` 是本地离线材料，不随仓库分发。
