import Foundation

// MARK: - 1. 标准遗传密码表与三联体氨基酸翻译器 (Ported from CloneCanvas genome/aa.ts & rowRender.ts)

public struct TranslatedCodonItem: Identifiable, Sendable, Equatable {
    /// 使用稳定的 baseOffset 作为 Identifiable ID，杜绝重绘时 UUID 变化导致视图销毁重建
    public var id: Int { baseOffset }
    /// 相对于当前窗口序列的 0-based 起始偏移
    public let baseOffset: Int
    public let codon: String
    public let aminoAcid: Character
    public let threeLetterCode: String
    public let isStartCodon: Bool
    public let isStopCodon: Bool
    
    public init(
        baseOffset: Int,
        codon: String,
        aminoAcid: Character,
        threeLetterCode: String,
        isStartCodon: Bool,
        isStopCodon: Bool
    ) {
        self.baseOffset = baseOffset
        self.codon = codon
        self.aminoAcid = aminoAcid
        self.threeLetterCode = threeLetterCode
        self.isStartCodon = isStartCodon
        self.isStopCodon = isStopCodon
    }
}

public enum CodonTranslator {
    
    /// 标准遗传密码表 (64 密码子 -> (单字母, 三字母))
    public static let standardTable: [String: (Character, String)] = [
        "TTT": ("F", "Phe"), "TTC": ("F", "Phe"), "TTA": ("L", "Leu"), "TTG": ("L", "Leu"),
        "CTT": ("L", "Leu"), "CTC": ("L", "Leu"), "CTA": ("L", "Leu"), "CTG": ("L", "Leu"),
        "ATT": ("I", "Ile"), "ATC": ("I", "Ile"), "ATA": ("I", "Ile"), "ATG": ("M", "Met"),
        "GTT": ("V", "Val"), "GTC": ("V", "Val"), "GTA": ("V", "Val"), "GTG": ("V", "Val"),
        "TCT": ("S", "Ser"), "TCC": ("S", "Ser"), "TCA": ("S", "Ser"), "TCG": ("S", "Ser"),
        "CCT": ("P", "Pro"), "CCC": ("P", "Pro"), "CCA": ("P", "Pro"), "CCG": ("P", "Pro"),
        "ACT": ("T", "Thr"), "ACC": ("T", "Thr"), "ACA": ("T", "Thr"), "ACG": ("T", "Thr"),
        "GCT": ("A", "Ala"), "GCC": ("A", "Ala"), "GCA": ("A", "Ala"), "GCG": ("A", "Ala"),
        "TAT": ("Y", "Tyr"), "TAC": ("Y", "Tyr"), "TAA": ("*", "Ter"), "TAG": ("*", "Ter"),
        "CAT": ("H", "His"), "CAC": ("H", "His"), "CAA": ("Q", "Gln"), "CAG": ("Q", "Gln"),
        "AAT": ("N", "Asn"), "AAC": ("N", "Asn"), "AAA": ("K", "Lys"), "AAG": ("K", "Lys"),
        "GAT": ("D", "Asp"), "GAC": ("D", "Asp"), "GAA": ("E", "Glu"), "GAG": ("E", "Glu"),
        "TGT": ("C", "Cys"), "TGC": ("C", "Cys"), "TGA": ("*", "Ter"), "TGG": ("W", "Trp"),
        "CGT": ("R", "Arg"), "CGC": ("R", "Arg"), "CGA": ("R", "Arg"), "CGG": ("R", "Arg"),
        "AGT": ("S", "Ser"), "AGC": ("S", "Ser"), "AGA": ("R", "Arg"), "AGG": ("R", "Arg"),
        "GGT": ("G", "Gly"), "GGC": ("G", "Gly"), "GGA": ("G", "Gly"), "GGG": ("G", "Gly")
    ]
    
    /// 20 种标准氨基酸 + 终止密码子选项（带推荐高频密码子与全套同义密码子）
    public struct AminoAcidOption: Identifiable, Sendable {
        public var id: String { String(singleLetter) }
        public let singleLetter: Character
        public let threeLetter: String
        public let chineseName: String
        public let preferredCodon: String
        public let allCodons: [String]
        
