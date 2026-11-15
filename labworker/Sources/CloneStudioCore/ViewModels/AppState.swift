import Foundation
import SwiftUI
import Combine
import AppKit

/// 侧边栏分组枚举（按实验直觉划分为 5 大清晰分类，支持小箭头折叠与展开）
public enum SidebarSectionKind: String, CaseIterable, Identifiable, Sendable {
    case cloning = "cloning"
    case targeting = "targeting"
    case bioImaging = "bioImaging"
    case benchTools = "benchTools"
    case orderAndSettings = "orderAndSettings"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .cloning:          return "分子克隆与质粒"
        case .targeting:        return "基因编辑与靶点"
        case .bioImaging:       return "电泳与图像定量"
        case .benchTools:       return "定量、进化与蛋白"
        case .orderAndSettings: return "合成订购与设置"
        }
    }
}

/// 侧边栏导航分类项
public enum NavItem: String, CaseIterable, Identifiable {
    case plasmidPool = "plasmidPool"
    case entryClone = "entryClone"
    case singleFragment = "singleFragment"
    case multiFragment = "multiFragment"
    case mutagenesis = "mutagenesis"
    case fragmentDeletion = "fragmentDeletion"
    case sangerVerify = "sangerVerify"
    case sgRNADesign = "sgRNADesign"
    case shRNADesign = "shRNADesign"
    case chopchopCompare = "chopchopCompare"
    case westernBlot = "westernBlot"
    case gelFigure = "gelFigure"
    case colonyCounter = "colonyCounter"
    case figureAnnotator = "figureAnnotator"
    case plateDesigner = "plateDesigner"
    case qpcrAnalysis = "qpcrAnalysis"
    case phylogeneticTree = "phylogeneticTree"
    case proteinWorkbench = "proteinWorkbench"
    case dnaCalculator = "dnaCalculator"
    case sequenceTools = "sequenceTools"
    case orderCenter = "orderCenter"
    case settings = "settings"
    
    public var id: String { rawValue }
    
    public var section: SidebarSectionKind {
        switch self {
        case .plasmidPool, .entryClone, .singleFragment, .multiFragment, .mutagenesis, .fragmentDeletion, .sangerVerify:
            return .cloning
        case .sgRNADesign, .shRNADesign, .chopchopCompare:
            return .targeting
        case .westernBlot, .gelFigure, .colonyCounter, .figureAnnotator:
            return .bioImaging
        case .plateDesigner, .qpcrAnalysis, .phylogeneticTree, .proteinWorkbench, .dnaCalculator, .sequenceTools:
            return .benchTools
        case .orderCenter, .settings:
            return .orderAndSettings
        }
    }
    
    public var title: String {
        switch self {
        case .plasmidPool:      return "质粒池"
        case .entryClone:       return "入门克隆"
        case .singleFragment:   return "单片段克隆"
        case .multiFragment:    return "多片段克隆"
        case .mutagenesis:      return "定点突变"
        case .fragmentDeletion: return "片段删除"
        case .sangerVerify:     return "Sanger 测序"
        case .sgRNADesign:      return "sgRNA 设计"
        case .shRNADesign:      return "shRNA 设计"
        case .chopchopCompare:  return "靶点对比"
        case .westernBlot:      return "WB 灰度定量"
        case .gelFigure:        return "凝胶分子量"
        case .colonyCounter:    return "菌落计数器"
        case .figureAnnotator:  return "科研多图拼版"
        case .plateDesigner:    return "微孔板设计"
        case .qpcrAnalysis:     return "qPCR 定量"
        case .phylogeneticTree: return "系统发育树"
        case .proteinWorkbench: return "蛋白质工作台"
        case .dnaCalculator:    return "用量计算"
        case .sequenceTools:    return "序列与 Tm"
        case .orderCenter:      return "订购中心"
        case .settings:         return "系统设置"
        }
    }
    
    public var systemImage: String {
        switch self {
        case .plasmidPool:      return "tray.2.fill"
        case .entryClone:       return "arrow.triangle.merge"
        case .singleFragment:   return "scissors"
        case .multiFragment:    return "square.stack.3d.forward.dottedline"
        case .mutagenesis:      return "wand.and.stars"
        case .fragmentDeletion: return "scissors.badge.ellipsis"
        case .sangerVerify:     return "waveform.path.ecg.rectangle"
        case .sgRNADesign:      return "scope"
        case .shRNADesign:      return "waveform.path.badge.plus"
        case .chopchopCompare:  return "globe.badge.chevron.backward"
        case .westernBlot:      return "slider.horizontal.below.rectangle"
        case .gelFigure:        return "chart.bar.doc.horizontal.fill"
        case .colonyCounter:    return "circle.hexagongrid.fill"
        case .figureAnnotator:  return "square.grid.2x2.fill"
        case .plateDesigner:    return "square.grid.3x3.fill"
        case .qpcrAnalysis:     return "chart.bar.xaxis"
        case .phylogeneticTree: return "point.3.connected.trianglepath.dotted"
        case .proteinWorkbench: return "atom"
        case .dnaCalculator:    return "function"
        case .sequenceTools:    return "character.textbox"
        case .orderCenter:      return "cart.fill"
        case .settings:         return "gearshape.fill"
        }
    }
    
    /// 侧边栏搜索匹配关键词（支持中英文、缩写与实验术语检索）
    public var searchKeywords: String {
        switch self {
        case .plasmidPool:      return "质粒池 plasmid pool vector dna 载体库"
        case .entryClone:       return "入门克隆 entry clone pce2 同源重组"
        case .singleFragment:   return "单片段克隆 single fragment clone 同源重组 酶切 插入"
        case .multiFragment:    return "多片段克隆 multi fragment assembly 无缝拼接 gibson"
        case .mutagenesis:      return "定点突变 mutagenesis point mutation 氨基酸 密码子"
        case .fragmentDeletion: return "片段删除 fragment deletion 敲除 截短"
        case .sangerVerify:     return "测序验证 sanger ab1 abi chromatogram 峰图 比对 突变 菌落测序"
        case .sgRNADesign:      return "sgrna crispr cas9 基因编辑 敲除 靶点"
        case .shRNADesign:      return "shrna rnai 干扰 敲低 发夹"
        case .chopchopCompare:  return "靶点对比 chopchop compare 在线检索"
        case .westernBlot:      return "wb 灰度定量 western blot densitometry 条带 内参 显影 tif"
        case .gelFigure:        return "凝胶分子量 gel electrophoresis figure marker ladder 电泳 胶图"
        case .colonyCounter:    return "菌落计数器 colony counter cfu 蓝白斑 平板 涂板"
        case .figureAnnotator:  return "科研多图拼版 figure annotator merge 荧光 伪彩 比例尺"
        case .plateDesigner:    return "微孔板设计 plate layout well 96孔板 384孔板 排布 样品"
        case .qpcrAnalysis:     return "qpcr 定量 ct ddct 标准曲线 荧光定量 表达量 csv"
        case .phylogeneticTree: return "系统发育树 phylogenetic tree newick 进化树 聚类 nwk"
        case .proteinWorkbench: return "蛋白质工作台 protein workbench structure pdb plddt ramachandran 等电点 疏水 折叠"
        case .dnaCalculator:    return "用量计算 dna molar calculator 摩尔 质量 ng pmol 体系"
        case .sequenceTools:    return "序列与 tm sequence gc 反向互补 退火温度"
        case .orderCenter:      return "订购中心 order export 擎科 生工 引物合成 测序 excel"
        case .settings:         return "系统设置 settings 外观 主题 参数 内切酶"
        }
    }
    
    /// 是否允许在侧边栏中隐藏（系统设置固定常驻，防止用户无法找回设置入口）
    public var canBeHiddenInSidebar: Bool {
        self != .settings
    }
    
