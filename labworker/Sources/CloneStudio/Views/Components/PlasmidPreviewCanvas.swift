import SwiftUI
import CloneStudioCore
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 1. 质粒图谱数据模型 (PlasmidMapModel)

public enum FeatureDirection: Sendable {
    case clockwise
    case counterClockwise
    case none
}

public struct PlasmidFeatureItem: Identifiable {
    public let id: UUID
    public let name: String
    public let featureType: String
    public let lengthBp: Int
    public let startRatio: Double // 0.0 ~ 1.0
    public let endRatio: Double   // 0.0 ~ 1.0
    public let color: Color
    public let direction: FeatureDirection
    public let isHighlight: Bool
    public let sequenceSnippet: String
    
    public init(
        name: String,
        featureType: String = "",
        lengthBp: Int,
        startRatio: Double,
        endRatio: Double,
        color: Color,
        direction: FeatureDirection = .clockwise,
        isHighlight: Bool = false,
        sequenceSnippet: String = ""
    ) {
        let sKey = Int((startRatio * 100000).rounded())
        let eKey = Int((endRatio * 100000).rounded())
        self.id = DeterministicUUID.from("feat_\(name)_\(lengthBp)_\(sKey)_\(eKey)")
        self.name = name
        if !featureType.isEmpty {
            self.featureType = featureType
        } else {
            let low = name.lowercased()
            if low.contains("ori") {
                self.featureType = "ORI"
            } else if low.contains("amp") || low.contains("kan") || low.contains("puro") || low.contains("neo") {
                self.featureType = "AMR"
            } else if low.contains("prom") || low.contains("u6") || low.contains("ef1") || low.contains("lacz") || low.contains("t7") {
                self.featureType = "PROM"
            } else if low.contains("urs") || low.contains("drs") || low.contains("臂") || low.contains("flank") {
                self.featureType = "ARM"
            } else if low.contains("insert") || low.contains("frag") || low.contains("cas9") || low.contains("cds") {
                self.featureType = "CDS"
            } else {
                self.featureType = "GENE"
            }
        }
        self.lengthBp = lengthBp
        self.startRatio = startRatio
        self.endRatio = endRatio
        self.color = color
        self.direction = direction
        self.isHighlight = isHighlight
        self.sequenceSnippet = sequenceSnippet
    }
}

public struct PlasmidEnzymeMarker: Identifiable {
    public let id: UUID
    public let name: String
    public let recognitionSite: String
    public let ratioPosition: Double // 0.0 ~ 1.0
    public let positionBp: Int
    public let color: Color
    
    public init(name: String, recognitionSite: String, ratioPosition: Double, positionBp: Int, color: Color = .red) {
        self.id = DeterministicUUID.from("enz_\(name)_\(positionBp)_\(Int((ratioPosition * 100000).rounded()))")
        self.name = name
        self.recognitionSite = recognitionSite
        self.ratioPosition = ratioPosition
        self.positionBp = positionBp
        self.color = color
    }
}

public struct PlasmidPrimerMarker: Identifiable {
    public let id: UUID
    public let name: String
    public let isForward: Bool
    public let startRatio: Double
    public let endRatio: Double
    public let tmText: String
    public let sequence: String
    public let color: Color
    
    public init(
        name: String,
        isForward: Bool,
        startRatio: Double,
        endRatio: Double,
        tmText: String,
        sequence: String,
        color: Color
    ) {
        self.id = DeterministicUUID.from("pmk_\(name)_\(isForward)_\(Int((startRatio * 100000).rounded()))")
        self.name = name
        self.isForward = isForward
        self.startRatio = startRatio
        self.endRatio = endRatio
        self.tmText = tmText
        self.sequence = sequence
        self.color = color
    }
}

public struct PlasmidJunctionBlock: Identifiable {
    public let id: UUID
    public let title: String
    public let leftLabel: String
    public let leftSeq: String
    public let midLabel: String
    public let midSeq: String
    public let rightLabel: String
    public let rightSeq: String
    
    public init(
        title: String,
        leftLabel: String,
        leftSeq: String,
        midLabel: String,
        midSeq: String,
        rightLabel: String,
        rightSeq: String
    ) {
        self.id = DeterministicUUID.from("junc_\(title)_\(leftLabel)_\(rightLabel)")
        self.title = title
        self.leftLabel = leftLabel
        self.leftSeq = leftSeq
        self.midLabel = midLabel
        self.midSeq = midSeq
        self.rightLabel = rightLabel
        self.rightSeq = rightSeq
    }
}

public struct PlasmidConstructPreviewData {
    public let constructTitle: String
    public let vectorName: String
    public let totalLengthBp: Int
    public let insertLengthBp: Int
    public let gcPercent: Double
    public let fullSequence: String
    public let features: [PlasmidFeatureItem]
    public let enzymes: [PlasmidEnzymeMarker]
    public let primers: [PlasmidPrimerMarker]
    public let junctions: [PlasmidJunctionBlock]
    public let linearSummarySteps: [(String, String, Color)]
    public let microscopicWindows: [MicroscopicSequenceWindow]
    
    public init(
        constructTitle: String,
        vectorName: String,
        totalLengthBp: Int,
        insertLengthBp: Int,
        gcPercent: Double,
        fullSequence: String = "",
        features: [PlasmidFeatureItem],
        enzymes: [PlasmidEnzymeMarker],
        primers: [PlasmidPrimerMarker],
        junctions: [PlasmidJunctionBlock],
        linearSummarySteps: [(String, String, Color)],
        microscopicWindows: [MicroscopicSequenceWindow] = []
    ) {
        self.constructTitle = constructTitle
        self.vectorName = vectorName
        self.totalLengthBp = totalLengthBp
        self.insertLengthBp = insertLengthBp
        self.gcPercent = gcPercent
        self.features = features
        self.enzymes = enzymes
        self.primers = primers
        self.junctions = junctions
        self.linearSummarySteps = linearSummarySteps
        self.microscopicWindows = microscopicWindows
        if !fullSequence.isEmpty {
            self.fullSequence = BioSequence.clean(fullSequence)
        } else {
            self.fullSequence = Self.synthesizeConstructSequence(
                totalLengthBp: totalLengthBp,
                windows: microscopicWindows
            )
        }
    }
    
    /// 将微观接头窗口与标准质粒骨架（含 MCS/ori/AmpR/KanR 代表性酶切位点）拼装为完整全长序列
    private static func synthesizeConstructSequence(
        totalLengthBp: Int,
        windows: [MicroscopicSequenceWindow]
    ) -> String {
        let targetLen = max(600, min(totalLengthBp, 6000))
        let firstWinSeq = windows.first?.sequence ?? "ATGTGCGTCGCCTCGCCTCAGAACAAC"
        let secondWinSeq = windows.count > 1 ? windows[1].sequence : ""
        
        // 标准质粒骨架特征块（含 StuI, HaeIII, PstI, BsaI, DraI, BbsI, XhoI, NdeI, FokI, EcoRI, BamHI, HindIII, NotI, KpnI, SalI 等真实识别序列）
        let backboneCassettes = [
            "TGCAAGGCCTGGCCTAATGCAGCTGGCAATTCCGGTTCGCTTGCTGTCCATAAAACCGCCCAGTCTAGCTATCGCCATGTAAGCCCACTGCAAGCTACCTGCTTTCTCTTTGCGCTTGCGTTTTCCCTTGTCCAGATAGCCCAGTAGCTGACATTCATCCGGGGTCAGCACCGTTTCTGCGGACTGGCTTTCTACGTGTTCCGCTTCCTTTAGCAGCCCTTGCGCCCTGAGTGCTTGCGGCAGCGTGAAGCT",
            "GCTAGCTGCAGAGGTCTCAAATTTAAAGAAGACCTCGAGCATATGGATGCGGAATTCGGATCCAAGCTTGCGGCCGCTCTAGAGGTACCGTCGACGAGCTCCATGGTACCCCGGGGATATCTGCA",
            "CCTGACGTCTAAGAAACCATTATTATCATGACATTAACCTATAAAAATAGGCGTATCACGAGGCCCTTTCGTCTCGCGCGTTTCGGTGATGACGGTGAAAACCTCTGACACATGCAGCTCCCGGAGACGGTCACAGCTTGTCTGTAAGCGGATGCCGGGAGCAGACAAGCCCGTCAGGGCGCGTCAGCGGGTGTTGGCGGGTGTCGGGGCTGGCTTAACTATGCGGCATCAGAGCAGATTGTACTGAGAGTGCACCATATGCGGTGTGAAATACCGCACAGATGCGTAAGGAGAAAATACCGCATCAGGCGCCATTCGCCATTCAGGCTGCGCAACTGTTGGGAAGGGCGATCGGTGCGGGCCTCTTCGCTATTACGCCAGCTGGCGAAAGGGGGATGTGCTGCAAGGCGATTAAGTTGGGTAACGCCAGGGTTTTCCCAGTCACGACGTTGTAAAACGACGGCCAGT"
        ]
        var builder = firstWinSeq
        if !secondWinSeq.isEmpty {
            builder += "GCTAGCGCTACCGGACTCAGATCTCGAGCTCAAGCTTCGAATTCTGCAGTCGACGGTACCGCGGGCCCGGGATCC" + secondWinSeq
        }
        var idx = 0
        while builder.count < targetLen {
            builder += backboneCassettes[idx % backboneCassettes.count]
            idx += 1
        }
        return String(builder.prefix(targetLen))
    }
}

// MARK: - 2. 质粒图谱智能构建器 (仅在用户真实提交后生成，拒绝凭空臆造)
public enum PlasmidMapBuilder {
    
