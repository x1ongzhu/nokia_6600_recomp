# 开发进度与路线图 — Nokia 6600 (NHL-10)

最后更新：2026-10-24  
目标：把 **NHL-10 v5.53.0** 固件静态重编译成可在 macOS / Linux 上原生运行的 6600；
最终里程碑是启动到 Nokia 开机画面 / 待机 UI。

---

## 1. 当前基线

| 项 | 内容 |
|---|---|
| 原始固件 | `fw/NHL105530.C1`（WD2 BT2 / WD2 ALGORITHM 容器，23.3 MB / 0x1635067） |
| 原始 ROM | `6600_mcu.bin`（23,285,596 字节 / 0x1634f5c flash 镜像；header `rom_size` = `0x1600000`） |
| Kernel | `fw/6600_kernel.bin`（166,592 / `0x28ac0` 字节 text，链接地址 `0x50310000`，入口 `0x50310054`） |
| CPU | ARM920T / ARMv4T（ARM + Thumb），UPP_WD2 |
| OS | Symbian OS 7.0s / S60 2nd Edition |
| 运行时 | 64 KiB 稀疏页表；ROM `0x50000000`、RAM `0x80000000`、pre-MMU 物理 RAM `0x00000000`（round 6）、high vectors `0xffff0000`、MMIO bus |
| 执行引擎 | 静态 lift 的 C + 原生 **ARMv4T 解释器**（`runtime/src/nokia_interp.c`，ARM + Thumb），带崩溃恢复、调用点修复表（callmap）、**代码范围约束**和少量 HLE 编译器运行时 |
| 工具链 | Python 3 + Capstone；clang；IDA Pro 9.1（可选）；Unicorn 仅用于研究 trace |

> 旧的 103 MB `6600_mcu.bin` 没有 WD2 头、EKA1 向量表或 E32Image UID，
> 不是 6600 ROM，已被真正的 23.3 MB EKA1 flash 镜像覆盖。
>
> **第 5 轮重要修正**：解释器的 Thumb `add/sub rd, rs, #imm3` 解码把
> bit 10（立即数/寄存器选择）用反了。此前所有 Thumb 运算类指令都在用错误
> 的操作数执行，**旧的 2,000,000 / 20,000,000 条指令 frontier 不再有效**。
> 修正后 kernel entry 正常执行 197 条指令并返回，详见 §2 M14。

---

## 2. 已完成里程碑

| 编号 | 里程碑 | 证据 / 验收 |
|---|---|---|
| M0 | **固件格式确认**：`NHL105530.C1` 是 WD2 容器，不是老式 DCT4 chunk | `wd2.py extract fw/NHL105530.C1 6600_mcu.bin` |
| M1 | **EKA1 ROM 解出并解析** | `wd2.py info 6600_mcu.bin`：`rom_base=0x50000000`、`rom_size=0x01600000`、`kern_data=0x80000000` |
| M2 | **Kernel E32Image 定位** | UID3 `0x100058e8`，header `0x503268c0`；代码 ROM `0x32692c`，link `0x50310000`，entry `0x50310054` |
| M3 | **ROMFS 可浏览** | `wd2.py list 6600_mcu.bin` 列出 64 个条目（`AcmClassController.dll`、`HttpTransportHandler.dll`、`MmfAudioController.dll` 等） |
| M4 | **Kernel 入口可执行** | `tools/build_boot_trace.sh`：12 条 Thumb 指令后停在 `0x50314c16`（Thumb→ARM 无 veneer）；旧的 Unicorn `0x5031140c` / 401 条结果已被 header 尺寸修正取代 |
| M5 | **混合 ARM/Thumb 函数发现 + lift** | `recursive.py`：131 个函数（120 Thumb + 11 ARM）；`lift.py`：1,873 条指令中 1,867 条 lift（99%） |
| M6 | **原生化 smoke test** | `tools/build_kernel_smoke.sh` 执行真实 kernel ARM 函数 `func_5031308c`，MMIO bus 记录 `write 0x58000000 = 0x1234` |
| M7 | **运行时内存模型升级** | `runtime/` 支持稀疏 64 KiB 页表、ROM/RAM/high vectors/MMIO，替代旧的平面 5.4 MB 模型 |
| M8 | **原生解释器 + 启动 trace** | `runtime/src/nokia_interp.c` 覆盖 ARMv4T ARM/Thumb、条件码、移位、乘除、load/store、LDM/STM、BX/BLX、MRS/MSR、SWI、CP15；`tools/build_boot_trace.sh` 原生跑 kernel 入口，打印精确 frontier；修复了 `nk_r32/nk_w32` 快路径 bug |
| M9 | **EKA1 header / 解释器 bug 修正** | 确认所有 EKA1 `TRomImageHeader` 都是 **0x64** 字节（kernel 的 `+0x64` 两字是 text 开头，不是 header）；修复 Thumb `BL` 返回地址（pc+4）和 ARM PC-relative load（pc+8）两个真实 bug；新增回归测试 |
| M10 | **ROM image loader + DLL 绑定** | `boot_kernel.c` 按 packed record 反向定位 text/data/edata/dllref，加载 kernel 引用的两个 DLL（`0x100065a5`、`0x100039e5`）及其 export dir；第一个 import stub 通过 `.edata` ordinal 解析并进入 DLL；`NK_CALL_INFER` 修复前几个 ARM/Thumb 调用点 |
| M11 | **扁平 runtime ROM 组装** | 新增 `recompiler/romimage.py`：恢复 448 个 `TRomImageHeader`，把 kernel + 2 个可达 DLL 放到 header 地址，把 64 KiB packed ROMFS 目录块放到 `0x50300000`，把 171 个 ROMFS 文件按线性地址放置；输出 `out/6600_runtime.bin`（正好 `0x1600000`）与 layout JSON，184 个 section **无重叠**；`boot_kernel --rom-image` 直接映射并复现同一 frontier |
| M12 | **互调调用点普查 + 运行时策略** | `romimage.py calls` 分类每个直接 ARM `BL`：kernel 3854 个（478 exact / 3222 biased / 154 unknown），DLL2 3886 个（705 / 2908 / 273）；bias 分布 `0x308×176、0x34×117、0x28×86、0x40×82…`；解释器新增 `NK_SNAP_WINDOW` 与 `NK_CALL_POLICY=0..3`，并把"调用点自身所在函数的 prologue"排除在回退候选之外，避免把调用变成自递归 |
| M13 | **崩溃恢复 + 调用点修复表 + 缺失函数尾部修复** | 解释器在每个 BL/BLX 保存完整 caller 状态；`NK_RECOVER=1` 在 callee 故障（未定义指令 / PC 越界）时回滚并把调用当作"返回 0"；`NK_CALLMAP` 可按调用点把 stale target 固定到真实 callee，并提供 `div/mod/memzero/bump-alloc` HLE；`config/patches-6600.txt` 补回 `0x5039adcc` 缺失的 `pop {r4,r7,pc}`。陪测：`tools/test_boot_recover.sh` |
| M14 | **Thumb 解码 bug 修正 + 代码范围约束 + 重新定义 frontier** | 修正 Thumb format-2（00011）bit10 立即数/寄存器选择反了的问题；新增 `Thumb add/sub immediate/register` 回归测试。解释器新增**代码范围**：只允许把调用修复到已登记 text 范围，范围外的直接调用在 `NK_RECOVER` 下按“返回 0”跳过，不再执行 ROMFS/rodata。恢复 `0x5039adb8` 的 descriptor memcpy HLE。kernel entry 现在 **197 条指令正常返回**（mask-ROM sentinel），4 次跳过、无 undefined；旧的 2M/20M 结果是 bug 假象 |
| M15 | **literal pool 重排（第 6 轮）**：`recompiler/relayout.py` 真正恢复 ROM linker 的 4 字节对齐填充 | 解码函数 → 收集 `ldr rd,[pc,#imm]` → 反查 terminator 后的 literal pool；把 **pool + 函数起点**按 packed 顺序对齐，凡最终地址是 2 mod 4 的实体前插入 2 字节。验证：entry pool `0x5031008e -> 0x50310090`，`ldr` 读到 `0x00046564`；helper `0x50312100` 的 pool `0x5031213e -> 0x50312140`；787/787 个 pool 重排后 4 字节对齐。kernel text 插入 **44 处 / 0x58 字节**。实验镜像 `out/6600_runtime_relaid.bin`（relaid text + 内核 .data 移到 `0x50400000`）boot **289 条指令**（带 callmap 315）而不是 197，并到达 UPP MMIO（`0x58120a04`、`0x58120110`、`0x58120308`、`0x59e00040`）。`tools/test_relayout.sh` 是验收脚本 |