        public init(
            singleLetter: Character,
            threeLetter: String,
            chineseName: String,
            preferredCodon: String,
            allCodons: [String]
        ) {
            self.singleLetter = singleLetter
            self.threeLetter = threeLetter
            self.chineseName = chineseName
            self.preferredCodon = preferredCodon
            self.allCodons = allCodons
        }
    }
    
    public static let aminoAcidOptions: [AminoAcidOption] = [
        AminoAcidOption(singleLetter: "A", threeLetter: "Ala", chineseName: "丙氨酸", preferredCodon: "GCC", allCodons: ["GCC", "GCT", "GCA", "GCG"]),
        AminoAcidOption(singleLetter: "R", threeLetter: "Arg", chineseName: "精氨酸", preferredCodon: "CGC", allCodons: ["CGC", "AGA", "AGG", "CGG", "CGT", "CGA"]),
        AminoAcidOption(singleLetter: "N", threeLetter: "Asn", chineseName: "天冬酰胺", preferredCodon: "AAC", allCodons: ["AAC", "AAT"]),
        AminoAcidOption(singleLetter: "D", threeLetter: "Asp", chineseName: "天冬氨酸", preferredCodon: "GAC", allCodons: ["GAC", "GAT"]),
        AminoAcidOption(singleLetter: "C", threeLetter: "Cys", chineseName: "半胱氨酸", preferredCodon: "TGC", allCodons: ["TGC", "TGT"]),
        AminoAcidOption(singleLetter: "Q", threeLetter: "Gln", chineseName: "谷氨酰胺", preferredCodon: "CAG", allCodons: ["CAG", "CAA"]),
        AminoAcidOption(singleLetter: "E", threeLetter: "Glu", chineseName: "谷氨酸", preferredCodon: "GAG", allCodons: ["GAG", "GAA"]),
        AminoAcidOption(singleLetter: "G", threeLetter: "Gly", chineseName: "甘氨酸", preferredCodon: "GGC", allCodons: ["GGC", "GGT", "GGA", "GGG"]),
        AminoAcidOption(singleLetter: "H", threeLetter: "His", chineseName: "组氨酸", preferredCodon: "CAC", allCodons: ["CAC", "CAT"]),
        AminoAcidOption(singleLetter: "I", threeLetter: "Ile", chineseName: "异亮氨酸", preferredCodon: "ATC", allCodons: ["ATC", "ATT", "ATA"]),
        AminoAcidOption(singleLetter: "L", threeLetter: "Leu", chineseName: "亮氨酸", preferredCodon: "CTG", allCodons: ["CTG", "CTC", "CTT", "TTG", "TTA", "CTA"]),
        AminoAcidOption(singleLetter: "K", threeLetter: "Lys", chineseName: "赖氨酸", preferredCodon: "AAG", allCodons: ["AAG", "AAA"]),
        AminoAcidOption(singleLetter: "M", threeLetter: "Met", chineseName: "甲硫氨酸", preferredCodon: "ATG", allCodons: ["ATG"]),
        AminoAcidOption(singleLetter: "F", threeLetter: "Phe", chineseName: "苯丙氨酸", preferredCodon: "TTC", allCodons: ["TTC", "TTT"]),
        AminoAcidOption(singleLetter: "P", threeLetter: "Pro", chineseName: "脯氨酸", preferredCodon: "CCC", allCodons: ["CCC", "CCT", "CCA", "CCG"]),
        AminoAcidOption(singleLetter: "S", threeLetter: "Ser", chineseName: "丝氨酸", preferredCodon: "AGC", allCodons: ["AGC", "TCC", "TCT", "TCA", "AGT", "TCG"]),
        AminoAcidOption(singleLetter: "T", threeLetter: "Thr", chineseName: "苏氨酸", preferredCodon: "ACC", allCodons: ["ACC", "ACT", "ACA", "ACG"]),
        AminoAcidOption(singleLetter: "W", threeLetter: "Trp", chineseName: "色氨酸", preferredCodon: "TGG", allCodons: ["TGG"]),
        AminoAcidOption(singleLetter: "Y", threeLetter: "Tyr", chineseName: "酪氨酸", preferredCodon: "TAC", allCodons: ["TAC", "TAT"]),
        AminoAcidOption(singleLetter: "V", threeLetter: "Val", chineseName: "缬氨酸", preferredCodon: "GTG", allCodons: ["GTG", "GTC", "GTT", "GTA"]),
        AminoAcidOption(singleLetter: "*", threeLetter: "Ter", chineseName: "终止子", preferredCodon: "TAA", allCodons: ["TAA", "TGA", "TAG"])
    ]
    