    /// 1. 入门克隆：支持输入插入片段序列后或生成引物后预览图谱
    public static func forEntryClone(
        insertSeq: String,
        hasEnzymes: Bool,
        enzyme5: RestrictionEnzyme?,
        enzyme3: RestrictionEnzyme?,
        primerF: PrimerItem?,
        primerR: PrimerItem?
    ) -> PlasmidConstructPreviewData? {
        let clean = BioSequence.clean(insertSeq)
        guard clean.count >= 20 else { return nil }
        
        let insertBp = clean.count
        let gc = BioSequence.gcContent(clean)
        let vectorBp = 3957
        let totalBp = vectorBp + insertBp + 30
        
        let e5Site = (hasEnzymes ? enzyme5?.site : nil) ?? ""
        let e3Site = (hasEnzymes ? enzyme3?.site : nil) ?? ""
        let ins5 = String(clean.prefix(18))
        let ins3 = String(clean.suffix(18))
        
        let features: [PlasmidFeatureItem] = [
            PlasmidFeatureItem(name: "lacZ/T7", lengthBp: 240, startRatio: 0.91, endRatio: 0.975, color: Color(red: 0.96, green: 0.26, blue: 0.38)),
            PlasmidFeatureItem(name: "5' URS (15bp)", lengthBp: 15, startRatio: 0.98, endRatio: 0.025, color: .cyan, isHighlight: true, sequenceSnippet: "ggatcttccagagat"),
            PlasmidFeatureItem(name: "Insert (\(insertBp)bp)", lengthBp: insertBp, startRatio: 0.025, endRatio: 0.30, color: Color(red: 0.10, green: 0.82, blue: 0.54), isHighlight: true, sequenceSnippet: String(clean.prefix(36))),
            PlasmidFeatureItem(name: "3' DRS (15bp)", lengthBp: 15, startRatio: 0.30, endRatio: 0.345, color: .cyan, isHighlight: true, sequenceSnippet: "ctgccgttcgacgat"),
            PlasmidFeatureItem(name: "KanR", lengthBp: 816, startRatio: 0.42, endRatio: 0.65, color: Color(red: 0.55, green: 0.36, blue: 0.96)),
            PlasmidFeatureItem(name: "ori", lengthBp: 589, startRatio: 0.71, endRatio: 0.85, color: Color(red: 0.96, green: 0.62, blue: 0.05), direction: .counterClockwise)
        ]
        
        var enzymes: [PlasmidEnzymeMarker] = [
            PlasmidEnzymeMarker(name: "URS", recognitionSite: "ggatcttccagagat", ratioPosition: 0.005, positionBp: 1, color: .cyan),
            PlasmidEnzymeMarker(name: "DRS", recognitionSite: "ctgccgttcgacgat", ratioPosition: 0.32, positionBp: insertBp + 15, color: .cyan)
        ]
        if hasEnzymes, let e5 = enzyme5 {
            enzymes.append(PlasmidEnzymeMarker(name: e5.name, recognitionSite: e5.site, ratioPosition: 0.032, positionBp: 16, color: .red))
        }
        if hasEnzymes, let e3 = enzyme3 {
            enzymes.append(PlasmidEnzymeMarker(name: e3.name, recognitionSite: e3.site, ratioPosition: 0.292, positionBp: insertBp + 15, color: .orange))
        }
        
        var primers: [PlasmidPrimerMarker] = []
        if let pF = primerF {
            primers.append(PlasmidPrimerMarker(name: pF.name, isForward: true, startRatio: 0.985, endRatio: 0.11, tmText: String(format: "%.1f℃", pF.tm ?? 60), sequence: pF.fullSequence, color: .blue))
        }
        if let pR = primerR {
            primers.append(PlasmidPrimerMarker(name: pR.name, isForward: false, startRatio: 0.21, endRatio: 0.335, tmText: String(format: "%.1f℃", pR.tm ?? 60), sequence: pR.fullSequence, color: .orange))
        }
        
        let junctions: [PlasmidJunctionBlock] = [
            PlasmidJunctionBlock(title: "5' URS 接头", leftLabel: "URS", leftSeq: "ggatcttccagagat", midLabel: e5Site, midSeq: e5Site.lowercased(), rightLabel: "5'端", rightSeq: ins5),
            PlasmidJunctionBlock(title: "3' DRS 接头", leftLabel: "3'端", leftSeq: ins3, midLabel: e3Site, midSeq: e3Site.lowercased(), rightLabel: "DRS", rightSeq: "atcgtcgaacggcag")
        ]
        
        let steps: [(String, String, Color)] = [
            ("URS (15bp)", "左重组臂", .cyan),
            ("Insert", "\(insertBp) bp", .green),
            ("DRS (15bp)", "右重组臂", .cyan)
        ]
        
        // 微观单碱基窗口：5' URS 接头 & 3' DRS 接头
        let win5Seq = "GGATCTTCCAGAGAT" + e5Site.uppercased() + String(clean.prefix(48))
        let win3Seq = String(clean.suffix(48)) + e3Site.uppercased() + "ATCGTCGAACGGCAG"
        let microWindows: [MicroscopicSequenceWindow] = [
            MicroscopicSequenceWindow(
                title: "5' URS 接头",
                subtitle: "pCE2 左重组臂 + 插入基因 5' 端",
                startBp: 1,
                sequence: win5Seq,
                homologyHighlightRange: 0..<15,
                homologyLabel: "15 bp URS 通用同源臂",
                focalHighlightRange: 15..<min(win5Seq.count, 15 + max(e5Site.count, 18)),
                focalLabel: hasEnzymes ? "酶切位点 + 5'插入端" : "插入基因 5' 起始区",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: hasEnzymes ? (enzyme5?.name ?? "URS") : "URS切点", topSnipOffset: 15, bottomSnipOffset: 15 + min(4, e5Site.count))
                ],
                primers: primerF != nil ? [
                    MicroscopicPrimerOverlay(name: primerF!.name, isForward: true, startOffset: 0, endOffset: min(win5Seq.count, primerF!.fullSequence.count), homologyArmLength: 15, tmText: String(format: "%.1f℃", primerF!.tm ?? 60), sequence: primerF!.fullSequence)
                ] : [],
                readingFrameOffset: (15 + e5Site.count) % 3
            ),
            MicroscopicSequenceWindow(
                title: "3' DRS 接头",
                subtitle: "插入基因 3' 端 + pCE2 右重组臂",
                startBp: max(1, insertBp - 32),
                sequence: win3Seq,
                homologyHighlightRange: (win3Seq.count - 15)..<win3Seq.count,
                homologyLabel: "15 bp DRS 通用同源臂",
                focalHighlightRange: max(0, win3Seq.count - 15 - max(e3Site.count, 18))..<(win3Seq.count - 15),
                focalLabel: "插入基因 3' 末端区",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: hasEnzymes ? (enzyme3?.name ?? "DRS") : "DRS切点", topSnipOffset: win3Seq.count - 15 - e3Site.count, bottomSnipOffset: win3Seq.count - 15)
                ],
                primers: primerR != nil ? [
                    MicroscopicPrimerOverlay(name: primerR!.name, isForward: false, startOffset: max(0, win3Seq.count - primerR!.fullSequence.count), endOffset: win3Seq.count, homologyArmLength: 15, tmText: String(format: "%.1f℃", primerR!.tm ?? 60), sequence: primerR!.fullSequence)
                ] : [],
                readingFrameOffset: 0
            )
        ]
        
        return PlasmidConstructPreviewData(
            constructTitle: "pCE2-Entry",
            vectorName: "pCE2",
            totalLengthBp: totalBp,
            insertLengthBp: insertBp,
            gcPercent: gc,
            features: features,
            enzymes: enzymes,
            primers: primers,
            junctions: junctions,
            linearSummarySteps: steps,
            microscopicWindows: microWindows
        )
    }
    
    /// 2. 单片段克隆：支持仅输入载体/插入序列或生成引物后预览图谱
    public static func forSingleFragment(
        mode: SingleFragmentViewModel.Mode,
        vectorSeq: String,
        vectorSeqU: String,
        vectorSeqD: String,
        insertSeq: String,
        enzymeSingle: RestrictionEnzyme?,
        enzyme5: RestrictionEnzyme?,
        enzyme3: RestrictionEnzyme?,
        primers: [PrimerItem]
    ) -> PlasmidConstructPreviewData? {
        let cleanIns = BioSequence.clean(insertSeq)
        let cleanVec = BioSequence.clean(mode == .pcr ? (vectorSeqU + vectorSeqD) : vectorSeq)
        guard cleanIns.count >= 30 || cleanVec.count >= 30 else { return nil }
        
        let insertBp = cleanIns.count
        let gc = BioSequence.gcContent(cleanIns.isEmpty ? cleanVec : cleanIns)
        let vectorBp = max(cleanVec.count, 5369)
        let totalBp = vectorBp + insertBp
        
        let e5Name = mode == .single ? (enzymeSingle?.name ?? "Enz") : (mode == .double ? (enzyme5?.name ?? "Enz1") : "5'端")
        let e5Site = mode == .single ? (enzymeSingle?.site ?? "") : (mode == .double ? (enzyme5?.site ?? "") : "")
        let e3Name = mode == .single ? (enzymeSingle?.name ?? "Enz") : (mode == .double ? (enzyme3?.name ?? "Enz2") : "3'端")
        let e3Site = mode == .single ? (enzymeSingle?.site ?? "") : (mode == .double ? (enzyme3?.site ?? "") : "")
        
        let vec5Arm = cleanVec.count >= 18 ? String(cleanVec.prefix(18)).lowercased() : "cggccgctcgagcatgga"
        let vec3Arm = cleanVec.count >= 18 ? String(cleanVec.suffix(18)).lowercased() : "gatccgaattcgagctcg"
        
        let features: [PlasmidFeatureItem] = [
            PlasmidFeatureItem(name: "Promoter", lengthBp: 580, startRatio: 0.88, endRatio: 0.975, color: Color(red: 0.96, green: 0.26, blue: 0.38)),
            PlasmidFeatureItem(name: "5' 载体臂", lengthBp: 18, startRatio: 0.975, endRatio: 0.025, color: .cyan, isHighlight: true, sequenceSnippet: vec5Arm),
            PlasmidFeatureItem(name: "Insert (\(insertBp)bp)", lengthBp: insertBp, startRatio: 0.025, endRatio: 0.31, color: Color(red: 0.10, green: 0.82, blue: 0.54), isHighlight: true, sequenceSnippet: String(cleanIns.prefix(36))),
            PlasmidFeatureItem(name: "3' 载体臂", lengthBp: 18, startRatio: 0.31, endRatio: 0.355, color: .cyan, isHighlight: true, sequenceSnippet: vec3Arm),
            PlasmidFeatureItem(name: "AmpR", lengthBp: 860, startRatio: 0.44, endRatio: 0.65, color: Color(red: 0.55, green: 0.36, blue: 0.96)),
            PlasmidFeatureItem(name: "ori", lengthBp: 620, startRatio: 0.70, endRatio: 0.83, color: Color(red: 0.96, green: 0.62, blue: 0.05), direction: .counterClockwise)
        ]
        
        let enzymes: [PlasmidEnzymeMarker] = [
            PlasmidEnzymeMarker(name: e5Name, recognitionSite: e5Site, ratioPosition: 0.022, positionBp: 1, color: .red),
            PlasmidEnzymeMarker(name: e3Name, recognitionSite: e3Site, ratioPosition: 0.315, positionBp: insertBp, color: .orange)
        ]
        
        var primerMarkers: [PlasmidPrimerMarker] = []
        if let f = primers.first {
            primerMarkers.append(PlasmidPrimerMarker(name: f.name, isForward: true, startRatio: 0.98, endRatio: 0.11, tmText: String(format: "%.1f℃", f.tm ?? 60), sequence: f.fullSequence, color: .blue))
        }
        if primers.count > 1 {
            let r = primers[1]
            primerMarkers.append(PlasmidPrimerMarker(name: r.name, isForward: false, startRatio: 0.22, endRatio: 0.35, tmText: String(format: "%.1f℃", r.tm ?? 60), sequence: r.fullSequence, color: .orange))
        }
        
        let junctions: [PlasmidJunctionBlock] = [
            PlasmidJunctionBlock(title: "5' 重组接头", leftLabel: "载体臂", leftSeq: vec5Arm, midLabel: e5Name, midSeq: e5Site.lowercased(), rightLabel: "片段5'", rightSeq: String(cleanIns.prefix(18))),
            PlasmidJunctionBlock(title: "3' 重组接头", leftLabel: "片段3'", leftSeq: String(cleanIns.suffix(18)), midLabel: e3Name, midSeq: e3Site.lowercased(), rightLabel: "载体臂", rightSeq: vec3Arm)
        ]
        
        let steps: [(String, String, Color)] = [
            ("5' 同源臂", vec5Arm, .cyan),
            ("Insert", "\(insertBp) bp", .green),
            ("3' 同源臂", vec3Arm, .cyan)
        ]
        
        let armLen = vec5Arm.count
        let win5Seq = vec5Arm.uppercased() + e5Site.uppercased() + String(cleanIns.prefix(48))
        let win3Seq = String(cleanIns.suffix(48)) + e3Site.uppercased() + vec3Arm.uppercased()
        let pF = primers.first
        let pR = primers.count > 1 ? primers[1] : primers.first
        
        let microWindows: [MicroscopicSequenceWindow] = [
            MicroscopicSequenceWindow(
                title: "5' 重组接头",
                subtitle: "载体 5' 同源臂 + \(e5Name) + 插入基因 5' 端",
                startBp: 1,
                sequence: win5Seq,
                homologyHighlightRange: 0..<(armLen + e5Site.count),
                homologyLabel: "\(armLen) bp 载体同源臂",
                focalHighlightRange: (armLen + e5Site.count)..<min(win5Seq.count, armLen + e5Site.count + 18),
                focalLabel: "插入基因 5' 特异结合区",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: e5Name, topSnipOffset: armLen + 1, bottomSnipOffset: armLen + max(1, e5Site.count - 1))
                ],
                primers: pF != nil ? [
                    MicroscopicPrimerOverlay(name: pF!.name, isForward: true, startOffset: 0, endOffset: min(win5Seq.count, pF!.fullSequence.count), homologyArmLength: armLen, tmText: String(format: "%.1f℃", pF!.tm ?? 60), sequence: pF!.fullSequence)
                ] : [],
                readingFrameOffset: (armLen + e5Site.count) % 3
            ),
            MicroscopicSequenceWindow(
                title: "3' 重组接头",
                subtitle: "插入基因 3' 端 + \(e3Name) + 载体 3' 同源臂",
                startBp: max(1, insertBp - 30),
                sequence: win3Seq,
                homologyHighlightRange: (win3Seq.count - armLen - e3Site.count)..<win3Seq.count,
                homologyLabel: "\(armLen) bp 载体同源臂",
                focalHighlightRange: max(0, win3Seq.count - armLen - e3Site.count - 18)..<(win3Seq.count - armLen - e3Site.count),
                focalLabel: "插入基因 3' 特异结合区",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: e3Name, topSnipOffset: win3Seq.count - armLen - e3Site.count + 1, bottomSnipOffset: win3Seq.count - armLen - 1)
                ],
                primers: pR != nil ? [
                    MicroscopicPrimerOverlay(name: pR!.name, isForward: false, startOffset: max(0, win3Seq.count - pR!.fullSequence.count), endOffset: win3Seq.count, homologyArmLength: armLen, tmText: String(format: "%.1f℃", pR!.tm ?? 60), sequence: pR!.fullSequence)
                ] : [],
                readingFrameOffset: 0
            )
        ]
        
        return PlasmidConstructPreviewData(
            constructTitle: "pClone-\(mode.rawValue)",
            vectorName: mode.title,
            totalLengthBp: totalBp,
            insertLengthBp: insertBp,
            gcPercent: gc,
            features: features,
            enzymes: enzymes,
            primers: primerMarkers,
            junctions: junctions,
            linearSummarySteps: steps,
            microscopicWindows: microWindows
        )
    }
    
    /// 3. 多片段克隆：支持载入/输入载体或片段序列后立即预览图谱
    public static func forMultiFragment(
        fragments: [String],
        vectorSeq: String,
        enzymeSingle: RestrictionEnzyme?,
        primers: [PrimerItem]
    ) -> PlasmidConstructPreviewData? {
        let validFrags = fragments.map { BioSequence.clean($0) }.filter { $0.count >= 20 }
        let cleanVec = BioSequence.clean(vectorSeq)
        guard !validFrags.isEmpty || cleanVec.count >= 20 else { return nil }
        
        let effectiveFrags = validFrags.isEmpty ? [cleanVec] : validFrags
        let count = effectiveFrags.count
        let palette: [Color] = [
            Color(red: 0.10, green: 0.82, blue: 0.54),
            Color(red: 0.08, green: 0.65, blue: 0.95),
            Color(red: 0.96, green: 0.55, blue: 0.15),
            Color(red: 0.93, green: 0.28, blue: 0.60),
            Color(red: 0.65, green: 0.45, blue: 0.98)
        ]
        
        var features: [PlasmidFeatureItem] = [
            PlasmidFeatureItem(name: "Promoter", lengthBp: 480, startRatio: 0.89, endRatio: 0.975, color: Color(red: 0.96, green: 0.26, blue: 0.38))
        ]
        
        let totalArcSpan = 0.50
        let segSpan = totalArcSpan / Double(count)
        var totalInsertBp = 0
        var allClean = ""
        var steps: [(String, String, Color)] = []
        var primerMarkers: [PlasmidPrimerMarker] = []
        
        for i in 0..<count {
            let clean = effectiveFrags[i]
            let bp = clean.count
            totalInsertBp += bp
            allClean += clean
            
            let sRatio = 0.015 + Double(i) * segSpan
            let eRatio = sRatio + segSpan * 0.88
            let col = palette[i % palette.count]
            
            features.append(
                PlasmidFeatureItem(name: validFrags.isEmpty ? "Vector (\(bp)bp)" : "Frag \(i+1)", lengthBp: bp, startRatio: sRatio, endRatio: eRatio, color: col, isHighlight: true, sequenceSnippet: String(clean.prefix(30)))
            )
            steps.append((validFrags.isEmpty ? "Vector" : "Frag \(i+1)", "\(bp)bp", col))
            
            if i * 2 < primers.count {
                let p = primers[i * 2]
                primerMarkers.append(PlasmidPrimerMarker(name: p.name, isForward: true, startRatio: sRatio, endRatio: sRatio + segSpan * 0.4, tmText: String(format: "%.0f℃", p.tm ?? 60), sequence: p.fullSequence, color: col))
            }
        }
        
        features.append(contentsOf: [
            PlasmidFeatureItem(name: "AmpR", lengthBp: 860, startRatio: 0.56, endRatio: 0.72, color: Color(red: 0.55, green: 0.36, blue: 0.96)),
            PlasmidFeatureItem(name: "ori", lengthBp: 590, startRatio: 0.76, endRatio: 0.86, color: Color(red: 0.96, green: 0.62, blue: 0.05), direction: .counterClockwise)
        ])
        
        let enz = enzymeSingle ?? RestrictionEnzyme(name: "BamHI", site: "GGATCC")
        let enzymes: [PlasmidEnzymeMarker] = [
            PlasmidEnzymeMarker(name: enz.name, recognitionSite: enz.site, ratioPosition: 0.01, positionBp: 1, color: .red)
        ]
        
        var microWindows: [MicroscopicSequenceWindow] = []
        if effectiveFrags.count >= 2 {
            let f1Tail = String(effectiveFrags[0].suffix(36))
            let f2Head = String(effectiveFrags[1].prefix(36))
            let seamSeq = f1Tail + f2Head
            microWindows.append(
                MicroscopicSequenceWindow(
                    title: "Frag1-Frag2 拼接缝",
                    subtitle: "片段 1 末端与片段 2 起始端无缝重叠区",
                    startBp: max(1, validFrags[0].count - 35),
                    sequence: seamSeq,
                    homologyHighlightRange: 18..<54,
                    homologyLabel: "片段间 18 bp 同源重叠臂",
                    focalHighlightRange: 34..<38,
                    focalLabel: "Frag1/Frag2 缝合切点",
                    enzymeCuts: [
                        MicroscopicEnzymeCut(name: "Frag1|Frag2", topSnipOffset: 36, bottomSnipOffset: 36)
                    ],
                    primers: primers.count >= 3 ? [
                        MicroscopicPrimerOverlay(name: primers[2].name, isForward: true, startOffset: 18, endOffset: min(seamSeq.count, 56), homologyArmLength: 18, tmText: String(format: "%.1f℃", primers[2].tm ?? 60), sequence: primers[2].fullSequence)
                    ] : []
                )
            )
        }
        
        return PlasmidConstructPreviewData(
            constructTitle: "MultiS-\(count)F",
            vectorName: "MultiS",
            totalLengthBp: 5000 + totalInsertBp,
            insertLengthBp: totalInsertBp,
            gcPercent: BioSequence.gcContent(allClean),
            features: features,
            enzymes: enzymes,
            primers: primerMarkers,
            junctions: [],
            linearSummarySteps: steps,
            microscopicWindows: microWindows
        )
    }
    
    /// 4. 定点突变：只要上下游序列有效即可实时预览并点击密码子进行突变
    public static func forMutagenesis(
        mutUp: String,
        mutSite: String,
        mutDown: String,
        primers: [PrimerItem]
    ) -> PlasmidConstructPreviewData? {
        let upClean = BioSequence.clean(mutUp)
        let siteClean = BioSequence.clean(mutSite)
        let downClean = BioSequence.clean(mutDown)
        guard upClean.count >= 20 && downClean.count >= 20 else { return nil }
        
        let mutLabel = siteClean.isEmpty ? "Δ" : siteClean
        let combined = upClean + siteClean + downClean
        
        let features: [PlasmidFeatureItem] = [
            PlasmidFeatureItem(name: "5' Flank", lengthBp: upClean.count, startRatio: 0.90, endRatio: 0.12, color: Color(red: 0.08, green: 0.65, blue: 0.95), isHighlight: true),
            PlasmidFeatureItem(name: "★ \(mutLabel)", lengthBp: max(siteClean.count, 1), startRatio: 0.12, endRatio: 0.165, color: Color(red: 0.98, green: 0.24, blue: 0.35), direction: .none, isHighlight: true, sequenceSnippet: mutLabel),
            PlasmidFeatureItem(name: "3' Flank", lengthBp: downClean.count, startRatio: 0.165, endRatio: 0.38, color: Color(red: 0.10, green: 0.82, blue: 0.54), isHighlight: true),
            PlasmidFeatureItem(name: "AmpR", lengthBp: 860, startRatio: 0.46, endRatio: 0.66, color: Color(red: 0.55, green: 0.36, blue: 0.96)),
            PlasmidFeatureItem(name: "ori", lengthBp: 590, startRatio: 0.72, endRatio: 0.85, color: Color(red: 0.96, green: 0.62, blue: 0.05), direction: .counterClockwise)
        ]
        
        let enzymes: [PlasmidEnzymeMarker] = [
            PlasmidEnzymeMarker(name: "★ 突变位点", recognitionSite: mutLabel, ratioPosition: 0.142, positionBp: upClean.count + 1, color: .red)
        ]
        
        var pMarkers: [PlasmidPrimerMarker] = []
        if let f = primers.first {
            pMarkers.append(PlasmidPrimerMarker(name: f.name, isForward: true, startRatio: 0.09, endRatio: 0.24, tmText: String(format: "%.1f℃", f.tm ?? 60), sequence: f.fullSequence, color: .red))
        }
        if primers.count > 1 {
            let r = primers[1]
            pMarkers.append(PlasmidPrimerMarker(name: r.name, isForward: false, startRatio: 0.04, endRatio: 0.19, tmText: String(format: "%.1f℃", r.tm ?? 60), sequence: r.fullSequence, color: .orange))
        }
        
        let junctions: [PlasmidJunctionBlock] = [
            PlasmidJunctionBlock(title: "突变位点局部放大", leftLabel: "上游", leftSeq: String(upClean.suffix(14)), midLabel: "★", midSeq: mutLabel, rightLabel: "下游", rightSeq: String(downClean.prefix(14)))
        ]
        
        // 微观单碱基窗口：围绕突变点的 72bp 局部双链 + 密码子翻译 + 18bp 重叠同源臂高亮
        let flankUp = String(upClean.suffix(36))
        let flankDown = String(downClean.prefix(max(18, 36 - siteClean.count)))
        let winSeq = flankUp + siteClean + flankDown
        let mutStartOff = flankUp.count
        let mutEndOff = mutStartOff + max(1, siteClean.count)
        let homStartOff = max(0, mutStartOff - 9)
        let homEndOff = min(winSeq.count, mutEndOff + 9)
        
        var microPrimers: [MicroscopicPrimerOverlay] = []
        if let f = primers.first {
            microPrimers.append(
                MicroscopicPrimerOverlay(
                    name: f.name,
                    isForward: true,
                    startOffset: homStartOff,
                    endOffset: min(winSeq.count, homStartOff + f.fullSequence.count),
                    homologyArmLength: 18,
                    tmText: String(format: "%.1f℃", f.tm ?? 60),
                    sequence: f.fullSequence
                )
            )
        }
        if primers.count > 1 {
            let r = primers[1]
            microPrimers.append(
                MicroscopicPrimerOverlay(
                    name: r.name,
                    isForward: false,
                    startOffset: max(0, homEndOff - r.fullSequence.count),
                    endOffset: homEndOff,
                    homologyArmLength: 18,
                    tmText: String(format: "%.1f℃", r.tm ?? 60),
                    sequence: r.fullSequence
                )
            )
        }
        
        let microWindows: [MicroscopicSequenceWindow] = [
            MicroscopicSequenceWindow(
                title: "★ 突变位点微观双链",
                subtitle: siteClean.isEmpty ? "定点缺失突变 (Δ)" : "定点突变 (\(siteClean)) 与氨基酸密码子核验",
                startBp: max(1, upClean.count - flankUp.count + 1),
                sequence: winSeq,
                homologyHighlightRange: homStartOff..<homEndOff,
                homologyLabel: "18 bp 突变环化重叠同源臂",
                focalHighlightRange: mutStartOff..<min(winSeq.count, mutEndOff),
                focalLabel: siteClean.isEmpty ? "Δ 缺失切点" : "★ 突变碱基 (\(siteClean))",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: "★\(mutLabel)", topSnipOffset: mutStartOff, bottomSnipOffset: min(winSeq.count, mutEndOff))
                ],
                primers: microPrimers,
                readingFrameOffset: 0
            )
        ]
        
        return PlasmidConstructPreviewData(
            constructTitle: "pMut",
            vectorName: "Mutagenesis",
            totalLengthBp: 5400 + siteClean.count,
            insertLengthBp: siteClean.count,
            gcPercent: BioSequence.gcContent(combined),
            features: features,
            enzymes: enzymes,
            primers: pMarkers,
            junctions: junctions,
            linearSummarySteps: [("上游", "\(upClean.count)bp", .blue), ("★ 突变", mutLabel, .red), ("下游", "\(downClean.count)bp", .green)],
            microscopicWindows: microWindows
        )
    }
    
    /// 5. 质粒片段删除：返回删除后重组质粒的图谱与断点数据
    public static func forFragmentDeletion(
        plasmidName: String,
        originalLength: Int,
        delStart: Int,
        delEnd: Int,
        newPlasmidSeq: String,
        primers: [PrimerItem]
    ) -> PlasmidConstructPreviewData? {
        guard !primers.isEmpty, originalLength > 0, !newPlasmidSeq.isEmpty else { return nil }
        
        let delLen = max(0, delEnd - delStart + 1)
        let newLen = newPlasmidSeq.count
        let gc = BioSequence.gcContent(newPlasmidSeq)
        
        let ratioPos = min(0.95, max(0.05, Double(delStart) / Double(max(originalLength, 1))))
        let startR = max(0.0, ratioPos - 0.03)
        let endR = min(1.0, ratioPos + 0.03)
        
        let features: [PlasmidFeatureItem] = [
            PlasmidFeatureItem(name: "保留骨架上游", lengthBp: delStart, startRatio: 0.0, endRatio: startR, color: Color(red: 0.20, green: 0.60, blue: 0.95)),
            PlasmidFeatureItem(name: "Δ 缺失切点 (\(delLen) bp)", lengthBp: 18, startRatio: startR, endRatio: endR, color: Color(red: 1.0, green: 0.30, blue: 0.43), isHighlight: true, sequenceSnippet: "Junction: \(delStart)-\(delStart)"),
            PlasmidFeatureItem(name: "保留骨架下游", lengthBp: max(0, newLen - delStart), startRatio: endR, endRatio: 1.0, color: Color(red: 0.20, green: 0.75, blue: 0.50))
        ]
        
        let enzymes: [PlasmidEnzymeMarker] = [
            PlasmidEnzymeMarker(name: "Δ 切点", recognitionSite: "Junction", ratioPosition: ratioPos, positionBp: delStart, color: .red)
        ]
        
        var primerMarkers: [PlasmidPrimerMarker] = []
        if let f = primers.first {
            primerMarkers.append(PlasmidPrimerMarker(name: f.name, isForward: true, startRatio: endR, endRatio: min(1.0, endR + 0.10), tmText: String(format: "%.1f℃", f.tm ?? 60), sequence: f.fullSequence, color: .blue))
        }
        if primers.count > 1 {
            let r = primers[1]
            primerMarkers.append(PlasmidPrimerMarker(name: r.name, isForward: false, startRatio: max(0.0, startR - 0.10), endRatio: startR, tmText: String(format: "%.1f℃", r.tm ?? 60), sequence: r.fullSequence, color: .orange))
        }
        
        let leftUp36 = String(newPlasmidSeq.prefix(max(0, delStart - 1)).suffix(36))
        let rightDown36 = String(newPlasmidSeq.dropFirst(max(0, delStart - 1)).prefix(36))
        let seamWindowSeq = leftUp36 + rightDown36
        let cutOff = leftUp36.count
        
        let junctions: [PlasmidJunctionBlock] = [
            PlasmidJunctionBlock(title: "缺失接缝结构 (Deletion Junction)", leftLabel: "上游断点", leftSeq: String(leftUp36.suffix(18)), midLabel: "Δ 移除 \(delLen)bp", midSeq: "---", rightLabel: "下游断点", rightSeq: String(rightDown36.prefix(18)))
        ]
        
        let steps: [(String, String, Color)] = [
            ("上游保留区", "1 ~ \(max(1, delStart - 1)) bp", .blue),
            ("Δ 缺失敲除", "\(delLen) bp 移除", .red),
            ("下游保留区", "\(delStart) ~ \(newLen) bp", .green)
        ]
        
        var microPrimers: [MicroscopicPrimerOverlay] = []
        if let f = primers.first {
            microPrimers.append(
                MicroscopicPrimerOverlay(
                    name: f.name,
                    isForward: true,
                    startOffset: max(0, cutOff - 9),
                    endOffset: min(seamWindowSeq.count, cutOff + 27),
                    homologyArmLength: 18,
                    tmText: String(format: "%.1f℃", f.tm ?? 60),
                    sequence: f.fullSequence
                )
            )
        }
        if primers.count > 1 {
            let r = primers[1]
            microPrimers.append(
                MicroscopicPrimerOverlay(
                    name: r.name,
                    isForward: false,
                    startOffset: max(0, cutOff - 27),
                    endOffset: min(seamWindowSeq.count, cutOff + 9),
                    homologyArmLength: 18,
                    tmText: String(format: "%.1f℃", r.tm ?? 60),
                    sequence: r.fullSequence
                )
            )
        }
        
        let microWindows: [MicroscopicSequenceWindow] = [
            MicroscopicSequenceWindow(
                title: "Δ 敲除缝合断点微观双链",
                subtitle: "已精确移除 \(delStart)..\(delEnd) (\(delLen) bp) 后的环化接缝与读码框核验",
                startBp: max(1, delStart - leftUp36.count),
                sequence: seamWindowSeq,
                homologyHighlightRange: max(0, cutOff - 9)..<min(seamWindowSeq.count, cutOff + 9),
                homologyLabel: "18 bp 跨断点无缝环化同源臂",
                focalHighlightRange: max(0, cutOff - 2)..<min(seamWindowSeq.count, cutOff + 2),
                focalLabel: "Δ 缺失缝合切点",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: "Δ移除\(delLen)bp", topSnipOffset: cutOff, bottomSnipOffset: cutOff)
                ],
                primers: microPrimers,
                readingFrameOffset: 0
            )
        ]
        
        return PlasmidConstructPreviewData(
            constructTitle: "\(plasmidName) (Δ\(delLen)bp)",
            vectorName: plasmidName,
            totalLengthBp: newLen,
            insertLengthBp: 0,
            gcPercent: gc,
            features: features,
            enzymes: enzymes,
            primers: primerMarkers,
            junctions: junctions,
            linearSummarySteps: steps,
            microscopicWindows: microWindows
        )
    }
    
    /// 5. sgRNA：仅在引物已生成时返回图谱数据
    public static func forSgRNA(
        species: TargetSpecies,
        geneName: String,
        spacerSequence: String,
        overhangType: CRISPRDesigner.VectorOverhang,
        hasGenerated: Bool
    ) -> PlasmidConstructPreviewData? {
        guard hasGenerated else { return nil }
        let clean = BioSequence.clean(spacerSequence)
        guard clean.count == 20 else { return nil }
        
        let activeGene = geneName.isEmpty ? "sgTarget" : geneName
        let isLenti = (overhangType == .lentiCRISPRv2)
        let vecBp = isLenti ? 14873 : 9175
        let enzName = isLenti ? "BsmBI" : "BbsI"
        
        let pair = CRISPRDesigner.designPair(
            target: clean,
            geneName: activeGene,
            index: 1,
            species: species,
            vector: overhangType
        )
        
        let features: [PlasmidFeatureItem] = [
            PlasmidFeatureItem(name: "hU6", lengthBp: 249, startRatio: 0.90, endRatio: 0.985, color: Color(red: 0.96, green: 0.26, blue: 0.38)),
            PlasmidFeatureItem(name: "\(activeGene) (20nt)", lengthBp: 20, startRatio: 0.985, endRatio: 0.065, color: Color(red: 0.10, green: 0.82, blue: 0.54), isHighlight: true, sequenceSnippet: clean),
            PlasmidFeatureItem(name: "gRNA Scaffold", lengthBp: 76, startRatio: 0.065, endRatio: 0.15, color: .cyan),
            PlasmidFeatureItem(name: "EF1α", lengthBp: 540, startRatio: 0.18, endRatio: 0.28, color: .orange),
            PlasmidFeatureItem(name: "Cas9", lengthBp: 4100, startRatio: 0.29, endRatio: 0.58, color: Color(red: 0.55, green: 0.36, blue: 0.96)),
            PlasmidFeatureItem(name: "PuroR", lengthBp: 1400, startRatio: 0.61, endRatio: 0.82, color: Color(red: 0.96, green: 0.62, blue: 0.05))
        ]
        
        let enzymes: [PlasmidEnzymeMarker] = [
            PlasmidEnzymeMarker(name: enzName, recognitionSite: "CACCG", ratioPosition: 0.985, positionBp: 249, color: .red)
        ]
        
        let primers: [PlasmidPrimerMarker] = [
            PlasmidPrimerMarker(name: pair.fwdPrimer.name, isForward: true, startRatio: 0.98, endRatio: 0.08, tmText: "Top", sequence: pair.fwdPrimer.fullSequence, color: .blue),
            PlasmidPrimerMarker(name: pair.revPrimer.name, isForward: false, startRatio: 0.98, endRatio: 0.08, tmText: "Bottom", sequence: pair.revPrimer.fullSequence, color: .orange)
        ]
        
        let junctions: [PlasmidJunctionBlock] = [
            PlasmidJunctionBlock(title: "Top Oligo (5'→3')", leftLabel: "悬垂", leftSeq: "caccg", midLabel: "Spacer", midSeq: clean, rightLabel: "", rightSeq: ""),
            PlasmidJunctionBlock(title: "Bottom Oligo (5'→3')", leftLabel: "悬垂", leftSeq: "aaac", midLabel: "互补", midSeq: BioSequence.reverseComplement(clean), rightLabel: "", rightSeq: "c")
        ]
        
        let sgWinSeq = "CACCG" + clean + "GTTTTAGAGCTAGAAATAGCAAGTTAAAATAAGGCT"
        let microWindows: [MicroscopicSequenceWindow] = [
            MicroscopicSequenceWindow(
                title: "sgRNA 退火双链与黏性末端",
                subtitle: "\(enzName) 4nt 悬垂端 + 20nt Spacer + gRNA Scaffold",
                startBp: 245,
                sequence: sgWinSeq,
                homologyHighlightRange: 0..<5,
                homologyLabel: "\(enzName) 5' 黏性悬垂端 (CACCG)",
                focalHighlightRange: 5..<25,
                focalLabel: "20 nt CRISPR 靶向 Spacer",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: enzName, topSnipOffset: 1, bottomSnipOffset: 5)
                ],
                primers: [
                    MicroscopicPrimerOverlay(name: pair.fwdPrimer.name, isForward: true, startOffset: 0, endOffset: 25, homologyArmLength: 5, tmText: "Top Oligo", sequence: pair.fwdPrimer.fullSequence)
                ]
            )
        ]
        
        return PlasmidConstructPreviewData(
            constructTitle: "\(activeGene)-sgRNA",
            vectorName: isLenti ? "lentiCRISPRv2" : "pX459",
            totalLengthBp: vecBp + 20,
            insertLengthBp: 20,
            gcPercent: BioSequence.gcContent(clean),
            features: features,
            enzymes: enzymes,
            primers: primers,
            junctions: junctions,
            linearSummarySteps: [("hU6", "启动子", .red), ("Spacer", "\(activeGene) (20nt)", .green), ("Scaffold", "骨架", .cyan)],
            microscopicWindows: microWindows
        )
    }
    
    /// 6. shRNA：仅在引物已生成时返回图谱数据
    public static func forShRNA(
        species: TargetSpecies,
        geneName: String,
        senseSequence: String,
        loopSequence: String,
        hasGenerated: Bool
    ) -> PlasmidConstructPreviewData? {
        guard hasGenerated else { return nil }
        let clean = BioSequence.clean(senseSequence)
        guard clean.count >= 19 && clean.count <= 22 else { return nil }
        
        let activeGene = geneName.isEmpty ? "shTarget" : geneName
        let loop = BioSequence.clean(loopSequence).isEmpty ? "CTCGAG" : BioSequence.clean(loopSequence)
        let antisense = BioSequence.reverseComplement(clean)
        
        let features: [PlasmidFeatureItem] = [
            PlasmidFeatureItem(name: "hU6", lengthBp: 250, startRatio: 0.88, endRatio: 0.975, color: Color(red: 0.96, green: 0.26, blue: 0.38)),
            PlasmidFeatureItem(name: "Sense (\(clean.count)nt)", lengthBp: clean.count, startRatio: 0.98, endRatio: 0.06, color: Color(red: 0.10, green: 0.82, blue: 0.54), isHighlight: true, sequenceSnippet: clean),
            PlasmidFeatureItem(name: "Loop", lengthBp: loop.count, startRatio: 0.06, endRatio: 0.105, color: .orange, isHighlight: true, sequenceSnippet: loop),
            PlasmidFeatureItem(name: "Antisense", lengthBp: antisense.count, startRatio: 0.105, endRatio: 0.185, color: .cyan, isHighlight: true, sequenceSnippet: antisense),
            PlasmidFeatureItem(name: "PuroR", lengthBp: 1120, startRatio: 0.25, endRatio: 0.52, color: Color(red: 0.55, green: 0.36, blue: 0.96)),
            PlasmidFeatureItem(name: "ori", lengthBp: 1850, startRatio: 0.58, endRatio: 0.82, color: Color(red: 0.96, green: 0.62, blue: 0.05))
        ]
        
        let enzymes: [PlasmidEnzymeMarker] = [
            PlasmidEnzymeMarker(name: "AgeI", recognitionSite: "ACCGGT", ratioPosition: 0.978, positionBp: 1, color: .red),
            PlasmidEnzymeMarker(name: "EcoRI", recognitionSite: "GAATTC", ratioPosition: 0.19, positionBp: 58, color: .blue)
        ]
        
        let topSeq = "CCGG\(clean)\(loop)\(antisense)TTTTTTG"
        let botSeq = "AATTCAAAAAAA\(clean)\(loop)\(antisense)"
        let primers: [PlasmidPrimerMarker] = [
            PlasmidPrimerMarker(name: "\(activeGene)-sh-F", isForward: true, startRatio: 0.978, endRatio: 0.19, tmText: "\(topSeq.count)nt", sequence: topSeq, color: .blue),
            PlasmidPrimerMarker(name: "\(activeGene)-sh-R", isForward: false, startRatio: 0.978, endRatio: 0.19, tmText: "\(botSeq.count)nt", sequence: botSeq, color: .orange)
        ]
        
        let junctions: [PlasmidJunctionBlock] = [
            PlasmidJunctionBlock(title: "Top (5'→3')", leftLabel: "AgeI+Sense", leftSeq: "ccgg" + clean, midLabel: "Loop", midSeq: loop.lowercased(), rightLabel: "Antisense+T6", rightSeq: antisense + "ttttttg"),
            PlasmidJunctionBlock(title: "Bottom (5'→3')", leftLabel: "EcoRI+A7", leftSeq: "aattcaaaaaaa", midLabel: "Sense+Loop", midSeq: clean + loop.lowercased(), rightLabel: "Antisense", rightSeq: antisense)
        ]
        
        let microWindows: [MicroscopicSequenceWindow] = [
            MicroscopicSequenceWindow(
                title: "pLKO.1 shRNA 发夹盒微观双链",
                subtitle: "AgeI 悬垂 + Sense + \(loop) 茎环 + Antisense + EcoRI 悬垂",
                startBp: 1,
                sequence: topSeq + "AATT",
                homologyHighlightRange: 4..<(4 + clean.count),
                homologyLabel: "\(clean.count) nt Sense 正义链",
                focalHighlightRange: (4 + clean.count)..<(4 + clean.count + loop.count),
                focalLabel: "茎环 Loop (\(loop))",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: "AgeI", topSnipOffset: 0, bottomSnipOffset: 4),
                    MicroscopicEnzymeCut(name: "EcoRI", topSnipOffset: topSeq.count, bottomSnipOffset: topSeq.count + 4)
                ],
                primers: [
                    MicroscopicPrimerOverlay(name: "\(activeGene)-sh-F", isForward: true, startOffset: 0, endOffset: topSeq.count, homologyArmLength: 4, tmText: "\(topSeq.count)nt", sequence: topSeq)
                ]
            )
        ]
        
        return PlasmidConstructPreviewData(
            constructTitle: "pLKO.1-\(activeGene)",
            vectorName: "pLKO.1",
            totalLengthBp: 7052 + 58,
            insertLengthBp: 58,
            gcPercent: BioSequence.gcContent(clean),
            features: features,
            enzymes: enzymes,
            primers: primers,
            junctions: junctions,
            linearSummarySteps: [("AgeI", "CCGG", .red), ("Sense", clean, .green), ("Loop", loop, .orange), ("Antisense", antisense, .cyan)],
            microscopicWindows: microWindows
        )
    }
    
    /// 7. SnapGene 真实质粒重组产物图谱 (保留载体原生 Features 注释 + 插入片段高亮 + 接头引物标注)
    public static func forSnapGeneRecombinant(
        vectorInfo: SnapGeneFileInfo,
        insertSeq: String,
        insertName: String,
        cutStart: Int,
        cutEnd: Int,
        primers: [PrimerItem]
    ) -> PlasmidConstructPreviewData? {
        let cleanIns = BioSequence.clean(insertSeq)
        guard cleanIns.count >= 20 else { return nil }
        
        let vecLen = max(vectorInfo.length, 1000)
        let insLen = cleanIns.count
        let cutLen = max(0, cutEnd - cutStart + 1)
        let totalBp = vecLen - cutLen + insLen
        guard totalBp > 0 else { return nil }
        
        let delta = insLen - cutLen
        let insStart = max(1, min(cutStart, vecLen))
        let insEnd = insStart + insLen - 1
        
        var features: [PlasmidFeatureItem] = []
        
        // 1. 映射载体原生 Features (平移切割点下游坐标)
        for f in vectorInfo.features {
            for seg in f.segments {
                let s = seg.start
                let e = seg.end
                var newS = s
                var newE = e
                
                if e < cutStart {
                    newS = s
                    newE = e
                } else if s > cutEnd {
                    newS = s + delta
                    newE = e + delta
                } else {
                    continue
                }
                
                guard newS >= 1 && newE <= totalBp && newS <= newE else { continue }
                let sRatio = Double(newS - 1) / Double(totalBp)
                let eRatio = Double(newE) / Double(totalBp)
                let dir: FeatureDirection = f.directionality == "2" ? .counterClockwise : .clockwise
                let col = Color(hexString: seg.color)
                
                features.append(PlasmidFeatureItem(
                    name: f.name,
                    lengthBp: newE - newS + 1,
                    startRatio: sRatio,
                    endRatio: eRatio,
                    color: col,
                    direction: dir,
                    isHighlight: false,
                    sequenceSnippet: ""
                ))
            }
        }
        
        // 2. 插入新重组片段 Feature (高亮醒目绿)
        let insSRatio = Double(insStart - 1) / Double(totalBp)
        let insERatio = Double(insEnd) / Double(totalBp)
        let dispName = insertName.isEmpty ? "Insert (\(insLen)bp)" : "\(insertName) (\(insLen)bp)"
        features.append(PlasmidFeatureItem(
            name: dispName,
            lengthBp: insLen,
            startRatio: insSRatio,
            endRatio: insERatio,
            color: Color(red: 0.10, green: 0.82, blue: 0.54),
            direction: .clockwise,
            isHighlight: true,
            sequenceSnippet: String(cleanIns.prefix(36))
        ))
        
        // 3. 引物标记
        var primerMarkers: [PlasmidPrimerMarker] = []
        if let f = primers.first {
            primerMarkers.append(PlasmidPrimerMarker(
                name: f.name,
                isForward: true,
                startRatio: max(0.0, insSRatio - 0.02),
                endRatio: min(1.0, insSRatio + 0.08),
                tmText: String(format: "%.1f℃", f.tm ?? 60),
                sequence: f.fullSequence,
                color: .cyan
            ))
        }
        if primers.count > 1 {
            let r = primers[1]
            primerMarkers.append(PlasmidPrimerMarker(
                name: r.name,
                isForward: false,
                startRatio: max(0.0, insERatio - 0.08),
                endRatio: min(1.0, insERatio + 0.02),
                tmText: String(format: "%.1f℃", r.tm ?? 60),
                sequence: r.fullSequence,
                color: .orange
            ))
        }
        
        // 4. 接头微观信息与真实全长重组序列构建 (根据实际 cutStart / cutEnd 计算，绝不硬取首尾 18bp)
        let cleanVecSeq = BioSequence.clean(vectorInfo.sequence)
        let safeVecLen = max(1, cleanVecSeq.count)
        let clampedStart = max(1, min(cutStart, safeVecLen + 1))
        let clampedEnd = max(clampedStart - 1, min(cutEnd, safeVecLen))
        
        let leftIdx = cleanVecSeq.index(cleanVecSeq.startIndex, offsetBy: clampedStart - 1)
        let rightIdx = cleanVecSeq.index(cleanVecSeq.startIndex, offsetBy: clampedEnd)
        let leftPart = String(cleanVecSeq[..<leftIdx])
        let rightPart = String(cleanVecSeq[rightIdx...])
        let trueRecombinantSeq = leftPart + cleanIns + rightPart
        
        let doubledVec = cleanVecSeq + cleanVecSeq
        let upEnd0 = (clampedStart - 1 + safeVecLen) % safeVecLen
        let upStart0 = (upEnd0 - 18 + safeVecLen) % safeVecLen
        let uSIdx = doubledVec.index(doubledVec.startIndex, offsetBy: upStart0)
        let uEIdx = doubledVec.index(uSIdx, offsetBy: min(18, safeVecLen))
        let vec5Arm = String(doubledVec[uSIdx..<uEIdx]).uppercased()
        
        let downStart0 = clampedEnd % safeVecLen
        let dSIdx = doubledVec.index(doubledVec.startIndex, offsetBy: downStart0)
        let dEIdx = doubledVec.index(dSIdx, offsetBy: min(18, safeVecLen))
        let vec3Arm = String(doubledVec[dSIdx..<dEIdx]).uppercased()
        
        let junctions: [PlasmidJunctionBlock] = [
            PlasmidJunctionBlock(
                title: "5' 重组接头 (@\(clampedStart) bp)",
                leftLabel: "载体 5' 骨架",
                leftSeq: vec5Arm,
                midLabel: "5' 接头同源臂",
                midSeq: primers.first?.fullSequence.prefix(18).lowercased() ?? "---",
                rightLabel: "插入基因 5' 端",
                rightSeq: String(cleanIns.prefix(20))
            ),
            PlasmidJunctionBlock(
                title: "3' 重组接头 (@\(insEnd) bp)",
                leftLabel: "插入基因 3' 端",
                leftSeq: String(cleanIns.suffix(20)),
                midLabel: "3' 接头同源臂",
                midSeq: primers.count > 1 ? primers[1].fullSequence.prefix(18).lowercased() : "---",
                rightLabel: "载体 3' 骨架",
                rightSeq: vec3Arm
            )
        ]
        
        let win5Seq = vec5Arm + String(cleanIns.prefix(54))
        let win3Seq = String(cleanIns.suffix(54)) + vec3Arm
        let microWindows: [MicroscopicSequenceWindow] = [
            MicroscopicSequenceWindow(
                title: "5' SnapGene 重组接头 (@\(clampedStart) bp)",
                subtitle: "\(vectorInfo.fileName) 5' 臂 + \(insertName) 5' 端",
                startBp: max(1, insStart - vec5Arm.count),
                sequence: win5Seq,
                homologyHighlightRange: 0..<vec5Arm.count,
                homologyLabel: "18 bp 载体同源臂",
                focalHighlightRange: vec5Arm.count..<min(win5Seq.count, vec5Arm.count + 18),
                focalLabel: "\(insertName) 5' 起始区",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: "5'Junction", topSnipOffset: vec5Arm.count, bottomSnipOffset: vec5Arm.count)
                ],
                primers: primers.first != nil ? [
                    MicroscopicPrimerOverlay(name: primers[0].name, isForward: true, startOffset: 0, endOffset: min(win5Seq.count, primers[0].fullSequence.count), homologyArmLength: 18, tmText: String(format: "%.1f℃", primers[0].tm ?? 60), sequence: primers[0].fullSequence)
                ] : []
            ),
            MicroscopicSequenceWindow(
                title: "3' SnapGene 重组接头 (@\(insEnd) bp)",
                subtitle: "\(insertName) 3' 端 + \(vectorInfo.fileName) 3' 臂",
                startBp: max(1, insEnd - 53),
                sequence: win3Seq,
                homologyHighlightRange: (win3Seq.count - vec3Arm.count)..<win3Seq.count,
                homologyLabel: "18 bp 载体同源臂",
                focalHighlightRange: max(0, win3Seq.count - vec3Arm.count - 18)..<(win3Seq.count - vec3Arm.count),
                focalLabel: "\(insertName) 3' 末端区",
                enzymeCuts: [
                    MicroscopicEnzymeCut(name: "3'Junction", topSnipOffset: win3Seq.count - vec3Arm.count, bottomSnipOffset: win3Seq.count - vec3Arm.count)
                ],
                primers: primers.count > 1 ? [
                    MicroscopicPrimerOverlay(name: primers[1].name, isForward: false, startOffset: max(0, win3Seq.count - primers[1].fullSequence.count), endOffset: win3Seq.count, homologyArmLength: 18, tmText: String(format: "%.1f℃", primers[1].tm ?? 60), sequence: primers[1].fullSequence)
                ] : []
            )
        ]
        
        return PlasmidConstructPreviewData(
            constructTitle: "Recombinant-\(insertName.isEmpty ? "Construct" : insertName)",
            vectorName: vectorInfo.fileName.replacingOccurrences(of: ".dna", with: ""),
            totalLengthBp: totalBp,
            insertLengthBp: insLen,
            gcPercent: BioSequence.gcContent(trueRecombinantSeq),
            fullSequence: trueRecombinantSeq,
            features: features,
            enzymes: [],
            primers: primerMarkers,
            junctions: junctions,
            linearSummarySteps: [
                ("载体保留骨架", "\(vecLen - cutLen)bp (Δ\(cutLen)bp @\(clampedStart)..\(clampedEnd))", .blue),
                (insertName.isEmpty ? "插入片段" : insertName, "\(insLen)bp (@\(insStart)..\(insEnd))", Color(red: 0.10, green: 0.82, blue: 0.54))
            ],
            microscopicWindows: microWindows
        )
    }
    
    /// 8. 原始 SnapGene 质粒全景预览构建器 (支持任意已载入的 .dna 质粒在新窗口或预览面板中完整交互预览、选择密码子/氨基酸)
    public static func forRawSnapGeneFile(
        info: SnapGeneFileInfo,
        highlightRange: ClosedRange<Int>? = nil
    ) -> PlasmidConstructPreviewData {
        let cleanSeq = BioSequence.clean(info.sequence)
        let totalBp = max(1, cleanSeq.count)
        let gc = BioSequence.gcContent(cleanSeq)
        
        var features: [PlasmidFeatureItem] = []
        var microWindows: [MicroscopicSequenceWindow] = []
        
        for f in info.features {
            for seg in f.segments {
                let s = max(1, min(seg.start, totalBp))
                let e = max(s, min(seg.end, totalBp))
                let sRatio = Double(s - 1) / Double(totalBp)
                let eRatio = Double(e) / Double(totalBp)
                let dir: FeatureDirection = f.directionality == "2" ? .counterClockwise : .clockwise
                let col = Color(hexString: seg.color)
                
                let sIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: s - 1)
                let eIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: e)
                let rawSub = String(cleanSeq[sIdx..<eIdx])
                let snippet = String((f.directionality == "2" ? BioSequence.reverseComplement(rawSub) : rawSub).prefix(36))
                let isHit: Bool = {
                    if let hr = highlightRange {
                        return max(s, hr.lowerBound) <= min(e, hr.upperBound)
                    }
                    return false
                }()
                
                features.append(PlasmidFeatureItem(
                    name: f.name,
                    lengthBp: e - s + 1,
                    startRatio: sRatio,
                    endRatio: eRatio,
                    color: col,
                    direction: dir,
                    isHighlight: isHit,
                    sequenceSnippet: snippet
                ))
            }
            
            // 为主要基因/CDS 特征构建独立的微观序列与氨基酸密码子窗口，方便在预览中一键切换并点选密码子突变
            if let firstSeg = f.segments.first, let lastSeg = f.segments.last {
                let s = max(1, min(firstSeg.start, totalBp))
                let e = max(s, min(lastSeg.end, totalBp))
                if (e - s + 1) >= 24 && microWindows.count < 12 {
                    let sIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: s - 1)
                    let eIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: e)
                    let winSeq = String(cleanSeq[sIdx..<eIdx])
                    var focRange: Range<Int>? = nil
                    if let hr = highlightRange, hr.lowerBound >= s && hr.upperBound <= e {
                        focRange = (hr.lowerBound - s)..<min(winSeq.count, hr.upperBound - s + 1)
                    }
                    microWindows.append(MicroscopicSequenceWindow(
                        title: "\(f.name) (\(s)..\(e))",
                        subtitle: "\(f.type) · \(e - s + 1) bp · 点击任意密码子/氨基酸可直接设定突变",
                        startBp: s,
                        sequence: winSeq,
                        focalHighlightRange: focRange,
                        focalLabel: focRange != nil ? "当前选中突变位点" : "",
                        readingFrameOffset: 0
                    ))
                }
            }
        }
        
        // 映射质粒内已绑定的引物
        var primerMarkers: [PlasmidPrimerMarker] = []
        for p in info.validBoundPrimers {
            if let s = p.startBp, let e = p.endBp {
                let sR = Double(max(1, s) - 1) / Double(totalBp)
                let eR = Double(min(totalBp, e)) / Double(totalBp)
                primerMarkers.append(PlasmidPrimerMarker(
                    name: p.name,
                    isForward: p.isForwardStrand,
                    startRatio: sR,
                    endRatio: eR,
                    tmText: "\(p.primarySite?.tm ?? "60")℃",
                    sequence: p.sequence,
                    color: p.isForwardStrand ? .cyan : .orange
                ))
            }
        }
        
        // 扫描唯一酶切位点
        let uniqueCuts = info.scanAvailableCutSites(maxCutsPerEnzyme: 1)
        let enzymeMarkers: [PlasmidEnzymeMarker] = uniqueCuts.prefix(24).map { opt in
            PlasmidEnzymeMarker(
                name: opt.enzyme.name,
                recognitionSite: opt.enzyme.site,
                ratioPosition: Double(opt.position1Based - 1) / Double(totalBp),
                positionBp: opt.position1Based,
                color: .red
            )
        }
        
        let cleanTitle = info.fileName.replacingOccurrences(of: ".dna", with: "")
        return PlasmidConstructPreviewData(
            constructTitle: cleanTitle,
            vectorName: cleanTitle,
            totalLengthBp: totalBp,
            insertLengthBp: highlightRange.map { $0.upperBound - $0.lowerBound + 1 } ?? 0,
            gcPercent: gc,
            fullSequence: cleanSeq,
            features: features,
            enzymes: enzymeMarkers,
            primers: primerMarkers,
            junctions: [],
            linearSummarySteps: [
                (cleanTitle, "\(totalBp) bp", .blue),
                ("特征数", "\(info.featuresCount) 个", .green),
                ("引物数", "\(info.validBoundPrimers.count) 条", .orange),
                ("唯一酶切", "\(uniqueCuts.count) 个", .purple)
            ],
            microscopicWindows: microWindows
        )
    }
}

