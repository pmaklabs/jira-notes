//
//  Bookmark.swift
//  JiraNotes
//
//  Created by Peter Mak on 10/8/2025.
//

import Foundation

struct Bookmark {
    static let store = Bookmark()
    private let key = "jiraNotesDirBookmark"

    func save(url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            return true
        } catch { return false }
    }

    func resolveAndStart() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { _ = save(url: url) }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }
}
