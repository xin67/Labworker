import Foundation
import Accelerate

/// Synthego ICE / TIDE 风格 Sanger 编辑池四色峰图解卷积引擎
/// 使用 Apple 原生 Accelerate (vDSP) 实现 Lawson-Hanson Active-Set 非负最小二乘 (NNLS) 求解器（零外部 C++ 依赖）
public struct CRISPRDeconvolutionEngine: Sendable {

    // MARK: - 1. 数据模型

    /// 单个移码或修复分量的贡献度条目
    public struct ComponentContribution: Identifiable, Sendable, Equatable, Codable {
        public var id: String { label }
        public let label: String            // 如 "-1", "0", "+1", "HDR"
        public let shiftBp: Int?            // NHEJ 移码长度 (-30...+20)，HDR 分量为 nil
        public let isHDR: Bool              // 是否为 HDR Donor 分量
        public let isFrameshift: Bool       // 是否导致编码框移码 (|shiftBp| % 3 != 0) 或长片段功能敲除 (<= -21 bp)
        public let rawWeight: Double        // NNLS 原始非负回归系数
        public let percent: Double          // 归一化百分比 (0.0 - 100.0)
        public let sePercent: Double?       // 支持集重拟合后的近似百分比标准误
        public let pValue: Double?          // 单分量显著性 p 值（双侧 t 近似）

        public init(
            label: String,
            shiftBp: Int?,
            isHDR: Bool,
            isFrameshift: Bool,
            rawWeight: Double,
            percent: Double,
            sePercent: Double? = nil,
            pValue: Double? = nil
        ) {
            self.label = label
            self.shiftBp = shiftBp
            self.isHDR = isHDR
            self.isFrameshift = isFrameshift
            self.rawWeight = rawWeight
            self.percent = percent
            self.sePercent = sePercent
            self.pValue = pValue
        }
    }

    /// 解卷积边界告警代码
    public enum DeconvolutionWarning: String, Sendable, Equatable, Codable {
        case windowTruncatedAt3PrimeEnd = "WINDOW_TRUNCATED_AT_3PRIME_END"
        case lowFitRSquared = "LOW_FIT_R_SQUARED"
        case sgRNANotFoundInWT = "SGRNA_NOT_FOUND_IN_WT"
        case cutSiteTooCloseTo5Prime = "CUT_SITE_TOO_CLOSE_TO_5PRIME"
        case insufficientDownstreamWindow = "INSUFFICIENT_DOWNSTREAM_WINDOW"
        case hdrCollinearWithWT = "HDR_COLLINEAR_WITH_WT"
        case hdrAlignmentFailed = "HDR_ALIGNMENT_FAILED"
    }

    /// Sanger 编辑池解卷积完整输出报告
    public struct DeconvolutionResult: Sendable, Equatable, Codable {
        public let cutIndex0Based: Int
        public let isReverseStrandSgRNA: Bool
        public let requestedWindowBp: Int
        public let effectiveWindowBp: Int
        public let shiftMinBp: Int
        public let shiftMaxBp: Int
        public let wtPercent: Double
        public let indelPercent: Double
        public let koScore: Double
        public let hdrPercent: Double
        public let totalEditedPercent: Double
        public let rSquared: Double
        public let residualNorm: Double
        public let contributions: [ComponentContribution]
        public let dominantIndels: [ComponentContribution]
        public let warnings: [DeconvolutionWarning]
        /// 上游对齐测得的 Edited 相对 WT 偏移（bp）
        public let alignmentOffsetBp: Int
        /// WT 与 HDR 列向量的余弦相似度（用于共线性诊断）
        public let hdrWTCosineSimilarity: Double?

        public init(
            cutIndex0Based: Int,
            isReverseStrandSgRNA: Bool,
            requestedWindowBp: Int,
            effectiveWindowBp: Int,
            shiftMinBp: Int,
            shiftMaxBp: Int,
            wtPercent: Double,
            indelPercent: Double,
            koScore: Double,
            hdrPercent: Double,
            totalEditedPercent: Double,
            rSquared: Double,
            residualNorm: Double,
            contributions: [ComponentContribution],
            dominantIndels: [ComponentContribution],
            warnings: [DeconvolutionWarning],
            alignmentOffsetBp: Int = 0,
            hdrWTCosineSimilarity: Double? = nil
        ) {
            self.cutIndex0Based = cutIndex0Based
            self.isReverseStrandSgRNA = isReverseStrandSgRNA
            self.requestedWindowBp = requestedWindowBp
            self.effectiveWindowBp = effectiveWindowBp
            self.shiftMinBp = shiftMinBp
            self.shiftMaxBp = shiftMaxBp
            self.wtPercent = wtPercent
            self.indelPercent = indelPercent
            self.koScore = koScore
            self.hdrPercent = hdrPercent
            self.totalEditedPercent = totalEditedPercent
            self.rSquared = rSquared
            self.residualNorm = residualNorm
            self.contributions = contributions
            self.dominantIndels = dominantIndels
            self.warnings = warnings
            self.alignmentOffsetBp = alignmentOffsetBp
            self.hdrWTCosineSimilarity = hdrWTCosineSimilarity
        }
    }

    // MARK: - 2. Accelerate (vDSP) 原生 Lawson-Hanson Active-Set NNLS 求解器

