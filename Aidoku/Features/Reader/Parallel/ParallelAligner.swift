//
//  ParallelAligner.swift
//  Aidoku
//
//  Text-robust alignment of two versions of the same chapter (e.g. English
//  and Russian scans of a webtoon). Both chapters are reduced to narrow
//  grayscale strips; a banded DTW over row blocks gives a coarse monotonic
//  mapping, and a local search refines it around the finger at hold time.
//
//  Distances are truncated L1 (every pixel difference is capped), so lettering
//  and redrawn sound effects, which differ between versions, can't outweigh
//  the artwork, which is the same.
//

import UIKit

/// A chapter reduced to a narrow grayscale strip.
struct ParallelStrip: Sendable {
    static let width = 64

    /// rows * width intensities, 0...1
    let intensity: [Float]
    /// rows * width gradient magnitudes, 0...1 (scaled)
    let gradient: [Float]
    let rows: Int
    /// first row of every page
    let pageStarts: [Int]
    let pageHeights: [Int]

    /// `pages` are per-page grayscale pixels from `grayPixels(_:)`, in reading order.
    init?(pages: [[Float]]) {
        let width = Self.width
        var intensity: [Float] = []
        var starts: [Int] = []
        var heights: [Int] = []
        for pixels in pages {
            guard !pixels.isEmpty else { return nil }
            starts.append(intensity.count / width)
            heights.append(pixels.count / width)
            intensity += pixels
        }
        let rows = intensity.count / width
        guard rows > 0 else { return nil }

        var gradient = [Float](repeating: 0, count: intensity.count)
        for y in 0..<rows {
            for x in 0..<width {
                let i = y * width + x
                let dx = x + 1 < width ? abs(intensity[i + 1] - intensity[i]) : 0
                let dy = y + 1 < rows ? abs(intensity[i + width] - intensity[i]) : 0
                gradient[i] = min((dx + dy) * 2, 1)
            }
        }

        self.intensity = intensity
        self.gradient = gradient
        self.rows = rows
        self.pageStarts = starts
        self.pageHeights = heights
    }

    /// Scales an image to the strip width (keeping aspect) and returns grayscale values 0...1.
    static func grayPixels(_ image: UIImage) -> [Float]? {
        let width = Self.width
        guard let cgImage = image.cgImage, cgImage.width > 0 else { return nil }
        let height = max(1, Int((Double(cgImage.height) * Double(width) / Double(cgImage.width)).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return bytes.map { Float($0) / 255 }
    }

    /// Converts a strip row to (page index, position inside page 0...1).
    func page(atRow row: Int) -> (index: Int, fraction: CGFloat) {
        let row = min(max(row, 0), rows - 1)
        var low = 0
        var high = pageStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if pageStarts[mid] <= row { low = mid } else { high = mid - 1 }
        }
        let fraction = CGFloat(row - pageStarts[low]) / CGFloat(max(pageHeights[low], 1))
        return (low, fraction)
    }

    func row(page index: Int, fraction: CGFloat) -> Int? {
        guard pageStarts.indices.contains(index) else { return nil }
        return pageStarts[index] + Int(CGFloat(pageHeights[index]) * min(max(fraction, 0), 1))
    }
}

/// Maps rows of one strip (the chapter being read) to rows of another (the linked chapter).
struct ParallelAlignment: Sendable {
    let source: ParallelStrip
    let target: ParallelStrip
    /// coarse mapping: source block -> target block (fractional)
    private let blockMap: [Float]

    /// rows pooled per block in the coarse stage
    private static let blockRows = 8
    /// columns pooled per block cell in the coarse stage
    private static let blockColumns = 2
    /// pixel differences are capped at this value (0...1 scale)
    private static let truncation: Float = 0.25
    /// cost of a non-diagonal DTW step (skipping rows on one side)
    private static let stepPenalty: Float = 0.2

    init(source: ParallelStrip, target: ParallelStrip) {
        self.source = source
        self.target = target
        self.blockMap = Self.coarseMap(source: source, target: target)
    }

    /// Returns the target row matching `row` of the source strip.
    func targetRow(forSourceRow row: Int) -> Int {
        let guess = coarseTargetRow(forSourceRow: row)
        return refine(sourceRow: row, guess: guess)
    }

    // MARK: Coarse stage

    private func coarseTargetRow(forSourceRow row: Int) -> Int {
        guard !blockMap.isEmpty else { return row }
        let position = Float(row) / Float(Self.blockRows)
        let index = min(Int(position), blockMap.count - 1)
        let next = blockMap[min(index + 1, blockMap.count - 1)]
        let mapped = blockMap[index] + (next - blockMap[index]) * (position - Float(index))
        return Int(mapped * Float(Self.blockRows))
    }

    private static func blocks(_ strip: ParallelStrip) -> (values: [Float], count: Int, width: Int) {
        let width = ParallelStrip.width / blockColumns
        let count = strip.rows / blockRows
        var values = [Float](repeating: 0, count: count * width)
        let scale = 1 / Float(blockRows * blockColumns)
        strip.intensity.withUnsafeBufferPointer { src in
            for b in 0..<count {
                for row in 0..<blockRows {
                    let base = (b * blockRows + row) * ParallelStrip.width
                    for c in 0..<width {
                        var sum: Float = 0
                        for k in 0..<blockColumns {
                            sum += src[base + c * blockColumns + k]
                        }
                        values[b * width + c] += sum * scale
                    }
                }
            }
        }
        return (values, count, width)
    }

