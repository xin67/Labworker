import Foundation

/// 质粒克隆正/阴性菌落鉴定最佳单/双内切酶推荐引擎
/// 对比空载载体与重组目标载体序列，在 0.8%–2.0% 琼脂糖凝胶上筛选出条带数为 2–4 条、
/// 且正/阴性克隆条带迁移位移与分辨率差异最显著的 Top 3 方案。
public struct DiagnosticDigestEngine: Sendable {

    // MARK: - 1. 预设常用鉴定酶盘 (24 个高频率标准克隆内切酶)

    public static let defaultDiagnosticEnzymeNames: [String] = [
        "AgeI", "BamHI", "BglII", "ClaI", "DraI", "EcoRI",
        "EcoRV", "HindIII", "KpnI", "NcoI", "NdeI", "NheI",
        "NotI", "PstI", "PvuII", "SacI", "SacII", "SalI",
        "ScaI", "SmaI", "SpeI", "StuI", "XbaI", "XhoI"
    ]

    // MARK: - 2. 数据模型

    public struct DiagnosticDigestRecommendation: Identifiable, Sendable, Equatable, Codable {
        public var id: String { "\(rank)_\(enzymeNames.joined(separator: "_"))" }
        public let rank: Int
        public let enzymeNames: [String]
        public let recommendedGelConcentration: String
        public let preferredBuffer: String
        public let bufferCompatibilityPercent: Int
        public let emptyVectorBandsBp: [Int]
        public let recombinantBandsBp: [Int]
        public let maxMigrationShiftY: Double
        public let meanMigrationShiftY: Double
        public let minIntraLaneGapY: Double
        public let maxBandSizeDiffBp: Int
        public let score: Double
        public let rationale: String

        public init(
            rank: Int,
            enzymeNames: [String],
            recommendedGelConcentration: String,
            preferredBuffer: String,
            bufferCompatibilityPercent: Int,
            emptyVectorBandsBp: [Int],
            recombinantBandsBp: [Int],
            maxMigrationShiftY: Double,
            meanMigrationShiftY: Double,
            minIntraLaneGapY: Double,
            maxBandSizeDiffBp: Int,
            score: Double,
            rationale: String
        ) {
            self.rank = rank
            self.enzymeNames = enzymeNames
            self.recommendedGelConcentration = recommendedGelConcentration
            self.preferredBuffer = preferredBuffer
            self.bufferCompatibilityPercent = bufferCompatibilityPercent
            self.emptyVectorBandsBp = emptyVectorBandsBp
            self.recombinantBandsBp = recombinantBandsBp
            self.maxMigrationShiftY = maxMigrationShiftY
            self.meanMigrationShiftY = meanMigrationShiftY
            self.minIntraLaneGapY = minIntraLaneGapY
            self.maxBandSizeDiffBp = maxBandSizeDiffBp
            self.score = score
            self.rationale = rationale
        }
    }

    public struct DiagnosticDigestReport: Sendable, Equatable, Codable {
        public let emptyVectorLengthBp: Int
        public let recombinantLengthBp: Int
        public let isCircular: Bool
        public let evaluatedCombinations: Int
        public let topRecommendations: [DiagnosticDigestRecommendation]
        public let warnings: [String]

        public init(
            emptyVectorLengthBp: Int,
            recombinantLengthBp: Int,
            isCircular: Bool,
            evaluatedCombinations: Int,
            topRecommendations: [DiagnosticDigestRecommendation],
            warnings: [String]
        ) {
            self.emptyVectorLengthBp = emptyVectorLengthBp
            self.recombinantLengthBp = recombinantLengthBp
            self.isCircular = isCircular
            self.evaluatedCombinations = evaluatedCombinations
            self.topRecommendations = topRecommendations
            self.warnings = warnings
        }
    }

    // MARK: - 3. 理论酶切片段计算与 Top 3 推荐

