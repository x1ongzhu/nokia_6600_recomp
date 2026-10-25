# 开发进度与路线图 — Nokia 6600 (NHL-10)

最后更新：2026-10-25
目标：把 **NHL-10 v5.53.0** 固件静态重编译成可在 macOS / Linux 上原生运行的 6600；
最终里程碑是启动到 Nokia 开机画面 / 待机 UI。

---

## 1. 当前基线

| 项 | 内容 |
|---|---|
| 原始固件 | `fw/NHL105530.C1`（WD2 BT2 / WD2 ALGORITHM 容器，23.3 MB / 0x1635067） |
| 原始 ROM | `6600_mcu.bin`（23,285,596 字节 / 0x1634f5c flash 镜像；header `rom_size` = `0x1600000`） |
| Kernel | 链接地址 `0x50310000`，入口 `0x50310054`（**ARM**，`push {r4,r5,r6,lr}` / `0xe92d4070`）；page-header-free stream 中 header `0x31004c`、text `0x3100b0`、text_size `0x28ac0` |
| CPU | ARM920T / ARMv4T（ARM + Thumb），UPP_WD2 |
| OS | Symbian OS 7.0s / S60 2nd Edition |
| 运行时 | 64 KiB 稀疏页表；ROM `0x50000000`、RAM `0x80000000`（`NK_RAM_EXTRA` 可扩到 6 MiB）、pre-MMU 物理 RAM `0x00000000`、kernel **super page `0x40000000`**（round 23 修正；`NK_SUPERPAGE=1` 写入 `iTotalRamSize`/`iRamBootData` 与 6 MiB bank 表，`TMachineConfig` 在 `+0x800`；旧 `0x7ff00000..0x80000000` 窗口保留为异常栈控制）、high vectors `0xffff0000`、MMIO bus；扁平镜像默认 **725 个 image / 1,847 个 section**（无重叠），`--place-rodata` 为 **726 / 2,335**（含 RTC PDD 的 header-less block）；放入 174 个 ROMFS E32Image + 85 个 AIF/MBM；`NK_KERNEL_VECTORS=1` 把 kernel text 头 0x64 字节装到 0/`0xffff0000`；`NK_LOW_ROM_IMAGE` 可把 linked 64 KiB boot bank 映射到 0；`NK_REGIONS` 可安装 bootregions 表；`NK_IMPORTMAP` 可绑定 export-table hole，并可对已绑定 slot 做 ABI rebind（round 21，`config/imports-b7e-6600.txt`；round 23 全量 map 为 `config/imports-wd2-6600.txt`，11 个 override；round 24 时间/对象/名字簇为 `config/imports-r24-6600.txt`，26 个 override）；`NK_ALLOC_HLE` 的 bump 块带 8 字节头，`NK_REALLOC_PC`（默认 `0x5039c630`）与 `NK_FREE_PC`（默认 `0x5038e3d8`）在 bump 区间内由 harness 服务（round 24）；`NK_B7E` 安装初始 thread→process→CObjectIx 图、watch `[0x800017d4]`，并跟随真实 DProcess 与 `[thread+0x5c]`（round 20/21/23）；`NK_WRITE_WATCH`/`NK_WRITE_WATCH_MAX` 在 store 后记录写入 PC（依赖写 watch 的 hook 可覆盖刚写入的值）；`NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec` 在真实 `RHeap::Alloc` 入口提供 bump heap；`NK_WATCH_MEM=rN:len` 在 watch 命中时 dump guest 内存；`NK_EXT_STUB=1` 给无 export 的嵌套 extension 安装 export 1；`NK_HLE_ZERO2` 清零 64-bit time 输出；`NK_POKE`/`NK_PATCH` 做 bring-up 探测 |
| 启动镜像格式（round 16） | flash 从 `0x20b0` 起是 **`0x20ec` 记录 = `0xec` 字节 page header + `0x2000` 字节 payload**，共 **852** 条；header 前 6 字节 `20 00 00 00 dc 23`，其余 `0xe6` 字节不是 packed 数据。`pagestream.py build` 去掉 header 后得到 `0x1605ed8` 字节 packed stream；kernel header `0x31004c`，text `0x3100b0`。`0x124` 的 `KaeP`/PeaK 容器（record `0x20` @ `0x12e`、image `0x1423dc` @ `0x14e`）已由 `kaep.py unpack` 导出；`install` 在 linked `0x80` 写可执行 handoff，loader 可进入 kernel `0x50310054`；mask ROM 的 record codec 仍未解出（B6a2d2b） |
| 执行引擎 | 静态 lift 的 C + 原生 **ARMv4T 解释器**（`runtime/src/nokia_interp.c`，ARM + Thumb），带崩溃恢复、调用点修复表（callmap）、**代码范围约束**、**死循环看门狗**（`NK_SPIN`）、**调用环 / PC watch**（`NK_WATCH`）、**PC 空间守卫**（`NK_CODE_ONLY`）、**`b .` panic 硬停**（`NK_STOP_SELF_BRANCH`）、**EKA1 executive call gate**（`NK_SWI_DIRECT`，round 18）和少量 HLE 编译器运行时；MMIO bus 带 UPP boot 握手 stub（`0x58150422`/`0x58120a08`） |
| 工具链 | Python 3 + Capstone；clang；IDA Pro 9.1（可选）；Unicorn 仅用于研究 trace |

> 旧的 103 MB `6600_mcu.bin` 没有 WD2 头、EKA1 向量表或 E32Image UID，
> 不是 6600 ROM，已被真正的 23.3 MB EKA1 flash 镜像覆盖。
>
> **第 5 轮修正**：解释器的 Thumb `add/sub rd, rs, #imm3` 解码把
> bit 10（立即数/寄存器选择）用反了，旧的 2M/20M 指令 frontier 因此无效。
>
> **第 16 轮关键修正**：第 7–15 轮把 `0xec` 字节 page header 当成了记录
> 数据（只把前 6 字节叫 tag）。这使得每个 packed record 每 `0x2000` 字节
> 插入 `0xec` 字节，于是：
> - “kernel entry 197 条 / 4 skips”执行的是 page header，不是 kernel；
> - export 命中率 17.2%、drift null、`relayout` 0x58 字节都是 page header
>   artifact；
> - `\System\Programs` 的“9 项 / tail 被覆盖”也是 page header 截断目录。
>
> 去 header 后 kernel 入口是 **ARM**，真实运行 **924,964 条指令**；478 个
> export 有 **469 个（98.1%）** 命中函数起点，页面头去除后 586 项目录是
> `\System\Libs`（round 19 修正；`\System\Programs` 为 55 项）。
> 旧结论保留在本文件作为历史，但不要再作为当前 frontier 使用。详见 §2 M25
> 和 [`BOOT.md`](BOOT.md) 的 Round 16。

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
| M16 | **完整 image map + ROMFS 目录树（第 7 轮）**：修正 2 字节对齐扫描、放置全部 image、定位启动模块表 | `recompiler/romimage.py` 的 header 扫描从 4 字节步进改为 **2 字节**（`TRomImageHeader` 可以位于 2 mod 4，例如 `MmfAudioController.dll` 的 header 在 file `0x7271ca`），并加入 record plausibility 过滤（declared sections 必须落在 next header 之前且 rodata 间隙合理）。结果：**722 个 image**（781 个候选，59 个误报），text 区间两两不重叠，覆盖 `0x5030ff9c..0x515978dc`；`build` 默认放置全部 722 个 image（1,580 个 section，**无重叠**），而不是仅 3 个 reachable。ROMFS 目录树按内容定位：root file `0x32639c`、`\System` `0x325aa4`、`\System\Libs` `0x3162bc`（171 项）、`\System\Programs` `0x318170`（236 项）。`names` 命令输出启动模块表：`ekern.exe`（kernel，uid3 `0x100058e8`）、`ecust.dll`、`ecomm.ldd`、`EStart.exe`、`EFile.exe`、`EFSrv.dll` 等；`\System\Libs` 有 73/171、`\System\Programs` 有 193/236 项映射到 packed image record（第 10 轮修正：Programs 声明 236 但实际只有 9 个有效条目，其余目录尾被下一个 packed record 覆盖）。同时修正：ROMFS **数据文件并不在** `addr - 0x50000000`，旧 build 往 17 MB 扁平镜像里塞的是无关代码；数据文件按 packed FS 顺序存放（0xff 填充），现在默认不再从线性地址复制。验收：`tools/test_romimage.sh` |
| M17 | **第 8 轮：call ring / spin watchdog / PC 空间守卫；重新确认 entry frontier** | 解释器新增 `NK_WATCH`（命中 PC 时打印寄存器 + 最近 64 次 BL/BLX 的调用环）、`NK_SPIN`/`NK_SPIN_MAX`（同一 PC 被访问 N 次即视为死循环，走 recovery 回滚）、`NK_CODE_ONLY`（PC 在 RAM / ROM / low alias / high vectors 之外时视为坏返回）、`NK_ENTRY`（覆盖启动地址）。用它们重新核对：faithful image（无 patch）的 2,000,000 条 trace 是 **0x5039adcc 缺失 `pop` 造成的垃圾路径**；bringup image 仍然 **197 条返回**。kernel entry 的第三个调用（snap 到 `0x50313518`）真实写入 UPP `0x5815053a/0x5815053c/0x5815056a/0x58150200/0x58150508/0x5815004a`，第五个调用访问 `0x58120308`/`0x59e00040`。从 ROM 向量 `0x50000000` 启动可执行 **16,396 条 ARM 指令**、打开 MMU/cache（CP15 c1）、写 `0x580047e0`/`0x580047dc`、安装 high vectors，最后跳到 0 —— 这是异常向量分发代码，不是 reset 路径。修正 `wd2.py`/`romimage.py` 的 UID1 常量：`0x1000007a` 是 EXE（kernel），`0x10000079` 是 DLL（`e32uid.h`）。 |
| M18 | **第 9 轮：export 表作为 layout oracle；packed text 不是 linked text** | 新增 `recompiler/layout.py` 与 `tools/test_layout.sh`。确认 `TRomImageHeader.iExportDir` 就是**按 ordinal 索引的、已 fixed-up 的函数地址数组**（不是名字表；Thumb 函数带 bit 0）；用 5 个 export 的小 DLL `0x101f6e00` 做正对照：5/5 都是 `push {..,lr}` 起点。**关键反证**：kernel 的 478 个 export 全部在 text 内且 4 字节对齐，但只有 82 个（17.2%）落在 stored text 的函数起点上，而随机 4 字节对齐地址的 baseline 就有 13.1%（1.31×）；DLL `0x100039e5` 是 258/1788 = 14.4%，baseline 5.9%（2.44×）。应用当前 relayout（44 pads / 0x58）后 kernel 仍只有 58/478；常数 shift 最好 0xb0 也只有 93/478；线性 drift 也没有改善。packed text 的 1420/1430 个 ARM prologue 都 4 字节对齐、759/787 个 pool 4 字节对齐，所以“只补 2 字节 padding”不可能解释这个差距。结论：**stored text 的 function layout 与 linked layout 不同（不只是对齐）**；`relayout` 只是局部修复（pool/入口验证），不能恢复跨函数调用/export 语义。 |
| M19 | **第 10 轮：pool-aware 起点检测 + Programs 目录截断 + entry literal 方程** | (1) `layout.py` 的起点检测现在会**穿过 literal pool 回溯到 terminator**，从而识别 pool 后的 leaf 函数；kernel export 命中从 82/478（17.2%）升到 **104/478（21.8%）**，但同一检测器的随机 baseline 也升到 **17.2%**（1.27×），结论不变。(2) `romimage.py` 的 `TRomDir` 解析加入条目校验（ASCII 名、地址在 ROM 窗口、size 上限）并显式报告截断：`\System\Programs` 声明 `0x5608` 字节，实际只有 **9 个有效条目 / 0x114 字节**，其余 `0x54f4` 字节被下一个 packed record 覆盖。旧文档中的 236 项（`EStart.exe`、`EFile.exe` 等）是越过目录尾后把代码当条目的**误报**。`\System\Libs`（171 项）、`\System`（23 项）、root（2 项）完整。(3) entry `0x50310054` 的三条 `ldr` 方程证明 packed pool 在 `0x5031008e`，linked pool 在 `0x50310090`；当前 relayout 把 pad 放在 entry push 前（`0x50310056`）后三条 literal 都正确，relaid entry 局部是自洽的。(4) 新增 `romimage.py tree`：64 KiB packed 目录块里其实有**整棵 ROMFS 树**；`\System\Apps` 是唯一“所有条目都是子目录”的 `TRomDir`，按 `<App>.app` 内容匹配可恢复 **63/63 个 app 目录**，包括 `snakeex`（SnakeEx.app 0x7ddc）和 `mixpix`（mixpix.app 0xd718）。`build` 进一步把 **76 个 E32Image 文件**（63 个 `.app` + 13 个 plugin/driver）按 `iCodeAddress-0x64` 映射从 packed file 原样复制到其 runtime 地址，并用 AIF/MBM UID 在 app packed run 内定位 **84 个 AIF/MBM** 伴随文件；`SnakeEx.app` 已在 flat image `0x5147f060` 验证逐字节一致。这为 P3 提供了完整的应用清单、app 二进制和图标/位图；`.r01`/`.wav` 数据仍待 B3g。 |
| M20 | **第 11 轮：padding-only drift 被否定；mask ROM loader 入口定位** | (1) 新增 `layout.py drift`：最强的“packed text + 非递减 2 字节 drift”模型允许 export `V` 匹配任意 `c <= V` 的 stored start，且可跳过 entry。kernel 在 `0x60/0xc0/0x200` 预算下最长单调链为 **149/183/225**，随机地址 null 为 **140.4/168.6/217.2**，比值 **1.06/1.09/1.04**——padding-only 模型与随机无差别。B1g2 的 monotone drift 分支关闭，剩余只能是显式 function-order/relocation 表或符号级置换。(2) `census` 新增 `in-code%`：692 个有 export 的 image 中 **135** 个 entry 全在自身 code 内（kernel/大 DLL）、**155** 个约一半、**36** 个更低、**366** 个为 0；kernel 是真实 export 表 + 错误 layout，不是解析错位。(3) boot harness 支持 `NK_Rn`（n=0..12）；定位 mask-ROM 二级 loader 入口 **`0x500003bc`** → **`0x50001648`**，`KaeP` 描述符在 `0x50000124`（payload `0x130`）。无 call repair 时执行 **211** 条、10 次 stale-call recovery 后返回 sentinel；`NK_CALL_POLICY=3 NK_SNAP_WINDOW=0x400` 时首个 stale call（`0x50001664 -> 0x50002ae4`）snap 到最近 prologue **`0x500029dc`**，运行 **>300,000** 条后进入 base 0、count≈`0x80000000` 的表扫描。snap 只是 bring-up 手段，不能证明 `0x29dc` 就是目标 callee；但扫描本身说明 loader 需要 mask ROM 应安装在地址 0 的 **boot image/super-page 表**，flash 中不存在。下一步是建模该表。(4) 发现 boot bank 的跳转表是 **0-based**（`0x2908` 等），所以 mask-ROM 物理视图是 **boot code at 0**、ROM 字面量 at `0x50000000`、RAM at `0x80000000`；新增 `NK_LOW_ROM=1` 把前 64 KiB 复制到 0、登记为 code、复制 16 个 high vectors，并让解释器只在 opt-in 时允许 low alias。该视图下 loader 无 snap 运行 **299,991** 条，随后在 high-vector 异常路径循环于 `0x1248`；下一 frontier 是异常/super-page state。(5) 新增 `layout.py gaps`：对 629 个带 header-less block 的 image 分类，404 个是字符串/指针表，**15 个是第二段 Thumb/ARM code**（最大 `0x100039e1` 0x1838、`0x100058c1` 0xbce、`0x101f85e3` 0xa32）；kernel（`0x135c`）和 DLL2（`0x19dc`）正确判为 rodata，因此它不解释 kernel export mismatch，但再次证明 packed record 不是简单连续镜像。`tools/test_layout.sh` 已加入 drift 回归（ratio < 1.2）与 gaps 回归，`interp_selftest` 新增 low-alias 回归。 |
| M21 | **第 12 轮：boot bank 是分段链接的；linked view 零恢复启动** | (1) 新增 [`recompiler/bootbank.py`](../recompiler/bootbank.py)：boot bank（flash 前 64 KiB）不是按链接地址存放，而是多个“按不同基址链接的代码段”拼接。`0x3b0` 的 `sub r1, pc, #0x308; add r0, r0, r1` 把 **重定位加数 0xb0** 加到 r0（`physical = linked + 0xb0`）；loader entry `0x3bc` 在 linked view 中是 `0x30c`，其 descriptor 是 `0x130-0xb0 = 0x80`（KaeP payload）。两个独立锚点验证 +0xb0：loader 最后 hand-off 的字面量 `0x1244` 对应 stored `0x12f4` 的真函数入口；第一个 switch table（`0x1238`/table `0x1240`）的 `0x11a8/0x11b0/...` 加 `0xb0` 正好是 `0x1258/0x1260/...` 的 case bodies。(2) `bootbank.py analyze` 扫描 17 个 `ldrls pc,[pc,rN,lsl#2]` 表，用 `table_end - entry` 估计 drift（下界，同段内一致到 `0x20`）：段 A linked `0x0-0x2000` ← stored `0xb0-0x20b0`，bias **0xb0**（7 个表全部精确 0xb0）；段 B linked `0x2000-0x6000` ← stored `0x219c-0x619c`，bias **0x19c**（8 个表 0x18c-0x19c）；段 C stored `0x6374`，bias **0x374**（2 个表，linked base 未定）。两处间隙 `0x20b0-0x219c`（0xec）和 `0x619c-0x6374`（0x1d8）**不是 padding**，里面还有 ARM/Thumb 代码和 literal pool，链接基址不同。(3) `bootbank.py build` 把 A/B 搬到 linked 地址；boot harness 新增 `NK_LOW_ROM_IMAGE` 把该 64 KiB 视图映射到 0，并从 linked `0x30c` 启动。结果：**600,000 条指令、0 恢复、0 undefined**（round 11 为 9 次恢复后循环在 `0x125c`），第一次出现真实 UPP 写 `0x08000008 = 0x37`（linked `0x4298`，由返回 `0xb8000` 的 size probe `0x36a4` 调用），并确认 `0x1244` 线程入口真正执行。(4) 新 frontier：`0x1244` 调用 `0xc58(KaeP payload 0x80, frame 0xfffff400)`；`0xc58` 检查 `[0x80+0x20]=0xe59ff018` 后在 `0xfffff400` 的列表里查 key `[0x80+0xc]=0xdff9ea00`，但该列表为空（`[0xfffff400]=0`），`0x1a1c` 返回 `-1`，调用者未检查而读到 `0x3`/`0x5f`，进入 `0xc7c` 循环。下一步是让 mask ROM/解压步骤安装 loader 需要的 **boot-image/region 列表**。验收：`tools/test_bootbank.sh` |
| M22 | **第 13 轮：ARM 立即数被误判为 LDRH/STRH；boot-region 表建模** | (1) 解释器的 extra load/store 判定 `(op & 0x90)==0x90 && (op & 0x60)!=0` 漏掉了 **bit 25 = 0** 这一条件。`and rd, rn, #0xff`（bit25=1 且 bit7-4=1111）因此被当成 `LDRH/STRH` 执行：`and r0,r0,#0xff` 在 boot bank 的 `0x2b40` 把 `0x504` 变成了 `0xffffd9c0`。修正后 `r0=4`，并新增 `interp_selftest` 回归（数据-processing 立即数 vs 真正的 `ldrh`）。(2) mask ROM 交给二级 loader 的 **boot-region/bank 表** 已建模：`recompiler/bootregions.py` 从 `TRomHeader` 派生 boot / ROM / RAM 三个 bank，entry 为 16 字节 `{base,size,attr,linbase}`，count 在 `+0`、entry 从 `+8` 开始；RAM bank 的 attr 带 `0x4000`，super page 取 `base+size-0x1000`。boot harness 新增 `NK_REGIONS=path[@addr]`。装入表后 linked loader 的 super page 从 `0xfffff000` 变成 **`0x802ff000`**，`0x1244` 线程栈为 `0x802ff3fc`，压缩后的 list 在 `0x802ff400` 有 3 项；仍然 0 recovery / 0 undefined，UPP 写 `0x08000008=0x37` 不变。(3) 新 frontier：线程用 KaeP descriptor 的 `[0x80+0x20]=0xf018e59f` 去查表，该地址不在任何 bank 的 linear 区间内；KaeP 头（`0x50000124`，size `0x20`，value `0x1423dc`）指向高熵区，且 `0x130` 起是重复的 `0xdff9ea00`。因此下一步是**解包/解密 KaeP payload**，而不是继续猜 bank 表。验收：`tools/test_bootregions.sh` |
| M23 | **第 14 轮：KaeP/分页 boot image；boot-region 的类型/标志修正；越过 0xc58 frontier** | (1) 发现 flash `0x20b0..0x6d9134` 不是连续字节流，而是 **852 个 page tag** 的分页区：tag 为 6 字节 `20 00 00 00 dc 23`，首个在 `0x20b0`，步长 **`0x20ec`**，最后在 `0x6d9134`。`KaeP` 头在 `0x124`；`0x128` 的 `20 00 00 00 dc 23` 是 size `0x20` + value 低半字，**不是 tag**（巧合）。kernel text 恰好从 tag `0x326924` 开始（runtime `0x50310000`），entry `+0x54` 是 `nop; push {r4,r7,lr}`；去掉 text 起始 tag 后 entry 在 `+0x4e`，同一指令。新增 [`recompiler/kaep.py`](../recompiler/kaep.py)：`analyze` 测量网格、`despan` 生成实验性去 tag 视图、`synth` 写入 bring-up descriptor/list node、`verify` 固定结构。实验表明单纯 despan **不能**修复 export layout（kernel 从 104/478 降到 67/478），所以 tag 与“function order 不同”是两个独立问题，不能把 despan 当作 B1g2 的答案。(2) 修正 `0x1a1c`/`0x1b34` 的类型/标志模型：`0x1a1c` 第一遍只处理 **type 5..8 且 attr bit `0x04000000`** 的 bank；`0x1b34` 只处理 **type 2**。第 13 轮的 `attr=1` legacy 表对这两个 consumer **完全不可见**，因此 KaeP 的 `0xf018e59f` 必然失败。新增 `bootregions.py --profile linear`：RAM 在前（type 2 + `0x4000` + `0x04000000`，默认 6 MiB）、ROM/boot 为 type 5 + `0x04000000`；boot harness 新增 `NK_RAM_EXTRA`（默认 0）以容纳 6 MiB RAM。用 **原始** linked boot bank + linear 表，loader 不再停在 `0xc58`，600,000 条后停在 `0x2fe4` 的 page-table 填充循环（`r2≈0x65802`、0 recoveries、0 undefined）；这是新 frontier，不是完成启动。(3) `kaep.py synth` 把 descriptor 放到 linked `0x80`、boot-image node 放到 `0xfd00`，可让原始 loader 也越过 `0xc58`，进入 heap/page-table 初始化；它是显式 bring-up stand-in，不是真实 KaeP 解密。验收：`tools/test_kaep.sh`，其余 8 个测试全部通过 |
| M25 | **第 16 轮：分页头去除；packed text 就是 linked text；真实 kernel 入口跑 92 万条** | (1) **关键修正**：flash 的 `0x20ec` 记录不是“6 字节 tag + 0x20e6 数据”，而是 **`0xec` 字节 page header + `0x2000` 字节 payload**。第 7–15 轮把整个 header 留在记录里，等于每 `0x2000` 字节插入 `0xec` 字节，这才是 kernel export 只有 17.2% 命中、`\System\Programs` 只剩 9 项的真正原因。新增 [`recompiler/pagestream.py`](../recompiler/pagestream.py)：`build` 输出去 header 的 packed stream（`0x1605ed8` 字节），`analyze`/`verify` 固定 852 个 header、kernel header `0x31004c`、text `+0x64`（`0x3100b0`）、entry `0x50310054` 为 ARM `push {r4,r5,r6,lr}`（word `0xe92d4070`）、text 首字为 ARM vector table。 (2) **B1g 关闭**：在 stream 上 kernel 478 个 export 有 **469 个（98.1%）** 落在函数起点，DLL `0x100039e5` **1757/1788（98.3%）**，best shift = 0；旧的 82/478、104/478、drift null、`relayout` 0x58 字节都是 page header artifact。`romimage.py`/`layout.py`/`relayout.py` 现在默认读 stream，`layout.py verify` 改为断言 ≥95%。 (3) **ROMFS 截断也关闭**：`\System\Programs` 现在完整解析 **586 项**（旧“9 项 / tail 被覆盖”是 page header 切断目录），`build` 放置 156 个 E32Image 文件和 85 个 AIF/MBM companion；`names` 可看到 `EStart.exe`、`BIGINT.DLL` 等完整启动表。 (4) **真实 kernel 启动**：`romimage.py build` 生成 1,833 section / 725 image 的 flat image；boot harness 修正 flat image entry mode（`entry & 1`，kernel 现在是 ARM），新增 `NK_KERNEL_VECTORS=1` 把 kernel text 头 0x64 字节装到 `0x0`/`0xffff0000`，并把 `0x7ff00000..0x80000000` 映射为 kernel super page。结果 **924,964 条 ARM 指令、0 undefined、0 call fixup、0 recoveries、2 reads / 18 writes**，最后在 `0x5039b2b8` 的 `bx lr` 返回到 0（SVC stack 已下穿 super page 进入 kernel `.data`）；这是新的 stack/exception frontier。 (5) **boot bank stream view**：`bootbank.py --stream` 直接把 stream `[0xb0,0x100b0)` 作为 linked boot bank，15 个 switch table 全部 bias 0；正确的 linked loader 在 **2,111 条** 后停在 `0x624c` 的 board/CPU detection panic（`r5=0x0c0047fd`、`r0=0x10`）。旧的 raw A/B/C 600k 运行使用了 B2 的 page header，作为 legacy control 保留。验收：新增 `tools/test_pagestream.sh`；`test_layout`/`test_romimage`/`test_relayout`/`test_boot_recover`/`test_bootbank` 全部按新事实重写并通过，其余测试也通过 |
| M24 | **第 15 轮：boot bank 段 C 重定位；CPU 表命中；loader 到达 boot-image handoff** | (1) **段 C 被重定位**：`0x3d10` 在 linked `0x74b8` 读 0x13 个 16-bit CPU/board 表项，正确值（含 CPU `0x3b`）在文件 `0x782c`，正好 `linked + 0x374`。第 12 轮只搬 A/B，CPU 查表把 `0x3b` 和指令字节比较后在 `0x3d44` 的 `b .` 挂死。`bootbank.py build` 现在搬 C（`0x6000..0x8000 <- 0x6374..0x8374`），`verify` 固定该表。 (2) **显式 KaeP/boot-image 链**：新增 [`recompiler/bootbringup.py`](../recompiler/bootbringup.py)，在 linked `0x80` 写 descriptor（key、entry、code/data、section size、list head），在 `0xfd00 → 0xfd10` 写 **list head → node → terminator**，node 的 `+0x5c=0`、`+0x60=0x05040000`；此前 synth node 的 `+0x5c` 未清零，`0xc58` 跟着垃圾 next 指针返回 0，导致 section descriptor 为空、`0xfb8` 去解析假 KaeP 数据并映射 2 GiB。 (3) **staging boot-region profile**：`bootregions.py --profile staging` 用 type-2 RAM（`linbase=0xffffffff`，`0x18b0` 的 no-expand 哨兵）、type-5 code bank（`0x5030ff9c+0x29064`，section builder 得到 `0x50310000`）、type-5 data bank（`0x50338ac0+0x3000`）和 boot bank；loader 现在把内核 code 映射到 `0x50310000`、data 映射到 `0x80000000`。 (4) **解释器/MMIO**：`b .` 现在以 `NK_STOP_SELF_BRANCH` 硬停（不再被 recovery 吞掉）；MMIO stub 让 UPP `0x58150422` bit `0x400` 和 `0x58120a08` 非零，从而通过两级握手。 (5) **结果**：`tools/test_bootbringup.sh` 跑到 **36,732 条指令、12 次 MMIO 读、46 次写、1 次 stale-call recovery、0 undefined**，停在 **boot-image handoff `0x80`**（`NK_STOP_PC=0x80`）。`0xfb8` 的 KaeP parser 用一条 `mov pc,lr` 显式跳过；真实解包仍未完成 |

