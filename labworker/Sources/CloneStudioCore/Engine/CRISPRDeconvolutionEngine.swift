import Foundation
import Accelerate

/// Synthego ICE 风格 Sanger 编辑池四色峰图解卷积引擎
/// 使用 Apple 原生 Accelerate (vDSP) 实现 Lawson-Hanson Active-Set 非负最小二乘 (NNLS) 求解器（零外部 C++ 依赖）
public struct CRISPRDeconvolutionEngine: Sendable {

    // MARK: - 1. 数据模型

    /// 单个移码或修复分量的贡献度条目
    public struct ComponentContribution: Identifiable, Sendable, Equatable, Codable {
        public var id: String { label }
        public let label: String            // 如 "-1", "0", "+1", "HDR"
        public let shiftBp: Int?            // NHEJ 移码长度 (-20...+20)，HDR 分量为 nil
        public let isHDR: Bool              // 是否为 HDR Donor 分量
        public let isFrameshift: Bool       // 是否导致编码框移码 (|shiftBp| % 3 != 0)
        public let rawWeight: Double        // NNLS 原始非负回归系数
        public let percent: Double          // 归一化百分比 (0.0 - 100.0)

        public init(
            label: String,
            shiftBp: Int?,
            isHDR: Bool,
            isFrameshift: Bool,
            rawWeight: Double,
            percent: Double
        ) {
            self.label = label
            self.shiftBp = shiftBp
            self.isHDR = isHDR
            self.isFrameshift = isFrameshift
            self.rawWeight = rawWeight
            self.percent = percent
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
            warnings: [DeconvolutionWarning]
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
        }
    }

    // MARK: - 2. Accelerate (vDSP) 原生 Lawson-Hanson Active-Set NNLS 求解器

    /// 使用 Apple Accelerate (vDSP) 求解非负最小二乘问题：
    ///   min_{w >= 0} || X * w - y ||_2^2
    /// - Parameters:
    ///   - matrixColumns: 设计矩阵 X 的列向量集合，共 n 列，每列长度为 m
    ///   - rhs: 观测向量 y，长度为 m
    ///   - maxIterations: 最大外层迭代次数（默认 3 * n）
    ///   - tolerance: 对偶梯度收敛容差（默认 1e-11）
    /// - Returns: (非负权重解向量 w, 残差二范数 ||X*w - y||_2)
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

        // 计算矩阵列范数以设定尺度自适应收敛阈值
        var maxColNorm = 1.0
        for col in matrixColumns {
            var sumSq = 0.0
            vDSP_svesqD(col, 1, &sumSq, vDSP_Length(m))
            maxColNorm = max(maxColNorm, sqrt(sumSq))
        }
        let dualTol = tolerance * maxColNorm

        // 辅助函数：利用 vDSP 计算残差 r = y - X * x
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

        // 辅助函数：利用 vDSP 计算对偶梯度 w = X^T * r
        func computeDualGradient(_ residual: [Double]) -> [Double] {
            var grad = Array(repeating: 0.0, count: n)
            for j in 0..<n {
                var dot = 0.0
                vDSP_dotprD(matrixColumns[j], 1, residual, 1, &dot, vDSP_Length(m))
                grad[j] = dot
            }
            return grad
        }

        // 辅助函数：基于 vDSP Householder QR 求解被动集无约束最小二乘 min ||X_P * s_P - y||_2
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

                // 对后续列 c = (j+1)..<k 施加 Householder 反射: col_c -= 2 * (v^T col_c / v^T v) * v
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

                // 对右端向量 qtB 施加同一 Householder 反射
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

            // 上三角回代求解 R * s_P = qtB[0..<k]
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

            // 在主动集 Z 中寻找对偶梯度最大的下标 t
            var bestIdx = -1
            var bestGrad = dualTol
            for j in 0..<n where !isPassive[j] {
                if dualGrad[j] > bestGrad {
                    bestGrad = dualGrad[j]
                    bestIdx = j
                }
            }

            if bestIdx == -1 {
                break // 已满足 KKT 最优性条件
            }

            passiveSet.append(bestIdx)
            isPassive[bestIdx] = true

            // 内层循环：修正被动集中可能出现的非正分量
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

                // 计算最大可行步长 alpha ∈ (0, 1]
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

                // 更新 x 并移除归零变量回主动集 Z
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

    // MARK: - 3. 序列转标准四通道峰值矩阵 & 切点定位

