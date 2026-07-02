//
//  XOInventoryApp.swift
//  XOInventory
//
//  A macOS SwiftUI app that inventories VMs on an XCP-NG cluster
//  by talking to the Xen Orchestra REST API.
//

import SwiftUI

// MARK: - Menu → view signals
//
// Menu commands live in the App scene; the state they act on lives in views.
// Notifications bridge the two without threading bindings through every layer.

extension Notification.Name {
    static let showTokenHelp    = Notification.Name("XOInventory.showTokenHelp")
    static let refreshInventory = Notification.Name("XOInventory.refreshInventory")
    static let exportCSV        = Notification.Name("XOInventory.exportCSV")
    static let exportPDF        = Notification.Name("XOInventory.exportPDF")
    static let selectVMsTab     = Notification.Name("XOInventory.selectVMsTab")
    static let selectHostsTab   = Notification.Name("XOInventory.selectHostsTab")
    static let focusSearch      = Notification.Name("XOInventory.focusSearch")
}

/// Shared state the menu bar needs for enabling/disabling items.
/// Views update it; AppCommands observes it.
@MainActor
final class MenuState: ObservableObject {
    static let shared = MenuState()
    @Published var isConnected = false
    @Published var hasVMs = false
    private init() {}
}

@main
struct XOInventoryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            AppCommands(menuState: .shared)
        }
    }
}

// MARK: - Menu bar commands

private struct AppCommands: Commands {
    @ObservedObject var menuState: MenuState

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        // Replaces the stock "XOInventory Help" item (which shows "Help isn't
        // available" — there's no Apple Help book). Declarative, so it survives
        // SwiftUI's menu-bar rebuilds; AppKit NSMenu surgery does not.
        CommandGroup(replacing: .help) {
            Button("Getting an Authentication Token…") {
                post(.showTokenHelp)
            }
        }

        // File → Export
        CommandGroup(replacing: .importExport) {
            Button("Export as CSV…") { post(.exportCSV) }
                .disabled(!canExport)
            Button("Export as PDF…") { post(.exportPDF) }
                .disabled(!canExport)
        }

        // Edit → Find
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") { post(.focusSearch) }
                .keyboardShortcut("f")
                .disabled(!menuState.isConnected)
        }

        // View → tabs + refresh
        CommandGroup(before: .toolbar) {
            Button("Show VMs") { post(.selectVMsTab) }
                .keyboardShortcut("1")
                .disabled(!menuState.isConnected)
            Button("Show Hosts") { post(.selectHostsTab) }
                .keyboardShortcut("2")
                .disabled(!menuState.isConnected)
            Divider()
            Button("Refresh") { post(.refreshInventory) }
                .keyboardShortcut("r")
                .disabled(!menuState.isConnected)
            Divider()
        }
    }

    private var canExport: Bool {
        menuState.isConnected && menuState.hasVMs
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