    /// 使用 Apple Accelerate (vDSP) 求解非负最小二乘问题：
    ///   min_{w >= 0} || X * w - y ||_2^2
    public static func solveNNLS(
        matrixColumns: [[Double]],
        rhs: [Double],
        maxIterations: Int? = nil,
        tolerance: Double = 1e-11
    ) -> (weights: [Double], residualNorm: Double) {
        let n = matrixColumns.count
        let m = rhs.count
        guard n > 0, m > 0, matrixColumns.allSatisfy({ $0.count == m }) else {
            return (Array(repeating: 0.0, count: max(0, n)), 0.0)
        }

        let maxIter = maxIterations ?? max(50, 3 * n)
        var x = Array(repeating: 0.0, count: n)
        var passiveSet: [Int] = []
        passiveSet.reserveCapacity(n)
        var isPassive = Array(repeating: false, count: n)

        var maxColNorm = 1.0
        for col in matrixColumns {
            var sumSq = 0.0
            vDSP_svesqD(col, 1, &sumSq, vDSP_Length(m))
            maxColNorm = max(maxColNorm, sqrt(sumSq))
        }
        let dualTol = tolerance * maxColNorm

        func computeResidual(_ currentX: [Double]) -> [Double] {
            var r = rhs
            for j in 0..<n {
                let wj = currentX[j]
                guard wj != 0.0 else { continue }
                var negWj = -wj
                vDSP_vsmaD(matrixColumns[j], 1, &negWj, r, 1, &r, 1, vDSP_Length(m))
            }
            return r
        }

        func computeDualGradient(_ residual: [Double]) -> [Double] {
            var grad = Array(repeating: 0.0, count: n)
            for j in 0..<n {
                var dot = 0.0
                vDSP_dotprD(matrixColumns[j], 1, residual, 1, &dot, vDSP_Length(m))
                grad[j] = dot
            }
            return grad
        }

        func solvePassiveLeastSquares(_ pIndices: [Int]) -> [Double] {
            let k = pIndices.count
            guard k > 0 else { return [] }
            var qrCols = pIndices.map { matrixColumns[$0] }
            var qtB = rhs

            let steps = min(k, m)
            for j in 0..<steps {
                let subLen = m - j
                guard subLen > 0 else { break }

                var normSq = 0.0
                qrCols[j].withUnsafeBufferPointer { buf in
                    vDSP_svesqD(buf.baseAddress! + j, 1, &normSq, vDSP_Length(subLen))
                }
                let norm = sqrt(normSq)
                if norm < 1e-14 {
                    continue
                }

                let pivot = qrCols[j][j]
                let alpha = (pivot >= 0.0) ? -norm : norm
                var v = Array(qrCols[j][j..<m])
                v[0] -= alpha

                var vNormSq = 0.0
                vDSP_svesqD(v, 1, &vNormSq, vDSP_Length(subLen))

                qrCols[j][j] = alpha
                for row in (j + 1)..<m {
                    qrCols[j][row] = 0.0
                }

                guard vNormSq > 1e-28 else { continue }

                if j + 1 < k {
                    for c in (j + 1)..<k {
                        var dot = 0.0
                        qrCols[c].withUnsafeBufferPointer { cBuf in
                            vDSP_dotprD(v, 1, cBuf.baseAddress! + j, 1, &dot, vDSP_Length(subLen))
                        }
                        var scale = -2.0 * dot / vNormSq
                        var slice = Array(qrCols[c][j..<m])
                        vDSP_vsmaD(v, 1, &scale, slice, 1, &slice, 1, vDSP_Length(subLen))
                        for idx in 0..<subLen {
                            qrCols[c][j + idx] = slice[idx]
                        }
                    }
                }

                var dotB = 0.0
                qtB.withUnsafeBufferPointer { bBuf in
                    vDSP_dotprD(v, 1, bBuf.baseAddress! + j, 1, &dotB, vDSP_Length(subLen))
                }
                var scaleB = -2.0 * dotB / vNormSq
                var bSlice = Array(qtB[j..<m])
                vDSP_vsmaD(v, 1, &scaleB, bSlice, 1, &bSlice, 1, vDSP_Length(subLen))
                for idx in 0..<subLen {
                    qtB[j + idx] = bSlice[idx]
                }
            }

            var sP = Array(repeating: 0.0, count: k)
            for r in stride(from: min(k, m) - 1, through: 0, by: -1) {
                var val = qtB[r]
                if r + 1 < k {
                    for c in (r + 1)..<k {
                        val -= qrCols[c][r] * sP[c]
                    }
                }
                let diag = qrCols[r][r]
                sP[r] = abs(diag) > 1e-12 ? (val / diag) : 0.0
            }
            return sP
        }

        var residual = computeResidual(x)
        var dualGrad = computeDualGradient(residual)
        var outerIter = 0

        while outerIter < maxIter {
            outerIter += 1

            var bestIdx = -1
            var bestGrad = dualTol
            for j in 0..<n where !isPassive[j] {
                if dualGrad[j] > bestGrad {
                    bestGrad = dualGrad[j]
                    bestIdx = j
                }
            }

            if bestIdx == -1 {
                break
            }

            passiveSet.append(bestIdx)
            isPassive[bestIdx] = true

            var innerIter = 0
            let maxInner = max(20, 2 * n)
            while innerIter < maxInner {
                innerIter += 1
                let sP = solvePassiveLeastSquares(passiveSet)
                let minSP = sP.min() ?? 0.0

                if minSP > 0.0 {
                    for (localIdx, colIdx) in passiveSet.enumerated() {
                        x[colIdx] = sP[localIdx]
                    }
                    break
                }

                var alpha = 1.0
                for (localIdx, colIdx) in passiveSet.enumerated() {
                    let sj = sP[localIdx]
                    if sj <= 0.0 {
                        let xj = x[colIdx]
                        let denom = xj - sj
                        if denom > 0.0 {
                            let ratio = xj / denom
                            if ratio < alpha {
                                alpha = ratio
                            }
                        } else {
                            alpha = 0.0
                        }
                    }
                }

                var newPassive: [Int] = []
                newPassive.reserveCapacity(passiveSet.count)
                for (localIdx, colIdx) in passiveSet.enumerated() {
                    let updated = x[colIdx] + alpha * (sP[localIdx] - x[colIdx])
                    if updated <= 1e-13 {
                        x[colIdx] = 0.0
                        isPassive[colIdx] = false
                    } else {
                        x[colIdx] = updated
                        newPassive.append(colIdx)
                    }
                }
                passiveSet = newPassive
                if passiveSet.isEmpty {
                    break
                }
            }

            residual = computeResidual(x)
            dualGrad = computeDualGradient(residual)
        }

        residual = computeResidual(x)
        var resNormSq = 0.0
        vDSP_svesqD(residual, 1, &resNormSq, vDSP_Length(m))
        return (x, sqrt(resNormSq))
    }

    // MARK: - 3. 序列转标准四通道峰值矩阵、基线扣除、对齐与切点定位

    /// 清理 DNA 序列但严格保留 'N' 碱基，维持字符坐标与 ABIF 峰位矩阵 1:1 等长映射
    private static func cleanPreservingN(_ sequence: String) -> String {
        var out = String()
        out.reserveCapacity(sequence.count)
        for ch in sequence.uppercased() {
            switch ch {
            case "A", "C", "G", "T", "N": out.append(ch)
            case "U": out.append("T")
            default: break
            }
        }
        return out
    }

    /// 将 DNA 序列转换为标准四色荧光峰高矩阵 [[A, C, G, T]]（保留 'N' 退化四通道均值以保持 1:1 坐标映射）
    public static func peaksFromSequence(
        _ sequence: String,
        primarySignal: Double = 1000.0,
        backgroundSignal: Double = 20.0
    ) -> [[Double]] {
        let clean = cleanPreservingN(sequence)
        return clean.map { base in
            switch base {
            case "A": return [primarySignal, backgroundSignal, backgroundSignal, backgroundSignal]
            case "C": return [backgroundSignal, primarySignal, backgroundSignal, backgroundSignal]
            case "G": return [backgroundSignal, backgroundSignal, primarySignal, backgroundSignal]
            case "T": return [backgroundSignal, backgroundSignal, backgroundSignal, primarySignal]
            default:
                let mid = (primarySignal + 3.0 * backgroundSignal) / 4.0
                return [mid, mid, mid, mid]
            }
        }
    }

