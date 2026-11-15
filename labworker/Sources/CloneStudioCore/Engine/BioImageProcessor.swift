import Foundation
import AppKit
import CoreGraphics
import Accelerate

// MARK: - 1. 通用生物图像平面数据结构 (RGBA + 0..255 Grayscale Plane)

public struct BioImageTIFFMetadata: Sendable, Equatable {
    public var physicalPixelSizeUM: Double?
    public var physicalSizeSource: String?
    public var channelNames: [String]?
    public var sizeC: Int?
    public var sizeZ: Int?
    public var sizeT: Int?
    public var descriptionRaw: String?

    public init(
        physicalPixelSizeUM: Double? = nil,
        physicalSizeSource: String? = nil,
        channelNames: [String]? = nil,
        sizeC: Int? = nil,
        sizeZ: Int? = nil,
        sizeT: Int? = nil,
        descriptionRaw: String? = nil
    ) {
        self.physicalPixelSizeUM = physicalPixelSizeUM
        self.physicalSizeSource = physicalSizeSource
        self.channelNames = channelNames
        self.sizeC = sizeC
        self.sizeZ = sizeZ
        self.sizeT = sizeT
        self.descriptionRaw = descriptionRaw
    }
}

public struct BioImagePlane: Sendable {
    public let width: Int
    public let height: Int
    public var originalWidth: Int
    public var originalHeight: Int
    /// 原始图像物理像素尺寸 (微米/像素, µm/px)
    public var physicalPixelSizeUM: Double?
    /// 物理像素尺寸来源 ("OME-XML", "ImageJ", "TIFF-Resolution", "Manual")
    public var physicalSizeSource: String?
    /// 多通道检测名称 (如 ["DAPI", "EGFP", "MitoTracker"])
    public var channelNames: [String]?
    public var sizeC: Int?
    public var sizeZ: Int?
    public var sizeT: Int?
    /// 灰度平面 (0..255，长度为 width * height)
    public var gray: [Float]
    /// RGBA 原始字节平面 (长度为 width * height * 4)
    public var rgba: [UInt8]

    /// 考虑从 originalWidth 缩放至当前 width 后的有效物理像素尺寸 (µm/px)
    public var effectivePixelSizeUM: Double? {
        guard let origPx = physicalPixelSizeUM, origPx > 0, width > 0, originalWidth > 0 else { return nil }
        return origPx * (Double(originalWidth) / Double(width))
    }
    
    public init(
        width: Int,
        height: Int,
        gray: [Float],
        rgba: [UInt8],
        originalWidth: Int? = nil,
        originalHeight: Int? = nil,
        physicalPixelSizeUM: Double? = nil,
        physicalSizeSource: String? = nil,
        channelNames: [String]? = nil,
        sizeC: Int? = nil,
        sizeZ: Int? = nil,
        sizeT: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.originalWidth = originalWidth ?? width
        self.originalHeight = originalHeight ?? height
        self.physicalPixelSizeUM = physicalPixelSizeUM
        self.physicalSizeSource = physicalSizeSource
        self.channelNames = channelNames
        self.sizeC = sizeC
        self.sizeZ = sizeZ
        self.sizeT = sizeT
        self.gray = gray
        self.rgba = rgba
    }
    
    /// 从 NSImage 提取标准缩放检测平面（限制最大边长以保证实时 60fps 交互响应）
    public static func fromNSImage(_ image: NSImage, maxDimension: Int = 520, metadata: BioImageTIFFMetadata? = nil) -> BioImagePlane? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return fromCGImage(cgImage, maxDimension: maxDimension, metadata: metadata)
    }

    /// 从文件 URL 读取图像并自动提取 OME-TIFF / ImageJ / TIFF 分辨率元数据
    public static func fromImageURL(_ url: URL, maxDimension: Int = 520) -> BioImagePlane? {
        let meta = BioImageProcessor.extractTIFFMetadata(at: url)
        if let imgSource = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) {
            return fromCGImage(cgImage, maxDimension: maxDimension, metadata: meta)
        }
        if let nsImg = NSImage(contentsOf: url) {
            return fromNSImage(nsImg, maxDimension: maxDimension, metadata: meta)
        }
        return nil
    }
    
    public static func fromCGImage(_ cgImage: CGImage, maxDimension: Int = 520, metadata: BioImageTIFFMetadata? = nil) -> BioImagePlane? {
        let origW = cgImage.width
        let origH = cgImage.height
        guard origW > 0, origH > 0 else { return nil }
        
        let scale = min(1.0, Double(maxDimension) / Double(max(origW, origH)))
        let w = max(8, Int(round(Double(origW) * scale)))
        let h = max(8, Int(round(Double(origH) * scale)))
        
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        
        var gray = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4])
            let g = Float(rgba[i * 4 + 1])
            let b = Float(rgba[i * 4 + 2])
            gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        return BioImagePlane(
            width: w,
            height: h,
            gray: gray,
            rgba: rgba,
            originalWidth: origW,
            originalHeight: origH,
            physicalPixelSizeUM: metadata?.physicalPixelSizeUM,
            physicalSizeSource: metadata?.physicalSizeSource,
            channelNames: metadata?.channelNames,
            sizeC: metadata?.sizeC,
            sizeZ: metadata?.sizeZ,
            sizeT: metadata?.sizeT
        )
    }
    
    public func toNSImage() -> NSImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        let copy = rgba
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(copy) as CFData),
              let cgImg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(cgImage: cgImg, size: NSSize(width: width, height: height))
    }
}

// MARK: - 2. 峰检测与连通域模型

public struct BioSignalPeak: Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    /// 归一化坐标 (0..1)
    public let fraction: Double
    public let value: Double
    public let prominence: Double
}

public struct BioConnectedComponent: Sendable {
    public let id: Int
    public let area: Int
    public let minX: Int
    public let minY: Int
    public let maxX: Int
    public let maxY: Int
    public let centroidX: Double
    public let centroidY: Double
    public let radius: Double
    public let meanIntensity: Double
    public let circularity: Double
    public let meanR: Double
    public let meanG: Double
    public let meanB: Double
    public let hueDegrees: Double
    public let saturation: Double
    public let pixels: [Int]
}

// MARK: - 3. 核心生物图像分割与信号投影算法引擎 (对应 gel.rs / segment.ts / gelmath.ts)

public enum BioImageProcessor {
    
    /// 分离式一维高斯卷积平滑 (Accelerate vDSP 向量化加速，保持边缘 clamp 语义不变)
    public static func gaussianBlur(gray: [Float], width: Int, height: Int, radius: Double) -> [Float] {
        guard radius > 0.05, width > 1, height > 1, gray.count >= width * height else { return gray }
        let sigma = max(0.5, radius / 2.0)
        let half = max(1, Int(ceil(sigma * 2.5)))
        var kernel = [Float](repeating: 0, count: half * 2 + 1)
        var kSum: Float = 0
        for i in -half...half {
            let v = Float(exp(-Double(i * i) / (2.0 * sigma * sigma)))
            kernel[i + half] = v
            kSum += v
        }
        var invKSum = 1.0 / max(1e-6, kSum)
        kernel.withUnsafeMutableBufferPointer { kBuf in
            guard let kPtr = kBuf.baseAddress else { return }
            vDSP_vsmul(kPtr, 1, &invKSum, kPtr, 1, vDSP_Length(kBuf.count))
        }
        
        var temp = [Float](repeating: 0, count: width * height)
        var out = [Float](repeating: 0, count: width * height)
        
        gray.withUnsafeBufferPointer { gBuf in
            temp.withUnsafeMutableBufferPointer { tBuf in
                out.withUnsafeMutableBufferPointer { oBuf in
                    guard let gPtr = gBuf.baseAddress,
                          let tPtr = tBuf.baseAddress,
                          let oPtr = oBuf.baseAddress else { return }
                    
                    let interiorCount = width - 2 * half
                    // 水平方向一维卷积：内区使用 vDSP_vsma 向量化，边界保持 clamp
                    for y in 0..<height {
                        let row = y * width
                        if interiorCount > 0 {
                            let dstPtr = tPtr + row + half
                            for k in -half...half {
                                var weight = kernel[k + half]
                                let srcPtr = gPtr + row + half + k
                                vDSP_vsma(srcPtr, 1, &weight, dstPtr, 1, dstPtr, 1, vDSP_Length(interiorCount))
                            }
                            for x in 0..<half {
                                var acc: Float = 0
                                for k in -half...half {
                                    let sx = min(width - 1, max(0, x + k))
                                    acc += gPtr[row + sx] * kernel[k + half]
                                }
                                tPtr[row + x] = acc
                            }
                            for x in (width - half)..<width {
                                var acc: Float = 0
                                for k in -half...half {
                                    let sx = min(width - 1, max(0, x + k))
                                    acc += gPtr[row + sx] * kernel[k + half]
                                }
                                tPtr[row + x] = acc
                            }
                        } else {
                            for x in 0..<width {
                                var acc: Float = 0
                                for k in -half...half {
                                    let sx = min(width - 1, max(0, x + k))
                                    acc += gPtr[row + sx] * kernel[k + half]
                                }
                                tPtr[row + x] = acc
                            }
                        }
                    }
                    
                    // 垂直方向一维卷积：按整行执行 vDSP_vsma，保持垂直边界 clamp
                    let vLen = vDSP_Length(width)
                    for y in 0..<height {
                        let dstRowPtr = oPtr + y * width
                        for k in -half...half {
                            let sy = min(height - 1, max(0, y + k))
                            var weight = kernel[k + half]
                            vDSP_vsma(tPtr + sy * width, 1, &weight, dstRowPtr, 1, dstRowPtr, 1, vLen)
                        }
                    }
                }
            }
        }
        return out
    }
    
