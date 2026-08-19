// SPDX-FileCopyrightText: © 2025 LibreLane Template Contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module hsrmteam3 #(
    // Power/ground pads for core
    parameter NUM_VDD_PADS = 1,
    parameter NUM_VSS_PADS = 1,
    
    // Power/ground pads for I/O
    parameter NUM_IOVDD_PADS = 1,
    parameter NUM_IOVSS_PADS = 1,
    
    // Signal pads
    parameter NUM_INPUT_PADS  = 8,
    parameter NUM_OUTPUT_PADS = 10
    )(
    `ifdef USE_POWER_PINS
    inout wire IOVDD,
    inout wire IOVSS,
    inout wire VDD,
    inout wire VSS,
    `endif
    inout  wire clk_PAD,
    inout  wire rst_n_PAD,
    inout  wire [NUM_INPUT_PADS-1 :0] input_PAD,
    inout  wire [NUM_OUTPUT_PADS-1:0] output_PAD
);

    wire clk_PAD2CORE;
    wire rst_n_PAD2CORE;
    wire [NUM_INPUT_PADS-1 :0] input_PAD2CORE;
    wire [NUM_OUTPUT_PADS-1:0] output_CORE2PAD;

    localparam int AES_INPUTS_USED  = 2;
    // 4 outputs used: lock_state, o_SPI_Clk, o_SPI_MOSI, o_SPI_CS_n
    // Was 3, which caused MULTIDRIVEN on output_CORE2PAD[3] (o_SPI_CS_n)
    localparam int AES_OUTPUTS_USED = 4;

    // Power/ground pad instances
    generate
    for (genvar i=0; i<NUM_IOVDD_PADS; i++) begin : iovdd_pads
        (* keep *)
        sg13g2_IOPadIOVdd iovdd_pad  (
            `ifdef USE_POWER_PINS
            .iovdd  (IOVDD),
            .iovss  (IOVSS),
            .vdd    (VDD),
            .vss    (VSS)
            `endif
        );
    end
    for (genvar i=0; i<NUM_IOVSS_PADS; i++) begin : iovss_pads
        (* keep *)
        sg13g2_IOPadIOVss iovss_pad  (
            `ifdef USE_POWER_PINS
            .iovdd  (IOVDD),
            .iovss  (IOVSS),
            .vdd    (VDD),
            .vss    (VSS)
            `endif
        );
    end
    for (genvar i=0; i<NUM_VDD_PADS; i++) begin : vdd_pads
        (* keep *)
        sg13g2_IOPadVdd vdd_pad  (
            `ifdef USE_POWER_PINS
            .iovdd  (IOVDD),
            .iovss  (IOVSS),
            .vdd    (VDD),
            .vss    (VSS)
            `endif
        );
    end
    for (genvar i=0; i<NUM_VSS_PADS; i++) begin : vss_pads
        (* keep *)
        sg13g2_IOPadVss vss_pad  (
            `ifdef USE_POWER_PINS
            .iovdd  (IOVDD),
            .iovss  (IOVSS),
            .vdd    (VDD),
            .vss    (VSS)
            `endif
        );
    end
    endgenerate

    // Signal IO pad instances

    // Schmitt trigger
    sg13g2_IOPadIn clk_pad (
        `ifdef USE_POWER_PINS
        .iovdd  (IOVDD),
        .iovss  (IOVSS),
        .vdd    (VDD),
        .vss    (VSS),
        `endif
        .p2c    (clk_PAD2CORE),
        .pad    (clk_PAD)
    );
    
    // Normal input
    sg13g2_IOPadIn rst_n_pad (
        `ifdef USE_POWER_PINS
        .iovdd  (IOVDD),
        .iovss  (IOVSS),
        .vdd    (VDD),
        .vss    (VSS),
        `endif
        .p2c    (rst_n_PAD2CORE),
        .pad    (rst_n_PAD)
    );

    generate
    for (genvar i=0; i<NUM_INPUT_PADS; i++) begin : inputs
        sg13g2_IOPadIn input_pad (
            `ifdef USE_POWER_PINS
            .iovdd  (IOVDD),
            .iovss  (IOVSS),
            .vdd    (VDD),
            .vss    (VSS),
            `endif
            .p2c    (input_PAD2CORE[i]),
            .pad    (input_PAD[i])
        );
    end
    endgenerate

    generate
    for (genvar i=0; i<NUM_OUTPUT_PADS; i++) begin : outputs
        sg13g2_IOPadOut30mA output_pad (
            `ifdef USE_POWER_PINS
            .iovdd  (IOVDD),
            .iovss  (IOVSS),
            .vdd    (VDD),
            .vss    (VSS),
            `endif
            .c2p    (output_CORE2PAD[i]),
            .pad    (output_PAD[i])
        );
    end
    endgenerate

    generate
    if (NUM_OUTPUT_PADS > AES_OUTPUTS_USED) begin : tieoff_unused_outputs
        assign output_CORE2PAD[NUM_OUTPUT_PADS-1:AES_OUTPUTS_USED] = '0;
    end
    endgenerate

    generate
    if (NUM_INPUT_PADS > AES_INPUTS_USED) begin : mark_unused_inputs
        (* keep *)
        wire unused_input_bits_seen;
        assign unused_input_bits_seen = |input_PAD2CORE[NUM_INPUT_PADS-1:AES_INPUTS_USED];
    end
    endgenerate


    // Core design
    (* keep *)
    cmac_handshake CMAC_DEA(
        .clk        (clk_PAD2CORE),
        .rst        (rst_n_PAD2CORE),
        .in         (input_PAD2CORE[0]),
        .i_SPI_MISO (input_PAD2CORE[1]),
        .lock_state (output_CORE2PAD[0]),
        .o_SPI_Clk  (output_CORE2PAD[1]),
        .o_SPI_MOSI (output_CORE2PAD[2]),
        .o_SPI_CS_n (output_CORE2PAD[3])
    );

endmodule

`default_nettype wire

