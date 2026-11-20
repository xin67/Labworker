# Labworker 20261115 (CloneStudio) — AI 项目交接与架构指南 (`HANDOVER.md`)

> **文档定位**：本文档专为接手本项目的 AI 编程助手（Claude / Cursor / Windsurf / Antigravity / Codex 等）编写，汇总目录拓扑、单一事实来源（Single Source of Truth）契约、双端（Swift + Python MCP）同步规范、已落地的科学严谨性与性能保障，以及后续演进约束。
> **核心铁律**：在修改任何算法、UI 模块或 MCP 工具后，**必须**运行 `cd labworker && bash Scripts/check_doc_counts.sh && /usr/bin/python3 Tests/vectors/run_python_vectors.py --tamper-check` 并确保回归闭环通过，严禁破坏现有科学计算精度、跨语言一致性与脱敏红线。

---

## 1. 项目概览与环境信息

- **项目名称**：Labworker 20261115（SwiftPM Package / Target 名称：`CloneStudio`、`CloneStudioCore`、`CloneStudioVerify`）
- **形态与定位**：macOS 原生干湿实验与生物信息学一体化科研桌面工作台（Wet-Lab & Bioinformatics Native Workbench）
- **目录结构**：
  - 仓库根目录：`<repo-root>/`（包含 `.gitignore`、`.github/workflows/ci.yml`、`ARCHITECTURE.md` 及 `labworker/`）
  - Swift Package 主目录：`<repo-root>/labworker`
- **远程仓库**：`https://github.com/xin67/Labworker.git`（分支：`main`，已全局脱敏个人隐私、本地用户名路径与实验室私有质粒记录）
- **本地私有数据保护（已在 `/.gitignore` 拦截，严禁提交到 Git）**：
  - `本地个人备份_勿上传/`（用户个人本地 `.dna` / 备份数据与私人订购模板）
  - `*.dna`, `*.ab1`, `*.seq`, `*.gb`, `*.gbk`, `plasmid_pool.json`, `.clonestudio_plasmid_pool.json`, `.clonestudio_mcp_sync.json`, `workspace_autosave.json`, `analysis_runs_index.json`, `*_MCP_*.xlsx`, `*订购表_*.xlsx`, `*.bak*`
- **技术栈与编译要求**：
  - **语言与平台**：Swift 6.4+ / **macOS 27.0+ (原生 Liquid Glass UI SDK)**（见 `labworker/Package.swift` `platforms: [.macOS(.v27)]`）
  - **零第三方 Swift Package 依赖**：100% 基于 Apple 原生框架（`SwiftUI`, `AppKit`, `Accelerate`, `SQLite3`, `CryptoKit`, `ImageIO`, `WebKit`, `Charts`, `UniformTypeIdentifiers`）
  - **Python 桥接层**：系统 `/usr/bin/python3`（MCP 与核心测试向量仅依赖 Python 标准库，无强制第三方依赖；可选增强包：`primer3-py`, `biopython`, `snapgene_reader`, `openpyxl`, `scipy`, `PySide6`, `pyqtgraph`）

---

## 2. 单一事实来源（Single Source of Truth）硬性指标

自动化门禁脚本 `labworker/Scripts/check_doc_counts.sh` 强制校验以下核心契约指标。**除非你同步更新了代码、测试和 `README.md` / `ARCHITECTURE.md` 中的声明，否则严禁让这些计数发生漂移**：

1. **自动化验证测试数 (`tests=50`)**：`Tests/CloneStudioVerify/main.swift` 执行并输出 **50** 项 `✅` 通过记录（无桌面外部私有文件时跳过 3 项本地路径测试），运行结束输出 `COUNTS tests=50 tools=23 modules=19`。
2. **MCP 全栈工具数 (`tools=23`)**：Python 端 `Sources/CloneStudioCore/Resources/clonestudio_mcp_server.py`（`--count-tools` 验证）与 Swift 端 `PlasmidPoolManager.mcpToolsCatalog` 严格保持 **23** 个工具 1:1 对齐。
3. **UI 导航模块总数 (`modules=19`)**：`Sources/CloneStudioCore/ViewModels/AppState.swift` 中的 `NavItem` 枚举共 **19** 个模块（5 大侧边栏分类下的 **18** 个科研业务模块 + **1** 个固定常驻 `.settings` 系统设置模块）。
4. **跨语言共享测试向量 (`10 files, 50 cases`)**：`Tests/vectors/*.json` 共 **10** 个 JSON 标准测试向量文件、**50** 个跨语言测试用例，由 Swift (`Test 48`) 与 Python (`Tests/vectors/run_python_vectors.py`) 双向对齐校验；`run_python_vectors.py --tamper-check` 验证篡改任一期望值必须触发非零退出码（exit code 2）。