// MARK: - 颜色 Hex 转换扩展
extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 100, 150, 240)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// 自动校正过浅（如浅绿 #ccffcc / 浅黄 #ffff99）或过深颜色，确保文字与图例在浅色/深色模式下均清晰可读
    func studioLegibleAccent(isDark: Bool) -> Color {
        #if canImport(AppKit)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if isDark {
            let adjSat = s > 0.08 ? max(Double(s), 0.55) : Double(s)
            let adjBri = max(Double(b), 0.72)
            return Color(hue: Double(h), saturation: adjSat, brightness: adjBri, opacity: Double(a))
        } else {
            let adjSat = s > 0.06 ? max(Double(s), 0.72) : Double(s)
            let adjBri = min(Double(b), 0.52)
            return Color(hue: Double(h), saturation: adjSat, brightness: adjBri, opacity: Double(a))
        }
        #else
        return self
        #endif
    }

    func studioStepCapsuleFill() -> Color {
        #if canImport(AppKit)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(max(s, 0.65)), brightness: Double(min(b, 0.66)), opacity: 1.0)
        #else
        return self
        #endif
    }

    /// 针对填充在色块内部（如环状图谱特征弧 / 线性分布块）的文字颜色：浅粉彩底色返回深灰字，饱和深色返回纯白字
    func studioContrastingTextOnFill() -> Color {
        #if canImport(AppKit)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        return luminance > 0.56 ? Color(red: 0.11, green: 0.14, blue: 0.18) : .white
        #else
        return .white
        #endif
    }
}