### 可复现命令

```sh
.venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 6600_mcu.bin
.venv/bin/python recompiler/wd2.py info 6600_mcu.bin
.venv/bin/python recompiler/wd2.py kernel 6600_mcu.bin fw/6600_kernel.bin
.venv/bin/python recompiler/wd2.py list 6600_mcu.bin

.venv/bin/python recompiler/trace_boot.py 6600_mcu.bin --kernel fw/6600_kernel.bin
tools/build_kernel_smoke.sh
tools/test_interp.sh
tools/test_loader.sh
tools/build_boot_trace.sh

# assisted boot: packed sections + referenced DLLs + call repair
NK_E32=0x3268c0 NK_E32_SECTIONS=1 NK_CALL_INFER=1 tools/build_boot_trace.sh

# assemble and boot the flat runtime ROM (new)
tools/build_rom_image.sh
tools/test_romimage.sh
NK_CALL_INFER=1 ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin

# call-target census / experiments
.venv/bin/python recompiler/romimage.py calls 6600_mcu.bin
NK_E32_SECTIONS=1 NK_CALL_INFER=1 NK_SNAP_WINDOW=0x100 \
    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --e32 0x3268c0
NK_E32_SECTIONS=1 NK_CALL_INFER=1 NK_CALL_POLICY=3 \
    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin --e32 0x3268c0

# bring-up image (patched missing tail) + recovery boot + call-site fixups
tools/build_bringup_image.sh
tools/test_boot_recover.sh        # entry returns in ~200 instructions, 4 skips

# the same run by hand (2,000,000 instruction budget; the entry returns early)
NK_BUDGET=2000000 NK_RECOVER=1 NK_CALL_INFER=1 \
NK_SNAP_WINDOW_ARM=0x200 NK_SNAP_WINDOW_THUMB=0x400 \
NK_CALLMAP=config/callmap-6600.txt \
    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime_bringup.bin

# round 6: literal-pool relayout + experimental flat image
.venv/bin/python recompiler/relayout.py analyze 6600_mcu.bin
.venv/bin/python recompiler/relayout.py build 6600_mcu.bin out/6600_kernel_relaid.bin
.venv/bin/python recompiler/relayout.py verify 6600_mcu.bin out/6600_kernel_relaid.bin
.venv/bin/python recompiler/relayout.py image 6600_mcu.bin \
    out/6600_runtime.bin out/6600_runtime_relaid.bin
tools/test_relayout.sh
```

---

## 3. 关键事实与地址