    /// 翻译单个三联体密码子
    public static func translateTriplet(_ triplet: String) -> (Character, String) {
        let clean = triplet.uppercased().replacingOccurrences(of: "U", with: "T")
        return standardTable[clean] ?? ("X", "Unk")
    }
    
    /// 将一段 DNA 序列按指定阅读框偏移 (0, 1, 2) 翻译为氨基酸序列数组
    public static func translateSequence(
        _ dna: String,
        readingFrameOffset: Int = 0
    ) -> [TranslatedCodonItem] {
        let chars = Array(BioSequence.clean(dna))
        let safeOffset = max(0, min(2, readingFrameOffset))
        guard chars.count >= safeOffset + 3 else { return [] }
        
        var items: [TranslatedCodonItem] = []
        var idx = safeOffset
        while idx + 2 < chars.count {
            let codonStr = String(chars[idx...(idx + 2)])
            let (aa, three) = translateTriplet(codonStr)
            items.append(
                TranslatedCodonItem(
                    baseOffset: idx,
                    codon: codonStr,
                    aminoAcid: aa,
                    threeLetterCode: three,
                    isStartCodon: codonStr == "ATG",
                    isStopCodon: aa == "*"
                )
            )
            idx += 3
        }
        return items
    }
}

/// 预览界面交互式选择密码子/氨基酸进行突变的回调负载
public struct InteractiveCodonMutationPayload: Sendable {
    public let windowTitle: String
    /// 该密码子在全局质粒或窗口中的 1-based 起始与终止坐标
    public let startBp: Int
    public let endBp: Int
    /// 在当前基因/窗口中的第几个氨基酸 (1-based)
    public let residueIndex1Based: Int
    public let wildTypeCodon: String
    public let wildTypeAA: Character
    public let targetCodon: String // 空字符串表示缺失 (Δ)
    public let targetAA: String
    /// 自动从所在序列截取出的上游 60 bp 与下游 60 bp 野生型序列
    public let upstreamFlank60Bp: String
    public let downstreamFlank60Bp: String
    
    public init(
        windowTitle: String,
        startBp: Int,
        endBp: Int,
        residueIndex1Based: Int,
        wildTypeCodon: String,
        wildTypeAA: Character,
        targetCodon: String,
        targetAA: String,
        upstreamFlank60Bp: String,
        downstreamFlank60Bp: String
    ) {
        self.windowTitle = windowTitle
        self.startBp = startBp
        self.endBp = endBp
        self.residueIndex1Based = residueIndex1Based
        self.wildTypeCodon = wildTypeCodon
        self.wildTypeAA = wildTypeAA
        self.targetCodon = targetCodon
        self.targetAA = targetAA
        self.upstreamFlank60Bp = upstreamFlank60Bp
        self.downstreamFlank60Bp = downstreamFlank60Bp
    }
}

// MARK: - 2. 微观序列窗口与酶切/同源臂标注模型

