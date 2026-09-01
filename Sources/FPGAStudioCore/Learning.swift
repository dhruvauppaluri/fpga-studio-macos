import Foundation

public enum LearningStep: String, CaseIterable, Codable, Sendable {
    case validate
    case simulate
    case build
    case connect
    case programSRAM
    case complete

    public var title: String {
        switch self {
        case .validate: "Check your project"
        case .simulate: "See it work in simulation"
        case .build: "Build for the FPGA"
        case .connect: "Connect your board"
        case .programSRAM: "Try it safely on hardware"
        case .complete: "Your first FPGA flow is complete"
        }
    }

    public var explanation: String {
        switch self {
        case .validate: "Check the source files, top module, and board pins before running tools."
        case .simulate: "Run the testbench and inspect signals without needing an FPGA board."
        case .build: "Turn the HDL design into a bitstream for the Cyclone V GX."
        case .connect: "Connect the C5G over USB and confirm its JTAG chain."
        case .programSRAM: "Load the design temporarily. Power cycling clears it, so this is the safest first hardware step."
        case .complete: "Edit the design and repeat the flow, or begin the RV32I lab when you feel ready."
        }
    }
}

public struct LearningProgress: Equatable, Sendable {
    public var validated: Bool
    public var simulated: Bool
    public var built: Bool
    public var boardConnected: Bool
    public var programmedSRAM: Bool

    public init(validated: Bool = false, simulated: Bool = false, built: Bool = false, boardConnected: Bool = false, programmedSRAM: Bool = false) {
        self.validated = validated
        self.simulated = simulated
        self.built = built
        self.boardConnected = boardConnected
        self.programmedSRAM = programmedSRAM
    }

    public var completedCount: Int {
        [validated, simulated, built, boardConnected, programmedSRAM].filter { $0 }.count
    }

    public var nextStep: LearningStep {
        if !validated { return .validate }
        if !simulated { return .simulate }
        if !built { return .build }
        if !boardConnected { return .connect }
        if !programmedSRAM { return .programSRAM }
        return .complete
    }
}