| 地址 / 值 | 含义 |
|---|---|
| `0x50000000` | EKA1 ROM 链接基址；ROM 向量表 / 异常表 |
| `0x01600000` | header 声明的 ROM 大小（22 MiB；文件实际 0x1634f5c） |
| `0x3162b0` | ROMFS root list 的 **文件偏移**（不是地址） |
| `0x50300000` | ROMFS root list 的 **runtime VA**（header 存储值）；64 KiB packed 目录块从 0x3162b0 映射到这里 |
| `0x5043fc90` | 第一个 ROMFS 文件的 runtime VA；文件按 `va - 0x50000000` 线性存放，共 171 个 |
| `0x80000000` | kernel data / RAM 基址 |
| `0x80300000` | kernel data limit |
| `0xffff0000` | high vectors（MMU 打开后） |
| `0x00e0ca39` | UPP mask ROM 入口（不在 flash dump 中） |
| `0x3268c0` | kernel `TRomImageHeader` 的 packed 文件偏移 |
| `0x5030ff9c` | kernel header 在扁平 runtime image 中的地址（`code - 0x64`） |
| `0x326924` | kernel 代码在 packed 文件中的偏移（header + 0x64） |
| `0x50310000` | kernel 代码链接地址 |
| `0x50310054` | kernel 入口（Thumb；`nop; push {r4,r7,lr}`） |
| `0x5030ff9c` / `0x34f3e4` | 扁平 image 里 kernel header 的位置 / packed 文件里 header 之后那个 header 未描述的 rodata 块（0x135c） |
| `0x50314c0c` | 真正的 ARM IRQ-lock helper（`push {r0,r1}; mrs r1,apsr; ...`） |
| `0x50314c16` | Thumb BL 编码目标（helper + 0xA，缺少 veneer） |
| `0x50312186` | 指向 `0x50314c16` 的 Thumb BL |
| `0x50337c00` | kernel 第一个 ARM import stub（`ldr ip,[pc]; ldr pc,[ip]`） |
| `0x503b381c` | 该 stub 的 IAT/edata slot：DLL `0x100039e5` 的 ordinal 34 |
| `0x5039f6e8` | 上述 ordinal 的真实 ARM 函数 prologue |
| `0x5039f700` | export 表里的偏置地址（prologue + 0x18） |
| `0x5038337c` | assisted trace 的停止点：ARM `lr=0`（364 条指令，未修正的旧文档写作 `0x50383364`） |
| `0x5031008e` | packed text 中 entry 的 literal pool 实际位置（应为 `0x50310090`，证明缺 2 字节对齐） |
| `0xdead0000` | boot harness 的 mask-ROM 返回 sentinel（`NK_LR` 默认值） |
| `0x5031308c` | smoke test / 解释器自检执行的真实 ARM helper |

### 引用的 DLL（kernel `TDllRefTable`）

| UID3 | code address | header 文件偏移 | export dir |
|---|---|---|---|
| `0x100065a5` | `0x5037c614` | `0x396188` | `0x5037d098` |
| `0x100039e5` | `0x5037d154` | `0x396cc8` | `0x503b3794` |

### EKA1 头部尺寸（本轮确认）

| 结构 | 大小 | 说明 |
|---|---|---|
| `TRomHeader` | 前 0x80 为 `iJump[124]` + `iVersion`，字段从 `0x7c` 开始解析 | `rom_base` `0x88`、`rom_size` `0x8c`、`root` `0x90`、`kern_data` `0x94`、`kern_limit` `0x98`、`primary` `0x9c`、`secondary` `0xa0`、`checksum` `0xa4` |
| `TRomImageHeader`（EKA1） | **0x64** | `entry` +0x10、`code` +0x14、`data` +0x18、`code_size` +0x1c、`text_size` +0x20、`data_size` +0x24、`bss` +0x28、`dll_ref` +0x38、`export_count` +0x3c、`export_dir` +0x40；没有 EKA2 的安全信息/压缩字段。**kernel 也是 0x64**，`+0x64` 两字属于 text |
| packed record | — | `header`、`.text`、`.rdata`、`.data`、`.edata`、`TDllRefTable`；从下一个 header 反向定位 |
| `TDllRefTable` | — | `{u16 flags; u16 count; u32 entry[count][2]; u32 0xffffffff}`；entry 第一字是被引用 DLL 的 code address |
| `TRomDir` / `TRomEntry` | 4 字节 `iSize`，随后是 `{size, addr, attr, name_len, UTF-16 name}`，4 字节对齐 | `wd2.py list` 的 `+0x162b0`/`+0x16538` 是 **packed 布局**造成的偏移，不是目录格式 |

---

## 4. 当前阻塞（按优先级）

### B1 第 5 轮重写：先修解释器，再谈 veneer
- **Thumb format-2 解码 bug 已修**：`00011` 组（`add/sub rd,rs,#imm3` 与
  `add/sub rd,rs,rn`）的 bit 10 含义是「1=立即数，0=寄存器」，旧实现正好
  相反。所有 Thumb 算术/指针计算都在错误操作数上运行，导致：
  - descriptor 指针变成 `0x800000`；
  - `HLE memcpy` 拿到 8 MB 长度；
  - 旧 2M/20M frontier 及其 callmap/HLE 结论都不可信。
  修正位置：`runtime/src/nokia_interp.c`；回归：`interp_selftest.c`
  「Thumb add/sub immediate and register forms」。
- **调用目标必须在代码范围内**：`nk_code_range_add()` 登记 kernel/DLL 的
  text，`snap_call_entry()` 不再把目标修复到 ROMFS/rodata。范围外的直接
  调用在 `NK_RECOVER=1` 下直接按「返回 0」跳过，并打印
  `skip: call ... is outside every code range`。
- **当前 entry 实测**（`tools/test_boot_recover.sh`）：`0x50310054` 执行
  **197 条指令**后通过 `pop {r4,r7,pc}` 返回 mask-ROM sentinel
  `0xdead0000`；`recoveries=4`（2 次真实回滚 + 2 次范围外跳过），
  `undefined=0`。不再有 2M 循环。
