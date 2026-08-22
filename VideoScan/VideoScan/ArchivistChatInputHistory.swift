// ArchivistChatInputHistory.swift
// Session-local command recall for Hallie's in-app chat field.

import Foundation

struct ArchivistChatInputHistory: Equatable {
    private(set) var entries: [String] = []
    private(set) var selectedIndex: Int?
    private var draft = ""
    private let limit: Int

    init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    mutating func record(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, entries.last != value {
            entries.append(value)
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
        }
        selectedIndex = nil
        draft = ""
    }

    mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let selectedIndex {
            self.selectedIndex = max(0, selectedIndex - 1)
        } else {
            draft = current
            selectedIndex = entries.count - 1
        }
        guard let selectedIndex else { return nil }
        return entries[selectedIndex]
    }

    mutating func next() -> String? {
        guard let selectedIndex else { return nil }
        if selectedIndex < entries.count - 1 {
            self.selectedIndex = selectedIndex + 1
            return entries[selectedIndex + 1]
        }
        self.selectedIndex = nil
        return draft
    }
}
