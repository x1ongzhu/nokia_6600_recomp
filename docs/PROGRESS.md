# 开发进度与路线图 — Nokia 6600 (NHL-10)

最后更新：2026-10-24  
目标：把 **NHL-10 v5.53.0** 固件静态重编译成可在 macOS / Linux 上原生运行的 6600；
最终里程碑是启动到 Nokia 开机画面 / 待机 UI。

---

## 1. 当前基线

| 项 | 内容 |
|---|---|
| 原始固件 | `fw/NHL105530.C1`（WD2 BT2 / WD2 ALGORITHM 容器，22.2 MiB） |
| 原始 ROM | `6600_mcu.bin`（22,285,596 字节 EKA1 ROM，链接基址 `0x50000000`） |
| Kernel | `fw/6600_kernel.bin`（168,504 字节，链接地址 `0x50310000`，入口 `0x50310054`） |
| CPU | ARM920T / ARMv4T（ARM + Thumb），UPP_WD2 |
| OS | Symbian OS 7.0s / S60 2nd Edition |
| 运行时 | 64 KiB 稀疏页表；ROM `0x50000000`、RAM `0x80000000`、high vectors `0xffff0000`、MMIO bus |
| 工具链 | Python 3 + Capstone；clang；IDA Pro 9.1（可选）；Unicorn 仅用于研究 trace |

> 旧的 103 MB `6600_mcu.bin` 没有 WD2 头、EKA1 向量表或 E32Image UID，
> 不是 6600 ROM，已被真正的 22 MiB EKA1 ROM 覆盖。

---

## 2. 已完成里程碑

| 编号 | 里程碑 | 证据 / 验收 |
|---|---|---|
| M0 | **固件格式确认**：`NHL105530.C1` 是 WD2 容器，不是老式 DCT4 chunk | `wd2.py extract fw/NHL105530.C1 6600_mcu.bin` |
| M1 | **EKA1 ROM 解出并解析** | `wd2.py info 6600_mcu.bin`：`rom_base=0x50000000`、`rom_size=0x01600000`、`kern_data=0x80000000` |
| M2 | **Kernel E32Image 定位** | UID3 `0x100058e8`，header `0x503268c0`；代码 ROM `0x32692c`，link `0x50310000`，entry `0x50310054` |
| M3 | **ROMFS 可浏览** | `wd2.py list 6600_mcu.bin` 列出 64 个条目（`AcmClassController.dll`、`HttpTransportHandler.dll`、`MmfAudioController.dll` 等） |
| M4 | **Kernel 入口可执行** | `trace_boot.py 6600_mcu.bin --kernel fw/6600_kernel.bin`：423 条唯一 Thumb 指令，停在 `0x5031140c` |
| M5 | **混合 ARM/Thumb 函数发现 + lift** | `recursive.py`：122 个函数（112 Thumb + 10 ARM）；`lift.py`：1,785 条指令中 1,777 条 lift（99%） |
| M6 | **原生化 smoke test** | `tools/build_kernel_smoke.sh` 执行真实 kernel ARM 函数 `func_50313084`，MMIO bus 记录 `write 0x58000000 = 0x1234` |
| M7 | **运行时内存模型升级** | `runtime/` 支持稀疏 64 KiB 页表、ROM/RAM/high vectors/MMIO，替代旧的平面 5.4 MB 模型 |

### 可复现命令

```sh
.venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 6600_mcu.bin
.venv/bin/python recompiler/wd2.py info 6600_mcu.bin
.venv/bin/python recompiler/wd2.py kernel 6600_mcu.bin fw/6600_kernel.bin
.venv/bin/python recompiler/wd2.py list 6600_mcu.bin

.venv/bin/python recompiler/trace_boot.py 6600_mcu.bin --kernel fw/6600_kernel.bin
tools/build_kernel_smoke.sh
```

---

## 3. 关键事实与地址

| 地址 / 值 | 含义 |
|---|---|
| `0x50000000` | EKA1 ROM 链接基址；ROM 向量表 / 异常表 |
| `0x01600000` | ROM 大小（22 MiB） |
| `0x503162b0` | ROMFS root list 实际位置（header 指针 `0x50300000` + `0x162b0` bias） |
| `0x16538` | 目录项文件地址 bias |
| `0x80000000` | kernel data / RAM 基址 |
| `0x80300000` | kernel data limit |
| `0xffff0000` | high vectors（MMU 打开后） |
| `0x00e0ca39` | UPP mask ROM 入口（不在 flash dump 中） |
| `0x503268c0` | kernel E32Image header |
| `0x32692c` | kernel 代码在 ROM 中的存放偏移 |
| `0x50310000` | kernel 代码链接地址 |
| `0x50310054` | kernel 入口（Thumb） |
| `0x5031140c` | 当前 trace 停下的 ARM 代码地址 |
| `0x50318aa8` | Thumb → ARM `mov lr,pc; bx lr` veneer 示例 |
| `0x50318ab0` | 上述 veneer 的 ARM 目标 |
| `0x50313084` | smoke test 执行的真实 ARM helper |

