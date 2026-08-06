-- ============================================================================
-- tb_axi_stream_sink.vhd
-- ============================================================================
-- Testbench: AXI4-Stream sink model for ZCU104 thermal feedback path.
--
-- The UHTC laser controller HLS kernel produces thermal readings on an
-- AXI4-Stream interface (PL -> PS).  This testbench models that stream sink
-- and verifies packet framing, TLAST assertion, and data integrity.
--
-- Stream packet format (AXI4-Stream 32-bit words):
--   Word 0: [31:0]  temperature_K (IEEE-754 float)
--   Word 1: [31:0]  dT_dt (IEEE-754 float)
--   Word 2: [31:1]  reserved, [0] emergency_stop
--   Word 3: [31:0]  timestamp_ms
--   Word 4: [31:0]  n_samples
--   TLAST asserted on last word.
--
-- References:
--   UG961 - AXI4-Stream Protocol Reference
--   UG1267 - ZCU104 Evaluation Board User Guide
-- ============================================================================

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

entity tb_axi_stream_sink is
end entity tb_axi_stream_sink;

architecture sim of tb_axi_stream_sink is

  constant C_AXIS_DATA_WIDTH : integer := 32;
  constant C_AXIS_KEEP_WIDTH  : integer := 4;
  constant C_PACKET_WORDS    : integer := 5;

  -----------------------------------------------------------------------------
  -- AXI4-Stream sink interface (DUT)
  -----------------------------------------------------------------------------
  signal axis_aclk    : std_logic := '0';
  signal axis_aresetn : std_logic := '0';
  signal axis_tdata   : std_logic_vector(C_AXIS_DATA_WIDTH-1 downto 0) := (others => '0');
  signal axis_tkeep   : std_logic_vector(C_AXIS_KEEP_WIDTH-1 downto 0)  := (others => '0');
  signal axis_tlast   : std_logic := '0';
  signal axis_tvalid  : std_logic := '0';
  signal axis_tready  : std_logic := '1';  -- sink always ready for simplicity

  -----------------------------------------------------------------------------
  -- Scoreboard
  -----------------------------------------------------------------------------
  type packet_t is record
    temperature_K : real;
    dT_dt         : real;
    emergency_stop : std_logic;
    timestamp_ms  : unsigned(31 downto 0);
    n_samples     : unsigned(31 downto 0);
  end record;

  signal received_packets : integer := 0;
  signal error_count      : integer := 0;
  signal sim_done         : boolean := false;

begin

  ---------------------------------------------------------------------------
  -- Clock generation: 100 MHz (ZCU104 PL typical clock)
  ---------------------------------------------------------------------------
  axis_aclk <= not axis_aclk after 5 ns;

  ---------------------------------------------------------------------------
  -- Reset sequence
  ---------------------------------------------------------------------------
  reset_proc : process
  begin
    wait for 100 ns;
    axis_aresetn <= '1';
    wait;
  end process reset_proc;

  ---------------------------------------------------------------------------
  -- AXI4-Stream sink model
  ---------------------------------------------------------------------------
  stream_sink_proc : process (axis_aclk)
    variable pkt      : packet_t;
    variable word_cnt : integer range 0 to C_PACKET_WORDS-1;
    variable data_i   : unsigned(31 downto 0);
  begin
    if rising_edge(axis_aclk) then
      if axis_aresetn = '0' then
        word_cnt := 0;
        received_packets <= 0;
        error_count      <= 0;
      elsif axis_tvalid = '1' and axis_tready = '1' then
        data_i := unsigned(axis_tdata);

        case word_cnt is
          when 0 =>
            -- Word 0: temperature_K (IEEE-754 float)
            pkt.temperature_K := ieee.float_ieee.to_real(to_float(data_i, 8, 23));
          when 1 =>
            -- Word 1: dT_dt (IEEE-754 float)
            pkt.dT_dt := ieee.float_ieee.to_real(to_float(data_i, 8, 23));
          when 2 =>
            -- Word 2: reserved + emergency_stop in bit 0
            pkt.emergency_stop := axis_tdata(0);
          when 3 =>
            -- Word 3: timestamp_ms
            pkt.timestamp_ms := data_i;
          when 4 =>
            -- Word 4: n_samples, TLAST asserted
            pkt.n_samples := data_i;
            if axis_tlast = '1' then
              -- Packet complete
              report "Packet received: T=" & real'image(pkt.temperature_K) &
                     " dT/dt=" & real'image(pkt.dT_dt) &
                     " e_stop=" & std_logic'image(pkt.emergency_stop) &
                     " ts=" & integer'image(to_integer(pkt.timestamp_ms));
              received_packets <= received_packets + 1;
              if pkt.temperature_K < 300.0 or pkt.temperature_K > 4000.0 then
                report "ERROR: temperature out of range" severity warning;
                error_count <= error_count + 1;
              end if;
            else
              report "ERROR: TLAST not asserted on last word" severity warning;
              error_count <= error_count + 1;
            end if;
          when others => null;
        end case;

        word_cnt := (word_cnt + 1) mod C_PACKET_WORDS;
      end if;
    end if;
  end process stream_sink_proc;

  ---------------------------------------------------------------------------
  -- Stimulus: drive a synthetic thermal packet every 1 us
  ---------------------------------------------------------------------------
  stimulus_proc : process
    variable temp_word  : unsigned(31 downto 0);
    variable dtdt_word  : unsigned(31 downto 0);
    variable ts_word    : unsigned(31 downto 0);
    variable n_word     : unsigned(31 downto 0);
  begin
    wait until axis_aresetn = '1';
    wait for 1 us;

    while not sim_done loop
      -- Build packet words
      temp_word := to_unsigned(ieee.float_ieee.to_single(1200.5), 32);
      dtdt_word := to_unsigned(ieee.float_ieee.to_single(50.0), 32);
      ts_word   := to_unsigned(123456, 32);
      n_word    := to_unsigned(1024, 32);

      -- Drive Word 0
      axis_tdata <= std_logic_vector(temp_word);
      axis_tvalid <= '1';
      wait until rising_edge(axis_aclk);

      -- Drive Word 1
      axis_tdata <= std_logic_vector(dtdt_word);
      wait until rising_edge(axis_aclk);

      -- Drive Word 2
      axis_tdata <= std_logic_vector(x"00000001");  -- emergency_stop=1
      wait until rising_edge(axis_aclk);

      -- Drive Word 3
      axis_tdata <= std_logic_vector(ts_word);
      wait until rising_edge(axis_aclk);

      -- Drive Word 4 with TLAST
      axis_tdata <= std_logic_vector(n_word);
      axis_tlast <= '1';
      wait until rising_edge(axis_aclk);
      axis_tlast <= '0';
      axis_tvalid <= '0';

      wait for 9 us;  -- 10 us period
    end loop;

    wait;
  end process stimulus_proc;

  ---------------------------------------------------------------------------
  -- End of simulation
  ---------------------------------------------------------------------------
  end_sim_proc : process
  begin
    wait until received_packets = 5;
    report "Simulation complete. Packets=" & integer'image(received_packets) &
           " Errors=" & integer'image(error_count);
    assert error_count = 0
      report "TEST FAILED"
      severity failure;
    report "TEST PASSED";
    sim_done <= true;
    wait;
  end process end_sim_proc;

end architecture sim;
