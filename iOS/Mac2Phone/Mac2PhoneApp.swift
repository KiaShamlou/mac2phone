import SwiftUI

@main
struct Mac2PhoneApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(mirror: model.mirror)
                .environmentObject(model)
        }
    }
}