---

## 4. 当前阻塞（按优先级）

### B1. ARM/Thumb 互调与 E32Image loader（P0，最关键）
- 入口是 Thumb；`0x50310054` 的 `bl` 进入 Thumb handler `0x50312c62`。
- Handler 后段进入 ARM 代码 `0x5031140c`，但 CPU 仍处于 Thumb 模式，Unicorn 报
  `UC_ERR_INSN_INVALID`。
- ARMv4T 没有立即数 `BLX`；kernel 使用
  `mov lr,pc; bx lr` / `add lr,pc,#1; bx lr` veneer 在 ARM/Thumb 间切换。
- 当前 `nk_call` 只按地址查表，没有 **T 位 / 模式**；lift 后的 C 也无法在函数中间切换模式。
- E32Image 的代码在 ROM `0x32692c`，而链接地址是 `0x50310000`；loader 的拷贝、BSS
  清零、导出表 / DLL reference table / relocation 还没有完整实现。

### B2. Mask ROM 初始状态（P0/P1）
- `0x00e0ca39` 在 UPP 内部 boot ROM 中，不在固件镜像里。
- 该路径通常负责 MMU、cache、时钟和向量表的初始设置，然后跳入 kernel。
- 我们需要 runtime 里的 **mask ROM stand-in**：设定初始 CPSR/CP15/栈，映射
  ROM/RAM/high vectors，然后跳到 `0x50310054`。

### B3. 可能的 packed/压缩区（P1）
- ROM `0x310000` 起的一段是高熵数据，当前入口 trace 还没有执行到。
- 需要确认它是 kernel 的压缩 payload（`KaeP` 头在 ROM `0x124`）还是普通数据文件。
- 如果是压缩，需要实现对应解压器，否则 kernel 只能执行一部分。

### B4. 设备模型（P2）
- 还没有真正到达 UPP display/timer/keypad 的初始化；当前 MMIO bus 只打印访问。
- 需要先从 kernel 的第一次 MMIO 访问建立设备地址表，再逐个实现。

---

## 5. 接下来的开发路径

### P0 — 让 kernel 真正跑起来（下一阶段，必须先做）

**P0-1 EKA1 loader**
- 解析并实现 `TRomImageHeader` 的加载语义：
  - 代码拷贝到 `0x50310000`
  - `data` / `data_size` / `bss_size` 处理
  - `dll_ref_table`、`export_dir`、`exception_descriptor`
  - 若存在 relocation table，则应用 relocation
- 初始化 kernel 栈（`0x80300000` 向下）和入口寄存器。
- 验收：kernel 不再因为“代码没加载到链接地址”而错位。

**P0-2 模式模型**
- 在 `nk_cpu_t` 中增加 `T` 位（或 `mode` 字段）。
- `nk_call` / `nk_register` 记录每个函数的 ARM/Thumb 模式：
  - 注册时使用 `start`（even） + `mode`；
  - 调用时根据目标地址 bit0 或注册模式选择。
- 为 `bx` / `blx` / `mov lr,pc; bx lr` 增加运行时 helper，例如：
  - `nk_bx(c, target)`：根据 target bit0 切换 T，并 dispatch；
  - `nk_call_mode(c, target, mode)`。
- 修改 `lift.py`：识别 `mov lr,pc; bx lr` 并生成模式切换，而不是普通 `return`。
- 验收：`recursive.py` 能同时产出 Thumb 和 ARM 函数；lift 后的 C 在 veneer 处正确切换。

**P0-3 解释器 fallback（推荐尽早做）**
- 实现一个精简 ARMv4T 解释器（ARM + Thumb），覆盖：
  - 数据处理、移位、load/store、block transfer、乘法、MRS/MSR、BX/BLX、SWI、CP15。
- 用途：
  - 执行尚未 lift 的 thunk / 间接调用 / 自修改代码；
  - 作为 bring-up 阶段的“真值”，把 lift 后的函数逐步替换进去。
- 这是最快突破 B1/B2 的路线，也符合 recompiler 的 hybrid bring-up 模式。
- 验收：解释器能从 `0x50310054` 连续执行 >10,000 条指令，不出现 invalid instruction。

**P0-4 Trace / 验收**
- 用模式感知的 trace 复跑 kernel：
  - 目标：越过 `0x5031140c`，进入 kernel main；
  - 记录第一次 SWI、第一次 MMIO 读/写、第一次中断使能。
- 验收：kernel 到达设备初始化阶段，日志中能看到 UPP 寄存器访问，而不是 invalid instruction。

### P1 — Mask ROM stand-in 与首次设备初始化

- 实现 CP15 最小模型：
  - c1 control（MMU/cache 位）
  - c2 TTB、c3 domain、c5/c6 fault/cache、c7 cache 操作、c8 TLB
  - MMU 可以先做 flat mapping（或只实现 section mapping），cache 操作当 NOP。
