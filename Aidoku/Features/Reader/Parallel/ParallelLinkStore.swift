//
//  ParallelLinkStore.swift
//  Aidoku
//
//  Stores links between a manga and the same title in another source
//  (for example, an English release and its Russian translation).
//

import AidokuRunner
import Foundation

struct ParallelLink: Codable, Hashable, Sendable {
    let sourceKey: String
    let mangaKey: String
    let title: String
}

enum ParallelLinkStore {
    static let didChangeNotification = Notification.Name("ParallelLinkStore.didChange")

    private static let defaultsKey = "Parallel.links"

    private static func id(sourceKey: String, mangaKey: String) -> String {
        "\(sourceKey)|\(mangaKey)"
    }

    private static func load() -> [String: ParallelLink] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let links = try? JSONDecoder().decode([String: ParallelLink].self, from: data)
        else {
            return [:]
        }
        return links
    }

    private static func save(_ links: [String: ParallelLink]) {
        if let data = try? JSONEncoder().encode(links) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func link(sourceKey: String, mangaKey: String) -> ParallelLink? {
        load()[id(sourceKey: sourceKey, mangaKey: mangaKey)]
    }

    static func link(for manga: AidokuRunner.Manga) -> ParallelLink? {
        link(sourceKey: manga.sourceKey, mangaKey: manga.key)
    }

    static func setLink(_ link: ParallelLink?, for manga: AidokuRunner.Manga) {
        var links = load()
        links[id(sourceKey: manga.sourceKey, mangaKey: manga.key)] = link
        save(links)
    }
}
