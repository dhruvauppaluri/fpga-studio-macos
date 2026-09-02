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
            .onAppear {
                appDelegate.prepareForTermination = {
                    await workspace.flushPendingEdits()
                }
            }
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
            CommandGroup(replacing: .saveItem) {
                Button("Save") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(workspace.project == nil)
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
                Button("Program SRAM") { workspace.programSRAM() }
                    .disabled(!workspace.canProgramSRAM)
                Button("Program Flash…") { workspace.prepareFlash() }
                    .disabled(!workspace.canProgramFlash)
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
    var prepareForTermination: (@MainActor () async -> Bool)?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make sure macOS treats FPGA Studio as a normal foreground app.
        NSApp.setActivationPolicy(.regular)

        // Activate the application.
        NSApp.activate(ignoringOtherApps: true)

        // Once SwiftUI has created the WindowGroup window, make it key.
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.flashWriteActive else { return .terminateCancel }
        guard let prepareForTermination else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { @MainActor [weak self] in
            let saved = await prepareForTermination()
            self?.terminationInProgress = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
