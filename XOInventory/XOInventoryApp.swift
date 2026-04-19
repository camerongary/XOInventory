//
//  XOInventoryApp.swift
//  XOInventory
//
//  A macOS SwiftUI app that inventories VMs on an XCP-NG cluster
//  by talking to the Xen Orchestra REST API.
//

import SwiftUI

@main
struct XOInventoryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