    /// Otsu 最大类间方差阈值计算 (0..255)
    public static func otsuThreshold(gray: [Float]) -> Double {
        guard !gray.isEmpty else { return 128.0 }
        var hist = [Double](repeating: 0, count: 256)
        for v in gray {
            let bin = min(255, max(0, Int(round(v))))
            hist[bin] += 1.0
        }
        let total = Double(gray.count)
        var sumTotal = 0.0
        for i in 0..<256 { sumTotal += Double(i) * hist[i] }
        
        var sumB = 0.0
        var wB = 0.0
        var maxVar = -1.0
        var bestThresh = 128
        
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t) * hist[t]
            let meanB = sumB / wB
            let meanF = (sumTotal - sumB) / wF
            let between = wB * wF * (meanB - meanF) * (meanB - meanF)
            if between > maxVar {
                maxVar = between
                bestThresh = t
            }
        }
        return Double(bestThresh)
    }
    
    /// 评估图像外框中位灰度以自动推断背景亮暗极性
    public static func estimateBorderBackground(gray: [Float], width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 128.0 }
        let band = max(2, Int(round(Double(min(width, height)) * 0.04)))
        var hist = [Int](repeating: 0, count: 256)
        var total = 0
        for y in 0..<height {
            let edgeY = (y < band) || (y >= height - band)
            for x in 0..<width {
                if edgeY || x < band || x >= width - band {
                    let b = min(255, max(0, Int(round(gray[y * width + x]))))
                    hist[b] += 1
                    total += 1
                }
            }
        }
        guard total > 0 else { return 128.0 }
        var acc = 0
        for i in 0..<256 {
            acc += hist[i]
            if acc >= total / 2 { return Double(i) }
        }
        return 128.0
    }
    
    /// 原生积分图自适应局部均值二值化与形态学开运算去噪 (1:1 对应 SPICE_GUI `src-tauri/src/gel.rs`)
    public static func adaptiveBinarizeGel(
        gray: [Float],
        width: Int,
        height: Int,
        forcedPolarity: Int = 0, // 0 = auto, 1 = bright bands, -1 = dark bands
        delta: Float = -8.0,
        openRadius: Int = 1
    ) -> (mask: [UInt8], brightSignal: Bool) {
        guard width > 0, height > 0, gray.count == width * height else {
            return ([], true)
        }
        let isBright: Bool = {
            if forcedPolarity == 1 { return true }
            if forcedPolarity == -1 { return false }
            let x0 = width / 10
            let x1 = max(x0 + 1, width - width / 10)
            let y0 = height / 10
            let y1 = max(y0 + 1, height - height / 10)
            var hist = [Int](repeating: 0, count: 256)
            var count = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let b = min(255, max(0, Int(round(gray[y * width + x]))))
                    hist[b] += 1
                    count += 1
                }
            }
            guard count > 0 else { return true }
            func quantile(_ q: Double) -> Double {
                let target = Int(Double(count) * q)
                var acc = 0
                for i in 0..<256 {
                    acc += hist[i]
                    if acc >= target { return Double(i) / 255.0 }
                }
                return 1.0
            }
            let low = quantile(0.01)
            let med = quantile(0.50)
            let high = quantile(0.99)
            return (high - med) >= (med - low)
        }()
        
        var work = gray
        if !isBright {
            for i in 0..<work.count { work[i] = 255.0 - work[i] }
        }
        
        // 构建二维积分图加速局部窗口均值计算 O(1)
        let side = min(width, height)
        let radius = max(8, min(side / 3, Int(round(Double(side) / 24.0))))
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += Double(work[y * width + x])
                integral[(y + 1) * (width + 1) + (x + 1)] = integral[y * (width + 1) + (x + 1)] + rowSum
            }
        }
        
        var mask = [UInt8](repeating: 0, count: width * height)
        let margin = min(-1.0, max(-64.0, Double(delta)))
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                let sum = integral[(y1 + 1) * (width + 1) + (x1 + 1)]
                    - integral[y0 * (width + 1) + (x1 + 1)]
                    - integral[(y1 + 1) * (width + 1) + x0]
                    + integral[y0 * (width + 1) + x0]
                let localMean = sum / area
                if Double(work[y * width + x]) > (localMean - margin) {
                    mask[y * width + x] = 1
                }
            }
        }
        
        if openRadius > 0 {
            mask = morphologicalOpen(mask: mask, width: width, height: height, radius: min(3, openRadius))
        }
        
        // 清除外边框伪影
        let border = max(2, min(side / 6, radius))
        for y in 0..<height {
            for x in 0..<width {
                if x < border || y < border || x >= width - border || y >= height - border {
                    mask[y * width + x] = 0
                }
            }
        }
        return (mask, isBright)
    }
    
    public static func morphologicalOpen(mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        let eroded = morphologicalStep(mask: mask, width: width, height: height, radius: radius, isErode: true)
        return morphologicalStep(mask: eroded, width: width, height: height, radius: radius, isErode: false)
    }
    
    private static func morphologicalStep(mask: [UInt8], width: Int, height: Int, radius: Int, isErode: Bool) -> [UInt8] {
        guard radius > 0 else { return mask }
        var out = [UInt8](repeating: isErode ? 1 : 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                if isErode {
                    var keep: UInt8 = 1
                    outer: for ny in y0...y1 {
                        for nx in x0...x1 where mask[ny * width + nx] == 0 {
                            keep = 0
                            break outer
                        }
                    }
                    out[y * width + x] = keep
                } else {
                    var hit: UInt8 = 0
                    outer: for ny in y0...y1 {
                        for nx in x0...x1 where mask[ny * width + nx] > 0 {
                            hit = 1
                            break outer
                        }
                    }
                    out[y * width + x] = hit
                }
            }
        }
        return out
    }
    
    // MARK: - 4. 八邻域连通域提取、距离变换分水岭拆分与 RGB/HSV 颜色统计
    
    public static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let rn = r / 255.0
        let gn = g / 255.0
        let bn = b / 255.0
        let maxC = max(rn, gn, bn)
        let minC = min(rn, gn, bn)
        let delta = maxC - minC
        var h = 0.0
        if delta > 1e-6 {
            if maxC == rn {
                h = 60.0 * (((gn - bn) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxC == gn {
                h = 60.0 * (((bn - rn) / delta) + 2.0)
            } else {
                h = 60.0 * (((rn - gn) / delta) + 4.0)
            }
            if h < 0 { h += 360.0 }
        }
        let s = maxC <= 1e-6 ? 0.0 : (delta / maxC)
        return (h, s, maxC)
    }

    /// 计算像素集合的统计几何属性 (Marching Squares 亚像素轮廓周长 + RGB/HSV 均值)
    public static func buildConnectedComponent(
        id: Int,
        pixels: [Int],
        plane: BioImagePlane
    ) -> BioConnectedComponent? {
        let w = plane.width
        let h = plane.height
        guard w > 0, h > 0, !pixels.isEmpty else { return nil }

        var minX = w, minY = h, maxX = 0, maxY = 0
        var sumX = 0.0, sumY = 0.0, sumGray = 0.0
        var sumR = 0.0, sumG = 0.0, sumB = 0.0

        for p in pixels {
            let x = p % w
            let y = p / w
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
            sumX += Double(x)
            sumY += Double(y)
            sumGray += Double(plane.gray[p])
            sumR += Double(plane.rgba[p * 4])
            sumG += Double(plane.rgba[p * 4 + 1])
            sumB += Double(plane.rgba[p * 4 + 2])
        }

        let area = pixels.count
        let perimeter = marchingSquaresPerimeter(
            pixels: pixels,
            imageWidth: w,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY
        )
        let circ = perimeter > 1e-6
            ? min(1.0, max(0.0, (4.0 * Double.pi * Double(area)) / (perimeter * perimeter)))
            : 0.0
        let nD = Double(area)
        let meanR = sumR / nD
        let meanG = sumG / nD
        let meanB = sumB / nD
        let hsv = rgbToHSV(r: meanR, g: meanG, b: meanB)

        return BioConnectedComponent(
            id: id,
            area: area,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            centroidX: sumX / nD + 0.5,
            centroidY: sumY / nD + 0.5,
            radius: sqrt(nD / Double.pi),
            meanIntensity: sumGray / nD,
            circularity: circ,
            meanR: meanR,
            meanG: meanG,
            meanB: meanB,
            hueDegrees: hsv.h,
            saturation: hsv.s,
            pixels: pixels
        )
    }

    /// 使用 2×2 Marching Squares 子轮廓近似真实欧氏周长，避免 4-邻域曼哈顿周长在小圆与锯齿边缘上严重低估圆度
    private static func marchingSquaresPerimeter(
        pixels: [Int],
        imageWidth: Int,
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int
    ) -> Double {
        let occW = (maxX - minX + 1) + 2
        let occH = (maxY - minY + 1) + 2
        var occ = [Bool](repeating: false, count: occW * occH)
        for p in pixels {
            let lx = (p % imageWidth) - minX + 1
            let ly = (p / imageWidth) - minY + 1
            occ[ly * occW + lx] = true
        }
        var perimeter = 0.0
        let diag = 0.7071067811865476
        for cy in 0..<(occH - 1) {
            let row0 = cy * occW
            let row1 = (cy + 1) * occW
            for cx in 0..<(occW - 1) {
                let b0 = occ[row0 + cx] ? 1 : 0
                let b1 = occ[row0 + cx + 1] ? 2 : 0
                let b2 = occ[row1 + cx + 1] ? 4 : 0
                let b3 = occ[row1 + cx] ? 8 : 0
                switch b0 | b1 | b2 | b3 {
                case 0, 15:
                    break
                case 3, 6, 9, 12:
                    perimeter += 1.0
                case 1, 2, 4, 7, 8, 11, 13, 14:
                    perimeter += diag
                case 5, 10:
                    perimeter += 2.0 * diag
                default:
                    break
                }
            }
        }
        return perimeter
    }

    /// 一维平方欧氏距离变换 (Felzenszwalb & Huttenlocher 2012, O(N) 精确下包络线扫描)
    private static func edt1D(_ f: [Double]) -> [Double] {
        let n = f.count
        guard n > 0 else { return [] }
        var d = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0
        z[0] = -Double.infinity
        z[1] = Double.infinity

        for q in 1..<n {
            while true {
                let r = v[k]
                let s = ((f[q] + Double(q * q)) - (f[r] + Double(r * r))) / Double(2 * q - 2 * r)
                if s <= z[k] {
                    k -= 1
                } else {
                    k += 1
                    v[k] = q
                    z[k] = s
                    z[k + 1] = Double.infinity
                    break
                }
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) {
                k += 1
            }
            let r = v[k]
            let diff = Double(q - r)
            d[q] = diff * diff + f[r]
        }
        return d
    }

    /// 精确二维欧氏距离变换 (返回前景像元至最近背景像元的欧氏距离)
    public static func euclideanDistanceTransform(mask: [Bool], width: Int, height: Int) -> [Double] {
        guard width > 0, height > 0, mask.count == width * height else { return [] }
        let infVal = 1e12
        var grid = [Double](repeating: 0, count: width * height)
        var col = [Double](repeating: 0, count: height)
        for x in 0..<width {
            for y in 0..<height {
                col[y] = mask[y * width + x] ? infVal : 0.0
            }
            let transformed = edt1D(col)
            for y in 0..<height {
                grid[y * width + x] = transformed[y]
            }
        }
        var row = [Double](repeating: 0, count: width)
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let offset = y * width
            for x in 0..<width {
                row[x] = grid[offset + x]
            }
            let transformed = edt1D(row)
            for x in 0..<width {
                out[offset + x] = mask[offset + x] ? sqrt(max(0.0, transformed[x])) : 0.0
            }
        }
        return out
    }

    /// 对二值掩膜提取 8-邻域连通像素集合列表
    private static func extractRawPixelGroups(mask: [UInt8], width: Int, height: Int) -> [[Int]] {
        guard width > 0, height > 0, mask.count == width * height else { return [] }
        var visited = [Bool](repeating: false, count: width * height)
        var groups: [[Int]] = []
        var stack: [Int] = []
        stack.reserveCapacity(512)

        for seed in 0..<(width * height) {
            if mask[seed] == 0 || visited[seed] { continue }
            visited[seed] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            var pixels: [Int] = []

            while let p = stack.popLast() {
                pixels.append(p)
                let x = p % width
                let y = p / width
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let ni = ny * width + nx
                        if mask[ni] > 0 && !visited[ni] {
                            visited[ni] = true
                            stack.append(ni)
                        }
                    }
                }
            }
            if !pixels.isEmpty {
                groups.append(pixels)
            }
        }
        return groups
    }

    public static func extractConnectedComponents(
        mask: [UInt8],
        plane: BioImagePlane
    ) -> [BioConnectedComponent] {
        let groups = extractRawPixelGroups(mask: mask, width: plane.width, height: plane.height)
        var components: [BioConnectedComponent] = []
        components.reserveCapacity(groups.count)
        var nextId = 1
        for pixels in groups {
            if let comp = buildConnectedComponent(id: nextId, pixels: pixels, plane: plane) {
                components.append(comp)
                nextId += 1
            }
        }
        return components
    }

    /// 提取连通域并对粘连菌落簇执行「距离变换 + 持久性峰筛选 + 色彩界面感知分水岭」自动拆分
    public static func extractSplitColonyComponents(
        mask: [UInt8],
        plane: BioImagePlane,
        splitTouching: Bool = true,
        colorAwareSplitting: Bool = true
    ) -> [BioConnectedComponent] {
        let groups = extractRawPixelGroups(mask: mask, width: plane.width, height: plane.height)
        var components: [BioConnectedComponent] = []
        components.reserveCapacity(groups.count)
        var nextId = 1

        for pixels in groups {
            let splitGroups = splitTouching && pixels.count >= 8
                ? splitColonyCluster(pixels: pixels, plane: plane, colorAware: colorAwareSplitting)
                : [pixels]
            for subPixels in splitGroups {
                if let comp = buildConnectedComponent(id: nextId, pixels: subPixels, plane: plane) {
                    components.append(comp)
                    nextId += 1
                }
            }
        }
        return components
    }

    private struct WatershedHeapNode {
        let cost: Double
        let li: Int
        let label: Int
    }

    private struct MinHeap<Element> {
        private var storage: [Element] = []
        private let lessThan: (Element, Element) -> Bool

        init(lessThan: @escaping (Element, Element) -> Bool) {
            self.lessThan = lessThan
        }

        var isEmpty: Bool { storage.isEmpty }

        mutating func push(_ item: Element) {
            storage.append(item)
            siftUp(storage.count - 1)
        }

        mutating func pop() -> Element? {
            guard !storage.isEmpty else { return nil }
            let top = storage[0]
            let last = storage.removeLast()
            if !storage.isEmpty {
                storage[0] = last
                siftDown(0)
            }
            return top
        }

        private mutating func siftUp(_ idx: Int) {
            var c = idx
            while c > 0 {
                let p = (c - 1) >> 1
                if lessThan(storage[c], storage[p]) {
                    storage.swapAt(c, p)
                    c = p
                } else {
                    break
                }
            }
        }

        private mutating func siftDown(_ idx: Int) {
            var p = idx
            let n = storage.count
            while true {
                let left = p * 2 + 1
                if left >= n { break }
                var best = left
                let right = left + 1
                if right < n && lessThan(storage[right], storage[left]) {
                    best = right
                }
                if lessThan(storage[best], storage[p]) {
                    storage.swapAt(p, best)
                    p = best
                } else {
                    break
                }
            }
        }
    }

    /// 对单个粘连连通域像素集执行局部 Patch 拆分
    private static func splitColonyCluster(
        pixels: [Int],
        plane: BioImagePlane,
        colorAware: Bool
    ) -> [[Int]] {
        let w = plane.width
        var minX = w, minY = plane.height, maxX = 0, maxY = 0
        for p in pixels {
            let x = p % w
            let y = p / w
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
        let pw = (maxX - minX + 1) + 2
        let ph = (maxY - minY + 1) + 2
        let nPatch = pw * ph

        var inComp = [Bool](repeating: false, count: nPatch)
        var origIdx = [Int](repeating: -1, count: nPatch)
        for p in pixels {
            let lx = (p % w) - minX + 1
            let ly = (p / w) - minY + 1
            let li = ly * pw + lx
            inComp[li] = true
            origIdx[li] = p
        }

        var cr = [Double](repeating: 0, count: nPatch)
        var cg = [Double](repeating: 0, count: nPatch)
        var cb = [Double](repeating: 0, count: nPatch)
        var isChromaWall = [Bool](repeating: false, count: nPatch)

        if colorAware {
            for li in 0..<nPatch where inComp[li] {
                let p = origIdx[li]
                let r = Double(plane.rgba[p * 4])
                let g = Double(plane.rgba[p * 4 + 1])
                let b = Double(plane.rgba[p * 4 + 2])
                let sum = max(60.0, r + g + b)
                cr[li] = r / sum
                cg[li] = g / sum
                cb[li] = b / sum
            }
            func chromaDist(_ a: Int, _ b: Int) -> Double {
                let dr = cr[a] - cr[b]
                let dg = cg[a] - cg[b]
                let db = cb[a] - cb[b]
                return sqrt(dr * dr + dg * dg + db * db)
            }
            // 使用对称中心差分与锐利正交跳变探测蓝/白交界，抑制单像元噪点误切断
            for ly in 1..<(ph - 1) {
                for lx in 1..<(pw - 1) {
                    let li = ly * pw + lx
                    guard inComp[li] else { continue }
                    if inComp[li - 1] && inComp[li + 1] && chromaDist(li - 1, li + 1) >= 0.16 {
                        isChromaWall[li] = true
                    } else if inComp[li - pw] && inComp[li + pw] && chromaDist(li - pw, li + pw) >= 0.16 {
                        isChromaWall[li] = true
                    } else if inComp[li + 1] && chromaDist(li, li + 1) >= 0.18 && !(inComp[li - 1] && chromaDist(li - 1, li) >= 0.12) {
                        isChromaWall[li] = true
                    } else if inComp[li + pw] && chromaDist(li, li + pw) >= 0.18 && !(inComp[li - pw] && chromaDist(li - pw, li) >= 0.12) {
                        isChromaWall[li] = true
                    }
                }
            }
        }

        let edtGeo = euclideanDistanceTransform(mask: inComp, width: pw, height: ph)
        let edtSplit: [Double]
        if colorAware && isChromaWall.contains(true) {
            var splitMask = inComp
            for li in 0..<nPatch where isChromaWall[li] {
                splitMask[li] = false
            }
            let tmp = euclideanDistanceTransform(mask: splitMask, width: pw, height: ph)
            // 确保完全不抹除色彩界壁处微弱信号
            edtSplit = tmp
        } else {
            edtSplit = edtGeo
        }

        // 极轻度可分离平滑 (权重 0.04 / 0.92 / 0.04) 消除像素网格奇偶台阶毛刺，同时保留微小菌落峰尖与粘连窄鞍部
        var tempScore = [Double](repeating: 0, count: nPatch)
        var score = [Double](repeating: 0, count: nPatch)
        for ly in 1..<(ph - 1) {
            for lx in 1..<(pw - 1) {
                let li = ly * pw + lx
                guard inComp[li] else { continue }
                let sL = inComp[li - 1] ? edtSplit[li - 1] : 0.0
                let sR = inComp[li + 1] ? edtSplit[li + 1] : 0.0
                tempScore[li] = 0.04 * sL + 0.92 * edtSplit[li] + 0.04 * sR
            }
        }
        for ly in 1..<(ph - 1) {
            for lx in 1..<(pw - 1) {
                let li = ly * pw + lx
                guard inComp[li] else { continue }
                let sU = inComp[li - pw] ? tempScore[li - pw] : 0.0
                let sD = inComp[li + pw] ? tempScore[li + pw] : 0.0
                score[li] = 0.04 * sU + 0.92 * tempScore[li] + 0.04 * sD
            }
        }

        // 拓扑持久性降序淹没筛选真实菌落峰种子
        var fgIndices: [Int] = []
        fgIndices.reserveCapacity(pixels.count)
        for ly in 1..<(ph - 1) {
            for lx in 1..<(pw - 1) {
                let li = ly * pw + lx
                if inComp[li] { fgIndices.append(li) }
            }
        }
        fgIndices.sort { a, b in
            if abs(score[a] - score[b]) > 1e-7 { return score[a] > score[b] }
            if abs(edtGeo[a] - edtGeo[b]) > 1e-7 { return edtGeo[a] > edtGeo[b] }
            return a < b
        }

        struct BasinInfo {
            var id: Int
            var seedLi: Int
            var seedX: Double
            var seedY: Double
            var peakScore: Double
            var seedCR: Double
            var seedCG: Double
            var seedCB: Double
            var mergedInto: Int?
        }

        var basinAt = [Int](repeating: 0, count: nPatch) // 0=未处理, >0=basin id
        var basins: [BasinInfo] = []
        basins.reserveCapacity(16)

        func resolveBasin(_ id: Int) -> Int {
            var cur = id
            while let parent = basins[cur - 1].mergedInto {
                cur = parent
            }
            return cur
        }

        for li in fgIndices {
            let lx = li % pw
            let ly = li / pw
            let s = score[li]

            var neighborRoots: [Int] = []
            for dy in -1...1 {
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let ni = (ly + dy) * pw + (lx + dx)
                    let bid = basinAt[ni]
                    if bid > 0 {
                        let root = resolveBasin(bid)
                        if !neighborRoots.contains(root) {
                            neighborRoots.append(root)
                        }
                    }
                }
            }

            if neighborRoots.isEmpty {
                // 新局部最大值：要求距离峰 >= 1.05 px (允许最小 r≈1.5 px 微小粘连群)
                if s >= 1.05 {
                    let newId = basins.count + 1
                    var sumR = 0.0, sumG = 0.0, sumB = 0.0, cnt = 0.0
                    if colorAware {
                        for dy in -1...1 {
                            for dx in -1...1 {
                                let ni = (ly + dy) * pw + (lx + dx)
                                if inComp[ni] && !isChromaWall[ni] {
                                    sumR += cr[ni]; sumG += cg[ni]; sumB += cb[ni]; cnt += 1.0
                                }
                            }
                        }
                    }
                    let inv = cnt > 0 ? 1.0 / cnt : 1.0
                    basins.append(BasinInfo(
                        id: newId,
                        seedLi: li,
                        seedX: Double(lx),
                        seedY: Double(ly),
                        peakScore: s,
                        seedCR: cnt > 0 ? sumR * inv : cr[li],
                        seedCG: cnt > 0 ? sumG * inv : cg[li],
                        seedCB: cnt > 0 ? sumB * inv : cb[li],
                        mergedInto: nil
                    ))
                    basinAt[li] = newId
                }
            } else if neighborRoots.count == 1 {
                basinAt[li] = neighborRoots[0]
            } else {
                // 多个盆地于鞍点 s 处相遇：选择最高峰作为主盆，判断其余子峰是独立菌落还是噪声假峰
                let mainRoot = neighborRoots.max { a, b in
                    let pa = basins[a - 1].peakScore
                    let pb = basins[b - 1].peakScore
                    if abs(pa - pb) > 1e-7 { return pa < pb }
                    return a > b
                }!
                let mInfo = basins[mainRoot - 1]
                for rOther in neighborRoots where rOther != mainRoot {
                    let oInfo = basins[rOther - 1]
                    let chromaGap = colorAware
                        ? sqrt(pow(mInfo.seedCR - oInfo.seedCR, 2) + pow(mInfo.seedCG - oInfo.seedCG, 2) + pow(mInfo.seedCB - oInfo.seedCB, 2))
                        : 0.0
                    if chromaGap >= 0.14 { continue } // 异色斑（如蓝斑连白斑）绝对保留拆分

                    let distPeaks = hypot(mInfo.seedX - oInfo.seedX, mInfo.seedY - oInfo.seedY)
                    let hSmall = oInfo.peakScore
                    let drop = hSmall - s
                    let neckRatio = s / max(1e-6, hSmall)

                    let tooClose = distPeaks < max(2.2, 0.68 * hSmall)
                    let farApart = distPeaks >= 1.30 * hSmall
                    let shallowRipple = farApart
                        ? (drop < 0.20 || neckRatio > 0.965)
                        : (drop < 0.40 || (neckRatio > 0.935 && distPeaks < 1.15 * hSmall))
                    if tooClose || shallowRipple {
                        basins[rOther - 1].mergedInto = mainRoot
                    }
                }
                // 鞍点归属最近种子（但不跨盆合并有效双峰）
                let bestAttach = neighborRoots.map { resolveBasin($0) }.min { a, b in
                    let ba = basins[a - 1]
                    let bb = basins[b - 1]
                    let da = hypot(Double(lx) - ba.seedX, Double(ly) - ba.seedY)
                    let db = hypot(Double(lx) - bb.seedX, Double(ly) - bb.seedY)
                    return da < db
                } ?? resolveBasin(mainRoot)
                basinAt[li] = bestAttach
            }
        }

        let activeSeeds = basins.filter { $0.mergedInto == nil }
        guard activeSeeds.count >= 2 else { return [pixels] }

        // 仅当聚类中确实存在明显异色菌落（如蓝斑连白斑）时启用色彩引力，避免同色团块因传感噪声产生锯齿界
        var maxSeedChromaGap = 0.0
        if colorAware {
            for i in 0..<activeSeeds.count {
                for j in (i + 1)..<activeSeeds.count {
                    let gap = sqrt(
                        pow(activeSeeds[i].seedCR - activeSeeds[j].seedCR, 2) +
                        pow(activeSeeds[i].seedCG - activeSeeds[j].seedCG, 2) +
                        pow(activeSeeds[i].seedCB - activeSeeds[j].seedCB, 2)
                    )
                    if gap > maxSeedChromaGap { maxSeedChromaGap = gap }
                }
            }
        }
        let useColorWatershed = colorAware && maxSeedChromaGap >= 0.10

        // 第二阶段：基于优先队列的 Meyer 色彩 + 地形分水岭淹没，精准沿咽喉与色差界面切分
        var seedIdMap = [Int: Int]()
        for (idx, sInfo) in activeSeeds.enumerated() {
            seedIdMap[sInfo.id] = idx + 1
        }

        var label = [Int](repeating: 0, count: nPatch)
        var heap = MinHeap<WatershedHeapNode> { a, b in
            if abs(a.cost - b.cost) > 1e-9 { return a.cost < b.cost }
            return a.li < b.li
        }

        // 先标定每颗存活峰的种子点及与其同平台 8-邻点
        for sInfo in activeSeeds {
            guard let compactLabel = seedIdMap[sInfo.id] else { continue }
            label[sInfo.seedLi] = compactLabel
            let sx = sInfo.seedLi % pw
            let sy = sInfo.seedLi / pw
            for dy in -1...1 {
                for dx in -1...1 {
                    let ni = (sy + dy) * pw + (sx + dx)
                    if inComp[ni] && label[ni] == 0 && abs(score[ni] - sInfo.peakScore) <= 0.15 {
                        label[ni] = compactLabel
                    }
                }
            }
        }

        func pushNeighbors(of li: Int, assignedLabel: Int) {
            let x = li % pw
            let y = li / pw
            let sInfo = activeSeeds[assignedLabel - 1]
            let colorWeight = useColorWatershed ? 14.0 : 0.0
            for dy in -1...1 {
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let nx = x + dx
                    let ny = y + dy
                    let ni = ny * pw + nx
                    if !inComp[ni] || label[ni] != 0 { continue }
                    let rawChromaPen: Double = useColorWatershed
                        ? sqrt(pow(cr[ni] - sInfo.seedCR, 2) + pow(cg[ni] - sInfo.seedCG, 2) + pow(cb[ni] - sInfo.seedCB, 2))
                        : 0.0
                    let cPen = max(0.0, rawChromaPen - 0.045)
                    let distSeed = hypot(Double(nx) - sInfo.seedX, Double(ny) - sInfo.seedY)
                    let wallPen = (useColorWatershed && isChromaWall[ni]) ? 4.0 : 0.0
                    let cost = -score[ni] + colorWeight * cPen + wallPen + 0.002 * distSeed
                    heap.push(WatershedHeapNode(cost: cost, li: ni, label: assignedLabel))
                }
            }
        }

        for ly in 1..<(ph - 1) {
            for lx in 1..<(pw - 1) {
                let li = ly * pw + lx
                if label[li] > 0 {
                    pushNeighbors(of: li, assignedLabel: label[li])
                }
            }
        }

        while let node = heap.pop() {
            if label[node.li] != 0 { continue }
            label[node.li] = node.label
            pushNeighbors(of: node.li, assignedLabel: node.label)
        }

        reconnectWatershedOrphans(
            label: &label,
            inComp: inComp,
            width: pw,
            height: ph,
            seedLocations: activeSeeds.map { ($0.seedLi, $0.seedX, $0.seedY) }
        )

        // 若因隔离边存在极少数未触及前景像元，兜底归属最近存活峰
        var buckets = [[Int]](repeating: [], count: activeSeeds.count)
        for p in pixels {
            let lx = (p % w) - minX + 1
            let ly = (p / w) - minY + 1
            let li = ly * pw + lx
            var lbl = label[li]
            if lbl <= 0 {
                var bestIdx = 1
                var bestDist = Double.infinity
                for (idx, sInfo) in activeSeeds.enumerated() {
                    let d = hypot(Double(lx) - sInfo.seedX, Double(ly) - sInfo.seedY)
                    if d < bestDist {
                        bestDist = d
                        bestIdx = idx + 1
                    }
                }
                lbl = bestIdx
            }
            buckets[lbl - 1].append(p)
        }
        return buckets.filter { !$0.isEmpty }
    }

    /// 清理分水岭切割边缘可能产生的孤立碎点，将与主峰断连的像元重新归属相邻有效连通体。
    private static func reconnectWatershedOrphans(
        label: inout [Int],
        inComp: [Bool],
        width pw: Int,
        height ph: Int,
        seedLocations: [(li: Int, x: Double, y: Double)]
    ) {
        let nPatch = pw * ph
        var connected = [Bool](repeating: false, count: nPatch)
        for (idx, seed) in seedLocations.enumerated() {
            let target = idx + 1
            guard seed.li >= 0, seed.li < nPatch, label[seed.li] == target, !connected[seed.li] else { continue }
            var queue = [seed.li]
            connected[seed.li] = true
            var head = 0
            while head < queue.count {
                let cur = queue[head]
                head += 1
                let x = cur % pw
                let y = cur / pw
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= ph { continue }
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        if nx < 0 || nx >= pw { continue }
                        let ni = ny * pw + nx
                        if !connected[ni] && label[ni] == target {
                            connected[ni] = true
                            queue.append(ni)
                        }
                    }
                }
            }
        }

        var orphans: [Int] = []
        for li in 0..<nPatch where inComp[li] && label[li] > 0 && !connected[li] {
            orphans.append(li)
        }
        guard !orphans.isEmpty else { return }

        // 多轮向已连通主体邻域吸附
        for _ in 0..<4 {
            var remaining: [Int] = []
            for li in orphans {
                let x = li % pw
                let y = li / pw
                var bestLbl = 0
                var bestDist = Double.infinity
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= ph { continue }
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        if nx < 0 || nx >= pw { continue }
                        let ni = ny * pw + nx
                        if connected[ni] && label[ni] > 0 {
                            let s = seedLocations[label[ni] - 1]
                            let d = hypot(Double(x) - s.x, Double(y) - s.y)
                            if d < bestDist {
                                bestDist = d
                                bestLbl = label[ni]
                            }
                        }
                    }
                }
                if bestLbl > 0 {
                    label[li] = bestLbl
                    connected[li] = true
                } else {
                    remaining.append(li)
                }
            }
            if remaining.count == orphans.count || remaining.isEmpty { break }
            orphans = remaining
        }
    }
    
    // MARK: - 5. 一维灰度积分投影与局部峰值检测 (用于 Gel 与 Western Blot 自动泳道/条带定位)
    
    public static func columnProfile(gray: [Float], width: Int, height: Int, y0: Int = 0, y1: Int? = nil, invert: Bool = false) -> [Double] {
        guard width > 0, height > 0, gray.count >= width * height else {
            return width > 0 ? [Double](repeating: 0, count: width) : []
        }
        let top = max(0, min(height - 1, y0))
        let bottom = max(top + 1, min(height, y1 ?? height))
        let count = Double(bottom - top)
        var rowSum = [Float](repeating: 0, count: width)
        gray.withUnsafeBufferPointer { gBuf in
            rowSum.withUnsafeMutableBufferPointer { sBuf in
                guard let gPtr = gBuf.baseAddress, let sPtr = sBuf.baseAddress else { return }
                let len = vDSP_Length(width)
                for y in top..<bottom {
                    vDSP_vadd(gPtr + y * width, 1, sPtr, 1, sPtr, 1, len)
                }
            }
        }
        let denom = count * 255.0
        var out = [Double](repeating: 0, count: width)
        for x in 0..<width {
            let v = Double(rowSum[x]) / denom
            out[x] = invert ? (1.0 - v) : v
        }
        return out
    }
    
    public static func rowProfile(gray: [Float], width: Int, height: Int, x0: Int = 0, x1: Int? = nil, invert: Bool = false) -> [Double] {
        guard width > 0, height > 0, gray.count >= width * height else {
            return height > 0 ? [Double](repeating: 0, count: height) : []
        }
        let left = max(0, min(width - 1, x0))
        let right = max(left + 1, min(width, x1 ?? width))
        let span = vDSP_Length(right - left)
        let denom = Double(right - left) * 255.0
        var out = [Double](repeating: 0, count: height)
        gray.withUnsafeBufferPointer { gBuf in
            guard let gPtr = gBuf.baseAddress else { return }
            for y in 0..<height {
                var sum: Float = 0
                vDSP_sve(gPtr + y * width + left, 1, &sum, span)
                let v = Double(sum) / denom
                out[y] = invert ? (1.0 - v) : v
            }
        }
        return out
    }
    
    public static func findPeaks(
        profile: [Double],
        minProminence: Double = 0.04,
        minGap: Int = 8,
        smoothWindow: Int = 3
    ) -> [BioSignalPeak] {
        let n = profile.count
        guard n >= 3 else { return [] }
        let half = max(0, smoothWindow / 2)
        var smoothed = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            var s = 0.0
            for j in lo...hi { s += profile[j] }
            smoothed[i] = s / Double(hi - lo + 1)
        }
        
        var candidates: [BioSignalPeak] = []
        let gap = max(1, minGap)
        for i in 1..<(n - 1) {
            let v = smoothed[i]
            if v < smoothed[i - 1] || v <= smoothed[i + 1] { continue }
            let lo = max(0, i - gap * 3)
            let hi = min(n - 1, i + gap * 3)
            var base = v
            for j in lo...hi { base = min(base, smoothed[j]) }
            let prom = v - base
            if prom >= minProminence {
                candidates.append(
                    BioSignalPeak(
                        index: i,
                        fraction: Double(i) / Double(max(1, n - 1)),
                        value: v,
                        prominence: prom
                    )
                )
            }
        }
        candidates.sort { $0.prominence > $1.prominence }
        var kept: [BioSignalPeak] = []
        for cand in candidates {
            if kept.allSatisfy({ abs($0.index - cand.index) >= gap }) {
                kept.append(cand)
            }
        }
        return kept.sorted { $0.index < $1.index }
    }
    
    // MARK: - 6. 内置高仿真示范实验图像生成器 (开箱即用免外部图片文件依赖)
    
    /// 生成蓝白斑琼脂平板示范图像 (含蓝斑、白斑与少量粘连菌落)
    public static func generateDemoColonyPlatePlane(width: Int = 380, height: Int = 380) -> BioImagePlane {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var gray = [Float](repeating: 0, count: width * height)
        let cx = Double(width) / 2.0
        let cy = Double(height) / 2.0
        let dishR = Double(min(width, height)) * 0.45
        
        // 生成确定性蓝斑与白斑坐标
        var rng = Mulberry32Generator(seed: 20261104)
        struct SynthColony {
            let x: Double
            let y: Double
            let r: Double
            let isBlue: Bool
        }
        var colonies: [SynthColony] = []
        for i in 0..<46 {
            let angle = rng.nextDouble() * 2.0 * Double.pi
            let dist = sqrt(rng.nextDouble()) * (dishR * 0.84)
            let x = cx + dist * cos(angle)
            let y = cy + dist * sin(angle)
            let rad = 5.2 + rng.nextDouble() * 3.8
            let isBlue = (i % 3 != 0) // 约 2/3 阳性白斑或蓝斑区分
            colonies.append(SynthColony(x: x, y: y, r: rad, isBlue: isBlue))
        }
        
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let distCenter = hypot(Double(x) - cx, Double(y) - cy)
                var r: Double = 236
                var g: Double = 232
                var b: Double = 218
                if distCenter > dishR {
                    r = 45; g = 48; b = 56
                } else if distCenter > dishR - 4.0 {
                    r = 180; g = 184; b = 192
                } else {
                    for col in colonies {
                        let d = hypot(Double(x) - col.x, Double(y) - col.y)
                        if d <= col.r {
                            let falloff = 1.0 - (d / col.r) * 0.35
                            if col.isBlue {
                                r = 38.0 * falloff
                                g = 98.0 * falloff
                                b = 210.0 * falloff
                            } else {
                                r = 135.0 * falloff
                                g = 128.0 * falloff
                                b = 112.0 * falloff
                            }
                            break
                        }
                    }
                }
                let ru = UInt8(min(255, max(0, Int(r))))
                let gu = UInt8(min(255, max(0, Int(g))))
                let bu = UInt8(min(255, max(0, Int(b))))
                rgba[idx * 4] = ru
                rgba[idx * 4 + 1] = gu
                rgba[idx * 4 + 2] = bu
                rgba[idx * 4 + 3] = 255
                gray[idx] = 0.299 * Float(ru) + 0.587 * Float(gu) + 0.114 * Float(bu)
            }
        }
        return BioImagePlane(width: width, height: height, gray: gray, rgba: rgba)
    }
    
    /// 生成 Western Blot 双排条带示范图像 (上方目的蛋白 TP53，下方内参 GAPDH，6 个泳道)
    public static func generateDemoWesternBlotPlane(width: Int = 440, height: Int = 260) -> BioImagePlane {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var gray = [Float](repeating: 0, count: width * height)
        let laneX: [Double] = [0.14, 0.28, 0.42, 0.58, 0.72, 0.86]
        let targetRelStrength: [Double] = [0.48, 0.52, 0.92, 0.88, 0.18, 0.21] // WT x2, OE x2, KO x2
        let loadingStrength: [Double] = [0.76, 0.78, 0.75, 0.79, 0.77, 0.76]
        
        for y in 0..<height {
            let yn = Double(y) / Double(height)
            for x in 0..<width {
                let xn = Double(x) / Double(width)
                var val = 238.0 - 8.0 * xn // 浅灰膜背景
                for i in 0..<laneX.count {
                    let dx = abs(xn - laneX[i])
                    if dx < 0.048 {
                        let horizProfile = cos((dx / 0.048) * (Double.pi / 2.0))
                        // 目的蛋白行 y = 0.36
                        let dy1 = abs(yn - 0.36)
                        if dy1 < 0.055 {
                            let v1 = exp(-(dy1 * dy1) / (2.0 * 0.018 * 0.018)) * horizProfile * targetRelStrength[i] * 195.0
                            val -= v1
                        }
                        // 内参蛋白行 y = 0.70
                        let dy2 = abs(yn - 0.70)
                        if dy2 < 0.055 {
                            let v2 = exp(-(dy2 * dy2) / (2.0 * 0.018 * 0.018)) * horizProfile * loadingStrength[i] * 185.0
                            val -= v2
                        }
                    }
                }
                let u = UInt8(min(255, max(5, Int(round(val)))))
                let idx = y * width + x
                rgba[idx * 4] = u
                rgba[idx * 4 + 1] = u
                rgba[idx * 4 + 2] = u
                rgba[idx * 4 + 3] = 255
                gray[idx] = Float(u)
            }
        }
        return BioImagePlane(width: width, height: height, gray: gray, rgba: rgba)
    }
    
    /// 生成琼脂糖凝胶电泳示范图像 (含 Lane 1 Marker DL2000 与 4 个 PCR/酶切样品泳道)
    public static func generateDemoAgaroseGelPlane(width: Int = 460, height: Int = 320) -> BioImagePlane {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var gray = [Float](repeating: 0, count: width * height)
        let lanes: [Double] = [0.15, 0.33, 0.51, 0.69, 0.85]
        let markerY: [Double] = [0.22, 0.35, 0.43, 0.52, 0.66, 0.82] // 2000, 1000, 750, 500, 250, 100 bp
        let sampleBands: [[Double]] = [
            markerY,
            [0.28, 0.46], // Vector + Insert
            [0.35],       // PCR 1000 bp
            [0.31],       // PCR 1350 bp
            [0.52]        // 500 bp
        ]
        
        for y in 0..<height {
            let yn = Double(y) / Double(height)
            for x in 0..<width {
                let xn = Double(x) / Double(width)
                var val = 22.0 + 6.0 * sin(xn * 3.14)
                for lIdx in 0..<lanes.count {
                    let dx = abs(xn - lanes[lIdx])
                    if dx < 0.045 {
                        let hEnv = cos((dx / 0.045) * (Double.pi / 2.0))
                        for (bIdx, by) in sampleBands[lIdx].enumerated() {
                            let dy = abs(yn - by)
                            if dy < 0.032 {
                                let boost = (lIdx == 0 && bIdx == 2) ? 225.0 : 185.0 // 750bp 高亮带
                                val += exp(-(dy * dy) / (2.0 * 0.009 * 0.009)) * hEnv * boost
                            }
                        }
                    }
                }
                let u = UInt8(min(255, max(0, Int(round(val)))))
                let idx = y * width + x
                rgba[idx * 4] = u
                rgba[idx * 4 + 1] = UInt8(min(255.0, Double(u) * 1.04))
                rgba[idx * 4 + 2] = u
                rgba[idx * 4 + 3] = 255
                gray[idx] = Float(u)
            }
        }
        return BioImagePlane(width: width, height: height, gray: gray, rgba: rgba)
    }

    // MARK: - 7. OME-TIFF / ImageJ / TIFF 物理像素尺寸与通道元数据提取器 (P13)

    public static func extractTIFFMetadata(at url: URL) -> BioImageTIFFMetadata {
        guard let data = try? Data(contentsOf: url) else {
            return BioImageTIFFMetadata()
        }
        return extractTIFFMetadata(from: data, sourceURL: url)
    }

    public static func extractTIFFMetadata(from data: Data, sourceURL: URL? = nil) -> BioImageTIFFMetadata {
        var rawDesc: String? = nil
        var xRes: Double? = nil
        var resUnit: Int? = nil

        // 1. 通过 ImageIO 读取 TIFF 字典属性
        let cfData = data as CFData
        if let imgSource = CGImageSourceCreateWithData(cfData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [CFString: Any] {
            if let tiffDict = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                if let d = tiffDict[kCGImagePropertyTIFFImageDescription] as? String {
                    rawDesc = d
                }
                if let xr = tiffDict[kCGImagePropertyTIFFXResolution] as? NSNumber {
                    xRes = xr.doubleValue
                }
                if let ru = tiffDict[kCGImagePropertyTIFFResolutionUnit] as? NSNumber {
                    resUnit = ru.intValue
                }
            }
        }

        // 2. 二进制快速回退扫描：若 ImageIO 未解析出 ImageDescription，直接在 TIFF IFD 中提取 Tag 270 (ImageDescription)
        if rawDesc == nil || rawDesc?.isEmpty == true {
            rawDesc = extractTIFFTag270String(from: data)
        }

        // 3. 优先级 1：OME-XML
        if let desc = rawDesc, (desc.contains("<OME") || desc.contains("<Pixels")) {
            if var omeMeta = parseOMEXMLString(desc) {
                omeMeta.descriptionRaw = desc
                return omeMeta
            }
        }

        // 4. 优先级 2：ImageJ 元数据 (ImageJ=...)
        if let desc = rawDesc, desc.contains("ImageJ=") {
            if var ijMeta = parseImageJDescription(desc, xResolution: xRes, resolutionUnit: resUnit) {
                ijMeta.descriptionRaw = desc
                return ijMeta
            }
        }

        // 5. 优先级 3：标准 TIFF Resolution (ResolutionUnit: 3 = cm, 2 = inch)
        if let xr = xRes, xr > 0, let ru = resUnit {
            let umPerPx: Double? = {
                if ru == 3 {
                    // 1 cm = 10,000 µm
                    return 10000.0 / xr
                } else if ru == 2 {
                    // 1 inch = 25,400 µm
                    return 25400.0 / xr
                }
                return nil
            }()
            if let um = umPerPx, um > 0.001, um < 5000.0 {
                return BioImageTIFFMetadata(
                    physicalPixelSizeUM: (um * 10000.0).rounded() / 10000.0,
                    physicalSizeSource: "TIFF-Resolution",
                    descriptionRaw: rawDesc
                )
            }
        }

        return BioImageTIFFMetadata(descriptionRaw: rawDesc)
    }

    /// 使用 Foundation.XMLParser 严格解析 OME-XML 中的 Pixels 物理尺寸与 Channel 名称 (P13)
    public static func parseOMEXMLString(_ xml: String) -> BioImageTIFFMetadata? {
        guard let xmlData = xml.data(using: .utf8) else { return nil }
        let parser = OMEPatternXMLParser(data: xmlData)
        return parser.parse()
    }

    /// 解析 ImageJ 标头信息 (如 unit=micron, spacing=0.325, 或使用 XResolution) (P13)
    public static func parseImageJDescription(_ desc: String, xResolution: Double?, resolutionUnit: Int?) -> BioImageTIFFMetadata? {
        var unitIsMicron = false
        var spacingVal: Double? = nil
        let lines = desc.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("unit=") {
                let u = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
                if u == "micron" || u == "µm" || u == "um" || u == "microns" {
                    unitIsMicron = true
                }
            } else if trimmed.lowercased().hasPrefix("spacing=") {
                if let v = Double(trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)), v > 0 {
                    spacingVal = v
                }
            }
        }
        if unitIsMicron {
            if let sp = spacingVal, sp > 0 {
                return BioImageTIFFMetadata(physicalPixelSizeUM: sp, physicalSizeSource: "ImageJ")
            }
            if let xr = xResolution, xr > 0 {
                // ImageJ 常见为像素/微米
                let um = 1.0 / xr
                return BioImageTIFFMetadata(physicalPixelSizeUM: (um * 10000.0).rounded() / 10000.0, physicalSizeSource: "ImageJ")
            }
        }
        return nil
    }

    /// 二进制提取 TIFF Tag 270 (ImageDescription)
    private static func extractTIFFTag270String(from data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        let isLittleEndian: Bool
        if data[0] == 0x49 && data[1] == 0x49 {
            isLittleEndian = true
        } else if data[0] == 0x4D && data[1] == 0x4D {
            isLittleEndian = false
        } else {
            return nil
        }
        func readUInt16(at offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1])
            return isLittleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
        }
        func readUInt32(at offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            return isLittleEndian ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) : ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        }
        guard let magic = readUInt16(at: 2), magic == 42 else { return nil }
        guard let ifdOffset = readUInt32(at: 4), ifdOffset > 0, Int(ifdOffset) < data.count else { return nil }
        let ifdPos = Int(ifdOffset)
        guard let entryCount = readUInt16(at: ifdPos) else { return nil }
        var cur = ifdPos + 2
        for _ in 0..<entryCount {
            guard cur + 12 <= data.count else { break }
            guard let tag = readUInt16(at: cur) else { break }
            if tag == 270 { // ImageDescription
                guard let count = readUInt32(at: cur + 4) else { break }
                let length = Int(count)
                let valOffset = cur + 8
                if length <= 4 {
                    let slice = data.subdata(in: valOffset..<(valOffset + length))
                    return String(data: slice, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \t\n\r"))
                } else if let offset = readUInt32(at: valOffset), Int(offset) + length <= data.count {
                    let slice = data.subdata(in: Int(offset)..<(Int(offset) + length))
                    return String(data: slice, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \t\n\r"))
                }
            }
            cur += 12
        }
        return nil
    }

    /// 合成包含合法 OME-XML ImageDescription 标签的最小 TIFF 测试数据 (P13)
    public static func generateSyntheticOMETIFFData(
        width: Int = 120,
        height: Int = 80,
        physicalSizeXUM: Double = 0.325,
        channelNames: [String] = ["DAPI", "EGFP"]
    ) -> Data {
        let channelXML = channelNames.enumerated().map { idx, name in
            "<Channel ID=\"Channel:0:\(idx)\" Name=\"\(name)\" />"
        }.joined(separator: "\n      ")
        let omeXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <OME xmlns="http://www.openmicroscopy.org/Schemas/OME/2016-06">
          <Image ID="Image:0" Name="Synthetic_OME_Test">
            <Pixels ID="Pixels:0" DimensionOrder="XYCZT" Type="uint8" SizeX="\(width)" SizeY="\(height)" SizeZ="1" SizeC="\(channelNames.count)" SizeT="1" PhysicalSizeX="\(physicalSizeXUM)" PhysicalSizeXUnit="µm" PhysicalSizeY="\(physicalSizeXUM)" PhysicalSizeYUnit="µm">
              \(channelXML)
            </Pixels>
          </Image>
        </OME>
        """
        let xmlBytes = Array(omeXML.utf8) + [0] // 以 null 结尾
        let pixelCount = width * height
        let pixelBytes = [UInt8](repeating: 128, count: pixelCount)

        // 构造合法的 Little-Endian TIFF 结构
        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00]) // "II", 42
        var ifdOffset = UInt32(8)
        data.append(Data(bytes: &ifdOffset, count: 4))

        let tagCount: UInt16 = 11
        data.append(Data(bytes: [UInt8(tagCount & 0xFF), UInt8(tagCount >> 8)], count: 2))

        let ifdSize = 2 + Int(tagCount) * 12 + 4
        let xmlOffset = UInt32(8 + ifdSize)
        let pixelOffset = UInt32(Int(xmlOffset) + xmlBytes.count)

        func appendTag(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
            var t = tag.littleEndian
            var tp = type.littleEndian
            var cnt = count.littleEndian
            var vo = valueOrOffset.littleEndian
            data.append(Data(bytes: &t, count: 2))
            data.append(Data(bytes: &tp, count: 2))
            data.append(Data(bytes: &cnt, count: 4))
            data.append(Data(bytes: &vo, count: 4))
        }

        appendTag(tag: 256, type: 4, count: 1, valueOrOffset: UInt32(width))
        appendTag(tag: 257, type: 4, count: 1, valueOrOffset: UInt32(height))
        appendTag(tag: 258, type: 3, count: 1, valueOrOffset: 8) // BitsPerSample = 8
        appendTag(tag: 259, type: 3, count: 1, valueOrOffset: 1) // Compression = 1
        appendTag(tag: 262, type: 3, count: 1, valueOrOffset: 1) // Photometric = 1 (BlackIsZero)
        appendTag(tag: 270, type: 2, count: UInt32(xmlBytes.count), valueOrOffset: xmlOffset) // ImageDescription
        appendTag(tag: 273, type: 4, count: 1, valueOrOffset: pixelOffset) // StripOffsets
        appendTag(tag: 277, type: 3, count: 1, valueOrOffset: 1) // SamplesPerPixel = 1
        appendTag(tag: 278, type: 4, count: 1, valueOrOffset: UInt32(height)) // RowsPerStrip
        appendTag(tag: 279, type: 4, count: 1, valueOrOffset: UInt32(pixelCount)) // StripByteCounts
        appendTag(tag: 284, type: 3, count: 1, valueOrOffset: 1) // PlanarConfiguration = 1

        var nextIFD: UInt32 = 0
        data.append(Data(bytes: &nextIFD, count: 4))

        data.append(contentsOf: xmlBytes)
        data.append(contentsOf: pixelBytes)
        return data
    }
}

// MARK: - 8. OME-XML SAX 解析器 (P13)

private final class OMEPatternXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var meta = BioImageTIFFMetadata()
    private var channels: [String] = []

    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }

    func parse() -> BioImageTIFFMetadata? {
        guard parser.parse() else { return nil }
        if !channels.isEmpty {
            meta.channelNames = channels
        }
        if meta.physicalPixelSizeUM != nil {
            meta.physicalSizeSource = "OME-XML"
        }
        return meta
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let tag = elementName.lowercased()
        if tag.hasSuffix("pixels") {
            var rawSizeX: Double? = nil
            var rawUnitX: String = "µm"
            for (k, v) in attributeDict {
                let lk = k.lowercased()
                if lk == "physicalsizex" {
                    rawSizeX = Double(v)
                } else if lk == "physicalsizexunit" {
                    rawUnitX = v.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if lk == "sizec" {
                    meta.sizeC = Int(v)
                } else if lk == "sizez" {
                    meta.sizeZ = Int(v)
                } else if lk == "sizet" {
                    meta.sizeT = Int(v)
                }
            }
            if let sx = rawSizeX, sx > 0 {
                let factor: Double = {
                    let u = rawUnitX.lowercased()
                    if u == "nm" || u == "nanometer" || u == "nanometers" {
                        return 0.001
                    } else if u == "µm" || u == "um" || u == "micron" || u == "microns" || u == "micrometer" || u == "micrometers" {
                        return 1.0
                    } else if u == "mm" || u == "millimeter" || u == "millimeters" {
                        return 1000.0
                    } else if u == "cm" || u == "centimeter" || u == "centimeters" {
                        return 10000.0
                    }
                    return 1.0
                }()
                meta.physicalPixelSizeUM = (sx * factor * 10000.0).rounded() / 10000.0
            }
        } else if tag.hasSuffix("channel") {
            for (k, v) in attributeDict {
                let lk = k.lowercased()
                if lk == "name" {
                    let name = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        channels.append(name)
                    }
                }
            }
        }
    }
}
