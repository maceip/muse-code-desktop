//
//  HarnessSessionIndex.swift
//  PiCode
//
//  Muse sessions are indexed directly by `SessionIndex` from
//  `~/.local/share/muse/sessions`.
//

import Foundation

enum HarnessSessionIndex {
    static func loadAllSessions(excluding existingPaths: Set<String>) -> [SessionRef] {
        []
    }

    static func history(id: String, harness: HarnessID) -> [PiMessage] {
        MuseSessionHistory.loadSummary(at: id).messages
    }
}
