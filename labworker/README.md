# Labworker — 原生 macOS 分子克隆、生物图像与蛋白质结构全栈工作台 (AI 开发者与智能体指南)

> **面向 AI 智能体（Claude Code / Cursor / Windsurf / Gemini / Codex）的速读摘要**：
> 本文件是 `Labworker`（原名 `CloneStudio`）项目的全景功能说明书与技术规范。任何 AI 在阅读、修改或扩展本项目前，请先阅读本文件与 `ARCHITECTURE.md`。

## 1. 项目定位与技术栈概览

**Labworker** 是一款运行于 macOS 27+（Apple Silicon 原生优化，全栈基于 macOS 27 SDK 原生 Liquid Glass 液态玻璃交互设计）的干湿实验一体化科研桌面软件，采用 **SwiftUI 声明式响应式界面 + Swift 核心生物计算引擎 + Python 科学计算/SnapGene 桥接 + SQLite 离线基因组库 + MCP 智能体协议** 的混合架构：

- **UI 与交互层 (`Sources/CloneStudio/`)**：原生 SwiftUI + AppKit 混合架构，具备 120Hz 微观双链序列虚拟化画布、OVE 同心多轨质粒环图、三维 Cα 蛋白质与对接盒视窗、16-bit 科学图像画布及 macOS 菜单栏极简托盘速算器。
- **核心算法与服务层 (`Sources/CloneStudioCore/`)**：纯 Swift 实现的同源重组引物设计、SantaLucia & Hicks 2004 最近邻热力学 $T_m$ 解算、对齐 `primer3-py` (`calc_hairpin` / `calc_homodimer` / `calc_dimer`) 的 **引物二级结构热力学 $\Delta G$ 与配对拓扑质检引擎 (`PrimerQualityEngine`，支持自定义 $\text{Mg}^{2+}$ 与 dNTP 浓度校正)**、原生 Applied Biosystems ABIF (`.ab1` / `.abi`) **Sanger 四色毛细管电泳峰图解析与环状质粒比对验证引擎 (`SangerAlignmentEngine`)**、CRISPR/RNAi 靶点评分、16-bit Western Blot 滚球背景扣除、qPCR $2^{-\Delta\Delta C_t}$ 相对定量、微孔板防边缘效应排布、以及对齐 [IBN-Spring/DockFlowLab](https://github.com/IBN-Spring/DockFlowLab) 源码的 **LIGSITE 七方向 P-S-P 口袋探测与共晶配体共识 AutoDock Vina 对接盒推荐引擎**。
- **Python 桥接与 MCP 服务 (`Sources/CloneStudioCore/Resources/` & `python/wbquant/`)**：
  - `snapgene_bridge.py`：无损读写 SnapGene `.dna` 二进制文件特征、引物与重组质粒组装。
  - `export_order.py`：灌装导出擎科（Tsingke）、生工（Sangon）商业引物合成与测序 Excel 订单。
  - `clonestudio_mcp_server.py`：**Labworker MCP Server 20261115**（JSON-RPC 2.0 协议，暴露 23 个全栈实验工具，算法与 Swift 核心引擎 100% 统一并支持实时同步回写 GUI 画布）。
  - `python/wbquant/`：16-bit TIFF 化学发光与明场 Marker 科学图像处理包（支持 CLI 与 PySide6 高级查看器）。
- **自动化回归测试 (`Tests/CloneStudioVerify/main.swift`)**：内置 **50 项端到端自动化验证测试**，覆盖全部核心算法、生物科研全能计算与换算引擎、引物二级结构热力学质检、Sanger `.ab1` 二进制峰图与质粒比对、Swift-Python 跨引擎共享测试向量（`Tests/vectors/*.json`）一致性、真实质粒与 16-bit WB 样本、UI 偏好状态机、多曝光线性检查及跨模块 `AnalysisRun` 质粒溯源；

## 2. AI 协作与工程治理铁律（修改代码前必读）

1. **先给 Plan，一次只做一件事**：每次修改前先读取相关源码并向用户给出清晰的原子化 Plan；确认后每次只聚焦单个明确任务，严禁自由发挥或夹带未请求的改动。
2. **极简与 100% 窗口缩放响应式 UI 规范**：
   - **严禁写死多列网格**：所有多列指标卡、开关矩阵或说明卡片必须使用 `LazyVGrid(columns: [GridItem(.adaptive(minimum: ..., maximum: ...))])`，随窗口宽度平滑折行，严禁使用固定 3 列 `[GridItem(.flexible()), ...]` 造成窄窗文字竖排截断。
   - **严禁在 3D/图像画布上堆叠遮挡浮层**：控制开关与滑块必须放在画布外侧的 `StudioFlowLayout` 流式工具栏中，窗口缩窄时自动换行。
   - **主工作区与表单行自适应**：分栏视图统一使用 `StudioResponsiveSplitLayout` 或 `AdaptiveTwoColumnWorkspace`（宽屏左右分栏、窄屏自动改为上下堆叠）；长表单行使用 `ViewThatFits(in: .horizontal)` 在窄窗下自动切换为上下两行。
   - **次要编辑器默认收起**：大块序列/PDB 文本编辑框与环境滑块默认收起在按需展开的抽屉中，保持首屏极简清爽。
3. **单一职责与文件准入清单 (`ARCHITECTURE.md`)**：
   - 跨视图复用的 UI 组件统一收口在 `Sources/CloneStudio/Views/Components/DesignSystem.swift`。
   - 任何新增或删除源码文件必须同步更新 `ARCHITECTURE.md`。
   - **MCP 服务控制中心仅允许出现在“系统设置 → MCP 服务”页签中**，不得散落在质粒池或其他业务页面。
4. **每次修改后的标准验证与打包闭环**：
   ```bash
   # 0. 校验测试数、MCP 工具数与模块数单一真值来源，并运行 Python 共享测试向量
   bash Scripts/check_doc_counts.sh && /usr/bin/python3 Tests/vectors/run_python_vectors.py

   # 1. 编译并运行全部 50 项自动化验证测试
   swift build --disable-sandbox && swift run --disable-sandbox CloneStudioVerify

   # 2. 更新构建并签名 labworker/Labworker.app（及打包 Labworker-20261115.dmg）
   bash Scripts/build_app.sh
   bash Scripts/package_dmg.sh --skip-build

   # 3. 使用清晰中文提交 Git 记录
   git add <修改文件> && git commit -m "清晰的中文提交说明"
   ```

## 3. 五大侧边栏分组与 19 个功能模块全景说明

侧边栏定义位于 `Sources/CloneStudioCore/ViewModels/AppState.swift` 的 `SidebarSectionKind` 与 `NavItem` 枚举中，支持顶部关键词实时检索、分类折叠以及在 **“系统设置 → 侧边栏定制”** 中按需隐藏任意非常驻模块（`系统设置` 固定常驻不可隐藏）。

### 3.1 分子克隆与质粒 (`SidebarSectionKind.cloning`)

| 模块枚举 (`NavItem`) | 界面名称 | 核心源码文件 | 核心算法与业务功能说明 | 支持快导格式 |
| :--- | :--- | :--- | :--- | :--- |
| `.plasmidPool` | **质粒池** | `Views/Pool/PlasmidPoolView.swift`<br>`Services/PlasmidPoolManager.swift` | 集中管理本地 `.dna` / `.fasta` 质粒库，自动提取载体骨架、抗性标签、CDS 特征与唯一酶切位点；支持构建谱系树追踪与一键送入克隆或蛋白质翻译。 | `.dna`, `.fa`, `.fasta`, `.gb` |
| `.entryClone` | **入门克隆** | `Views/Cloning/EntryCloneView.swift`<br>`Views/Components/HomologousPCRGelView.swift`<br>`Engine/HomologyArmDesigner.swift`<br>`Engine/HomologousPCRGelSimulator.swift` | 针对 pCE2 等线性化入门载体的一步法快速克隆引物设计，自动匹配退火温度 $T_m$ 与 5' 同源序列，并提供同源重组 PCR 凝胶电泳片段模拟（0.8%–2.0% 琼脂糖梯度、Marker 标尺对比与 CSV 导出）。 | `.dna`, `.fa`, `.fasta`, `.seq` |
| `.singleFragment` | **单片段克隆** | `Views/Cloning/SingleFragmentCloneView.swift`<br>`Views/Components/HomologousPCRGelView.swift`<br>`Engine/HomologyArmDesigner.swift`<br>`Engine/HomologousPCRGelSimulator.swift`<br>`Engine/PrimerQualityEngine.swift` | 支持按载体特征、按已有引物对、按限制性内切酶切点、按自定义坐标四维定位线性化位点；基于 18 bp 黄金同源臂与 SantaLucia 最近邻热力学模型设计引物，内置对齐 `primer3-py` 的发夹/自二聚体/异二聚体 $\Delta G$ 质检与配对示意图，支持同源重组 PCR 与载体线性化琼脂糖凝胶电泳模拟，自动校验 3n 阅读框并生成重组 `.dna` 文件。 | `.dna`, `.fa`, `.fasta`, `.seq` |
| `.multiFragment` | **多片段克隆** | `Views/Cloning/MultiFragmentCloneView.swift`<br>`Views/Components/HomologousPCRGelView.swift`<br>`Engine/HomologyArmDesigner.swift`<br>`Engine/HomologousPCRGelSimulator.swift`<br>`Engine/PrimerQualityEngine.swift` | 支持 2–10 个插入片段的 Gibson / In-Fusion 无缝同源拼接，各片段可独立载入供体 `.dna` 截取特征，自动优化相邻重叠区 $T_m$ 并执行 `calc_hairpin` / `calc_homodimer` / `calc_dimer` 二级结构风险评估，支持多片段扩增子与混泳同源重组凝胶电泳分辨模拟。 | `.dna`, `.fa`, `.fasta`, `.seq` |
| `.mutagenesis` | **定点突变** | `Views/Mutagenesis/MutationView.swift`<br>`Engine/HomologyArmDesigner.swift` | 支持在微观序列画布点选密码子或直接输入 `S42A` / `K15R` / `K15Δ` 简写，自动核对野生型氨基酸、选择宿主偏好密码子并生成反向 PCR 或重叠延伸突变引物。 | `.dna`, `.fa`, `.fasta`, `.seq` |
| `.fragmentDeletion` | **片段删除** | `Views/Cloning/FragmentDeletionView.swift`<br>`Views/Components/HomologousPCRGelView.swift`<br>`Engine/HomologyArmDesigner.swift`<br>`Engine/HomologousPCRGelSimulator.swift` | 精准跨区域同源环化敲除或结构域截短，自动设计跨越删除边界的反向 PCR 桥接引物、模拟环化扩增条带对比对照载体电泳并重映射下游质粒图谱特征坐标。 | `.dna`, `.fa`, `.fasta`, `.seq` |
| `.sangerVerify` | **测序验证** | `Views/Cloning/SangerVerificationView.swift`<br>`Engine/SangerAlignmentEngine.swift`<br>`Engine/SangerBatchEngine.swift` | 原生解析 Applied Biosystems ABIF (`.ab1` / `.abi`) 四色毛细管电泳荧光色谱（`DATA` 9–12、`PBAS`、`PLOC`、`PCON`）、滑动窗口修剪 5'/3' 低质量端，并与环状质粒双向带状 DP 比对，自动识别 SNP 点突变、移码 Indel 与杂合双峰（次峰 $\ge 30\%$），支持多文件/文件夹批量克隆分组合并看板、正反向覆盖并集统计与点击变异胶囊一键滚动定位峰图。 | `.ab1`, `.abi`, `.seq`, `.fasta` |

### 3.2 基因编辑与靶点 (`SidebarSectionKind.targeting`)

| 模块枚举 (`NavItem`) | 界面名称 | 核心源码文件 | 核心算法与业务功能说明 | 支持快导格式 |
| :--- | :--- | :--- | :--- | :--- |
| `.sgRNADesign` | **sgRNA 设计** | `Views/CRISPR/SgRNADesignView.swift`<br>`Engine/CRISPRDesigner.swift`<br>`Services/GenomicLibraryService.swift` | 支持从离线 `Libraries.sqlite`（标注参考基因组 `hg38` / `mm39`）高速检索或从给定序列全长扫描 PAM 位点（NGG / TTTV），综合 GC%、二级结构、Poly-T 终止信号与位置权重计算 **序列启发式评分**（`score_type = sequence_heuristic`，明确提示未含全基因组脱靶搜索并提供一键跳转 CHOPCHOP 靶点对比），生成 `lentiCRISPRv2` (BsmBI) 或 `pX459` (BbsI) 退火 Oligo。 | `.fa`, `.fasta`, `.dna` |
| `.shRNADesign` | **shRNA 设计** | `Views/RNAi/ShRNADesignView.swift`<br>`Engine/ShRNADesigner.swift` | 基于 21nt 靶点热力学不对称性（5' 反义链解旋自由能差）与 RISC 装载偏好筛选高活性 RNAi 靶点，自动生成 `pLKO.1` (AgeI / EcoRI) 正义与反义发夹引物。 | `.fa`, `.fasta`, `.dna` |
| `.chopchopCompare` | **靶点对比** | `Views/Compare/CHOPCHOPWebView.swift`<br>`Services/CHOPCHOPService.swift` | 内置 CHOPCHOP 靶点评分对比工作台，将本地已选的 sgRNA / shRNA 候选靶点自动置顶并与脱靶/效率分布交叉比对。 | `.fa`, `.fasta`, `.dna` |

### 3.3 电泳与图像定量 (`SidebarSectionKind.bioImaging`)

| 模块枚举 (`NavItem`) | 界面名称 | 核心源码文件 | 核心算法与业务功能说明 | 支持快导格式 |
| :--- | :--- | :--- | :--- | :--- |
| `.westernBlot` | **WB 灰度定量** | `Views/BenchTools/WesternBlotView.swift`<br>`Engine/WesternBlotEngine.swift`<br>`Models/AnalysisRun.swift`<br>`python/wbquant/` | 深度整合 `WBStudio` 原生 16-bit TIFF 无损解析与 Swift 原生双引擎：支持同批次化学发光图与明场 Marker 自动配对、Active Strip 膜条定位、一维 Rolling-ball 滚球背景扣除、高斯加权四边收紧框、可拖拽微调泳道框、内参（GAPDH/ACTB）归一化、过曝像素红色遮罩与自动剔除、双组 Welch's t 检验及带 `AnalysisRun`（`<basename>.run.json` + SHA256 指纹）的 CSV/离线 HTML 报告导出。 | `.tif`, `.tiff` (16-bit), `.png`, `.jpg` |
| `.gelFigure` | **凝胶分子量** | `Views/BenchTools/GelFigureEditorView.swift`<br>`Engine/GelAnalysisEngine.swift`<br>`Models/AnalysisRun.swift` | 琼脂糖/SDS-PAGE 电泳胶图泳道自动寻峰与 $\log_{10}(\text{MW}) = a \cdot y + b$ 最小二乘标准曲线拟合，支持未知条带分子量插值测算、质粒双酶切虚拟电泳对照叠加及 `AnalysisRun` v2 (`.run.json` + 质粒关联索引) 溯源导出。 | `.tif`, `.tiff`, `.png`, `.jpg` |

### 3.4 定量与蛋白工具 (`SidebarSectionKind.benchTools`)

| 模块枚举 (`NavItem`) | 界面名称 | 核心源码文件 | 核心算法与业务功能说明 | 支持快导格式 |
| :--- | :--- | :--- | :--- | :--- |
| `.plateDesigner` | **微孔板设计** | `Views/BenchTools/PlateDesignerView.swift`<br>`Engine/PlateLayoutEngine.swift` | 支持 6 / 12 / 24 / 48 / 96 / 384 孔板可视化涂刷分配、防边缘蒸发效应自动避开最外圈孔（Outer-edge Avoidance）、Mulberry32 确定性随机盲法排布、正交相邻冲突检测及 CSV / qPCR 模板双向联动。 | `.csv`, `.tsv` |
| `.qpcrAnalysis` | **qPCR 定量** | `Views/BenchTools/QPCRAnalysisView.swift`<br>`Engine/QPCRAnalysisEngine.swift` | 支持 $2^{-\Delta\Delta C_t}$ 相对表达量解算、多内参几何平均归一化、扩增效率标准曲线回归（$E = 10^{-1/\text{slope}} - 1$）、**NTC / no-RT 阴性对照污染告警与熔解曲线 $T_m$ 偏离自动排除**、样品级 Welch's t 检验、**Holm–Bonferroni 多组比较校正** 与 $\Delta\Delta C_t$ / Fold Change **95% 置信区间**（支持 SD / SEM / 95% CI 误差线切换）。 | `.csv`, `.tsv` |
| `.proteinWorkbench` | **蛋白质工作台** | `Views/BenchTools/ProteinWorkbenchView.swift`<br>`Engine/ProteinBiophysicsEngine.swift` | **极简声明式窗口响应式工作台**：<br>1. **理化与 SPICE 五维指标**：分子量、二分法等电点 pI、消光系数 $\varepsilon_{280}$、GRAVY 疏水剖面、不稳定指数 II 与 M1–M5 折叠质量评分。<br>2. **对齐 `DockFlowLab` 源码的口袋与对接盒引擎**：严格实现 `first_model=True`（`ENDMDL` 截断）、非氢重原子过滤、七方向 `LIGSITE P-S-P` 空腔扫描，以及 `CONSENSUS_COVERAGE = 0.35`（共晶配体）与 `SITE_CONSENSUS_COVERAGE = 0.50`（PDB `SITE` 记录）的 **共识融合盒（Consensus Box）**、`_sanitize_box` `18–60 Å` 尺寸钳制、体积告警（`<1,500` 或 `>40,000 Å³`）与近端可旋转柔性侧链（`--flex`）推荐，一键复制 `vina_config.txt`。<br>3. **点突变 $\Delta\Delta G$ 快速初筛 (`empirical_heuristic`)**：基于 Kyte-Doolittle 疏水性差异、残基质量位阻与脯氨酸罚分的经验启发式模型进行单点/组合突变初筛，并显式标注 `model_type="empirical_heuristic"`（不等同于 FoldX / Rosetta 全原子能量计算）。 | `.pdb`, `.cif`, `.ent`, `.fasta` |
| `.dnaCalculator` | **生物计算器** | `Views/Calculator/RestructureCalculatorView.swift`<br>`Views/Calculator/LabBioCalculatorsView.swift`<br>`Engine/DNAMolarCalculator.swift`<br>`Engine/LabBioCalculatorsEngine.swift` | 四合一全能科研计算工作台：① 克隆与经典摩尔比 (0.03 pmol, `1:1–1:5`) 20 μL 配液与单/多片段一键同步；② dsDNA (`µg⇄pmol`)、ssDNA (`µg/mL⇄pmol/µL`)、Linear DNA 末端摩尔及 $\text{OD}_{260}$ 核酸定量；③ 蛋白质摩尔转换 (`kDa⇄µg⇄pmol`) 与 DNA 编码容量三向互算；④ 溶液摩尔配制、$C_1V_1=C_2V_2$ 稀释计算与 °F/°C/K 温标换算。 | 内置交互面板 |
| `.sequenceTools` | **序列工具** | `Views/Tools/SequenceToolsView.swift`<br>`Engine/TmCalculator.swift`<br>`Engine/PrimerQualityEngine.swift` | DNA/RNA 序列格式化清洗、反向互补、三阅读框密码子翻译、GC% 分布、SantaLucia 最近邻热力学 $T_m$ 速算及 `primer3` 发夹/自二聚体 $\Delta G$ 与配对拓扑评估。 | `.fa`, `.fasta`, `.seq`, 纯文本 |

### 3.5 合成订购与设置 (`SidebarSectionKind.orderAndSettings`)

| 模块枚举 (`NavItem`) | 界面名称 | 核心源码文件 | 核心算法与业务功能说明 |
| :--- | :--- | :--- | :--- |
| `.orderCenter` | **订购中心** | `Views/Order/OrderExportView.swift`<br>`Services/ExcelOrderExporter.swift` | 汇总各模块加入订购池的引物与测序样品，支持成对重命名、批量写回 `.dna` 质粒文件，并一键导出符合擎科（Tsingke）、生工（Sangon）官方模板格式的 `.xlsx` 订购表。 |
| `.settings` | **系统设置** | `Views/Settings/SettingsView.swift`<br>`ViewModels/AppState.swift` | **四段式极简响应式设置中心**：<br>① **参数与外观**：浅色/深色/跟随系统主题、画布底色、强调色、状态栏图标开关，以及分子克隆、WB/微孔板/qPCR、蛋白质工作台与订购人档案默认参数。<br>② **侧边栏定制**：提供 3 个一键预设（显示全部 / 仅分子克隆与基因编辑 / 仅图像定量与蛋白工具）及 5 大分类自适应开关矩阵。<br>③ **MCP 服务**：集中管理 `labworker-mcp` 20261115，支持一键注入 Claude Desktop / Cursor / Windsurf、复制标准 JSON、查看跨进程同步记录与 23 项工具清单。<br>④ **全局说明书**：支持按名称/算法/文件格式实时检索全部 19 个模块的功能定位、支持格式与实操提示，并提供 `直达功能` 与 `恢复显示` 按钮。 |

## 4. Finder 多格式智能快导与状态栏极简工作台

1. **Finder 拖拽与“快导”智能路由 (`ContentView.swift` & `FinderFileDropHelper`)**：
   - 点击侧边栏顶部的 `快导` 按钮或直接将文件拖入主窗口，系统会根据扩展名自动路由并载入对应工作台：
     - `.ab1` / `.abi` → 自动切换至 **测序验证** 并解析四色荧光毛细管电泳峰图与参考质粒比对；
     - `.dna` → 导入质粒池并同步至当前分子克隆模块；
     - `.tif` / `.tiff` / `.png` / `.jpg` → 自动切换至 **WB 灰度定量**（或当前所处的凝胶图像模块）并载入图像；
     - `.pdb` / `.cif` / `.ent` → 自动切换至 **蛋白质工作台** 并解析三维结构、LIGSITE 口袋与 Vina 对接盒；
     - `.csv` / `.tsv` → 自动切换至 **qPCR 定量** 或 **微孔板设计**；
     - `.fa` / `.fasta` / `.seq` → 自动识别核酸或氨基酸序列并路由至对应模块。
2. **macOS 右上角状态栏极简托盘 (`CloneStudioStatusBarPopoverView`)**：
   - 定义于 `Sources/CloneStudioCore/Models/CloneStudioIconProvider.swift`。
   - 摒弃与设置面板重复的繁琐配置项，专注提供 **“序列随手算（实时显示 bp 长度、GC%、SantaLucia $T_m$ 及一键反向互补）”** 与 **“8 宫格高频工作台直达按钮”**。

## 5. Labworker MCP Server 20261115 协议与 23 大工具清单

MCP 服务端脚本位于 `Sources/CloneStudioCore/Resources/clonestudio_mcp_server.py`（服务标识 `labworker-mcp` 20261115），遵循标准 JSON-RPC 2.0 (stdio) 协议，无需任何第三方 Python 依赖（纯标准库实现）。

### 5.1 标准客户端配置 (`mcpServers.labworker`)
可在 **“系统设置 → MCP 服务”** 中点击 **“一键注入 Claude / Cursor / Windsurf”** 自动写入，或手动配置：
```json
{
  "mcpServers": {
    "labworker": {
      "command": "/usr/bin/python3",
      "args": [
        "/path/to/labworker/Sources/CloneStudioCore/Resources/clonestudio_mcp_server.py"
      ]
    }
  }
}
```

### 5.2 已注册的 23 个 MCP 工具 (`MCP_TOOLS`) 与两阶段写盘确认 (`confirm`)
所有只读查询与分析工具均标注 `annotations.readOnlyHint = true`；涉及磁盘写入或修改质粒池的工具（`add_plasmid_to_pool`、`design_single_clone_primers(export_recombinant_dna=true)`、`manage_primer_cart_and_export(action=export_tsingke_excel)`）统一标注 `destructiveHint = true` 且默认 `confirm = false`：调用时先返回 `{"status": "preview", "planned_writes": [...]}` 预览而不触碰磁盘，经用户确认后再以 `confirm = true` 执行落盘（若目标文件已存在，自动备份为 `*.bak-<timestamp>`）。

1. `list_plasmid_pool`：按载体骨架、目的基因、抗性与分类多维检索本地质粒池。
2. `inspect_plasmid`：深度查看指定质粒的全部特征坐标、唯一酶切位点与完整序列。
3. `add_plasmid_to_pool`：将本地 `.dna` 文件解析并导入质粒池（支持 `confirm` dry-run 预览）。
4. `design_single_clone_primers`：单片段无缝克隆引物设计、3n 阅读框校验与可选重组 `.dna` 导出（`export_recombinant_dna` 默认 `false`，开启时支持 `confirm` dry-run 预览）。
5. `design_multi_fragment_primers`：2–10 片段同源组装拼接引物设计。
6. `design_mutagenesis_primers`：氨基酸定点突变（如 `S42A`、`K15R`）引物设计与野生型核对。
7. `design_fragment_deletion_primers`：质粒片段敲除/截短反向 PCR 桥接引物设计。
8. `verify_sanger_sequencing`：原生解析 Sanger 测序 (`.ab1` / `.abi` / `.seq`) 四色峰图并与参考质粒执行环状双向比对，检出 SNP、Indel 与杂合双峰。
9. `calculate_recombination_dosage`：计算 20 μL 同源重组体系或经典 0.03 pmol 摩尔比 (`1:1–1:5`) 载体与片段的最佳 ng 与移液体积。
10. `convert_nucleic_acid_units`：dsDNA (`µg⇄pmol`)、ssDNA (`µg/mL⇄pmol/µL`)、Linear DNA 末端摩尔及 $\text{OD}_{260}$ 核酸定量换算。
11. `convert_protein_and_coding`：蛋白质大小/质量/摩尔数 (`kDa⇄µg⇄pmol`) 三角互算及 DNA 编码容量 (`bp⇄aa⇄kDa`) 联动推算。
12. `calculate_solution_and_temperature`：溶液摩尔浓度配制质量 (`g/mg/µg`)、$C_1V_1=C_2V_2$ 稀释度移液体积与 °F/°C/K 温度转换。
13. `design_sgrna_primers`：CRISPR/Cas9 NGG 靶点扫描评分与 `lentiCRISPRv2` / `pX459` 退火引物生成。
14. `design_shrna_primers`：21nt RNAi 靶点筛选与 `pLKO.1` 发夹引物生成。
15. `manage_primer_cart_and_export`：查看引物订购池或一键导出《擎科引物合成订购表.xlsx》。
16. `analyze_protein_and_docking_box`：分析蛋白序列或 `.pdb` 文件，返回分子量、理论 pI、GRAVY、LIGSITE 口袋、AutoDock Vina 对接盒配置（`vina_config`）与点突变 $\Delta\Delta G$。
17. `analyze_western_blot`：对目的蛋白与内参条带 IOD 执行归一化、均值/SD 汇总与显著性分析。
18. `analyze_qpcr_ddct`：计算 qPCR $2^{-\Delta\Delta C_t}$ 相对表达量并标记高 SD 异常复孔。
19. `design_plate_layout`：生成 96 / 384 孔板防边缘效应自动排布方案。
20. `deconvolute_crispr_sanger`：Sanger 编辑池四通道峰图 NNLS 解卷积定量（`-20..+20 bp` 移码分布、Indel%、KO Score、HDR% 与 $R^2$）。
21. `auto_annotate_sequence`：基于 `Libraries.sqlite` 的纯离线未知质粒 FASTA 自动注释，支持正反双链、跨零点匹配与 30%–90% 残留片段（Fragment）标记。
22. `design_golden_gate_assembly`：Type IIS (`BsaI` / `BsmBI` / `BbsI` / `SapI`) 2–6 片段零交叉错配接头规划与编码区同义位点抹除 (Domestication)。
23. `design_hdr_donor`：CRISPR Knock-in HDR 同源供体（`ssODN` / `dsDNAPlasmid`）、PAM/Seed 同义阻断突变、可选同义 RFLP 位点与 Out-Out PCR 引物设计。

### 5.3 跨进程 GUI 实时同步机制
当外部 AI 通过 MCP 调用上述工具时，`clonestudio_mcp_server.py` 会为每次运行生成唯一 `run_id`，将包含 `schema_version: 1`、`run_id`、`tool_name` 与 `target_module` 的结构化结果通过临时文件 `os.replace` 原子写入 `~/Library/Application Support/CloneStudio/mcp_sync/<run_id>.json`（同时原子更新兼容文件 `latest.json`），并以非阻塞方式广播 macOS `DistributedNotificationCenter` 通知（`com.clonestudio.mcp.updated`）。正在运行的 `Labworker.app`（或在下次启动时）会按时间顺序扫描 `mcp_sync/`、基于 `processed_runs.json` 幂等去重消费、自动归档至 `mcp_sync/done/`（自动清理超过 7 天的旧归档）并刷新对应工作台画布。
