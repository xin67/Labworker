# Labworker 原生生物实验工作台架构与核心文件清单 (labworker/ARCHITECTURE.md)

> **工程治理与 Vibe Coding 五大铁律**：
> 1. **一次只做一件事**：每次修改只聚焦单个原子功能，严禁自由发挥或生成调试垃圾。
> 2. **文件准入清单化（本文件为唯一权威清单）**：全量重构工程统一收口于 `labworker/` 目录下；任何新增源码、脚本或资源文件必须先登记在本清单中；若某个文件不在清单内且无法说明存在理由，一律视为可疑冗余文件并删除。
> 3. **单一职责与反重复**：跨模块复用的 UI 控件、Finder 交互与预设常量统一收口至 `DesignSystem.swift`，几何解算与确定性 ID 收口至 `Geometry/`，严禁在各业务 View 内复制粘贴同类辅助函数。
> 4. **立刻 Git Commit + 更新打包（说人话）**：每完成一个原子步骤并通过编译校验后，立即在 `labworker/` 下更新打包 `labworker/Labworker.app` 并使用清晰人话执行 `git commit`。
> 5. **定期执行删除测试**：每完成一个阶段，对照本清单清理冗余代码与无用文件，运行 `swift build --disable-sandbox` 与 `swift run --disable-sandbox CloneStudioVerify` 确认回归通过。

## 一、 顶层配置、构建脚本与真实测试样本 (`labworker/`)

| 文件路径 | 核心用途说明 |
| :--- | :--- |
| `../.github/workflows/ci.yml` | GitHub Actions `macos-14` 自动化 CI 门禁：在每次 `push`/`pull_request` 执行 Python 跨语言测试向量、防篡改校验及 `check_doc_counts.sh` 全量回归 |
| `labworker/README.md` | 面向其他 AI 智能体（Claude / Cursor / Windsurf / Gemini / Codex）与开发者的项目全景功能说明书、22 模块算法速查、UI 响应式规范与 MCP v3.0 协议指南 |
| `labworker/HANDOVER.md` | AI 项目架构交接与维护规范手册：包含目录拓扑、Single Source of Truth 门禁契约、双端 (Swift + Python MCP) 同步机制、跨语言测试向量与编码红线 |
| `labworker/Package.swift` | SwiftPM 工程定义（Swift 6.4 / 最低支持 `macOS 27.0`），包含 `CloneStudio`（macOS 桌面端）、`CloneStudioCore`（核心算法与业务服务库）、`CloneStudioVerify`（命令行回归自检靶点）三个 Target |
| `labworker/ARCHITECTURE.md` | 项目全量核心文件职责权威清单与工程维护规范 |
| `labworker/Labworker.app` | 每次原子步骤完成后由 `labworker/Scripts/build_app.sh` 自动构建并签名的最新可执行 macOS 应用包 |
| `labworker/Scripts/build_app.sh` | Release 编译、组装 `labworker/Labworker.app` 应用包、写入 `Info.plist`（`LSMinimumSystemVersion = 27.0`）并执行 Apple Ad-hoc 签名校验 |
| `labworker/Scripts/check_doc_counts.sh` | 自动提取 `CloneStudioVerify` 测试数、`MCP_TOOLS` 工具数与 `NavItem` 模块数真值，校验证书/文档数字一致性，并自动核验 `Sources/`、`Scripts/`、`python/`、`Tests/` 下全量文件均已在 `ARCHITECTURE.md` 登记 |
| `labworker/Scripts/generate_icon.py` | 遵循 Apple HIG 生成浅色/深色应用图标（`.icns`/`.png`）与 macOS 状态栏模板图标 |
| `labworker/Scripts/build_libraries_db.py` | 将原始全基因组靶点数据离线编译为 `Libraries.sqlite` 数据库的构建脚本 |
| `labworker/Samples/WB/gapdh_*.tif` | 迁移自 `WBStudio` 的真实 16-bit 原始化学发光图、常规发光图、明场 Marker 图与合成叠加图样本 |
| `labworker/python/wbquant/` | 迁移自 `WBStudio` 的 Python 科学计算与 `PySide6 + pyqtgraph` 协同分析包（`__init__.py`、`models.py`、`io.py`、`preprocess.py`、`detect.py`、`quantify.py`、`pipeline.py`、`qt_viewer.py`、`cli.py`） |