/// 确定性 UUID 生成器：基于稳定的内容字符串生成固定 UUID，避免 SwiftUI 重绘时因随机 UUID() 导致视图树销毁闪烁
public enum DeterministicUUID {
    public static func from(_ seed: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x84222325cbf29ce4
        for byte in seed.utf8 {
            h1 ^= UInt64(byte)
            h1 = h1 &* 0x100000001b3
            h2 ^= UInt64(byte)
            h2 = h2 &* 0x100000001b3
            h2 = (h2 << 13) | (h2 >> 51)
        }
        var bytes: uuid_t = (
            UInt8((h1 >> 56) & 0xFF), UInt8((h1 >> 48) & 0xFF),
            UInt8((h1 >> 40) & 0xFF), UInt8((h1 >> 32) & 0xFF),
            UInt8((h1 >> 24) & 0xFF), UInt8((h1 >> 16) & 0xFF),
            UInt8(((h1 >> 8) & 0x0F) | 0x50), UInt8(h1 & 0xFF),
            UInt8(((h2 >> 56) & 0x3F) | 0x80), UInt8((h2 >> 48) & 0xFF),
            UInt8((h2 >> 40) & 0xFF), UInt8((h2 >> 32) & 0xFF),
            UInt8((h2 >> 24) & 0xFF), UInt8((h2 >> 16) & 0xFF),
            UInt8((h2 >> 8) & 0xFF), UInt8(h2 & 0xFF)
        )
        return withUnsafePointer(to: &bytes) { ptr in
            UUID(uuid: ptr.pointee)
        }
    }
}

/// 限制性内切酶或定点劈开裂解切口 (1:1 OVE topSnipPosition / bottomSnipPosition)
public struct MicroscopicEnzymeCut: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    /// 上链切口位于第几个碱基处 (0-based 偏移)
    public let topSnipOffset: Int
    /// 下链切口位于第几个碱基处 (0-based 偏移)
    public let bottomSnipOffset: Int
    /// 识别序列在窗口内的 0-based 范围
    public let recognitionRange: Range<Int>?
    /// 颜色 Hex
    public let colorHex: String
    
    public init(
        id: UUID? = nil,
        name: String,
        topSnipOffset: Int,
        bottomSnipOffset: Int,
        recognitionRange: Range<Int>? = nil,
        colorHex: String = "#F87171"
    ) {
        self.id = id ?? DeterministicUUID.from("cut_\(name)_\(topSnipOffset)_\(bottomSnipOffset)")
        self.name = name
        self.topSnipOffset = topSnipOffset
        self.bottomSnipOffset = bottomSnipOffset
        self.recognitionRange = recognitionRange
        self.colorHex = colorHex
    }
}

/// 引物在微观序列行上的覆盖标注（区分 5' 同源臂与 3' 退火结合区）
public struct MicroscopicPrimerOverlay: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let isForward: Bool
    /// 窗口内 0-based 覆盖起点
    public let startOffset: Int
    /// 窗口内 0-based 覆盖终点 (exclusive)
    public let endOffset: Int
    /// 5' 同源臂长度（如 18 bp）
    public let homologyArmLength: Int
    public let tmText: String
    public let sequence: String
    
    public init(
        id: UUID? = nil,
        name: String,
        isForward: Bool,
        startOffset: Int,
        endOffset: Int,
        homologyArmLength: Int = 18,
        tmText: String,
        sequence: String
    ) {
        self.id = id ?? DeterministicUUID.from("primer_\(name)_\(isForward)_\(startOffset)_\(endOffset)")
        self.name = name
        self.isForward = isForward
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.homologyArmLength = homologyArmLength
        self.tmText = tmText
        self.sequence = sequence
    }
}

