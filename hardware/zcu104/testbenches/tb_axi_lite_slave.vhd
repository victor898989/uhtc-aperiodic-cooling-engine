-- ============================================================================
-- tb_axi_lite_slave.vhd
-- ============================================================================
-- Testbench: AXI4-Lite slave model matching ZCU104 laser controller register map.
--
-- Simulates the AXI4-Lite register space exposed by the UHTC laser controller
-- HLS kernel on the ZCU104 PL.  This allows host-side software validation
-- without hardware.
--
-- Register map (offsets from 0x80000000 base used in zcu104_driver.cpp):
--   0x00 - LASER_POWER_REG   [15:0] power_W, [31:16] reserved
--   0x04 - GALVO_X_REG       [15:0] galvo_x, [31:16] reserved
--   0x08 - GALVO_Y_REG       [15:0] galvo_y, [31:16] reserved
--   0x0C - MOD_FREQ_REG      [15:0] mod_freq, [31:16] mod_phase
--   0x10 - STATUS_REG        [0] emergency_stop, [1] thermal_runaway
--   0x14 - TEMPERATURE_REG   [31:0] temperature_K (IEEE-754 float)
--   0x18 - DT_DT_REG         [31:0] dT_dt (IEEE-754 float)
--   0x1C - TIMESTAMP_REG     [31:0] timestamp_ms
--   0x20 - COMMAND_COUNT_REG [31:0] n_commands_queued
--   0x40 - STREAM_TRIG_REG   write any value to assert stream ready
--
-- References:
--   UG961 - AXI4-Stream Protocol Reference
--   UG1037 - AXI4-Lite Protocol Reference
--   UG1267 - ZCU104 Evaluation Board User Guide
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

entity tb_axi_lite_slave is
end entity tb_axi_lite_slave;

