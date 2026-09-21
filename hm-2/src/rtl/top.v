
module hmteam2 (
`ifdef USE_POWER_PINS
    inout wire IOVDD,
    inout wire IOVSS,
    inout wire VDD,
    inout wire VSS,
`endif
    inout sys_clk_PAD,
    inout rst_in_PAD,
    output wire spi_sclk_PAD,
    output wire spi_mosi_PAD,
    inout spi_miso_PAD,
    output wire rfid_ss_n_PAD,
    output wire eeprom_ss_n_PAD,
    output wire s_unlock_PAD,
    output wire s_fault_PAD,
    output wire s_busy_PAD,
    output wire user_io_0_PAD,
    output wire user_io_1_PAD,
    output wire user_io_2_PAD,
    output wire user_io_3_PAD,
    output wire user_io_4_PAD,
    inout uart_tx_PAD,
    inout uart_rx_PAD,
    inout uart_clk_PAD
);

    // Internal nets (SystemVerilog `logic` used in original)
    logic sys_clk;
    logic rst_in;
    logic spi_sclk;
    logic spi_mosi;
    logic spi_miso;
    logic rfid_ss_n;
    logic eeprom_ss_n;
    logic s_unlock;
    logic s_fault;
    logic s_busy;
    logic user_io_0;
    logic user_io_1;
    logic user_io_2;
    logic user_io_3;
    logic user_io_4;

    // IOVDD / IOVSS pads (kept as in original)
    generate
        for (genvar i = 0; i < 1; i++) begin : iovdd_pads
            (* keep *)
            sg13g2_IOPadIOVdd iovdd_pad (
`ifdef USE_POWER_PINS
                .iovdd(IOVDD),
                .iovss(IOVSS),
                .vdd  (VDD),
                .vss  (VSS)
`endif
            );
        end
    endgenerate

    generate
        for (genvar i = 0; i < 1; i++) begin : iovss_pads
            (* keep *)
            sg13g2_IOPadIOVss iovss_pad (
`ifdef USE_POWER_PINS
                .iovdd(IOVDD),
                .iovss(IOVSS),
                .vdd  (VDD),
                .vss  (VSS)
`endif
            );
        end
    endgenerate

    generate
        for (genvar i = 0; i < 2; i++) begin : vdd_pads
            (* keep *)
            sg13g2_IOPadVdd vdd_pad (
`ifdef USE_POWER_PINS
                .iovdd(IOVDD),
                .iovss(IOVSS),
                .vdd  (VDD),
                .vss  (VSS)
`endif
            );
        end
    endgenerate

    generate
        for (genvar i = 0; i < 2; i++) begin : vss_pads
            (* keep *)
            sg13g2_IOPadVss vss_pad (
`ifdef USE_POWER_PINS
                .iovdd(IOVDD),
                .iovss(IOVSS),
                .vdd  (VDD),
                .vss  (VSS)
`endif
            );
        end
    endgenerate

    // Clock PAD instance (input)
    sg13g2_IOPadIn clk_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .p2c  (sys_clk),
        .pad  (sys_clk_PAD)
    );

    // Reset PAD instance (input)
    sg13g2_IOPadIn rst_in_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .p2c  (rst_in),
        .pad  (rst_in_PAD)
    );

    // SPI SCLK PAD instance (output)
    sg13g2_IOPadOut30mA spi_sclk_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (spi_sclk),
        .pad  (spi_sclk_PAD)
    );

    // SPI MOSI PAD instance (output)
    sg13g2_IOPadOut30mA spi_mosi_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (spi_mosi),
        .pad  (spi_mosi_PAD)
    );

    // SPI MISO PAD instance (input)
    sg13g2_IOPadIn spi_miso_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .p2c  (spi_miso),
        .pad  (spi_miso_PAD)
    );

    // RFID (RC) CS PAD (output)
    sg13g2_IOPadOut30mA spi_rfid_ss_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (rfid_ss_n),
        .pad  (rfid_ss_n_PAD)
    );

    // EEPROM CS PAD (output)
    sg13g2_IOPadOut30mA spi_eeprom_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (eeprom_ss_n),
        .pad  (eeprom_ss_n_PAD)
    );

    // Unlock status PAD (output)
    sg13g2_IOPadOut30mA unlock_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (s_unlock),
        .pad  (s_unlock_PAD)
    );

    // Fault status PAD (output)
    sg13g2_IOPadOut30mA fault_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (s_fault),
        .pad  (s_fault_PAD)
    );

    // Busy status PAD (output)
    sg13g2_IOPadOut30mA busy_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (s_busy),
        .pad  (s_busy_PAD)
    );

    // User IO PADs (outputs)
    sg13g2_IOPadOut30mA user_io_0_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (user_io_0),
        .pad  (user_io_0_PAD)
    );
    sg13g2_IOPadOut30mA user_io_1_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (user_io_1),
        .pad  (user_io_1_PAD)
    );
    sg13g2_IOPadOut30mA user_io_2_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (user_io_2),
        .pad  (user_io_2_PAD)
    );
    sg13g2_IOPadOut30mA user_io_3_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (user_io_3),
        .pad  (user_io_3_PAD)
    );
    sg13g2_IOPadOut30mA user_io_4_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (user_io_4),
        .pad  (user_io_4_PAD)
    );

    // UART pads (floating - not yet implemented)
    sg13g2_IOPadOut30mA uart_tx_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (1'b0),
        .pad  (uart_tx_PAD)
    );

    sg13g2_IOPadOut30mA uart_rx_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (1'b0),
        .pad  (uart_rx_PAD)
    );

    sg13g2_IOPadOut30mA uart_clk_pad (
`ifdef USE_POWER_PINS
        .iovdd(IOVDD),
        .iovss(IOVSS),
        .vdd  (VDD),
        .vss  (VSS),
`endif
        .c2p  (1'b0),
        .pad  (uart_clk_PAD)
    );

    // Instantiate top-level chip and connect internal nets with correct port names
    chip chip_inst (
        .rst            (rst_in),
        .sys_clk        (sys_clk),
        .user_io_0      (user_io_0),
        .user_io_1      (user_io_1),
        .user_io_2      (user_io_2),
        .user_io_3      (user_io_3),
        .user_io_4      (user_io_4),
        .cs_1           (rfid_ss_n),
        .cs_2           (eeprom_ss_n),
        .spi_miso       (spi_miso),
        .spi_mosi       (spi_mosi),
        .spi_sclk       (spi_sclk),
        .status_unlock  (s_unlock),
        .status_fault   (s_fault),
        .status_busy    (s_busy)
    );

endmodule