- **新的关键证据：packed text 缺少 4 字节对齐填充。** entry 的代码在
  `0x5031008c` 结束，Thumb literal pool 本应从 `0x50310090` 开始，但 packed
  text 把它放在 `0x5031008e`：
  - `0x5031008e`: `0x00046564`
  - `0x50310092`: `0x00046fca`
  - `0x50310096`: `0x00000c03`
  这三个值加上 RAM base `0x80000000` 后正好是合法的 `0x8004_6564` /
  `0x8004_6fca` / `0x8000_0c03`；而 `0x50310090` 被读成
  `0x6fca0004`。下一个函数从 `0x5031009a`（2 mod 4）开始，最终布局里
  应该在 `0x5031009c`。这与「ROM linker 在 packed text 上重新插入 2 字节
  对齐填充」的模型一致，也解释了 BL target 上那些偶数 bias。
  **下一步不是继续放大 snap，而是建立 function map + relayout：**
  1. 用递归/IDA 枚举每个函数起点；
  2. 按「函数/常量池 4 字节对齐」插入缺失的 2 字节；
  3. 重建 flat image，验证 BL target 是否落回真实函数入口；
  4. 再处理确实无法由对齐解释的 site（如 entry 的 `0x5030fbc6`、
     `0x5030807a`，它们低于 code base，当前被跳过）。
- 旧的「per-call-site bias」观察仍然成立，但需要重新在**修正后的解释器**
  上重做 census；不要沿用第 4 轮的 2M/20M 结论。

#### B1 第 6 轮：literal pool 重排已实现（2026-10-24）

- 新增 `recompiler/relayout.py`：从 packed text 解码函数（Thumb `push {..,lr}`
  与 ARM `stmdb/sub sp/mov ip,sp` 起点），收集函数内所有
  `ldr rd,[pc,#imm]`，从 target 向前找最近的 terminator，跳过 `0x0000`
  filler 后得到 literal pool 起点。把 **pool + 函数起点**按 packed 地址排序，
  逐个检查 `packed + shift` 是否 4 字节对齐；不对齐就在实体前插入 2 字节。
  这是 ROM linker padding pass 的逆操作，packed 字节本身不改。
- **验证 1**：entry 的 pool 在 packed `0x5031008e`，重排后 final
  `0x50310090`，`ldr r0,[pc,#0x1c]` 读到 `0x00046564`（之前读到
  `0x6fca0004`）。
- **验证 2**：`0x50312100` 的 helper pool 在 packed `0x5031213e`，重排后
  `0x50312140`；`ldr` 的目标字也对齐。
- 第一处插入其实在 **entry 的 push（packed `0x50310056`）之前**：push 对齐
  后整个 text 右移 2 字节，entry pool 自然落到 `0x50310090`。后续插入由
  其它 pool/函数起点累积。
- **误报过滤**：raw ldr 扫描会把 `0x50311a20`、`0x50312070` 这类
  **8 字节地址对表**当成很多小 pool；工具用 terminator + 地址对启发式
  过滤，否则 shift 会被抬高。
- 当前 kernel text 插入 **44 处（0x58 字节）**，787 个 pool 全部对齐。
  `tools/test_relayout.sh` 通过。
- **实验镜像**：`relayout.py image` 生成 `out/6600_runtime_relaid.bin`：
  relaid kernel text 仍在 `0x50310000`，内核 `.data` 的 ROM 副本移到
  `0x50400000`（第一个 ROMFS 文件之前的空闲区），并更新 header 的
  `text_size` / `code_size` / `data`。DLL 保持在原地址。boot trace 从 197
  条升到 **289 条**（带 callmap 315），到达 UPP MMIO
  `0x58120a04` / `0x58120110` / `0x58120308` / `0x59e00040`，无 undefined。
- **新发现：pre-MMU physical view**。entry 的 literal pool 里是
  `0x00046564` / `0x00046fca` 这样的**物理数据偏移**，而 kernel 其余部分
  使用 `0x800xxxxx` 虚拟地址。`boot_kernel` 现在额外映射 3 MiB RAM 到
  `0x00000000`（`NK_NO_LOW_RAM=1` 可关闭）；在此之前这些早期写入落到
  MMIO log。
- **仍差 4 字节**：当前 shift 在 packed `0x5031261c` 是 `0x14`，而 entry
  的第一个 BL target `0x50312634` 需要 `0x18`。差的 4 字节最可能是**没有
  `push/stmdb` 的 leaf 函数起点**（还未成为 entity）。另一方面 round 4 已
  证明 encoded target 是 per-call-site stale，callmap/snap 仍然需要。
  下一步：完整 function map（leaf + export 反推）→ DLL 也重排 → 重建 flat
  image。

#### B1 第 4 轮记录（已被第 5 轮修正，保留作历史）
- baseline 原生解释器现在精确停在 `0x50314c16`（12 条 Thumb 指令）：入口
  `0x50310054` → ARM helper `0x5031261c` → Thumb 函数 `0x50312160` →
  `BL 0x50314c16`。真正的 ARM IRQ-lock helper 在 `0x50314c0c`，目标偏 +0xA。
- 这不是 CPU 模型错误：Thumb BL 的编码目标就是 `0x50314c16`，说明镜像缺了
  ROM linker 会插入的 Thumb→ARM veneer。
- export 表也有同样的 bias：DLL `0x100039e5` 的 export slot `0x503b381c` 指向
  `0x5039f700`，真实 prologue 在 `0x5039f6e8`（+0x18）。
- **本轮普查**（`romimage.py calls`，只统计直接 ARM `BL`）：
  - kernel：3854 个调用点，478 个正好落在 prologue，3222 个 biased，154 个
    附近找不到入口；
  - DLL `0x100039e5`：3886 / 705 / 2908 / 273；
  - bias 不是固定值：`0x308×176`、`0x34×117`、`0x28×86`、`0x40×82`、
    `0x10×71`、`0x14×71`、`0x18×70`、`0x24×69`…；
  - 单个例子：Thumb caller `0x5039adb8` 编码目标 `0x5038231e`，最近的
    真入口是 `0x503820b8`（`push {r4-r10,lr}`，前一条是 `bx lr`），bias
    **0x266**。
