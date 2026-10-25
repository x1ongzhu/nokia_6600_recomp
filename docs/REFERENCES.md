# 本地开发参考资料

本次收集日期：2026-10-24；**2026-10-25 补入本地提供的 Series 60 2.0 SDK**。
参考目标是 Nokia 6600 / ARM920T / ARMv4T / Symbian 7.0s（EKA1），优先服务于
当前的 E32Image、ROMFS、装载和 ARM/Thumb 互操作问题。**资料是研究参考，不是
新增运行依赖，也不代表已验证的 6600 硬件行为。**

## 存放与复现

- 本地目录：[`references/`](../references/)，合计约 **540 MiB**，其中
  `Series60_v20/` 约 **349 MiB**。
- 版本与下载包 SHA-256：[`tools/reference_sources.json`](../tools/reference_sources.json)。
- 由脚本下载的资料，其下载地址、时间、大小及校验值见
  `references/<name>.metadata.json`。
- `references/` 已加入 `.gitignore`，避免第三方源码、上游测试资源和预编译文件混入本项目提交。
- 除 `Series60_v20/` 外，下载的是固定 Git commit 的源码归档及随附文档，不包含
  Git 历史；不递归下载子模块。为安全起见只提取普通文件和目录，忽略符号链接，
  不保留执行位。不执行上游代码。
- `references/Series60_v20/` 是用户本地提供的 Nokia **Series 60 2.0 SDK for
  Symbian OS**，不由 `fetch_references.py` 下载，也没有固定 commit、SHA-256 或
  `*.metadata.json`。它属于 Nokia/Symbian 的专有 SDK（文档首页标注 2003 年版权与
  保密信息），只应留在本机；新环境需自行取得合法副本，并按相同目录名放置。
- 脚本没有下载手机固件、ROM、SDK 安装包或游戏。上游源码归档本身可能附带测试数据、
  资源或预编译依赖；本地保存不意味着可以随本项目重新分发。

在干净目录恢复脚本管理的资料（仅需 Python 3 标准库及网络）：

```sh
python3 tools/fetch_references.py
```

也可选择一份，或下载到其他目录：

```sh
python3 tools/fetch_references.py eka2l1
python3 tools/fetch_references.py --destination /path/to/reference-copy
```

脚本校验固定归档的 SHA-256，拒绝覆盖已有同名目录，避免丢弃本地笔记或修改。
重下前请先移走旧目录。GitHub 若重新打包导致哈希变化，应先核实来源，不能直接跳过校验。
调整版本时同时更新 commit、校验值及本文中的说明。

本地 SDK 不由脚本恢复；确认它已就位：

```sh
test -f references/Series60_v20/Epoc32/include/e32std.h &&
test -f references/Series60_v20/Epoc32/release/armi/urel/euser.lib &&
echo "S60 2.0 SDK present"
```

缺少文件时先检查目录名和 SDK 解包层级，不要用脚本重建或从其他 SDK 版本拼接。

## 资料清单

以下路径均相对于项目根目录；脚本管理的资料含完整 commit，本地 SDK 没有固定
commit/校验值。版本边界见各节说明。