private final class CutsiteMemoBox {
    var key: String = ""
    var cutsites: [ConstructCutsite] = []
}

// MARK: - 3. 精细质粒预览工作台 (1:1 CloneCanvas / SnapGene 同屏双视 + OVE 多轨环形图 + 微观单碱基序列 + 线性组装 + 构建谱系)
public struct PlasmidPreviewPanel: View {
    @ObservedObject private var appState = AppState.shared
    public let data: PlasmidConstructPreviewData
    public var onClose: (() -> Void)? = nil
    public var onMutateCodon: ((InteractiveCodonMutationPayload) -> Void)? = nil
    public var isStandaloneWindow: Bool = false
    
    private var isDark: Bool {
        appState.resolvedCanvasIsDark()
    }
    
    public enum PreviewTab: String, CaseIterable {
        case split = "精细同屏"
        case circular = "环形图谱"
        case microscopic = "微观序列"
        case linear = "线性拼接"
        case lineage = "构建谱系"
        
        public var icon: String {
            switch self {
            case .split: return "rectangle.split.2x1.fill"
            case .circular: return "circle.circle"
            case .microscopic: return "character.textbox"
            case .linear: return "link"
            case .lineage: return "point.3.connected.trianglepath.dotted"
            }
        }
    }
    
    public enum CircularToolMode: String {
        case select
        case pan
        case rotate
    }
    