- **不能简单“往回找最近的 prologue”**：有些目标是合法的共享 basic block，
  例如 `0x503364b0`（由 `0x50312c50` 的 `bl` 调用）以 `mov r0,r7` 开头、
  使用调用者的 `r7`，它前面的字是 `bl` 而不是终止指令。把它 snap 到最近的
  prologue `0x503361d4` 会在 31 条指令内跑飞。
- 运行时已经能做三件事：
  1. `NK_CALL_INFER=1` 在 BL 处按“最近的 prologue + 前驱终止指令”回退并切换
     ARM/Thumb；本轮把“调用点自身所在函数的 prologue”排除在候选之外，
     避免把调用变成自递归；同时先接受真正的 leaf/strong entry；
  2. `NK_E32_SECTIONS=1` 递归装载 kernel 引用的 DLL 和 export dir，使 import
     stub 能解析；
  3. `NK_SNAP_WINDOW`、`NK_CALL_POLICY=0..3` 可复现地比较不同回退策略。
- 该轮的 assisted trace 是 `0x50383364`（364 条指令）后 `lr=0`；窗口
  `0x40/0x100/0x200` 结果相同，`0x400` 因共享 basic block 退化到 31 条。
  **只放大 Thumb caller 的窗口**（`NK_SNAP_WINDOW_THUMB=0x400`，ARM 保持
  `0x40`）能到 380 条，然后在 `0x5039ba4e` 遇到 undefined Thumb 指令：Thumb
  函数 `0x5039ad9e` 在 packed data `0x5039adcc` 之前**没有 `pop`**，尾部本身
  就缺失了。这说明仅靠 call snap 无法修复，必须重建 text/veneer。**本轮已补回
  该尾部并把 frontier 推到 2,000,000 条（见下方 B1 本轮更新）。**
- 下一步：**function/veneer map**——枚举所有 prologue/terminator，把每个
  BL 目标归到"它所在的函数"，用 push/pop 平衡、调用者 `lr` 是否在被保存前
  使用、目标是否在 caller 函数体内等信号区分"biased entry"和"函数内 label"，
  然后才插入 veneer 或修正目标。

#### B1 第 4 轮补充（历史）：bias 是 per-call-site，且会命中合法共享入口
- **同一个 callee 的不同调用点编码不同**：例如打印例程 `0x50313518` 被
  `0x50310060` 以 `+0xa` 调用、被 `0x503103bc` 以 `+0x78` 调用；`0x5039390c`
  调用 `0x5039f980` 时编码成 `0x5039f9f4`（`+0x74`）。所以 bias 不是 callee
  的属性，不能按函数建一张固定偏移表。
- **stale target 可能正好落在一个合法的共享入口上**：`0x50389d14` 是 64 位
  移位 helper 的 `>=32` 入口（前面是 `bx lr`，看起来像 leaf entry），但
  `0x503965fc` 处的真实意图是 32 位除法；只按"target 是否是入口"判断会漏掉。
  这是当前 callmap 存在的原因：让每个无法用局部规则判定的站点显式指定 callee。
- **缺失尾部已确认并补回**：Thumb 函数 `0x5039ad9e` 在 `0x5039adcc` 处没有
  `pop {r4,r7,pc}`（该 2 字节被后面的 packed 表覆盖），补丁后调用能正常返回；
  之前 364 条 frontier 中的 `0x50383364` 只是这个函数跑飞后的次生现象。
- **恢复模式让 boot 真正往前走**：在每个 BL/BLX 保存 caller 状态，callee
  未定义/PC 越界时回滚并当作返回 0。当前结果：
  - baseline：12 条；
  - assisted（`NK_CALL_INFER` + 大窗口）：364 条；
  - recovery + patch + callmap：**2,000,000 条**，2 次跳过，停在
    `0x503820d0`（描述符 copy 循环）；20M 预算时 6 次跳过，停在
    `0x50389330`（被 0 指针污染的字符串比较循环）。
- **仍未解决**：`0x5039adaa` 的 allocator、`0x503938e0`/`0x5039390c` 的
  描述符/日志调用、以及 `0x5039f764` 的 memclr 语义。它们不是"再放大窗口"
  能解决的，需要 function/veneer map 或从 ROM build 的 collapse 规则恢复
  真实目标。

### B1b. import binding 已打通（P0，完成第一层）
- kernel 的 `TDllRefTable` 引用两个 DLL：`0x100065a5`（code `0x5037c614`）和
  `0x100039e5`（code `0x5037d154`）；两者都没有 DLL-to-DLL 引用，
  `romimage.py` 的 BFS 确认 **kernel 只需要这 3 个 image**。
- import stub `0x50337c00` 读取 `.edata` slot `0x503b381c`（0-based slot 34），
  装载该 DLL 的 text + export dir 后解析到 `0x5039f700`；`NK_SNAP_ENTRY`
  把它修正到真实 prologue `0x5039f6e8`。
- 第 5 轮修正 Thumb 后，descriptor copy 已能正常走通；`0x5039adb8` 的
  stale target 用 `NK_HLE_MEMCPY` 固定为 `memcpy(dst, src, len)`，
  `config/callmap-6600.txt` 现在有 5 条 fixup。
- 仍缺：为访问硬件的导入函数提供 HLE/stub；以及 entry 的两个
  低于 code base 的调用目标（见 B1）。

### B2. Mask ROM 初始状态（P0/P1）
- `0x00e0ca39` 在 UPP 内部 boot ROM 中，不在固件镜像里。
- 该路径通常负责 MMU、cache、时钟和向量表的初始设置，然后跳入 kernel。
- 我们需要 runtime 里的 **mask ROM stand-in**：设定初始 CPSR/CP15/栈，映射
  ROM/RAM/high vectors，然后跳到 `0x50310054`。

### B3. WD2 是 **packed** 镜像，但 runtime 布局已恢复（P0/P1，大幅推进）
- 23.3 MB 的 `6600_mcu.bin` 是 **section database**，不是 `rom_base` 起点的
  线性镜像：每个 image 是 `[TRomImageHeader][.text][rodata][.data][.edata]
  [TDllRefTable]`，header 和 code 的 file offset 与 runtime address 无关。
