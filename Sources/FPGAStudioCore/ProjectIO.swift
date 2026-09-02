import Foundation

public enum FPGAStudioError: LocalizedError, Sendable {
    case resourceMissing(String)
    case invalidProject(String)
    case unsafePath(String)
    case toolMissing(String)
    case commandFailed(tool: String, code: Int32, output: String)
    case unsupported(String)
    case checksumMismatch
    case signatureMismatch
    case noBitstream

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): "Required resource is missing: \(name)"
        case .invalidProject(let message): "Invalid FPGA project: \(message)"
        case .unsafePath(let path): "The project path is unsafe: \(path)"
        case .toolMissing(let tool): "\(tool) is not installed in the managed toolchain or PATH."
        case .commandFailed(let tool, let code, _): "\(tool) exited with status \(code)."
        case .unsupported(let message): message
        case .checksumMismatch: "The toolchain archive checksum does not match its manifest."
        case .signatureMismatch: "The toolchain archive signature is invalid."
        case .noBitstream: "Build the project successfully before programming the board."
        }
    }
}

public enum BundledResources {
    public static func boardProfile(id: String = "terasic-c5g") throws -> BoardProfile {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Boards/\(id).json")
        guard let url = packaged.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                ?? Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "Boards")
                ?? Bundle.module.url(forResource: id, withExtension: "json") else {
            throw FPGAStudioError.resourceMissing("Boards/\(id).json")
        }
        return try JSONDecoder().decode(BoardProfile.self, from: Data(contentsOf: url))
    }

    public static func toolchainManifest() throws -> ToolchainManifest {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ToolchainManifest.json")
        guard let url = packaged.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                ?? Bundle.module.url(forResource: "ToolchainManifest", withExtension: "json") else {
            throw FPGAStudioError.resourceMissing("ToolchainManifest.json")
        }
        return try JSONDecoder().decode(ToolchainManifest.self, from: Data(contentsOf: url))
    }
}

public enum ProjectStore {
    public static let manifestName = "fpga-project.json"

    public static func load(from root: URL) throws -> FPGAProject {
        let manifest = root.appendingPathComponent(manifestName)
        let data = try Data(contentsOf: manifest)
        return try JSONDecoder().decode(FPGAProject.self, from: data)
    }

    public static func save(_ project: FPGAProject, to root: URL) throws {
        guard !project.isReadOnly else {
            throw FPGAStudioError.unsupported("This project uses a newer schema and was opened read-only.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(project)
        try data.write(to: root.appendingPathComponent(manifestName), options: .atomic)
    }

    public static func resolve(_ relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0") else {
            throw FPGAStudioError.unsafePath(relativePath)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path == canonicalRoot.path || candidate.path.hasPrefix(prefix) else {
            throw FPGAStudioError.unsafePath(relativePath)
        }
        return candidate
    }

    public static func sourceURLs(for project: FPGAProject, root: URL, includeTestbenches: Bool = false) throws -> [URL] {
        try project.sources
            .filter { includeTestbenches || !$0.isTestbench }
            .map { try resolve($0.path, under: root) }
    }
}

public enum ProjectTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank
    case blinky
    case rv32i

    public static let recommendedForBeginners: ProjectTemplate = .blinky

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .blank: "Blank Design"
        case .blinky: "C5G Blinky"
        case .rv32i: "RV32I Lab"
        }
    }
    public var summary: String {
        switch self {
        case .blank: "A minimal synthesizable top level and testbench."
        case .blinky: "A safe 50 MHz counter driving the first green LED."
        case .rv32i: "Interfaces and directed tests for a processor you implement."
        }
    }
}

public enum ProjectTemplateFactory {
    public static func create(_ template: ProjectTemplate, language: HDLLanguage, name: String, at root: URL) throws -> FPGAProject {
        guard !FileManager.default.fileExists(atPath: root.path) else {
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            if !contents.isEmpty { throw FPGAStudioError.invalidProject("The destination folder is not empty.") }
            return try createInEmptyDirectory(template, language: language, name: name, root: root)
        }
        return try createInEmptyDirectory(template, language: language, name: name, root: root)
    }