    /// 模拟单酶切或双酶切产生的 DNA 条带长度列表 (bp，按降序排列)
    public static func digestFragments(
        sequence: String,
        enzymes: [RestrictionEnzyme],
        isCircular: Bool = true
    ) -> [Int] {
        let cleanSeq = BioSequence.clean(sequence)
        let totalLen = cleanSeq.count
        guard totalLen > 0 else { return [] }

        var cutPositions = Set<Int>()
        for enz in enzymes {
            for hit in enz.findDualStrandSites(in: cleanSeq, circular: isCircular) {
                cutPositions.insert(hit.topSnip0Based)
            }
        }
        let sorted = cutPositions.sorted()

        var fragments: [Int] = []
        if isCircular {
            if sorted.isEmpty {
                return [] // 未切开超螺旋环状载体，不计入有效酶切条带
            } else if sorted.count == 1 {
                fragments = [totalLen]
            } else {
                for i in 0..<sorted.count {
                    let nextPos = (i + 1 < sorted.count) ? sorted[i + 1] : (sorted[0] + totalLen)
                    fragments.append(max(1, nextPos - sorted[i]))
                }
            }
        } else {
            var prev = 0
            for pos in sorted {
                if pos > prev { fragments.append(pos - prev) }
                prev = pos
            }
            if totalLen > prev { fragments.append(totalLen - prev) }
        }
        return fragments.sorted(by: >)
    }

    private struct CandidateScore {
        let enzymeNames: [String]
        let gelConc: String
        let bufferName: String
        let bufferPct: Int
        let emptyBands: [Int]
        let recombBands: [Int]
        let maxShiftY: Double
        let meanShiftY: Double
        let minGapY: Double
        let maxDiffBp: Int
        let score: Double
    }