| M26 | **第 17 轮：KaeP/PeaK 容器解包；handoff 可执行并进入 kernel** | (1) **头/记录/镜像边界**：`0x124` 的 magic 是 little-endian `0x5065614B`（Nokia 的 **PeaK** 标记），后接 `u32 record_size=0x20`、`u32 image_size=0x1423dc`。0x20 字节 record 从 file **`0x12e`** 开始（其首个半字与 image-size 的高半字重叠，是打包时的 overlay），image 从 **`0x14e`** 开始，首字是干净的 ARM vector table `e59ff018`；image `+0x38`（file `0x186`）是真实 ARM `e59f11a0`，到 `0x14252a` 结束。 (2) **工具**：`kaep.py unpack` 逐字节导出 `out/6600_kaep_record.bin` 与 `out/6600_kaep_image.bin`（含 SHA-256）；`kaep.py install` 在 linked `0x80` 写入 `ldr pc,[pc,#-4]; .word 0x50310054`，保留 loader 需要的 `+0xc/+0x14/+0x1c/+0x20/...` 字段和 `0xfd00→0xfd10` 的 head→node→terminator 链。 (3) **handoff 可执行**：此前去掉 `NK_STOP_PC` 会在 `0x80` 执行 record 字节（`SWI 0xf9ea00`）；现在进入 **kernel entry `0x50310054`**，1.5M budget 下执行 **1,499,999 条 ARM 指令、0 undefined、1 次 stale-call recovery**，结束于 kernel 代码区 `0x5039...`。`bootbringup.py` 不再 patch `0xfb8` 的 parser。 (4) **剩余**：mask ROM 对 0x20 字节 record 的 codec 仍未解出；`unpack` 保留原始 record，`install` 是显式的 handoff stand-in，不是 record 解密。`0x3ae8 → 0x5bb4` stale call 仍在。验收：`tools/test_kaep.sh`、`tools/test_bootbringup.sh` |
| M27 | **第 18 轮：SWI 不是 no-op —— EKA1 executive call gate 与真实 frontier** | (1) **924k 运行的真正原因**：EUser.dll 的用户侧 kernel API 是一张密集的 `svc #N` stub 表（`0x50392b00..0x50392dc8`）。解释器只打印 SWI 后继续执行，于是从 stub 进入后会**穿过整张表**，落到表后的真实函数 `0x50392dcc`，并进入每轮泄漏 **`0x4b0` 栈**的循环；`0x5039b2b8` 的 `lr=0` 是栈下穿后的症状，不是“kernel stack/super-page frontier”。 (2) **executive 表可读**：kernel SVC handler 在 `0x50314f30`，其 bound literal `[0x50314f7c] = 0x444`，即 **273 项**服务表 `0x50314aec`；269 项是 kernel text 内的代码地址，4 项为零（`0x8a/0x94/0x95/0x96`）。新增 [`executive.py`](../recompiler/executive.py)：`verify` 固定 handler/table/zero slots，`list --used` 统计每个服务的调用点，`stubs` 把所有 image 的 ARM/Thumb SVC stub 映射回服务地址。EUser 的 `0x68 -> 0x5032541c`、`0x4d -> 0x503244e4` 已验证。 (3) **direct call gate**：解释器新增 `NK_SWI_DIRECT=1`，按 EKA1 约定把 `svc #N` 直接派发到 `table[N & 0x1ff]`，并保留 caller 的 LR（stub 是 call gate，不是 SWI 后的继续执行）；这不是完整异常模型，是显式 bring-up 手段。 (4) **新 frontier**：直接派发暴露了两个真实缺口：scheduler/current-thread 全局 `[0x800017d4]` 为 0（直接跑 E32 entry 跳过了 mask ROM/kernel startup 创建初始线程的步骤），以及 IAT slot `0x5037d0e8 = 0xffffffff`（flat image 没有绑定 import）。用 `NK_FAKE_THREAD` 的最小对象 + `NK_SWI_COMPLETE=0x4d` 的“请求立即完成”stand-in 后，kernel 执行 **7,540 条指令、0 undefined**，停在 **unbound IAT slot `0x5037d0e8`**（`sp=0x802fff08`、`cpsr=0x800000d3`）。`NK_IAT_FAKE=1` 的对照跑 8,425 条后因 `r4=0x00730072` 跳到 PC 0，这不是 frontier。这比 924k 早，但第一次走在真实路径上；旧的 924k 只保留为回归基线。 (5) **IAT 检测修正**：import stub 的 slot 值不再只按 `<0x1000` 判定；`0xffffffff` 或任何不在 code range 内的值都按 unbound import 处理，`NK_IAT_FAKE=1` 可显式返回 0。 (6) **第二个解码 bug**：multiply 判定只看 bits 7-4=1001，导致 `sub sp,sp,#0x258` 被执行成 MUL 并清零 SP；现在同时要求 bits 27-22=000000，`interp_selftest` 固定。`NK_BANKED=1` 的 banked/SPSR 模型也已实现（模式栈可由 harness 预置），但 kernel 自己的 mode-stack setup 依赖缺失的 boot state，所以下一缺口仍是 boot descriptor。验收：`tools/test_executive.sh` |
| M28 | **第 19 轮：ROMFS 启动表命名修正；import/IAT 全表；真实 rtc.dll extension 路径** | (1) **`\System\Libs` 不是 Programs**：kernel 下方 586 项目录是 **Libs**，ROM header 的 `iPrimaryFile/iSecondaryFile/iVariantFile/iExtensionFile`（`0x5000009c/0xa0/0xc8/0xcc`）就是指向它的 `TRomEntry`：`ekern.exe`、`EFile.exe`、`ecust.dll`、`rtc.dll`。旧 build 把 171 项 `Plugins` 内容覆盖到 Libs 的 VA `0x50301ec0`，破坏这些 entry，kernel loader 在 `0x5031eae0` 把 UTF-16 文件名当成 `TRomImageHeader`（`[r3+4]`）。现在 packed 目录块按线性 runtime VA 放置并逐目录校验；`\System\Programs` 是真正的 **55** 项 server 列表，`\System\Libs\Plugins` 是 **171** 项。 (2) **import map**：新增 [`imports.py`](../recompiler/imports.py)。EKA1 import stub 是 `ldr ip,[pc]; ldr pc,[ip]`，slot 就是导出 image 的 `.edata` entry；flat image 的合法 export 已经是绑定地址，无需搬运。全镜像 **1,111** 个可解析 stub；kernel **257** 个（236 EUser + 21 ELocl），唯一未绑定的是 **ELocl ord 20**（export table hole `0xffffffff`），由 locale 初始化 `0x50326078` 无条件调用。 (3) **`NK_IMPORTMAP`**：flat loader 扫描 stub，校验 slot→(uid,ordinal,value)，对 hole 应用 `config/imports-6600.txt`；`zero` 生成 high-vector `mov r0,#0; bx lr` code stub 并登记 code range。 (4) **IAT 判定修正**：slot 值 `<0xffff0000` 但属于已登记 code range（如 high-vector stub）现在是合法绑定。 (5) **新 frontier**：修正 ROMFS 后，kernel 走真实 `rtc.dll` extension 路径，**8,512 条指令、0 unbound IAT、0 undefined**，停在 EUser `RHeap::Alloc`（`0x50380270`）：kernel 把 `[0x800017d4]` 写成了 `0x802ffd00`，thread/process/heap 对象不再是 harness 预置值，`[heap+0x18]` 为 0 → `bx ip` 到 0。这是 **B7e 初始 thread/process/heap** 缺口，不再是 import/layout 问题。验收：`tools/test_imports.sh`；全部 13 个测试通过 |

