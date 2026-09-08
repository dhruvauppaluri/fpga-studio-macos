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

    public static let recommendedForBeginners: ProjectTemplate = .blinky

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .blank: "Blank Design"
        case .blinky: "C5G Blinky"
        }
    }
    public var summary: String {
        switch self {
        case .blank: "A minimal synthesizable top level and testbench."
        case .blinky: "A safe 50 MHz counter driving the first green LED."
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

}
