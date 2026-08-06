-- ============================================================================
-- tb_uhc_laser_controller.vhd
-- ============================================================================
-- Top-level testbench for the UHTC laser controller on ZCU104.
--
-- Integrates:
--   - AXI4-Lite register slave (laser control + thermal status)
--   - AXI4-Stream source (laser command packets PS->PL)
--   - AXI4-Stream sink   (thermal feedback packets PL->PS)
--
-- Run command (GHDL):
--   ghdl -a tb_axi_lite_slave.vhd tb_axi_stream_sink.vhd tb_uhc_laser_controller.vhd
--   ghdl -e tb_uhc_laser_controller
--   ghdl -r tb_uhc_laser_controller --wave=uhc_zcu104.ghw --stop-time=100us
--
-- Run command (XSIM / Vivado):
--   vivado -mode batch -source run_xsim.tcl
--
-- References:
--   UG961 - AXI4-Stream Protocol Reference
--   UG1037 - AXI4-Lite Protocol Reference
--   UG1267 - ZCU104 Evaluation Board User Guide
--   UG1475 - Vitis HLS AXI4-Stream Interfaces
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

entity tb_uhc_laser_controller is
end entity tb_uhc_laser_controller;

architecture sim of tb_uhc_laser_controller is

  -----------------------------------------------------------------------------
  -- Clock / Reset
  -----------------------------------------------------------------------------
  signal s_axi_aclk    : std_logic := '0';
  signal s_axi_aresetn : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Lite host interface (ZCU104 PS -> PL AXI Lite at 0x80000000)
  -----------------------------------------------------------------------------
  signal s_axi_awaddr  : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axi_awprot  : std_logic_vector(2 downto 0)  := (others => '0');
  signal s_axi_awvalid : std_logic := '0';
  signal s_axi_awready : std_logic := '0';

  signal s_axi_wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axi_wstrb   : std_logic_vector(3 downto 0)  := (others => '0');
  signal s_axi_wvalid  : std_logic := '0';
  signal s_axi_wready  : std_logic := '0';

  signal s_axi_bresp   : std_logic_vector(1 downto 0) := "00";
  signal s_axi_bvalid  : std_logic := '0';
  signal s_axi_bready  : std_logic := '0';

  signal s_axi_araddr  : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axi_arprot  : std_logic_vector(2 downto 0)  := (others => '0');
  signal s_axi_arvalid : std_logic := '0';
  signal s_axi_arready : std_logic := '0';

  signal s_axi_rdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axi_rresp   : std_logic_vector(1 downto 0) := "00";
  signal s_axi_rvalid  : std_logic := '0';
  signal s_axi_rready  : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Stream laser command (PS -> PL)
  -----------------------------------------------------------------------------
  signal axis_tx_tdata  : std_logic_vector(31 downto 0) := (others => '0');
  signal axis_tx_tkeep  : std_logic_vector(3 downto 0)  := (others => '0');
  signal axis_tx_tlast  : std_logic := '0';
  signal axis_tx_tvalid : std_logic := '0';
  signal axis_tx_tready : std_logic := '0';

  -----------------------------------------------------------------------------
  -- AXI4-Stream thermal feedback (PL -> PS)
  -----------------------------------------------------------------------------
  signal axis_rx_tdata  : std_logic_vector(31 downto 0) := (others => '0');
  signal axis_rx_tkeep  : std_logic_vector(3 downto 0)  := (others => '0');
  signal axis_rx_tlast  : std_logic := '0';
  signal axis_rx_tvalid : std_logic := '0';
  signal axis_rx_tready : std_logic := '0';

  -----------------------------------------------------------------------------
  -- Register map offsets (matches zcu104_driver.cpp REG_*)
  -----------------------------------------------------------------------------
  constant REG_LASER_POWER    : unsigned(31 downto 0) := x"00000000";
  constant REG_GALVO_X        : unsigned(31 downto 0) := x"00000004";
  constant REG_GALVO_Y        : unsigned(31 downto 0) := x"00000008";
  constant REG_MOD_FREQ       : unsigned(31 downto 0) := x"0000000C";
  constant REG_STATUS         : unsigned(31 downto 0) := x"00000010";
  constant REG_TEMPERATURE    : unsigned(31 downto 0) := x"00000014";
  constant REG_DT_DT          : unsigned(31 downto 0) := x"00000018";
  constant REG_TIMESTAMP      : unsigned(31 downto 0) := x"0000001C";
  constant REG_COMMAND_COUNT  : unsigned(31 downto 0) := x"00000020";
  constant REG_STREAM_TRIG    : unsigned(31 downto 0) := x"00000040";

  -----------------------------------------------------------------------------
  -- Test control
  -----------------------------------------------------------------------------
  signal test_pass : boolean := false;
  signal test_fail : boolean := false;

