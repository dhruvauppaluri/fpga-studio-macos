import FPGAStudioCore
import SwiftUI

enum StudioMetrics {
    static let compact: CGFloat = 8
    static let standard: CGFloat = 12
    static let roomy: CGFloat = 20
    static let cardRadius: CGFloat = 14
}

struct FirstLaunchTour: View {
    @EnvironmentObject private var workspace: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("didSeeWelcomeTour") private var didSeeWelcomeTour = false
    @AppStorage("experienceProfile") private var experienceProfile: ExperienceProfile = .beginner
    @AppStorage("showLearningGuide") private var showLearningGuide = true
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @State private var page = 0

    private var pages: [(icon: String, title: String, text: String, note: String)] { [
        (
            experienceProfile.icon,
            "Choose how you work",
            "FPGA Studio has one complete toolset for everyone. Your workspace profile changes how much guidance and technical detail appears by default—not what you can do.",
            "You can switch profiles or customize either setting at any time."
        ),
        (
            "waveform.path.ecg",
            workflowTitle,
            workflowText,
            workflowNote
        ),
        (
            "bolt.horizontal.circle.fill",
            "Try hardware safely",
            "When your C5G is connected, program SRAM first. It is temporary and clears when power is removed. Persistent flash stays behind an advanced confirmation.",
            "The guide always suggests one safe next step."
        )
    ] }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 82, height: 82)
                    Image(systemName: pages[page].icon)
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 10) {
                    Text(pages[page].title).font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(pages[page].text)
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(3)
                        .frame(maxWidth: 520)
                    Text(pages[page].note)
                        .font(.callout.weight(.medium)).foregroundStyle(.blue)
                        .padding(.top, 2)
                }
                if page == 0 {
                    ExperienceProfilePicker(selection: $experienceProfile)
                        .frame(maxWidth: 590)
                }
                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: index == page ? 22 : 7, height: 7)
                    }
                }.accessibilityLabel("Page \(page + 1) of \(pages.count)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(42)

            Divider()
            HStack {
                Button("Skip Tour") { finish() }.buttonStyle(.borderless)
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page < pages.count - 1 {
                    Button("Continue") { page += 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Create a Project") {
                        finish(createProject: true)
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(20).background(.bar)
        }
        .frame(width: 780, height: 650)
    }

    private func finish(createProject: Bool = false) {
        showLearningGuide = experienceProfile.showsLearningGuideByDefault
        showAdvancedControls = experienceProfile.showsAdvancedControlsByDefault
        didSeeWelcomeTour = true
        dismiss()
        if createProject {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                workspace.showingNewProject = true
            }
        }
    }

    private var workflowTitle: String {
        switch experienceProfile {
        case .beginner: "Learn one step at a time"
        case .hobbyist: "Move quickly from idea to hardware"
        case .professional: "Keep the complete flow close"
        }
    }

    private var workflowText: String {
        switch experienceProfile {
        case .beginner: "Start with Blinky, simulate without a board, and follow one recommended action at a time. Plain-language help is always nearby."
        case .hobbyist: "Create portable HDL projects, inspect waveforms, edit validated pins, and move directly through simulation, build, and programming."
        case .professional: "Work with direct toolbar actions, raw diagnostics, build artifacts, deterministic routing, board constraints, and visible backend details."
        }
    }

    private var workflowNote: String {
        switch experienceProfile {
        case .beginner: "The learning guide stays visible until you hide it."
        case .hobbyist: "Guidance stays available without taking over the workspace."
        case .professional: "Advanced controls are visible by default; safety checks still apply."
        }
    }
}

struct ExperienceProfilePicker: View {
    @Binding var selection: ExperienceProfile