    /// 全局功能说明书：核心定位与算法简介
    public var summaryDescription: String {
        switch self {
        case .plasmidPool:
            return "集中管理本地 SnapGene (.dna) 与 FASTA 质粒载体库，自动解析全序列特征、酶切位点、抗性标签与多步构建谱系树。"
        case .entryClone:
            return "针对 pCE2 等线性入门载体的一步法同源重组引物设计，自动匹配目标退火温度 Tm 与 5' 同源搭桥序列。"
        case .singleFragment:
            return "支持酶切线性化或反向 PCR 扩增载体，基于 18 bp 黄金同源臂与 SantaLucia 最近邻热力学模型设计无缝克隆引物并直接生成重组 .dna 文件。"
        case .multiFragment:
            return "支持 2–10 个插入片段的 Gibson / In-Fusion 多片段同源组装，自动优化相邻片段间重叠区 Tm 一致性，并基于对齐 primer3-py 的热力学引擎执行发夹与自/异二聚体 ΔG 质检。"
        case .mutagenesis:
            return "支持氨基酸定点突变、多位点组合突变与碱基替换，智能切换背靠背反向 PCR 与重叠延伸模式，自动高亮密码子改变。"
        case .fragmentDeletion:
            return "精准跨区域同源环化敲除或结构域截短，自动设计跨越删除边界的桥接引物并重映射下游质粒图谱特征坐标。"
        case .sangerVerify:
            return "原生解析 Sanger 测序 (.ab1 / .abi / .seq) 四色毛细管电泳荧光峰图与 Phred Q 值，执行环状质粒双向全局比对，自动识别 SNP 点突变、移码 Indel 与杂合双峰，并支持多文件批量克隆分组合并看板。"
        case .sgRNADesign:
            return "支持离线文库 (hg38/mm39) 检索与全序列扫描 PAM 位点 (NGG/TTTV)，基于 GC 含量、二级结构、Poly-T 终止信号与位置权重计算 CRISPR/Cas9 序列启发式评分（不含全基因组脱靶搜索，可在靶点对比中用 CHOPCHOP 核验特异性）并生成退火 Oligo。"
        case .shRNADesign:
            return "基于热力学不对称性 (5' 反义链解旋自由能差) 与 RISC 装载偏好筛选高活性 RNAi 干扰靶点，一键生成 pLKO.1 等载体正义/反义发夹序列。"
        case .chopchopCompare:
            return "内置 CHOPCHOP 靶点评分对比工作台，将本地设计的 sgRNA/shRNA 与全基因组脱靶及在线评分分档高亮比对。"
        case .westernBlot:
            return "原生 16-bit TIFF 无损灰度密度定量引擎，采用一维滚球背景扣除、高斯峰分离与内参归一化，自动执行 Welch t 检验并生成出版级显著性柱状图。"
        case .gelFigure:
            return "电泳胶图泳道自动识别与 Log10(MW) 标准曲线回归计算，支持条带分子量插值估算、泳道标签注释与高分辨率图像导出。"
        case .colonyCounter:
            return "基于 Otsu 自适应阈值、连通域分割与 HSV 色彩空间识别平板菌落，支持蓝白斑筛选自动分类计数与 Garwood 泊松 95% 置信区间统计。"
        case .figureAnnotator:
            return "多通道荧光显微图像 RGB 伪彩合成、微米比例尺绘制与跨越 ROI 共定位荧光强度剖面 (Line Profile) 定量拼版工具。"
        case .plateDesigner:
            return "96 孔 / 384 孔微孔板实验排布设计器，支持边缘效应规避 (Edge Avoidance)、梯度稀释序列生成、生物学重复分组与 CSV 机器表导出。"
        case .qpcrAnalysis:
            return "实时荧光定量 PCR 2^(-ΔΔCt) 相对表达量与扩增效率标准曲线解算引擎，严格基于生物学样品级 ΔCt 执行 Welch's t 检验、Holm–Bonferroni 多组比较校正并输出 95% 置信区间。"
        case .phylogeneticTree:
            return "支持多序列距离矩阵构建邻接树 (NJ / UPGMA) 及外部 Newick (.nwk) 进化树解析渲染，提供 Robinson-Foulds 拓扑距离比对。"
        case .proteinWorkbench:
            return "集成蛋白质理化性质 (pI/GRAVY/ε280)、三维 Cα 骨架与二面角拉氏图、LIGSITE 七方向 P-S-P 结合口袋扫描、共晶配体共识 Vina 对接盒推荐及点突变 ΔΔG 评估。"
        case .dnaCalculator:
            return "重组连接与转染体系摩尔质量互算工具，支持载体:片段摩尔比 (1:1 至 1:5) 自动配比、稀释体积计算与多组分加样表生成。"
        case .sequenceTools:
            return "快速 DNA/RNA/氨基酸序列清洗、反向互补、三框密码子翻译、GC% 分布、SantaLucia 最近邻退火温度 (Tm) 及 primer3 发夹/自二聚体 ΔG 即时验算。"
        case .orderCenter:
            return "汇总各模块加入购物车的引物与测序样品，一键导出符合擎科 (Tsingke)、生工 (Sangon) 等合成公司标准格式的 Excel/CSV 订购单。"
        case .settings:
            return "集中管理应用深浅色外观、侧边栏功能模块显隐定制、各实验工作台默认算法参数、限制性内切酶库以及全局功能说明书。"
        }
    }
    
    /// 全局功能说明书：支持快导或解析的文件格式
    public var supportedFormats: String {
        switch self {
        case .plasmidPool, .entryClone, .singleFragment, .multiFragment, .mutagenesis, .fragmentDeletion:
            return ".dna (SnapGene) / .fa / .fasta / .seq / .gb"
        case .sangerVerify:
            return ".ab1 / .abi (ABIF 四色峰图) / .seq / .fasta"
        case .sgRNADesign, .shRNADesign, .chopchopCompare, .sequenceTools:
            return ".fa / .fasta / .dna / 纯文本序列"
        case .westernBlot, .gelFigure, .colonyCounter, .figureAnnotator:
            return ".tif / .tiff (原生16-bit) / .png / .jpg"
        case .plateDesigner, .qpcrAnalysis, .orderCenter:
            return ".csv / .tsv / .xlsx 制表文本"
        case .phylogeneticTree:
            return ".nwk / .tree / .newick / 多序列 .fasta"
        case .proteinWorkbench:
            return ".pdb / .cif / .ent / 氨基酸 .fasta"
        case .dnaCalculator, .settings:
            return "内置交互参数面板"
        }
    }
    