| M29 | **第 20 轮：MUL/MLA 目标寄存器修正；B7e 重新定性为 CObjectIx / 初始 process** | (1) **解释器 MUL/MLA bug**：`nokia_interp.c` 把 `Rd` 取成 bits 15-12，而 ARM 的 `Rd` 是 **bits 19-16**（bits 15-12 只是 MLA 的累加寄存器）。结果每条普通 `mul rd,rm,rs` 都写 **r0**，真正的目标不变；对象访问器（`0x50380270`）里的 `mul r2,r3,r2` 因此清掉 r0（结果指针）。修正为写 `c->r[rn]`，MLA 从 `c->r[rd]` 累加；`interp_selftest` 新增 `mul r2,r0,r1` / `mla` / 链式 `mul` 回归，断言 r0 不再被改写。 (2) **round 19 的 “RHeap::Alloc / null heap” 定性是错的**：`0x50380270` 不是堆分配器，而是**对象数组访问器**（`[this+0x18]` = array、`[this+0x14]` = element size、`[this]` = base）；调用者 `0x50318410` 是 handle→object 路径，读取 `[thread+0x18] -> [process+0x38]`。这与 SDK EUser ordinal 109 的 **`CObjectIx::At`** 一致。真正缺的是**初始 process 及其 object index**，不是 heap。 (3) **`NK_B7E` bring-up**：harness 新增单字写 watch（`nk_dbg_watch_write`，在 `nk_w32` 快路径触发），在 kernel 发布 current-thread 时安装 thread → process → `CObjectIx` → array 图；array 的 element fetch 返回 live current thread，vtable 用 `mov r0,#0; bx lr` 占位；另有一个 guest bump allocator。kernel 先后发布 `0x802ffd00` 和 `0x80001860`，都得到该图。 (4) **结果**：`NK_B7E=1` 运行 **5,575,900 条 ARM 指令、0 undefined、0 call fixups、0 recoveries**，越过 round-19 的 8,512 条 stop；新 frontier 是第二个 thread `0x80001860` 的栈下穿（`sp=0`、`pc=0`）。 (5) **低物理别名修正**：pre-MMU 的 `0x00000000` alias 现在跟随 `NK_RAM_EXTRA` 的大小（原先固定 3 MiB，6 MiB boot profile 会读到 alias 外）。验收：`tools/test_b7e.sh`；`tools/test_imports.sh` 的 import/ROMFS 断言保持通过 |
| M30 | **第 21 轮：EUser import ABI 修正；RTC 驱动 rodata；KERN-NO-SESSION 22** | (1) **四个 kernel EUser import slot 的 ABI 不匹配**：kernel 链接时使用的 EUser `.def` 与本 ROM 的 EUser DLL 顺序不同，导致 panic printer 的 `0x503b391c`（ord 98）拿到 array accessor 而不是 `TDesC16::AtC`；panic init 的 `0x503b4d1c`（ord 1378）拿到 3-arg `TPtr16` ctor 而不是 2-arg；object-container init 的 `0x503b4b9c`（ord 1282）拿到字符串 copy 而不是 `TBuf16(int)`；locale init 的 `0x503b3b70`（ord 247）拿到 descriptor copy 而不是 `TDes16::Copy(buf,len)`。flat loader 现在对**已绑定** slot 也应用 `NK_IMPORTMAP` override，[`config/imports-b7e-6600.txt`](../config/imports-b7e-6600.txt) 显式 rebind 这 4 个 slot；确认用 map 仍是 `config/imports-6600.txt`（1 个 hole）。 (2) **B7E element fetch 修正**：`CObjectIx` 的 array vtable 必须填一个 **`TDesC8` descriptor**（随后调用 `TDesC8::Ptr` `0x5038891c`），不能只写裸指针；handle 路径还要返回带 vtable 的 harness CObject（`B7E_THREAD`），不能返回 live scheduler stack block。 (3) **RTC PDD rodata**：RTC 物理驱动 uid3 `0x100000d8`（header `0x33e340`，code `0x5033e2f4`，rodata `0x279c` @ stream `0x33ee40`）的 vtable/字符串在 `.text` 后的 header-less block。`romimage.py --place-rodata` 把 driver image 的 block 放到 `code+text_size`（仅在不越过下一个 packed header 时），RTC vtable `0x503413e8` 的 `+0x18` 现在是 `0x5033ef98`。默认 build 仍 725 image / 1,847 section；`--place-rodata` 为 726 / 2,335。 (4) **分配器/HAL stand-in**：RTC 构造函数用 `User::AllocZ -> RHeap::Alloc`（真实入口 `0x5038e2ec`）；`NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec` 从 harness bump heap 返回清零块。HAL 全局 `[0x800003ac]` 由 `0x80003c00` 的 vtable 占位，`+0x108` 按 `r1` 返回 0/1。 (5) **新 frontier**：RTC 构造完成，kernel 在加载 **Econs.dll**（uid3 `0x100039e7`，code `0x5079d244`）时要求 file-server session，panic **KERN-NO-SESSION 22** 并在 `0x50312b88` halt。运行 **8,655 条、0 undefined、0 call fixups、0 unbound IAT、0 recoveries**。这是 ROMFS/file-server 任务，不是 import/layout/stack 问题；round 20 的 5,575,900 条实际是 panic printer 在坏 import/descriptor 上循环。新增 `NK_WATCH_MEM=rN:len`。验收：`tools/test_b7e.sh` |
| M31 | **第 22 轮：RTC 扩展是嵌套 E32Image；分配器 ABI、HAL channel 与 27,470 条 boot** | (1) **“RTC rodata block” 是第二个 E32Image**：uid2 `0x100058d8`、text `0x5033ee14..0x50341414`（`0x2600`）、data `0x50341414`、export_count **0**。kernel 的 extension loader 先调用 image entry `0x5033ee14`（driver object 构造），随后通过 `[hdr+0x40]` 调 **export ordinal 1**；export_dir 为 0 时直接跳到 0。`NK_EXT_STUB=1` 在 high vector 安装一个单入口 export stub，并返回 HAL-like object 供 kernel 写入 `[0x800003ac]`。 (2) **RTC 驱动 `new` 的 ABI 不匹配**：`0x5033efa8`/`0x5033eff0` 以 `r0=0x38`/`8` 调用 EUser export index **1504**；该 ROM 的 export table 在该 index 是 **`RTest::operator()`**（引用 `": FAIL : ..."`/`"Checkpoint-fail"`），不是 `operator new`。driver 和 EUser 是用不同 `.def` revision 链接的。RTest 路径调用 `Console::NewL` → `RLibrary::Load("econs")` → `svc 0x76`，在没有 session 时 panic KERN-NO-SESSION。round 21 的 “file-server session” 因此是 ABI mismatch 的**症状**。`config/callmap-rtc-6600.txt` 用 `NK_HLE_ALLOC` 服务这两个 `new`。 (3) **HAL channel 必须是对象**：B7e HAL stub 旧版对 `r1=0` 返回整数 1；RTC driver 把它存到 `[this+8]`，随后 `ldr r3,[r0]; ldr pc,[r3,#0x18]` 解引用，跳到 0。现在返回 `0x80003a40`（vtable `0x80003c00`）。 (4) **系统时间/格式化路径**：`0x5033f040` 调 kernel 的 64-bit time helper，后者经 EUser slot `0x503b4d1c` 格式化；该 slot 在 round 21 被 rebind 成 2-arg `TPtr16` ctor 以修 panic printer，两个调用点需要不同 ABI。`NK_HLE_ZERO2=0xfffffff9` 直接把 64-bit 输出清零。 (5) **结果**：RTC 扩展完整初始化，kernel 进入 extension 之后的 boot init `0x50310fa4`；运行 **27,470 条、0 undefined、0 unbound IAT、0 recoveries**。新 frontier 是 `0x5031f3a8` 检查 kernel `.bss` 的 boot/timer descriptor `[0x80000b5c] == 0xff`（否则 panic PLAT 21）；调用点先构造 `"IrqTimer0"` descriptor（字面量 `0x50337200`），所以这是 kernel 的 timer/DFC 初始化，不是通用 HAL 表。直接跑 E32 entry 跳过了 mask ROM/kernel startup 对该结构的初始化。验收：`tools/test_rtc.sh` |
| M32 | **第 23 轮：PLAT 21 是 TDesC8 ABI；超页模型、RAM 位图、页表与 WD2 CTSI DMA；139,784 条** | (1) **PLAT 21 不是缺失的 boot descriptor**：`0x50311508` 先构造 `0x80000b5c` 的 timer 对象（state `0xff`），随后用 kernel import slot `0x503b4d34` 初始化 **8 字节** `TDesC8` 名字数组（`0x80000b54, b4c, …`）。该 slot 在本 ROM 指向 idx 1384 的 **12 字节**默认构造 `0x5038a234`，其 `str r1,[r0,#8]` 正好把 timer 的 state 清成 0，后续 `"IrqTimer0"` start 于是 panic PLAT 21。把 slot rebind 到 `TDesC8(const char*)` `0x50388984` 后 timer 正常启动。 (2) **第二个 ABI**：timer 名字查表 `0x50310d5c` 调 slot `0x503b3ac4`（idx 204），本 ROM 是 `DObject::Close` `0x5039d870`，把 descriptor 长度 `0x1000000d` 当 handle 并 panic KERN-EXEC。rebind 到 `TDesC8::Compare` 的 EABI 入口 **`0x50388e30`**（不是 body `0x50388e34`；后者会 `bx ip` 到 stale slot 地址）。 (3) **超页在 `0x40000000`，不是 0x7ff00000**：kernel 的 `TheSuperPage` 是 `0x40000000`（`iTotalRamSize` +0x10、`iRamBootData` +0x18），`TMachineConfig` 在 `+0x800`。`NK_SUPERPAGE=1` 映射该 64 KiB 页并写入 6 MiB RAM bank 表（`4 MiB + 2 MiB`，`SRamBank{base,size}`）；RAM allocator 从此能建立页位图。 (4) **CBitMapAllocator ABI**：slot `0x503b433c`（idx 746）是 2 字节数组 allocator `0x50394b60`，不是 `New`；slot `0x503b3980`（idx 123）是 CBufSeg helper `0x50383718`，不是 `Alloc`；slot `0x503b3efc`（idx 474）是引用计数 buffer release `0x503a2980`，不是 `AllocAt(pos,count)`。分别 rebind 到 **`0x50381b28` / `0x50381b84` / `0x50382418`**。 (5) **B7e 跟随真实 DProcess**：kernel 在启动中把 thread→process 换成自己分配的 DProcess，其 `+0x38` 为 0；harness 现在 watch thread 的 process 字段，给真实 DProcess 挂上 `CObjectIx`，并在 current-thread 被瞬时清零时恢复最后一个 live thread；`[thread+0x5c]` 也提供带 vtable 的 thread-local 对象（`+0x24` 返回 1）。 (6) **WD2 CTSI DMA**：`0x5031380c` 的 HAL 调用在 E32-entry boot 中失败并 panic KERN-WD2 24；`config/imports-wd2-6600.txt` 用 `zero` 提供服务成功的 stand-in。 (7) **结果**：**139,784 条 ARM、0 undefined、0 unbound IAT、0 recoveries**，穿过页表与 WD2 CTSI DMA init，最后在 `0x503994e8` 以 **USER-EXEC 3** 停下：当前 thread 没有 trap/exception handler，E32 entry 跳过了 scheduler 的初始 trap state。新 frontier 是 thread 的 exception/trap 状态，不是 import/layout/页表。验收：`tools/test_round23.sh`；旧 `test_b7e/test_rtc/test_imports/test_interp` 保持通过 |
| M33 | **第 24 轮：EUser ABI 全景修复；真实系统时间、对象容器与进程创建；126,238 条** | (1) **时间簇不是浮点问题**：round 23 的 `USER-EXEC 3` 是 `__truncdfsf2` 的 underflow 异常，但调用点 `0x50312720` 实际是 **`TInt64::operator>>(int)`**（隐藏返回指针 r0、this r1、shift r2），kernel 以 generic-7.0 ordinal 1612 导入，ROM EUser 的同一 slot 却是 `__truncdfsf2`。把整簇 rebind 到 ROM 中真正的实现后，`P::InitSystemTime` 首次走通：`0x503b50c0→0x50389fc8`（TInt64>>）、`0x503b4980→0x5038cae8`（TTrap::Trap）、`0x503b4d1c→0x50389a40`（TInt64(int)）、`0x503b4ffc→0x50389f0c`（TInt64*）、`0x503b4ec4→0x503a4f84`（TTime+=us）、`0x503b46bc→0x503a4380`（TTime::SecondsFrom）、`0x503b426c→0x503a4344`（MicroSecondsFrom）、`0x503b4e50→0x50389ae8`（TInt64/=）、`0x503b4ecc→0x50389a68`（TInt64+=）、`0x503b4e58→0x50389e20`（TInt64<<=）。这十个 rebind 全部由**调用点语义**确定，不是按偏移猜的。 (2) **对象容器创建**：`0x5031e594`（`K::Init1` 路径）调用 `0x50336b10`/`0x50336b1c` 各 16 次；两者是 EUser 的 `CObjectConIx::NewL` 和 `CObjectConIx::CreateL`。kernel 的 slot `0x503b42e8`/`0x503b3be8` 分别指向 `0x50396408`/`0x5039dd90`（错误 ABI）；rebind 到 ROM 的 `0x50385858`/`0x5038598c` 后，16 个容器全部创建成功。`0x503b3be8` 的原值不是早先记录的 `0x5039dc70`（那是 idx 276），而是 idx 277 的 `0x5039dd90`。 (3) **进程名解析**：`0x5032b6a4`（初始进程创建）用 `TDesC16::Locate('\\')`、`TDesC16::Locate('.')`、`TDesC16::Mid` 切片进程名；slot `0x503b41c0` 的原值是 SVC stub `0x503987c8`，slot `0x503b4278` 的原值是时间格式化器 `0x503a443c`。rebind 到 `0x503884ac`（TDesC16::Locate）和 `0x50388654`（TDesC16::Mid）。`0x503b3850`（TDesC8::Alloc）的原值是 `TDes8::Format` `0x503945e4`，运行到 `0x5031e680` 时把空 descriptor 当格式串，panic USER 23；rebind 到 `0x50396354`。 (4) **HLE 堆支持 ReAlloc/Free**：bump allocator 现在给每个块加 8 字节头（payload size + `HLEH`），`RHeap1::ReAlloc1`（`0x5039c630`）和 `RHeap::Free`（`0x5038e3d8`）在旧指针属于 bump 区间时由 harness 处理；否则落回真实实现。此前 `0x5039c630` 把 bump 指针当真实块头，算出 `0xfffffffc` 并进入 8.4M MMIO 的 memmove 循环。 (5) **结果与新 frontier**：**126,238 条 ARM、0 undefined、0 unbound IAT、0 recoveries、33 call fixups**，穿过真实系统时间、16 个对象容器、初始进程名解析，在初始进程创建中的 `CleanupStack::PushL` 停下。下一项是 **thread 的 trap frame / cleanup stack 初始状态**（USER-CBase 69），不是 import/layout/堆问题。验收：`tools/test_round24.sh`；`test_round23` 与旧 `test_b7e/test_rtc/test_imports/test_interp` 保持通过 |

### 可复现命令

```sh
.venv/bin/python recompiler/wd2.py extract fw/NHL105530.C1 6600_mcu.bin
.venv/bin/python recompiler/wd2.py info 6600_mcu.bin
.venv/bin/python recompiler/wd2.py kernel 6600_mcu.bin fw/6600_kernel.bin
.venv/bin/python recompiler/wd2.py list 6600_mcu.bin

# round 16: remove the 0xec page headers; the packed text is the linked text
.venv/bin/python recompiler/pagestream.py analyze 6600_mcu.bin
.venv/bin/python recompiler/pagestream.py verify 6600_mcu.bin
.venv/bin/python recompiler/pagestream.py build 6600_mcu.bin out/6600_pagestream.bin
.venv/bin/python recompiler/layout.py verify 6600_mcu.bin
.venv/bin/python recompiler/bootbank.py verify 6600_mcu.bin --stream
tools/test_pagestream.sh

# real kernel entry (ARM) with the kernel vector table installed
tools/build_rom_image.sh
NK_KERNEL_VECTORS=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=1000000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin

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

# round 9: export-table / layout audit (packed vs linked)
.venv/bin/python recompiler/layout.py census 6600_mcu.bin --json out/layout_census.json
.venv/bin/python recompiler/layout.py pools 6600_mcu.bin
.venv/bin/python recompiler/layout.py verify 6600_mcu.bin
tools/test_layout.sh

# round 12: boot-bank fragment drift + linked low-ROM view
.venv/bin/python recompiler/bootbank.py analyze 6600_mcu.bin
.venv/bin/python recompiler/bootbank.py build 6600_mcu.bin out/6600_bootbank_linked.bin
.venv/bin/python recompiler/bootbank.py verify 6600_mcu.bin
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
    NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
    NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_bootbank.sh

# round 13: ARM immediate decode regression + mask-ROM bank table
tools/test_interp.sh
.venv/bin/python recompiler/bootregions.py build 6600_mcu.bin out/6600_bootregions.bin
.venv/bin/python recompiler/bootregions.py explain out/6600_bootregions.bin
.venv/bin/python recompiler/bootregions.py verify 6600_mcu.bin
NK_LOW_ROM=1 NK_LOW_ROM_IMAGE=out/6600_bootbank_linked.bin \
    NK_REGIONS=out/6600_bootregions.bin@0x80000000 \
    NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
    NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=600000 \
    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_bootregions.sh

# round 15: relocate fragment C, map kernel sections, reach the boot-image handoff
.venv/bin/python recompiler/bootbank.py build 6600_mcu.bin \
    out/6600_bootbank_linked.bin
.venv/bin/python recompiler/bootregions.py build 6600_mcu.bin \
    out/6600_bootregions_staging.bin --profile staging
.venv/bin/python recompiler/bootbringup.py build 6600_mcu.bin \
    out/6600_bootbank_bringup.bin \
    --regions out/6600_bootregions_staging.bin
NK_RAM_EXTRA=0x300000 NK_LOW_ROM=1 \
    NK_LOW_ROM_IMAGE=out/6600_bootbank_bringup.bin \
    NK_REGIONS=out/6600_bootregions_staging.bin@0x80000000 \
    NK_ENTRY=0x30c NK_R11=0x80000000 NK_R10=0x80000000 \
    NK_RECOVER=1 NK_CODE_ONLY=1 NK_BUDGET=1500000 NK_STOP_PC=0x80 \
    ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_bootbringup.sh

# round 18: EKA1 executive (SWI) call gate
.venv/bin/python recompiler/executive.py verify 6600_mcu.bin
.venv/bin/python recompiler/executive.py list 6600_mcu.bin --used
.venv/bin/python recompiler/executive.py stubs 6600_mcu.bin --image 0x100039e5
NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 NK_FAKE_THREAD=1 NK_SWI_COMPLETE=0x4d \
  NK_IAT_FAKE=1 NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=20000 NK_MMIO_N=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_executive.sh

# round 20: ARM MUL/MLA destination fix + initial thread/process/object index
clang -std=c11 -O2 -Wall -Wextra -Iruntime/include \
  runtime/test/interp_selftest.c runtime/src/nokia_rt.c \
  runtime/src/nokia_interp.c -o out/interp_selftest && ./out/interp_selftest
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=6000000 NK_B7E=1 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin

# round 21: ABI rebinds + RTC PDD rodata + allocator/HAL stand-ins
#   8,655 instructions, 0 undefined/fixups/unbound/recoveries,
#   halt in the panic printer at 0x50312b88 with KERN-NO-SESSION 22
.venv/bin/python recompiler/romimage.py build 6600_mcu.bin \
  out/6600_runtime.bin --place-rodata
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=0 NK_BUDGET=8000000 NK_B7E=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_b7e.sh

# round 22: RTC extension nested image, allocator ABI, HAL channel, 27,470 insns
#   The RTC driver's operator new (EUser export index 1504) is RTest::operator()
#   in this ROM; the callmap serves the two allocations.  The nested extension
#   image has no export table, so NK_EXT_STUB installs export 1.  The run then
#   reaches the post-extension boot descriptor at 0x80000b5c (panic PLAT 21).
NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-b7e-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=8000000 \
  NK_MMIO_N=0 NK_SWI_LOG=0 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x5031f3c0 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_rtc.sh

# round 23: super page at 0x40000000, RAM bank list, CBitMapAllocator ABI,
# page tables, WD2 CTSI DMA; 139,784 insns, USER-EXEC 3 trap frontier
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-wd2-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x503994e8 NK_WATCH_HITS=1 NK_WATCH_LOG=0 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_round23.sh

# round 24: EUser ABI repair (time/object/name cluster), real RHeap realloc,
# 126,238 insns, initial-process cleanup-stack frontier (USER-CBase 69)
NK_SUPERPAGE=1 NK_RAM_EXTRA=0x300000 NK_KERNEL_VECTORS=1 NK_SWI_DIRECT=1 \
  NK_SWI_COMPLETE=0x4d NK_IMPORTMAP=config/imports-r24-6600.txt \
  NK_RECOVER=0 NK_CALL_INFER=1 NK_BUDGET=3000000 NK_B7E=1 NK_EXT_STUB=1 \
  NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec NK_ALLOC_LOG=64 \
  NK_ALLOC_BASE=0x80600000 NK_ALLOC_END=0x80a00000 \
  NK_HLE_HEAP=0x80700000 NK_CALLMAP=config/callmap-rtc-6600.txt \
  NK_WATCH=0x50312b34 NK_WATCH_HITS=1 NK_WATCH_LOG=12 \
  ./out/boot_kernel 6600_mcu.bin fw/6600_kernel.bin \
    --rom-image out/6600_runtime.bin
tools/test_round24.sh
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
| `0x00e0ca39` | 旧文档标为 UPP mask ROM 入口；round 19 证明它是 `TRomHeader.iTime` 的高半字（`0x80` 起的 64-bit 时间戳），真正的 mask-ROM 入口不在 flash dump 中 |
| `0x3268c0` | kernel `TRomImageHeader` 的 packed 文件偏移 |
| `0x5030ff9c` | kernel header 在扁平 runtime image 中的地址（`code - 0x64`） |
| `0x31004c` | kernel header 在 **page-header-free packed stream** 中的偏移 |
| `0x3100b0` | kernel text 在 stream 中的偏移（header + 0x64） |
| `0x326924` | raw flash 里的 page header（不是 kernel text 起点；旧版本误当成 text） |
| `0x50310000` | kernel 代码链接地址 |
| `0x50310054` | kernel 入口（**ARM**；`push {r4,r5,r6,lr}` / `0xe92d4070`） |
| `0x00000080` | boot bank 的 KaeP descriptor / 真实 mask ROM 解压后的 **boot-image handoff** 目标；第 15 轮 synthetic loader 停在这里 |
| `0x00003d44` | 段 C 未重定位时的 CPU 查表 `b .` panic（第 15 轮已越过） |
| `0x000074b8` | 段 C 的 16-bit CPU/board 表 linked 地址（CPU `0x3b` 在 `+0x20`） |
| `0x0000782c` | 同一张表的 packed file 偏移（= linked `0x74b8` + `0x374`） |
| `0x00000fb8` | KaeP compressed-image parser；第 15 轮 stand-in 用 `mov pc,lr` 跳过 |
| `0x5030ff9c` / `0x34f3e4` | 扁平 image 里 kernel header 的位置 / packed 文件里 header 之后那个 header 未描述的 rodata 块（0x135c） |
| `0x30fb28` | packed **root directory**（2 项：`\System`、`\Nokia`），运行时 VA `0x5030fa78`（round 19 修正 stream 偏移） |
| `0x30f230` | packed **`\System` directory**（23 项），运行时 VA `0x5030f180` |
| `0x301f70` | packed **`\System\Libs` directory**（**586** 项），运行时 VA `0x50301ec0`。这是 ROM 的 **boot image table**：ROM header 的 `iPrimaryFile`/`iSecondaryFile`/`iVariantFile`/`iExtensionFile` 指向其中的 `ekern.exe`/`EFile.exe`/`ecust.dll`/`rtc.dll` entry（round 19） |
| `0x307a14` | packed **`\System\Programs` directory**（**55** 项：BTTestServer、PhoneServer、SharedDataServer 等），运行时 VA `0x50307964`（round 19） |
| `0x3000bc` | packed **`\System\Libs\Plugins` directory**（**171** 项：AcmClassController.dll 等），运行时 VA `0x5030000c`（round 19；旧文档误标为 Libs） |
| `0x5000009c` / `0xa0` / `0xc8` / `0xcc` | `TRomHeader` 的 primary/secondary/variant/extension **TRomEntry 指针**，分别指向 Libs 中的 `ekern.exe` / `EFile.exe` / `ecust.dll` / `rtc.dll` |
| `0x5030ff9c` | `ekern.exe` / kernel `TRomImageHeader` 的运行时地址（code `0x50310000`，size `0x2974c`） |
| `0x50339750` | `ecust.dll` 的 header（code `0x503397b4`）——kernel 的 dllref 表只引用 `0x5037c614` / `0x5037d154` 两个 DLL |
| `0x5031eae0` | kernel 的 E32 boot-file loader：读 `[0x500000cc]`（extension TRomEntry），`r4=[entry+4]`，用 `[r4+0x10]` 作为 entry；round 19 修正 ROMFS 后第一次走到真实 `rtc.dll` 路径 |
| `0x50326078` | kernel locale 初始化；调用 ELocl 的 20 个 export 并写入 `0x80000410..0x8000044c`；最后一个就是 ord 20 hole |
| `0x5037d0e8` | ELocl.dll 的 export table 第 20 项：`0xffffffff`。kernel 的唯一未绑定 import slot（stub `0x50336fe4`） |
| `0x50380270` | EUser **`CObjectIx::At`**（import slot `0x503b3948` 即 EUser ord 109）：`[this+0x18]` array、`[this+0x14]` element size、`[this]` base。round 19 误标为 `RHeap::Alloc`；round 20 定性为 handle→object 访问器 |
| `0x800017d4` | kernel current-thread 全局；kernel 启动后把它写成 `0x802ffd00`（round 19 观测），`NK_B7E` 的写 watch 会在这里重装 process/object index；round 20 又观测到第二个 thread `0x80001860` |
| `0x80001860` | round 20 中 kernel 创建的第二个 thread 对象；`NK_B7E` 下它的栈从对象地址开始，最终 `sp=0`、`pc=0`（新的 B7e2 frontier） |
| `0x50318410` | handle→object 路径：`[0x800017d4] -> [thread+0x18] -> [process+0x38]`，再调用 `0x50380270`（`CObjectIx::At`） |
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
| `0x20b0` / `0x20ec` | 第一个 page header / 记录步长（`0xec` header + `0x2000` payload） |
| `0x1605ed8` | 去除 page header 后的 packed stream 长度 |
| `0x5039b2b8` | 第 16 轮 924k 运行的停止点；第 18 轮证明是 SWI stub 表 fall-through 循环的栈下穿症状 |
| `0x50314f30` | kernel SVC (SWI) vector handler；bound literal `0x50314f7c = 0x444` |
| `0x50314aec` | EKA1 executive 服务表：**273** 项；270 个 kernel text 地址 + 4 个零槽（`0x8a/0x94/0x95/0x96`） |
| `0x50392b78` | EUser `svc #0x800068` stub → service `0x5032541c` |
| `0x50392b08` | EUser `svc #0x4d` stub → service `0x503244e4`（`TRequestStatus` wait/poll） |
| `0x800017d4` | kernel scheduler/current-thread 全局指针；直接跑 E32 entry 时为 0 |
| `0x5037d0e8` | 第一个未绑定 IAT slot：`0xffffffff`（flat image 未做 import binding） |
| `0x50392dcc` | SWI 表之后的真实函数；旧 no-op SWI 路径从表尾落入这里并泄漏 `0x4b0` 栈/轮 |
| `0x5031eb9c` | 第 18 轮 `NK_IAT_FAKE=1` 对照运行的停止返回点；随后 `pc=0`、`cpsr=0x600000db`、`sp=0x802ffc7c`（unbound IAT 返回 0 后对象损坏） |
| `0x0000624c` | page-header-free boot bank 的 board/CPU detection panic（`b .`） |

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

