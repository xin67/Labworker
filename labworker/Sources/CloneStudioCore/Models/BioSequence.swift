import Foundation

/// DNA 序列模型与基础生物信息学工具
public struct BioSequence {
    
    /// 清洗 DNA 序列：剔除空格、换行、数字，仅保留 ATCG，并统一转换为大写
    public static func clean(_ seq: String) -> String {
        let pattern = "[^ATCGatcg]"
        let cleaned = seq.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return cleaned.uppercased()
    }
    
    /// 反向序列 (5' -> 3' 变为 3' -> 5')
    public static func reverse(_ seq: String) -> String {
        return String(clean(seq).reversed())
    }
    
    /// 互补序列 (A <-> T, C <-> G)
    public static func complement(_ seq: String) -> String {
        let cleaned = clean(seq)
        var result = ""
        result.reserveCapacity(cleaned.count)
        for char in cleaned {
            switch char {
            case "A": result.append("T")
            case "T": result.append("A")
            case "C": result.append("G")
            case "G": result.append("C")
            default:  result.append(char)
            }
        }
        return result
    }
    
    /// 反向互补序列 (Reverse Complement)
    public static func reverseComplement(_ seq: String) -> String {
        return reverse(complement(seq))
    }
    
    /// 计算 GC 含量百分比 (0.0 ~ 100.0)
    public static func gcContent(_ seq: String) -> Double {
        let cleaned = clean(seq)
        guard !cleaned.isEmpty else { return 0.0 }
        let gcCount = cleaned.filter { $0 == "G" || $0 == "C" }.count
        return (Double(gcCount) / Double(cleaned.count)) * 100.0
    }
    
    /// 近似估算单链 DNA (ssDNA) 分子量 (g/mol)
    /// MW ≈ (An * 313.21) + (Tn * 304.2) + (Cn * 289.18) + (Gn * 329.21) - 61.96
    public static func molecularWeight(_ seq: String) -> Double {
        let cleaned = clean(seq)
        guard !cleaned.isEmpty else { return 0.0 }
        var mw = 0.0
        for char in cleaned {
            switch char {
            case "A": mw += 313.21
            case "T": mw += 304.20
            case "C": mw += 289.18
            case "G": mw += 329.21
            default:  mw += 309.0
            }
        }
        return max(0, mw - 61.96)
    }
    
    /// 截取环状质粒子序列（支持 `start1Based > end1Based` 跨越环状原点 1 bp 边界，以及正链 "+" / 负链 "-" 自动反向互补）
    public static func extractCircularSubsequence(
        _ seq: String,
        start1Based: Int,
        end1Based: Int,
        strand: String = "+"
    ) -> String {
        let cleaned = clean(seq)
        let n = cleaned.count
        guard n > 0 else { return "" }
        let chars = Array(cleaned)
        let s0 = ((start1Based - 1) % n + n) % n
        let e0 = ((end1Based - 1) % n + n) % n
        var out = ""
        if s0 <= e0 {
            out = String(chars[s0...e0])
        } else {
            out = String(chars[s0..<n]) + String(chars[0...e0])
        }
        return (strand == "-") ? reverseComplement(out) : out
    }
}