    var body: some View {
        HStack(spacing: StudioMetrics.compact) {
            ForEach(ExperienceProfile.allCases) { profile in
                Button { selection = profile } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(profile.title, systemImage: profile.icon).font(.headline)
                        Text(profile.summary)
                            .font(.caption).foregroundStyle(selection == profile ? .white.opacity(0.88) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                    .padding(StudioMetrics.standard)
                    .background(selection == profile ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius, style: .continuous))
                    .foregroundStyle(selection == profile ? Color.white : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(profile.title) workspace")
                .accessibilityValue(selection == profile ? "Selected" : "Not selected")
            }
        }
    }
}

struct GuidedNextStepView: View {
    @EnvironmentObject private var workspace: WorkspaceController
    @AppStorage("showLearningGuide") private var showLearningGuide = true

    private var step: LearningStep { workspace.learningProgress.nextStep }

    var body: some View {
        HStack(spacing: StudioMetrics.standard) {
            Image(systemName: icon)
                .font(.title2).foregroundStyle(step == .complete ? .green : .blue)
                .frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(step.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 16)
            progressDots
            nextButton
            Button { showLearningGuide = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Hide the learning guide. You can turn it back on in Settings.")
                .accessibilityLabel("Hide learning guide")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("learning-guide")
    }

    @ViewBuilder private var nextButton: some View {
        switch step {
        case .validate:
            Button("Check Project") { workspace.perform(.validate) }.buttonStyle(.borderedProminent).disabled(!workspace.canRun)
        case .simulate:
            Button("Run Simulation") { workspace.simulateSelectedTest() }.buttonStyle(.borderedProminent).disabled(!workspace.canSimulate)
        case .build:
            if workspace.buildToolsReady {
                Button("Build Bitstream") { workspace.perform(.build) }.buttonStyle(.borderedProminent).disabled(!workspace.canRun)
            } else {
                SettingsLink { Text("Set Up Build Tools") }.buttonStyle(.borderedProminent)
            }
        case .connect:
            Button("Detect Board") { workspace.perform(.detectDevice) }.buttonStyle(.borderedProminent).disabled(!workspace.canRun)
        case .programSRAM:
            Button("Program SRAM") { workspace.programSRAM() }.buttonStyle(.borderedProminent).disabled(!workspace.canProgramSRAM)
        case .complete:
            Button("Open Learn Center") { workspace.showingLearnCenter = true }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { index in
                Circle().fill(index < workspace.learningProgress.completedCount ? Color.green : Color.secondary.opacity(0.22))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("\(workspace.learningProgress.completedCount) of 5 beginner steps complete")
    }

    private var icon: String {
        switch step {
        case .validate: "checkmark.circle"
        case .simulate: "waveform.path.ecg"
        case .build: "hammer"
        case .connect: "cable.connector"
        case .programSRAM: "bolt.horizontal.circle"
        case .complete: "checkmark.seal.fill"
        }
    }
}

struct LearnCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: LearningTopic.ID? = LearningTopic.all.first?.id

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.icon).tag(topic.id)
            }
            .searchable(text: $query, prompt: "Search FPGA terms")
            .navigationTitle("Learn")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            if let topic = LearningTopic.all.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: topic.icon).font(.system(size: 36)).foregroundStyle(.blue)
                        Text(topic.title).font(.largeTitle.bold())
                        Text(topic.summary).font(.title3).foregroundStyle(.secondary)
                        Divider()
                        Text(topic.detail).font(.body).lineSpacing(4).textSelection(.enabled)
                        if let tip = topic.tip {
                            Label(tip, systemImage: "lightbulb.fill")
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
                        }
                    }.padding(34).frame(maxWidth: 680, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Choose a Topic", systemImage: "book")
            }
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) } }
        .frame(minWidth: 850, minHeight: 590)
    }

    private var filtered: [LearningTopic] {
        query.isEmpty ? LearningTopic.all : LearningTopic.all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }
}