#### B8 第 20 轮：ROMFS/import 已修；frontier 是初始 process/object index

第 18 轮的 import 缺口已经关闭：

1. **flat-image import binding（完成）**：`imports.py` 证明 kernel 的 257 个
   stub（236 EUser + 21 ELocl）中只有 **ELocl ord 20** 是 export-table hole
   (`0xffffffff`)；flat image 的其它 slot 已经是导出 image 的 `.edata` 地址，
   无需搬运。`NK_IMPORTMAP=config/imports-6600.txt` 在 flat loader 里把该
   slot 绑定到 high-vector 的 `mov r0,#0; bx lr` stub。7,540 条的 IAT 停止点
   因此消失（0 unbound IAT）。
2. **ROMFS 启动表（完成）**：旧 build 把 `Plugins`（171 项）覆盖到
   `\System\Libs` 的 VA，破坏了 ROM header 的 iPrimaryFile/iSecondaryFile/
   iVariantFile/iExtensionFile 所指的 `ekern.exe`/`EFile.exe`/`ecust.dll`/
   `rtc.dll` entry。修正后 packed 目录块按 runtime VA 线性放置，kernel 的
   boot loader（`0x5031eae0`）真正加载/运行 `rtc.dll` extension。
3. **新 frontier：初始 process / object index（B7e，round 20 已纠正定性）**：
   kernel 把 `[0x800017d4]` 从 harness 预置值改写成 `0x802ffd00`。round 19
   把 `0x50380270` 当成 `RHeap::Alloc`，但它是**对象数组访问器**：
   `[this+0x18]` 是 array、`[this+0x14]` 是 element size、`[this]` 是 base；
   调用者 `0x50318410` 是 handle→object 路径，读取
   `[thread+0x18] -> [process+0x38]`。这与 SDK EUser ordinal 109 的
   **`CObjectIx::At`** 一致。所以缺口是初始 process 及其 object index，
   不是 heap。
   - **MUL/MLA 修正（round 20）**：解释器原来把 `Rd` 取成 bits 15-12，
     普通 `mul` 因此写 r0；`0x5038029c` 的 `mul r2,r3,r2` 会破坏
     `RHeap::Alloc` 的结果指针。现在写 bits 19-16，MLA 从 bits 15-12
     累加，`interp_selftest` 有回归。
   - **`NK_B7E`**：安装 thread → process → `CObjectIx` → array 图，并在
     kernel 写 `[0x800017d4]` 时重装。round 20 记录 **5,575,900 条指令、
     0 undefined、0 call fixups、0 recoveries**；**round 21 重新定性**：这
     5.575M 条是 panic printer 在四个 ABI 错误的 EUser import 和一个裸指针
     object-index element 上循环，不是第二个 thread 的真实栈下穿。修正后
     同一路径在 **8,655 条** 就以 KERN-NO-SESSION 22 停下，见 B9。
   - 该图是显式 bring-up stand-in；下一步是从 boot descriptor 恢复真实
     `SProcess`/`SThread` 的字段（尤其是第二个 thread 的 stack/object 字段）。

验收：`tools/test_imports.sh`、`tools/test_executive.sh`、`tools/test_b7e.sh`。

#### B9 第 21 轮：EUser import ABI / RTC rodata / file-server session frontier

1. **四个 kernel EUser import slot 的 ABI 不匹配（已用显式 rebind 隔离）**：
   kernel 和 ROM 里的 EUser DLL 来自不同的 `.def` revision。`0x503b391c`
   （ord 98）应为 `TDesC16::AtC` 却指向 array accessor；`0x503b4d1c`
   （ord 1378）应为 2-arg `TPtr16` ctor 却指向 3-arg；`0x503b4b9c`
   （ord 1282）应为 `TBuf16(int)` 却指向字符串 copy；`0x503b3b70`
   （ord 247）应为 `TDes16::Copy(buf,len)` 却指向 descriptor copy。flat
   loader 现在对已绑定 slot 也应用 override；`config/imports-b7e-6600.txt`
   把这四个 slot 固定到实际调用点需要的实现。确认-only 的
   `config/imports-6600.txt` 保持 1 个 ELocl hole。
2. **B7E element fetch 必须是 descriptor**：`0x503802b0` 随后调用
   `TDesC8::Ptr`（`0x5038891c`），所以 array vtable 要在 `r0` 处写
   `{0x10000004, object_ptr}`，而不是只写裸指针；handle 路径还要返回带
   vtable 的 harness CObject（`B7E_THREAD`），不能返回 live scheduler block。
3. **RTC PDD 的 header-less block**：RTC 物理驱动 uid3 `0x100000d8`
   （header `0x33e340`，code `0x5033e2f4`，text `0xa9c`）在 `.text` 后有
   `0x279c` 字节 rodata（stream `0x33ee40`），其中 `0x503413e8` 是 vtable；
   `+0x18` = `0x5033ef98`。`romimage.py --place-rodata` 把 driver image
   的 block 放到 `code+text_size`（只在不超过下一个 packed header 时），
   默认 build 仍 725 image / 1,847 section，`--place-rodata` 为
   **726 / 2,335**。这是 B3c 的第一个**真正需要运行时放置**的 gap；RTC
   驱动因此不再读零 vtable。
4. **分配器 / HAL stand-in**：RTC 构造调用 `User::AllocZ -> RHeap::Alloc`
   （真实入口 `0x5038e2ec`）；`NK_ALLOC_HLE=1 NK_ALLOC_PC=0x5038e2ec`
   从 harness bump heap 返回清零块。HAL 全局 `[0x800003ac]` 用
   `0x80003c00` 的 vtable 占位，`+0x108` 按 `r1` 返回 0/1（r1=1 时 0 表示
   success；r1=0 时非 0 是 channel handle）。
5. **新 frontier：KERN-NO-SESSION 22（Econs.dll）**：RTC 驱动构造完成后，
   kernel 在加载 **Econs.dll**（uid3 `0x100039e7`，code `0x5079d244`）时
   要求 file-server session；session 不存在，panic **KERN-NO-SESSION 22**
   并在 `0x50312b88` halt。运行 **8,655 条、0 undefined、0 call fixups、
   0 unbound IAT、0 recoveries**。这是 ROMFS/file-server 任务，不是
   import/layout/stack 问题。下一步：建模 ROMFS/E32 文件服务（或显式 HLE
   返回已放置的 ROM image），再继续驱动/进程启动。
   诊断线索：panic 前最后的关键 SVC 是 `SWI 0x52`（`0x50392b1c` →
   service `0x503245bc`，参数 `r0=0x64 r1=0x14/0x64 r2=0x503b2f24`），
   随后 `SWI 0x72`（trap push）和 `SWI 0x76`（`Kernel::Panic` 22）。
   service `0x503245bc` 取一个全局 session/server 对象并调用
   `0x50336abc`；该对象为空就是 KERN-NO-SESSION 的直接来源。
6. **banked registers / SPSR / 异常模型（仍待）**：`svc` 仍是直接调用而非
   进入 `0x50314f30` 的 SVC vector；kernel 的 `msr cpsr_c` 模式切换、
   `mrs spsr`、`movs pc,lr`/`ldm ^` 还没有完整异常语义。`NK_BANKED=1`
   已实现 banked/SPSR 模型和 harness 模式栈；kernel 自己的 mode-stack
   setup 仍依赖缺失的 boot state。
7. **等待/中断完成路径（仍待）**：`NK_SWI_COMPLETE=0x4d` 把
   `TRequestStatus*` 直接写 0；真实路径需要 timer/interrupt/DMA 的完成投递。

验收：`tools/test_b7e.sh`（同时固定 RTC vtable、四个 rebind、8,655 条和
KERN-NO-SESSION 22）。

#### B10 第 22 轮：RTC 扩展是嵌套 E32Image；boot 推进到 27,470 条

第 21 轮把 8,655 条的 KERN-NO-SESSION 定性为 file-server 依赖；第 22 轮
证明它是 **RTC 驱动 allocator import 的 ABI mismatch**，并把 kernel 推进到
extension 之后的 boot init。

1. **“RTC rodata block” 是第二个 E32Image**：RTC 记录里第一个 image
   （uid3 `0x100000d8`，code `0x5033e2f4`）之后，stream `0x33ee60` 是
   **uid2 `0x100058d8`、uid3 0** 的 DLL header：entry/code
   `0x5033ee14`、text `0x2600`、data `0x50341414`、`export_count=0`。
   这段代码不是 rodata，而是真正被执行的 extension driver。kernel 的
   extension loader `0x5031eae0` 先调用 entry `0x5033ee14`（driver object
   构造 + Install），随后在 `0x5031ebbc` 用 `[hdr+0x40]` 调 **export
   ordinal 1**；该 image 没有 export，于是跳到 0。`NK_EXT_STUB=1` 在
   `0xffff0900` 安装单入口表、在 `0xffff0910` 安装
   `ldr r0,[pc,#8]; bx lr; .word 0x80003a40`，并把 header 的
   `export_count/export_dir` 改成 1/`0xffff0900`；kernel 把这个 HAL-like
   object 写入 `[0x800003ac]`。
2. **RTC `new` 的 import 落在 `RTest::operator()`**：
   `0x5033efa8`（`r0=0x38`）和 `0x5033eff0`（`r0=8`）调用 EUser export
   index 1504；该 ROM 的 export 表在该 index 是 `RTest::operator()`（代码
   引用 `": FAIL : %S failed check %d\n"` 和 `"Checkpoint-fail\n"`）。
   RTC 驱动期望 `operator new(size)`，于是把 `0x38` 当作 RTest 对象，
   进入 console 路径，最终 `Console::NewL` → `RLibrary::Load("econs")`
   → `svc 0x76`，在没有 session 时走 panic printer 的 KERN-NO-SESSION。
   这说明 driver 与 EUser 的 `.def` revision 不同；`config/callmap-rtc-6600.txt`
   用 `NK_HLE_ALLOC` 为这两个站点返回 bump-heap 指针。
3. **HAL channel 必须是可解引用的对象**：B7e HAL stub 旧版对 `r1=0`
   返回整数 1。RTC driver 把它存到 `[this+8]`，随后
   `ldr r3,[r0]; ldr pc,[r3,#0x18]`，于是跳到 0。现在返回 guest object
   `0x80003a40`（`[0] = 0x80003c00`，vtable 全是 zero stub）。
4. **系统时间格式化共用 slot 的冲突**：`0x5033f040` 调 kernel 的 64-bit
   time helper，helper 再经 EUser slot `0x503b4d1c` 格式化；该 slot 在
   round 21 被 rebind 成 2-arg `TPtr16` ctor 以修 panic printer。两个调用
   点需要不同 ABI，因此 `NK_HLE_ZERO2`（`0xfffffff9`）直接把 64-bit 输出
   清零，driver 只消费两个 time word。
5. **新 frontier：post-extension boot descriptor**。RTC 扩展完成后，
   kernel 进入 `0x50310fa4`（初始化 `[0x80001774]=0x80000b80`、
   `[0x80001778]=0xba`、清零 0x2e8 字节）并调用 `0x5031f3a8`；后者检查
   kernel `.bss` 的 `[0x80000b5c] == 0xff`，否则 **panic PLAT 21** 并在
   `0x50312b88` halt。调用点先构造 `"IrqTimer0"` descriptor（字面量
   `0x50337200`），所以这是 kernel 的 timer/DFC 初始化。直接跑 E32 entry
   跳过了 mask ROM/kernel startup 对该结构的填充。实验性 `NK_PATCH=0x5031f3b8:0xe3530000`（把 `cmp
   r3,#0xff` 改成 `cmp r3,#0`）可让 boot 再前进 179 条到下一次
   KERN-NO-SESSION，说明该检查是当前直接门槛；但正确做法是恢复
   `0x80000b5c` 的 boot descriptor / HAL entry 表，而不是长期 patch。
6. 运行数据：**27,470 条、0 undefined、0 unbound IAT、0 recoveries**，
   `call fixups=15`（3 个 RTC callmap + 12 个 inferred ARM 修正），
   `mmio 42 reads / 22 writes`。验收：`tools/test_rtc.sh`；旧的
   `tools/test_b7e.sh`（8,655 / KERN-NO-SESSION 22）保持通过，作为
   历史基线。

#### B11 第 23 轮：PLAT 21 是 TDesC8 ABI；超页、RAM 位图、页表与 WD2 CTSI DMA

第 22 轮的结论是“直接 E32 entry 跳过了填充 `0x80000b5c` 的 boot 初始化”。
第 23 轮从 **static constructor 的实际布局**重新检查，发现门槛是另一个
EUser ABI 错误，并把 boot 推进到 **139,784 条**。

1. **12 字节构造函数覆盖 8 字节名字对象**。`0x50311508`（entry 的 static
   ctor 表第二项）先调用 `0x50310dbc(0x80000b5c)` 构造 timer：`0x5031f35c`
   写入 `[obj]=0xff`、`[obj+0x10]=0x50338340`。随后它用 kernel import
   slot `0x503b4d34`（本 ROM export idx 1384）初始化
   `0x80000b54, b4c, b44, …` 的 **8 字节** `TDesC8` 名字（`"FiqTimer0"` 等）。
   该 slot 在本 ROM 指向 **12 字节**默认构造 `0x5038a234`：
   `str r1,[r0]; str r1,[r0,#4]; str r1,[r0,#8]`。对 `r0=0x80000b54`
   的第三次 store 正好写到 `0x80000b5c`，把 timer state 清成 0；
   `0x5031f3a8` 的 `cmp [0x80000b5c],#0xff` 于是 panic PLAT 21。
   rebind 到 `TDesC8(const char*)` **`0x50388984`** 后 timer 正常启动。
   `NK_PATCH=0x5031f3b8:0xe3530000` 的旧实验只是绕过症状。
