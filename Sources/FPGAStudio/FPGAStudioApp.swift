import SwiftUI

@main
struct FPGAStudioApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var workspace = WorkspaceController()

    var body: some Scene {
        WindowGroup {
            Group {
                if workspace.project == nil {
                    WelcomeView()
                } else {
                    WorkspaceView()
                }
            }
            .environmentObject(workspace)
            .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { workspace.showingNewProject = true }
                    .keyboardShortcut("n")
                Button("Open Project…") { workspace.chooseProject() }
                    .keyboardShortcut("o")
            }
            CommandMenu("FPGA") {
                Button("Validate") { workspace.perform(.validate) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!workspace.canRun)
                Button("Simulate") { workspace.simulateSelectedTest() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!workspace.canSimulate)
                Button("Build") { workspace.perform(.build) }
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(!workspace.canRun)
                Divider()
                Button("Program SRAM") { workspace.perform(.programSRAM) }
                    .disabled(!workspace.canProgramSRAM)
                Button("Program Flash…") { workspace.prepareFlash() }
                    .disabled(!workspace.canRun)
                Divider()
                Button("Cancel Operation") { workspace.cancel() }
                    .disabled(!workspace.canCancel)
            }
            CommandGroup(after: .help) {
                Button("FPGA Learning Center") { workspace.showingLearnCenter = true }
                    .keyboardShortcut("?", modifiers: [.command, .shift])
                SettingsLink { Text("Customize Workspace…") }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(workspace)
                .frame(width: 720, height: 540)
        }
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static var flashWriteActive = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.flashWriteActive ? .terminateCancel : .terminateNow
    }
}