    /// 对四通道峰图矩阵执行逐通道局部基线扣除（取各通道 10% 分位数作为基线漂移）
    public static func subtractChannelBaselines(_ peaks: [[Double]], quantile: Double = 0.10) -> [[Double]] {
        guard !peaks.isEmpty else { return peaks }
        let n = peaks.count
        var baselines = [0.0, 0.0, 0.0, 0.0]
        for ch in 0..<4 {
            let vals = peaks.map { $0.count > ch ? $0[ch] : 0.0 }.sorted()
            let idx = min(n - 1, max(0, Int(Double(n - 1) * quantile)))
            baselines[ch] = vals[idx]
        }
        return peaks.map { row in
            [
                max(0.0, (row.count > 0 ? row[0] : 0.0) - baselines[0]),
                max(0.0, (row.count > 1 ? row[1] : 0.0) - baselines[1]),
                max(0.0, (row.count > 2 ? row[2] : 0.0) - baselines[2]),
                max(0.0, (row.count > 3 ? row[3] : 0.0) - baselines[3])
            ]
        }
    }

    /// Mott 质量修剪算法（Phred 经典最大子数组修剪）：返回高质量有效区间 [start, end)
    public static func mottQualityTrimRange(qualities: [Int], errorCutoff: Double = 0.05) -> Range<Int> {
        let n = qualities.count
        guard n > 0 else { return 0..<0 }
        // 若缺乏真实 Phred 质量分数（全 0），返回全区间
        if qualities.allSatisfy({ $0 <= 0 }) {
            return 0..<n
        }
        var curSum = 0.0
        var curStart = 0
        var bestSum = 0.0
        var bestStart = 0
        var bestEnd = 0
        for i in 0..<n {
            let q = Double(max(0, qualities[i]))
            let pErr = pow(10.0, -q / 10.0)
            let score = errorCutoff - pErr
            if curSum + score <= 0.0 {
                curSum = 0.0
                curStart = i + 1
            } else {
                curSum += score
                if curSum > bestSum {
                    bestSum = curSum
                    bestStart = curStart
                    bestEnd = i + 1
                }
            }
        }
        if bestEnd - bestStart < 20 {
            return 0..<n
        }
        return bestStart..<bestEnd
    }

    /// 估算 WT 局部主峰 RFU 振幅与背景基底（用于 HDR 列与插入基底的同量纲缩放）
    public static func estimateLocalSignalScale(
        wtPeaks: [[Double]],
        start: Int,
        end: Int
    ) -> (primary: Double, background: Double) {
        let s = max(0, min(wtPeaks.count, start))
        let e = max(s, min(wtPeaks.count, end))
        let slice = s < e ? Array(wtPeaks[s..<e]) : wtPeaks
        guard !slice.isEmpty else { return (1000.0, 0.0) }
        var primaries: [Double] = []
        var nonPrimaries: [Double] = []
        primaries.reserveCapacity(slice.count)
        nonPrimaries.reserveCapacity(slice.count * 3)
        for row in slice {
            let vals = [
                row.count > 0 ? row[0] : 0.0,
                row.count > 1 ? row[1] : 0.0,
                row.count > 2 ? row[2] : 0.0,
                row.count > 3 ? row[3] : 0.0
            ].sorted()
            primaries.append(vals[3])
            nonPrimaries.append(vals[0])
            nonPrimaries.append(vals[1])
            nonPrimaries.append(vals[2])
        }
        primaries.sort()
        nonPrimaries.sort()
        let medPrimary = max(1.0, primaries[primaries.count / 2])
        let medBg = nonPrimaries[nonPrimaries.count / 2]
        return (medPrimary, medBg)
    }

    /// 在切点上游窗口执行 WT 与 Edited 序列/四通道峰图互相关对齐，返回 edited 相对 WT 的偏移量 (editedCut0 = wtCut0 + offset)
    public static func estimateUpstreamAlignmentOffset(
        wtSequence: String,
        editedSequence: String,
        wtPeaks: [[Double]],
        editedPeaks: [[Double]],
        wtCutIndex0Based: Int,
        maxSearchOffset: Int = 50
    ) -> Int {
        let wtChars = Array(cleanPreservingN(wtSequence))
        let edChars = Array(cleanPreservingN(editedSequence))

        // 上游对齐窗口：跳过 5' 低质量首端与切口附近 15 bp 编辑扰动区
        let winEnd = max(0, wtCutIndex0Based - 15)
        let winStart = max(min(10, max(0, winEnd - 25)), winEnd - 95)

        // 策略 1：优先使用上游高特异性 12-20 nt 无 'N' 锚点精确子串匹配（含 'N' 时跳过并回落至策略 2 四通道互相关）
        if winEnd - winStart >= 12, wtChars.count >= winEnd, edChars.count >= 12 {
            let edStr = String(edChars)
            for anchorLen in [20, 16, 12] where winEnd - winStart >= anchorLen {
                let ancStart = winEnd - anchorLen
                let anchor = String(wtChars[ancStart..<winEnd])
                if anchor.contains("N") { continue }
                if let range = edStr.range(of: anchor) {
                    let edAncPos = edStr.distance(from: edStr.startIndex, to: range.lowerBound)
                    let candidateOffset = edAncPos - ancStart
                    if abs(candidateOffset) <= maxSearchOffset {
                        return candidateOffset
                    }
                }
            }
        }

        // 策略 2：四通道上游窗口归一化互相关（抗测序杂峰、'N' 模糊位点与单碱基错读）
        let pEnd = min(wtPeaks.count, max(0, wtCutIndex0Based - 10))
        let pStart = max(0, pEnd - 80)
        guard pEnd - pStart >= 12, !editedPeaks.isEmpty else { return 0 }

        var bestOffset = 0
        var bestScore = -Double.infinity
        let searchLim = min(maxSearchOffset, max(10, editedPeaks.count / 2))

        for delta in -searchLim...searchLim {
            var dot = 0.0
            var normW = 0.0
            var normE = 0.0
            var overlap = 0
            for idx in pStart..<pEnd {
                let eIdx = idx + delta
                guard eIdx >= 0 && eIdx < editedPeaks.count else { continue }
                let wp = wtPeaks[idx]
                let ep = editedPeaks[eIdx]
                for c in 0..<4 {
                    let wv = c < wp.count ? wp[c] : 0.0
                    let ev = c < ep.count ? ep[c] : 0.0
                    dot += wv * ev
                    normW += wv * wv
                    normE += ev * ev
                }
                overlap += 1
            }
            guard overlap >= 10, normW > 1e-12, normE > 1e-12 else { continue }
            let corr = dot / (sqrt(normW) * sqrt(normE))
            if corr > bestScore + 1e-9 || (abs(corr - bestScore) <= 1e-9 && abs(delta) < abs(bestOffset)) {
                bestScore = corr
                bestOffset = delta
            }
        }
        return bestOffset
    }