    /// 全局功能说明书：快捷实操提示
    public var workflowTip: String {
        switch self {
        case .plasmidPool:      return "可从 Finder 直接拖入整个质粒文件夹批量建库；右键或点击卡片可一键送入克隆或蛋白翻译。"
        case .entryClone:       return "输入目的片段后自动计算正反向引物并高亮同源臂，点击「加入订购车」即可汇总至订购中心。"
        case .singleFragment:   return "支持在环图或微观序列上直接点选双酶切位点或 PCR 扩增区间，导出时自动备份原载体。"
        case .multiFragment:    return "按组装顺序添加多个片段，系统会自动检查相邻接头是否存在发夹或错配风险。"
        case .mutagenesis:      return "可直接输入如 V12A 或 K45R 氨基酸突变指令，自动挑选最优同义/非同义密码子。"
        case .fragmentDeletion: return "拖动滑块或输入起止位点即可预览截短后的环图及下游特征偏移量。"
        case .sangerVerify:     return "拖入测序公司返还的 .ab1 峰图后自动与参考质粒比对，点击异常变异胶囊可直接将荧光色谱图平滑滚动定位至突变峰。"
        case .sgRNADesign:      return "勾选高分靶点后可自动生成带 BbsI / BsmBI 粘性末端的正反向退火 Oligo。"
        case .shRNADesign:      return "内置 AgeI / EcoRI 酶切接头模板，设计完成后可一键送入靶点对比模块交叉验证。"
        case .chopchopCompare:  return "本地设计的候选靶点会自动置顶并在检索表中以星标高亮。"
        case .westernBlot:      return "支持主条带与内参双行联动定量，可手动微调泳道框与基线，并导出带显著性星号的离线 HTML 报告。"
        case .gelFigure:        return "选择预设 Marker (如 DL2000 / 1kb Ladder) 后点击标准带即可拟合 R² 并自动测算未知条带大小。"
        case .colonyCounter:    return "开启蓝白斑模式后可自动区分 X-gal 显色菌落与白色阳性克隆并计算转化效率。"
        case .figureAnnotator:  return "支持 DAPI / GFP / RFP 多通道独立增益调节与一键添加微米标尺。"
        case .plateDesigner:    return "开启「避开最外圈孔」可显著降低 96 孔板边缘蒸发带来的 ELISA / 细胞活性定量偏差。"
        case .qpcrAnalysis:     return "支持直接粘贴仪器导出的 Well / Gene / Sample / Ct 表格，自动剔除或警示 SD > 0.30 的异常复孔。"
        case .phylogeneticTree: return "支持从侧边栏「快导」直接打开 .nwk 树文件，并在矩形进化分支图与辐射树之间切换。"
        case .proteinWorkbench: return "导入含共晶配体的 PDB 时会自动启用「共晶配体 + LIGSITE 共识融合盒」，一键复制 AutoDock Vina 配置。"
        case .dnaCalculator:    return "输入载体与片段长度及浓度后，实时给出最优 ng 质量与 μL 加样体积。"
        case .sequenceTools:    return "菜单栏托盘弹窗也内置了与本模块同源的极简序列 Tm / GC / 反向互补速算器。"
        case .orderCenter:      return "可在「系统设置 → 参数与外观」中预先保存课题组订购人姓名、电话与抗性偏好，免去每次重复填写。"
        case .settings:         return "所有隐藏的侧边栏功能均可在本页随时恢复，也可通过侧边栏搜索框或说明书「直达功能」随时打开。"
        }
    }
    
    public func matchesSearch(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }
        return title.lowercased().contains(trimmed)
            || section.title.lowercased().contains(trimmed)
            || searchKeywords.lowercased().contains(trimmed)
            || summaryDescription.lowercased().contains(trimmed)
            || supportedFormats.lowercased().contains(trimmed)
    }
}

/// 侧边栏模块可见性快捷预设方案
public enum SidebarVisibilityPreset: String, CaseIterable, Identifiable, Sendable {
    case all = "all"
    case cloningAndTargeting = "cloningAndTargeting"
    case imagingAndBench = "imagingAndBench"
    
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all:                 return "显示全部功能 (\(NavItem.allCases.count))"
        case .cloningAndTargeting: return "仅分子克隆与基因编辑"
        case .imagingAndBench:     return "仅图像定量与蛋白工具"
        }
    }
}

/// 全局应用深浅色外观模式
public enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色模式"
        case .dark:   return "深色模式"
        }
    }
    
    public var shortTitle: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
    
    public var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// 质粒图谱与序列画布专属配色模式
public enum CanvasThemeOverride: String, CaseIterable, Identifiable, Sendable {
    case followApp = "followApp"
    case forceLight = "forceLight"
    case forceDark = "forceDark"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .followApp:  return "跟随外观"
        case .forceLight: return "固定白底"
        case .forceDark:  return "固定黑底"
        }
    }
    
    public var shortTitle: String {
        title
    }
}

/// 全局主题强调色（对齐 macOS 27 系统设置外观颜色，支持跟随系统/多色与手动单色选择）
public enum AppAccentTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case blue = "blue"
    case teal = "teal"
    case purple = "purple"
    case pink = "pink"
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case graphite = "graphite"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system:   return "多色"
        case .blue:     return "蓝色"
        case .teal:     return "青色"
        case .purple:   return "紫色"
        case .pink:     return "粉色"
        case .red:      return "红色"
        case .orange:   return "橙色"
        case .yellow:   return "黄色"
        case .green:    return "绿色"
        case .graphite: return "石墨灰"
        }
    }

    public var color: Color {
        switch self {
        case .system:   return AppState.shared.systemAccentColor
        case .blue:     return .blue
        case .teal:     return .teal
        case .purple:   return .purple
        case .pink:     return .pink
        case .red:      return .red
        case .orange:   return .orange
        case .yellow:   return Color(red: 0.96, green: 0.76, blue: 0.08)
        case .green:    return .green
        case .graphite: return Color(red: 0.55, green: 0.55, blue: 0.57)
        }
    }
}

/// macOS 27 原生 Liquid Glass 折射材质档位
public enum LiquidGlassStyleMode: String, CaseIterable, Identifiable, Sendable {
    case regular = "regular"
    case clear = "clear"
    case tinted = "tinted"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .regular: return "标准液态玻璃 (Regular)"
        case .clear:   return "高透液态玻璃 (Clear)"
        case .tinted:  return "主题浸染玻璃 (Tinted)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .regular: return "标准 (Regular)"
        case .clear:   return "清透 (Clear)"
        case .tinted:  return "浸染 (Tinted)"
        }
    }

    /// 各档位对应的默认 Liquid Glass 强度 (0.0 清透 ~ 1.0 浸染)
    public var defaultStrength: Double {
        switch self {
        case .clear:   return 0.08
        case .regular: return 0.38
        case .tinted:  return 0.85
        }
    }

    /// 根据连续强度映射至离散玻璃档位
    public static func fromStrength(_ strength: Double) -> LiquidGlassStyleMode {
        if strength < 0.22 {
            return .clear
        } else if strength < 0.62 {
            return .regular
        } else {
            return .tinted
        }
    }

    /// 返回对应的原生 SwiftUI `Glass` 材质配置
    public func resolvedGlass(accentColor: Color, interactive: Bool = false) -> Glass {
        let base: Glass
        switch self {
        case .regular:
            base = .regular
        case .clear:
            base = .clear
        case .tinted:
            base = .regular.tint(accentColor.opacity(0.22))
        }
        return interactive ? base.interactive() : base
    }
}

/// 构建产物 .dna 默认保存目录
public enum ExportSaveLocation: String, CaseIterable, Identifiable, Sendable {
    case sameAsSource = "sameAsSource"
    case desktop = "desktop"
    case downloads = "downloads"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .sameAsSource: return "与原载体同目录"
        case .desktop:      return "桌面"
        case .downloads:    return "下载目录"
        }
    }
    
    public func resolveDirectory(fallbackSourceURL: URL) -> URL {
        let fm = FileManager.default
        switch self {
        case .sameAsSource:
            return fallbackSourceURL.deletingLastPathComponent()
        case .desktop:
            return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fallbackSourceURL.deletingLastPathComponent()
        case .downloads:
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fallbackSourceURL.deletingLastPathComponent()
        }
    }
}

/// 全局应用程序状态与持久化偏好设置管理器
public final class AppState: ObservableObject {
    public static let shared = AppState()
    private let defaults = UserDefaults.standard
    private var isInitializing = true
    private var isSyncingGlassStrength = false
    
    @Published public var selectedNav: NavItem = .entryClone {
        didSet {
            if selectedNav != oldValue {
                isPreviewExpanded = false
            }
        }
    }
    
    /// 侧边栏搜索框输入词
    @Published public var sidebarSearchText: String = ""
    
    /// 已折叠的侧边栏分组 ID 集合（默认全部展开）
    @Published public var collapsedSidebarSections: Set<String> = [] {
        didSet {
            if !isInitializing {
                defaults.set(Array(collapsedSidebarSections), forKey: "cs_collapsedSidebarSections")
            }
        }
    }
    
    /// 用户自定义在侧边栏中隐藏的功能模块 ID 集合（系统设置 `.settings` 永不隐藏）
    @Published public var hiddenSidebarItems: Set<String> = [] {
        didSet {
            if !isInitializing {
                defaults.set(Array(hiddenSidebarItems), forKey: "cs_hiddenSidebarItems")
            }
        }
    }
    