/// 单个微观审图焦点窗口（如 5' 重组接头、3' 重组接头、定点突变位点、大片段删除接缝）
public struct MicroscopicSequenceWindow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let subtitle: String
    /// 该窗口在完整质粒中的 1-based 起始坐标
    public let startBp: Int
    /// 正义链序列 (5' -> 3')
    public let sequence: String
    /// 18 bp 同源臂或同源重叠区在窗口内的 0-based 范围
    public let homologyHighlightRange: Range<Int>?
    public let homologyLabel: String
    /// 突变碱基 / 插入边界 / 敲除接缝在窗口内的 0-based 范围
    public let focalHighlightRange: Range<Int>?
    public let focalLabel: String
    public let enzymeCuts: [MicroscopicEnzymeCut]
    public let primers: [MicroscopicPrimerOverlay]
    public let readingFrameOffset: Int
    
    public var endBp: Int {
        startBp + max(0, sequence.count - 1)
    }
    
    public init(
        id: UUID? = nil,
        title: String,
        subtitle: String = "",
        startBp: Int,
        sequence: String,
        homologyHighlightRange: Range<Int>? = nil,
        homologyLabel: String = "18 bp 同源臂",
        focalHighlightRange: Range<Int>? = nil,
        focalLabel: String = "",
        enzymeCuts: [MicroscopicEnzymeCut] = [],
        primers: [MicroscopicPrimerOverlay] = [],
        readingFrameOffset: Int = 0
    ) {
        self.id = id ?? DeterministicUUID.from("win_\(title)_\(startBp)_\(sequence.count)")
        self.title = title
        self.subtitle = subtitle
        self.startBp = max(1, startBp)
        self.sequence = BioSequence.clean(sequence)
        self.homologyHighlightRange = homologyHighlightRange
        self.homologyLabel = homologyLabel
        self.focalHighlightRange = focalHighlightRange
        self.focalLabel = focalLabel
        self.enzymeCuts = enzymeCuts
        self.primers = primers
        self.readingFrameOffset = readingFrameOffset
    }
}

// MARK: - 3. 行切片与像素防碰撞解算器 (Ported from CloneCanvas utils/rowRender.ts)

public struct SequenceRowSlice: Identifiable, Sendable, Equatable {
    /// 使用稳定的 rowIndex 作为 Identifiable ID，彻底避免选区变化时 SwiftUI 销毁重建行视图打断拖拽手势
    public var id: Int { rowIndex }
    public let rowIndex: Int
    /// 质粒全局 1-based 起点
    public let startBp: Int
    /// 质粒全局 1-based 终点
    public let endBp: Int
    /// 窗口内 0-based 起始偏移
    public let windowOffsetStart: Int
    /// 窗口内 0-based 结束偏移 (exclusive)
    public let windowOffsetEnd: Int
    public let topStrand: String
    public let bottomStrand: String
    public let codons: [TranslatedCodonItem]
}

public enum SequenceRowLayout {
    public static let defaultCharWidth: Double = 9.2
    public static let defaultLeftMargin: Double = 36.0
    public static let defaultRightMargin: Double = 42.0
    
    /// 根据容器可用像素宽度自适应计算每行最佳碱基数（强制对齐 3 的整数倍以保证密码子不跨行截断）
    public static func optimalBasesPerRow(
        forWidth width: Double,
        leftMargin: Double = defaultLeftMargin,
        rightMargin: Double = defaultRightMargin,
        charWidth: Double = defaultCharWidth
    ) -> Int {
        let usable = max(160.0, width - leftMargin - rightMargin)
        let rawCount = Int(floor(usable / max(7.0, charWidth)))
        let aligned3 = (rawCount / 3) * 3
        return max(18, min(90, aligned3))
    }
    
    /// 计算选中序列片段的解链温度 Tm (°C) (统一调用 SantaLucia 1998 近邻热力学模型)
    public static func estimateSelectionTm(_ dna: String) -> Int {
        let clean = BioSequence.clean(dna)
        guard !clean.isEmpty else { return 0 }
        let res = TmCalculator.calculate(sequence: clean)
        return max(0, Int(res.tm.rounded()))
    }
    
    /// 计算行内第 charOffset (0-based) 个碱基左边缘的 X 像素坐标
    public static func basePixelX(
        charOffset0Based: Int,
        leftMargin: Double = defaultLeftMargin,
        charWidth: Double = defaultCharWidth
    ) -> Double {
        leftMargin + Double(charOffset0Based) * charWidth
    }
    
    /// 线性区间重叠检测
    public static func rangesOverlap(
        _ r1: (start: Int, end: Int),
        _ r2: (start: Int, end: Int)
    ) -> Bool {
        max(r1.start, r2.start) <= min(r1.end, r2.end)
    }
    