    /// 将任意长度的正义或反义 HDR Donor 模板自动对齐到 WT 切点，并按 WT 实测 RFU 尺度构造下游窗口峰值矩阵；
    /// 若供体与 WT 上游无同源锚点且不等长/一致性 < 80%，严格返回 nil 拒绝注入垃圾列。
    public static func alignAndScaleHDRWindow(
        wtSequence: String,
        hdrDonorSequence: String,
        wtCutIndex0Based: Int,
        requestedWindowBp: Int,
        wtPrimarySignal: Double,
        wtBackgroundSignal: Double
    ) -> [[Double]]? {
        let cleanWT = cleanPreservingN(wtSequence)
        let cleanHDRSense = BioSequence.clean(hdrDonorSequence)
        guard !cleanHDRSense.isEmpty else { return nil }
        let cleanHDRAntisense = BioSequence.reverseComplement(cleanHDRSense)

        let wtChars = Array(cleanWT)
        guard wtCutIndex0Based >= 0 && wtCutIndex0Based < wtChars.count else { return nil }

        func findAnchorCut(in candidateHDR: String) -> Int? {
            let candChars = Array(candidateHDR)
            for anchorLen in [20, 16, 12] {
                guard wtCutIndex0Based >= anchorLen + 3 else { continue }
                for back in stride(from: 4, through: min(50, wtCutIndex0Based - anchorLen), by: 2) {
                    let aStart = wtCutIndex0Based - back - anchorLen
                    let aEnd = aStart + anchorLen
                    guard aStart >= 0, aEnd <= wtChars.count else { continue }
                    let anchor = String(wtChars[aStart..<aEnd])
                    if anchor.contains("N") { continue }
                    if let range = candidateHDR.range(of: anchor) {
                        let hdrAncPos = candidateHDR.distance(from: candidateHDR.startIndex, to: range.lowerBound)
                        let candCut = hdrAncPos + (wtCutIndex0Based - aStart)
                        if candCut >= 0 && candCut < candChars.count {
                            return candCut
                        }
                    }
                }
            }
            return nil
        }

        func upstreamIdentityMatches(candidateHDR: String) -> Bool {
            let candChars = Array(candidateHDR)
            guard candChars.count == wtChars.count, wtCutIndex0Based >= 10 else { return false }
            let uStart = max(0, wtCutIndex0Based - 40)
            let uEnd = wtCutIndex0Based
            var matches = 0
            var compared = 0
            for i in uStart..<uEnd {
                if wtChars[i] == "N" { continue }
                compared += 1
                if candChars[i] == wtChars[i] { matches += 1 }
            }
            return compared >= 8 && (Double(matches) / Double(compared)) >= 0.80
        }

        // 优先正义链锚定，失败则尝试反义链 ssODN 锚定；仅等长且上游一致性 >= 80% 时允许回退 wtCutIndex0Based
        var resolvedHDR: String? = nil
        var resolvedCut: Int? = nil
        if let c = findAnchorCut(in: cleanHDRSense) {
            resolvedHDR = cleanHDRSense
            resolvedCut = c
        } else if let c = findAnchorCut(in: cleanHDRAntisense) {
            resolvedHDR = cleanHDRAntisense
            resolvedCut = c
        } else if upstreamIdentityMatches(candidateHDR: cleanHDRSense) {
            resolvedHDR = cleanHDRSense
            resolvedCut = wtCutIndex0Based
        } else if upstreamIdentityMatches(candidateHDR: cleanHDRAntisense) {
            resolvedHDR = cleanHDRAntisense
            resolvedCut = wtCutIndex0Based
        }

        guard let finalHDR = resolvedHDR, let hCut = resolvedCut else { return nil }
        let hdrChars = Array(finalHDR)

        // 构造下游 HDR 序列：若短 ssODN 在下游结束早于 requestedWindowBp，则通过下游同源臂无缝拼接 WT 剩余序列
        var hdrDownstreamChars: [Character] = Array(hdrChars[hCut..<min(hdrChars.count, hCut + requestedWindowBp)])
        if hdrDownstreamChars.count < requestedWindowBp, hdrDownstreamChars.count >= 12 {
            for tailLen in [16, 12] where hdrDownstreamChars.count >= tailLen {
                let tailAnchor = String(hdrDownstreamChars[(hdrDownstreamChars.count - tailLen)...])
                let searchStart = min(wtChars.count, wtCutIndex0Based)
                if searchStart < wtChars.count {
                    let wtTailStr = String(wtChars[searchStart...])
                    if let r = wtTailStr.range(of: tailAnchor) {
                        let wtEndOffset = searchStart + wtTailStr.distance(from: wtTailStr.startIndex, to: r.upperBound)
                        if wtEndOffset < wtChars.count {
                            let need = requestedWindowBp - hdrDownstreamChars.count
                            let extraEnd = min(wtChars.count, wtEndOffset + need)
                            hdrDownstreamChars.append(contentsOf: wtChars[wtEndOffset..<extraEnd])
                        }
                        break
                    }
                }
            }
        }

        return peaksFromSequence(
            String(hdrDownstreamChars),
            primarySignal: wtPrimarySignal,
            backgroundSignal: wtBackgroundSignal
        )
    }

    /// 在 WT 序列中定位 sgRNA (20nt) 及其 SpCas9 切割位点 (0-based 下标，保留 'N' 以确保与峰位数组 1:1 对齐)
    public static func locateCutSite(
        wtSequence: String,
        sgRNASequence: String
    ) -> (cutIndex0Based: Int, isReverseStrand: Bool)? {
        let cleanWT = cleanPreservingN(wtSequence)
        let cleanSg = BioSequence.clean(sgRNASequence)
        guard cleanWT.count >= cleanSg.count, cleanSg.count >= 12 else { return nil }

        if let range = cleanWT.range(of: cleanSg) {
            let start0 = cleanWT.distance(from: cleanWT.startIndex, to: range.lowerBound)
            let cut0 = start0 + cleanSg.count - 3
            return (cut0, false)
        }

        let rcSg = BioSequence.reverseComplement(cleanSg)
        if let rcRange = cleanWT.range(of: rcSg) {
            let start0 = cleanWT.distance(from: cleanWT.startIndex, to: rcRange.lowerBound)
            let cut0 = start0 + 3
            return (cut0, true)
        }

        return nil
    }

    // MARK: - 4. 核心四色峰值矩阵 NNLS 解卷积（TIDE/ICE 插入模型 + 稀疏重拟合 + 共线性诊断）