---

## 3. 仓库目录拓扑与核心模块映射

```text
<repo-root>/
├── .gitignore                                  # 严格拦截 .dna/.ab1/.gb、私有质粒池、本地个人备份及生成物
├── .github/workflows/ci.yml                    # macOS-14 CI：Python 共享向量 + 防篡改检查 + check_doc_counts.sh
├── ARCHITECTURE.md                             # 仓库根指向 labworker/ARCHITECTURE.md
└── labworker/                                  # Swift Package 主目录
    ├── Package.swift                           # macOS 27+，3 Targets: CloneStudioCore, CloneStudio, CloneStudioVerify
    ├── README.md / ARCHITECTURE.md / HANDOVER.md
    ├── Scripts/
    │   ├── check_doc_counts.sh                 # 【核心门禁】校验 50 测试 + 23 MCP 工具 + 19 UI 模块 + 文档一致性
    │   ├── build_app.sh                        # Release 编译并签名 labworker/Labworker.app
    │   ├── generate_icon.py                    # 亮/暗色 AppIcon 与状态栏模板图标生成
    │   └── build_libraries_db.py               # 离线全基因组 sgRNA/shRNA 靶点 SQLite 编译脚本
    ├── Samples/WB/gapdh_*.tif                  # 真实 16-bit 化学发光图、明场 Marker 与叠加图回归样本
    ├── python/wbquant/                         # Western Blot 16-bit 科学计算与 PySide6 协同包
    ├── Tests/
    │   ├── CloneStudioVerify/main.swift        # 自动化回归测试套件
    │   └── vectors/                            # 跨语言 (Swift <-> Python) 共享黄金测试向量 (10 JSON, 50 cases)
    │       ├── run_python_vectors.py           # Python 端向量校验器（含 --tamper-check）
    │       ├── generate/generate_vectors.py    # 向量生成脚本
    │       ├── tm_santalucia.json              # SantaLucia & Hicks 2004 + 等效单价盐离子校正 Tm
    │       ├── reverse_complement.json         # IUPAC 简并碱基反向互补 + 环状跨原点切片
    │       ├── primer_thermo_dg.json           # Hairpin / Homodimer / Heterodimer 热力学 ΔG & Tm
    │       ├── protein_pi_ddg.json             # 蛋白质 MW、等电点 pI、GRAVY 与点突变经验 ΔΔG
    │       ├── qpcr_ddct.json                  # qPCR 2^(-ΔΔCt)、Welch t 检验与 95% CI
    │       └── holm_adjust.json                # Holm-Bonferroni 多重假设检验校正
    └── Sources/
        ├── CloneStudioCore/                    # 核心生物计算、持久化与视图模型层（无 UI 耦合）
        │   ├── Models/                         # BioSequence, RestrictionEnzyme, PrimerItem, GenomicTarget, TargetScore,
        │   │                                   # CHOPCHOPResult, ConstructHistory, PlateLayoutModels, OrderFormProfile,
        │   │                                   # CloneStudioIconProvider, AnalysisRun (Schema v2 + AnalysisRunIndexStore)
        │   ├── Geometry/                       # SequenceRowLayout, CircularOVELayout, CircularGeometry
        │   ├── Engine/                         # 20 个核心算法引擎 (见下文清单)
        │   ├── Services/                       # WorkspaceSessionManager, PlasmidPoolManager, SnapGeneService,
        │   │                                   # ExcelOrderExporter, GenomicLibraryService, CHOPCHOPService,
        │   │                                   # CloneOnlineAPIClient, CloneStudioResourceLocator
        │   ├── ViewModels/                     # 模块化 ViewModel 状态机：
        │   │                                   # AppState, CloningViewModels, MultiFragmentViewModel,
        │   │                                   # MutagenesisViewModel, FragmentDeletionViewModel,
        │   │                                   # BenchCalculatorViewModels, SgRNADesignViewModel, ShRNADesignViewModel,
        │   │                                   # CHOPCHOPCompareViewModel, OrderExportViewModel
        │   └── Resources/                      # clonestudio_mcp_server.py (23 工具), snapgene_bridge.py,
        │                                       # export_order.py, chopchop_query.py, Libraries.sqlite, *.xlsx, 图标
        └── CloneStudio/                        # SwiftUI + AppKit 原生桌面 UI 层
            ├── CloneStudioApp.swift
            └── Views/                          # Main/ContentView, Components/* (含 DesignSystem.swift),
                                                # Cloning/*, Mutagenesis/MutationView, Pool/PlasmidPoolView,
                                                # CRISPR/SgRNADesignView, RNAi/ShRNADesignView,
                                                # Compare/CHOPCHOPWebView, Calculator/RestructureCalculatorView,
                                                # Tools/SequenceToolsView, BenchTools/*, Order/OrderExportView,
                                                # Settings/SettingsView
```