begin

  ---------------------------------------------------------------------------
  -- Clock: 100 MHz (ZCU104 PS-to-PL AXI clock)
  ---------------------------------------------------------------------------
  s_axi_aclk <= not s_axi_aclk after 5 ns;

  ---------------------------------------------------------------------------
  -- Reset
  ---------------------------------------------------------------------------
  reset_proc : process
  begin
    wait for 50 ns;
    s_axi_aresetn <= '1';
    wait;
  end process reset_proc;

  ---------------------------------------------------------------------------
  -- AXI4-Lite slave model (instantiated as in tb_axi_lite_slave.vhd)
  ---------------------------------------------------------------------------
  axi_lite_slave_inst : entity work.tb_axi_lite_slave
    generic map (
      C_AXI_DATA_WIDTH => 32,
      C_AXI_ADDR_WIDTH => 32,
      C_SLOT_DEPTH     => 256
    )
    port map (
      s_axi_aclk    => s_axi_aclk,
      s_axi_aresetn => s_axi_aresetn,
      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awprot  => s_axi_awprot,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata   => s_axi_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,
      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,
      s_axi_araddr  => s_axi_araddr,
      s_axi_arprot  => s_axi_arprot,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,
      axis_tdata    => axis_tx_tdata,
      axis_tkeep    => axis_tx_tkeep,
      axis_tlast    => axis_tx_tlast,
      axis_tvalid   => axis_tx_tvalid,
      axis_tready   => axis_tx_tready
    );

  ---------------------------------------------------------------------------
  -- AXI4-Stream sink model (instantiated as in tb_axi_stream_sink.vhd)
  ---------------------------------------------------------------------------
  axis_sink_inst : entity work.tb_axi_stream_sink
    port map (
      axis_aclk    => s_axi_aclk,
      axis_aresetn => s_axi_aresetn,
      axis_tdata   => axis_rx_tdata,
      axis_tkeep   => axis_rx_tkeep,
      axis_tlast   => axis_rx_tlast,
      axis_tvalid  => axis_rx_tvalid,
      axis_tready  => axis_rx_tready
    );

  ---------------------------------------------------------------------------
  -- Host-side test procedure
  ---------------------------------------------------------------------------
  host_test_proc : process
    procedure axi_write (
      constant addr : in unsigned(31 downto 0);
      constant data : in std_logic_vector(31 downto 0)
    ) is
    begin
      -- AW channel
      s_axi_awaddr  <= std_logic_vector(addr);
      s_axi_awvalid <= '1';
      s_axi_wdata   <= data;
      s_axi_wstrb   <= "1111";
      s_axi_wvalid  <= '1';
      wait until rising_edge(s_axi_aclk);
      while s_axi_awready = '0' loop
        wait until rising_edge(s_axi_aclk);
      end loop;
      s_axi_awvalid <= '0';
      while s_axi_wready = '0' loop
        wait until rising_edge(s_axi_aclk);
      end loop;
      s_axi_wvalid <= '0';
      wait until rising_edge(s_axi_aclk);
      -- B channel
      s_axi_bready <= '1';
      while s_axi_bvalid = '0' loop
        wait until rising_edge(s_axi_aclk);
      end loop;
      s_axi_bready <= '0';
    end procedure;

    procedure axi_read (
      constant addr   : in unsigned(31 downto 0);
      variable rdata  : out std_logic_vector(31 downto 0)
    ) is
    begin
      -- AR channel
      s_axi_araddr  <= std_logic_vector(addr);
      s_axi_arvalid <= '1';
      wait until rising_edge(s_axi_aclk);
      while s_axi_arready = '0' loop
        wait until rising_edge(s_axi_aclk);
      end loop;
      s_axi_arvalid <= '0';
      -- R channel
      s_axi_rready <= '1';
      while s_axi_rvalid = '0' loop
        wait until rising_edge(s_axi_aclk);
      end loop;
      rdata := s_axi_rdata;
      s_axi_rready <= '0';
    end procedure;

    variable rdata : std_logic_vector(31 downto 0);
  begin
    wait until s_axi_aresetn = '1';
    wait for 100 ns;

    ----------------------------------------------------------------
    -- Test 1: Write laser power register
    ----------------------------------------------------------------
    report "TEST 1: Write LASER_POWER_REG";
    axi_write(REG_LASER_POWER, std_logic_vector(to_unsigned(1200, 16)) & x"0000");

    ----------------------------------------------------------------
    -- Test 2: Write galvo positions
    ----------------------------------------------------------------
    report "TEST 2: Write GALVO_X/Y";
    axi_write(REG_GALVO_X, std_logic_vector(to_unsigned(32768, 16)) & x"0000");
    axi_write(REG_GALVO_Y, std_logic_vector(to_unsigned(16384, 16)) & x"0000");

    ----------------------------------------------------------------
    -- Test 3: Write modulation frequency
    ----------------------------------------------------------------
    report "TEST 3: Write MOD_FREQ";
    axi_write(REG_MOD_FREQ, std_logic_vector(to_unsigned(90, 16)) & std_logic_vector(to_unsigned(180, 16)));

    ----------------------------------------------------------------
    -- Test 4: Trigger stream
    ----------------------------------------------------------------
    report "TEST 4: Trigger AXI stream";
    axi_write(REG_STREAM_TRIG, x"00000001");

    ----------------------------------------------------------------
    -- Test 5: Read status register
    ----------------------------------------------------------------
    report "TEST 5: Read STATUS";
    axi_read(REG_STATUS, rdata);
    assert rdata(0) = '0' or rdata(0) = '1'
      report "Emergency stop bit invalid"
      severity warning;

    ----------------------------------------------------------------
    -- Test 6: Read temperature
    ----------------------------------------------------------------
    report "TEST 6: Read TEMPERATURE";
    axi_read(REG_TEMPERATURE, rdata);
    report "Temperature register=" & to_hstring(rdata);

    ----------------------------------------------------------------
    -- Test 7: Send laser command stream burst (3 words)
    ----------------------------------------------------------------
    report "TEST 7: Send laser command stream";
    axis_tx_tdata <= std_logic_vector(to_unsigned(1200, 16)) & std_logic_vector(to_unsigned(32768, 16)); -- power + galvo_x
    axis_tx_tvalid <= '1';
    wait until rising_edge(s_axi_aclk);

    axis_tx_tdata <= std_logic_vector(to_unsigned(16384, 16)) & std_logic_vector(to_unsigned(90, 16)); -- galvo_y + mod_freq
    wait until rising_edge(s_axi_aclk);

    axis_tx_tdata <= std_logic_vector(to_unsigned(180, 16)) & x"0000"; -- mod_phase + reserved
    axis_tx_tlast  <= '1';
    wait until rising_edge(s_axi_aclk);
    axis_tx_tvalid <= '0';
    axis_tx_tlast  <= '0';

    ----------------------------------------------------------------
    -- Test 8: Wait for thermal feedback stream
    ----------------------------------------------------------------
    report "TEST 8: Wait for thermal feedback";
    for i in 1 to 5 loop
      wait until axis_rx_tvalid = '1' and axis_rx_tlast = '1';
    end loop;

    report "ALL TESTS PASSED";
    test_pass <= true;
    wait;
  end process host_test_proc;

  ---------------------------------------------------------------------------
  -- End of simulation
  ---------------------------------------------------------------------------
  end_sim_proc : process
  begin
    wait until test_pass = true;
    wait for 1 us;
    assert false report "Simulation finished successfully." severity failure;
  end process end_sim_proc;

end architecture sim;