    /// 对切点下游窗口的四通道荧光峰矩阵执行 NNLS 解卷积
    public static func deconvolvePeakMatrices(
        wtPeaksACGT: [[Double]],
        editedWindowPeaksACGT: [[Double]],
        cutIndex0Based: Int,
        isReverseStrandSgRNA: Bool = false,
        requestedWindowBp: Int = 150,
        shiftRange: ClosedRange<Int> = -20...20,
        hdrWindowPeaksACGT: [[Double]]? = nil,
        noiseFloorWeight: Double = 1e-6,
        minComponentPercent: Double = 1.0,
        alignmentOffsetBp: Int = 0
    ) -> DeconvolutionResult {
        var warnings: [DeconvolutionWarning] = []
        let nWT = wtPeaksACGT.count
        let maxDeletion = max(0, -shiftRange.lowerBound)
        let maxInsertion = max(0, shiftRange.upperBound)

        if cutIndex0Based < maxInsertion {
            warnings.append(.cutSiteTooCloseTo5Prime)
        }

        let maxWTWindow = max(0, nWT - maxDeletion - cutIndex0Based)
        let editedAvail = editedWindowPeaksACGT.count
        let effectiveW = min(requestedWindowBp, maxWTWindow, editedAvail)

        if effectiveW < requestedWindowBp {
            warnings.append(.windowTruncatedAt3PrimeEnd)
        }
        if effectiveW < 30 {
            warnings.append(.insufficientDownstreamWindow)
        }

        guard effectiveW > 0, cutIndex0Based >= 0, cutIndex0Based < nWT else {
            return DeconvolutionResult(
                cutIndex0Based: cutIndex0Based,
                isReverseStrandSgRNA: isReverseStrandSgRNA,
                requestedWindowBp: requestedWindowBp,
                effectiveWindowBp: max(0, effectiveW),
                shiftMinBp: shiftRange.lowerBound,
                shiftMaxBp: shiftRange.upperBound,
                wtPercent: 0.0,
                indelPercent: 0.0,
                koScore: 0.0,
                hdrPercent: 0.0,
                totalEditedPercent: 0.0,
                rSquared: 0.0,
                residualNorm: 0.0,
                contributions: [],
                dominantIndels: [],
                warnings: warnings,
                alignmentOffsetBp: alignmentOffsetBp
            )
        }

        let m = effectiveW * 4
        let shifts = Array(shiftRange)
        // 统一使用下游分解窗 [cut0, cut0 + effectiveW] 估算局部主峰 RFU，消除 5'→3' 衰减偏差
        let (localPrimary, localBg) = estimateLocalSignalScale(
            wtPeaks: wtPeaksACGT,
            start: cutIndex0Based,
            end: min(nWT, cutIndex0Based + effectiveW)
        )
        let degenLevel = localBg + 0.25 * (localPrimary - localBg)

        // 设计矩阵列元数据：对 +1 插入展开为 {A, C, G, T} 四种子列（Synthego ICE 规范），
        // 对 >= +2 插入在 0..<s 位置使用退化均等基底 [0.25, 0.25, 0.25, 0.25] 避免错误串联重复
        struct ColMeta {
            let shiftIdx: Int? // 对应 shifts 中的索引；nil 表示 HDR
            let isHDR: Bool
        }
        var columns: [[Double]] = []
        var colMetas: [ColMeta] = []
        columns.reserveCapacity(shifts.count + 4)
        colMetas.reserveCapacity(shifts.count + 4)

        var wtColumnIndex: Int? = nil

        for (sIdx, s) in shifts.enumerated() {
            if s == 1 {
                // +1 bp 插入：显式枚举 4 种单碱基 {A, C, G, T}，k >= 1 接下游移位 WT
                for insBase in 0..<4 {
                    var col = Array(repeating: 0.0, count: m)
                    col[0] = (insBase == 0) ? localPrimary : localBg
                    col[1] = (insBase == 1) ? localPrimary : localBg
                    col[2] = (insBase == 2) ? localPrimary : localBg
                    col[3] = (insBase == 3) ? localPrimary : localBg
                    for k in 1..<effectiveW {
                        let srcIdx = min(max(0, cutIndex0Based + k - 1), nWT - 1)
                        let p = wtPeaksACGT[srcIdx]
                        let baseOffset = k * 4
                        col[baseOffset] = p.count > 0 ? p[0] : 0.0
                        col[baseOffset + 1] = p.count > 1 ? p[1] : 0.0
                        col[baseOffset + 2] = p.count > 2 ? p[2] : 0.0
                        col[baseOffset + 3] = p.count > 3 ? p[3] : 0.0
                    }
                    columns.append(col)
                    colMetas.append(ColMeta(shiftIdx: sIdx, isHDR: false))
                }
            } else if s >= 2 {
                // >= +2 bp 插入：0..<s 使用退化均等基底（ICE/TIDE 规范），k >= s 接下游移位 WT
                var col = Array(repeating: 0.0, count: m)
                for k in 0..<effectiveW {
                    let baseOffset = k * 4
                    if k < s {
                        col[baseOffset] = degenLevel
                        col[baseOffset + 1] = degenLevel
                        col[baseOffset + 2] = degenLevel
                        col[baseOffset + 3] = degenLevel
                    } else {
                        let srcIdx = min(max(0, cutIndex0Based + k - s), nWT - 1)
                        let p = wtPeaksACGT[srcIdx]
                        col[baseOffset] = p.count > 0 ? p[0] : 0.0
                        col[baseOffset + 1] = p.count > 1 ? p[1] : 0.0
                        col[baseOffset + 2] = p.count > 2 ? p[2] : 0.0
                        col[baseOffset + 3] = p.count > 3 ? p[3] : 0.0
                    }
                }
                columns.append(col)
                colMetas.append(ColMeta(shiftIdx: sIdx, isHDR: false))
            } else {
                // 缺失 (s < 0) 与 WT (s == 0)
                if s == 0 { wtColumnIndex = columns.count }
                var col = Array(repeating: 0.0, count: m)
                for k in 0..<effectiveW {
                    let srcIdx = min(max(0, cutIndex0Based + k - s), nWT - 1)
                    let p = wtPeaksACGT[srcIdx]
                    let baseOffset = k * 4
                    col[baseOffset] = p.count > 0 ? p[0] : 0.0
                    col[baseOffset + 1] = p.count > 1 ? p[1] : 0.0
                    col[baseOffset + 2] = p.count > 2 ? p[2] : 0.0
                    col[baseOffset + 3] = p.count > 3 ? p[3] : 0.0
                }
                columns.append(col)
                colMetas.append(ColMeta(shiftIdx: sIdx, isHDR: false))
            }
        }

        // 2. 可选追加 HDR Donor 列并检测 WT vs HDR 共线性
        let hasHDR: Bool
        var hdrColIdx: Int? = nil
        var hdrCosSim: Double? = nil
        if let hdrPeaks = hdrWindowPeaksACGT, hdrPeaks.count >= effectiveW {
            var hdrCol = Array(repeating: 0.0, count: m)
            for k in 0..<effectiveW {
                let p = hdrPeaks[k]
                let baseOffset = k * 4
                hdrCol[baseOffset] = p.count > 0 ? p[0] : 0.0
                hdrCol[baseOffset + 1] = p.count > 1 ? p[1] : 0.0
                hdrCol[baseOffset + 2] = p.count > 2 ? p[2] : 0.0
                hdrCol[baseOffset + 3] = p.count > 3 ? p[3] : 0.0
            }
            if let wtIdx = wtColumnIndex {
                let wtCol = columns[wtIdx]
                var dot = 0.0, nW = 0.0, nH = 0.0
                vDSP_dotprD(wtCol, 1, hdrCol, 1, &dot, vDSP_Length(m))
                vDSP_svesqD(wtCol, 1, &nW, vDSP_Length(m))
                vDSP_svesqD(hdrCol, 1, &nH, vDSP_Length(m))
                if nW > 1e-12 && nH > 1e-12 {
                    let cosVal = dot / (sqrt(nW) * sqrt(nH))
                    hdrCosSim = cosVal
                    if cosVal > 0.96 {
                        warnings.append(.hdrCollinearWithWT)
                    }
                }
            }
            hdrColIdx = columns.count
            columns.append(hdrCol)
            colMetas.append(ColMeta(shiftIdx: nil, isHDR: true))
            hasHDR = true
        } else {
            hasHDR = false
        }

        // 3. 展平观测向量 y (Edited 窗口四通道信号)
        var rhs = Array(repeating: 0.0, count: m)
        for k in 0..<effectiveW {
            let p = editedWindowPeaksACGT[k]
            let baseOffset = k * 4
            rhs[baseOffset] = p.count > 0 ? p[0] : 0.0
            rhs[baseOffset + 1] = p.count > 1 ? p[1] : 0.0
            rhs[baseOffset + 2] = p.count > 2 ? p[2] : 0.0
            rhs[baseOffset + 3] = p.count > 3 ? p[3] : 0.0
        }

        // 4. 初次 vDSP Lawson-Hanson NNLS 求解
        var (rawWeights, resNorm) = solveNNLS(matrixColumns: columns, rhs: rhs)

        // 5. Synthego ICE 风格稀疏剪枝（过滤 < minComponentPercent 的微弱噪声假克隆）+ 无偏支持集重拟合
        let initialSum = rawWeights.reduce(0.0, +)
        if initialSum > 1e-12 && minComponentPercent > 0.0 {
            // 先按移位聚合判断哪些逻辑分量 >= minComponentPercent
            var shiftAgg = Array(repeating: 0.0, count: shifts.count)
            var hdrAgg = 0.0
            for (cIdx, meta) in colMetas.enumerated() {
                if let sIdx = meta.shiftIdx {
                    shiftAgg[sIdx] += rawWeights[cIdx]
                } else if meta.isHDR {
                    hdrAgg += rawWeights[cIdx]
                }
            }
            let keepIndices: [Int] = colMetas.enumerated().compactMap { cIdx, meta in
                guard rawWeights[cIdx] >= noiseFloorWeight else { return nil }
                if let sIdx = meta.shiftIdx {
                    let pct = (shiftAgg[sIdx] / initialSum) * 100.0
                    return (pct >= minComponentPercent || shifts[sIdx] == 0) ? cIdx : nil
                } else {
                    let pct = (hdrAgg / initialSum) * 100.0
                    return pct >= minComponentPercent ? cIdx : nil
                }
            }
            if !keepIndices.isEmpty && keepIndices.count < columns.count {
                let subCols = keepIndices.map { columns[$0] }
                let (subW, subRes) = solveNNLS(matrixColumns: subCols, rhs: rhs)
                var refitW = Array(repeating: 0.0, count: columns.count)
                for (localIdx, origIdx) in keepIndices.enumerated() {
                    refitW[origIdx] = subW[localIdx]
                }
                rawWeights = refitW
                resNorm = subRes
            }
        }

        // 6. 计算决定系数 R^2 = 1 - SS_res / SS_tot
        let ssRes = resNorm * resNorm
        var meanY = 0.0
        vDSP_meanvD(rhs, 1, &meanY, vDSP_Length(m))
        var negMean = -meanY
        var centeredY = Array(repeating: 0.0, count: m)
        vDSP_vsaddD(rhs, 1, &negMean, &centeredY, 1, vDSP_Length(m))
        var ssTot = 0.0
        vDSP_svesqD(centeredY, 1, &ssTot, vDSP_Length(m))
        let rSquared = ssTot > 1e-12 ? max(0.0, min(1.0, 1.0 - (ssRes / ssTot))) : 1.0
        if rSquared < 0.75 {
            warnings.append(.lowFitRSquared)
        }

        // 7. 聚合回逻辑分量（将 +1A/+1C/+1G/+1T 合并为 "+1"），使用完整活动子集协方差矩阵 Σ_A = σ²(X_A^T X_A)^(-1) 计入非对角负协方差
        let cleanedWeights = rawWeights.map { $0 >= noiseFloorWeight ? $0 : 0.0 }
        let activeIndices = cleanedWeights.enumerated().filter { $0.element > 0.0 }.map(\.offset)
        let covResult = estimateActiveCovariance(
            columns: columns,
            activeIndices: activeIndices,
            ssRes: ssRes,
            m: m
        )

        var shiftWeights = Array(repeating: 0.0, count: shifts.count)
        var shiftActiveCols = Array(repeating: [Int](), count: shifts.count)
        var hdrWeight = 0.0
        var hdrActiveCols: [Int] = []

        for (cIdx, meta) in colMetas.enumerated() {
            let rw = cleanedWeights[cIdx]
            if let sIdx = meta.shiftIdx {
                shiftWeights[sIdx] += rw
                if rw > 0.0 { shiftActiveCols[sIdx].append(cIdx) }
            } else if meta.isHDR {
                hdrWeight += rw
                if rw > 0.0 { hdrActiveCols.append(cIdx) }
            }
        }

        let weightSum = shiftWeights.reduce(0.0, +) + hdrWeight
        let normScale = weightSum > 1e-12 ? (100.0 / weightSum) : 0.0
        let df = max(1, m - max(1, activeIndices.count))

        func groupSEAndP(rw: Double, pct: Double, groupCols: [Int]) -> (se: Double?, p: Double?) {
            guard rw > 0.0 && !groupCols.isEmpty else { return (nil, nil) }
            switch covResult {
            case .zeroResidual:
                return (0.0, 0.0)
            case .unavailable:
                return (nil, nil)
            case .matrix(let cov):
                // Var(sum_{j in G} w_j) = sum_{i in G} sum_{j in G} Cov(w_i, w_j)
                var sumVar = 0.0
                for ci in groupCols {
                    guard let rowMap = cov[ci] else { return (nil, nil) }
                    for cj in groupCols {
                        guard let v = rowMap[cj] else { return (nil, nil) }
                        sumVar += v
                    }
                }
                let sePct = sqrt(max(0.0, sumVar)) * normScale
                if sePct <= 1e-12 {
                    return (0.0, 0.0)
                }
                return (sePct, QPCRStatistics.studentTTwoSidedP(t: pct / sePct, df: Double(df)))
            }
        }

        var contributions: [ComponentContribution] = []
        contributions.reserveCapacity(shifts.count + (hasHDR ? 1 : 0))

        var wtPct = 0.0
        var indelPct = 0.0
        var koPct = 0.0
        var hdrPct = 0.0

        for (idx, s) in shifts.enumerated() {
            let rw = shiftWeights[idx]
            let pct = rw * normScale
            // Synthego ICE 规范：非 3 倍数移码 OR 大片段框内缺失 (<= -21 bp) 均计入 Knockout Score
            let isKOShift = (abs(s) % 3 != 0) || (s <= -21)
            let lbl = s > 0 ? "+\(s)" : "\(s)"
            if s == 0 {
                wtPct = pct
            } else {
                indelPct += pct
                if isKOShift {
                    koPct += pct
                }
            }
            let (sePct, pVal) = groupSEAndP(rw: rw, pct: pct, groupCols: shiftActiveCols[idx])
            contributions.append(
                ComponentContribution(
                    label: lbl,
                    shiftBp: s,
                    isHDR: false,
                    isFrameshift: isKOShift,
                    rawWeight: rw,
                    percent: pct,
                    sePercent: sePct,
                    pValue: pVal
                )
            )
        }

        if hasHDR, hdrColIdx != nil {
            let rw = hdrWeight
            let pct = rw * normScale
            hdrPct = pct
            let (sePct, pVal) = groupSEAndP(rw: rw, pct: pct, groupCols: hdrActiveCols)
            contributions.append(
                ComponentContribution(
                    label: "HDR",
                    shiftBp: nil,
                    isHDR: true,
                    isFrameshift: false,
                    rawWeight: rw,
                    percent: pct,
                    sePercent: sePct,
                    pValue: pVal
                )
            )
        }

        let dominant = contributions
            .filter { $0.percent >= 0.5 }
            .sorted {
                if abs($0.percent - $1.percent) > 1e-6 {
                    return $0.percent > $1.percent
                }
                return ($0.shiftBp ?? 999) < ($1.shiftBp ?? 999)
            }

        return DeconvolutionResult(
            cutIndex0Based: cutIndex0Based,
            isReverseStrandSgRNA: isReverseStrandSgRNA,
            requestedWindowBp: requestedWindowBp,
            effectiveWindowBp: effectiveW,
            shiftMinBp: shiftRange.lowerBound,
            shiftMaxBp: shiftRange.upperBound,
            wtPercent: wtPct,
            indelPercent: indelPct,
            koScore: koPct,
            hdrPercent: hdrPct,
            totalEditedPercent: indelPct + hdrPct,
            rSquared: rSquared,
            residualNorm: resNorm,
            contributions: contributions,
            dominantIndels: dominant,
            warnings: warnings,
            alignmentOffsetBp: alignmentOffsetBp,
            hdrWTCosineSimilarity: hdrCosSim
        )
    }

