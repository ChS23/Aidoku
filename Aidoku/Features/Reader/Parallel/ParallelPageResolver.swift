//
//  ParallelPageResolver.swift
//  Aidoku
//
//  Finds the page in a linked source (e.g. the Russian translation) that
//  corresponds to a position in the chapter being read, and loads its image
//  together with its neighbours.
//

import AidokuRunner
import Nuke
import UIKit

actor ParallelPageResolver {
    static let shared = ParallelPageResolver()

    struct Position: Sendable {
        /// index of the image page in the chapter being read
        let pageIndex: Int
        /// number of image pages in the chapter being read
        let pageCount: Int
        /// vertical position inside the page, 0...1
        let fraction: CGFloat
    }

    struct Result: @unchecked Sendable {
        /// consecutive pages of the linked chapter (target page and its neighbours)
        let images: [UIImage]
        /// index of the target page inside `images`
        let targetImageIndex: Int
        /// vertical position inside the target page, 0...1
        let fraction: CGFloat
        let label: String
    }

    enum ResolveError: LocalizedError {
        case sourceMissing(String)
        case noChapters(String)
        case chapterNotFound(String)
        case noPages

        var errorDescription: String? {
            switch self {
                case .sourceMissing(let key):
                    String(format: NSLocalizedString("PARALLEL_ERROR_SOURCE"), key)
                case .noChapters(let sourceName):
                    String(format: NSLocalizedString("PARALLEL_ERROR_NO_CHAPTERS"), sourceName)
                case .chapterNotFound(let number):
                    String(format: NSLocalizedString("PARALLEL_ERROR_CHAPTER"), number)
                case .noPages:
                    NSLocalizedString("PARALLEL_ERROR_PAGES")
            }
        }
    }

    private var chaptersCache: [String: [AidokuRunner.Chapter]] = [:]
    private var pagesCache: [String: [AidokuRunner.Page]] = [:]

    func resolve(
        link: ParallelLink,
        chapter: AidokuRunner.Chapter,
        position: Position
    ) async throws -> Result {
        guard let source = await SourceManager.shared.source(for: link.sourceKey) else {
            throw ResolveError.sourceMissing(link.sourceKey)
        }
        let manga = AidokuRunner.Manga(sourceKey: link.sourceKey, key: link.mangaKey, title: link.title)

        let linkedChapter = try await findChapter(matching: chapter, in: manga, source: source)
        let pages = try await pageList(for: linkedChapter, manga: manga, source: source)
        guard !pages.isEmpty else { throw ResolveError.noPages }

        // use the image alignment when it's ready, otherwise map the position proportionally
        let targetIndex: Int
        let targetFraction: CGFloat
        let alignmentKey = Self.alignmentKey(link: link, chapter: chapter)
        if
            let alignment = alignments[alignmentKey],
            alignment.source.pageStarts.count == position.pageCount,
            alignment.target.pageStarts.count == pages.count,
            let sourceRow = alignment.source.row(page: position.pageIndex, fraction: position.fraction)
        {
            let aligned = alignment.target.page(atRow: alignment.targetRow(forSourceRow: sourceRow))
            targetIndex = aligned.index
            targetFraction = aligned.fraction
        } else if pages.count == position.pageCount {
            targetIndex = min(max(position.pageIndex, 0), pages.count - 1)
            targetFraction = position.fraction
        } else {
            let relative = (CGFloat(position.pageIndex) + position.fraction) / CGFloat(max(position.pageCount, 1))
            let scaled = min(max(relative, 0), 0.9999) * CGFloat(pages.count)
            targetIndex = min(Int(scaled), pages.count - 1)
            targetFraction = scaled - CGFloat(targetIndex)
        }

        LogManager.logger.info(
            "Parallel: position page \(position.pageIndex)/\(position.pageCount) fraction \(position.fraction)"
                + " -> linked page \(targetIndex)/\(pages.count) fraction \(targetFraction)"
                + (alignments[alignmentKey] != nil ? " (aligned)" : " (proportional)")
        )

        // load the target page first, then its neighbours (failures of neighbours are ignored)
        let targetImage = try await loadImage(page: pages[targetIndex], source: source)
        var images = [targetImage]
        var targetImageIndex = 0
        if targetIndex > 0, let previous = try? await loadImage(page: pages[targetIndex - 1], source: source) {
            images.insert(previous, at: 0)
            targetImageIndex = 1
        }
        if targetIndex + 1 < pages.count, let next = try? await loadImage(page: pages[targetIndex + 1], source: source) {
            images.append(next)
        }

        let number = linkedChapter.chapterNumber.map(Self.format) ?? "?"
        let label = String(
            format: NSLocalizedString("PARALLEL_CHAPTER_PAGE"),
            number,
            targetIndex + 1,
            pages.count
        )
        return Result(images: images, targetImageIndex: targetImageIndex, fraction: targetFraction, label: label)
    }

    /// Loads the linked chapter in advance and aligns it with the chapter being read,
    /// so holds land on the matching spot instead of a proportional guess.
    /// `readerPages` are the image pages of the chapter being read, in order.
    func prepare(
        link: ParallelLink,
        chapter: AidokuRunner.Chapter,
        readerPages: [AidokuRunner.Page],
        readerSource: AidokuRunner.Source?
    ) async {
        let key = Self.alignmentKey(link: link, chapter: chapter)
        guard alignments[key] == nil, !preparing.contains(key) else { return }
        guard let source = await SourceManager.shared.source(for: link.sourceKey) else { return }
        let manga = AidokuRunner.Manga(sourceKey: link.sourceKey, key: link.mangaKey, title: link.title)
        guard
            let linkedChapter = try? await findChapter(matching: chapter, in: manga, source: source),
            let linkedPages = try? await pageList(for: linkedChapter, manga: manga, source: source),
            !linkedPages.isEmpty, !readerPages.isEmpty
        else { return }

        preparing.insert(key)
        defer { preparing.remove(key) }
        let start = Date()

        // keep only a few chapter alignments in memory
        if alignments.count >= 3, let oldest = alignmentOrder.first {
            alignments[oldest] = nil
            alignmentOrder.removeFirst()
        }

        async let readerPixels = loadAllPixels(pages: readerPages, source: readerSource)
        async let linkedPixels = loadAllPixels(pages: linkedPages, source: source)
        guard
            let readerPixels = await readerPixels,
            let linkedPixels = await linkedPixels
        else {
            LogManager.logger.info("Parallel: alignment skipped, some pages failed to load")
            return
        }

        let alignment = await Task.detached(priority: .utility) { () -> ParallelAlignment? in
            guard
                let source = ParallelStrip(pages: readerPixels),
                let target = ParallelStrip(pages: linkedPixels)
            else { return nil }
            return ParallelAlignment(source: source, target: target)
        }.value
        guard let alignment else { return }
        alignments[key] = alignment
        alignmentOrder.append(key)
        LogManager.logger.info(
            "Parallel: aligned \(readerPages.count) pages with \(linkedPages.count) linked pages"
                + " in \(String(format: "%.1f", Date().timeIntervalSince(start)))s"
        )
    }

    private var alignments: [String: ParallelAlignment] = [:]
    private var alignmentOrder: [String] = []
    private var preparing: Set<String> = []

    private static func alignmentKey(link: ParallelLink, chapter: AidokuRunner.Chapter) -> String {
        "\(link.sourceKey)|\(link.mangaKey)|\(chapter.key)"
    }

    /// Loads all pages (a few at a time) and reduces each to strip pixels right away,
    /// so full-size images aren't kept in memory. Returns nil if any page fails.
    private func loadAllPixels(pages: [AidokuRunner.Page], source: AidokuRunner.Source?) async -> [[Float]]? {
        var images = [[Float]?](repeating: nil, count: pages.count)
        let maxConcurrent = 4
        let loaded: Bool = await withTaskGroup(of: (Int, [Float]?).self) { group in
            var next = 0
            func addNext() {
                guard next < pages.count else { return }
                let index = next
                let page = pages[index]
                next += 1
                group.addTask {
                    var image = try? await self.loadImage(page: page, source: source)
                    if image == nil { // one retry
                        image = try? await self.loadImage(page: page, source: source)
                    }
                    return (index, image.flatMap(ParallelStrip.grayPixels))
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let (index, image) = await group.next() {
                guard let image else {
                    group.cancelAll()
                    return false
                }
                images[index] = image
                addNext()
            }
            return true
        }
        guard loaded else { return nil }
        return images.compactMap { $0 }
    }

    private func findChapter(
        matching chapter: AidokuRunner.Chapter,
        in manga: AidokuRunner.Manga,
        source: AidokuRunner.Source
    ) async throws -> AidokuRunner.Chapter {
        let cacheKey = "\(manga.sourceKey)|\(manga.key)"
        let chapters: [AidokuRunner.Chapter]
        if let cached = chaptersCache[cacheKey] {
            chapters = cached
        } else {
            let updated = try await source.getMangaUpdate(manga: manga, needsDetails: false, needsChapters: true)
            chapters = updated.chapters ?? []
            if !chapters.isEmpty {
                chaptersCache[cacheKey] = chapters
            }
            let numbers = chapters.prefix(5).map { "\($0.chapterNumber.map { String($0) } ?? "nil")" }
            LogManager.logger.info(
                "Parallel: \(manga.sourceKey) returned \(chapters.count) chapters, first numbers: \(numbers)"
            )
        }

        guard !chapters.isEmpty else {
            throw ResolveError.noChapters(source.name)
        }
        guard let number = chapter.chapterNumber else {
            throw ResolveError.chapterNotFound(chapter.title ?? "?")
        }
        let candidates = chapters.filter {
            guard let other = $0.chapterNumber else { return false }
            return abs(other - number) < 0.001
        }
        // prefer chapters that can actually be read
        if let match = candidates.first(where: { !$0.locked }) ?? candidates.first {
            return match
        }
        throw ResolveError.chapterNotFound(Self.format(number))
    }

    private func pageList(
        for chapter: AidokuRunner.Chapter,
        manga: AidokuRunner.Manga,
        source: AidokuRunner.Source
    ) async throws -> [AidokuRunner.Page] {
        let cacheKey = "\(manga.sourceKey)|\(manga.key)|\(chapter.key)"
        if let cached = pagesCache[cacheKey] {
            return cached
        }
        let pages = try await source.getPageList(manga: manga, chapter: chapter)
            .filter {
                if case .text = $0.content { return false }
                return true
            }
        pagesCache[cacheKey] = pages
        return pages
    }

    private func loadImage(page: AidokuRunner.Page, source: AidokuRunner.Source?) async throws -> UIImage {
        switch page.content {
            case .image(let image):
                return image
            case .url(let url, let context):
                let urlRequest = if !url.isFileURL, let source {
                    await source.getModifiedImageRequest(url: url, context: context)
                } else {
                    URLRequest(url: url)
                }
                var processors: [ImageProcessing] = []
                let processesPages = !url.isFileURL && (source?.features.processesPages ?? false)
                if processesPages, let source {
                    processors.append(PageInterceptorProcessor(source: source, pageContext: context))
                }
                let request = ImageRequest(
                    urlRequest: urlRequest,
                    processors: processors,
                    userInfo: [.processesKey: processesPages]
                )
                return try await ImagePipeline.shared.image(for: request)
            default:
                throw ResolveError.noPages
        }
    }

    private static func format(_ number: Float) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}
