import SwiftUI

@main struct PolevoyJournalApp: App {
    @StateObject private var store = JournalStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { JournalHome().environmentObject(store).onChange(of: phase) { _, next in
            if next != .active { Task { await store.flush() } }
        } }
    }
}
