import SwiftUI
import MeetSpaceCore
import MeetSpaceFeatures

@main
struct MeetSpaceApp: App {
    @UIApplicationDelegateAdaptor(MeetSpaceAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitesting") {
            let model = AppModel(dependencies: UITestDependencies.make())
            if ProcessInfo.processInfo.arguments.contains("-demo") { model.enterDemo() }
            if ProcessInfo.processInfo.arguments.contains("-offline") { model.contentState = .offline }
            if ProcessInfo.processInfo.arguments.contains("-empty") { model.contentState = .empty }
            if ProcessInfo.processInfo.arguments.contains("-error") { model.contentState = .failed }
            if ProcessInfo.processInfo.arguments.contains("-loading") { model.contentState = .loading }
            _model = State(initialValue: model)
            return
        }
        #endif
        let runtime = AppPlatformRuntime.shared
        _model = State(initialValue: AppModel(dependencies: .live(calling: runtime.calling, notifications: runtime.notifications)))
    }

    var body: some Scene {
        WindowGroup { MeetSpaceRootView(model: model) }
    }
}
