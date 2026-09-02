module top_tb;
    reg clock = 1'b0;
    wire led;

    top dut(.CLOCK_50_B5B(clock), .LEDG0(led));

    initial begin
        #1 clock = 1'b1;
        #1;
        if (led !== 1'b1) $fatal(1, "simulation mismatch");
        $display("iverilog-smoke-ok");
        $finish;
    end
endmodule