    /// Banded DTW over row blocks; returns, for every source block, the matching target block.
    private static func coarseMap(source: ParallelStrip, target: ParallelStrip) -> [Float] {
        let a = blocks(source)
        let b = blocks(target)
        let n = a.count
        let m = b.count
        let width = a.width
        guard n > 1, m > 1 else { return [] }

        let band = max(20, Int(0.06 * Double(max(n, m))))
        let span = 2 * band + 1
        let infinity = Float.greatestFiniteMagnitude / 4
        // backpointers: 0 diagonal, 1 up (source advances), 2 left (target advances)
        var back = [UInt8](repeating: 0, count: n * span)
        var lows = [Int](repeating: 0, count: n)
        var previous = [Float](repeating: infinity, count: span)
        var current = [Float](repeating: infinity, count: span)
        var previousLow = 0

        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                for i in 0..<n {
                    let center = Int((Double(i) * Double(m - 1) / Double(n - 1)).rounded())
                    let low = max(0, center - band)
                    let high = min(m - 1, center + band)
                    lows[i] = low
                    for k in 0..<span { current[k] = infinity }

                    for j in low...high {
                        // truncated L1 between block rows
                        var cost: Float = 0
                        let ai = i * width
                        let bj = j * width
                        for c in 0..<width {
                            cost += min(abs(av[ai + c] - bv[bj + c]), truncation)
                        }
                        cost /= Float(width)

                        let k = j - low
                        var best = infinity
                        var pointer: UInt8 = 0
                        if i == 0 && j == 0 {
                            best = 0
                        } else {
                            if i > 0 {
                                let pd = j - 1 - previousLow
                                if pd >= 0 && pd < span { best = previous[pd]; pointer = 0 }
                                let pu = j - previousLow
                                if pu >= 0 && pu < span, previous[pu] + stepPenalty < best {
                                    best = previous[pu] + stepPenalty
                                    pointer = 1
                                }
                            }
                            if k > 0, current[k - 1] + stepPenalty < best {
                                best = current[k - 1] + stepPenalty
                                pointer = 2
                            }
                        }
                        current[k] = best + cost
                        back[i * span + k] = pointer
                    }
                    swap(&previous, &current)
                    previousLow = low
                }
            }
        }

        // backtrack from the end, collecting the target range for every source block
        var minTarget = [Int](repeating: Int.max, count: n)
        var maxTarget = [Int](repeating: Int.min, count: n)
        var i = n - 1
        var j = m - 1
        while i >= 0 && j >= 0 {
            minTarget[i] = min(minTarget[i], j)
            maxTarget[i] = max(maxTarget[i], j)
            if i == 0 && j == 0 { break }
            let k = j - lows[i]
            guard k >= 0 && k < span else { break }
            switch back[i * span + k] {
                case 0: i -= 1; j -= 1
                case 1: i -= 1
                default: j -= 1
            }
        }

        var map = [Float](repeating: 0, count: n)
        for index in 0..<n {
            if minTarget[index] <= maxTarget[index] {
                map[index] = Float(minTarget[index] + maxTarget[index]) / 2
            } else {
                map[index] = index > 0 ? map[index - 1] : 0
            }
        }
        return map
    }

    // MARK: Refinement

    /// Searches around `guess` for the target row whose neighbourhood best matches the source.
    private func refine(sourceRow: Int, guess: Int) -> Int {
        let width = ParallelStrip.width
        let window = 100
        let sourceTop = min(max(sourceRow - window / 2, 0), max(source.rows - window, 0))
        let rows = min(window, source.rows - sourceTop)
        guard rows > 10 else { return guess }
        let anchor = sourceRow - sourceTop

        func cost(_ targetRow: Int) -> Float? {
            let top = targetRow - anchor
            guard top >= 0, top + rows <= target.rows else { return nil }
            var sum: Float = 0
            source.intensity.withUnsafeBufferPointer { si in
                source.gradient.withUnsafeBufferPointer { sg in
                    target.intensity.withUnsafeBufferPointer { ti in
                        target.gradient.withUnsafeBufferPointer { tg in
                            let s0 = sourceTop * width
                            let t0 = top * width
                            for p in 0..<(rows * width) {
                                sum += min(abs(si[s0 + p] - ti[t0 + p]), Self.truncation)
                                sum += min(abs(sg[s0 + p] - tg[t0 + p]), Self.truncation)
                            }
                        }
                    }
                }
            }
            return sum
        }

        var best = guess
        var bestCost = cost(guess) ?? .greatestFiniteMagnitude
        for (radius, step) in [(140, 8), (8, 1)] {
            let center = best
            for offset in stride(from: -radius, through: radius, by: step) where offset != 0 {
                if let value = cost(center + offset), value < bestCost {
                    bestCost = value
                    best = center + offset
                }
            }
        }
        return best
    }
}
