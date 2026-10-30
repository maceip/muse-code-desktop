//
//  PaletteCommand.swift
//  PiCode
//
//  The single list of actions that menus, keyboard shortcuts, and the command
//  palette all share. Views own the dispatch (they have the focused controls);
//  this file only names the actions and their presentation.
//

import Foundation

enum PaletteCommand: String, CaseIterable, Identifiable, Hashable {
    case newSession
    case addProject
    case cloneRepository
    case newProjectFolder
    case refreshSessions
    case renameSession
    case exportSession
    case deleteSession

    case focusComposer
    case interrupt
    case abortRun
    case cycleModel
    case cycleThinkingLevel

    case toggleInspector
    case toggleSidebar
    case toggleTerminal

    case copyTranscript
    case copyLastResponse
    case openInTerminal
    case openInVSCode
    case revealInFinder
    case revealPiDirectory

    case openSettings
    case showPiSetup
    case checkForPiUpdates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newSession: return "New Session"
        case .addProject: return "Open Project Folder…"
        case .cloneRepository: return "Clone Git Repository…"
        case .newProjectFolder: return "New Project Folder…"
        case .refreshSessions: return "Reload Sessions"
        case .renameSession: return "Rename Session…"
        case .exportSession: return "Export Session…"
        case .deleteSession: return "Delete Session…"
        case .focusComposer: return "Focus Composer"
        case .interrupt: return "Interrupt and Restore Queue"
        case .abortRun: return "Stop the Agent"
        case .cycleModel: return "Cycle Model"
        case .cycleThinkingLevel: return "Cycle Thinking Level"
        case .toggleInspector: return "Toggle Inspector"
        case .toggleSidebar: return "Toggle Sidebar"
        case .toggleTerminal: return "Toggle Terminal"
        case .copyTranscript: return "Copy Transcript"
        case .copyLastResponse: return "Copy Last Response"
        case .openInTerminal: return "Open Project in Terminal"
        case .openInVSCode: return "Open Project in VS Code"
        case .revealInFinder: return "Reveal Project in Finder"
        case .revealPiDirectory: return "Reveal Muse's Config Folder"
        case .openSettings: return "Settings…"
        case .showPiSetup: return "Muse Setup Help"
        case .checkForPiUpdates: return "Check Muse Version"
        }
    }

    var systemImage: String {
        switch self {
        case .newSession: return "message-add-01"
        case .addProject: return "folder-add"
        case .cloneRepository: return "git-branch"
        case .newProjectFolder: return "add-01"
        case .refreshSessions: return "refresh"
        case .renameSession: return "edit-02"
        case .exportSession: return "arrow-up-right-01"
        case .deleteSession: return "delete-01"
        case .focusComposer: return "edit-02"
        case .interrupt: return "stop"
        case .abortRun: return "stop-circle"
        case .cycleModel: return "cpu"
        case .cycleThinkingLevel: return "bulb"
        case .toggleInspector: return "layout-align-right"
        case .toggleSidebar: return "layout-align-left"
        case .toggleTerminal: return "terminal"
        case .copyTranscript: return "clipboard-text"
        case .copyLastResponse: return "checkmark-circle-01"
        case .openInTerminal: return "terminal"
        case .openInVSCode: return "code"
        case .revealInFinder: return "folder"
        case .revealPiDirectory: return "setting-3"
        case .openSettings: return "settings-02"
        case .showPiSetup: return "message-question"
        case .checkForPiUpdates: return "refresh-circle"
        }
    }

    /// Actions that only make sense with a live session.
    var requiresSession: Bool {
        switch self {
        case .newSession, .addProject, .cloneRepository, .newProjectFolder, .refreshSessions, .toggleInspector, .toggleSidebar,
             .toggleTerminal, .openSettings, .showPiSetup,
             .checkForPiUpdates, .revealPiDirectory:
            return false
        default:
            return true
        }
    }

    /// Actions that require Muse to be idle.
    var requiresIdleAgent: Bool {
        switch self {
        case .deleteSession, .renameSession, .exportSession, .newSession:
            return true
        default:
            return false
        }
    }

    var shortcutHint: String? {
        switch self {
        case .newSession: return "⌘N"
        case .addProject: return "⇧⌘O"
        case .refreshSessions: return "⌘R"
        case .renameSession: return "⇧⌘R"
        case .exportSession: return "⇧⌘E"
        case .focusComposer: return "⌘L"
        case .interrupt: return "esc"
        case .abortRun: return "⌘."
        case .toggleInspector: return "⌥⌘I"
        case .toggleSidebar: return "⌃⌘S"
        case .toggleTerminal: return "⌃`"
        case .openSettings: return "⌘,"
        case .openInTerminal: return "⇧⌘T"
        default: return nil
        }
    }

    var group: Group {
        switch self {
        case .newSession, .addProject, .cloneRepository, .newProjectFolder, .refreshSessions, .renameSession,
             .exportSession, .deleteSession:
            return .session
        case .focusComposer, .interrupt, .abortRun, .cycleModel, .cycleThinkingLevel:
            return .run
        case .toggleInspector, .toggleSidebar, .toggleTerminal:
            return .view
        case .copyTranscript, .copyLastResponse, .openInTerminal, .openInVSCode, .revealInFinder,
             .revealPiDirectory:
            return .share
        case .openSettings, .showPiSetup, .checkForPiUpdates:
            return .app
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case session
        case run
        case view
        case share
        case app

        var id: String { rawValue }

        var label: String {
            switch self {
            case .session: return "Session"
            case .run: return "Agent"
            case .view: return "View"
            case .share: return "Share"
            case .app: return "PiCode"
            }
        }
    }
}