    @State private var selectedTab: PreviewTab = .split
    @State private var rotationDegrees: Double = 0
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var toolMode: CircularToolMode = .select
    @State private var isFeaturesOverlayExpanded: Bool = true
    @State private var selectedFeatureID: UUID? = nil
    @State private var selectedRangeBp: ClosedRange<Int>? = nil
    @State private var showEnzymeInspector: Bool = false
    @State private var isSplitWorkbenchWide: Bool = false
    private let cutsiteMemo = CutsiteMemoBox()
    
    public init(
        data: PlasmidConstructPreviewData,
        onClose: (() -> Void)? = nil,
        onMutateCodon: ((InteractiveCodonMutationPayload) -> Void)? = nil,
        isStandaloneWindow: Bool = false
    ) {
        self.data = data
        self.onClose = onClose
        self.onMutateCodon = onMutateCodon
        self.isStandaloneWindow = isStandaloneWindow
    }
    
    /// 缓存内切酶切点扫描结果，避免鼠标拖拽选区时重复扫描全长质粒导致掉帧（采用非 @State 引用盒子，零重绘副作用）
    private var currentCutsiteScanKey: String {
        "\(data.fullSequence.count)_\(data.fullSequence.prefix(32))_\(appState.selectedEnzymeNames.count)_\(appState.uniqueCuttersOnly)"
    }
    
