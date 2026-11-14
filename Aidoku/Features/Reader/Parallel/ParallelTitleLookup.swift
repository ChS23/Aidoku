//
//  ParallelTitleLookup.swift
//  Aidoku
//
//  Looks up alternative titles (Russian, romanized, synonyms) of a series on
//  Shikimori, so translations can be found in sources that list the series
//  under a different name.
//

import Foundation

enum ParallelTitleLookup {
    private struct Response: Decodable {
        struct DataField: Decodable {
            let mangas: [Entry]
        }
        let data: DataField?
    }

    private struct Entry: Decodable {
        let name: String
        let russian: String?
        let english: String?
        let synonyms: [String]?
    }

    private static let query = """
    query($search: String) {
      mangas(search: $search, limit: 5, censored: false) {
        name
        russian
        english
        synonyms
      }
    }
    """

    /// Returns alternative titles for `title`, most useful first (Russian, then romanized),
    /// excluding `title` itself. Returns an empty array when nothing is found or the request fails.
    static func alternativeTitles(for title: String, limit: Int = 3) async -> [String] {
        guard let url = URL(string: "https://shikimori.io/api/graphql") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aidoku", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["query": query, "variables": ["search": title]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let entries = (try? JSONDecoder().decode(Response.self, from: data))?.data?.mangas,
            !entries.isEmpty
        else {
            return []
        }

        // prefer an entry whose known names contain the exact title
        let normalizedTitle = normalize(title)
        let entry = entries.first { entry in
            ([entry.name, entry.english].compactMap { $0 } + (entry.synonyms ?? []))
                .contains { normalize($0) == normalizedTitle }
        } ?? entries[0]

        var seen: Set<String> = [normalizedTitle]
        var result: [String] = []
        for candidate in [entry.russian, entry.name, entry.english].compactMap({ $0 }) + (entry.synonyms ?? []) {
            let key = normalize(candidate)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(candidate)
            if result.count >= limit { break }
        }
        return result
    }

    static func normalize(_ string: String) -> String {
        string
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