- **已确认的 runtime 布局**（`recompiler/romimage.py`）：
  - `0x50000000..0x50010000`：boot / vectors，文件前 64 KiB，线性；
  - `0x50300000..0x50310000`：ROMFS root list + 所有目录，来自文件
    `0x3162b0..0x3262b0` 的 64 KiB packed 块（root list 的存储值就是
    `0x50300000`；`+0x162b0` 是 **file offset bias**，不是 VA）；
  - `0x50310000`：kernel text；`0x50338ac0` data；`0x50338fc0` export dir；
    `0x50339738` dll-ref；kernel 的 `TRomImageHeader` 在扁平 image 中位于
    `0x5030ff9c`；
  - `0x503397b4..0x5042f170`：kernel 可达的 DLL（实际只有两个）；
  - `0x5043fc90..0x51600000`：171 个 ROMFS 文件，**严格线性**
    （`file = va - 0x50000000`，无重叠，全部在文件内）。
- `rom_size = 0x1600000`（22.0 MB），file size = `0x1634f5c`（22.3 MB）；
  文件末尾 `0x1600000..0x1634f5c` 是 0x34f5c 字节的 trailer。
- **kernel 记录的 section 布局**：
  - header：file `0x3268c0`，`0x64`
  - text：file `0x326924`，`0x28ac0` → `0x50310000`
  - rodata（header 未描述）：file `0x34f3e4`，`0x135c`（中断名 + handler 表）
  - data：file `0x350740`，`0x500` → `0x50338ac0`，同时复制到 RAM `0x80000000`
  - export dir：file `0x350c40`，`0x778`（478 项）→ `0x50338fc0`
  - dll-ref：file `0x3513b8`，`0x18` → `0x50339738`
  - bss：`0x1c58` → RAM `0x80000500`
- 三个可达 image 都无重叠地装入 `out/6600_runtime.bin`；`boot_kernel
  --rom-image` 直接映射并复现同一个 364 条 frontier。
- 仍缺：
  1. header 未描述的 **rodata/debug 块**：kernel `0x135c`，DLL2 `0x19dc`。
     它们没有被任何 text literal 引用，runtime 地址也没有空间；当前假设是
     ROM build 会剥离的 debug/rodata，尚未放入扁平 image。
  2. `0x10000..0x2a0000` 的高熵区还没有归属（可能是 PPM/fonts/预解包数据），
     当前不在扁平 image 中。
  3. ROMFS 目录项的 `iAddress` 字段（0x5030fa78 等）与 pack 偏移不一致，
     所以扁平 image 复制目录块（0xff9c 字节，止于 kernel header）而不是信任
     该字段；文件项本身是准确的。
  4. **packed text 的对齐填充缺失**（第 5 轮新证据）：至少 entry 的 literal
     pool 早了 2 字节。当前 `romimage.py build` 只是把 packed 字节原样复制
     到目标地址，没有重建 ROM linker 的对齐；因此 entry 的后半段 literal /
     部分 BL 目标仍不可用。relayout/function map 是 B3 的新阻塞。

### B4. 设备模型（P2）
- 还没有真正到达 UPP display/timer/keypad 的初始化；当前 MMIO bus 只打印访问。
- 需要先从 kernel 的第一次 MMIO 访问建立设备地址表，再逐个实现。

---

## 5. 接下来的开发路径

### P0 — 让 kernel 真正跑起来

**P0-1 EKA1 loader（基本完成）**
- `TRomImageHeader` 为 0x64 字节，代码紧跟 header。
- `runtime/test/boot_kernel.c --e32 <offset>` 现在按 packed record 反向定位
  并装载 text/data/BSS/export dir/DLL-ref table，递归加载引用的 DLL，并
  通过 export dir 解析 import stub。
- 仍缺：异常描述符、所有 DLL-to-DLL import、以及（最关键的）ROM build 的
  **对齐/veneer 插入**。第 5 轮已经证明 packed text 连 literal pool 的 2 字节
  对齐都可能缺失，必须先把 text 重排回最终布局，再谈调用点语义。
- 验收：kernel + 两个 DLL 的 text/edata 被正确放到 runtime 地址；第一个
  import 能进入被引用 DLL；entry 能完整返回（第 5 轮已达到）。

**P0-2 模式模型（部分完成）**
- 解释器已按 CPSR 的 T 位执行 ARM/Thumb，并用 shadow call stack 在返回时
  恢复调用者模式。
- 仍缺：`nk_register` 记录模式、`nk_call_mode`/`nk_bx` 供 lift 后的 C 使用；
  `lift.py` 的 `mov lr,pc; bx lr` 仍按普通 `return` 处理（本轮已补上
  `mov pc,lr` → `return`，`mov pc,rN` → tail call）。
- 验收：`recursive.py` 同时产出 Thumb/ARM 函数；解释器已能在 veneer 处切换。

**P0-3 解释器 fallback（完成）**
- `runtime/src/nokia_interp.c`：ARMv4T ARM + Thumb，覆盖数据处理、移位、
  load/store、block transfer、乘法、MRS/MSR、BX/BLX、SWI、CP15。
- `nk_call` 可通过 `NK_INTERP_FALLBACK=1` 把未 lift 的 callee 交给解释器。
- 自检：`tools/build_kernel_smoke.sh` 让解释器执行真实 ARM helper
  `func_5031308c`，返回 `r2=0x58000000`。
- 验收（调整后）：解释器能稳定执行数万条指令；遇到未定义指令会精确报告
  地址/mode/字节，而不是静默失败。

**P0-4 Trace / 验收（重新定义）**
- `tools/build_boot_trace.sh` 输出：指令数、ARM/Thumb 计数、MMIO 计数、
  调用修复数、未绑定 import 数、寄存器、最后 16 个 PC、frontier 字节。