    /// 将 DNA 序列转换为标准四色荧光峰高矩阵 [[A, C, G, T]]
    public static func peaksFromSequence(
        _ sequence: String,
        primarySignal: Double = 1000.0,
        backgroundSignal: Double = 20.0
    ) -> [[Double]] {
        let clean = BioSequence.clean(sequence)
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

    /// 在 WT 序列中定位 sgRNA (20nt) 及其 SpCas9 切割位点 (0-based 下标)
    /// - 正向链匹配：切点位于 sgRNA 3' 端上游 3 bp (即 start + sgRNA.count - 3)
    /// - 反向互补链匹配：切点位于反向互补匹配区 5' 端下游 3 bp (即 rcStart + 3)
    public static func locateCutSite(
        wtSequence: String,
        sgRNASequence: String
    ) -> (cutIndex0Based: Int, isReverseStrand: Bool)? {
        let cleanWT = BioSequence.clean(wtSequence)
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

    // MARK: - 4. 核心四色峰值矩阵 NNLS 解卷积

    /// 对切点下游窗口的四通道荧光峰矩阵执行 NNLS 解卷积
    public static func deconvolvePeakMatrices(
        wtPeaksACGT: [[Double]],
        editedWindowPeaksACGT: [[Double]],
        cutIndex0Based: Int,
        isReverseStrandSgRNA: Bool = false,
        requestedWindowBp: Int = 150,
        shiftRange: ClosedRange<Int> = -20...20,
        hdrWindowPeaksACGT: [[Double]]? = nil,
        noiseFloorWeight: Double = 1e-6
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
                warnings: warnings
            )
        }

        let m = effectiveW * 4
        let shifts = Array(shiftRange)
        var columns: [[Double]] = []
        columns.reserveCapacity(shifts.count + 1)

        // 1. 构建 41 个移码分量列 (-20 ... +20)
        for s in shifts {
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
        }

        // 2. 可选追加 HDR Donor 列
        let hasHDR: Bool
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
            columns.append(hdrCol)
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

        // 4. 调用 vDSP Lawson-Hanson NNLS 求解
        let (rawWeights, resNorm) = solveNNLS(matrixColumns: columns, rhs: rhs)

        // 5. 计算决定系数 R^2 = 1 - SS_res / SS_tot (使用 vDSP)
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

        // 6. 过滤极小数值噪声并归一化为百分比
        let cleanedWeights = rawWeights.map { $0 >= noiseFloorWeight ? $0 : 0.0 }
        let weightSum = cleanedWeights.reduce(0.0, +)
        let normScale = weightSum > 1e-12 ? (100.0 / weightSum) : 0.0

        var contributions: [ComponentContribution] = []
        contributions.reserveCapacity(columns.count)

        var wtPct = 0.0
        var indelPct = 0.0
        var koPct = 0.0
        var hdrPct = 0.0

        for (idx, s) in shifts.enumerated() {
            let rw = cleanedWeights[idx]
            let pct = rw * normScale
            let isFS = (abs(s) % 3) != 0
            let lbl = s > 0 ? "+\(s)" : "\(s)"
            if s == 0 {
                wtPct = pct
            } else {
                indelPct += pct
                if isFS {
                    koPct += pct
                }
            }
            contributions.append(
                ComponentContribution(
                    label: lbl,
                    shiftBp: s,
                    isHDR: false,
                    isFrameshift: isFS,
                    rawWeight: rw,
                    percent: pct
                )
            )
        }

        if hasHDR {
            let rw = cleanedWeights[shifts.count]
            let pct = rw * normScale
            hdrPct = pct
            contributions.append(
                ComponentContribution(
                    label: "HDR",
                    shiftBp: nil,
                    isHDR: true,
                    isFrameshift: false,
                    rawWeight: rw,
                    percent: pct
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
            warnings: warnings
        )
    }

    // MARK: - 5. 从 ABIF ChromatogramRecord 直接解卷积

    /// 从 WT.ab1 与 Edited.ab1 解析记录及 sgRNA/HDR 序列执行端到端解卷积
    public static func deconvolveChromatograms(
        wt: SangerAlignmentEngine.ChromatogramRecord,
        edited: SangerAlignmentEngine.ChromatogramRecord,
        sgRNASequence: String,
        hdrDonorSequence: String? = nil,
        requestedWindowBp: Int = 150,
        shiftRange: ClosedRange<Int> = -20...20
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

        let wtMatrix = extractCalledPeaksMatrix(wt)
        let editedFullMatrix = extractCalledPeaksMatrix(edited)

        guard let loc = locateCutSite(wtSequence: wt.rawSequence, sgRNASequence: sgRNASequence) else {
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
        let editedWin: [[Double]]
        if cut0 < editedFullMatrix.count {
            let endIdx = min(editedFullMatrix.count, cut0 + requestedWindowBp)
            editedWin = Array(editedFullMatrix[cut0..<endIdx])
        } else {
            editedWin = []
        }

        var hdrWin: [[Double]]? = nil
        if let hdrSeq = hdrDonorSequence, !BioSequence.clean(hdrSeq).isEmpty {
            let hdrFull = peaksFromSequence(hdrSeq)
            if cut0 < hdrFull.count {
                let endIdx = min(hdrFull.count, cut0 + requestedWindowBp)
                hdrWin = Array(hdrFull[cut0..<endIdx])
            }
        }

        return deconvolvePeakMatrices(
            wtPeaksACGT: wtMatrix,
            editedWindowPeaksACGT: editedWin,
            cutIndex0Based: cut0,
            isReverseStrandSgRNA: loc.isReverseStrand,
            requestedWindowBp: requestedWindowBp,
            shiftRange: shiftRange,
            hdrWindowPeaksACGT: hdrWin
        )
    }
}