    public func isNavItemVisible(_ item: NavItem) -> Bool {
        if !item.canBeHiddenInSidebar { return true }
        return !hiddenSidebarItems.contains(item.rawValue)
    }
    
    public func setNavItemVisible(_ item: NavItem, visible: Bool) {
        guard item.canBeHiddenInSidebar else { return }
        if visible {
            hiddenSidebarItems.remove(item.rawValue)
        } else {
            hiddenSidebarItems.insert(item.rawValue)
            if selectedNav == item {
                selectedNav = NavItem.allCases.first(where: { isNavItemVisible($0) }) ?? .settings
            }
        }
    }
    
    public func applySidebarVisibilityPreset(_ preset: SidebarVisibilityPreset) {
        switch preset {
        case .all:
            hiddenSidebarItems.removeAll()
        case .cloningAndTargeting:
            let keepSections: Set<SidebarSectionKind> = [.cloning, .targeting, .orderAndSettings]
            hiddenSidebarItems = Set(
                NavItem.allCases
                    .filter { $0.canBeHiddenInSidebar && !keepSections.contains($0.section) }
                    .map(\.rawValue)
            )
        case .imagingAndBench:
            let keepSections: Set<SidebarSectionKind> = [.bioImaging, .benchTools, .orderAndSettings]
            hiddenSidebarItems = Set(
                NavItem.allCases
                    .filter { $0.canBeHiddenInSidebar && !keepSections.contains($0.section) }
                    .map(\.rawValue)
            )
        }
        if !isNavItemVisible(selectedNav) {
            selectedNav = NavItem.allCases.first(where: { isNavItemVisible($0) }) ?? .settings
        }
    }
    
    public func isSidebarSectionExpanded(_ section: SidebarSectionKind) -> Bool {
        if !sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !collapsedSidebarSections.contains(section.rawValue)
    }
    
    public func toggleSidebarSection(_ section: SidebarSectionKind) {
        if collapsedSidebarSections.contains(section.rawValue) {
            collapsedSidebarSections.remove(section.rawValue)
        } else {
            collapsedSidebarSections.insert(section.rawValue)
        }
    }
    
    // MARK: - 1. 外观与主题设置
    @Published public var appearanceMode: AppAppearanceMode = .system {
        didSet { saveSetting("cs_appearanceMode", appearanceMode.rawValue) }
    }
    @Published public var systemIsLightAppearance: Bool = true
    @Published public var systemAccentColor: Color = AppState.resolveSystemAccentColor()
    @Published public var systemAccentTitle: String = AppState.resolveSystemAccentTitle()
    @Published public var systemLiquidGlassStrength: Double = AppState.resolveSystemLiquidGlassStrength()
    @Published public var showStatusBarIcon: Bool = true {
        didSet { saveSetting("cs_showStatusBarIcon", showStatusBarIcon) }
    }
    @Published public var canvasThemeOverride: CanvasThemeOverride = .followApp {
        didSet { saveSetting("cs_canvasThemeOverride", canvasThemeOverride.rawValue) }
    }
    @Published public var accentTheme: AppAccentTheme = .system {
        didSet { saveSetting("cs_accentTheme", accentTheme.rawValue) }
    }
    @Published public var followSystemLiquidGlass: Bool = true {
        didSet { saveSetting("cs_followSystemLiquidGlass", followSystemLiquidGlass) }
    }
    @Published public var liquidGlassStrength: Double = 0.38 {
        didSet {
            let clamped = min(1.0, max(0.0, liquidGlassStrength))
            if abs(clamped - liquidGlassStrength) > 1e-6 {
                liquidGlassStrength = clamped
                return
            }
            saveSetting("cs_liquidGlassStrength", clamped)
            guard !isInitializing && !isSyncingGlassStrength else { return }
            isSyncingGlassStrength = true
            let mapped = LiquidGlassStyleMode.fromStrength(clamped)
            if liquidGlassStyle != mapped {
                liquidGlassStyle = mapped
            }
            isSyncingGlassStrength = false
        }
    }
    @Published public var liquidGlassStyle: LiquidGlassStyleMode = .regular {
        didSet {
            saveSetting("cs_liquidGlassStyle", liquidGlassStyle.rawValue)
            guard !isInitializing && !isSyncingGlassStrength else { return }
            isSyncingGlassStrength = true
            liquidGlassStrength = liquidGlassStyle.defaultStrength
            isSyncingGlassStrength = false
        }
    }
    /// 当前实际生效的 Liquid Glass 强度 (0.0 清透 ~ 1.0 浸染)
    public var effectiveLiquidGlassStrength: Double {
        followSystemLiquidGlass ? systemLiquidGlassStrength : liquidGlassStrength
    }
    /// 当前实际生效的 Liquid Glass 离散材质档位
    public var effectiveLiquidGlassStyle: LiquidGlassStyleMode {
        followSystemLiquidGlass ? LiquidGlassStyleMode.fromStrength(systemLiquidGlassStrength) : liquidGlassStyle
    }
    /// 当前外观、Liquid Glass 与主题强调色是否已全部处于「跟随系统」状态
    public var isFollowingAllSystemAppearance: Bool {
        appearanceMode == .system && accentTheme == .system && followSystemLiquidGlass
    }
    @Published public var enableAmbientGlassGlow: Bool = true {
        didSet { saveSetting("cs_enableAmbientGlassGlow", enableAmbientGlassGlow) }
    }
    @Published public var sidebarWidth: CGFloat = 232 {
        didSet {
            let clamped = min(380.0, max(188.0, sidebarWidth))
            if abs(clamped - sidebarWidth) > 0.5 {
                sidebarWidth = clamped
                return
            }
            saveSetting("cs_sidebarWidth", Double(clamped))
        }
    }
    @Published public var sequenceFontSize: Double = 10.0 {
        didSet { saveSetting("cs_sequenceFontSize", sequenceFontSize) }
    }