## 二、 视图表现层 (`labworker/Sources/CloneStudio/`)

| 文件路径 | 核心用途说明 |
| :--- | :--- |
| `CloneStudioApp.swift` | 应用入口、菜单栏命令快捷键、macOS 系统深浅色 / 强调色 / 辅助透明 / Liquid Glass 强度广播与激活刷新监听、状态栏 `NSStatusItem` 快捷工作台及退出进度保存提示 |
| `Views/Main/ContentView.swift` | 主窗口容器：透明窗口底色 + 原生 `NSVisualEffectView(.sidebar, .behindWindow)` 磨砂侧边栏、单一像素级 `.separatorColor` 可拖拽调宽（双击重置）分栏线、顶部 macOS 27 Liquid Glass 折射搜索框（无默认自动聚焦闪烁）+ SDK 圆形导入按钮、全局拖拽导入遮罩与 Liquid Glass HDR Toast 通知 |
| `Views/Components/DesignSystem.swift` | 全局 macOS 27 Liquid Glass + HDR 设计系统与复用组件库：`StudioPalette`（系统语义 `NSColor` 黑白/浅灰背景与分割线）、全局标准 macOS 系统字体与 `.monospacedDigit()` 等宽数字规范（仅序列/比对网格/ASCII 二级结构/raw FASTA 编辑器/JSON 保留等宽）、`StudioGlassSupport`、`StudioManualGlassButtonStyle`、`studioGlassButton` / `studioGlassMenu`（`StudioNativeOrManualGlassMenuModifier` 统一走 `.menuStyle(.button)` + `.glassEffect` 修复 macOS 27 `Menu` 忽略 `.buttonStyle(.glass)` 退化为实心灰底的问题）/ `studioJoinedGlassCapsule` / `studioOptionalForeground`（常规按钮直用原生 `.buttonStyle(.glass / .glassProminent)` 且非高亮按钮保持中性通透玻璃杜绝同色淹没）、`StudioNoAutoFocusSearchField`、`StudioPageLayout`（`.scrollEdgeEffectStyle(.soft)` + `.safeAreaBar` 渐隐顶栏）、`StudioOverflowToolbar`（含 `»` 溢出玻璃菜单）& `StudioGlassSegmentedBar`（统一由 `GlassEffectContainer` + `.glassEffect` 驱动，替代内容区退化为扁平灰的 `ControlGroup` 与 `.pickerStyle(.segmented)`）、`StudioCard`、`StudioSegmentedPicker`、`StudioSegmentedPillGroup`、`StudioActionPillButton`、`StudioCompactPillButton`、`StudioMenuPillButton`、`StudioPrimaryActionButton`、`StudioSectionClearButton`、`FinderRevealButton`、`SpeciesSwitchBar`、`StudioMetricBadge`、`SequenceEditorBox`、`StudioFlowLayout`、`StudioResponsiveSplitLayout`、`AdaptiveTwoColumnWorkspace`、`PlasmidPreviewToggle`、`PlasmidFileToolbarGroup`、`StudioRadius`（三层连续圆角规范）、`StandardLinkerPreset`、`FinderFileDropHelper` |
| `Views/Components/PlasmidPreviewCanvas.swift` | 质粒全景图谱引擎：对齐系统语义深浅色底与 `StudioGlassSegmentedBar` 液态玻璃分段切换的 `PlasmidPreviewPanel` 同屏双视工作台（无冗余折叠/关闭按钮）、OVE 同心多轨环形质粒图（工具按钮适配 `.colorScheme` 与高亮白显对比度）、`PlasmidMapBuilder` 图谱构建器与沉浸式透明标题栏（`.fullSizeContentView`）独立预览窗口控制器 `PlasmidWindowPresenter` |
| `Views/Components/SequenceRowCanvasView.swift` | 微观单碱基双链序列画布：对齐系统语义浅白/深灰炭底（同步 `.colorScheme`）与 `GlassEffectContainer` 液态玻璃视口/功能按钮的 `LazyVStack` 视口虚拟化画布、静态序列层与选区浮层分离、互补链、氨基酸密码子带、内切酶裂解切口与 120Hz 拖拽选区 |
| `Views/Components/SequenceMinimapView.swift` | 全长序列缩略图导航条与视口快速定位滑块 |
| `Views/Components/RestrictionEnzymeInspectorView.swift` | 限制性内切酶切点汇总与点击跳转浮层面板（系统语义深色浮层 + SDK `.studioGlassButton` / `.studioGlassMenu` 预设与搜索操作栏） |
| `Views/Components/SequenceHighlightText.swift` | 引物 5' 同源臂 / 3' 特异结合区分色高亮文本、`PrimerCardView` 引物卡片（含二级结构风险等级徽章、$\text{Mg}^{2+}$/dNTP 即时调节滑块与可展开碱基配对示意图）、`PrimerPairDimerSummaryBar` 对间异二聚体摘要条与 `PrimerPairQuickRenameBar` 成对重命名栏 |
| `Views/Components/HistoryTreeView.swift` | 质粒构建谱系树与上下游特征坐标偏移对比视图 |
| `Views/Components/TargetScoreBadge.swift` | CRISPR sgRNA / RNAi shRNA 靶点评分胶囊徽章 |
| `Views/Cloning/EntryCloneView.swift` | pCE2 入门克隆引物设计视图 |
| `Views/Cloning/SingleFragmentCloneView.swift` | 单片段同源重组引物设计视图（支持按载体特征、按已有引物对、按真实酶切位点、按自定义坐标四维定位） |
| `Views/Cloning/MultiFragmentCloneView.swift` | 多片段无缝拼接组装引物设计视图（支持各片段独立载入供体 `.dna` 截取特征与 3n 阅读框联动核验） |
| `Views/Cloning/FragmentDeletionView.swift` | 质粒大片段删除与敲除引物设计视图 |
| `Views/Cloning/SangerVerificationView.swift` | Sanger 测序 (`.ab1` / `.abi` / `.seq`) 四色荧光峰图可视化、变异胶囊定位跳转与环状质粒双向比对验证视图 |
| `Views/Mutagenesis/MutationView.swift` | 定点突变引物设计与交互式密码子/氨基酸点选突变视图 |
| `Views/Pool/PlasmidPoolView.swift` | 本地质粒池纯粹管理视图（支持拖入 `.dna` 批量建库、特征/酶切位点检视与构建谱系树） |
| `Views/CRISPR/SgRNADesignView.swift` | CRISPR sgRNA 离线文库检索与引物设计视图 |
| `Views/RNAi/ShRNADesignView.swift` | shRNA 发夹结构离线文库检索与引物设计视图 |
| `Views/Compare/CHOPCHOPWebView.swift` | CHOPCHOP 在线靶点检索与本地已选靶点置顶对比视图 |
| `Views/Calculator/RestructureCalculatorView.swift` | 重组反应体系载体/片段 DNA 质量与摩尔数计算器视图 |
| `Views/Tools/SequenceToolsView.swift` | 序列反向互补、GC 含量与 SantaLucia 近邻热力学 Tm 计算工具视图 |
| `Views/BenchTools/PlateDesignerView.swift` | 微孔板（6～384 孔）可视化点选涂刷、随机种子排布与 CSV/qPCR 导出视图 |
| `Views/BenchTools/QPCRAnalysisView.swift` | qPCR $\Delta\Delta C_t$ 相对定量、标准曲线拟合、反应孔 QC 质控与 `Swift Charts` 显著性柱状图/热图视图 |
| `Views/BenchTools/PhylogeneticTreeView.swift` | 系统发育树（直角/等距/环形布局）矢量交互画布、演化支折叠旋转与 Robinson-Foulds 双树拓扑比对视图 |
| `Views/BenchTools/ColonyCounterView.swift` | 菌落计数器与蓝白斑筛选视图（900 px 高清采样、分水岭粘连拆分开关、`minArea=4` 微小菌落支持、X-gal 色相分类、点选修正与 Garwood 95% 泊松区间 CFU 换算） |
| `Views/BenchTools/WesternBlotView.swift` | Western Blot 16-bit 自动圈定、明场 Marker 混叠、Rolling-ball 背景扣除、可拖拽条带框、1D 峰剖面与内参归一化统计视图 |
| `Views/BenchTools/GelFigureEditorView.swift` | 凝胶电泳分子量回归拟合、Marker 标准品标尺与质粒双酶切虚拟电泳对照叠加视图 |
| `Views/BenchTools/FigureAnnotatorView.swift` | 科研多图拼版、RGB 多通道荧光伪彩合成、微米比例尺与共定位像素强度剖面图视图 |
| `Views/BenchTools/ProteinWorkbenchView.swift` | 极简声明式窗口响应式蛋白质工作台：三维 Cα 骨架与 Vina 对接盒视窗、SPICE 五维指标、对齐 `DockFlowLab` 的 LIGSITE 共识融合盒与经验启发式 (`empirical_heuristic`) 突变 ΔΔG 扫描视图 |
| `Views/Order/OrderExportView.swift` | 商业引物合成与测序订单（擎科/生工等）一键导出中心及引物批量写入 `.dna` 工具 |
| `Views/Settings/SettingsView.swift` | 四段式系统设置中心：① 参数与外观（仿 macOS 27 系统设置 Liquid Glass 实时预览与强度滑块、多色/系统主题色阵与跟随系统设置按钮、HDR 动态高光及双引擎协同调度模式）② 侧边栏定制 ③ MCP 智能体服务 (17 工具) ④ 22 模块全局功能说明书 |