    /// 推荐空载 vs 重组载体最佳鉴定酶单/双酶切 Top N 方案
    public static func recommendTopDigests(
        emptyVectorSequence: String,
        recombinantSequence: String,
        isCircular: Bool = true,
        enzymeNames: [String]? = nil,
        minBands: Int = 2,
        maxBands: Int = 4,
        topN: Int = 3
    ) -> DiagnosticDigestReport {
        let cleanEmpty = BioSequence.clean(emptyVectorSequence)
        let cleanRecomb = BioSequence.clean(recombinantSequence)
        guard !cleanEmpty.isEmpty && !cleanRecomb.isEmpty else {
            return DiagnosticDigestReport(
                emptyVectorLengthBp: cleanEmpty.count,
                recombinantLengthBp: cleanRecomb.count,
                isCircular: isCircular,
                evaluatedCombinations: 0,
                topRecommendations: [],
                warnings: [L10n.t("输入空载或重组载体序列为空")]
            )
        }

        let db = RestrictionEnzymeDatabase.shared
        let rawNames = enzymeNames ?? defaultDiagnosticEnzymeNames
        var seenLower = Set<String>()
        var pool: [RestrictionEnzyme] = []
        for n in rawNames {
            let low = n.lowercased()
            if !seenLower.contains(low), let enz = db.find(name: n) {
                seenLower.insert(low)
                pool.append(enz)
            }
        }
        pool.sort { $0.name < $1.name }

        // 预扫描各酶在空载与重组载体上的单酶切位点数，过滤掉无切点或超频切割 (>6 切点) 的酶
        var viableEnzymes: [RestrictionEnzyme] = []
        var singleCacheEmpty: [String: [Int]] = [:]
        var singleCacheRecomb: [String: [Int]] = [:]
        for enz in pool {
            let negCuts = enz.findDualStrandSites(in: cleanEmpty, circular: isCircular).count
            let posCuts = enz.findDualStrandSites(in: cleanRecomb, circular: isCircular).count
            guard (negCuts >= 1 || posCuts >= 1), negCuts <= 6, posCuts <= 6 else { continue }
            viableEnzymes.append(enz)
            singleCacheEmpty[enz.name] = digestFragments(sequence: cleanEmpty, enzymes: [enz], isCircular: isCircular)
            singleCacheRecomb[enz.name] = digestFragments(sequence: cleanRecomb, enzymes: [enz], isCircular: isCircular)
        }

        func bestBuffer(for enzymes: [RestrictionEnzyme]) -> (name: String, activity: Int) {
            let compats = enzymes.map { db.bufferCompatibility(for: $0.name) }
            let options: [(String, (NEBBufferCompatibility) -> Int)] = [
                ("CutSmart", { $0.cutSmart }),
                ("r2.1", { $0.r2_1 }),
                ("r3.1", { $0.r3_1 }),
                ("r1.1", { $0.r1_1 })
            ]
            var bestName = "CutSmart"
            var bestAct = -1
            for (bName, getter) in options {
                let minAct = compats.map(getter).min() ?? 0
                if minAct > bestAct {
                    bestAct = minAct
                    bestName = bName
                }
            }
            return (bestName, max(0, bestAct))
        }

        func evaluatePair(enzymes: [RestrictionEnzyme], strictBoth2To4: Bool) -> CandidateScore? {
            let emptyAll: [Int]
            let recombAll: [Int]
            if enzymes.count == 1 {
                emptyAll = singleCacheEmpty[enzymes[0].name] ?? []
                recombAll = singleCacheRecomb[enzymes[0].name] ?? []
            } else {
                emptyAll = digestFragments(sequence: cleanEmpty, enzymes: enzymes, isCircular: isCircular)
                recombAll = digestFragments(sequence: cleanRecomb, enzymes: enzymes, isCircular: isCircular)
            }

            let emptyVis = emptyAll.filter { $0 >= 100 }
            let recombVis = recombAll.filter { $0 >= 100 }

            guard emptyAll.count <= 6, recombAll.count <= 6 else { return nil }
            if strictBoth2To4 {
                guard emptyVis.count >= minBands, emptyVis.count <= maxBands,
                      recombVis.count >= minBands, recombVis.count <= maxBands else { return nil }
            } else {
                guard recombVis.count >= minBands, recombVis.count <= maxBands,
                      emptyVis.count >= 1, emptyVis.count <= maxBands else { return nil }
            }

            let bufInfo = bestBuffer(for: enzymes)
            var bestConcScore: CandidateScore? = nil

            for conc in AgaroseGelConcentration.allCases {
                let yNeg = emptyVis.map { conc.migrationY(sizeBp: $0) }
                let yPos = recombVis.map { conc.migrationY(sizeBp: $0) }

                let dPos = yPos.map { yp in yNeg.map { abs(yp - $0) }.min() ?? 1.0 }
                let dNeg = yNeg.map { yn in yPos.map { abs(yn - $0) }.min() ?? 1.0 }
                let maxShiftY = max(dPos.max() ?? 0.0, dNeg.max() ?? 0.0)
                guard maxShiftY >= 0.03 else { continue }

                let meanShiftY = (dPos.reduce(0.0, +) + dNeg.reduce(0.0, +)) / Double(dPos.count + dNeg.count)

                let sNeg = yNeg.sorted()
                let sPos = yPos.sorted()
                var gaps: [Double] = []
                if sNeg.count >= 2 {
                    for i in 0..<(sNeg.count - 1) { gaps.append(sNeg[i + 1] - sNeg[i]) }
                }
                if sPos.count >= 2 {
                    for i in 0..<(sPos.count - 1) { gaps.append(sPos[i + 1] - sPos[i]) }
                }
                let minGapY = gaps.min() ?? 0.5

                let diffPosBp = recombVis.map { rp in emptyVis.map { abs(rp - $0) }.min() ?? rp }
                let diffNegBp = emptyVis.map { rn in recombVis.map { abs(rn - $0) }.min() ?? rn }
                let maxDiffBp = max(diffPosBp.max() ?? 0, diffNegBp.max() ?? 0)

                let shiftComp = min(45.0, maxShiftY * 180.0)
                let meanComp = min(20.0, meanShiftY * 120.0)
                let resComp = min(20.0, minGapY * 220.0) - (minGapY < 0.025 ? 15.0 : 0.0)
                let countBonus = (emptyVis.count != recombVis.count) ? 6.0 : 0.0
                let bufBonus: Double
                if enzymes.count == 1 {
                    bufBonus = 5.0
                } else if bufInfo.activity >= 100 {
                    bufBonus = 4.0
                } else if bufInfo.activity >= 75 {
                    bufBonus = 1.5
                } else {
                    bufBonus = -8.0
                }
                let hasExtreme = (emptyVis + recombVis).contains { $0 < 150 || $0 > 12000 }
                let rangePenalty = hasExtreme ? -10.0 : 0.0
                let totalScore = max(0.0, min(100.0, shiftComp + meanComp + resComp + countBonus + bufBonus + rangePenalty))

                let cand = CandidateScore(
                    enzymeNames: enzymes.map(\.name),
                    gelConc: conc.rawValue,
                    bufferName: bufInfo.name,
                    bufferPct: bufInfo.activity,
                    emptyBands: emptyVis,
                    recombBands: recombVis,
                    maxShiftY: maxShiftY,
                    meanShiftY: meanShiftY,
                    minGapY: minGapY,
                    maxDiffBp: maxDiffBp,
                    score: totalScore
                )
                if let cur = bestConcScore {
                    if cand.score > cur.score + 1e-9 {
                        bestConcScore = cand
                    }
                } else {
                    bestConcScore = cand
                }
            }
            return bestConcScore
        }

        var combinations: [[RestrictionEnzyme]] = viableEnzymes.map { [$0] }
        if viableEnzymes.count >= 2 {
            for i in 0..<(viableEnzymes.count - 1) {
                for j in (i + 1)..<viableEnzymes.count {
                    combinations.append([viableEnzymes[i], viableEnzymes[j]])
                }
            }
        }

        var strictHits: [CandidateScore] = []
        for combo in combinations {
            if let scored = evaluatePair(enzymes: combo, strictBoth2To4: true) {
                strictHits.append(scored)
            }
        }

        var finalPool = strictHits
        var warnings: [String] = []
        if finalPool.count < topN {
            var seenKeys = Set(finalPool.map { $0.enzymeNames.joined(separator: "+") })
            for combo in combinations {
                let key = combo.map(\.name).joined(separator: "+")
                if seenKeys.contains(key) { continue }
                if let relaxed = evaluatePair(enzymes: combo, strictBoth2To4: false) {
                    finalPool.append(relaxed)
                    seenKeys.insert(key)
                }
            }
            if strictHits.isEmpty && !finalPool.isEmpty {
                warnings.append(L10n.tr("未能找到空载与重组载体均严格产生 \(minBands)–\(maxBands) 条带的组合，已补充单带对照候选方案。", "No digest strictly yielded \(minBands)–\(maxBands) bands for both vectors; supplemented with single-band candidates."))
            }
        }

        finalPool.sort { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            if abs(a.maxShiftY - b.maxShiftY) > 1e-9 { return a.maxShiftY > b.maxShiftY }
            if a.enzymeNames.count != b.enzymeNames.count { return a.enzymeNames.count < b.enzymeNames.count }
            return a.enzymeNames.joined(separator: "+") < b.enzymeNames.joined(separator: "+")
        }

        let topItems = Array(finalPool.prefix(topN)).enumerated().map { idx, item in
            let negStr = item.emptyBands.map(String.init).joined(separator: " / ")
            let posStr = item.recombBands.map(String.init).joined(separator: " / ")
            let rationale = L10n.tr("\(item.enzymeNames.joined(separator: " + ")) (\(item.bufferName) \(item.bufferPct)%): 空载 [\(negStr)] bp vs 重组 [\(posStr)] bp，\(item.gelConc) 胶最大迁移差 Δy=\(String(format: "%.3f", item.maxShiftY))", "\(item.enzymeNames.joined(separator: " + ")) (\(item.bufferName) \(item.bufferPct)%): Empty [\(negStr)] bp vs Recomb [\(posStr)] bp, max shift on \(item.gelConc) gel Δy=\(String(format: "%.3f", item.maxShiftY))")
            return DiagnosticDigestRecommendation(
                rank: idx + 1,
                enzymeNames: item.enzymeNames,
                recommendedGelConcentration: item.gelConc,
                preferredBuffer: item.bufferName,
                bufferCompatibilityPercent: item.bufferPct,
                emptyVectorBandsBp: item.emptyBands,
                recombinantBandsBp: item.recombBands,
                maxMigrationShiftY: item.maxShiftY,
                meanMigrationShiftY: item.meanShiftY,
                minIntraLaneGapY: item.minGapY,
                maxBandSizeDiffBp: item.maxDiffBp,
                score: item.score,
                rationale: rationale
            )
        }

        if topItems.isEmpty {
            warnings.append(L10n.t("在可用酶切面板中未找到可区分空载与重组载体的有效鉴定方案。"))
        }

        return DiagnosticDigestReport(
            emptyVectorLengthBp: cleanEmpty.count,
            recombinantLengthBp: cleanRecomb.count,
            isCircular: isCircular,
            evaluatedCombinations: combinations.count,
            topRecommendations: topItems,
            warnings: warnings
        )
    }
}