    private static func createInEmptyDirectory(_ template: ProjectTemplate, language: HDLLanguage, name: String, root: URL) throws -> FPGAProject {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rtl"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sim"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("constraints"), withIntermediateDirectories: true)

        switch template {
        case .blank:
            return try createBlank(language: language, name: name, root: root)
        case .blinky:
            return try createBlinky(language: language, name: name, root: root)
        case .rv32i:
            return try createRV32I(name: name, root: root)
        }
    }

    private static func createBlank(language: HDLLanguage, name: String, root: URL) throws -> FPGAProject {
        let sourceName: String
        let testName: String
        let source: String
        let test: String
        switch language {
        case .verilog, .systemVerilog:
            let ext = language == .systemVerilog ? "sv" : "v"
            sourceName = "rtl/top.\(ext)"
            testName = "sim/top_tb.\(ext)"
            source = """
            module top(input wire CLOCK_50_B5B, output wire LEDG0);
              assign LEDG0 = CLOCK_50_B5B;
            endmodule
            """
            test = """
            `timescale 1ns/1ps
            module top_tb;
              reg clock = 0;
              wire led;
              top dut(.CLOCK_50_B5B(clock), .LEDG0(led));
              always #10 clock = ~clock;
              initial begin
                $dumpfile("waves.vcd");
                $dumpvars(0, top_tb);
                #100 $finish;
              end
            endmodule
            """
        case .vhdl:
            sourceName = "rtl/top.vhd"
            testName = "sim/top_tb.vhd"
            source = """
            library ieee;
            use ieee.std_logic_1164.all;
            entity top is port (CLOCK_50_B5B : in std_logic; LEDG0 : out std_logic); end entity;
            architecture rtl of top is begin LEDG0 <= CLOCK_50_B5B; end architecture;
            """
            test = """
            library ieee;
            use ieee.std_logic_1164.all;
            entity top_tb is end entity;
            architecture sim of top_tb is
              signal clock : std_logic := '0'; signal led : std_logic;
            begin
              dut: entity work.top port map(CLOCK_50_B5B => clock, LEDG0 => led);
              clock <= not clock after 10 ns;
              process begin wait for 100 ns; std.env.finish; end process;
            end architecture;
            """
        }
        try write(source, to: root.appendingPathComponent(sourceName))
        try write(test, to: root.appendingPathComponent(testName))
        try write(minimalQSF(top: "top", output: "LEDG0"), to: root.appendingPathComponent("constraints/c5g.qsf"))
        let project = FPGAProject(name: name, top: "top", sources: [
            .init(path: sourceName, language: language),
            .init(path: testName, language: language, isTestbench: true)
        ], tests: [.init(name: "Top-level behavior", top: "top_tb", sources: [sourceName, testName], language: language)])
        try ProjectStore.save(project, to: root)
        return project
    }

    private static func createBlinky(language: HDLLanguage, name: String, root: URL) throws -> FPGAProject {
        let ext = language == .vhdl ? "vhd" : (language == .systemVerilog ? "sv" : "v")
        let sourceName = "rtl/blinky.\(ext)"
        let testName = "sim/blinky_tb.\(ext)"
        if language == .vhdl {
            try write(vhdlBlinky, to: root.appendingPathComponent(sourceName))
            try write(vhdlBlinkyTest, to: root.appendingPathComponent(testName))
        } else {
            try write(verilogBlinky, to: root.appendingPathComponent(sourceName))
            try write(verilogBlinkyTest, to: root.appendingPathComponent(testName))
        }
        try write(minimalQSF(top: "blinky", output: "LEDG0"), to: root.appendingPathComponent("constraints/c5g.qsf"))
        let project = FPGAProject(name: name, top: "blinky", sources: [
            .init(path: sourceName, language: language),
            .init(path: testName, language: language, isTestbench: true)
        ], tests: [.init(name: "Counter toggles", top: "blinky_tb", sources: [sourceName, testName], language: language)])
        try ProjectStore.save(project, to: root)
        return project
    }

    private static func createRV32I(name: String, root: URL) throws -> FPGAProject {
        try write(rv32Core, to: root.appendingPathComponent("rtl/rv32i_core.sv"))
        try write(rv32Top, to: root.appendingPathComponent("rtl/c5g_top.sv"))
        try write(rv32Test, to: root.appendingPathComponent("sim/rv32i_core_tb.sv"))
        try write("00100093\n00200113\n002081b3\n0000006f\n", to: root.appendingPathComponent("sim/program.hex"))
        try write(rv32QSF, to: root.appendingPathComponent("constraints/c5g.qsf"))
        try write(rv32Guide, to: root.appendingPathComponent("README.md"))
        let project = FPGAProject(name: name, top: "c5g_top", sources: [
            .init(path: "rtl/rv32i_core.sv", language: .systemVerilog),
            .init(path: "rtl/c5g_top.sv", language: .systemVerilog),
            .init(path: "sim/rv32i_core_tb.sv", language: .systemVerilog, isTestbench: true)
        ], tests: [.init(name: "RV32I directed ISA checks", top: "rv32i_core_tb", sources: ["rtl/rv32i_core.sv", "sim/rv32i_core_tb.sv"], language: .systemVerilog)])
        try ProjectStore.save(project, to: root)
        return project
    }

    private static func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private static func minimalQSF(top: String, output: String) -> String {
        """
        set_global_assignment -name FAMILY "Cyclone V"
        set_global_assignment -name DEVICE 5CGXFC5C6F27C7
        set_global_assignment -name TOP_LEVEL_ENTITY \(top)
        set_location_assignment PIN_R20 -to CLOCK_50_B5B
        set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to CLOCK_50_B5B
        set_location_assignment PIN_L7 -to \(output)
        set_instance_assignment -name IO_STANDARD "2.5 V" -to \(output)
        """
    }

    private static let verilogBlinky = """
    // FPGA Studio Blinky — edit this file and run the simulation to experiment.
    module blinky(input wire CLOCK_50_B5B, output wire LEDG0);
      reg [25:0] counter = 0;

      always @(posedge CLOCK_50_B5B) counter <= counter + 1'b1;

      // Try a different counter bit to change the blink rate.
      assign LEDG0 = counter[24];
    endmodule
    """

    private static let verilogBlinkyTest = """
    `timescale 1ns/1ps
    module blinky_tb;
      reg clock = 0; wire led;
      blinky dut(.CLOCK_50_B5B(clock), .LEDG0(led));
      always #10 clock = ~clock;
      initial begin
        $dumpfile("waves.vcd"); $dumpvars(0, blinky_tb);
        #1000 $finish;
      end
    endmodule
    """

    private static let vhdlBlinky = """
    -- FPGA Studio Blinky — edit this file and run the simulation to experiment.
    library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

    entity blinky is
      port (
        CLOCK_50_B5B : in std_logic;
        LEDG0         : out std_logic
      );
    end entity;

    architecture rtl of blinky is
      signal counter : unsigned(25 downto 0) := (others => '0');
    begin
      process(CLOCK_50_B5B)
      begin
        if rising_edge(CLOCK_50_B5B) then
          counter <= counter + 1;
        end if;
      end process;

      -- Try a different counter bit to change the blink rate.
      LEDG0 <= counter(24);
    end architecture;
    """

    private static let vhdlBlinkyTest = """
    library ieee;
    use ieee.std_logic_1164.all;
    entity blinky_tb is end entity;
    architecture sim of blinky_tb is signal clock : std_logic := '0'; signal led : std_logic;
    begin dut: entity work.blinky port map(CLOCK_50_B5B => clock, LEDG0 => led);
    clock <= not clock after 10 ns;
    process begin wait for 1 us; std.env.finish; end process; end architecture;
    """

    private static let rv32Core = """
    module rv32i_core(
      input  logic        clock,
      input  logic        reset_n,
      output logic [31:0] instruction_address,
      input  logic [31:0] instruction_data,
      output logic [31:0] data_address,
      output logic [31:0] data_write,
      output logic [3:0]  data_write_strobe,
      input  logic [31:0] data_read,
      output logic        retired
    );
      // Your processor begins here. Suggested milestones:
      // 1. Program counter and instruction fetch
      // 2. RV32I decoder and immediate generator
      // 3. Register file with x0 hard-wired to zero
      // 4. ALU, branches, loads, stores, and writeback
      // 5. Retire pulse for the directed testbench
      always_ff @(posedge clock) begin
        if (!reset_n) begin
          instruction_address <= 32'h0;
          data_address <= 32'h0;
          data_write <= 32'h0;
          data_write_strobe <= 4'h0;
          retired <= 1'b0;
        end else begin
          retired <= 1'b0;
          // TODO: implement your RV32I machine.
        end
      end
    endmodule
    """

    private static let rv32Top = """
    module c5g_top(input logic CLOCK_50_B5B, input logic CPU_RESET_n, output logic [7:0] LEDG);
      logic [31:0] instruction_address, instruction_data;
      logic [31:0] data_address, data_write, data_read;
      logic [3:0] data_write_strobe;
      logic retired;
      always_comb begin
        case (instruction_address[3:2])
          2'd0: instruction_data = 32'h00100093; // addi x1,x0,1
          2'd1: instruction_data = 32'h00200113; // addi x2,x0,2
          2'd2: instruction_data = 32'h002081b3; // add x3,x1,x2
          default: instruction_data = 32'h0000006f; // jal x0,0
        endcase
      end
      assign data_read = 32'h0;
      assign LEDG = instruction_address[9:2];
      rv32i_core core(.*,.clock(CLOCK_50_B5B),.reset_n(CPU_RESET_n));
    endmodule
    """

    private static let rv32Test = """
    `timescale 1ns/1ps
    module rv32i_core_tb;
      logic clock = 0, reset_n = 0;
      logic [31:0] instruction_address, instruction_data;
      logic [31:0] data_address, data_write, data_read = 0;
      logic [3:0] data_write_strobe; logic retired;
      logic [31:0] rom [0:3]; integer retire_count = 0;
      rv32i_core dut(.*);
      assign instruction_data = rom[instruction_address[3:2]];
      always #10 clock = ~clock;
      always @(posedge clock) if (retired) retire_count <= retire_count + 1;
      initial begin
        $readmemh("program.hex", rom);
        $dumpfile("waves.vcd"); $dumpvars(0, rv32i_core_tb);
        #40 reset_n = 1;
        #2000;
        if (retire_count < 3) $fatal(1, "Implement fetch/decode/execute until three instructions retire");
        $finish;
      end
    endmodule
    """

    private static let rv32QSF = """
    set_global_assignment -name FAMILY "Cyclone V"
    set_global_assignment -name DEVICE 5CGXFC5C6F27C7
    set_global_assignment -name TOP_LEVEL_ENTITY c5g_top
    set_location_assignment PIN_R20 -to CLOCK_50_B5B
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to CLOCK_50_B5B
    set_location_assignment PIN_AB24 -to CPU_RESET_n
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to CPU_RESET_n
    set_location_assignment PIN_L7 -to LEDG[0]
    set_location_assignment PIN_K6 -to LEDG[1]
    set_location_assignment PIN_D8 -to LEDG[2]
    set_location_assignment PIN_E9 -to LEDG[3]
    set_location_assignment PIN_A5 -to LEDG[4]
    set_location_assignment PIN_B6 -to LEDG[5]
    set_location_assignment PIN_H8 -to LEDG[6]
    set_location_assignment PIN_H9 -to LEDG[7]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[0]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[1]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[2]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[3]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[4]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[5]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[6]
    set_instance_assignment -name IO_STANDARD "2.5 V" -to LEDG[7]
    """

    private static let rv32Guide = """
    # RV32I Lab

    This project intentionally contains no finished processor. Implement `rtl/rv32i_core.sv`, then use the directed simulation target to grow the design instruction by instruction.

    The board wrapper uses logic-only instruction ROM and maps the program counter to the C5G green LEDs. Hard RAM, DSP, transceivers, and PLL inference remain disabled by default because the Mistral Cyclone V backend is experimental.
    """
}