## 三、 核心算法与业务服务层 (`labworker/Sources/CloneStudioCore/`)

### 3.1 状态与视图模型 (`ViewModels/`)
- `ViewModels/AppState.swift`：全局响应式状态、侧边栏分组折叠/宽度持久化/搜索路由、macOS 全局 `NSGlassTintAmount` / `controlAccentColor` 跟随系统同步与 `UserDefaults` 偏好设置持久化中心。
- `ViewModels/CloningViewModels.swift`：入门克隆 (`EntryCloneViewModel`)、质粒特征分类器 (`PlasmidFeatureFilter`) 与单片段同源重组 (`SingleFragmentViewModel`) 核心状态机。
- `ViewModels/MultiFragmentViewModel.swift`：多片段无缝组装 (`MultiFragmentViewModel`，2–10 片段动态增减、供体特征截取与总阅读框核验) 状态机。
- `ViewModels/MutagenesisViewModel.swift`：定点突变 (`MutagenesisViewModel` 与 `MutagenesisResidueItem`，密码子/氨基酸交互点选与突变质粒导出) 状态机。
- `ViewModels/FragmentDeletionViewModel.swift`：质粒大片段删除/敲除 (`FragmentDeletionViewModel`，四模式删除边界定位与谱系记录) 状态机。
- `ViewModels/BenchCalculatorViewModels.swift`：重组体系 DNA 摩尔用量计算 (`CalculatorViewModel`) 与序列/SantaLucia $T_m$ 工具 (`SequenceToolViewModel`) 状态机。
- `ViewModels/SgRNADesignViewModel.swift` & `ShRNADesignViewModel.swift`：CRISPR sgRNA 与 RNAi shRNA 检索及引物生成 ViewModel。
- `ViewModels/CHOPCHOPCompareViewModel.swift`：CHOPCHOP 在线查询与本地靶点匹配比对 ViewModel。
- `ViewModels/OrderExportViewModel.swift`：商业合成与测序订购单导出 ViewModel。