2. **名字查表用了 `DObject::Close`**。timer start 进入
   `0x5031ba2c -> 0x50311104 -> 0x50310d5c`，后者遍历
   `[0x80000020]` 的名字表并用 slot `0x503b3ac4`（idx 204）比较。
   本 ROM 的 idx 204 是 `DObject::Close` `0x5039d870`，它把栈上 descriptor
   的 length word `0x1000000d` 当 handle 调 `svc 0x6b`，panic KERN-EXEC。
   rebind 到 `TDesC8::Compare` 的 **EABI 入口 `0x50388e30`**。注意
   `0x50388e34` 是 compare body，直接 bind 会保留 stale `ip=slot`，
   `bx ip` 跳回 slot 地址形成循环；`0x50388e30` 先 `ldr ip,=memcompare`。
3. **超页在 `0x40000000`**。kernel 的 `TheSuperPage` 访问器
   （`0x5032211c` 返回 `0x40000800` 的 MachineConfig）和
   `0x5031c0ac` 的 `mov r3,#0x40000000; ldr r6,[r3,#0x18]` 表明：
   super page base `0x40000000`，`iTotalRamSize` 在 `+0x10`，
   `iRamBootData` 在 `+0x18`，`TMachineConfig` 在 `+0x800`。旧 harness
   映射的是 `0x7ff00000..0x80000000`，所以这些读全部落到 MMIO 返回 0，
   RAM allocator 看不到任何 bank。`NK_SUPERPAGE=1` 映射该 64 KiB 页并写入
   6 MiB 的 `SRamBank{base,size}` 表（`0x000000..0x400000` +
   `0x400000..0x600000`，最小 bank 必须是 2 的幂），同时保留
   MachineConfig 区域供 kernel 自己写。日志：
   `super page 0x40000000: total RAM 0x600000, 2 banks ... {0,0x400000} {0x400000,0x200000}`。
4. **CBitMapAllocator 的 ABI 也不同**。RAM allocator 用 bitmap 管理页和
   页表；本 ROM 的三个 kernel import slot 都指向语义不同的 EUser 函数：
   - `0x503b433c`（idx 746）→ `0x50394b60`（2 字节数组 allocator，分配
     `2*n+4` 并只清首字），kernel 期望 `CBitMapAllocator::New`；正确实现
    是 **`0x50381b28`**（`((n+31)>>5)`、`0x14 + 4*sz`、构造
     `iAvail/iSize/iLength/iMap`）。
   - `0x503b3980`（idx 123）→ `0x50383718`（CBufSeg helper），kernel
     期望 `CBitMapAllocator::Alloc()`；正确实现是 **`0x50381b84`**。
   - `0x503b3efc`（idx 474）→ `0x503a2980`（引用计数 buffer release），
     kernel 期望 `CBitMapAllocator::AllocAt(pos,count)`；正确实现是
     **`0x50382418`**。
   对应 panic 依次是 E32USER-CBase 80（AllocFrom offset out of range）和
   CBufSeg 14；修正后页表分配正常推进。
5. **B7e 需要跟随 kernel 自己创建的 DProcess**。kernel 在 boot 中把
   thread→process 从 `B7E_PROCESS` 换成自己分配的真实 DProcess，其
   `+0x38`（CObjectIx）为 0；`0x50318410` 于是在 handle 路径把 0 传给
   `CObjectIx::At`。harness 现在：
   - 在每次 `[0x800017d4]` 发布时也 watch `thread+0x18`（第三个写 watch
     slot），给真实 DProcess 挂 `B7E_OBJIDX`；
   - current-thread 被瞬时清零时恢复最后一个 live thread（直接 E32 entry
     没有 scheduler startup）；
   - 给 `[thread+0x5c]` 提供带 vtable 的 thread-local 对象，`+0x24` 返回 1。
   同时 `nk_w32` 的 debug hook 改为**在 store 之后**调用，hook 才能覆盖
   guest 刚写入的值（`NK_WRITE_WATCH` 的语义也据此更新）。
6. **WD2 CTSI DMA 的 HAL stand-in**。`0x5031380c` 在
   `0x503126d0` 通过 EUser idx 970（`0x503a14ec`）调用 HAL 时间/DMA
   服务；直接 E32 entry 没有 mask-ROM 的 HAL 状态，返回非零后
   `0x50310b30` panic **KERN-WD2 24 "Invalid CTSI DMA"**。
   `config/imports-wd2-6600.txt` 用 `zero` 让该调用返回 0（成功）。
7. **结果与新 frontier**：**139,784 条 ARM、0 undefined、0 unbound IAT、
   0 recoveries、15 call fixups**；穿过 6 MiB RAM bank 表、页位图、页表
   和 WD2 CTSI DMA init，在 `0x503994e8` 以 **USER-EXEC 3** 停下。
   `0x503994b0` 在 `0x50399504` 返回 0 时格式化 `"USER-EXEC"` 并 panic；
   当前 thread 没有 trap/exception handler。直接 E32 entry 跳过了
   scheduler 的初始 trap 状态，因此下一项是 **initial thread 的
   trap/exception state**，不是 import/layout/页表。
   验收：`tools/test_round23.sh`（super page、11 个 override、139,784 条、
   USER-EXEC 3）；旧的 `test_b7e/test_rtc/test_imports/test_interp` 保持通过。

#### B12 第 24 轮：EUser ABI 全景修复；时间/对象容器/进程创建；trap frontier

第 23 轮的 `USER-EXEC 3` 不是初始 trap state，而是 **EUser 导入 ABI
错位**的最后一个症状。kernel 里同一段代码按 generic-7.0 ordinal 导入，
ROM EUser 的 export table 却是另一个 `.def` revision，二者在多个区域
相差 3–4 项。第 24 轮不再逐个 panic 猜测，而是按**调用点语义**把整个
可见簇 rebind 到 ROM 中真正的实现：

1. **系统时间簇**。`0x50312720` 以 `(out, &TTime, 6)` 调 `0x503b50c0`，
   实际语义是 `TInt64::operator>>(int)`（隐藏返回指针 r0、this r1、
   shift r2）；ROM 同一 slot 是 `__truncdfsf2`，于是把指针当 double 低字，
   underflow 后走 `User::RaiseException` 并 panic `USER-EXEC 3`。
   十个 rebind 覆盖 `TInt64` 的 `>>/*/=/+=/<<=`、`TTime::SecondsFrom/
   MicroSecondsFrom/operator+=`、`TTime` 构造和 `TTrap::Trap`。
2. **对象容器**。`0x5031e594` 的 `K::Init1` 路径创建
   `CObjectConIx` 并循环 16 次 `CreateL`；原 slot 指向
   `0x50396408`（allocator wrapper）和 `0x5039dd90`（USER-CBase
   panic helper），rebind 到 `CObjectConIx::NewL` `0x50385858` 与
   `CreateL` `0x5038598c`。
3. **初始进程名**。`0x5032b6a4` 用 `TDesC16::Locate('\\')`、
   `Locate('.')`、`Mid` 解析 `ekern` 路径；原 slot 分别是 SVC stub
   和时间格式化器。`0x503b3850`（`TDesC8::Alloc`）原值是
   `TDes8::Format`，会把空 descriptor 当格式串并 panic USER 23。
4. **HLE 堆**。bump allocator 现在写 8 字节块头；`RHeap1::ReAlloc1`
   和 `RHeap::Free` 对 bump 指针由 harness 处理。此前 ReAlloc 把
   bump 指针当真实块头，读出 `0xfffffffc`，进入 8.4M MMIO 的
   memmove 反向循环。
5. **结果**：**126,238 条 ARM、0 undefined、0 unbound IAT、
   0 recoveries、33 call fixups**。真实系统时间、16 个对象容器、
   初始进程名解析都已执行；停在初始进程创建里的
   `CleanupStack::PushL`，panic **USER-CBase 69**
   （`EClnNoTrapHandlerInstalled`）。直接 E32 entry 没有 scheduler
   安装的 trap frame，因此下一项是 **初始 thread 的 trap frame /
   cleanup stack 状态**，不是 import/layout/堆问题。
   **探索记录**：把 `[thread+0x3c]`/`[thread+0x58]` 直接指向一个
   `mov r0,#0; bx lr` 的假 `TTrapHandler` 可以让 `PushL` 通过，但 boot
   回退到 **12,737 条**并在 RTC 扩展处 panic；trap handler 必须真正保存/
   恢复 leave context（`Trap` vtable +8、leave path +0x10），不能只返回 0。
   因此下一轮应实现最小的 trap frame 保存/恢复，而不是继续用 no-op stub。
   验收：`tools/test_round24.sh`；`test_round23` 与旧
   `test_b7e/test_rtc/test_imports/test_interp` 保持通过。

#### B1 第 16 轮：B1g/B5 关闭 —— 问题是 page header，不是 function order

`recompiler/pagestream.py` 去掉每个 `0x20ec` 记录里的 `0xec` 字节 page
header 后：

- kernel 478 个 export：**469/478 = 98.1%** 落在函数起点；
- DLL `0x100039e5`：**1757/1788 = 98.3%**；DLL `0x100065a5`：20/21；
- best constant shift = **0**（`layout.py census`）；
- 812 个 literal pool 中 787 个本来 4 字节对齐，残余 relayout 只有 26 处 /
  `0x34` 字节，且不应应用（是 detector 噪声）。

因此 B1g2b（符号级置换）、B1g3（重新生成 flat image）、B5 的
“不同 function order”分支都不需要了。`layout.py verify` 现在直接断言
kernel ≥95%。旧的 §B1 文本保留为历史。

**第 18 轮更正**：924,964 条 ARM 指令是 SWI stub 表的 fall-through 循环，
不是 boot。真正的 call-gate 路径在 `NK_SWI_DIRECT=1` 下执行 7,540 条后停在
unbound IAT slot `0x5037d0e8`（`sp=0x802fff08`、`cpsr=0x800000d3`），
见 §B7。旧的 stack/super-page 描述保留为历史，不再作为当前 frontier。

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
- UPP 内部 boot ROM 不在固件镜像里。旧文档的 `0x00e0ca39` 是
  `TRomHeader.iTime` 的高半字（round 19），不是 mask-ROM 入口。
- 该路径通常负责 MMU、cache、时钟和向量表的初始设置，然后跳入 kernel。
- **第 12 轮更新**：mask ROM 还会把 flash 前 64 KiB 的 boot bank **按链接地址
  展开**。boot bank 是多个不同基址的代码段拼接而成（A bias `0xb0`、B
  `0x19c`、C `0x374`）；按 flash 原样执行会让所有绝对跳转落进错误段。
  `recompiler/bootbank.py` 已能从 `0x3b0` 的 `sub r1, pc, #0x308` 和 17 个
  switch table 测出这些 bias 并重建 linked view。用
  `NK_LOW_ROM_IMAGE` 映射后 loader 连续执行 **600k 条、0 次 stale-call
  recovery**，到达 linked `0x1244` 的 image-loader 线程，并第一次写 UPP
  `0x08000008 = 0x37`。**当前缺口**：该线程在 `0xc58` 查
  `0xfffff400` 的 boot-image/region 列表时列表为空（`[0xfffff400]=0`），
  `0x1a1c` 返回 `-1` 后调用者未检查，进入 `0xc7c` 循环。第 13 轮已把这张表
  建模并从 `TRomHeader` 生成（boot/ROM/RAM 三个 bank，RAM 带 `0x4000`）：
  super page 变为 `0x802ff000`，`0x802ff400` 的压缩 list 有 3 项。现在失败点
  变成 KaeP payload 的 `0xf018e59f` 不在任何 bank 的 linear 区间内；KaeP 头
  （size `0x20`、value `0x1423dc`、重复 `0xdff9ea00`）需要**解包/解密**，
  不是再补 bank 表。
- 我们需要 runtime 里的 **mask ROM stand-in**：设定初始 CPSR/CP15/栈，映射
  ROM/RAM/high vectors，展开 linked boot bank，安装 boot-image 列表，然后
  跳到 `0x50310054`。
- **第 14 轮更新**：`0x1a1c`/`0x1b34` 的 type/flag 模型修正后，legacy
  `attr=1` 表被证明对它们不可见；`--profile linear`（RAM type2、ROM/boot
  type5 + `0x04000000`、6 MiB RAM）让 **原始** linked bank 越过 `0xc58`，
  600k 条后停在 `0x2fe4` 的 page-table 填充。新 frontier 不再是 KaeP 头，
  而是 **region 表的 `linbase` 双重语义 / page-table 目标地址**；同时
  `kaep.py` 已把 `0x20b0..0x6d9134` 的 852 个 page tag 结构化。真实 KaeP 解包
  （B6a2d2）仍是未完成项，但不再阻塞 loader 越过 0xc58。
- **第 15 轮更新**：段 C 的重定位把 CPU/board 表放回 linked `0x74b8`，CPU
  查表 `0x3b` 命中；`bootbringup.py` 的 descriptor/node + `staging` 表让
  loader 映射内核 code/data，并通过 UPP 两级握手（`0x58150422` 的 bit
  `0x400`、`0x58120a08` 非零），在 **36,732 条指令**后停在 **boot-image
  handoff `0x80`**。`0xfb8` 的真实 KaeP compressed-image parser 被一条
  `mov pc,lr` 显式跳过；`0x80` 仍不是可执行 boot image，所以真实 KaeP 解包
  （B6a2g）仍是下一个必须完成的步骤。

### B3. WD2 是 **packed** 镜像，但 runtime 布局已恢复（P0/P1，大幅推进）
- 23.3 MB 的 `6600_mcu.bin` 是 **section database**，不是 `rom_base` 起点的
  线性镜像：每个 image 是 `[TRomImageHeader][.text][rodata][.data][.edata]
  [TDllRefTable]`，header 和 code 的 file offset 与 runtime address 无关。
- **第 7 轮修正后的 runtime 布局**（`recompiler/romimage.py`）：
  - `0x50000000..0x50010000`：boot / vectors，文件前 64 KiB，线性；
  - `0x50300000..0x5030ff9c`：ROMFS 目录区。packed 目录块从文件 `0x3162b0`
    开始（root list 的存储值就是 `0x50300000`）；目录本身按内容定位：
    root file `0x32639c`、`\System` `0x325aa4`、`\System\Libs` `0x3162bc`
    （171 项）、`\System\Programs` `0x318170`（声明 236 项，实际只有 9 个有效条目，见第 10 轮修正）；
  - `0x50310000`：kernel text；`0x50338ac0` data；`0x50338fc0` export dir；
    `0x50339738` dll-ref；kernel 的 `TRomImageHeader` 在扁平 image 中位于
    `0x5030ff9c`；
  - `0x503397b4..0x515978dc`：**722 个 image 的 text**，两两不重叠
    （含 kernel 的 dllref、启动 DLL、应用和资源 DLL）；`build` 默认把
    header+text+data+edata+dllref 全部放到各自的 runtime 地址，共
    **1,580 个 section，无重叠**；
  - `0x5043fc90..0x515ed6e0`：ROMFS **数据文件**的 runtime 地址范围。
    这些地址**不是** packed 文件偏移：文件实际按 packed FS 顺序存放
    （0xff 填充，目录间 bias 不同），所以旧版 `file = va - ROM_BASE` 的
    线性复制是错的，现已默认关闭（`--romfs-linear` 仅供实验）。
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
- 第 7 轮：packed header 扫描从 4 字节改为 **2 字节**（header 可在 2 mod 4），
  722 个 image 全部装入扁平 image；boot harness 注册 kernel + dllref 的
  code range（`NK_RANGE_ALL=1` 接受全部 722 个）。faithful image 仍是
  364 条 frontier（不带 recovery）；relaid image 仍是 289 条。
- 仍缺：
  1. header 未描述的 **rodata/debug 块**：kernel `0x135c`，DLL2 `0x19dc`。
     它们没有被任何 text literal 引用，runtime 地址也没有空间；当前假设是
     ROM build 会剥离的 debug/rodata，尚未放入扁平 image。
  2. `0x10000..0x2a0000` 的高熵区还没有归属（可能是 PPM/fonts/预解包数据），
     当前不在扁平 image 中。
  3. ROMFS **数据文件**的 packed 顺序尚未重建（B3g）；目录树本身已经可读。
  4. **packed text 与 export table 的布局不一致**（第 7 轮新证据）：
     478 个 kernel export 中只有 17 个落在检测到的 prologue 上，其余回退
     距离在 0,4,8,...,44 上近似均匀分布。这不是 padding 能解释的；packed
     text 需要 function order / symbol 级恢复（B1g），relayout 只是部分修复。

### B4. 设备模型（P2）
- 还没有真正到达 UPP display/timer/keypad 的初始化；当前 MMIO bus 只打印访问。
- 需要先从 kernel 的第一次 MMIO 访问建立设备地址表，再逐个实现。

### B5. packed text / export table 不同布局（第 7 轮证据；第 16 轮关闭）

> **第 16 轮结论：本节的 17.2%/21.8% 和 1.27x/1.04x 结果全部是在带 page
> header 的 raw 字节上测的。去 header 后 kernel 98.1%、DLL2 98.3%，shift 0
> 就是 linked layout。本节以下内容只作历史记录。**
- kernel 的 export dir 有 478 个 4 字节对齐、全部落在 text 内的地址，但只有
  **17 个**落在「prologue + 前驱 terminator」检测到的函数起点上；其余地址到
  最近 prologue 的回退距离在 `0, 4, 8, ..., 44` 上近似均匀分布
  （每个距离 10–18 次）。如果是 padding 累积，回退距离应该随地址单调增长且
  总量不超过 `0x58`，实测不符合。
- **第 9 轮定量结果**（`recompiler/layout.py census`，用 export dir 作为 oracle）：
  - export entry 是**已 fixed-up 的函数地址**：小 DLL `0x101f6e00` 的 5 个
    entry 全部是 odd（Thumb bit），且 5/5 落在 `push {..,lr}`；`0x10001844`
    8 个 entry 中 6 个被检测为 prologue/after-terminator（另 2 个是 leaf）。
  - kernel：legacy 检测器 `82/478 = 17.2%`；第 10 轮的 pool-aware 检测器
    （穿过 literal pool 回溯 terminator）升到 **`104/478 = 21.8%`**，但同一
    检测器的随机 baseline 也从 13.1% 升到 **17.2%**，因此比值仍只有
    **`1.27×`**。
  - DLL `0x100039e5`：`258/1788 = 14.4%`，baseline 5.9% (`2.44×`)。
  - 应用当前 relayout 的 variable shift 后：kernel `58/478`，DLL2 不变；
    最优**常数** shift `0xb0`（pool-aware 下 `0x128`）也只有约 `112/478`；
    线性/放大 drift 模型没有改善。
  - packed kernel text 的 **1420/1430** 个 ARM 函数起点 4 字节对齐
    （0 个 ARM prologue 在 2 mod 4），**759/787** 个 literal pool 4 字节对齐。
    因此“移除/补回 2 字节 padding”最多只能解释 `0x58` 的 drift，不能解释
    export 与 BL target 的 mismatch。
  - 结论：**stored text 的 function layout 与 linked layout 不同**，不是
    padding 级别的差异。`relayout` 只能修复 pool 对齐和入口 literal，不能恢复
    跨函数的 real target/export 语义。
- **entry 的 literal 方程（第 10 轮）**：entry 的三条 `ldr` 都指向同一个
  packed pool `0x5031008e`：`ldr r0(0x50310070,imm 0x1c)`、
  `ldr r7(0x5031007a,imm 0x14)`、`ldr r0(0x50310084,imm 0x10)`。packed 下前两条
  都算到 `0x50310090`，但只有把 pad 放在 entry push 前（`0x50310056`）让整段
  Thumb 代码右移 2 字节，三条才分别读到 `0x00046564`、`0x00046fca`、
  `0x00000c03`。这说明 relayout 的入口修复是**局部自洽**的；也说明 BL target
  上的 `+2/+0xa/+0x18` 不能简单当成“callee 的累计 padding”（round 4 已证明
  同一 callee 在不同调用点的 bias 不同）。第 10 轮找到的合理 callee 候选是
  `0x50312c3c`（vtable thunk，+0x2e）和 `0x503134f0`（leaf，+0x32），说明
  “最近 prologue”不是正确的 callee 识别方法。