    private enum ActiveCovarianceStatus {
        case zeroResidual
        case unavailable
        case matrix([Int: [Int: Double]])
    }

    /// 估算活跃支持集完整协方差矩阵 Σ_A = σ² * (X_A^T X_A)^(-1)，显式区分零残差与奇异/欠定不可用状态
    private static func estimateActiveCovariance(
        columns: [[Double]],
        activeIndices: [Int],
        ssRes: Double,
        m: Int
    ) -> ActiveCovarianceStatus {
        let k = activeIndices.count
        guard k > 0, m > k else { return .unavailable }
        let sigma2 = ssRes / Double(m - k)
        if sigma2 <= 1e-18 { return .zeroResidual }

        var gram = Array(repeating: Array(repeating: 0.0, count: k), count: k)
        var maxDiag = 0.0
        for i in 0..<k {
            for j in i..<k {
                var dot = 0.0
                vDSP_dotprD(columns[activeIndices[i]], 1, columns[activeIndices[j]], 1, &dot, vDSP_Length(m))
                gram[i][j] = dot
                gram[j][i] = dot
            }
            maxDiag = max(maxDiag, abs(gram[i][i]))
        }
        guard maxDiag > 1e-18 else { return .unavailable }
        let pivotTol = max(1e-14, 1e-12 * maxDiag)

        // 高斯-约当求逆（严格检验奇异性，不向奇异矩阵注入伪正定偏置）
        var aug = Array(repeating: Array(repeating: 0.0, count: 2 * k), count: k)
        for i in 0..<k {
            for j in 0..<k { aug[i][j] = gram[i][j] }
            aug[i][k + i] = 1.0
        }
        for col in 0..<k {
            var pivotRow = col
            var maxVal = abs(aug[col][col])
            for r in (col + 1)..<k {
                if abs(aug[r][col]) > maxVal {
                    maxVal = abs(aug[r][col])
                    pivotRow = r
                }
            }
            guard maxVal > pivotTol else { return .unavailable }
            if pivotRow != col { aug.swapAt(col, pivotRow) }
            let diag = aug[col][col]
            for c in 0..<(2 * k) { aug[col][c] /= diag }
            for r in 0..<k where r != col {
                let factor = aug[r][col]
                if factor == 0 { continue }
                for c in 0..<(2 * k) { aug[r][c] -= factor * aug[col][c] }
            }
        }

        var covMap: [Int: [Int: Double]] = [:]
        for i in 0..<k {
            var row: [Int: Double] = [:]
            for j in 0..<k {
                let v = sigma2 * aug[i][k + j]
                guard v.isFinite else { return .unavailable }
                row[activeIndices[j]] = v
            }
            covMap[activeIndices[i]] = row
        }
        return .matrix(covMap)
    }

