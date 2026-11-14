//
//  ParallelLinkView.swift
//  Aidoku
//
//  Lets the user pick the same title in another installed source
//  (e.g. the Russian translation) to show while holding a page in the reader.
//

import AidokuRunner
import SwiftUI

struct ParallelLinkView: View {
    let manga: AidokuRunner.Manga

    // presented through SwiftUINavigationViewController, which dismisses via the coordinator
    @EnvironmentObject private var path: NavigationCoordinator

    @State private var query: String
    @State private var currentLink: ParallelLink?
    @State private var sourceNames: [String: String] = [:]
    @State private var results: [SourceResults] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var alternativeTitles: [String] = []

    private struct SourceResults: Identifiable {
        let source: AidokuRunner.Source
        let entries: [AidokuRunner.Manga]
        var id: String { source.key }
    }

    init(manga: AidokuRunner.Manga) {
        self.manga = manga
        self._query = State(initialValue: manga.title)
        self._currentLink = State(initialValue: ParallelLinkStore.link(for: manga))
    }

    var body: some View {
        List {
            if let currentLink {
                Section(NSLocalizedString("PARALLEL_LINKED_TO")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentLink.title)
                        Text(sourceNames[currentLink.sourceKey] ?? currentLink.sourceKey)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        ParallelLinkStore.setLink(nil, for: manga)
                        self.currentLink = nil
                    } label: {
                        Text(NSLocalizedString("PARALLEL_UNLINK"))
                    }
                }
            }

            Section {
                TextField(NSLocalizedString("PARALLEL_SEARCH_PLACEHOLDER"), text: $query)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .onSubmit { search() }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !alternativeTitles.isEmpty {
                        Text(String(
                            format: NSLocalizedString("PARALLEL_ALSO_SEARCHING"),
                            alternativeTitles.joined(separator: " · ")
                        ))
                    }
                    Text(NSLocalizedString("PARALLEL_LINK_FOOTER"))
                }
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }

            ForEach(results) { group in
                Section(group.source.name) {
                    ForEach(group.entries, id: \.key) { entry in
                        Button {
                            select(entry, source: group.source)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .foregroundStyle(.primary)
                                if let authors = entry.authors, !authors.isEmpty {
                                    Text(authors.joined(separator: ", "))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if !isLoading && results.isEmpty {
                Section {
                    Text(NSLocalizedString("PARALLEL_NO_RESULTS"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("PARALLEL_LINK"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            search()
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func select(_ entry: AidokuRunner.Manga, source: AidokuRunner.Source) {
        let link = ParallelLink(sourceKey: source.key, mangaKey: entry.key, title: entry.title)
        ParallelLinkStore.setLink(link, for: manga)
        currentLink = link
        searchTask?.cancel()
        path.dismiss()
    }

    private func search() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let currentSourceKey = manga.sourceKey

        searchTask = Task {
            isLoading = true
            results = []

            // installed sources other than the one this manga comes from
            var sources: [AidokuRunner.Source] = []
            for info in await SourceManager.shared.getSourceInfos(includeDisabled: false) {
                guard
                    info.sourceId != currentSourceKey,
                    let source = await SourceManager.shared.source(for: info.sourceId)
                else { continue }
                sources.append(source)
            }
            // show sources in the reader's likely target language first
            sources.sort { lhs, rhs in
                lhs.languages.contains("ru") && !rhs.languages.contains("ru")
            }
            sourceNames = Dictionary(sources.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
            if let source = await SourceManager.shared.source(for: currentSourceKey) {
                sourceNames[source.key] = source.name
            }
            if let currentLink, sourceNames[currentLink.sourceKey] == nil,
               let source = await SourceManager.shared.source(for: currentLink.sourceKey) {
                sourceNames[source.key] = source.name
            }

            // the same series is often listed under a different name in other languages,
            // so also search by alternative titles (only when searching the series' own title)
            var queries = [text]
            if text == manga.title {
                let alternatives = await ParallelTitleLookup.alternativeTitles(for: text)
                guard !Task.isCancelled else { return }
                alternativeTitles = alternatives
                queries += alternatives
            } else {
                alternativeTitles = []
            }

            // sources freeze if too many searches run at once, so limit concurrency
            let maxConcurrentTasks = 3
            let maxEntriesPerSource = 6
            await withTaskGroup(of: (AidokuRunner.Source, [AidokuRunner.Manga]).self) { group in
                for source in sources.prefix(maxConcurrentTasks) {
                    group.addTask { (source, await Self.search(source: source, queries: queries)) }
                }
                var index = maxConcurrentTasks
                while let (source, entries) = await group.next() {
                    if index < sources.count {
                        let next = sources[index]
                        group.addTask { (next, await Self.search(source: next, queries: queries)) }
                        index += 1
                    }
                    guard !Task.isCancelled else { continue }
                    if !entries.isEmpty {
                        let ordered = sources.map(\.key)
                        // some sources return dozens of loose matches; the right one is near the top
                        results.append(.init(source: source, entries: Array(entries.prefix(maxEntriesPerSource))))
                        results.sort {
                            (ordered.firstIndex(of: $0.source.key) ?? 0) < (ordered.firstIndex(of: $1.source.key) ?? 0)
                        }
                    }
                }
            }

            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }

    /// Searches one source with every query, merging results without duplicates.
    /// Exact title matches come first, then results in query order.
    private static func search(source: AidokuRunner.Source, queries: [String]) async -> [AidokuRunner.Manga] {
        var exact: [AidokuRunner.Manga] = []
        var other: [AidokuRunner.Manga] = []
        var seenKeys: Set<String> = []
        let normalizedQueries = Set(queries.map(ParallelTitleLookup.normalize))
        for query in queries {
            guard !Task.isCancelled else { break }
            let entries = (try? await source.getSearchMangaList(query: query, page: 1, filters: []))?.entries ?? []
            for entry in entries where seenKeys.insert(entry.key).inserted {
                if normalizedQueries.contains(ParallelTitleLookup.normalize(entry.title)) {
                    exact.append(entry)
                } else {
                    other.append(entry)
                }
            }
        }
        return exact + other
    }
}
