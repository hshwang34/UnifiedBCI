import SwiftUI

@main
struct BCIWorkspaceApp: App {
    @State private var model = FeasibilityModel()

    var body: some Scene {
        WindowGroup("BCI Workspace — Phase 0") {
            FeasibilityView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