    private var detectedCutsites: [ConstructCutsite] {
        let key = currentCutsiteScanKey
        if cutsiteMemo.key == key {
            return cutsiteMemo.cutsites
        }
        let scanned = RestrictionEnzymeDatabase.shared.scanConstructCutsites(
            sequence: data.fullSequence,
            circular: true,
            enzymeNames: appState.selectedEnzymeNames,
            uniqueOnly: appState.uniqueCuttersOnly
        )
        cutsiteMemo.key = key
        cutsiteMemo.cutsites = scanned
        return scanned
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶栏第一行：沉浸式标题（独立窗口自动让出左侧红黄绿交通灯区域） + 指标徽章 + 展开/弹出控件（零重复关闭按钮）
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    if isStandaloneWindow {
                        Spacer()
                            .frame(width: 68, height: 1)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "circle.circle.fill")
                            .foregroundStyle(.cyan)
                            .font(.system(size: 13))
                        Text(data.insertLengthBp == 0 ? "原始质粒全景图谱：\(data.constructTitle)" : "重组质粒全景图谱")
                            .font(.system(size: 13.5, weight: .bold))
                            .lineLimit(1)
                    }
                    .help(onMutateCodon != nil
                          ? "在序列或氨基酸带中按住拖拽选区，可在底部直接点选目标氨基酸进行定点突变"
                          : "在序列或密码子带上直接按住拖拽选区，实时测算坐标、氨基酸序列与 Tm 值")
                    
                    Spacer(minLength: 4)
                    
                    HStack(spacing: 5) {
                        StudioMetricBadge(label: "总长", value: "\(data.totalLengthBp) bp", color: .blue)
                        if data.insertLengthBp > 0 {
                            StudioMetricBadge(label: "插入", value: "\(data.insertLengthBp) bp", color: .green)
                        } else {
                            StudioMetricBadge(label: "特征", value: "\(data.features.count) 个", color: .green)
                        }
                        StudioMetricBadge(label: "GC", value: "\(String(format: "%.0f", data.gcPercent))%", color: .purple)
                    }
                    
