library ieee;
use ieee.std_logic_1164.all;

entity vhdl_smoke is
    port (
        input_signal  : in  std_logic;
        output_signal : out std_logic
    );
end entity;

architecture rtl of vhdl_smoke is
begin
    output_signal <= not input_signal;
end architecture;