- **ROMFS 截断（第 10 轮）**：`\System\Programs` 的 `TRomDir` 声明 `0x5608`
  字节，但 packed 文件里只有 **9 个有效条目 / 0x114 字节**，其余 `0x54f4`
  字节被下一个 packed record 覆盖。旧解析把代码字节当成条目，产生 236 个
  “像模像样”的名字（`EStart.exe`、`EFile.exe` 等）——这些条目**不在本 dump
  中**。`\System\Libs`（171）、`\System`（23）、root（2）完整。`romimage.py`
  现在校验名字/地址并在 `scan` / `names` / `build` 中报告截断。
- 直接后果：
  1. 不要再靠放大 `NK_SNAP_WINDOW` 或继续调 padding 来推进；
  2. 运行时 call repair/snap 仍是有界 bring-up 手段，但**不是** faithful
     执行路径；
  3. 下一步是 **layout 级恢复**：从 WD2 容器 / ROM build 描述里拿到显式
     linked layout（B6b），或用 export + call graph + literal 里的 code
     pointer 解一个**符号级置换**（B1g2b），再重建 flat image。第 11 轮的
     `layout.py drift` 已经证明“全局单调 padding/drift”这个分支不成立：
     最强 drift 匹配仍与随机 null 相当（1.03–1.08×）。
- 这也解释了为什么 entry 能跑：entry 在 text 开头，前几个 callee 的局部
  偏差仍小，snap 后可以执行；越往后 function order 的差异越大，
  export/call target 就越不可信。


### B6. kernel entry 的真实 continuation（第 8 轮）

第 8 轮加入 `NK_WATCH` / `NK_SPIN` / `NK_CODE_ONLY` / `NK_ENTRY` 后重新核对
entry：

1. **faithful image 的 2,000,000 条不是进展**。没有 `config/patches-6600.txt`
   时，Thumb helper `0x5039ad9e` 在 `0x5039adcc` 没有 `pop`，会一路执行到
   ARM 代码；`NK_RECOVER` 回滚后把 trace 带进 `euser.dll`，最终在
   `0x50389330` 的字符串扫描循环里打转。**bringup image（同一布局 + patch）
   仍然 197 条指令、4 次跳过返回 `0xdead0000`**。以后比较 trace 必须同时
   标注 faithful / bringup。
2. **entry 的第三个调用是真的设备初始化**：`0x50313522` snap 到
   `0x50313518`，以 16-bit 写 UPP `0x5815053a`、`0x5815053c`、
   `0x5815056a`、`0x58150200`、`0x58150508`、`0x5815004a`；第五个调用访问
   `0x58120308` / `0x59e00040`。这是第一条确认的 UPP init 路径。
3. **entry 的第二个调用需要 kernel 对象状态**：它进入
   `0x503364b0`，该函数从栈参数取 vtable 并调用 `+0x14`；r0=0 时 vtable
   为空，被 recovery 跳过。旧日志把它标成 “unbound IAT” 是
   `ldr pc,[r3,#0x14]` 的误判；IAT 检测已收紧为 `ldr pc,[ip]` 且 offset 0，
   现在恢复日志正确显示 “pc left the image”。
4. **ROM 向量表不是 reset 路径**：`NK_ENTRY=0x50000000` 能执行 16,396 条
   ARM 指令、通过 CP15 c1 打开 MMU/cache、写 `0x580047e0`/`0x580047dc`、
   安装 high vectors，然后跳到 0。它是异常分发代码；mask ROM 仍应从
   primary image header 进入 `0x50310054`。
5. **两个低于 code base 的调用仍是主阻塞**：`0x5030fbc6`、`0x5030807a`
   不能用 +0x10000 简单重定位（落点都是函数中部）；下一步试 WD2
   “ALGORITHM” bytecode、function-order 约束求解，或从 kernel export /
   veneer 布局反推。
6. `wd2.py` / `romimage.py` 的 UID1 常量已修正：`0x1000007a` 是 EXE（kernel），
   `0x10000079` 是 DLL（`e32uid.h`）。

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

**P0-5 Boot-image handoff（第 15 轮 stand-in；第 16 轮真实 kernel；第 19 轮真实 extension）**
- 第 15 轮的 `bootbringup.py` + staging 表仍可到达 synthetic handoff（36,732
  条），但真实 KaeP 解包未完成。
- 第 16 轮改为直接启动真实 kernel：`romimage.py build` 从 packed stream
  组装，boot harness 以 ARM 模式进入 `0x50310054`，`NK_KERNEL_VECTORS=1`
  安装 kernel vector table，运行 **924,964 条、0 undefined、0 recoveries**。
- 第 18 轮证明 924k 是 SWI stub fall-through；真实 call-gate 路径在
  `NK_SWI_DIRECT=1` 下 7,540 条停在 unbound IAT。
- 第 19 轮修掉 ROMFS 启动表覆盖并加入 `NK_IMPORTMAP`：kernel 走真实的
  `rtc.dll` extension 加载，**8,512 条、0 unbound IAT、0 undefined**，
  停在 handle→object 路径（round 20 定性为 `CObjectIx::At`，不是 heap）。
- 第 20 轮加入 `NK_B7E`（thread → process → object index）并修正 MUL/MLA
  目标寄存器：**5,575,900 条、0 undefined、0 recoveries**，新 frontier 是
  第二个 thread `0x80001860` 的栈下穿（`pc=0`）。
  验收：`tools/test_imports.sh`、`tools/test_executive.sh`、`tools/test_b7e.sh`。

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
- [x] **B3b** runtime ROM 组装：`romimage.py build` → `out/6600_runtime.bin`，`--rom-image` 可启动
- [x] **B3d** 2 字节对齐 header 扫描 + record plausibility：722 个 image，text 区间不重叠；`build` 默认放置全部 image（1,580 section，无重叠），boot harness 注册 kernel + dllref 的 code range（`NK_RANGE_ALL=1` 接受全部）
- [x] **B3e** ROMFS 目录树定位（root / `\System` / `\System\Libs` / `\System\Programs`）+ `romimage.py names` 启动模块表；`ekern.exe -> uid3 0x100058e8`。第 10 轮修正：`\System\Programs` 实际只有 **9 个有效条目**（其余 `0x54f4` 字节被下一个 packed record 覆盖）；旧“236 项 / 193 映射”是误报
- [x] **B3f** 停止把 ROMFS 数据文件从 `addr - 0x50000000` 线性复制（它们按 packed FS 顺序存放）；`--romfs-linear` 仅保留作实验
- [x] **B3h** ~~恢复被覆盖的 `\System\Programs` 尾部~~：目录从未被覆盖，`0xec` page header 把它切断。**第 19 轮修正命名**：kernel 下方 586 项是 `\System\Libs`（ROM header 的 boot image table），`\System\Programs` 是 55 项 server 列表，171 项是 `\System\Libs\Plugins`；旧“586 Programs”结论作废
- [ ] **B3g** 重建 ROMFS 数据文件的 packed 顺序（目录 → 文件偏移），并填入扁平镜像。第 19 轮已放置 **174 个 E32Image 文件**（63 个 `.app` + plugin/driver）和 **85 个 AIF/MBM** 伴随文件；剩余 `.r01`/`.wav` 等数据文件仍需定位
- [x] **B3i** `romimage.py tree`：按内容恢复 `\System\Apps` 的 63 个 app 目录（含 `snakeex`、`mixpix`）；`build` 放置 76 个 E32Image 文件和 84 个 AIF/MBM
- [x] **B1g1** `recompiler/layout.py` + `tools/test_layout.sh`：把 export dir 当 layout oracle 做 census（stored-start rate vs random baseline、常数 shift、pool 对齐），确认 packed text 与 linked text 不是同一套 function layout
- [x] **B1g2a** 单调 drift 模型定量否定：`layout.py drift` 允许 export 匹配任意 `c <= V` 且 drift 非递减，kernel 在 `0x60/0xc0/0x200` 下仍只有 148/182/223，而随机 null 为 140/168/216（1.05/1.08/1.03×）。padding/relayout 不可能恢复 linked layout
- [x] **B1g2b** ~~layout 级恢复（非 drift）~~：`pagestream.py` 去掉 page header 后，kernel 469/478、DLL2 1757/1788，shift 0 就是 linked layout；不需要 function-order/relocation 表
- [x] **B1g2c** header-less block 分类：`layout.py gaps`；629 个 gap 中 15 个是第二段 Thumb/ARM code，kernel/DLL2 为 rodata。尚未发现它与 export 布局的对应关系
- [x] **B1g3** ~~用 B1g2b 的结果重新生成 flat image~~：`romimage.py build` 现在从 page-header-free stream 组装（1,833 section / 725 image），kernel export 98.1% 命中；旧 924,964 条已被第 18 轮证明是 SWI fall-through 循环，仅作回归基线
- [x] **B7a** `recompiler/executive.py`：解码 kernel SVC handler（`0x50314f30`）、bound `0x444` 与 273 项服务表 `0x50314aec`；固定 4 个零槽（`0x8a/0x94/0x95/0x96`），并把所有 image 的 SVC stub 映射回服务地址
- [x] **B7b** 解释器 `NK_SWI_DIRECT=1`：按 EKA1 call-gate 约定直接派发服务，保留 caller LR；`NK_FAKE_THREAD` + `NK_SWI_COMPLETE=0x4d` 把真实路径推进到 7,540 条 / unbound-IAT frontier
- [x] **B7c** IAT 检测扩展：slot 值 `0xffffffff` 或任何 code range 外的值按 unbound import 处理（`NK_IAT_FAKE=1` 可返回 0）
- [x] **B7c2** multiply 解码修正：只有 bits 7-4=1001 **且** bits 27-22=000000 才是 MUL/MLA；`sub sp,sp,#0x258` 不再清零 SP。`interp_selftest` 回归
- [x] **B7d1** banked registers / SPSR 模型（`NK_BANKED=1`）：MSR/MRS CPSR/SPSR、模式 bank、`movs pc,lr`/`ldm ^` 异常返回、harness 模式栈
- [ ] **B7d2** 真实 SVC/IRQ/FIQ 异常入口：`svc` 进入 `0x50314f30`，设置 SPSR_svc 并用 SPSR 返回；kernel 的 mode-stack setup 仍依赖缺失的 boot state
- [ ] **B7d3** boot descriptor / 初始模式栈：kernel 从 boot state 推导 `0xfffffffc/0`，需要真实 descriptor 或恢复其字段
- [x] **B7e1** `NK_B7E` 初始 thread → process → CObjectIx 图（round 20/21）：`0x50380270` 是 `CObjectIx::At` 而非 `RHeap::Alloc`；写 watch 在 kernel 发布 `[0x800017d4]` 时安装图。round 21 修正 element fetch 为 `TDesC8` descriptor 并返回带 vtable 的 CObject；运行 8,655 条、0 undefined/recoveries，停在 KERN-NO-SESSION 22。验收：`tools/test_b7e.sh`
- [ ] **B7e2** 真实 `SThread`/`SProcess` 字段：从 boot descriptor / kernel data 恢复，替代 `NK_B7E` 的占位 vtable 和 element fetch（round 20 的 5,575,900 条栈下穿已被 round 21 重新定性为 panic printer 循环，不再是直接 frontier）
- [x] **B7e3** `CObjectIx` element fetch 的 descriptor 语义（round 21）：array vtable 必须返回 `TPtrC8{length, object_ptr}`，随后 `TDesC8::Ptr` 才能解析；handle 路径返回带 vtable 的 harness CObject
- [x] **B7h** ~~ROMFS/E32 file-server session~~：round 21 的 KERN-NO-SESSION 22 在 round 22 被重新定性为 RTC 驱动 allocator import 的 ABI mismatch（EUser export 1504 = `RTest::operator()`，driver 期望 `operator new`），不是真实的 file-server 依赖。`config/callmap-rtc-6600.txt` 用 HLE alloc 修掉两个 `new` 站点；RTC 扩展完整初始化后 boot 到 27,470 条。真正的 ROMFS/E32 文件服务留到 P3（UI/app 加载）。
- [x] **B7h2** RTC 扩展的嵌套 E32Image：`rtc.dll` 记录里第二个 image（uid2 `0x100058d8`，text `0x5033ee14..0x50341414`，export_count 0）；kernel extension loader 调 entry 后还会调 export 1。`NK_EXT_STUB=1` 安装单入口 stub；HAL channel 返回真实对象；`NK_HLE_ZERO2` 处理 64-bit time 输出。验收：`tools/test_rtc.sh`（27,470 条、0 undefined/recoveries）。
- [ ] **B7h3** post-extension boot descriptor：`0x5031f3a8` 检查 `[0x80000b5c] == 0xff`，否则 PLAT 21；调用点先构造 `"IrqTimer0"` descriptor（`0x50337200`），所以这是 kernel timer/DFC 对象；下一步是恢复其初始 queue/state（与 B7d3 同源），而不是用 `NK_PATCH` 跳过。
- [ ] **B7e3** `CObjectIx::At` 的 handle→object 语义：`NK_B7E` 目前对 handle 0 返回 live current thread；需要真实 object index 元素（thread/process/chunk/…）
- [x] **B7f** flat-image import binding：`recompiler/imports.py` 枚举全镜像 **1,111** 个 stub、kernel **257** 个（236 EUser + 21 ELocl），唯一 kernel hole 是 ELocl ord 20；`NK_IMPORTMAP=config/imports-6600.txt` 在 flat loader 绑定该 slot（1 patched），运行时 `unbound IAT=0`。验收：`tools/test_imports.sh`
- [ ] **B7g** timer/interrupt/DMA 完成路径：替代 `NK_SWI_COMPLETE`，让 `TRequestStatus` 由设备模型完成
- [x] **P0-3d** 修复 Thumb BL 返回地址 + ARM PC-relative load 并加回归测试
- [x] **P0-3e** 修复 ARM data-processing 立即数被误判为 extra load/store（必须要求 bit25=0）；`and r0,r0,#0xff` 不再变成 `LDRH`。`interp_selftest` 新增 `and/orr immediate vs extra load/store` 回归
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
- [ ] **B1d4** 完整 function map：leaf 函数 + export 反推。第 9 轮确认：`0x5031261c` 的目标 `0x50312634`/relaid `0x50312636` 在 final layout 里也不可能是这个 ARM 函数的起点（差 2/6 字节），所以这 4 字节不是“再补 padding”能对齐的；call target 本身就是 stale，需要 layout 级恢复（B1g2）
- [ ] **B1d5** DLL 也重排并重建 flat image（当前实验镜像只重排 kernel）
- [ ] **B1e** 重新 census / 重新评估 callmap（第 4 轮数据受 Thumb bug 污染；round 6 的 relaid text 需要重新算 callmap 地址）
- [ ] **B1f** entry 的 `0x5030fbc6` / `0x5030807a` 真实 callee（低于 code base；relaid 后是 `0x5030fbc8` / `0x5030807c`）
- [x] **M17a** 解释器 call ring + `NK_WATCH`（最近 64 次调用，含 raw/resolved target、模式、r0-r3、sp）
- [x] **M17b** tight-loop watchdog `NK_SPIN` / `NK_SPIN_MAX`，命中后走 recovery 回滚
- [x] **M17c** PC 空间守卫 `NK_CODE_ONLY`（ROM / low alias / high vectors 之外视为坏返回）
- [x] **M17d** 重新核对 faithful vs bringup：2M trace 是缺 `pop` 的垃圾路径；bringup 197 条返回
- [x] **M17e** `NK_ENTRY` 覆盖启动地址；ROM 向量 `0x50000000` 跑 16,396 条并打开 MMU
- [x] **M17f** 修正 UID1 常量（`0x1000007a` = EXE，`0x10000079` = DLL）
- [x] **B6a0** mask-ROM 物理视图：boot bank 的跳转表是 0-based，代码必须在地址 0 执行。`NK_LOW_ROM=1`（copy 64 KiB + high vectors + opt-in low alias）下 loader 运行 299,991 条，循环于 `0x1248`
- [x] **B6a1** mask-ROM 二级 loader 入口：`0x500003bc` → `0x50001648`，输入是 `0x50000130` 的 KaeP 描述符；boot harness 支持 `NK_Rn` 注入。无 repair 时 211 条 / 10 次 recovery；`NK_CALL_POLICY=3` 时进入表扫描
- [x] **B6a1b** boot-bank 分段重建：`recompiler/bootbank.py`。`0x3b0` 的 `sub r1,pc,#0x308; add r0,r0,r1` 给出重定位加数 `0xb0`；17 个 switch table 测出段 A `0xb0`（7/7）、段 B `0x19c`（8 个，0x18c-0x19c）、段 C `0x374`（2 个）。**第 15 轮**用 linked `0x74b8` 的 CPU/board 表和文件 `0x782c` 的 16-bit 表项固定 C：`0x6000..0x8000 <- 0x6374..0x8374`；`build` 现在搬 A/B/C。两处间隙（0xec / 0x1d8）仍是另一基址的 ARM/Thumb 代码，不是 padding。验收：`tools/test_bootbank.sh`
- [x] **B6a1c** linked low-ROM view：`NK_LOW_ROM_IMAGE` + `NK_ENTRY=0x30c`。结果 **600,000 条、0 recoveries、0 undefined**，到达 linked `0x1244`，写 UPP `0x08000008=0x37`；round 11 的原样 bank 仍为 9 次恢复后循环 `0x125c`
- [x] **B6a2** boot-region/bank 表建模：`recompiler/bootregions.py` 从 `TRomHeader` 派生 boot/ROM/RAM 三个 bank（`{base,size,attr,linbase}`，count `+0`、entry `+8`、RAM attr `0x4000`），`NK_REGIONS` 装入。super page `0x802ff000`，list `0x802ff400` 有 3 项；`tools/test_bootregions.sh` 验收。剩余 frontier：KaeP payload 的 `0xf018e59f` 查表失败，需要 B6a2d 的解包/解密
- [x] **B6a2d1** KaeP/分页结构测量：`recompiler/kaep.py`。`0x20b0..0x6d9134` 是 852 个 6 字节 page tag（`20 00 00 00 dc 23`）的分页区，步长 `0x20ec`，首个 `0x20b0`、最后 `0x6d9134`；`0x128` 的同样字节是 KaeP size/value 前缀，不是 tag；kernel text 从 tag `0x326924` 开始。验收：`tools/test_kaep.sh`
- [x] **B6a2d2** KaeP/PeaK 容器解包：`0x124` 是 little-endian `0x5065614B`（PeaK），`record_size=0x20`、`image_size=0x1423dc`；0x20 字节 record 从 `0x12e` 开始（与 size 高半字重叠），image 从 `0x14e` 的 ARM vector table 开始。`kaep.py unpack` 逐字节导出 record/image（SHA-256），`verify` 固定边界。mask ROM 对 record 的 codec 仍未知，作为 B6a2d2b 保留
- [x] **B6a2d3** 显式 KaeP descriptor/node：`kaep.py install` 在 linked `0x80` 写 `ldr pc` trampoline + descriptor、在 `0xfd00 → 0xfd10` 写 boot-image node；原始 loader 越过 `0xc58` 后可直接进入 kernel entry
- [ ] **B6a2d2b** PeaK 0x20 字节 record 的真实 codec：当前 `unpack` 只保留原始 record，`install` 用 trampoline 代过；需要恢复 mask ROM 的压缩/加密语义并删除 stand-in
- [x] **B6a2e** boot-region 类型/标志修正：`0x1a1c` 第一遍要求 type 5..8 + attr `0x04000000`，`0x1b34` 要求 type 2；`bootregions.py --profile linear` + `NK_RAM_EXTRA`。用原始 linked bank 时 frontier 从 `0xc58` 推进到 `0x2fe4`（page-table 填充），0 recoveries / 0 undefined。验收：`tools/test_kaep.sh`
- [x] **B6a2f** `linbase` 双重语义的可用解：type-2 RAM 用 `0xffffffff`（`0x18b0` 的 no-expand 哨兵），把 code/data 拆成独立 type-5 bank。`--profile staging` 不再让 compaction 把 6 MiB RAM 当 page mask 展开；旧 `--profile linear` 保留为 0x2fe4 control
- [x] **B6a2b** 段 C 重定位完成（见 B6a1b）；两处间隙 code fragment 仍未搬。验收：`bootbank.py verify` 固定 stored `0x782c` -> linked `0x74b8` 的 CPU 表
- [x] **B6a2h** 显式 KaeP descriptor/node + staging section：`bootbringup.py` 在 `0x80` 写 descriptor、`0xfd00 → 0xfd10` 写 list head/node（`+0x5c=0`、`+0x60=0x05040000`），跳过 `0xfb8` 的假 KaeP parser；loader 映射 code/data 后到达 boot-image handoff `0x80`
- [x] **B6a2g** handoff 可执行并进入 kernel：`kaep.py install` 在 linked `0x80` 写入 `ldr pc,[pc,#-4]; .word 0x50310054`，loader 消费的 descriptor 字段保持不变；去掉 `NK_STOP_PC` 后运行 1,499,999 条 ARM、0 undefined、1 次 recovery，PC 进入 kernel `0x5039...`。验收：`tools/test_kaep.sh`、`tools/test_bootbringup.sh`。`0x3ae8 → 0x5bb4` stale call 仍待修
- [ ] **B6a1d** boot bank stream view 的 board/CPU detection：正确的 linked stream bank 在 `0x624c` 进入 panic（`r5=0x0c0047fd`、`r0=0x10`）。需要提供真实的 board/CPU 返回值或该寄存器的设备模型，而不是继续用 raw A/B/C 的 600k 假路径
- [ ] **B6a3b** kernel stack/super-page 初始状态：真实 kernel 在 924,964 条后 SVC stack 下穿 `0x7ff00000` 进入 `.data`，`0x5039b2b8` 的 `bx lr` 返回 0。需要从 kernel data/boot descriptor 恢复正确的 stack 或 super-page 内容（`NK_NO_SUPER_PAGE` 可关闭当前 1 MiB 映射做对照）
- [ ] **B6a3** entry 第二个调用的 kernel 对象 / vtable（`[0x80000000]` 全局 + `0x503364b0` 的 `+0x14` slot）
- [ ] **B6b** 解析 WD2 “ALGORITHM” header/bytecode，检查它是否描述 final layout / veneer / patch（容器 header 里尚未找到已知地址/大小值，需按格式解码）
- [ ] **B6c** 为 `0x5030fbc6` / `0x5030807a` 找到真实 callee（+0x10000 落点都是函数中部）
- [ ] **B1c** 从 callmap 的已验证站点反推 function map，减少 HLE/手工修复
- [ ] **B3c** header 未描述的 rodata/debug 块（kernel 0x135c / DLL2 0x19dc）归属；round 21 已用 `romimage.py --place-rodata` 放置 **RTC PDD uid3 0x100000d8** 的 0x279c block（vtable `0x503413e8`），其余 gap 仍待分类
- [x] **B7i** kernel EUser import ABI rebind（round 21）：4 个 slot（0x503b391c/0x503b4d1c/0x503b4b9c/0x503b3b70）指向错误 ABI；loader 支持对已绑定 slot 的 override，`config/imports-b7e-6600.txt` 固定到 AtC16 / 2-arg TPtr16 / TBuf16(int) / TDes16::Copy(buf,len)。验收：`tools/test_b7e.sh`
- [ ] **P1-1** CP15 / MMU flat mapping + high vectors
- [ ] **P1-2** MMIO 设备注册表 + 首批 UPP 寄存器
- [ ] **P2-1** LCD framebuffer → host window
- [ ] **P2-2** timer + IRQ + keypad
- [ ] **P3-1** ROMFS 文件服务 + SWI/HLE
- [ ] **P3-2** window server / fonts / first app。第 10 轮已恢复 `\System\Apps` 的 63 个 app 目录（含 `snakeex`、`mixpix`），下一步是把 app 的 `.app`/`.r01`/`.mbm` 数据按 B3g 放入扁平镜像
- [ ] **P4** radio/audio stubs + 性能与打包