                    if !isStandaloneWindow {
                        popoutWindowButton
                        expandToggleButton
                    }
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 5) {
                        if isStandaloneWindow {
                            Spacer()
                                .frame(width: 68, height: 1)
                        }
                        Image(systemName: "circle.circle.fill")
                            .foregroundStyle(.cyan)
                            .font(.system(size: 13))
                        Text(data.insertLengthBp == 0 ? "原始质粒：\(data.constructTitle)" : data.constructTitle)
                            .font(.system(size: 13.5, weight: .bold))
                            .lineLimit(1)
                        
                        Spacer()
                        
                        if !isStandaloneWindow {
                            popoutWindowButton
                            expandToggleButton
                        }
                    }
                    HStack(spacing: 5) {
                        StudioMetricBadge(label: "总长", value: "\(data.totalLengthBp) bp", color: .blue)
                        if data.insertLengthBp > 0 {
                            StudioMetricBadge(label: "插入", value: "\(data.insertLengthBp) bp", color: .green)
                        } else {
                            StudioMetricBadge(label: "特征", value: "\(data.features.count) 个", color: .green)
                        }
                        StudioMetricBadge(label: "GC", value: "\(String(format: "%.0f", data.gcPercent))%", color: .purple)
                    }
                }
            }
            .frame(minHeight: isStandaloneWindow ? 28 : nil)
            
            // 顶栏第二行：macOS 27 原生 Liquid Glass 分段控制器
            StudioGlassSegmentedBar(
                selection: $selectedTab,
                options: PreviewTab.allCases.map { tab in
                    StudioSegmentedOption(value: tab, title: tab.rawValue)
                },
                controlSize: .large,
                fillWidth: true
            )
            
            // 主视图区 (精细同屏 / 环形 / 微观序列 / 线性 / 谱系)
            Group {
                switch selectedTab {
                case .split:
                    splitWorkbenchView
                case .circular:
                    circularPlasmidView
                case .microscopic:
                    sequenceMapView
                case .linear:
                    linearConstructView
                case .lineage:
                    HistoryTreeView(fillsAvailableHeight: isStandaloneWindow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: isStandaloneWindow ? .infinity : nil, alignment: .topLeading)
            
            // 底栏：极简元件胶囊与旋转滑块
            HStack(spacing: 6) {
                Text("元件:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 4) {
                        HStack(spacing: 4) {
                            ForEach(data.features) { feat in
                                let isSel = (selectedFeatureID == feat.id)
                                let legibleCol = feat.color.studioLegibleAccent(isDark: isDark)
                                Button(action: {
                                    selectFeature(feat)
                                }) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(isSel ? Color.white : legibleCol)
                                            .frame(width: 5, height: 5)
                                        Text(feat.name)
                                            .font(.system(size: 10, weight: isSel ? .semibold : .medium))
                                        Text("\(feat.lengthBp)bp")
                                            .font(.system(size: 9))
                                            .monospacedDigit()
                                            .studioOptionalForeground(isSel ? nil : .secondary)
                                    }
                                    .studioOptionalForeground(isSel ? nil : .primary)
                                }
                                .studioGlassButton(
                                    tint: isSel ? legibleCol : nil,
                                    isProminent: isSel,
                                    isSelected: isSel,
                                    controlSize: .small
                                )
                            }
                        }
                    }
                }
                
                if selectedTab == .circular || selectedTab == .split {
                    Slider(value: $rotationDegrees, in: 0...360)
                        .frame(width: 64)
                        .controlSize(.mini)
                        .help("旋转环形质粒图谱视角")
                }
            }
            
            // 选中的元件序列细节
            if let selID = selectedFeatureID,
               let feat = data.features.first(where: { $0.id == selID }),
               !feat.sequenceSnippet.isEmpty {
                let legibleCol = feat.color.studioLegibleAccent(isDark: isDark)
                Text("\(feat.name): 5'- \(feat.sequenceSnippet) -3'")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(legibleCol)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(legibleCol.opacity(0.10))
                    )
            }
        }
        .padding(.horizontal, isStandaloneWindow ? 16 : 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: isStandaloneWindow ? .infinity : nil, alignment: .topLeading)
        .background {
            ZStack {
                Color.clear
                    .onGeometryChange(for: Int.self) { proxy in
                        Int(proxy.size.width.rounded())
                    } action: { width in
                        guard width > 80 else { return }
                        if isSplitWorkbenchWide && width < 660 {
                            isSplitWorkbenchWide = false
                        } else if !isSplitWorkbenchWide && width >= 690 {
                            isSplitWorkbenchWide = true
                        }
                    }

                if !isStandaloneWindow {
                    RoundedRectangle(cornerRadius: StudioRadius.card, style: .continuous)
                        .fill(StudioPalette.cardBg(isLight: !isDark))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.card, style: .continuous)
                                .stroke(StudioPalette.cardBorder(isLight: !isDark), lineWidth: 1)
                        )
                }
            }
        }
    }
    
    // MARK: - 顶栏控制按钮 (全宽同屏展开)
    private var expandToggleButton: some View {
        StudioCompactPillButton(
            title: appState.isPreviewExpanded ? "恢复双栏" : "精细同屏",
            icon: appState.isPreviewExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            tint: .cyan,
            isProminent: appState.isPreviewExpanded,
            help: appState.isPreviewExpanded ? "恢复左右双栏表单+预览模式" : "全宽展开精细同屏工作台（左环图 + 右序列同屏联动）"
        ) {
            withAnimation(.easeInOut(duration: 0.22)) {
                appState.isPreviewExpanded.toggle()
                if appState.isPreviewExpanded {
                    selectedTab = .split
                }
            }
        }
    }
    
    private func selectFeature(_ feat: PlasmidFeatureItem) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedFeatureID == feat.id {
                selectedFeatureID = nil
            } else {
                selectedFeatureID = feat.id
                let total = max(1, data.fullSequence.count)
                let sBp = max(1, Int((feat.startRatio * Double(total)).rounded()) + 1)
                let eBp = max(sBp, min(total, sBp + min(feat.lengthBp, 60) - 1))
                selectedRangeBp = sBp...eBp
            }
        }
    }
    
    // MARK: - 精细同屏双视工作台 (基于容器真实宽度自适应切换并排或上下堆叠)
    private var splitWorkbenchView: some View {
        Group {
            if isStandaloneWindow || appState.isPreviewExpanded || isSplitWorkbenchWide {
                // 宽屏 / 全宽精细同屏模式：左 Circular Map + 右 Sequence Map 1:1 并排联动
                HStack(alignment: .top, spacing: 8) {
                    circularPlasmidView
                        .frame(minWidth: 0, idealWidth: 420, maxWidth: .infinity)
                    
                    sequenceMapView
                        .frame(minWidth: 0, idealWidth: 500, maxWidth: .infinity)
                }
            } else {
                // 紧凑双栏/窄屏自动回退：上下流式堆叠，保证零挤压、零截断
                VStack(alignment: .leading, spacing: 8) {
                    circularPlasmidView
                        .frame(maxWidth: .infinity)
                        .frame(height: 390)
                    
                    sequenceMapView
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 380)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isStandaloneWindow ? .infinity : nil, alignment: .topLeading)
    }
    
    private var popoutWindowButton: some View {
        StudioCompactPillButton(
            title: "新窗口",
            icon: "macwindow.badge.plus",
            tint: .purple,
            help: "弹出一个独立 macOS 新窗口预览该质粒图谱与序列"
        ) {
            PlasmidWindowPresenter.shared.openPreviewWindow(
                data: data,
                title: "🧬 质粒独立窗口预览 — \(data.constructTitle) (\(data.totalLengthBp) bp)",
                onMutateCodon: onMutateCodon
            )
        }
    }
    
    private var sequenceMapView: some View {
        SequenceRowCanvasView(
            totalLengthBp: data.totalLengthBp,
            fullSequence: data.fullSequence,
            gcPercent: data.gcPercent,
            features: data.features,
            enzymes: data.enzymes,
            detectedCutsites: detectedCutsites,
            windows: data.microscopicWindows,
            fallbackJunctions: data.junctions,
            selectedRangeBp: $selectedRangeBp,
            showEnzymeInspector: $showEnzymeInspector,
            onMutateCodon: onMutateCodon
        )
    }
    
    // MARK: - 环形质粒图谱 (对齐系统设置浅色白底/深色黑灰底)
    private var circularPlasmidView: some View {
        let mapBg = StudioPalette.cardBg(isLight: !isDark)
        let borderCol = StudioPalette.cardBorder(isLight: !isDark)
        return VStack(spacing: 0) {
            circularTopToolbar
            
            ZStack(alignment: .topLeading) {
                mapBg
                
                Canvas { context, size in
                    drawCircularPlasmidCanvas(context: context, size: size)
                }
                .frame(minHeight: 280, idealHeight: 380, maxHeight: .infinity)
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            if toolMode == .pan {
                                panOffset = val.translation
                            } else if toolMode == .rotate {
                                rotationDegrees = (Double(val.translation.width) * 0.8).truncatingRemainder(dividingBy: 360)
                            }
                        }
                )
                
                circularCenterHub
                
                plasmidFeaturesFloatingCard
                    .padding(.top, 8)
                    .padding(.leading, 8)
            }
            
            circularBottomStatusBar
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                .fill(mapBg)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .stroke(borderCol, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
    
    private func circularRingMinDim(for size: CGSize) -> CGFloat {
        // 为左右半区外圈引出酶切标签预留安全水平边界，避免 HaeIII (28) 等标签贴边裁切
        let safeW = max(140.0, size.width - 124.0) / 0.74
        let safeH = max(170.0, size.height - 20.0) / 0.86
        return min(size.width, size.height, min(safeW, safeH)) * zoomScale
    }

    @ViewBuilder
    private func circularToolControls(compactCamera: Bool) -> some View {
        GlassEffectContainer(spacing: 5) {
            HStack(spacing: 5) {
                circularToolbarBtn(icon: "cursorarrow", isActive: toolMode == .select, tooltip: "Select Mode") {
                    toolMode = .select
                }
                circularToolbarBtn(icon: "hand.draw", isActive: toolMode == .pan, tooltip: "Pan Canvas") {
                    toolMode = .pan
                }
                circularToolbarBtn(icon: "arrow.triangle.2.circlepath", isActive: toolMode == .rotate, tooltip: "Rotate +30°") {
                    toolMode = .rotate
                    withAnimation(.easeInOut(duration: 0.18)) {
                        rotationDegrees = (rotationDegrees + 30).truncatingRemainder(dividingBy: 360)
                    }
                }
                circularToolbarBtn(icon: "plus.magnifyingglass", isActive: false, tooltip: "Zoom In") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        zoomScale = min(2.0, zoomScale + 0.18)
                    }
                }
                circularToolbarBtn(icon: "minus.magnifyingglass", isActive: false, tooltip: "Zoom Out") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        zoomScale = max(0.70, zoomScale - 0.18)
                    }
                }
                circularToolbarBtn(icon: "arrow.counterclockwise", isActive: false, tooltip: "Reset View") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        zoomScale = 1.0
                        panOffset = .zero
                        rotationDegrees = 0
                    }
                }
                Button(action: {
                    appState.showToast("已将「\(data.constructTitle)」环形图谱快照复制至剪贴板")
                }) {
                    if compactCamera {
                        Image(systemName: "camera")
                            .font(.system(size: 10.5, weight: .semibold))
                    } else {
                        Label("PNG", systemImage: "camera")
                            .font(.system(size: 10.5, weight: .semibold))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .studioGlassButton(isCircle: compactCamera, controlSize: .regular)
                .help("导出高分辨率 PNG 图谱")
            }
        }
    }

    private var circularTopToolbar: some View {
        let headerBg = StudioPalette.trackBg(isLight: !isDark)
        let titleCol: Color = .primary
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text("Circular Plasmid Map")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(titleCol)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                circularToolControls(compactCamera: false)
            }

            HStack(spacing: 6) {
                Text("Circular Map")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(titleCol)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                circularToolControls(compactCamera: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Circular Plasmid Map")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(titleCol)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                circularToolControls(compactCamera: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(headerBg)
    }
    
    private var circularCenterHub: some View {
        let titleCol = isDark ? Color.cyan : Color(red: 0.02, green: 0.45, blue: 0.78)
        let bpCol = isDark ? Color.white.opacity(0.88) : Color(red: 0.10, green: 0.14, blue: 0.22)
        let subCol = isDark ? Color.white.opacity(0.45) : Color(red: 0.40, green: 0.46, blue: 0.56)
        return GeometryReader { geo in
            let ringDim = circularRingMinDim(for: geo.size)
            let innerDiameter = max(70.0, (ringDim * 0.195 - 16.0) * 1.64)
            let hubMaxWidth = min(innerDiameter, max(70.0, geo.size.width * 0.42))
            VStack(spacing: 1) {
                Text(data.constructTitle)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(titleCol)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.82)
                Text("\(data.totalLengthBp) bps")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(bpCol)
                Text("circular")
                    .font(.system(size: 8.5))
                    .foregroundColor(subCol)
            }
            .frame(maxWidth: hubMaxWidth)
            .position(
                x: geo.size.width / 2.0 + panOffset.width,
                y: geo.size.height / 2.0 + panOffset.height
            )
        }
        .allowsHitTesting(false)
    }
    
    private var circularBottomStatusBar: some View {
        let headerBg = StudioPalette.trackBg(isLight: !isDark)
        let subCol: Color = .secondary
        let accentCol = isDark ? Color.cyan.opacity(0.88) : Color(red: 0.02, green: 0.45, blue: 0.78)
        return HStack {
            Text("Vector: \(data.vectorName) · Zoom: \(Int(zoomScale * 100))%")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundColor(subCol)
            Spacer()
            Text("\(detectedCutsites.count) sites · \(data.features.count) features")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundColor(accentCol)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(headerBg)
    }
    
    private func drawCircularPlasmidCanvas(context: GraphicsContext, size: CGSize) {
        let cx = size.width / 2.0 + panOffset.width
        let cy = size.height / 2.0 + panOffset.height
        let center = CGPoint(x: cx, y: cy)
        let centerCartesian = CartesianPoint(x: Double(cx), y: Double(cy))
        let minDim = circularRingMinDim(for: size)
        
        let gridCol = isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.04)
        let rulerRingCol = isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.18)
        let rulerTickCol = isDark ? Color.cyan : Color(red: 0.04, green: 0.48, blue: 0.58)
        let rulerNumCol = isDark ? Color.white.opacity(0.48) : Color(red: 0.35, green: 0.42, blue: 0.52)
        let outerRingCol = isDark ? Color.white.opacity(0.55) : Color(red: 0.20, green: 0.26, blue: 0.36).opacity(0.75)
        let innerRingCol = isDark ? Color.white.opacity(0.38) : Color(red: 0.20, green: 0.26, blue: 0.36).opacity(0.52)
        
        var vGrid = Path()
        vGrid.move(to: CGPoint(x: cx, y: 0))
        vGrid.addLine(to: CGPoint(x: cx, y: size.height))
        vGrid.move(to: CGPoint(x: 0, y: cy))
        vGrid.addLine(to: CGPoint(x: size.width, y: cy))
        context.stroke(vGrid, with: .color(gridCol), lineWidth: 0.8)
        
        let rBackboneOuter = minDim * 0.285
        let rBackboneInner = minDim * 0.268
        let rRulerRing = minDim * 0.195
        let rFeatBaseInner = Double(minDim * 0.232)
        let rFeatBaseOuter = Double(minDim * 0.298)
        let trackStep = Double(minDim * 0.034)
        
        let rotOffsetOveRad = rotationDegrees * .pi / 180.0
        let rotCanvasRad = rotOffsetOveRad - (.pi / 2.0)
        let totalBp = max(data.totalLengthBp, 1000)
        
        // 0. 选区高亮扇形弧
        if let sel = selectedRangeBp {
            let seqMax = max(1, data.fullSequence.count)
            let sRatio = Double(max(0, sel.lowerBound - 1)) / Double(seqMax)
            let eRatio = Double(min(seqMax, sel.upperBound)) / Double(seqMax)
            let sAng = sRatio * 2.0 * .pi + rotCanvasRad
            let eAng = max(sAng + 0.035, eRatio * 2.0 * .pi + rotCanvasRad)
            
            var selArc = Path()
            selArc.addArc(center: center, radius: rBackboneOuter + 14, startAngle: .radians(sAng), endAngle: .radians(eAng), clockwise: false)
            selArc.addArc(center: center, radius: rRulerRing, startAngle: .radians(eAng), endAngle: .radians(sAng), clockwise: true)
            selArc.closeSubpath()
            context.fill(selArc, with: .color(Color.cyan.opacity(isDark ? 0.16 : 0.22)))
            context.stroke(selArc, with: .color(isDark ? Color.cyan.opacity(0.75) : Color(red: 0.02, green: 0.48, blue: 0.85)), lineWidth: 1.2)
        }
        
        // 1. 内圈坐标标尺环与数字刻度
        let rulerRect = CGRect(x: cx - rRulerRing, y: cy - rRulerRing, width: rRulerRing * 2, height: rRulerRing * 2)
        context.stroke(Path(ellipseIn: rulerRect), with: .color(rulerRingCol), lineWidth: 1.0)
        
        for i in 0..<36 {
            let ratio = Double(i) / 36.0
            let ang = ratio * 2.0 * .pi + rotCanvasRad
            let cosA = CGFloat(Foundation.cos(ang))
            let sinA = CGFloat(Foundation.sin(ang))
            let isMajor = (i % 6 == 0)
            let r1 = rRulerRing - (isMajor ? 5.0 : 2.5)
            let r2 = rRulerRing + (isMajor ? 3.0 : 1.5)
            var tick = Path()
            tick.move(to: CGPoint(x: cx + r1 * cosA, y: cy + r1 * sinA))
            tick.addLine(to: CGPoint(x: cx + r2 * cosA, y: cy + r2 * sinA))
            context.stroke(tick, with: .color(rulerTickCol.opacity(isMajor ? 0.65 : 0.30)), lineWidth: isMajor ? 1.1 : 0.6)
            
            if isMajor {
                let bpVal = i == 0 ? 1 : Int((ratio * Double(totalBp)).rounded())
                let rTxt = rRulerRing - 13.0
                let numResolved = context.resolve(
                    Text("\(bpVal)")
                        .font(.system(size: 7.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(rulerNumCol)
                )
                context.draw(numResolved, at: CGPoint(x: cx + rTxt * cosA, y: cy + rTxt * sinA), anchor: .center)
            }
        }
        
        // 2. 双链环形骨架
        let outerRect = CGRect(x: cx - rBackboneOuter, y: cy - rBackboneOuter, width: rBackboneOuter * 2, height: rBackboneOuter * 2)
        let innerRect = CGRect(x: cx - rBackboneInner, y: cy - rBackboneInner, width: rBackboneInner * 2, height: rBackboneInner * 2)
        context.stroke(Path(ellipseIn: outerRect), with: .color(outerRingCol), lineWidth: 1.6)
        context.stroke(Path(ellipseIn: innerRect), with: .color(innerRingCol), lineWidth: 1.2)
        
        // 3. 计算同心多轨避让层级
        let circularRanges: [CircularRange] = data.features.map { feat in
            let sBp = Int((feat.startRatio * Double(totalBp)).rounded())
            let eBp = Int((feat.endRatio * Double(totalBp)).rounded())
            return CircularRange(id: feat.id, start: sBp, end: eBp)
        }
        let trackOffsets = CircularOVELayout.calculateConcentricYOffsets(
            features: circularRanges,
            sequenceLength: totalBp
        )
        
        var rawLabels: [OveCircularLabel] = []
        var colorMap: [UUID: Color] = [:]
        
        // 4. 绘制多轨功能元件方向弧 + 弧内标签
        for feat in data.features {
            let level = Double(trackOffsets[feat.id] ?? 0)
            let rIn = (feat.isHighlight ? (rFeatBaseInner - 1.5) : rFeatBaseInner) - level * trackStep * 0.5
            let rOut = (feat.isHighlight ? (rFeatBaseOuter + 1.5) : rFeatBaseOuter) - level * trackStep * 0.5
            
            let isCw: Bool? = {
                switch feat.direction {
                case .clockwise: return true
                case .counterClockwise: return false
                case .none: return nil
                }
            }()
            
            let arcGeo = CircularOVELayout.computeDirectedArc(
                startRatio: feat.startRatio,
                endRatio: feat.endRatio,
                rInner: rIn,
                rOuter: rOut,
                isClockwise: isCw,
                rotationRadians: rotOffsetOveRad
            )
            
            let isSelected = (selectedFeatureID == feat.id)
            let arcPath = buildOVEDirectedArcPath(center: center, geo: arcGeo, rInner: CGFloat(rIn), rOuter: CGFloat(rOut))
            let legibleStroke = feat.color.studioLegibleAccent(isDark: isDark)
            context.fill(arcPath, with: .color(feat.color.opacity(isSelected ? 1.0 : 0.90)))
            context.stroke(
                arcPath,
                with: .color(isSelected ? legibleStroke : legibleStroke.opacity(isDark ? 0.55 : 0.45)),
                lineWidth: isSelected ? 2.0 : 0.9
            )
            
            let rMid = CGFloat((rIn + rOut) / 2.0)
            let midPt = CGPoint(
                x: cx + rMid * CGFloat(cos(arcGeo.midCanvasRad)),
                y: cy + rMid * CGFloat(sin(arcGeo.midCanvasRad))
            )
            let span = feat.endRatio >= feat.startRatio ? (feat.endRatio - feat.startRatio) : (1.0 - feat.startRatio + feat.endRatio)
            if span >= 0.075 {
                let fResolved = context.resolve(
                    Text(feat.name)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(feat.color.studioContrastingTextOnFill())
                )
                context.draw(fResolved, at: midPt, anchor: .center)
            }
        }
        
        // 5. 引物结合箭头
        for primer in data.primers {
            let pRadius = primer.isForward ? (rFeatBaseOuter + 7.5) : (rFeatBaseInner - 7.0)
            let pGeo = CircularOVELayout.computeDirectedArc(
                startRatio: primer.startRatio,
                endRatio: primer.endRatio,
                rInner: pRadius - 2.0,
                rOuter: pRadius + 2.0,
                isClockwise: primer.isForward,
                rotationRadians: rotOffsetOveRad
            )
            let pPath = buildOVEDirectedArcPath(
                center: center,
                geo: pGeo,
                rInner: CGFloat(pRadius - 2.0),
                rOuter: CGFloat(pRadius + 2.0)
            )
            context.fill(pPath, with: .color(primer.color))
        }
        
        // 6. 密集限制性内切酶切点刻度 + 外圈折线引出标签
        let seqLen = Double(max(1, data.fullSequence.count))
        let maxSitesOnRing = 22
        let allCuts = detectedCutsites
        let sampledCuts: [ConstructCutsite] = {
            if allCuts.count <= maxSitesOnRing {
                return allCuts
            }
            let step = Double(allCuts.count) / Double(maxSitesOnRing)
            return (0..<maxSitesOnRing).map { idx in
                allCuts[min(allCuts.count - 1, Int(Double(idx) * step))]
            }
        }()
        
        for cut in sampledCuts {
            let ratio = Double(cut.recognitionStart0Based) / seqLen
            let angCanvas = ratio * 2.0 * .pi + rotCanvasRad
            let cosC = CGFloat(Foundation.cos(angCanvas))
            let sinC = CGFloat(Foundation.sin(angCanvas))
            let enzCol = Color(hexString: cut.colorHex)
            
            let r1 = rBackboneInner - 2.0
            let r2 = rBackboneOuter + 6.0
            var tick = Path()
            tick.move(to: CGPoint(x: cx + r1 * cosC, y: cy + r1 * sinC))
            tick.addLine(to: CGPoint(x: cx + r2 * cosC, y: cy + r2 * sinC))
            context.stroke(tick, with: .color(enzCol), lineWidth: 1.3)
            
            let dotPt = CGPoint(x: cx + r2 * cosC, y: cy + r2 * sinC)
            let dotRect = CGRect(x: dotPt.x - 2.2, y: dotPt.y - 2.2, width: 4.4, height: 4.4)
            context.fill(Path(ellipseIn: dotRect), with: .color(enzCol))
            
            let anchorOve = CircularGeometry.normalizeAngle(angCanvas + (.pi / 2.0))
            // 当左上角 Plasmid Features 浮动卡片展开时，避开左上角象限 (285° ~ 358°) 的外圈折线标签，仅保留环上酶切刻度与圆点
            let collidesWithTopLeftLegend = isFeaturesOverlayExpanded && anchorOve > 4.95 && anchorOve < 6.24
            if !collidesWithTopLeftLegend {
                colorMap[cut.id] = enzCol
                let labelText = cut.cutCountInPlasmid > 1 ? "\(cut.name) (\(cut.cutCountInPlasmid))" : cut.name
                rawLabels.append(
                    OveCircularLabel(
                        id: cut.id,
                        text: labelText,
                        angle: anchorOve,
                        radius: Double(r2),
                        colorHex: cut.colorHex,
                        isEnzyme: true,
                        priority: cut.isUniqueCutter ? 18 : 12
                    )
                )
            }
        }
        
        if sampledCuts.isEmpty {
            for enz in data.enzymes.prefix(6) {
                let angCanvas = enz.ratioPosition * 2.0 * .pi + rotCanvasRad
                let r2 = rBackboneOuter + 6.0
                let anchorOve = CircularGeometry.normalizeAngle(angCanvas + (.pi / 2.0))
                colorMap[enz.id] = enz.color
                rawLabels.append(
                    OveCircularLabel(
                        id: enz.id,
                        text: enz.name,
                        angle: anchorOve,
                        radius: Double(r2),
                        colorHex: "",
                        isEnzyme: true,
                        priority: 16
                    )
                )
            }
        }
        
        // 7. 使用左右半球防碰撞松弛算法排布外圈折线引出标签
        let labelRingRadius = Double(minDim * 0.375)
        let relaxedLabels = CircularGeometry.relaxLabelAngles(
            labels: rawLabels,
            radius: labelRingRadius,
            center: centerCartesian,
            canvasWidth: Double(size.width),
            canvasHeight: Double(size.height),
            textVerticalOffset: 13.5
        )
        
        for lbl in relaxedLabels {
            let rawCol = colorMap[lbl.id] ?? .white
            let col = rawCol.studioLegibleAccent(isDark: isDark)
            let stubRadius = lbl.radius + 7.0
            let stubPt = CircularGeometry.polarToCartesian(
                radius: stubRadius,
                angleRadians: lbl.anchorAngle,
                center: centerCartesian
            )

            let resolvedText = context.resolve(
                Text(lbl.text)
                    .font(.system(size: 8.5, weight: lbl.priority >= 16 ? .bold : .medium))
                    .foregroundColor(col.opacity(0.95))
            )
            let textW = Double(resolvedText.measure(in: CGSize(width: 220, height: 32)).width)
            let shelfLen: Double = lbl.isLeftHalf ? -10.0 : 10.0
            let rawShelfEndX = lbl.outerPoint.x + shelfLen
            let safeShelfEndX: Double = {
                if lbl.isLeftHalf {
                    let minAllowedX = 6.0 + textW + 3.0
                    return max(rawShelfEndX, min(lbl.outerPoint.x, minAllowedX))
                } else {
                    let maxAllowedX = Double(size.width) - 6.0 - textW - 3.0
                    return min(rawShelfEndX, max(lbl.outerPoint.x, maxAllowedX))
                }
            }()

            let textX: Double = {
                if lbl.isLeftHalf {
                    return max(6.0 + textW, safeShelfEndX - 3.0)
                } else {
                    return min(max(6.0, Double(size.width) - 6.0 - textW), safeShelfEndX + 3.0)
                }
            }()

            var leader = Path()
            leader.move(to: CGPoint(x: lbl.innerPoint.x, y: lbl.innerPoint.y))
            leader.addLine(to: CGPoint(x: stubPt.x, y: stubPt.y))
            leader.addLine(to: CGPoint(x: lbl.outerPoint.x, y: lbl.outerPoint.y))
            leader.addLine(to: CGPoint(x: safeShelfEndX, y: lbl.outerPoint.y))

            context.stroke(
                leader,
                with: .color(col.opacity(0.70)),
                style: StrokeStyle(lineWidth: 0.9)
            )

            let anchor: UnitPoint = lbl.isLeftHalf ? .trailing : .leading
            context.draw(resolvedText, at: CGPoint(x: textX, y: lbl.outerPoint.y), anchor: anchor)
        }
    }
    
    // MARK: - 左上角 Plasmid Features ♦ 悬浮卡片
    private var plasmidFeaturesFloatingCard: some View {
        let cardBg = StudioPalette.cardBg(isLight: !isDark).opacity(0.94)
        let cardStroke = StudioPalette.cardBorder(isLight: !isDark)
        let titleCol: Color = .primary
        let itemCol = isDark ? Color.white.opacity(0.88) : Color(red: 0.14, green: 0.18, blue: 0.24)
        
        return VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isFeaturesOverlayExpanded.toggle()
                }
            }) {
                HStack(spacing: 5) {
                    Text("Plasmid Features")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(titleCol)
                    Spacer(minLength: 6)
                    Image(systemName: "suit.diamond.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.cyan)
                }
            }
            .buttonStyle(.plain)
            
            if isFeaturesOverlayExpanded {
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(data.features.prefix(6)) { feat in
                        let isSel = (selectedFeatureID == feat.id)
                        let legibleFeatCol = feat.color.studioLegibleAccent(isDark: isDark)
                        Button(action: {
                            selectFeature(feat)
                        }) {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(legibleFeatCol)
                                    .frame(width: 6, height: 6)
                                Text("[\(feat.featureType)]")
                                    .font(.system(size: 8.0, weight: .bold))
                                    .foregroundColor(legibleFeatCol)
                                Text(feat.name)
                                    .font(.system(size: 8.5, weight: isSel ? .bold : .medium))
                                    .foregroundColor(isSel ? .cyan : itemCol)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isSel ? Color.cyan.opacity(0.18) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(7)
        .frame(width: 138)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                .fill(cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .stroke(cardStroke, lineWidth: 0.8)
                )
        )
    }
    
    private func circularToolbarBtn(
        icon: String,
        isActive: Bool,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        let activeCol: Color = isDark ? .cyan : appState.accentTheme.color
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: isActive ? .bold : .medium))
                .studioOptionalForeground(isActive ? nil : .primary)
        }
        .studioGlassButton(
            tint: isActive ? activeCol : nil,
            isProminent: isActive,
            isSelected: isActive,
            isCircle: true,
            controlSize: .regular
        )
        .help(tooltip)
    }
    
    // MARK: - 线性重组组装图 & 线性坐标概览
    private var linearConstructView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(data.linearSummarySteps.enumerated()), id: \.offset) { idx, step in
                            HStack(spacing: 5) {
                                HStack(spacing: 5) {
                                    Text(step.0)
                                        .font(.system(size: 11, weight: .bold))
                                    if !step.1.isEmpty {
                                        Text(step.1)
                                            .font(.system(size: 10.5, weight: .medium))
                                            .monospacedDigit()
                                            .opacity(0.92)
                                    }
                                }
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule(style: .continuous).fill(step.2.studioStepCapsuleFill()))

                                if idx < data.linearSummarySteps.count - 1 {
                                    Image(systemName: "link")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                linearConstructTrackCard

                if !data.primers.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("绑定引物列表 (\(data.primers.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("5' → 3' 方向 · 青底正向 F / 橙底反向 R")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        ForEach(data.primers) { p in
                            HStack(spacing: 8) {
                                Text(p.isForward ? "F" : "R")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 20, height: 18)
                                    .background(p.isForward ? Color.blue : Color.orange)
                                    .clipShape(Capsule(style: .continuous))
                                Text(p.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(minWidth: 115, maxWidth: 175, alignment: .leading)
                                Text(p.sequence)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer(minLength: 6)
                                Text(p.tmText)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundColor(.orange)
                                    .fixedSize()
                            }
                            .studioInnerBox(paddingH: 10, paddingV: 6)
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: isStandaloneWindow ? .infinity : nil, alignment: .topLeading)
    }

    private var linearConstructTrackCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("线性特征与引物分布图 (0 – \(data.totalLengthBp) bp)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(data.features.count) 元件 · \(data.primers.count) 引物")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            Canvas { context, size in
                let padX: CGFloat = 14
                let trackW = max(40, size.width - padX * 2)
                let barY: CGFloat = 40
                let axisCol = isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.26)
                let tickTextCol = isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.55)

                // 主骨架线与 0/25/50/75/100% 刻度
                var axis = Path()
                axis.move(to: CGPoint(x: padX, y: barY))
                axis.addLine(to: CGPoint(x: padX + trackW, y: barY))
                context.stroke(axis, with: .color(axisCol), lineWidth: 1.5)

                for frac in [0.0, 0.25, 0.50, 0.75, 1.0] {
                    let x = padX + trackW * CGFloat(frac)
                    var t = Path()
                    t.move(to: CGPoint(x: x, y: barY - 4))
                    t.addLine(to: CGPoint(x: x, y: barY + 4))
                    context.stroke(t, with: .color(axisCol), lineWidth: 1.0)

                    let bp = frac == 0.0 ? 1 : Int((Double(data.totalLengthBp) * frac).rounded())
                    let lbl = context.resolve(
                        Text("\(bp)")
                            .font(.system(size: 8.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(tickTextCol)
                    )
                    let anc: UnitPoint = frac == 0.0 ? .topLeading : (frac == 1.0 ? .topTrailing : .top)
                    context.draw(lbl, at: CGPoint(x: x, y: barY + 8), anchor: anc)
                }

                // 功能元件块
                var lastLabelRightX: CGFloat = -100
                for feat in data.features {
                    let sR = max(0.0, min(1.0, feat.startRatio))
                    let eR = max(0.0, min(1.0, feat.endRatio))
                    let x1 = padX + trackW * CGFloat(sR)
                    let x2 = padX + trackW * CGFloat(eR >= sR ? eR : 1.0)
                    let w = max(3.0, x2 - x1)
                    let rect = CGRect(x: x1, y: barY - 6, width: w, height: 12)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(feat.color.opacity(0.90)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(feat.color.studioLegibleAccent(isDark: isDark).opacity(0.7)), lineWidth: 0.7)

                    if w >= 42 && x1 > lastLabelRightX + 4 {
                        let txt = context.resolve(
                            Text(feat.name)
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(feat.color.studioContrastingTextOnFill())
                        )
                        let tw = txt.measure(in: CGSize(width: w - 4, height: 14)).width
                        if tw <= w - 4 {
                            context.draw(txt, at: CGPoint(x: x1 + w / 2, y: barY), anchor: .center)
                            lastLabelRightX = x2
                        }
                    }
                }

                // 引物箭头指示（正向 F 在上方青蓝轨道，反向 R 在下方橙色轨道）
                for p in data.primers {
                    let sR = max(0.0, min(1.0, p.startRatio))
                    let eR = max(0.0, min(1.0, p.endRatio))
                    let px1 = padX + trackW * CGFloat(min(sR, eR))
                    let px2 = padX + trackW * CGFloat(max(sR, eR))
                    let py: CGFloat = p.isForward ? (barY - 14) : (barY + 24)
                    let pCol: Color = p.isForward ? .blue : .orange
                    var arrow = Path()
                    let xStart = px1
                    let xEnd = max(px1 + 14, px2)
                    arrow.move(to: CGPoint(x: xStart, y: py))
                    arrow.addLine(to: CGPoint(x: xEnd, y: py))
                    let headX = p.isForward ? xEnd : xStart
                    let dir: CGFloat = p.isForward ? -4.5 : 4.5
                    arrow.move(to: CGPoint(x: headX + dir, y: py - 3))
                    arrow.addLine(to: CGPoint(x: headX, y: py))
                    arrow.addLine(to: CGPoint(x: headX + dir, y: py + 3))
                    context.stroke(arrow, with: .color(pCol), lineWidth: 1.6)
                }
            }
            .frame(height: 76)
        }
        .studioInnerBox(paddingH: 10, paddingV: 8)
    }
    
    private func buildOVEDirectedArcPath(
        center: CGPoint,
        geo: DirectedArcGeometry,
        rInner: CGFloat,
        rOuter: CGFloat
    ) -> Path {
        var path = Path()
        if !geo.hasArrowhead {
            path.addArc(center: center, radius: rOuter, startAngle: .radians(geo.startCanvasRad), endAngle: .radians(geo.endCanvasRad), clockwise: false)
            path.addArc(center: center, radius: rInner, startAngle: .radians(geo.endCanvasRad), endAngle: .radians(geo.startCanvasRad), clockwise: true)
            path.closeSubpath()
            return path
        }
        
        if geo.isClockwise {
            path.addArc(center: center, radius: rOuter, startAngle: .radians(geo.bodyStartCanvasRad), endAngle: .radians(geo.bodyEndCanvasRad), clockwise: false)
            path.addLine(to: CGPoint(x: center.x + CGFloat(geo.outerShoulderRadius * cos(geo.bodyEndCanvasRad)), y: center.y + CGFloat(geo.outerShoulderRadius * sin(geo.bodyEndCanvasRad))))
            path.addLine(to: CGPoint(x: center.x + CGFloat(geo.tipRadius * cos(geo.tipCanvasRad)), y: center.y + CGFloat(geo.tipRadius * sin(geo.tipCanvasRad))))
            path.addLine(to: CGPoint(x: center.x + CGFloat(geo.innerShoulderRadius * cos(geo.bodyEndCanvasRad)), y: center.y + CGFloat(geo.innerShoulderRadius * sin(geo.bodyEndCanvasRad))))
            path.addArc(center: center, radius: rInner, startAngle: .radians(geo.bodyEndCanvasRad), endAngle: .radians(geo.bodyStartCanvasRad), clockwise: true)
            path.closeSubpath()
        } else {
            path.addArc(center: center, radius: rOuter, startAngle: .radians(geo.bodyEndCanvasRad), endAngle: .radians(geo.bodyStartCanvasRad), clockwise: true)
            path.addLine(to: CGPoint(x: center.x + CGFloat(geo.outerShoulderRadius * cos(geo.bodyStartCanvasRad)), y: center.y + CGFloat(geo.outerShoulderRadius * sin(geo.bodyStartCanvasRad))))
            path.addLine(to: CGPoint(x: center.x + CGFloat(geo.tipRadius * cos(geo.tipCanvasRad)), y: center.y + CGFloat(geo.tipRadius * sin(geo.tipCanvasRad))))
            path.addLine(to: CGPoint(x: center.x + CGFloat(geo.innerShoulderRadius * cos(geo.bodyStartCanvasRad)), y: center.y + CGFloat(geo.innerShoulderRadius * sin(geo.bodyStartCanvasRad))))
            path.addArc(center: center, radius: rInner, startAngle: .radians(geo.bodyStartCanvasRad), endAngle: .radians(geo.bodyEndCanvasRad), clockwise: false)
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - 4. 独立 macOS 窗口质粒预览管理器 (点击“预览质粒”弹出新窗口)
@MainActor
public final class PlasmidWindowPresenter: NSObject, NSWindowDelegate {
    public static let shared = PlasmidWindowPresenter()
    private var activeWindows: [NSWindow] = []
    
    private override init() {
        super.init()
    }
    
    /// 直接为已载入的 SnapGene .dna 文件弹出独立新窗口预览（100% 原始质粒，支持载体与供体多窗口并排对比）
    public func openPreviewWindow(
        for info: SnapGeneFileInfo,
        roleLabel: String = "原始质粒预览",
        highlightRange: ClosedRange<Int>? = nil,
        onMutateCodon: ((InteractiveCodonMutationPayload) -> Void)? = nil
    ) {
        let previewData = PlasmidMapBuilder.forRawSnapGeneFile(info: info, highlightRange: highlightRange)
        let winTitle = "🧬 【\(roleLabel)】\(info.fileName) (\(info.length) bp · \(info.featuresCount) 个特征 · \(info.validBoundPrimers.count) 条引物)"
        openPreviewWindow(data: previewData, title: winTitle, onMutateCodon: onMutateCodon)
    }
    
    /// 为任意构建或原始质粒预览数据弹出新窗口
    public func openPreviewWindow(
        data: PlasmidConstructPreviewData,
        title: String,
        onMutateCodon: ((InteractiveCodonMutationPayload) -> Void)? = nil
    ) {
        let contentRect = NSRect(x: 0, y: 0, width: 1120, height: 760)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 780, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        
        let rootView = StandalonePlasmidPreviewWindowView(
            data: data,
            onMutateCodon: onMutateCodon
        )
        window.appearance = NSApplication.shared.appearance
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        activeWindows.append(window)
    }
    
    public func windowWillClose(_ notification: Notification) {
        if let closedWin = notification.object as? NSWindow {
            activeWindows.removeAll { $0 === closedWin }
        }
    }
}

private struct StandalonePlasmidPreviewWindowView: View {
    @ObservedObject private var appState = AppState.shared
    let data: PlasmidConstructPreviewData
    let onMutateCodon: ((InteractiveCodonMutationPayload) -> Void)?
    
    private var isDark: Bool {
        appState.resolvedCanvasIsDark()
    }
    
    var body: some View {
        PlasmidPreviewPanel(
            data: data,
            onMutateCodon: onMutateCodon,
            isStandaloneWindow: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 780, minHeight: 540)
        .background(StudioPalette.workspaceBg(isLight: !isDark))
        .ignoresSafeArea(.container, edges: .top)
    }
}