    public static func resolveSystemAccentColor() -> Color {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let code = global?["AppleAccentColor"] as? Int {
            switch code {
            case -1: return Color(red: 0.55, green: 0.55, blue: 0.57)
            case 0:  return .red
            case 1:  return .orange
            case 2:  return Color(red: 0.96, green: 0.76, blue: 0.08)
            case 3:  return .green
            case 4:  return .blue
            case 5:  return .purple
            case 6:  return .pink
            default: break
            }
        }
        if let srgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            return Color(
                .sRGB,
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent),
                opacity: Double(srgb.alphaComponent)
            )
        }
        return .blue
    }

    public static func resolveSystemAccentTitle() -> String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let code = global?["AppleAccentColor"] as? Int {
            switch code {
            case -1: return "石墨灰"
            case 0:  return "红色"
            case 1:  return "橙色"
            case 2:  return "黄色"
            case 3:  return "绿色"
            case 4:  return "蓝色"
            case 5:  return "紫色"
            case 6:  return "粉色"
            default: break
            }
        }
        return "多色"
    }

    public static func resolveSystemLiquidGlassStrength() -> Double {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return 0.88
        }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let num = global?["NSGlassTintAmount"] as? NSNumber {
            return min(1.0, max(0.0, num.doubleValue))
        }
        if let rawDouble = global?["NSGlassTintAmount"] as? Double {
            return min(1.0, max(0.0, rawDouble))
        }
        return 0.25
    }

    /// 刷新来自 macOS 系统设置的实时外观、主题色与 Liquid Glass 强度
    public func refreshSystemAppearancePreferences() {
        systemAccentColor = Self.resolveSystemAccentColor()
        systemAccentTitle = Self.resolveSystemAccentTitle()
        systemLiquidGlassStrength = Self.resolveSystemLiquidGlassStrength()
    }

    /// 一键将外观、Liquid Glass 强度与主题色全部恢复跟随 macOS 系统设置
    public func followAllSystemAppearanceSettings() {
        refreshSystemAppearancePreferences()
        appearanceMode = .system
        accentTheme = .system
        followSystemLiquidGlass = true
        showToast("外观、Liquid Glass 与主题色已跟随系统设置")
    }
    
    // MARK: - 2. 克隆与引物设计默认参数 (同源重组与定点突变独立 Tm 及浮动范围)
    @Published public var defaultHomologyLength: Int = 18 {
        didSet { saveSetting("cs_defaultHomologyLength", defaultHomologyLength) }
    }
    @Published public var defaultLinearizationModeRaw: String = "pcr" {
        didSet { saveSetting("cs_defaultLinearizationModeRaw", defaultLinearizationModeRaw) }
    }
    @Published public var defaultIncludeVectorPCRPrimers: Bool = true {
        didSet { saveSetting("cs_defaultIncludeVectorPCRPrimers", defaultIncludeVectorPCRPrimers) }
    }
    
    /// 同源重组默认目标退火温度 (52.0 ~ 68.0 ℃，默认 60.0 ℃)
    @Published public var cloningTargetTm: Double = 60.0 {
        didSet { saveSetting("cs_cloningTargetTm", cloningTargetTm) }
    }
    
    /// 定点突变/环化默认目标退火温度 (58.0 ~ 72.0 ℃，默认 68.0 ℃)
    @Published public var mutationTargetTm: Double = 68.0 {
        didSet { saveSetting("cs_mutationTargetTm", mutationTargetTm) }
    }
    
    /// 允许 Tm 浮动范围 (±0.0 ~ ±3.0 ℃，默认 ±1.0 ℃)
    @Published public var tmTolerance: Double = 1.0 {
        didSet { saveSetting("cs_tmTolerance", tmTolerance) }
    }
    
    /// 引物二级结构质检：二价镁离子浓度 [Mg2+] (0.0 ~ 6.0 mM，默认 1.5 mM；仅作用于二聚体/发夹 ΔG 解算，不影响 SnapGene 对齐的引物 Tm)
    @Published public var primerMgConc: Double = 1.5 {
        didSet { saveSetting("cs_primerMgConc", primerMgConc) }
    }
    
    /// 引物二级结构质检：dNTP 浓度 (0.0 ~ 4.0 mM，默认 0.6 mM)
    @Published public var primerDntpConc: Double = 0.6 {
        didSet { saveSetting("cs_primerDntpConc", primerDntpConc) }
    }
    
    /// 引物二级结构质检：单价阳离子浓度 [Na+/K+] (10.0 ~ 200.0 mM，默认 50.0 mM)
    @Published public var primerMvConc: Double = 50.0 {
        didSet { saveSetting("cs_primerMvConc", primerMvConc) }
    }
    
    /// 发夹结构中度风险告警阈值 ΔG (-8.0 ~ -1.0 kcal/mol，默认 -3.0 kcal/mol)
    @Published public var primerHairpinAlertDg: Double = -3.0 {
        didSet { saveSetting("cs_primerHairpinAlertDg", primerHairpinAlertDg) }
    }
    
    /// 二聚体中度风险告警阈值 ΔG (-12.0 ~ -3.0 kcal/mol，默认 -6.0 kcal/mol)
    @Published public var primerDimerAlertDg: Double = -6.0 {
        didSet { saveSetting("cs_primerDimerAlertDg", primerDimerAlertDg) }
    }
    
    /// 当前二级结构热力学反应条件
    public var primerThermoConditions: PrimerQualityEngine.Conditions {
        PrimerQualityEngine.Conditions(
            mvConc: primerMvConc,
            dvConc: primerMgConc,
            dntpConc: primerDntpConc,
            dnaConc: 50.0,
            tempC: 37.0
        )
    }
    
    public func evaluatePrimerQuality(_ sequence: String) -> PrimerQualityEngine.SinglePrimerReport {
        PrimerQualityEngine.evaluatePrimer(
            sequence,
            conditions: primerThermoConditions,
            hairpinAlertDg: primerHairpinAlertDg,
            dimerAlertDg: primerDimerAlertDg
        )
    }
    
    public func evaluatePrimerPairQuality(forward: String, reverse: String) -> PrimerQualityEngine.PrimerPairReport {
        PrimerQualityEngine.evaluatePrimerPair(
            forward: forward,
            reverse: reverse,
            conditions: primerThermoConditions,
            hairpinAlertDg: primerHairpinAlertDg,
            dimerAlertDg: primerDimerAlertDg
        )
    }
    
    /// 兼容属性（映射至同源重组目标 Tm）
    public var defaultTargetTm: Double {
        get { cloningTargetTm }
        set { cloningTargetTm = newValue }
    }
    
    // MARK: - 3. 质粒预览与微观序列画布默认开关
    @Published public var showPlasmidPreview: Bool = true {
        didSet {
            if !showPlasmidPreview {
                isPreviewExpanded = false
            }
            saveSetting("cs_showPlasmidPreview", showPlasmidPreview)
        }
    }
    @Published public var isPreviewExpanded: Bool = false
    
    @Published public var defaultSnapToCodonMode: Bool = true {
        didSet { saveSetting("cs_defaultSnapToCodonMode", defaultSnapToCodonMode) }
    }
    @Published public var defaultShowComplement: Bool = true {
        didSet { saveSetting("cs_defaultShowComplement", defaultShowComplement) }
    }
    @Published public var defaultShowTranslation: Bool = true {
        didSet { saveSetting("cs_defaultShowTranslation", defaultShowTranslation) }
    }
    @Published public var defaultShowFeatures: Bool = true {
        didSet { saveSetting("cs_defaultShowFeatures", defaultShowFeatures) }
    }
    @Published public var defaultShowPrimers: Bool = true {
        didSet { saveSetting("cs_defaultShowPrimers", defaultShowPrimers) }
    }
    @Published public var defaultShowEnzymes: Bool = true {
        didSet { saveSetting("cs_defaultShowEnzymes", defaultShowEnzymes) }
    }
    @Published public var defaultColorizeBases: Bool = true {
        didSet { saveSetting("cs_defaultColorizeBases", defaultColorizeBases) }
    }
    
    // MARK: - 4. 计算引擎与 SnapGene 联动设置
    @Published public var engineMode: EngineMode = .smartDual {
        didSet {
            DualEngineCoordinator.shared.currentMode = engineMode
            saveSetting("cs_engineMode", engineMode.rawValue)
        }
    }
    @Published public var autoCreateSnapGeneBackup: Bool = true {
        didSet { saveSetting("cs_autoCreateSnapGeneBackup", autoCreateSnapGeneBackup) }
    }
    @Published public var autoOpenInSnapGene: Bool = true {
        didSet { saveSetting("cs_autoOpenInSnapGene", autoOpenInSnapGene) }
    }
    @Published public var exportSaveLocation: ExportSaveLocation = .sameAsSource {
        didSet { saveSetting("cs_exportSaveLocation", exportSaveLocation.rawValue) }
    }
    
    // MARK: - 5. 电泳图像、定量实验台与蛋白质工作台默认参数（新增）
    /// WB 默认 Rolling-ball 局部背景扣除半径 (15 ~ 150 px)
    @Published public var defaultWBRollingBallRadius: Int = 50 {
        didSet { saveSetting("cs_defaultWBRollingBallRadius", defaultWBRollingBallRadius) }
    }
    /// WB 默认图像极性（true = 白底黑带 ECL/胶片，false = 黑底亮带 荧光）
    @Published public var defaultWBWhiteBackground: Bool = true {
        didSet { saveSetting("cs_defaultWBWhiteBackground", defaultWBWhiteBackground) }
    }
    /// 凝胶分子量拟合默认 Marker 预设 ID (`dl2000`, `dl5000`, `1kb`, `page_protein`)
    @Published public var defaultGelLadderID: String = "dl2000" {
        didSet { saveSetting("cs_defaultGelLadderID", defaultGelLadderID) }
    }
    /// 微孔板设计器默认孔板规格 (`96` 或 `384`)
    @Published public var defaultPlateFormatRaw: Int = 96 {
        didSet { saveSetting("cs_defaultPlateFormatRaw", defaultPlateFormatRaw) }
    }
    /// 微孔板设计器默认是否开启防边缘效应（跳过最外圈孔位）
    @Published public var defaultPlateAvoidOuterEdge: Bool = true {
        didSet { saveSetting("cs_defaultPlateAvoidOuterEdge", defaultPlateAvoidOuterEdge) }
    }
    /// qPCR 相对定量默认内参基因名称
    @Published public var defaultQPCRReferenceGene: String = "ACTB" {
        didSet { saveSetting("cs_defaultQPCRReferenceGene", defaultQPCRReferenceGene) }
    }
    /// qPCR 复孔 Ct 标准差异常告警阈值 (0.10 ~ 1.00)
    @Published public var defaultQPCRSdThreshold: Double = 0.30 {
        didSet { saveSetting("cs_defaultQPCRSdThreshold", defaultQPCRSdThreshold) }
    }
    /// qPCR NTC 阴性对照起峰告警阈值 (Ct < 阈值判定污染，默认 35.0)
    @Published public var defaultQPCRNtcCtThreshold: Double = 35.0 {
        didSet { saveSetting("cs_defaultQPCRNtcCtThreshold", defaultQPCRNtcCtThreshold) }
    }
    /// qPCR no-RT 对照与对应样品的最小 ΔCt 阈值 (ΔCt < 阈值判定 gDNA 污染，默认 5.0)
    @Published public var defaultQPCRNoRTDeltaCt: Double = 5.0 {
        didSet { saveSetting("cs_defaultQPCRNoRTDeltaCt", defaultQPCRNoRTDeltaCt) }
    }
    /// qPCR 同一靶标熔解曲线 Tm 偏离中位数最大容差 (默认 1.0 ℃)
    @Published public var defaultQPCRMeltTolerance: Double = 1.0 {
        didSet { saveSetting("cs_defaultQPCRMeltTolerance", defaultQPCRMeltTolerance) }
    }
    /// Sanger 批量验证克隆名引物后缀剥离正则（默认兼容 -F/-R/-T7/-M13F 等）
    @Published public var defaultSangerCloneGroupingPattern: String = SangerBatchEngine.defaultPrimerSuffixRegex {
        didSet { saveSetting("cs_defaultSangerCloneGroupingPattern", defaultSangerCloneGroupingPattern) }
    }
    /// 蛋白质工作台默认溶液 pH 值 (4.0 ~ 10.0)
    @Published public var defaultProteinPH: Double = 7.0 {
        didSet { saveSetting("cs_defaultProteinPH", defaultProteinPH) }
    }
    /// 蛋白质工作台默认热力学环境温度 (273.0 ~ 370.0 K)
    @Published public var defaultProteinTempK: Double = 310.0 {
        didSet { saveSetting("cs_defaultProteinTempK", defaultProteinTempK) }
    }
    
    /// Finder 打开或拖入的待处理实验文件 URL（供 WB / 蛋白质工作台 / 进化树 / qPCR 视图自动消费载入）
    @Published public var pendingFinderOpenedFileURL: URL? = nil
    
    // MARK: - 6. 商业订购与引物池状态
    @Published public var primersCart: [PrimerItem] = []
    @Published public var sangonSamples: [SequencingSampleItem] = [
        SequencingSampleItem(sampleName: "pCE-TP53-Entry", sampleType: "质粒", resistance: "Amp", vectorName: "pCE-Entry", fragmentLength: 1182, primerName: "T7", primerCategory: "A、通用引物", requirement: "单向测通", characteristics: "A、正常", returnRequirement: "C、无需返还质粒", notes: "首批重组质粒全长验证"),
        SequencingSampleItem(sampleName: "lentiCRISPRv2-sgTP53", sampleType: "质粒", resistance: "Amp", vectorName: "lentiCRISPRv2", fragmentLength: 500, primerName: "U6", primerCategory: "A、通用引物", requirement: "正向测序", characteristics: "A、正常", returnRequirement: "C、无需返还质粒", notes: "sgRNA插入端测序")
    ]
    @Published public var profile: OrderFormProfile = OrderFormProfile() {
        didSet {
            if !isInitializing, let encoded = try? JSONEncoder().encode(profile) {
                defaults.set(encoded, forKey: "cs_orderProfile")
            }
        }
    }
    
    // MARK: - 全局提示、CHOPCHOP 与谱系传递状态
    @Published public var toastMessage: String? = nil
    @Published public var isShowingToast: Bool = false
    @Published public var chopchopGene: String = ""
    @Published public var chopchopSpecies: TargetSpecies = .human
    @Published public var shouldAutoQueryCHOPCHOP: Bool = false
    /// 本地查找或生成的 sgRNA / shRNA / 自定义对比序列集合（用于在 CHOPCHOP 检索结果中自动高亮提示与置顶对比）
    @Published public var localCompareTargets: [LocalCompareTarget] = []
    @Published public var pendingChainedNode: ConstructHistoryNode? = nil
    
    /// 限制性内切酶预设组名称
    @Published public var selectedEnzymePreset: String = "NEB Standard" {
        didSet { saveSetting("cs_selectedEnzymePreset", selectedEnzymePreset) }
    }
    
    /// 当前选中要在环图与微观序列上标注的内切酶名称列表
    @Published public var selectedEnzymeNames: [String] = RestrictionEnzymeDatabase.presetGroups.first?.enzymeNames ?? [
        "EcoRI", "BamHI", "HindIII", "XhoI", "NdeI", "NcoI", "NotI", "XbaI",
        "SpeI", "PstI", "SalI", "SacI", "KpnI", "SmaI", "EcoRV", "BglII",
        "AgeI", "NheI", "StuI", "HaeIII", "DraI", "BsaI", "BbsI", "BsmBI", "FokI"
    ]
    
    /// 是否仅显示唯一切点酶 (Unique Cutters Only)
    @Published public var uniqueCuttersOnly: Bool = false {
        didSet { saveSetting("cs_uniqueCuttersOnly", uniqueCuttersOnly) }
    }
    
    /// 当前应用是否处于浅色视觉样式（基于 appearanceMode 与系统通知状态，不依赖高频 SwiftUI Environment 广播）
    public var isLightAppearance: Bool {
        switch appearanceMode {
        case .light:  return true
        case .dark:   return false
        case .system: return systemIsLightAppearance
        }
    }
    
    /// 根据当前系统外观与画布覆盖模式计算画布是否应使用深色主题
    public func resolvedCanvasIsDark(systemColorScheme: ColorScheme? = nil) -> Bool {
        switch canvasThemeOverride {
        case .followApp:
            switch appearanceMode {
            case .system:
                if let scheme = systemColorScheme {
                    return scheme == .dark
                }
                return !systemIsLightAppearance
            case .light:  return false
            case .dark:   return true
            }
        case .forceLight:
            return false
        case .forceDark:
            return true
        }
    }
    
    private func saveSetting(_ key: String, _ value: Any) {
        guard !isInitializing else { return }
        defaults.set(value, forKey: key)
    }
    
    public init() {
        loadPersistedSettings()
        isInitializing = false
        DualEngineCoordinator.shared.currentMode = engineMode
    }
    
    private func loadPersistedSettings() {
        if let savedCollapsed = defaults.stringArray(forKey: "cs_collapsedSidebarSections") {
            collapsedSidebarSections = Set(savedCollapsed)
        }
        if let savedHidden = defaults.stringArray(forKey: "cs_hiddenSidebarItems") {
            hiddenSidebarItems = Set(savedHidden.filter { $0 != NavItem.settings.rawValue })
        }
        if let raw = defaults.string(forKey: "cs_appearanceMode"),
           let mode = AppAppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        if defaults.object(forKey: "cs_showStatusBarIcon") != nil {
            showStatusBarIcon = defaults.bool(forKey: "cs_showStatusBarIcon")
        }
        if let raw = defaults.string(forKey: "cs_canvasThemeOverride"),
           let ov = CanvasThemeOverride(rawValue: raw) {
            canvasThemeOverride = ov
        }
        if let raw = defaults.string(forKey: "cs_accentTheme"),
           let acc = AppAccentTheme(rawValue: raw) {
            accentTheme = acc
        }
        if defaults.object(forKey: "cs_followSystemLiquidGlass") != nil {
            followSystemLiquidGlass = defaults.bool(forKey: "cs_followSystemLiquidGlass")
        }
        isSyncingGlassStrength = true
        if let rawGlass = defaults.string(forKey: "cs_liquidGlassStyle"),
           let glassMode = LiquidGlassStyleMode(rawValue: rawGlass) {
            liquidGlassStyle = glassMode
            liquidGlassStrength = glassMode.defaultStrength
        }
        if defaults.object(forKey: "cs_liquidGlassStrength") != nil {
            let s = max(0.0, min(1.0, defaults.double(forKey: "cs_liquidGlassStrength")))
            liquidGlassStrength = s
            if defaults.string(forKey: "cs_liquidGlassStyle") == nil {
                liquidGlassStyle = LiquidGlassStyleMode.fromStrength(s)
            }
        }
        isSyncingGlassStrength = false
        if defaults.object(forKey: "cs_enableAmbientGlassGlow") != nil {
            enableAmbientGlassGlow = defaults.bool(forKey: "cs_enableAmbientGlassGlow")
        }
        if defaults.object(forKey: "cs_sidebarWidth") != nil {
            let savedW = CGFloat(defaults.double(forKey: "cs_sidebarWidth"))
            sidebarWidth = min(380.0, max(188.0, savedW))
        }
        if defaults.object(forKey: "cs_sequenceFontSize") != nil {
            sequenceFontSize = max(9.0, min(13.0, defaults.double(forKey: "cs_sequenceFontSize")))
        }
        if defaults.object(forKey: "cs_defaultHomologyLength") != nil {
            let len = defaults.integer(forKey: "cs_defaultHomologyLength")
            if [15, 18, 20, 25].contains(len) {
                defaultHomologyLength = len
            }
        }
        if let raw = defaults.string(forKey: "cs_defaultLinearizationModeRaw") {
            defaultLinearizationModeRaw = raw
        }
        if defaults.object(forKey: "cs_defaultIncludeVectorPCRPrimers") != nil {
            defaultIncludeVectorPCRPrimers = defaults.bool(forKey: "cs_defaultIncludeVectorPCRPrimers")
        }
        if defaults.object(forKey: "cs_cloningTargetTm") != nil {
            cloningTargetTm = max(52.0, min(68.0, defaults.double(forKey: "cs_cloningTargetTm")))
        } else if defaults.object(forKey: "cs_defaultTargetTm") != nil {
            cloningTargetTm = max(52.0, min(68.0, defaults.double(forKey: "cs_defaultTargetTm")))
        }
        if defaults.object(forKey: "cs_mutationTargetTm") != nil {
            mutationTargetTm = max(58.0, min(72.0, defaults.double(forKey: "cs_mutationTargetTm")))
        }
        if defaults.object(forKey: "cs_tmTolerance") != nil {
            tmTolerance = max(0.0, min(3.0, defaults.double(forKey: "cs_tmTolerance")))
        }
        if defaults.object(forKey: "cs_primerMgConc") != nil {
            primerMgConc = max(0.0, min(6.0, defaults.double(forKey: "cs_primerMgConc")))
        }
        if defaults.object(forKey: "cs_primerDntpConc") != nil {
            primerDntpConc = max(0.0, min(4.0, defaults.double(forKey: "cs_primerDntpConc")))
        }
        if defaults.object(forKey: "cs_primerMvConc") != nil {
            primerMvConc = max(10.0, min(200.0, defaults.double(forKey: "cs_primerMvConc")))
        }
        if defaults.object(forKey: "cs_primerHairpinAlertDg") != nil {
            primerHairpinAlertDg = max(-8.0, min(-1.0, defaults.double(forKey: "cs_primerHairpinAlertDg")))
        }
        if defaults.object(forKey: "cs_primerDimerAlertDg") != nil {
            primerDimerAlertDg = max(-12.0, min(-3.0, defaults.double(forKey: "cs_primerDimerAlertDg")))
        }
        if defaults.object(forKey: "cs_showPlasmidPreview") != nil {
            showPlasmidPreview = defaults.bool(forKey: "cs_showPlasmidPreview")
        }
        if defaults.object(forKey: "cs_defaultSnapToCodonMode") != nil {
            defaultSnapToCodonMode = defaults.bool(forKey: "cs_defaultSnapToCodonMode")
        }
        if defaults.object(forKey: "cs_defaultShowComplement") != nil {
            defaultShowComplement = defaults.bool(forKey: "cs_defaultShowComplement")
        }
        if defaults.object(forKey: "cs_defaultShowTranslation") != nil {
            defaultShowTranslation = defaults.bool(forKey: "cs_defaultShowTranslation")
        }
        if defaults.object(forKey: "cs_defaultShowFeatures") != nil {
            defaultShowFeatures = defaults.bool(forKey: "cs_defaultShowFeatures")
        }
        if defaults.object(forKey: "cs_defaultShowPrimers") != nil {
            defaultShowPrimers = defaults.bool(forKey: "cs_defaultShowPrimers")
        }
        if defaults.object(forKey: "cs_defaultShowEnzymes") != nil {
            defaultShowEnzymes = defaults.bool(forKey: "cs_defaultShowEnzymes")
        }
        if defaults.object(forKey: "cs_defaultColorizeBases") != nil {
            defaultColorizeBases = defaults.bool(forKey: "cs_defaultColorizeBases")
        }
        if let raw = defaults.string(forKey: "cs_engineMode"),
           let em = EngineMode(rawValue: raw) {
            engineMode = em
        }
        if defaults.object(forKey: "cs_autoCreateSnapGeneBackup") != nil {
            autoCreateSnapGeneBackup = defaults.bool(forKey: "cs_autoCreateSnapGeneBackup")
        }
        if defaults.object(forKey: "cs_autoOpenInSnapGene") != nil {
            autoOpenInSnapGene = defaults.bool(forKey: "cs_autoOpenInSnapGene")
        }
        if let raw = defaults.string(forKey: "cs_exportSaveLocation"),
           let loc = ExportSaveLocation(rawValue: raw) {
            exportSaveLocation = loc
        }
        if defaults.object(forKey: "cs_defaultWBRollingBallRadius") != nil {
            defaultWBRollingBallRadius = max(15, min(150, defaults.integer(forKey: "cs_defaultWBRollingBallRadius")))
        }
        if defaults.object(forKey: "cs_defaultWBWhiteBackground") != nil {
            defaultWBWhiteBackground = defaults.bool(forKey: "cs_defaultWBWhiteBackground")
        }
        if let raw = defaults.string(forKey: "cs_defaultGelLadderID") {
            defaultGelLadderID = raw
        }
        if defaults.object(forKey: "cs_defaultPlateFormatRaw") != nil {
            let pf = defaults.integer(forKey: "cs_defaultPlateFormatRaw")
            if [96, 384].contains(pf) {
                defaultPlateFormatRaw = pf
            }
        }
        if defaults.object(forKey: "cs_defaultPlateAvoidOuterEdge") != nil {
            defaultPlateAvoidOuterEdge = defaults.bool(forKey: "cs_defaultPlateAvoidOuterEdge")
        }
        if let raw = defaults.string(forKey: "cs_defaultQPCRReferenceGene"), !raw.isEmpty {
            defaultQPCRReferenceGene = raw
        }
        if defaults.object(forKey: "cs_defaultQPCRSdThreshold") != nil {
            defaultQPCRSdThreshold = max(0.05, min(1.5, defaults.double(forKey: "cs_defaultQPCRSdThreshold")))
        }
        if defaults.object(forKey: "cs_defaultQPCRNtcCtThreshold") != nil {
            defaultQPCRNtcCtThreshold = max(20.0, min(42.0, defaults.double(forKey: "cs_defaultQPCRNtcCtThreshold")))
        }
        if defaults.object(forKey: "cs_defaultQPCRNoRTDeltaCt") != nil {
            defaultQPCRNoRTDeltaCt = max(1.0, min(15.0, defaults.double(forKey: "cs_defaultQPCRNoRTDeltaCt")))
        }
        if defaults.object(forKey: "cs_defaultQPCRMeltTolerance") != nil {
            defaultQPCRMeltTolerance = max(0.2, min(5.0, defaults.double(forKey: "cs_defaultQPCRMeltTolerance")))
        }
        if let rawPattern = defaults.string(forKey: "cs_defaultSangerCloneGroupingPattern"), !rawPattern.isEmpty {
            defaultSangerCloneGroupingPattern = rawPattern
        }
        if defaults.object(forKey: "cs_defaultProteinPH") != nil {
            defaultProteinPH = max(4.0, min(10.0, defaults.double(forKey: "cs_defaultProteinPH")))
        }
        if defaults.object(forKey: "cs_defaultProteinTempK") != nil {
            defaultProteinTempK = max(273.0, min(370.0, defaults.double(forKey: "cs_defaultProteinTempK")))
        }
        if let data = defaults.data(forKey: "cs_orderProfile"),
           let decoded = try? JSONDecoder().decode(OrderFormProfile.self, from: data) {
            profile = decoded
        }
        if let presetName = defaults.string(forKey: "cs_selectedEnzymePreset"),
           let group = RestrictionEnzymeDatabase.presetGroups.first(where: { $0.name == presetName }) {
            applyEnzymePreset(group)
        }
        if defaults.object(forKey: "cs_uniqueCuttersOnly") != nil {
            uniqueCuttersOnly = defaults.bool(forKey: "cs_uniqueCuttersOnly")
        }
    }
    
    /// 一键恢复默认设置
    public func resetSettingsToDefaults() {
        hiddenSidebarItems.removeAll()
        collapsedSidebarSections.removeAll()
        appearanceMode = .system
        showStatusBarIcon = true
        canvasThemeOverride = .followApp
        accentTheme = .system
        followSystemLiquidGlass = true
        isSyncingGlassStrength = true
        liquidGlassStrength = 0.38
        liquidGlassStyle = .regular
        isSyncingGlassStrength = false
        enableAmbientGlassGlow = true
        sidebarWidth = 232
        refreshSystemAppearancePreferences()
        sequenceFontSize = 10.0
        defaultHomologyLength = 18
        defaultLinearizationModeRaw = "pcr"
        defaultIncludeVectorPCRPrimers = true
        cloningTargetTm = 60.0
        mutationTargetTm = 68.0
        tmTolerance = 1.0
        primerMgConc = 1.5
        primerDntpConc = 0.6
        primerMvConc = 50.0
        primerHairpinAlertDg = -3.0
        primerDimerAlertDg = -6.0
        showPlasmidPreview = true
        defaultSnapToCodonMode = true
        defaultShowComplement = true
        defaultShowTranslation = true
        defaultShowFeatures = true
        defaultShowPrimers = true
        defaultShowEnzymes = true
        defaultColorizeBases = true
        engineMode = .smartDual
        autoCreateSnapGeneBackup = true
        autoOpenInSnapGene = true
        exportSaveLocation = .sameAsSource
        defaultWBRollingBallRadius = 50
        defaultWBWhiteBackground = true
        defaultGelLadderID = "dl2000"
        defaultPlateFormatRaw = 96
        defaultPlateAvoidOuterEdge = true
        defaultQPCRReferenceGene = "ACTB"
        defaultQPCRSdThreshold = 0.30
        defaultQPCRNtcCtThreshold = 35.0
        defaultQPCRNoRTDeltaCt = 5.0
        defaultQPCRMeltTolerance = 1.0
        defaultSangerCloneGroupingPattern = SangerBatchEngine.defaultPrimerSuffixRegex
        defaultProteinPH = 7.0
        defaultProteinTempK = 310.0
        profile = OrderFormProfile()
        if let firstGroup = RestrictionEnzymeDatabase.presetGroups.first {
            applyEnzymePreset(firstGroup)
        }
        showToast("已恢复默认设置")
    }
    
    public func applyEnzymePreset(_ group: EnzymePresetGroup) {
        selectedEnzymePreset = group.name
        if group.isDynamicUnique || group.id.lowercased().contains("unique") {
            uniqueCuttersOnly = true
            selectedEnzymeNames = RestrictionEnzymeDatabase.shared.enzymes.map { $0.name }
        } else {
            uniqueCuttersOnly = false
            selectedEnzymeNames = group.enzymeNames
        }
    }
    
    public func addEnzymeName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !selectedEnzymeNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            selectedEnzymeNames.append(trimmed)
        }
    }
    
    public func removeEnzymeName(_ name: String) {
        selectedEnzymeNames.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
    
    public func clearSelectedEnzymes() {
        selectedEnzymeNames.removeAll()
    }
    
    @MainActor
    public func chainProductConstruct(_ node: ConstructHistoryNode, to targetNav: NavItem) {
        ConstructHistoryManager.shared.activeNodeID = node.id
        self.pendingChainedNode = node
        self.selectedNav = targetNav
        showToast("已将「\(node.constructName)」送入「\(targetNav.title)」作为改造模板")
    }
    
    /// 同步本地查找/选中的 sgRNA 或 shRNA 序列至全局对比池
    public func syncLocalCompareTargets(
        _ targets: [LocalCompareTarget],
        replaceSourceType: LocalCompareTarget.SourceType? = nil
    ) {
        var updated = localCompareTargets
        if let st = replaceSourceType {
            updated.removeAll { $0.sourceType == st }
        }
        for item in targets where item.cleanSequence.count >= 15 {
            if let idx = updated.firstIndex(where: { $0.cleanSequence == item.cleanSequence && $0.sourceType == item.sourceType }) {
                if item.isSelectedOrGenerated || !updated[idx].isSelectedOrGenerated {
                    updated[idx] = item
                }
            } else {
                updated.append(item)
            }
        }
        self.localCompareTargets = updated
    }
    
    public func navigateToCHOPCHOP(
        gene: String,
        species: TargetSpecies,
        localTargets: [LocalCompareTarget]? = nil,
        sourceType: LocalCompareTarget.SourceType? = nil
    ) {
        if let localTargets = localTargets {
            syncLocalCompareTargets(localTargets, replaceSourceType: sourceType)
        }
        self.chopchopGene = gene
        self.chopchopSpecies = species
        self.shouldAutoQueryCHOPCHOP = true
        self.selectedNav = .chopchopCompare
        let selectedCount = self.localCompareTargets.filter { $0.isSelectedOrGenerated }.count
        if selectedCount > 0 {
            showToast("已带入 \(selectedCount) 条本地靶点跳转至「\(gene)」CHOPCHOP 对比")
        } else {
            showToast("已跳转至「\(gene)」CHOPCHOP 在线对比")
        }
    }
    
    public func addPrimerToCart(_ primer: PrimerItem) {
        primersCart.append(primer)
        showToast("已将「\(primer.name)」添加至订购单池")
    }
    
    public func addPrimersToCart(_ primers: [PrimerItem]) {
        primersCart.append(contentsOf: primers)
        showToast("已将 \(primers.count) 条引物添加至订购单池")
    }
    
    public func removePrimer(at index: Int) {
        guard index >= 0 && index < primersCart.count else { return }
        let item = primersCart.remove(at: index)
        showToast("已移除引物：\(item.name)")
    }
    
    public func clearPrimersCart() {
        primersCart.removeAll()
        showToast("已清空订购单引物池")
    }
    
    public func showToast(_ msg: String) {
        toastMessage = msg
        isShowingToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.toastMessage == msg {
                self.isShowingToast = false
            }
        }
    }
}