---

## 7. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| E32Image relocation / packed 数据格式未知 | kernel 只能跑一部分 | 先用解释器 + trace 找到 loader 行为；对照 EKA1 文档 / N-Gage 参考 ROM |
| 分页 boot image / KaeP 语义未知 | loader 的 page-table 目标地址和 boot-image 列表可能不真实 | `kaep.py` 固定 852 个 tag 与 `KaeP` 头；`bootregions.py --profile linear` 是显式 masked-ROM 模型；真实解包仍需从 mask ROM/容器算法取证 |
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

- 2026-10-25（本轮 22）：**RTC 扩展是嵌套 E32Image；分配器 ABI、HAL channel
  与 post-extension boot descriptor**。
  (1) **“RTC rodata block” 是第二个 E32Image**：rtc.dll 记录内 stream
  `0x33ee60` 是 uid2 `0x100058d8`、uid3 0 的 DLL header，entry/code
  `0x5033ee14`、text `0x2600`、data `0x50341414`、export_count 0。它不是
  rodata，而是真正执行的 extension driver。kernel 的 extension loader 先
  调 entry，随后用 `[hdr+0x40]` 调 export 1；没有 export 时跳到 0。
  `NK_EXT_STUB=1` 安装单入口 export stub，并返回 HAL-like object。
  (2) **RTC `new` import 落在 `RTest::operator()`**：EUser export index
  1504 在本 ROM 是 RTest（引用 `": FAIL : ..."`/`"Checkpoint-fail"`），
  不是 `operator new`；driver 与 EUser 的 `.def` revision 不同。RTest
  路径调用 `Console::NewL` → `RLibrary::Load("econs")` → `svc 0x76`，
  没有 session 时 panic KERN-NO-SESSION。round 21 的 “file-server session”
  因此是 ABI mismatch 的症状。`config/callmap-rtc-6600.txt` 用
  `NK_HLE_ALLOC` 修掉两个 `new` 站点。
  (3) **HAL channel**：旧 stub 对 `r1=0` 返回整数 1，driver 把它存到
  `[this+8]` 并解引用；现在返回 `0x80003a40`（vtable `0x80003c00`）。
  `NK_HLE_ZERO2` 处理 driver 的 64-bit system-time 输出，避免与 round 21
  的 `TPtr16` rebind 冲突。
  (4) **结果**：RTC 扩展完整初始化，kernel 进入 post-extension boot init
  `0x50310fa4`；运行 **27,470 条、0 undefined、0 unbound IAT、0
  recoveries**，`call fixups=15`。新 frontier 是 `0x5031f3a8` 检查
  `[0x80000b5c] == 0xff`，否则 panic PLAT 21；该结构由 mask ROM/kernel
  startup 填充，直接 E32 entry 跳过了它。新增 `NK_POKE`/`NK_PATCH` 诊断
  开关（实验用）。验收：`tools/test_rtc.sh`；旧 `tools/test_b7e.sh`
  （8,655 / KERN-NO-SESSION 22）继续作为历史基线通过。

- 2026-10-25（本轮 19）：**ROMFS 启动表命名修正 + import/IAT 全表；真实 rtc.dll
  extension 路径**。
  (1) **586 项目录是 `\System\Libs`，不是 Programs**。kernel 下方的 packed
  目录块实际上按 runtime VA 线性排列：`\System\Libs` 在 `0x50301ec0`（586 项，
  从 `ekern.exe` 开始）、`\System\Programs` 在 `0x50307964`（55 项 server）、
  `\System\Libs\Plugins` 在 `0x5030000c`（171 项）。ROM header 的
  `iPrimaryFile=0x50301ec4`、`iSecondaryFile=0x50302148`、
  `iVariantFile=0x50301ee0`、`iExtensionFile=0x50301f3c` 都是 Libs 里的
  `TRomEntry`，分别指向 `ekern.exe`、`EFile.exe`、`ecust.dll`、`rtc.dll`。
  旧 build 把 171 项 Plugins 覆盖到 Libs 的 VA（并把 586 项 Libs 覆盖到
  Programs 的 VA），于是 kernel 的 boot loader `0x5031eae0` 把 UTF-16 文件名
  当作 `TRomImageHeader`（`[r3+4]`）并跳到 PC 0。`find_boot_dirs` 现按内容
  正确命名并新增 `plugins_*`；`build_image` 不再做破坏性 overlay，改为逐目录
  在 runtime VA 校验，只有布局不一致时才按内容回退重定位。
  (2) **`recompiler/imports.py`**：枚举 1,111 个 import stub，把 slot 解析为
  `(导出 image uid3, ordinal, 当前值)`。kernel 有 **257** 个（236 EUser + 21
  ELocl），唯一未绑定的是 **ELocl ord 20** —— ELocl 的 export table 最后一
  项是 `0xffffffff`，而 locale 初始化 `0x50326078` 无条件调用它。flat image
  里其它 slot 已经保存 linked 代码地址（slot 就是导出 image 的 `.edata`），
  所以“绑定 import”实际只需要处理这种 hole。
  (3) **`NK_IMPORTMAP`**：flat loader 扫描 stub，验证 slot owner/ordinal，
  对 `config/imports-6600.txt` 中的项写入绑定；`zero` 在 high-vector
  `0xffff0100` 生成 `mov r0,#0; bx lr` 并登记 code range。解释器的 IAT 判定
  也从“值 `>=0xffff0000` 一律 unbound”改为“只要落在已登记 code range 就是
  合法绑定”。
  (4) **新 frontier**：修正 ROMFS 后 kernel 真正加载/运行 `rtc.dll`
  extension，**8,512 条指令、0 undefined、0 unbound IAT**。随后 kernel 把
  `[0x800017d4]` 改写成 `0x802ffd00`（不再是 harness 的 `0x80003000`），
  EUser `RHeap::Alloc`（`0x50380270`）从 `[thread+0x18]`/`[process+0x38]`
  拿到 0，最后 `bx ip` 到 0：`pc=0`、`lr=0x503802ac`、`cpsr=0xdb`。下一项
  是 B7e（真实 thread/process/heap 或 boot descriptor 恢复）。
  (5) 新增 `tools/test_imports.sh`（import map + ROM header boot entry +
  flat-image slot bridge）；`test_romimage.sh` 与 `test_executive.sh` 已按
  新命名/新 frontier 更新。全部 13 个测试通过。

- 2026-10-25（本轮 18）：**SWI 不是 no-op：EKA1 executive call gate；924k 运行被重新解释**。
  EUser.dll 的 kernel API 是密集的单指令 `svc #N` stub 表；解释器把 SWI
  当 no-op 后，从 stub 进入会穿过整张表，落到 `0x50392dcc`，并进入每轮泄漏
  `0x4b0` 栈的循环。`0x5039b2b8` 的 `lr=0` 是栈下穿症状，不是 kernel
  stack/super-page frontier。新增 [`executive.py`](../recompiler/executive.py)：
  kernel SVC handler `0x50314f30` 的 bound literal 是 `0x444`，服务表
  `0x50314aec` 有 **273** 项（270 个代码地址 + 4 个零槽
  `0x8a/0x94/0x95/0x96`），每项都在 kernel text 内；`stubs` 可把所有
  image 的 SVC stub 映射回服务。解释器新增 `NK_SWI_DIRECT=1`：按 EKA1
  call-gate 约定直接派发服务并保留 caller LR（不是完整异常模型）。直接
  派发暴露两个真实缺口：`[0x800017d4]`（scheduler/current-thread）为 0，
  以及 IAT slot `0x5037d0e8 = 0xffffffff` 未绑定。用 `NK_FAKE_THREAD`
  最小对象 + `NK_SWI_COMPLETE=0x4d` 立即完成 stand-in 后，kernel 执行
  **7,540 条指令、0 undefined**，停在 **unbound IAT slot `0x5037d0e8`**
  （`sp=0x802fff08`、`cpsr=0x800000d3`）。`NK_IAT_FAKE=1` 对照跑 8,425
  条后因 `r4=0x00730072` 跳到 PC 0，这不是 frontier。这比 924k 早，
  但第一次走在真实路径上；旧 924k 仅作回归基线。解释器的 IAT 检测也
  修正为：`0xffffffff` 或 code range 外的 slot 值都算 unbound import。
  另外修复 multiply 解码与 data-processing immediate 的重叠：只有
  bits 7-4=1001 且 bits 27-22=000000 才是 MUL/MLA，`sub sp,sp,#0x258`
  不再被当成 MUL 并清零 SP（`interp_selftest` 回归）。新增 `NK_BANKED=1`
  banked/SPSR 模型（MSR/MRS、`movs pc,lr`、`ldm ^`、模式栈），但 kernel
  自己的 mode-stack setup 仍依赖缺失的 boot state。验收：
  `tools/test_executive.sh`、`tools/test_interp.sh`。

- 2026-10-25（本轮 17）：**KaeP/PeaK 容器解包；handoff 可执行并进入 kernel**。
  `0x124` 的 magic 是 little-endian `0x5065614B`（Nokia **PeaK**），后接
  `record_size=0x20`、`image_size=0x1423dc`。0x20 字节 record 从 file **`0x12e`**
  开始（首半字与 image-size 高半字重叠），image 从 **`0x14e`** 的 ARM vector
  table 开始，`+0x38`（file `0x186`）是真实 ARM 代码。新增
  `kaep.py unpack`（逐字节导出 record/image，SHA-256）与 `kaep.py install`
  （在 linked `0x80` 写 `ldr pc,[pc,#-4]; .word 0x50310054`，保留 loader
  需要的 descriptor 字段和 `0xfd00→0xfd10` 链）。`bootbringup.py` 不再 patch
  `0xfb8` parser。去掉 `NK_STOP_PC` 后，loader 从 handoff 进入 kernel entry
  `0x50310054`，运行 **1,499,999 条 ARM、0 undefined、1 次 stale-call
  recovery**，结束于 kernel `0x5039...`；此前会执行 record 字节并出现
  `SWI 0xf9ea00 at 0x80`。mask ROM 对 0x20 字节 record 的 codec 仍未解出，
  作为 B6a2d2b 保留；`0x3ae8 → 0x5bb4` stale call 仍在。验收：
  `tools/test_kaep.sh`、`tools/test_bootbringup.sh`。

- 2026-10-25（本轮 16）：**page header 去除；packed text = linked text；真实 kernel 入口运行 924,964 条**。
  发现 `0x20ec` 记录的真实结构是 **`0xec` 字节 header + `0x2000` 字节
  payload**，不是“6 字节 tag + 0x20e6 数据”。第 7–15 轮保留整个 header，
  等价于每 `0x2000` 字节插入 `0xec` 字节，直接导致：
  1. kernel entry 197 条 / 4 skips 执行的是 page header；
  2. kernel export 命中率 17.2%/21.8%、drift null、`relayout` 0x58 字节；
  3. `\System\Programs` 只剩 9 项。
  新增 [`recompiler/pagestream.py`](../recompiler/pagestream.py)（`analyze`/
  `build`/`verify`）。去 header 后 kernel header `0x31004c`、text `0x3100b0`、
  entry `0x50310054` 为 ARM `push {r4,r5,r6,lr}`；478 个 export **469 个
  （98.1%）** 命中函数起点，DLL `0x100039e5` **1757/1788（98.3%）**，best
  shift 0；Programs 完整 **586 项**。`romimage.py`/`layout.py`/`relayout.py`
  默认读 stream，`romimage.py build` 生成 1,833 section / 725 image，放置
  156 个 E32Image + 85 个 AIF/MBM。`wd2.py kernel` 改为从 stream 切 text
  （跳过 raw page header），`build_kernel_smoke.sh` 改用真实的 MMIO helper
  `0x50312eb4`，lift/解释器 smoke 仍通过。boot harness 修正 flat image entry mode
  （`entry & 1`）并新增 `NK_KERNEL_VECTORS=1`（kernel text 头 0x64 字节 →
  0/`0xffff0000`）和 `0x7ff00000..0x80000000` kernel super page 映射。结果：
  **924,964 条 ARM、0 undefined、0 call fixup、0 recoveries、2 reads /
  18 writes**，停在 `0x5039b2b8` 的 `bx lr` → 0（SVC stack 下穿 super page
  进入 `.data`）。`bootbank.py --stream` 把 stream `[0xb0,0x100b0)` 作为
  linked bank，15 个 switch table 全 bias 0；正确的 loader 在 2,111 条后停在
  `0x624c` 的 board/CPU detection panic（raw A/B/C 的 600k 作为 legacy
  control 保留）。验收：新增 `tools/test_pagestream.sh`；`test_layout`、
  `test_romimage`、`test_relayout`、`test_boot_recover`、`test_bootbank` 按新
  事实重写并通过，`test_interp`、`test_loader`、`test_bootregions`、
  `test_kaep`、`test_bootbringup` 也全部通过。

- 2026-10-25（本轮 15）：**段 C 重定位、CPU 表命中、loader 到达 boot-image handoff**。
  第 12 轮只把 A/B 搬到了 linked 地址，段 C 的 **16-bit CPU/board 表**仍在
  file `0x782c`，而 linked 代码在 `0x74b8` 读它。`bootbank.py` 现在把
  `0x6000..0x8000 <- 0x6374..0x8374`（bias `0x374`）；CPU 值 `0x3b` 命中，
  loader 不再在 `0x3d44` 的 `b .` panic。新增
  [`recompiler/bootbringup.py`](../recompiler/bootbringup.py)：在 linked `0x80`
  写显式 KaeP descriptor，在 `0xfd00 → 0xfd10` 写 **head → node → terminator**
  链（`+0x5c=0`、`+0x60=0x05040000`），并显式跳过 `0xfb8` 的假 KaeP
  compressed-image parser（`mov pc,lr`）。`bootregions.py --profile staging`
  用 `linbase=0xffffffff` 的 type-2 RAM、code/data type-5 bank，把内核 code
  映射到 `0x50310000`、data 到 `0x80000000`。解释器新增
  `NK_STOP_SELF_BRANCH`（`b .` 硬停，不被 recovery 吞掉）；MMIO bus 增加
  UPP boot 握手 stub（`0x58150422` bit `0x400`、`0x58120a08` 非零）。
  结果：`tools/test_bootbringup.sh` 跑到 **36,732 条指令、12 reads / 46 writes、
  1 recovery、0 undefined**，停在 **boot-image handoff `0x80`**。这仍是
  mask-ROM stand-in：`0x80` 是真实 mask ROM 解压 boot image 的目标，合成
  descriptor 本身不可执行；真实 KaeP 解包（B6a2g）是下一步。
  验收：`tools/test_bootbringup.sh` 通过；`test_interp`、`test_bootbank`、
  `test_bootregions`、`test_kaep`、`test_boot_recover`、`test_loader`、
  `test_romimage`、`test_layout`、`test_relayout` 全部通过。