    /// 1:1 OVE 行内注释轨道垂直分层 (calculateRowYOffsets)
    public static func calculateRowYOffsets(
        intervals: [(id: String, start: Int, end: Int)]
    ) -> [String: Int] {
        let sorted = intervals.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        var levels: [[(start: Int, end: Int)]] = []
        var result: [String: Int] = [:]
        
        for item in sorted {
            var yOffset = 0
            while yOffset < levels.count {
                let blocked = levels[yOffset].contains { other in
                    rangesOverlap((item.start, item.end), other)
                }
                if !blocked { break }
                yOffset += 1
            }
            if yOffset == levels.count {
                levels.append([])
            }
            levels[yOffset].append((item.start, item.end))
            result[item.id] = yOffset
        }
        return result
    }
    
    /// 1:1 OVE 标签水平碰撞检测与垂直堆叠 (calculateLabelYOffsets)
    public static func calculateLabelYOffsets(
        items: [(id: String, x0: Double, x1: Double, text: String)]
    ) -> [String: Int] {
        let expanded = items.map { it -> (id: String, x0: Double, x1: Double) in
            let minW = Double(CircularGeometry.visualTextLength(it.text)) * 6.0
            return (it.id, it.x0, max(it.x1, it.x0 + minW))
        }.sorted { $0.x0 < $1.x0 }
        
        var levels: [[(x0: Double, x1: Double)]] = []
        var out: [String: Int] = [:]
        
        for it in expanded {
            var yOffset = 0
            while yOffset < levels.count {
                let hit = levels[yOffset].contains { other in
                    max(it.x0, other.x0) <= min(it.x1, other.x1)
                }
                if !hit { break }
                yOffset += 1
            }
            if yOffset == levels.count {
                levels.append([])
            }
            levels[yOffset].append((it.x0, it.x1))
            out[it.id] = yOffset
        }
        return out
    }
    
    /// 将微观序列窗口按每行指定碱基数 (默认 36 bp) 切分为单行绘制切片
    public static func sliceWindow(
        _ window: MicroscopicSequenceWindow,
        basesPerRow: Int = 36
    ) -> [SequenceRowSlice] {
        let safePerRow = max(12, basesPerRow)
        let cleanTop = BioSequence.clean(window.sequence)
        let cleanBot = BioSequence.complement(cleanTop)
        let topChars = Array(cleanTop)
        let botChars = Array(cleanBot)
        guard !topChars.isEmpty else { return [] }
        
        let allCodons = CodonTranslator.translateSequence(
            cleanTop,
            readingFrameOffset: window.readingFrameOffset
        )
        
        var slices: [SequenceRowSlice] = []
        slices.reserveCapacity((topChars.count + safePerRow - 1) / safePerRow)
        var offset = 0
        var rowIdx = 0
        var codonCursor = 0
        let codonCount = allCodons.count
        
        while offset < topChars.count {
            let endOff = min(offset + safePerRow, topChars.count)
            let rowTop = String(topChars[offset..<endOff])
            let rowBot = String(botChars[offset..<endOff])
            
            while codonCursor < codonCount && allCodons[codonCursor].baseOffset < offset {
                codonCursor += 1
            }
            var rowCodons: [TranslatedCodonItem] = []
            var scanIdx = codonCursor
            while scanIdx < codonCount && (allCodons[scanIdx].baseOffset + 3) <= endOff {
                rowCodons.append(allCodons[scanIdx])
                scanIdx += 1
            }
            
            let sBp = window.startBp + offset
            let eBp = window.startBp + endOff - 1
            
            slices.append(
                SequenceRowSlice(
                    rowIndex: rowIdx,
                    startBp: sBp,
                    endBp: eBp,
                    windowOffsetStart: offset,
                    windowOffsetEnd: endOff,
                    topStrand: rowTop,
                    bottomStrand: rowBot,
                    codons: rowCodons
                )
            )
            offset = endOff
            rowIdx += 1
        }
        return slices
    }
}