---

## 4. 19 个 UI 导航模块 (`NavItem`) 与核心引擎对照表（含固定常驻 `.settings`，共 19 项）

定义于 `Sources/CloneStudioCore/ViewModels/AppState.swift` 的 `NavItem` 与 `SidebarSectionKind`：

| 分组 | `NavItem` 枚举值 | 界面名称 | 核心 UI 视图 (`Sources/CloneStudio/`) | 核心引擎 / 服务 (`Sources/CloneStudioCore/`) |
| :--- | :--- | :--- | :--- | :--- |
| 分子克隆与质粒 | `.plasmidPool` | 质粒池 | `Views/Pool/PlasmidPoolView.swift` | `Services/PlasmidPoolManager.swift`, `Models/ConstructHistory.swift` |
| 分子克隆与质粒 | `.entryClone` | 入门克隆 | `Views/Cloning/EntryCloneView.swift`, `Views/Components/HomologousPCRGelView.swift` | `Engine/HomologyArmDesigner.swift`, `Engine/HomologousPCRGelSimulator.swift`, `Engine/TmCalculator.swift` |
| 分子克隆与质粒 | `.singleFragment` | 单片段克隆 | `Views/Cloning/SingleFragmentCloneView.swift`, `Views/Components/HomologousPCRGelView.swift` | `Engine/HomologyArmDesigner.swift`, `Engine/HomologousPCRGelSimulator.swift`, `Engine/PrimerQualityEngine.swift` |
| 分子克隆与质粒 | `.multiFragment` | 多片段克隆 | `Views/Cloning/MultiFragmentCloneView.swift`, `Views/Components/HomologousPCRGelView.swift` | `Engine/HomologyArmDesigner.swift`, `Engine/HomologousPCRGelSimulator.swift`, `ViewModels/MultiFragmentViewModel.swift` |
| 分子克隆与质粒 | `.mutagenesis` | 定点突变 | `Views/Mutagenesis/MutationView.swift` | `Engine/HomologyArmDesigner.swift`, `ViewModels/MutagenesisViewModel.swift` |
| 分子克隆与质粒 | `.fragmentDeletion` | 片段删除 | `Views/Cloning/FragmentDeletionView.swift`, `Views/Components/HomologousPCRGelView.swift` | `Engine/HomologyArmDesigner.swift`, `Engine/HomologousPCRGelSimulator.swift`, `ViewModels/FragmentDeletionViewModel.swift` |
| 分子克隆与质粒 | `.sangerVerify` | 测序验证 | `Views/Cloning/SangerVerificationView.swift` | `Engine/SangerAlignmentEngine.swift`, `Engine/SangerBatchEngine.swift` |
| 基因编辑与靶点 | `.sgRNADesign` | sgRNA 设计 | `Views/CRISPR/SgRNADesignView.swift` | `Engine/CRISPRDesigner.swift`, `Engine/SgRNAScoringEngine.swift`, `Services/GenomicLibraryService.swift` |
| 基因编辑与靶点 | `.shRNADesign` | shRNA 设计 | `Views/RNAi/ShRNADesignView.swift` | `Engine/ShRNADesigner.swift`, `Engine/ShRNAScoringEngine.swift` |
| 基因编辑与靶点 | `.chopchopCompare` | 靶点对比 | `Views/Compare/CHOPCHOPWebView.swift` | `Services/CHOPCHOPService.swift`, `ViewModels/CHOPCHOPCompareViewModel.swift` |
| 电泳与图像定量 | `.westernBlot` | WB 灰度定量 | `Views/BenchTools/WesternBlotView.swift` | `Engine/WesternBlotEngine.swift`, `Models/AnalysisRun.swift` |
| 电泳与图像定量 | `.gelFigure` | 凝胶分子量 | `Views/BenchTools/GelFigureEditorView.swift` | `Engine/GelAnalysisEngine.swift`, `Models/AnalysisRun.swift` |
| 定量与蛋白工具 | `.plateDesigner` | 微孔板设计 | `Views/BenchTools/PlateDesignerView.swift` | `Engine/PlateLayoutEngine.swift`, `Models/PlateLayoutModels.swift` |
| 定量与蛋白工具 | `.qpcrAnalysis` | qPCR 定量 | `Views/BenchTools/QPCRAnalysisView.swift` | `Engine/QPCRAnalysisEngine.swift`, `Models/AnalysisRun.swift` |
| 定量与蛋白工具 | `.proteinWorkbench` | 蛋白质工作台 | `Views/BenchTools/ProteinWorkbenchView.swift` | `Engine/ProteinBiophysicsEngine.swift` |
| 定量与蛋白工具 | `.dnaCalculator` | 生物计算器 | `Views/Calculator/RestructureCalculatorView.swift`, `Views/Calculator/LabBioCalculatorsView.swift` | `Engine/DNAMolarCalculator.swift`, `Engine/LabBioCalculatorsEngine.swift`, `ViewModels/BenchCalculatorViewModels.swift` |
| 定量与蛋白工具 | `.sequenceTools` | 序列工具 | `Views/Tools/SequenceToolsView.swift` | `Engine/TmCalculator.swift`, `Engine/PrimerQualityEngine.swift` |
| 合成订购与设置 | `.orderCenter` | 订购中心 | `Views/Order/OrderExportView.swift` | `Services/ExcelOrderExporter.swift`, `Models/OrderFormProfile.swift` |
| 合成订购与设置 | `.settings` | 系统设置 | `Views/Settings/SettingsView.swift` | `ViewModels/AppState.swift` |