    // MARK: - 5. 从 ABIF ChromatogramRecord 直接解卷积

    /// 从 WT.ab1 与 Edited.ab1 解析记录及 sgRNA/HDR 序列执行端到端解卷积
    /// 顺序：先 Mott 质量裁切，再在高质量有效区内执行逐通道局部基线扣除、上游窗口 WT↔Edited 自动对齐、HDR 同量纲缩放
    public static func deconvolveChromatograms(
        wt: SangerAlignmentEngine.ChromatogramRecord,
        edited: SangerAlignmentEngine.ChromatogramRecord,
        sgRNASequence: String,
        hdrDonorSequence: String? = nil,
        requestedWindowBp: Int = 150,
        shiftRange: ClosedRange<Int> = -30...14
    ) -> DeconvolutionResult {
        func extractCalledPeaksMatrix(_ rec: SangerAlignmentEngine.ChromatogramRecord) -> [[Double]] {
            rec.calledPeaks.map { pk in
                let tIdx = pk.traceIndex
                let a = Double(tIdx < rec.traceA.count ? rec.traceA[tIdx] : 0)
                let c = Double(tIdx < rec.traceC.count ? rec.traceC[tIdx] : 0)
                let g = Double(tIdx < rec.traceG.count ? rec.traceG[tIdx] : 0)
                let t = Double(tIdx < rec.traceT.count ? rec.traceT[tIdx] : 0)
                return [a, c, g, t]
            }
        }

        // 1. 先执行 Mott 质量区间裁切（剔除 5' 染料前导与 3' 死尾，避免死尾 ~0 压低 10% 基线分位数）
        let rawWTPeaks = extractCalledPeaksMatrix(wt)
        let rawEdPeaks = extractCalledPeaksMatrix(edited)
        let wtTrim = mottQualityTrimRange(qualities: wt.calledPeaks.map(\.phredQuality))
        let edTrim = mottQualityTrimRange(qualities: edited.calledPeaks.map(\.phredQuality))

        let wtCharsAll = Array(cleanPreservingN(wt.rawSequence))
        let edCharsAll = Array(cleanPreservingN(edited.rawSequence))
        let wtTrimmedRaw = (wtTrim.lowerBound < wtTrim.upperBound && wtTrim.upperBound <= rawWTPeaks.count)
            ? Array(rawWTPeaks[wtTrim])
            : rawWTPeaks
        let wtTrimSeq = (wtTrim.lowerBound < wtTrim.upperBound && wtTrim.upperBound <= wtCharsAll.count)
            ? String(wtCharsAll[wtTrim])
            : cleanPreservingN(wt.rawSequence)

        let edTrimmedRaw = (edTrim.lowerBound < edTrim.upperBound && edTrim.upperBound <= rawEdPeaks.count)
            ? Array(rawEdPeaks[edTrim])
            : rawEdPeaks
        let edTrimSeq = (edTrim.lowerBound < edTrim.upperBound && edTrim.upperBound <= edCharsAll.count)
            ? String(edCharsAll[edTrim])
            : cleanPreservingN(edited.rawSequence)

        // 2. 在高质量有效区内执行逐通道局部基线扣除（消除 4 通道底部漂移）
        let wtMatrix = subtractChannelBaselines(wtTrimmedRaw)
        let edMatrix = subtractChannelBaselines(edTrimmedRaw)

        guard let loc = locateCutSite(wtSequence: wtTrimSeq, sgRNASequence: sgRNASequence) else {
            return DeconvolutionResult(
                cutIndex0Based: 0,
                isReverseStrandSgRNA: false,
                requestedWindowBp: requestedWindowBp,
                effectiveWindowBp: 0,
                shiftMinBp: shiftRange.lowerBound,
                shiftMaxBp: shiftRange.upperBound,
                wtPercent: 0.0,
                indelPercent: 0.0,
                koScore: 0.0,
                hdrPercent: 0.0,
                totalEditedPercent: 0.0,
                rSquared: 0.0,
                residualNorm: 0.0,
                contributions: [],
                dominantIndels: [],
                warnings: [.sgRNANotFoundInWT]
            )
        }

        let cut0 = loc.cutIndex0Based

        // 3. 上游窗口 WT vs Edited 自动对齐；若 cut0 + alignOffset < 0 则严禁截断为 0，返回空窗触发告警
        let alignOffset = estimateUpstreamAlignmentOffset(
            wtSequence: wtTrimSeq,
            editedSequence: edTrimSeq,
            wtPeaks: wtMatrix,
            editedPeaks: edMatrix,
            wtCutIndex0Based: cut0
        )
        let editedCut0 = cut0 + alignOffset
        let editedWin: [[Double]]
        if editedCut0 >= 0 && editedCut0 < edMatrix.count {
            let endIdx = min(edMatrix.count, editedCut0 + requestedWindowBp)
            editedWin = Array(edMatrix[editedCut0..<endIdx])
        } else {
            editedWin = []
        }

        // 4. HDR 模板自动对齐（支持正义/反义 ssODN），统一使用下游分解窗 [cut0, cut0 + estEffectiveW] 估算局部 RFU 振幅
        let maxDeletion = max(0, -shiftRange.lowerBound)
        let estEffectiveW = max(1, min(requestedWindowBp, max(0, wtMatrix.count - maxDeletion - cut0), max(1, editedWin.count)))
        let (wtPrimaryRFU, wtBgRFU) = estimateLocalSignalScale(
            wtPeaks: wtMatrix,
            start: cut0,
            end: min(wtMatrix.count, cut0 + estEffectiveW)
        )
        var hdrWin: [[Double]]? = nil
        var hdrAlignFailed = false
        if let hdrSeq = hdrDonorSequence, !BioSequence.clean(hdrSeq).isEmpty {
            hdrWin = alignAndScaleHDRWindow(
                wtSequence: wtTrimSeq,
                hdrDonorSequence: hdrSeq,
                wtCutIndex0Based: cut0,
                requestedWindowBp: requestedWindowBp,
                wtPrimarySignal: wtPrimaryRFU,
                wtBackgroundSignal: wtBgRFU
            )
            if hdrWin == nil {
                hdrAlignFailed = true
            }
        }

        let res = deconvolvePeakMatrices(
            wtPeaksACGT: wtMatrix,
            editedWindowPeaksACGT: editedWin,
            cutIndex0Based: cut0,
            isReverseStrandSgRNA: loc.isReverseStrand,
            requestedWindowBp: requestedWindowBp,
            shiftRange: shiftRange,
            hdrWindowPeaksACGT: hdrWin,
            alignmentOffsetBp: alignOffset
        )
        if hdrAlignFailed {
            var warns = res.warnings
            warns.append(.hdrAlignmentFailed)
            return DeconvolutionResult(
                cutIndex0Based: res.cutIndex0Based,
                isReverseStrandSgRNA: res.isReverseStrandSgRNA,
                requestedWindowBp: res.requestedWindowBp,
                effectiveWindowBp: res.effectiveWindowBp,
                shiftMinBp: res.shiftMinBp,
                shiftMaxBp: res.shiftMaxBp,
                wtPercent: res.wtPercent,
                indelPercent: res.indelPercent,
                koScore: res.koScore,
                hdrPercent: res.hdrPercent,
                totalEditedPercent: res.totalEditedPercent,
                rSquared: res.rSquared,
                residualNorm: res.residualNorm,
                contributions: res.contributions,
                dominantIndels: res.dominantIndels,
                warnings: warns,
                alignmentOffsetBp: res.alignmentOffsetBp,
                hdrWTCosineSimilarity: res.hdrWTCosineSimilarity
            )
        }
        return res
    }
}