architecture sim of tb_axi_lite_slave is

  constant C_AXI_DATA_WIDTH : integer := 32;
  constant C_AXI_ADDR_WIDTH : integer := 32;
  constant C_SLOT_DEPTH     : integer := 256;  -- 1 KB register file

  -----------------------------------------------------------------------------
  -- AXI4-Lite slave signals (write address channel)
  -----------------------------------------------------------------------------
  signal s_axi_awaddr  : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal s_axi_awprot  : std_logic_vector(2 downto 0) := (others => '0');
  signal s_axi_awvalid : std_logic := '0';
  signal s_axi_awready : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Lite slave signals (write data channel)
  -----------------------------------------------------------------------------
  signal s_axi_wdata  : std_logic_vector(C_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
  signal s_axi_wstrb  : std_logic_vector(C_AXI_DATA_WIDTH/8-1 downto 0) := (others => '0');
  signal s_axi_wvalid : std_logic := '0';
  signal s_axi_wready : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Lite slave signals (write response channel)
  -----------------------------------------------------------------------------
  signal s_axi_bresp  : std_logic_vector(1 downto 0) := "00";
  signal s_axi_bvalid : std_logic := '0';
  signal s_axi_bready : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Lite slave signals (read address channel)
  -----------------------------------------------------------------------------
  signal s_axi_araddr  : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal s_axi_arprot  : std_logic_vector(2 downto 0) := (others => '0');
  signal s_axi_arvalid : std_logic := '0';
  signal s_axi_arready : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Lite slave signals (read data channel)
  -----------------------------------------------------------------------------
  signal s_axi_rdata  : std_logic_vector(C_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
  signal s_axi_rresp  : std_logic_vector(1 downto 0) := "00";
  signal s_axi_rvalid : std_logic := '0';
  signal s_axi_rready : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Stream laser command source (PS -> PL)
  -----------------------------------------------------------------------------
  signal axis_tdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal axis_tkeep   : std_logic_vector(3 downto 0)  := (others => '1');
  signal axis_tlast   : std_logic := '0';
  signal axis_tvalid  : std_logic := '0';
  signal axis_tready  : std_logic := '0';

  -----------------------------------------------------------------------------
  -- Internal register file
  -----------------------------------------------------------------------------
  type reg_array_t is array (0 to C_SLOT_DEPTH-1) of std_logic_vector(C_AXI_DATA_WIDTH-1 downto 0);
  signal regs : reg_array_t := (others => (others => '0'));

  signal emergency_stop : std_logic := '0';
  signal thermal_runaway : std_logic := '0';

begin

  ---------------------------------------------------------------------------
  -- AXI4-Lite slave process
  ---------------------------------------------------------------------------
  axi_lite_slave_proc : process (s_axi_aclk, s_axi_aresetn)
  begin
    if s_axi_aresetn = '0' then
      s_axi_awready <= '0';
      s_axi_wready  <= '0';
      s_axi_bvalid  <= '0';
      s_axi_bresp   <= "00";
      s_axi_arready <= '0';
      s_axi_rvalid  <= '0';
      s_axi_rdata   <= (others => '0');
      s_axi_rresp   <= "00";
      regs <= (others => (others => '0'));
      emergency_stop  <= '0';
      thermal_runaway <= '0';

    elsif rising_edge(s_axi_aclk) then

      -- Default deassert ready
      s_axi_awready <= '0';
      s_axi_wready  <= '0';
      s_axi_arready <= '0';
      s_axi_bvalid  <= '0';
      s_axi_rvalid  <= '0';

      -- ================================================================
      -- Write transaction
      -- ================================================================
      if s_axi_awvalid = '1' and s_axi_wvalid = '1' then
        if s_axi_awready = '0' and s_axi_wready = '0' then
          s_axi_awready <= '1';
          s_axi_wready  <= '1';
        elsif s_axi_awready = '1' and s_axi_wready = '1' then
          -- Accept write
          declare
            addr : integer := to_integer(unsigned(s_axi_awaddr(7 downto 2))) * 4;
          begin
            if addr < C_SLOT_DEPTH * 4 then
              regs(addr/4) <= s_axi_wdata;
            end if;
            -- Trigger stream if writing COMMAND_TRIG_REG
            if std_match(s_axi_awaddr, x"00000040") then
              axis_tvalid <= '1';
            end if;
          end;
          s_axi_awready <= '0';
          s_axi_wready  <= '0';
          s_axi_bvalid  <= '1';
          s_axi_bresp   <= "00"; -- OKAY
        end if;

      -- ================================================================
      -- Read transaction
      -- ================================================================
      elsif s_axi_arvalid = '1' and s_axi_arready = '0' then
        s_axi_arready <= '1';
      elsif s_axi_arvalid = '1' and s_axi_arready = '1' then
        declare
          addr : integer := to_integer(unsigned(s_axi_araddr(7 downto 2))) * 4;
        begin
          if addr < C_SLOT_DEPTH * 4 then
            s_axi_rdata <= regs(addr/4);
          else
            s_axi_rdata <= (others => '0');
          end if;
          -- Inject emergency stop on status register read
          if std_match(s_axi_araddr, x"00000010") then
            s_axi_rdata(0) <= emergency_stop;
            s_axi_rdata(1) <= thermal_runaway;
          end if;
        end;
        s_axi_arready <= '0';
        s_axi_rvalid  <= '1';
        s_axi_rresp   <= "00"; -- OKAY
      end if;

      -- Accept write response
      if s_axi_bvalid = '1' and s_axi_bready = '1' then
        s_axi_bvalid <= '0';
      end if;

      -- Accept read response
      if s_axi_rvalid = '1' and s_axi_rready = '1' then
        s_axi_rvalid <= '0';
      end if;

    end if;
  end process axi_lite_slave_proc;

  ---------------------------------------------------------------------------
  -- AXI4-Stream source process (laser commands)
  ---------------------------------------------------------------------------
  axis_source_proc : process
    variable v : real;
  begin
    wait until rising_edge(s_axi_aclk);
    if axis_tvalid = '1' and axis_tready = '1' then
      uniform(v, 0.0, 1.0);
      if v > 0.95 then
        axis_tlast <= '1';
      else
        axis_tlast <= '0';
      end if;
    end if;
  end process axis_source_proc;

  ---------------------------------------------------------------------------
  -- Clock and reset generation
  ---------------------------------------------------------------------------
  s_axi_aclk    <= not s_axi_aclk    after 5 ns;  -- 100 MHz clock
  s_axi_aresetn <= '0', '1' after 100 ns;

end architecture sim;