- 安装 high vectors，SVC/IRQ/FIQ 至少能记录并返回。
- 建立 **MMIO 设备注册表**：地址范围 → 读/写回调。
- 从 kernel 日志提取第一批设备：
  - display controller / framebuffer
  - timers / RTC
  - interrupt controller
  - keypad
- 验收：kernel 完成设备探测，不再因为未映射寄存器崩溃；能看到 display/timer 初始化序列。

### P2 — First light（Nokia 开机画面）

- 实现 UPP display HLE：
  - 176×208、16-bit RGB565 framebuffer；
  - 将 guest framebuffer 映射到 host 窗口（SDL/Cocoa）。
- 实现 timer tick 和最小 IRQ 投递。
- 实现 keypad 输入映射（方向键、软键、数字键）。
- 验收：窗口出现 Nokia 开机 logo / 待机画面；按键能触发 UI 事件。

### P3 — UI / 应用层

- 挂载 ROMFS（`wd2.py` 已能列出条目），实现最小文件服务。
- 处理 EKA1 SWI / 内核服务：
  - 优先跑真实 kernel；对高频服务做 HLE。
- Window server / 字体 / 位图 / 资源加载。
- 验收：进入菜单、打开 Snake 或 About；能返回待机。

### P4 — 外围与收尾

- GSM/DSP/radio stub：让 UI 接受“无网络”状态。
- 音频、振动、相机、蓝牙/红外 stub。
- 性能优化：热点函数从解释器替换为 lift 后的 C。
- 打包原生可执行文件（macOS/Linux），补构建脚本和 CI。

---

## 6. 任务看板（近期）

- [ ] **P0-1** 实现 EKA1 loader（拷贝 / BSS / 初始寄存器 / export/dllref）
- [ ] **P0-2** `nk_cpu_t` 增加 T 位；`nk_register/nk_call` 支持模式
- [ ] **P0-2b** `lift.py` 支持 `mov lr,pc; bx lr` / `bx` 模式切换
- [ ] **P0-3** ARMv4T 解释器 fallback（先覆盖 kernel 用到的指令）
- [ ] **P0-4** 模式感知 trace：越过 `0x5031140c`，到达 kernel main
- [ ] **P1-1** CP15 / MMU flat mapping + high vectors
- [ ] **P1-2** MMIO 设备注册表 + 首批 UPP 寄存器
- [ ] **P2-1** LCD framebuffer → host window
- [ ] **P2-2** timer + IRQ + keypad
- [ ] **P3-1** ROMFS 文件服务 + SWI/HLE
- [ ] **P3-2** window server / fonts / first app
- [ ] **P4** radio/audio stubs + 性能与打包

---

## 7. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| E32Image relocation / packed 数据格式未知 | kernel 只能跑一部分 | 先用解释器 + trace 找到 loader 行为；对照 EKA1 文档 / N-Gage 参考 ROM |
| Mask ROM 缺失 | 初始 MMU/时钟/向量状态未知 | 写 stand-in；用 trace 逐步补齐；必要时从硬件手册推导 |
| ARM/Thumb 互调复杂 | 大量 thunk / 间接调用 | 统一模式模型 + 解释器 fallback；lift 只覆盖热点 |
| ROMFS 地址 bias / 文件格式 | 文件服务/应用加载受阻 | 已有 `+0x162b0` / `+0x16538` 规律；用 `wd2.py list` 校验 |
| 版权 / 固件分发 | 不能提交固件 | 继续 `.gitignore`；仓库只放工具和文档 |
| 范围过大 | 长期无法交付 | 以“开机画面 / 待机 UI”为第一 finish line；radio/audio 全部 stub |

---

## 8. 工程决策

1. **Hybrid 执行**：静态 lift 热点 + 解释器 fallback。不要试图一次性 lift 22 MB。
2. **Unicorn 只做研究 oracle**，不进入最终 runtime。
3. **先 boot，再优化**：P0/P1 阶段允许慢速解释器；P2 开始把热点替换为 lift 后的 C。
4. **每阶段都有可验收命令**：所有里程碑必须能由 `tools/` 下的脚本复现。
5. **固件不入库**：`fw/`、`6600_mcu.bin`、`*.C1` 全部 gitignore。

---

## 9. 变更记录

- 2026-10-24：确认 103 MB `6600_mcu.bin` 不是 6600 ROM；替换为从
  `NHL105530.C1` 解出的 22 MiB EKA1 ROM；新增 `wd2.py`、`recursive.py`、
  `trace_boot.py`、稀疏内存 runtime、kernel smoke test；更新 README /
  ARCHITECTURE / FIRMWARE-FORMAT / BOOT / config。
- 下一步：按 P0 实现 EKA1 loader + 模式感知执行，目标越过 `0x5031140c`。