- 2026-10-25（本轮 14）：**KaeP/分页 boot image；boot-region 类型/标志修正；越过 0xc58**。
  发现 `6600_mcu.bin` 的 `0x20b0..0x6d9134` 是 **分页区**：`0x124` 是
  `KaeP` 头（magic、size `0x20`、value `0x1423dc`），从 `0x20b0` 起每
  **`0x20ec`** 插入 6 字节 page tag `20 00 00 00 dc 23`，最后在 `0x6d9134`，
  共 **852 个 tag**。`0x128` 的同样 6 字节是 size/value 前缀，不是 tag。
  kernel text 的 file `0x326924` 正好是一个 tag（runtime `0x50310000`），entry `+0x54` =
  `nop; push {r4,r7,lr}`；去掉起始 tag 后 entry 在 `+0x4e`，同样是该指令。
  新增 `recompiler/kaep.py`（`analyze`/`despan`/`synth`/`verify`）和
  `tools/test_kaep.sh`。**注意**：despan 后 kernel export 命中从 104/478
  降到 67/478，所以分页 tag 不能解释 packed text 与 linked text 的 function
  order 差异；B1g2 仍然需要显式 layout/置换。
  第二个修正是 boot-region 表：`0x1a1c` 的第一遍只接受 **type 5..8 且
  attr bit `0x04000000`** 的 bank，`0x1b34` 只接受 **type 2**；第 13 轮的
  `attr=1` legacy 表对两者都不可见，这就是 KaeP 查表失败的真正原因。
  `bootregions.py --profile linear` 生成 RAM（type2 + super + linear，6 MiB）、
  ROM（type5 + linear）、boot（type5 + linear）三 bank；boot harness 新增
  `NK_RAM_EXTRA`。用原始 linked boot bank + linear 表，loader 越过 `0xc58`，
  600,000 条后停在 `0x2fe4` 的 **page-table 填充**，0 recoveries / 0 undefined。
  `kaep.py synth` 另提供 descriptor/node stand-in，同样越过 `0xc58`；两者都
  是 bring-up 手段，真实 KaeP 解包仍未完成。验收：`tools/test_kaep.sh` 通过，
  其余 8 个测试全部通过。

- 2026-10-25（本轮 13）：**ARM 立即数解码 bug + boot-region 表建模**。
  发现解释器的 halfword/signed-transfer 判定漏掉 **bit 25 = 0**：ARMv4T 的
  extra load/store 用 bit22 作立即数位，而 data-processing 用 bit25；当立即数
  的低字节含 bit7/bit4（如 `#0xff`）时，`and/orr/...` 会被误当成 `LDRH/STRH`。
  实测 boot bank `0x2b40` 的 `and r0,r0,#0xff` 把 `0x504` 变成 `0xffffd9c0`，
  修正后为 `4`。新增 `interp_selftest` 回归，其他所有 boot trace 的指令数不变
  （kernel entry 197、assisted 364、relaid 315、raw bank 399,991）。
  新增 [`recompiler/bootregions.py`](../recompiler/bootregions.py)：把 mask ROM
  交给二级 loader 的 bank 表显式建模为 `count + 0x10-byte {base,size,attr,linbase}`，
  从 `TRomHeader` 派生 boot `0..0x10000`、ROM `0x50000000..0x51600000`、RAM
  `0x80000000..0x80300000`（attr `0x4000`）。boot harness 新增
  `NK_REGIONS=path[@addr]`。装入后 linked loader 的 super page 从
  `0xfffff000` 回退值变为 **`0x802ff000`**，`0x1244` 栈 `0x802ff3fc`，
  `0x802ff400` 的 compact list 有 3 项；仍然 0 recovery / 0 undefined，
  UPP `0x08000008=0x37` 不变。新 frontier 在 `0xc58` 内部：KaeP payload 的
  `[0x80+0x20]=0xf018e59f` 不在任何 bank 的 linear 区间，KaeP 头
  （`0x124`，size `0x20`，value `0x1423dc`）指向高熵区，下一步是**解包/解密**
  而不是继续猜 bank 表。验收：`tools/test_bootregions.sh`，其余 7 个测试全部通过。

- 2026-10-25（本轮 12）：**boot bank 是分段链接的；linked view 零恢复启动**。
  boot bank（flash 前 64 KiB）由多个“按不同基址链接的代码段”拼接，绝对
  指针保留的是**链接地址**，所以按 flash 原样执行会让所有绝对跳转落进错误
  段。`0x3b0` 的 `sub r1, pc, #0x308; add r0, r0, r1` 把 **重定位加数 0xb0** 加到 r0
  （`linked = stored - 0xb0`），loader entry `0x3bc` 在 linked view 中是
  `0x30c`、descriptor 是 `0x130-0xb0 = 0x80`。两个独立锚点验证：loader
  最后 hand-off 的字面量 `0x1244` 对应 stored `0x12f4` 的真函数入口；第一个
  switch table（`0x1238`/table `0x1240`）的 `0x11a8/0x11b0/...` 加 `0xb0`
  正好是 `0x1258/0x1260/...` 的 case bodies。新增
  [`recompiler/bootbank.py`](../recompiler/bootbank.py)：`analyze` 扫描 17 个
  `ldrls pc,[pc,rN,lsl#2]` 表，用 `table_end - entry` 估计 drift（下界，同段
  一致到 `0x20`）：段 A linked `0x0-0x2000` ← stored `0xb0-0x20b0`
  （**0xb0**，7/7 精确）；段 B linked `0x2000-0x6000` ← stored
  `0x219c-0x619c`（**0x19c**，8 个表 0x18c-0x19c）；段 C stored `0x6374`
  （**0x374**，linked base 未定）。两处间隙 `0x20b0-0x219c`（0xec）和
  `0x619c-0x6374`（0x1d8）里还有 ARM/Thumb 代码和 literal pool，**不是
  padding**。`build` 把 A/B 搬到 linked 地址；boot harness 新增
  `NK_LOW_ROM_IMAGE` 把 64 KiB linked view 映射到 0，从 `0x30c` 启动。
  结果：**600,000 条、0 次 stale-call recovery、0 undefined**（round 11
  的原样 bank 是 9 次恢复后循环在 `0x125c`），第一次执行到 linked
  `0x1244` 的 image-loader 线程，并第一次写真实 UPP 寄存器
  `0x08000008 = 0x37`（linked `0x4298`，由返回 `0xb8000` 的 size probe
  `0x36a4` 调用）。新 frontier：`0xc58` 用 KaeP payload 的 key
  `[0x80+0xc]=0xdff9ea00` 查 `0xfffff400` 的 boot-image/region 列表，但列表
  为空（`[0xfffff400]=0`），`0x1a1c` 返回 `-1` 后调用者未检查，进入 `0xc7c`
  循环。下一步是安装该列表（B6a2）而不是继续放大 snap 窗口。boot harness
  另新增 `NK_DUMP`/`NK_DUMP_FILE`，可在结束时导出 guest 内存。验收：
  `tools/test_bootbank.sh`、`tools/test_interp.sh`、`tools/test_loader.sh`、
  `tools/test_romimage.sh`、`tools/test_layout.sh`、`tools/test_boot_recover.sh`、
  `tools/test_relayout.sh` 全部通过。

- 2026-10-25（本轮 11）：**padding-only drift 被定量否定 + mask-ROM loader 入口**。
  新增 `layout.py drift`：把“packed text = linked text 减去若干 2 字节 padding”
  的最强形式写成约束——export `V` 可匹配任意 `c <= V` 的 stored start，drift
  `V-c` 只需非递减，且允许跳过 export。kernel 在 drift 预算 `0x60/0xc0/0x200`
  下的最长单调链为 **149/183/225**（31.2%/38.3%/47.1%），同一批随机地址的
  null 为 **140.4/168.6/217.2**，比值 **1.06/1.09/1.04**；最优 drift 总是
  顶到预算上限，说明匹配器只是在利用自由度，而不是发现了 padding。结论：
  **B1g2 的 monotone drift 分支关闭**，stored function order 与 linked order
  不同，只能靠显式 function-order/relocation 表（B6b）或符号级置换恢复。
  `census` 同时新增 `in-code%`：692 个有 export 的 image 中 135 个 entry 全在
  自身 code 内（kernel 与启动 DLL）、155 个约一半、36 个更低、366 个为 0；
  kernel 的 478 个 entry 全部 in-code，因此它的低 start rate 是真实 layout
  不匹配，不是 export 段解析错位。`tools/test_layout.sh` 增加 drift 回归
  （`ratio < 1.2`），并保留 104/478（1.27x）的池感知 census 不变量。
  boot harness 新增 `NK_Rn`（n=0..12）寄存器注入；用
  `NK_ENTRY=0x500003bc NK_R11=0x80000000 NK_R10=0` 复现 mask-ROM 二级
  loader：入口经 `0x50001648` 进入，`0x50000124` 的 **KaeP** 描述符
  （payload `0x50000130`）是它的输入。无 call repair 时执行 **211** 条、
  10 次 stale-call recovery 后返回 sentinel；`NK_CALL_POLICY=3
  NK_SNAP_WINDOW=0x400` 时首个 stale call（`0x50001664 -> 0x50002ae4`）
  被 snap 到最近 prologue `0x500029dc`，loader 运行 **>300,000** 条后在一个
  base=0、count≈`0x80000000` 的表上扫描。snap 只是 bring-up 手段，不能
  证明 `0x29dc` 就是目标 callee；但扫描本身说明 loader 需要 mask ROM 应
  安装在地址 0 的 boot image/super-page 表，flash dump 中没有；下一步是
  建模该表（B6a2），而不是继续放大 snap 窗口。进一步发现 boot bank 的
  类型跳转表是 **0-based**（`0x2908` 等），因此 mask-ROM 物理视图是
  **boot code at 0 / ROM 字面量 at 0x50000000 / RAM at 0x80000000**。
  新增 `NK_LOW_ROM=1`：复制前 64 KiB 到 0、登记 code range、复制 16 个
  high vectors，并让解释器在 opt-in 时允许 low alias（默认仍把
  `0x00000000` 的 stale call 视为 fault，避免破坏 bring-up 路径）。
  该视图下 loader 无 call repair 运行 **299,991** 条，随后在 high-vector
  异常路径循环于 `0x1248`；下一 frontier 是异常/super-page state。
  另外新增 `layout.py gaps`：629 个 header-less block 中 404 个是
  rodata、**15 个是第二段 Thumb/ARM code**（最大 `0x100039e1` 0x1838、
  `0x100058c1` 0xbce、`0x101f85e3` 0xa32）；kernel 0x135c 和 DLL2 0x19dc
  仍判为 rodata。该发现不解释 kernel export mismatch，但说明 packed record
  里确实混有 header 未描述的可执行片段。
  验收：`tools/test_layout.sh`、`tools/test_interp.sh`、
  `tools/test_loader.sh`、`tools/test_boot_recover.sh`、
  `tools/test_relayout.sh` 全部通过。

- 2026-10-25（本轮 10）：**pool-aware 起点检测 + Programs 目录截断 + entry literal
  方程**。`layout.py` 的 `start_kind` 新增 `pool_aware`：从候选地址向前穿过
  literal pool 回溯到 terminator，从而识别 pool 后的 leaf 函数。kernel 的 478
  个 export 命中从 `82/478 = 17.2%` 升到 **`104/478 = 21.8%`**，但同一检测器的
  随机 baseline 也从 13.1% 升到 **17.2%**，比值反而降到 **1.27×**；常数 shift
  最好 `0x128`（112/478），仍远低于 linked image。结论不变：packed text 与
  linked text 不是同一套 function layout。第 10 轮还逐条验证 entry 的三条
  `ldr`：只有把 pad 放在 `0x50310056`（entry push 前）才能同时读到
  `0x00046564 / 0x00046fca / 0x00000c03`，说明当前 relayout 的入口修复是
  局部自洽的；BL target 的 bias 仍然不能当累计 padding（round 4 已证明是
  per-call-site），合理 callee 候选是 `0x50312c3c`（vtable thunk，+0x2e）
  和 `0x503134f0`（leaf，+0x32）。
  `romimage.py` 的 `TRomDir` 解析加入条目校验（ASCII 名字、地址在 ROM 窗口、
  size 上限）并显式报告截断：`\System\Programs` 声明 `0x5608` 字节，实际只有
  **9 个有效条目 / 0x114 字节**，其余 `0x54f4` 字节被下一个 packed record
  覆盖。旧解析读到的 236 项（`EStart.exe`、`EFile.exe` 等）是把代码当条目的
  误报；`\System\Libs`（171）、`\System`（23）、root（2）完整。新增
  `B3h`（恢复被覆盖的 Programs 尾部）。同时新增 `romimage.py tree`：在 64 KiB
  packed 目录块中按内容恢复整棵 ROMFS 树，`\System\Apps` 的 **63/63** 个 app
  目录全部定位，包括 `snakeex`（SnakeEx.app 0x7ddc）和 `mixpix`
  （mixpix.app 0xd718），为 P3 提供完整应用清单。`build` 现在把 **76 个
  E32Image 文件**（63 个 `.app` + 13 个 plugin/driver）按 `iCodeAddress-0x64`
  映射原样复制到 runtime 地址，并用 AIF/MBM UID 定位 **84 个 AIF/MBM**
  伴随文件；`SnakeEx.app` 在 flat image `0x5147f060` 逐字节验证一致。
  `.r01`/`.wav` 数据仍待 B3g。验收：`tools/test_layout.sh`、
  `tools/test_romimage.sh` 通过。

- 2026-10-24（本轮 9）：**export 表作为 layout oracle；确认 packed text 不是
  linked text**。新增 `recompiler/layout.py`（`census` / `pools` / `verify`）
  和 `tools/test_layout.sh`。确认 `iExportDir` 是**按 ordinal 的函数地址
  数组**（Thumb 带 bit 0）：小 DLL `0x101f6e00` 的 5/5 个 entry 都落在
  `push {..,lr}` 上，`0x10001844` 8 个中 6 个（另 2 个是 leaf）也对得上。
  但 kernel 的 478 个 export 只有 **82 个（17.2%）**落在 stored text 的
  函数起点，而随机 4 字节对齐地址的 baseline 是 **13.1%**（仅 1.31×）；
  DLL `0x100039e5` 是 258/1788 = 14.4%，baseline 5.9%（2.44×）。
  当前 relayout 的 variable shift 下 kernel 仍只有 58/478；最优常数 shift
  `0xb0` 也只有 93/478；线性 drift 没有改善。packed kernel text 的
  1420/1430 个 ARM 起点和 759/787 个 pool 都是 4 字节对齐，所以 2 字节
  padding 最多解释 `0x58` 的 drift，**不能**解释这个差距。结论：stored
  text 的 function layout 与 linked layout 不同；`relayout` 只能修复 pool
  和入口 literal，跨函数 target/export 需要 layout 级恢复（B1g2）。
  同时修正 B1d4 的表述：entry 的 `0x50312634` 目标即使回到 final layout
  也不是该 ARM 函数的起点（差 2/6 字节），不是“再补 4 字节”的问题。
  验收：`tools/test_layout.sh` 通过（并把“kernel 比值 < 2×”作为诊断
  不变量）。

- 2026-10-24（本轮 8）：**call ring / spin watchdog / PC 空间守卫；重新核对
  entry frontier**。解释器新增 `NK_WATCH`（命中地址时打印寄存器 + 最近
  64 次 BL/BLX 的调用环，含 raw/resolved target、模式、r0-r3、sp）、
  `NK_SPIN`/`NK_SPIN_MAX`（同一 PC 访问 N 次即判定 tight loop，走 recovery
  回滚）、`NK_CODE_ONLY`（PC 在 ROM `0x50000000..0x51000000`、pre-MMU low
  alias `<3 MiB`、high vectors 之外时视为坏返回）、`NK_ENTRY`（覆盖启动
  地址）。`boot_kernel` 默认在 ROM 启动路径开启 `NK_CODE_ONLY`。
  重新核对后确认：faithful image（无 patch）的 **2,000,000 条 trace 是
  `0x5039adcc` 缺失 `pop` 造成的垃圾路径**（helper 跑进 ARM 代码 →
  `euser.dll` → `0x50389330` 扫描循环）；bringup image 仍然 **197 条返回**。
  entry 的第三个调用（`0x50313522` → `0x50313518`）真实写入 UPP
  `0x5815053a/0x5815053c/0x5815056a/0x58150200/0x58150508/0x5815004a`，
  第五个调用访问 `0x58120308`/`0x59e00040`。`NK_ENTRY=0x50000000` 启动
  ROM 向量代码可执行 **16,396 条 ARM 指令**、通过 CP15 c1 打开 MMU/cache、
  写 `0x580047e0`/`0x580047dc`、安装 high vectors 后跳到 0 —— 这是异常
  分发代码，不是 reset 路径。entry 的第二个调用进入 `0x503364b0`，从栈
  参数取 vtable 并调用 `+0x14`，r0=0 时失败；旧日志的 “unbound IAT” 是
  `ldr pc,[r3,#0x14]` 的误判，检测已收紧为 `ldr pc,[ip]` + offset 0。
  修正 `wd2.py`/`romimage.py` 的 UID1 常量：
  `0x1000007a` = EXE（kernel），`0x10000079` = DLL（`e32uid.h`）。
  验收：`tools/test_interp.sh`、`tools/test_boot_recover.sh`、
  `tools/test_relayout.sh` 全部通过。
- 2026-10-24（本轮 7）：**完整 image map + ROMFS 目录树**。
  `recompiler/romimage.py` 的 `TRomImageHeader` 扫描从 4 字节步进改为
  **2 字节**——packed record 的 header 可以在 2 mod 4（`MmfAudioController.dll`
  在 file `0x7271ca`），旧的 4 字节扫描静默丢掉了 40+ 个 image。配合
  record plausibility（declared sections ≤ next header、rodata 间隙 ≤ 0x2000）
  得到 **722 个 image**（781 候选 / 59 误报），text 区间两两不重叠，
  覆盖 `0x5030ff9c..0x515978dc`。`build` 默认放置全部 722 个 image
  （1,580 个 section，无重叠），不再只放 kernel + 2 个 dllref；
  `--only-reachable` 保留旧行为。boot harness 的扁平镜像加载器也改为
  2 字节扫描，默认只把 kernel + 其 dllref 注册为 code range
  （`NK_RANGE_ALL=1` 接受全部）。
  ROMFS 目录树按内容定位：root file `0x32639c`（`\System`/`\Nokia`）、
  `\System` `0x325aa4`、`\System\Libs` `0x3162bc`（171）、
  `\System\Programs` `0x318170`（声明 236；第 10 轮修正为实际 9 个有效条目）。
  新增 `romimage.py names`
  输出启动模块表：`ekern.exe -> uid3 0x100058e8`（code `0x50310000`）、
  `ecust.dll`、`ecomm.ldd` 等 9 个模块；
  `\System\Libs` 73/171 映射到 packed record（第 10 轮修正：Programs 为 6/9）。
  同时修正一个真实错误：ROMFS **数据文件并不在** `addr - 0x50000000`，
  旧 build 往扁平镜像的 17 MB 区域复制了无关代码；数据文件按 packed FS
  顺序（0xff 填充）存放，现在默认不复制（`--romfs-linear` 实验开关）。
  新证据（B5）：478 个 kernel export 中只有 17 个落在 prologue 上，回退
  距离均匀分布 —— packed text 与 export table 不同布局，padding/relayout
  只是部分修复。faithful image 仍 364 条 frontier，relaid image 仍 289；
  `tools/test_romimage.sh` 已更新为 722-image / 1580-section / ROMFS 树
  的验收。
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