- baseline 结果：12 条 Thumb 指令后停在 `0x50314c16`（Thumb→ARM helper 缺
  veneer，与第 4 轮相同）。
- assisted（`NK_E32_SECTIONS=1 NK_CALL_INFER=1`）：364 条指令，停在
  `0x5038337c`，`lr=0`，**undefined=0**。第 4 轮把 364 条 frontier 解释成
  「Thumb 尾部缺失」的次生现象，但其中一部分是 Thumb 解码 bug 造成的；
  现在 364 仍在，原因需要重新审。
- recovery + patch + callmap：**entry 197 条指令正常返回**，4 次跳过，
  无 undefined。旧的 2M（descriptor copy loop）和 20M（null string compare）
  结果由 Thumb bug 制造，已作废。
- 下一步：B1d（function map + 对齐 relayout），而不是继续放大 snap 窗口。

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

- [x] **P0-3** ARMv4T 解释器 fallback（ARM + Thumb，含 SWI/CP15/MMIO）
- [x] **P0-3b** 解释器自检 + 原生 boot trace（`tools/build_boot_trace.sh`）
- [x] **P0-3c** 修复稀疏内存快路径（`nk_r32/nk_w32` 页内偏移 bug）
- [x] **P0-2a** 解释器 T 位 + shadow call stack 模式恢复
- [x] **P0-1a** EKA1 loader：packed record 反向定位 + data/BSS/export/dllref
- [x] **P0-1b** 递归加载 DLL-ref、通过 `.edata` 解析 import stub
- [ ] **P0-1c** 异常描述符 + HLE stub（kernel 的 DLL 依赖只有两个，已全部加载）
- [ ] **P0-2b** `nk_register/nk_call` 记录模式；`lift.py` 识别 `mov lr,pc; bx lr`
- [ ] **B1/P0-4** 解决 veneer bias：function/veneer map（prologue + terminator + push/pop 平衡）
- [x] **B3a** 确认 EKA1 头部尺寸（0x64）/ TRomDir 格式 / packed record 布局
- [x] **B3b** runtime ROM 组装：`romimage.py build` → `out/6600_runtime.bin`，184 个 section 无重叠，`--rom-image` 可启动
- [x] **P0-3d** 修复 Thumb BL 返回地址 + ARM PC-relative load 并加回归测试
- [x] **M13a** 解释器崩溃恢复（caller 快照 + 回滚 + 跳过调用），`NK_RECOVER`
- [x] **M13b** callmap + HLE（div/mod/memzero/alloc），调用点固定
- [x] **M13c** 补回 `0x5039adcc` 缺失的 `pop {r4,r7,pc}`；`romimage.py --patch`
- [x] **M13d** `tools/test_boot_recover.sh`：≥1M 条指令、≤20 次跳过、无 undefined
- [x] **M14a** 修正 Thumb format-2（`add/sub rd,rs,#imm3`）bit10 反了；加回归测试
- [x] **M14b** 解释器代码范围约束：调用修复不进入 ROMFS/rodata；范围外调用跳过
- [x] **M14c** descriptor memcpy HLE（`0x5039adb8`）；callmap 5 条
- [x] **M14d** 新的 entry 验收：197 条指令返回、4 skips、无 undefined
- [x] **B1d** packed-text relayout：`recompiler/relayout.py`，pool + 函数起点 4 字节对齐，entry pool 已验证；787/787 pool 对齐，text +0x58
- [x] **B1d2** 实验镜像 `out/6600_runtime_relaid.bin`：relaid text + 内核 .data 移到 `0x50400000`；boot 289/315 条，到达 UPP MMIO
- [x] **B1d3** pre-MMU low RAM（`0x00000000` 再映射 3 MiB，`NK_NO_LOW_RAM=1` 可关）
- [ ] **B1d4** 完整 function map：leaf 函数 + export 反推，补上 `0x5031261c` 仍差的 4 字节（当前 shift 0x14，target 需 0x18）
- [ ] **B1d5** DLL 也重排并重建 flat image（当前实验镜像只重排 kernel）
- [ ] **B1e** 重新 census / 重新评估 callmap（第 4 轮数据受 Thumb bug 污染；round 6 的 relaid text 需要重新算 callmap 地址）
- [ ] **B1f** entry 的 `0x5030fbc6` / `0x5030807a` 真实 callee（低于 code base；relaid 后是 `0x5030fbc8` / `0x5030807c`）
- [ ] **B1c** 从 callmap 的已验证站点反推 function map，减少 HLE/手工修复
- [ ] **B3c** header 未描述的 rodata/debug 块（kernel 0x135c / DLL2 0x19dc）归属
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

- 2026-10-24（本轮 6）：**literal pool 重排落地**。新增
  `recompiler/relayout.py`：解码 packed 函数、收集 `ldr rd,[pc,#imm]`、
  反查 terminator 后的 literal pool，把 **pool + 函数起点**按 packed 顺序
  做 4 字节对齐（实体前插入 2 字节）。entry pool `0x5031008e -> 0x50310090`
  并读到 `0x00046564`；helper `0x50312100` 的 pool 同样对齐；
  787/787 pool 对齐；kernel text +0x58（44 处）。误报的 8 字节地址对表
  （`0x50311a20`、`0x50312070`）已过滤。新增 `tools/test_relayout.sh`、
  实验镜像 `out/6600_runtime_relaid.bin`（relaid text + .data 移到
  `0x50400000`）；boot 289 条（callmap 315），到达 UPP MMIO
  `0x58120a04`/`0x58120110`/`0x58120308`/`0x59e00040`，无 undefined。
  同时发现 entry 运行在 **pre-MMU physical view**（pool 是 `0x00046564`
  物理偏移），`boot_kernel` 增加 `0x00000000` 的 3 MiB RAM 映射
  （`NK_NO_LOW_RAM=1` 可关）。仍差：`0x5031261c` 当前 shift 0x14、target
  需 0x18（leaf 函数起点未覆盖）；DLL 尚未重排；两个低于 code base 的
  调用点仍待解析。