### 3.2 纯数学几何与排版引擎 (`Geometry/`)
- `Geometry/SequenceRowLayout.swift`：标准遗传密码翻译器 `CodonTranslator`、确定性视图标识 `DeterministicUUID`、微观序列焦点窗口 `MicroscopicSequenceWindow` 与行内防碰撞排版解算器 `SequenceRowLayout`。
- `Geometry/CircularOVELayout.swift`：环形极角映射与 OVE 同心圆多轨防重叠解算器。
- `Geometry/CircularGeometry.swift`：极坐标/笛卡尔坐标转换与 SnapGene/OVE 双栏外圈标签垂直松弛防碰撞算法。

### 3.3 算法引擎 (`Engine/`)
- `Engine/HomologyArmDesigner.swift`：同源重组、多片段拼接、定点突变与大片段敲除引物设计核心引擎。
- `Engine/TmCalculator.swift`：SantaLucia 1998 近邻热力学模型解链温度（Tm）与 GC 含量计算器。
- `Engine/PrimerQualityEngine.swift`：参考 `primer3-py` 的寡核苷酸二级结构（发夹 `calcHairpin`、自二聚体 `calcHomodimer`、异二聚体 `calcDimer`）热力学 $\Delta G$ / $T_m$ 解算、$\text{Mg}^{2+}$/dNTP 二价盐校正、风险分级与 ASCII 碱基配对示意图渲染引擎。
- `Engine/SangerAlignmentEngine.swift`：原生 Applied Biosystems ABIF (`.ab1` / `.abi`) 四色荧光毛细管电泳峰图解析、Phred 质量窗口修剪、杂合双峰检测与环状质粒双向带状 DP 比对验证引擎。
- `Engine/SangerBatchEngine.swift`：Sanger 批量测序验证与克隆分组合并看板引擎（三级参考质粒自动匹配、正则引物后缀剥离、正反向双端环状覆盖并集计算、并发限流 `withTaskGroup` 与 `batch_summary.csv` + `.run.json` 溯源导出）。
- `Engine/DualEngineCoordinator.swift`：本地离线引擎与在线 API 双引擎智能协同调度器。
- `Engine/CRISPRDesigner.swift` & `SgRNAScoringEngine.swift`：sgRNA 引物构建与靶点评分引擎。
- `Engine/ShRNADesigner.swift` & `ShRNAScoringEngine.swift`：shRNA 发夹引物构建与靶点评分引擎。
- `Engine/DNAMolarCalculator.swift`：重组体系 DNA 最适投入量（ng / pmol）计算引擎。
- `Engine/PlateLayoutEngine.swift`：微孔板确定性随机排布（Mulberry32）、正交连通冲突核验、CSV/TSV 样品解析导出及全局微孔板共享状态中心 `PlateLayoutStore`。
- `Engine/QPCRAnalysisEngine.swift`：qPCR $\Delta\Delta C_t$ 相对定量、多内参几何平均、标准曲线最小二乘回归、反应孔 QC 质控与 Welch's t-test 显著性检验引擎。
- `Engine/PhylogeneticTreeEngine.swift`：系统发育树 Newick 递归解析与序列化、中点定根/阶梯化排序、直角/等距/环形三种几何布局解算及双树 Robinson-Foulds 拓扑距离对比引擎。
- `Engine/BioImageProcessor.swift`：生物图像底层处理引擎（RGBA/灰度平面提取、高斯滤波、Otsu 大津法分割、积分图自适应局部均值二值化、形态学开闭运算、Felzenszwalb 精确欧氏距离变换 EDT、拓扑持久性选峰与色彩边界感知 Meyer 分水岭粘连拆分、Marching Squares 亚像素周长圆度评估、HSV 色相统计、一维灰度投影峰值检测及高仿真实验示范图生成器）。
- `Engine/ColonyCounterEngine.swift`：皿内琼脂局部背景平场估计与双滞后阈值菌落分割（微小与模糊低对比度菌落保留 + 分水岭粘连拆分）、X-gal 蓝白斑 HSV 色相判别、Garwood 精确泊松 95% 置信区间、CFU/mL 滴度计算及 `AnalysisRun` v2 (`.run.json`) 溯源导出引擎。
- `Engine/WesternBlotEngine.swift`：融合 `WBStudio` 的 16-bit 无损读取、显影增强、同批次曝光配对、有效膜条定位（Active Strip ROI）、Rolling-ball 背景扣除、高斯加权剖面四边收紧框、内参归一化与分组 Welch's t 检验双引擎。
- `Engine/GelAnalysisEngine.swift`：凝胶电泳泳道/条带寻峰、Marker 对数分子量回归拟合（$\log_{10}(\text{size}) = a\cdot y + b$）、质粒酶切虚拟电泳对照生成及 `AnalysisRun` v2 (`.run.json` + 质粒关联索引) 溯源导出引擎。
- `Engine/FigureAnnotatorEngine.swift`：科研多图拼版 RGB 荧光通道伪彩增益合成、线段像素强度剖面采样（Line Intensity Profile）与共聚焦四通道示范生成引擎。
- `Engine/ProteinBiophysicsEngine.swift`：蛋白质理化性质（分子量、等电点 pI、消光系数、GRAVY 疏水剖面）、PDB 三维结构解析、Ramachandran 二面角、Cα 接触图、结合口袋探测与明确标注 `empirical_heuristic` 的点突变 ΔΔG 经验初筛引擎。