---

## 5. MCP Server 20261115 协议与 23 个工具清单

服务端：`Sources/CloneStudioCore/Resources/clonestudio_mcp_server.py`（`labworker-mcp` 20261115，纯 Python 标准库 JSON-RPC 2.0 stdio，**23** 个工具与 Swift `PlasmidPoolManager.mcpToolsCatalog` 严格对齐）：

1. `list_plasmid_pool`
2. `inspect_plasmid`
3. `add_plasmid_to_pool` *(支持两阶段 `confirm` dry-run 预览与 `.bak-*` 备份)*
4. `design_single_clone_primers` *(导出重组 `.dna` 时支持 `confirm` dry-run)*
5. `design_multi_fragment_primers`
6. `design_mutagenesis_primers`
7. `design_fragment_deletion_primers`
8. `calculate_recombination_dosage` *(支持同源重组与 0.03 pmol 经典摩尔比模式)*
9. `convert_nucleic_acid_units` *(dsDNA / ssDNA / Linear DNA 末端 / OD260 核酸定量)*
10. `convert_protein_and_coding` *(蛋白质摩尔 kDa⇄µg⇄pmol & DNA 编码容量)*
11. `calculate_solution_and_temperature` *(摩尔浓度质量配制 / C1V1=C2V2 稀释 / 温标转换)*
12. `design_sgrna_primers` *(返回 `score_type="sequence_heuristic"`、`off_target_checked=false`)*
13. `design_shrna_primers` *(返回 `score_type="sequence_heuristic"`、`off_target_checked=false`)*
14. `manage_primer_cart_and_export` *(导出 `.xlsx` 支持 `confirm` dry-run)*
15. `analyze_protein_and_docking_box` *(返回 `ddg_model_type="empirical_heuristic"` 及 LIGSITE + 共晶/SITE 共识盒)*
16. `analyze_western_blot`
17. `analyze_qpcr_ddct` *(生物重复级 Welch t 检验、95% CI 与 Holm-Bonferroni 校正)*
18. `design_plate_layout`
19. `verify_sanger_sequencing`
20. `deconvolute_crispr_sanger`
21. `auto_annotate_sequence`
22. `design_golden_gate_assembly`
23. `design_hdr_donor`