| 本地目录 | 上游 / 固定 commit | 主要用途 | 许可提醒 |
|---|---|---|---|
| `references/eka2l1/` | [EKA2L1/EKA2L1](https://github.com/EKA2L1/EKA2L1) / `a6d67d8d40f0` | EKA1/E32Image、ROM 解析、代码段重定位、Symbian 服务 HLE | 根目录 `LICENSE` 为 GPLv3；第三方组件另查各自许可 |
| `references/symbian-kernelhwsrv/` | [SymbianSource/oss.FCL.sf.os.kernelhwsrv](https://github.com/SymbianSource/oss.FCL.sf.os.kernelhwsrv) / `0c3208650587` | ROM 结构定义、ARM 内核和硬件抽象的术语及设计 | 所查核心文件头为 EPL-1.0；逐文件核查 |
| `references/symbian-buildtools/` | [SymbianSource/oss.FCL.sf.os.buildtools](https://github.com/SymbianSource/oss.FCL.sf.os.buildtools) / `7b35cd328d3a` | E32Image/ROM 构造、压缩与格式文档 | 所查 E32 工具文件头为 EPL-1.0；其他组件可能不同 |
| `references/ngagerecomp/` | [sp00nznet/ngagerecomp](https://github.com/sp00nznet/ngagerecomp) / `2d72acd88c75` | 本项目同源 ARMv4T lifter、CPU/runtime 设计 | 根目录 `LICENSE` 为 MIT，复用时保留声明 |
| `references/dct4crypt/` | [g3gg0/DCT4Crypt](https://github.com/g3gg0/DCT4Crypt) / `0c22856d8cb5` | 老式 DCT4 算法来源核对 | 此快照只有 `decr.c`，未见明确许可证；不可假定可自由复制或分发 |
| `references/Series60_v20/` | Nokia **Series 60 2.0 SDK for Symbian OS**（2003；本地手工提供，无固定归档、commit 或校验值） | Symbian OS 7.0s / S60 头文件、ARM/Thumb 导入库、SDK 文档与示例；用于 API/ABI 对照 | Nokia/Symbian 专有；仅本地研究，禁止提交、复制或再分发 |

公开可读不等于许可兼容。阅读和验证格式与直接移植实现应分开处理；尤其不要把 GPL
实现直接复制进采用不同许可的代码，也不要因已有致谢就假定 DCT4Crypt 已取得授权。

## 优先阅读入口

### 1. EKA2L1：优先解决装载和 ROM 解析

- `references/eka2l1/README.md`：项目概况。
- `references/eka2l1/src/emu/loader/include/loader/e32img.h`
  和 `src/emu/loader/src/e32img.cpp`：E32Image 头、段、导入及重定位解析。
  `parse_e32img_header` 有明确的旧 EKA1 分支（该快照约第 268 行），
  不能只看后面的现代格式结构体。
- `references/eka2l1/src/emu/loader/include/loader/rom.h`
  和 `src/emu/loader/src/rom.cpp`：ROM 头与文件系统；头中有 `eka1_diff0/eka1_diff1`。
- `references/eka2l1/src/emu/loader/include/loader/romimage.h`
  和 `src/emu/loader/src/romimage.cpp`：区分 ROM 内映像与独立 E32 文件。
- `references/eka2l1/src/emu/kernel/src/codeseg.cpp`、`libmanager.cpp`：
  代码段装载、地址修正及 EKA1 分支。
- `references/eka2l1/src/tests/epoc/loader/e32img.cpp`、`romimg.cpp`：
  查阅测试方式，但不直接将上游测试资源作为本项目可分发样本。

建议先与 `recompiler/wd2.py` 中的字段偏移、入口含义和地址换算逐项对照，
区分「文件偏移 / ROM 地址 / 装载地址」，再验证重定位和压缩假设。
EKA2L1 是仿真/HLE 项目，不是 UPP_WD2 裸机启动或 MMIO 的权威实现。

### 2. Series 60 2.0 SDK：7.0s 的 API/ABI 对照

本地路径：`references/Series60_v20/`。这是 2003 年的 Nokia **Series 60 2.0 SDK
for Symbian OS**（Windows 宿主）。`Epoc32/data/epoc.ini` 指向
`\Symbian\7.0s\Series60_v20`，`Epoc32/data/buildinfo.txt` 的 `DeviceFamilyRev`
为 `0x700`；目标 6600 是 Symbian OS 7.0s / S60 2nd Edition，代际一致。
**它不是 S60 3rd Edition / Symbian 9 的 SDK**，不能把新版本的 API 或 ABI 套过来。

- `Epoc32/include/`：1,393 个顶层文件（另 16 个子目录，共 1,643 个文件，其中
  1,221 个 `.h`），如 `e32std.h`、`e32base.h`、`e32panic.h`、`eikappui.h`、
  `aknapp.h`；适合核对 HLE 的参数、返回值、panic 和错误码。
- `Epoc32/release/armi/urel/`、`thumb/urel/`：分别有 391 和 415 个
  `.lib` 链接库，其中大部分是系统 DLL 的 ARM/Thumb 导入库。`.lib` 内嵌
  `<DLL>[UID3].DLL`，如 `EUSER[100039e5].DLL`、`ELOCL[100065a5].DLL`；
  这两个 UID3 与 6600 ROM 中的同名 DLL 一致，可帮助确认 import slot 的宿主
  DLL，并读取 mangled 符号名和类名。
  **但它们不是 6600 ROM 导出表的副本**：SDK 中的 DLL 只代表该 SDK 自身的构建，
  不能证明目标 ROM 的导出顺序；目标 ROM 甚至可能由不同的 `.def` 构建
  （第 21 轮已确认 kernel 与 EUser 的导出顺序不一致）。不要按 `.lib` 的成员
  顺序或符号顺序推断 ROM ordinal，必须回到目标 ROM 的 `.edata` 和调用点。
- `Series60Doc/`：20 份文档，包括 `series60apiref.chm`、`series60guides.chm`、
  `series60examples.chm`，以及 UI style guide、application framework、安装包、
  document handler 等 PDF；适合查 API 语义、S60 UI 行为和应用生命周期。
- `Series60Ex/`：39 个示例目录（Avkon UI、listbox、menu、sockets、sound、
  Bluetooth、client/server 等），带 `.mmp`/`.rss`/`.cpp`/`.hrh`；
  `Examples/` 另有 11 类 Symbian 基础示例。
- `SymbianSampleCode/`：更老的 Techview 示例；其 `readme.txt` 明确说明它们与
  S60 UI 不兼容，只能作为 API 用法参考，不能当作可编译工程。
- `Epoc32/tools/`、`Epoc32/gcc/`：Windows 宿主的 PE32 工具和 GCC 2.9-psion-98r2
  交叉工具链（`petran.exe`、`makesis.exe`、`rombuild.exe` 等），不能在 macOS 上
  直接运行，本仓库也不依赖它们构建。
- `Series60Tools/`：Visual C++ AppWizard、EnvironmentSwitch、EpocToolbar 和
  MBM viewer 等 Windows IDE 集成，同样不能在本机直接使用。
- `Epoc32/release/wins/urel/epoc.exe` 与 `z/system/`：SDK 的 Windows 模拟器环境，
  可作 UI/系统服务的行为参考；它是 x86 宿主实现，不是 ARM 目标代码，不能作为
  6600 的内存布局、指令或 MMIO 证据。

SDK 与固件同代只能提高 API 名称、签名和错误码的置信度，不能证明固件实现、
对象布局或某个 ordinal 的语义；所有结论仍以 `6600_mcu.bin` 的 header/export/
调用点和 runtime 观测为准。头文件中的 inline、类布局和目标 ABI 也不可直接当作
二进制布局。**只做阅读对照，不要复制 SDK 的源码、头文件、文档或二进制到仓库、
测试或发行物。**

### 3. Symbian 官方开源资料：结构与文档交叉验证

- `references/symbian-kernelhwsrv/kernel/eka/include/e32rom.h`：ROM 结构定义。
- `references/symbian-kernelhwsrv/kernel/eka/include/`、`kernel/eka/`：
  内核接口、ARM 启动及内存模型的背景资料。
- `references/symbian-buildtools/toolsandutils/e32tools/inc/e32image.h`：映像结构。
- `references/symbian-buildtools/toolsandutils/e32tools/e32image/e32image.cpp`、
  `imgdump.cpp`：ROMBUILD 所用 E32Image 操作和字段打印。
- `references/symbian-buildtools/toolsandutils/e32tools/e32image/deflate/`：压缩实现。
- `references/symbian-buildtools/toolsandutils/e32tools/rombuild/`：ROM 生成逻辑。
- **随附格式文档**：
  `references/symbian-buildtools/toolsandutils/e32tools/dspec/romimage.rtf`，
  可用 macOS 文本编辑打开；另有 `ddesign/e32rom.mdl` 模型资料。

**版本边界：这两份 SymbianSource 快照主要是较新的 EKA2 时代代码，不是
6600 的 EKA1 7.0s 内核源码。** 安全能力字段、头部尺寸、压缩与内存布局不能照搬。
发现差异时应保留目标固件的证据，不应用较新结构强行解释旧映像。

### 4. ngagerecomp：重编译器与 runtime

- `references/ngagerecomp/recompiler/README.md`、`recompiler/lift.py`。
- `references/ngagerecomp/runtime/README.md`、`runtime/include/ngage_cpu.h`。
- `references/ngagerecomp/harness/README.md`。

适合对照 ARMv4T 指令语义、标志位、PC/LR 和调用约定。
N-Gage 应用级兼容层不等于 6600 整机启动；其内存布局也不能直接替换本项目稀疏总线。

### 5. DCT4Crypt：只用于老式 DCT4 路径

入口为 `references/dct4crypt/decr.c`，仅用于核对 6100 等老式 `DCT4` chunk
格式。**它不是 6600 WD2 BT2 / WD2 ALGORITHM 装载器**，
不要用于解释 WD2 的 EKA1 头或压缩区域。

## 使用这些资料时的证据要求

1. 将目标字段与 EKA2L1 的旧格式分支交叉核对，为 `wd2.py` 增加不依赖真实固件的合成测试。
2. 分别验证 ROM 内映像与独立 E32Image；不要假定扫描到的每个 UID 都意味着同一种文件头。
3. 对 ARM/Thumb 停点先检查字节、PC/LR、状态位和 veneer，再判定是否缺失重定位。
4. 当前 `BOOT.md` 提到的 `KaeP`/压缩、地址偏置与互操作原因仍需目标映像证据；
   下载这些资料本身不构成确认，也不能证明高熵区域一定需要某种解压算法。
   第 16 轮已把 `0x20b0` 起的 852 个 `0x20ec` 记录确定为 **`0xec` page
   header + `0x2000` payload**，并用 `recompiler/pagestream.py` 去 header；
   kernel export 命中率因此从 17.2% 升到 98.1%。`0x124` 的 `KaeP`/PeaK
   容器边界已测量为 record `0x20` @ `0x12e`、image `0x1423dc` @ `0x14e`；
   但 mask ROM 对 0x20 字节 record 的 codec 仍未确认，启动 harness 用的是
   显式 `ldr pc` hand-off stand-in，当前树中没有 KaeP 解包工具。
5. UPP_WD2 的 LCD、计时器和键盘寄存器仍需另找板级资料或实际访问轨迹，以上资料不能填补这一空白。
6. `Series60_v20` 提供同代的头文件、符号名和文档，但不提供目标 ROM 的导出表或
   内存布局；不要用 SDK 的 `.lib` 顺序、头文件类布局或模拟器行为替代目标映像证据。
   第 27 轮进一步确认：SDK `euser.lib` 的序号（以及
   `references/symbian-kernelhwsrv/.../7.0-euseru.def` 的通用 7.0 顺序）
   都**不是**目标 ROM 的导出顺序；kernel→ROM 的 `K-3` 规则来自 49 个
   由调用点语义独立确定的锚点，`euser_reloc.py verify` 只把这些锚点和
   `edata[K-3]` 一致性固定下来。`Series60_v20/Epoc32/release/*/euser.lib`
   的 `d2353s_NNNNN.o` 成员名可用于核对符号名，但不要把它当作目标 DLL 的 ordinal。