### 3.4 领域模型 (`Models/`)
- `Models/BioSequence.swift`：DNA 序列清洗、互补链、反向互补与 GC% 基础工具。
- `Models/PrimerItem.swift`：引物数据结构（区分 5' 同源臂/接头与 3' 特异退火序列）及成对命名提取器。
- `Models/RestrictionEnzyme.swift`：限制性内切酶数据库、切点扫描器与 NEB/常用酶预设组。
- `Models/ConstructHistory.swift`：质粒构建谱系树节点与特征偏移模型。
- `Models/CloneStudioIconProvider.swift`：动态深浅色应用图标渲染器与右上角状态栏弹窗视图 `CloneStudioStatusBarPopoverView`。
- `Models/GenomicTarget.swift`、`TargetScore.swift`、`CHOPCHOPResult.swift`、`OrderFormProfile.swift`：靶点、评分与订购人档案数据模型。
- `Models/PlateLayoutModels.swift`：6～384 孔板几何规格、孔位分配模型、排布规则与科研分组调色板定义。
- `Models/AnalysisRun.swift`：科学分析可复现溯源记录模型（`schemaVersion = 2`、`AnyCodableValue`、CryptoKit `SHA256` 文件指纹、`ManualEdit` 手动编辑记录、`Exclusion` 剔除记录、`linkedPlasmidIDs` 关联质粒 ID 列表与 `.run.json` 伴随文件写入器 + `AnalysisRunIndexStore` 跨模块索引）。