- 2026-10-24（本轮 5）：**修正 Thumb format-2 解码 bug**——`00011` 组的
  bit 10 是「1=imm3 / 0=寄存器」，旧实现写反，导致所有 Thumb
  `adds rd,rs,#imm` 使用错误操作数。这个 bug 污染了第 4 轮的全部 2M/20M
  trace、descriptor 指针和 HLE 长度；旧结论作废。新增解释器**代码范围**
  约束：调用修复只在已登记 text 内进行，范围外的直接调用在 recovery 下
  跳过而不是执行 ROMFS/rodata。`0x5039adb8` 增加 `NK_HLE_MEMCPY`，descriptor
  copy 正常完成。kernel entry 现在 **197 条指令返回**（4 skips、无
  undefined）。同时发现 packed text 缺少 **2 字节对齐填充**：entry 的
  literal pool 从 `0x5031008e` 开始（应为 `0x50310090`），三个
  `0x0004_6564 / 0x0004_6fca / 0x0000_0c03` 加上 RAM base 后是合法指针；
  这是 B1d（function map + relayout）的直接证据。更新
  `tools/test_boot_recover.sh` 的验收为「entry 返回」，更新
  `interp_selftest`、callmap 和文档。
- 2026-10-24（本轮 4）：解释器加入**崩溃恢复**（每 BL/BLX 保存 caller
  状态，`NK_RECOVER`；callee 故障时回滚为“返回 0”）、**callmap**（按调用点
  固定 callee，含 `div/mod/memzero/bump-alloc` HLE）和更详细的 fixup 日志
  （打印调用点）。确认 bias 是 **per-call-site** 而不是 per-callee，并且 stale
  target 可能落在合法共享入口上；`0x5039adcc` 缺失的 Thumb `pop` 已补回，
  364 条 frontier 是 `0x5039ad9e` 跑飞后的次生现象。新增
  `config/callmap-6600.txt`、`config/patches-6600.txt`、
  `tools/build_bringup_image.sh`、`tools/test_boot_recover.sh`，以及
  `romimage.py build --patch`。当前 recovery boot：**2,000,000 条指令、
  2 次跳过、无 undefined**，停在 `0x503820d0`（描述符 copy 循环）；20M
  预算时到 `0x50389330`。下一步是 function/veneer map 与剩余调用点语义。
- 2026-10-24（本轮 3）：新增 `recompiler/romimage.py`（`scan` / `build` /
  `calls`）：恢复 448 个 `TRomImageHeader` 与 3 个可达 image 的 section，
  确认 ROMFS root list 的 runtime VA 是 `0x50300000`（file `0x3162b0` 只是
  packed 偏移），171 个 ROMFS 文件严格线性；`build` 生成
  `out/6600_runtime.bin`（0x1600000，184 个 section 无重叠）与 layout JSON。
  `boot_kernel` 新增 `--rom-image`，直接映射扁平 image，复现同一 364 条
  frontier。解释器新增 `NK_SNAP_WINDOW` / `NK_CALL_POLICY`，并把“调用点所在
  函数的 prologue”排除在回退候选之外（避免自递归）。新增
  `tools/build_rom_image.sh`、`tools/test_romimage.sh`；`romimage.py calls`
  量化了 kernel 3854 / DLL2 3886 个 ARM BL 的 bias 分布（4..0x308），并记录
  了共享 basic block（`0x503364b0`）这个反例。config 的 ROMFS 字段和
  FIRMWARE-FORMAT/BOOT 同步更新。当前 frontier 不变：`0x50383364`，364 条。
- 2026-10-24（本轮 2）：修正 EKA1 header 尺寸（kernel 也是 **0x64**，不是 0x6c），
  修复两个解释器 bug（Thumb `BL` 返回 `pc+4`、ARM PC-relative load 用 `pc+8`），
  新增对应回归测试；重写 `boot_kernel.c` 的 EKA1 loader，按 packed record 反向
  定位 text/data/edata/dllref，递归加载 kernel 引用的两个 DLL；实现 import
  stub 的 `.edata` 解析、`NK_CALL_INFER` 调用点回退、`NK_IAT_FAKE`/unbound IAT
  报告和 PC 离开镜像检测；smoke helper 地址更新为 `0x5031308c`。baseline
  frontier 变为 `0x50314c16`（12 条指令），assisted trace 到 `0x50383364`
  （364 条指令）后 `lr=0`；下一步是 veneer bias / 真实 ROM linker。
- 2026-10-24（本轮 1）：新增 `runtime/src/nokia_interp.c`（ARMv4T ARM + Thumb
  解释器、shadow call stack、`NK_INFER` 模式推断）、`runtime/test/boot_kernel.c`
  与 `tools/build_boot_trace.sh`；`nk_call` 支持 `NK_INTERP_FALLBACK`；修复
  `nk_r32/nk_w32/nk_r16/nk_w16` 忽略页内偏移的 bug；`lift.py` 支持
  `mov pc,lr` / `mov pc,rN`。确认 EKA1 `TRomImageHeader`=0x64（当时误把 kernel
  记作 0x6c，本轮已修正）、`TRomDir` 格式、WD2 packed 布局，以及 kernel blob
  是 pre-link 镜像（Thumb BL 直接指向 ARM 代码）。当轮 trace 停在 `0x50311c7a`。
- 2026-10-24：确认 103 MB `6600_mcu.bin` 不是 6600 ROM；替换为从
  `NHL105530.C1` 解出的 23.3 MB EKA1 flash 镜像；新增 `wd2.py`、`recursive.py`、
  `trace_boot.py`、稀疏内存 runtime、kernel smoke test；更新 README /
  ARCHITECTURE / FIRMWARE-FORMAT / BOOT / config。
- 下一步：按 B1/B3 解决 pre-link image——优先找 WD2 packed 表中的已链接
  runtime image；否则实现最小 ROM linker（veneer + relocation）。
