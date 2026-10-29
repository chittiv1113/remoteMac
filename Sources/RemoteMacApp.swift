import SwiftUI

@main
struct RemoteMacApp: App {
    @StateObject private var helper = Helper()

    var body: some Scene {
        MenuBarExtra("remoteMac", systemImage: "dot.radiowaves.left.and.right") {
            MenuView(helper: helper)
        }
        .menuBarExtraStyle(.window)
    }
}