### 3.5 基础服务 (`Services/`)
- `Services/WorkspaceSessionManager.swift`：全模块工作区进度自动保存、异常退出看门狗保护恢复与 Finder 打开文件路由。
- `Services/PlasmidPoolManager.swift`：本地 `.dna` 质粒池持久化管理与目录扫描导入服务。
- `Services/SnapGeneService.swift`：调用 `snapgene_bridge.py` 解析 `.dna` 质粒特征/引物、注入引物及生成重组质粒 `.dna` 文件。
- `Services/ExcelOrderExporter.swift`：调用 `export_order.py` 将引物池与测序样品灌装导出为擎科/生工标准 `.xlsx` 订购表。
- `Services/GenomicLibraryService.swift`：基于 SQLite3 高速检索 `Libraries.sqlite` 中的人源（hg38）/鼠源（mm39）sgRNA 与 shRNA 靶点。
- `Services/CHOPCHOPService.swift` & `CloneOnlineAPIClient.swift`：CHOPCHOP 靶点检索服务与在线克隆引物设计客户端。
- `Services/CloneStudioResourceLocator.swift`：兼容 `.app` Bundle 与 SwiftPM 命令行模式的资源路径定位器。

### 3.6 打包资源 (`Resources/`)
- 图标资源：`AppIcon.icns`、`AppIcon_Light.icns`、`AppIcon_Dark.icns`、`AppIcon_1024.png`、`AppIcon_Light_1024.png`、`AppIcon_Dark_1024.png`、`StatusBarIcon.png`、`StatusBarIcon@2x.png`。
- 数据库与配置：`Libraries.sqlite`（离线基因组靶点库）、`select.json`。
- Python 桥接脚本：`snapgene_bridge.py`、`export_order.py`、`chopchop_query.py`、`clonestudio_mcp_server.py`。
- 商业订购表母版：`擎科引物合成订购表.xlsx`、`擎科测序订购表专属电子订单.xlsx`、`生工DNA测序订购表.xlsx`、`DNA测序订购表_V9(1).xlsx`。

## 四、 命令行自检与测试 (`labworker/Tests/`)
- `Tests/CloneStudioVerify/main.swift`：`CloneStudioVerify` 靶点入口，用于对引物设计、Tm 计算、`.dna` 解析、几何排版与实验台算法（含 `Samples/WB/gapdh_*.tif` 真实 16-bit 样本）执行回归校验。
- `Tests/vectors/*.json`：Swift (`CloneStudioCore`) 与 Python (`clonestudio_mcp_server.py`) 跨语言共享黄金测试向量集（`tm_santalucia.json`、`reverse_complement.json`、`primer_thermo_dg.json`、`protein_pi_ddg.json`、`qpcr_ddct.json`、`holm_adjust.json`）。
- `Tests/vectors/run_python_vectors.py`：Python 端共享测试向量执行器与防篡改校验脚本（支持 `--tamper-check`）。
- `Tests/vectors/generate/generate_vectors.py`：基于 `primer3` / `scipy` / SantaLucia 1998 黄金真值的测试向量一次性生成脚本。