struct LearningTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let detail: String
    let tip: String?

    static let all: [LearningTopic] = [
        .init(id: "flow", title: "The FPGA Flow", icon: "arrow.right.circle", summary: "The five steps from source code to working hardware.", detail: "1. Validate checks project structure and pins.\n\n2. Simulate runs a testbench on your Mac.\n\n3. Build synthesizes the logic, places it in the FPGA, routes connections, and creates an RBF bitstream.\n\n4. Detect confirms the board and JTAG chain.\n\n5. Program SRAM loads the design temporarily and safely.", tip: "Repeat the flow after every meaningful design change."),
        .init(id: "hdl", title: "HDL", icon: "chevron.left.forwardslash.chevron.right", summary: "Code that describes digital hardware, not a sequence of software instructions.", detail: "Verilog, SystemVerilog, and VHDL describe registers, wires, gates, and how signals change with clocks. Statements may represent hardware operating at the same time, so HDL is not executed top-to-bottom like an ordinary app.", tip: "For a first project, SystemVerilog is concise and works well with the included examples."),
        .init(id: "top", title: "Top Module", icon: "square.stack.3d.up", summary: "The outermost design connected to physical board pins.", detail: "The top module or entity is the root of the hardware design. Its ports connect to clocks, LEDs, buttons, switches, and other pins through the QSF constraints file.", tip: "If a board signal is missing, check both the top-level port and its pin assignment."),
        .init(id: "testbench", title: "Testbench", icon: "testtube.2", summary: "A simulation-only environment that drives inputs and checks outputs.", detail: "A testbench creates clocks and reset signals, supplies input values, waits for the design to respond, and reports whether behavior is correct. It is not synthesized into the FPGA.", tip: "Test one small behavior at a time and include an intentional failure message."),
        .init(id: "waveform", title: "Waveform", icon: "waveform.path.ecg", summary: "A timeline of signal values from simulation.", detail: "Waveforms show when clocks rise, registers change, and buses carry values. Zoom into the moment a result becomes wrong, then trace backward through the signals that produced it.", tip: "Start with the clock, reset, inputs, and one important output."),
        .init(id: "synthesis", title: "Synthesis", icon: "square.3.layers.3d", summary: "Converts HDL into logic cells and connections.", detail: "Yosys reads the synthesizable HDL and creates a netlist. FPGA Studio uses conservative logic-only settings for the experimental Cyclone V flow, avoiding unsupported hard-block inference by default.", tip: nil),
        .init(id: "place-route", title: "Place and Route", icon: "point.topleft.down.to.point.bottomright.curvepath", summary: "Fits the synthesized design into the physical FPGA.", detail: "nextpnr-mistral chooses locations for logic cells and routes signals between them. It also reports timing and utilization, then produces the RBF configuration bitstream.", tip: "A design can simulate correctly and still fail timing; always inspect the build report."),
        .init(id: "pins", title: "Pins and Constraints", icon: "pin", summary: "Maps top-level signals to physical package pins.", detail: "The QSF file assigns signals such as the 50 MHz clock and LEDs to pins on the Cyclone V package. FPGA Studio rejects duplicate, unknown, missing, and direction-incompatible assignments before synthesis.", tip: "Use the validated pin editor instead of guessing package-pin names."),
        .init(id: "sram", title: "SRAM Programming", icon: "bolt.horizontal.circle", summary: "Temporarily configures the FPGA—the safest first hardware action.", detail: "Programming SRAM loads the design immediately. The configuration disappears when the board loses power, making it ideal for experiments and recovery-safe testing.", tip: "Always try a new bitstream in SRAM before considering persistent flash."),
        .init(id: "flash", title: "Persistent Flash", icon: "externaldrive.badge.exclamationmark", summary: "Stores a design that reloads when the board powers on.", detail: "EPCQ flash programming persists across power cycles. FPGA Studio requires a separate confirmation, verifies the exact artifact, prevents sleep and app termination during the write, and performs a post-write device check.", tip: "Use flash only after the same artifact works correctly in SRAM."),
        .init(id: "rv32i", title: "RV32I Lab", icon: "cpu", summary: "A guided framework for designing your own 32-bit RISC-V processor.", detail: "The template supplies interfaces, a C5G wrapper, a small demonstration program, and directed test scaffolding. It intentionally does not contain a finished CPU. Build it in milestones: program counter, decode, register file, ALU, control flow, loads/stores, and retirement.", tip: "Complete Blinky and become comfortable with waveforms before starting the processor lab.")
    ]
}