---

## 6. 已落地的工程健壮性、科学透明性与性能机制

1. **防管道死锁的同步子进程读取 (`DispatchGroup`)**：
   - `ExcelOrderExporter.swift` 与 `WesternBlotEngine.swift`（`runPythonCLI`）均采用 `DispatchGroup` 并行排空 `standardOutput` 与 `standardError` 管道后再调用 `waitUntilExit()`，消除大输出场景下的经典 macOS Pipe 缓冲区死锁。
2. **启发式算法诚实标注（无夸大、无黑盒）**：
   - CRISPR/shRNA 评分明确标记 `score_type = "sequence_heuristic"` 与 `off_target_checked = false`，提示需使用 CHOPCHOP/Cas-OFFinder 核验全基因组脱靶。
   - 点突变稳定性初筛明确标记 `model_type = "empirical_heuristic"` / `ddg_model_type = "empirical_heuristic"`（基于疏水性/位阻/脯氨酸经验项初筛，非 FoldX / Rosetta 全原子能量模型）。
3. **全链路可复现溯源 (`AnalysisRun` Schema v2)**：
   - 导出数据时伴生写入 `<basename>.run.json`（含输入文件 CryptoKit `SHA-256` 指纹、算法参数、`manualEdits` 手动编辑、`exclusions` 剔除记录与 `linkedPlasmidIDs` 关联质粒 ID）并注册至 `AnalysisRunIndexStore`，覆盖 **测序验证 (`SangerAlignmentEngine` / `SangerBatchEngine`)、WB 灰度定量 (`WesternBlotEngine`)、qPCR (`QPCRAnalysisEngine`)、凝胶分子量 (`GelAnalysisEngine`)** 四大定量分析工作台。
4. **`Accelerate` (`vDSP`) 图像 SIMD 加速**：
   - `BioImageProcessor`（`gaussianBlur`、`columnProfile`、`rowProfile`）与 `WesternBlotEngine`（`grayscaleMorphStep1D`、`computeGaussianWeightedLaneProfile`、`detectLanesNative` 列均值）使用 Apple `Accelerate/vDSP` 向量化计算，严格保持原有边缘夹紧（clamp）与浮点数值语义。

---

## 7. 标准验证与发布流程

每次代码修改后，在 `<repo-root>/labworker` 目录执行：

```bash
# 1. Python 跨语言共享测试向量 + 防篡改自检 (exit 0 + exit 2)
/usr/bin/python3 Tests/vectors/run_python_vectors.py
/usr/bin/python3 Tests/vectors/run_python_vectors.py --tamper-check; echo "tamper_exit=$?"

# 2. Swift 编译 + 50 项回归测试 + 文档数字单一真值门禁
bash Scripts/check_doc_counts.sh

# 3. Release 编译 (0 warnings) 并重新打包签名 Labworker.app，生成可分发 .dmg
bash Scripts/build_app.sh
bash Scripts/package_dmg.sh --skip-build
```

> **开发规范提示**：
> - 严禁在 `Sources/`、`Tests/` 或公开文档中硬编码任何本地用户路径（如个人 home 目录）、真实实验室质粒私有名称或私人联系方式。
> - 新增、删除或拆分的任何 `.swift` 源码文件，必须在 `labworker/ARCHITECTURE.md` 中同步登记。
> - 修改任何跨语言核心科学计算（Tm、反向互补、引物 ΔG、蛋白 pI/ΔΔG、qPCR $\Delta\Delta C_t$/Welch CI、Holm 校正）时，必须同步更新 `Tests/vectors/*.json`、`clonestudio_mcp_server.py` 与 `CloneStudioCore`。
> - UI 控件须遵守同排同档高度（L 档 28pt / S 档 24pt）、玻璃交互默认受限 HDR（`StudioGlassSupport.dynamicRange` `.constrainedHigh` + `hdrGain`，静止描边禁加曝光）、科学定量图像画布显式 `.allowedDynamicRange(.standard)` 锁定 SDR、工作台主操作栏采用 `StudioActionBar` 居左紧凑排布（禁用全宽长条主按钮）、顶栏 `.plasmidToggle`「图谱」按钮未生成图谱时自动隐藏以及嵌入式 `Canvas` 禁止硬设固定宽度锁死窗口缩放（详见 `labworker/README.md` 第 2 节）。
