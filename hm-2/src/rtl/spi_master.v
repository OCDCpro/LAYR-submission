// ----------------------------------------------------------------------------
// SPI Master - Full-duplex byte transceiver (Mode 0: CPOL=0, CPHA=0)
// ADAPTED from the user's proven working ESP32-FPGA SPI master.
//
// Changes from original:
//   - CLK_DIV parameterized (default 100 → 1 MHz SPI from 100 MHz sysclk)
//   - Identical state machine, timing, and interface
//
// Interface:
//   tx_data  : byte to transmit (latched on tx_start)
//   rx_data  : byte received (valid when done pulses)
//   tx_start : pulse high for 1 cycle to begin
//   busy     : high while a byte is being clocked
//   done     : pulses high for 1 cycle when byte is complete
// ----------------------------------------------------------------------------
module spi_master #(
    parameter CLK_DIV = 100          // SPI period = CLK_DIV system clocks
)(
    input  wire       clk,
    input  wire       rst,           // synchronous active-HIGH reset
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    input  wire       miso,
    output reg  [7:0] rx_data,
    output reg        busy,
    output reg        done,
    output reg        mosi,
    output reg        sclk
);

    localparam HALF = CLK_DIV / 2;

    localparam S_IDLE = 2'd0;
    localparam S_LOW  = 2'd1;
    localparam S_HIGH = 2'd2;
    localparam S_DONE = 2'd3;

    reg [1:0]  state;
    reg [2:0]  bit_cnt;
    reg [7:0]  shift_tx;
    reg [7:0]  shift_rx;
    reg [15:0] clk_cnt;

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            sclk     <= 1'b0;
            mosi     <= 1'b0;
            busy     <= 1'b0;
            done     <= 1'b0;
            shift_tx <= 8'd0;
            shift_rx <= 8'd0;
            rx_data  <= 8'd0;
            bit_cnt  <= 3'd0;
            clk_cnt  <= 16'd0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (tx_start && !busy) begin
                        busy     <= 1'b1;
                        shift_tx <= tx_data;
                        shift_rx <= 8'd0;
                        bit_cnt  <= 3'd0;
                        mosi     <= tx_data[7];
                        clk_cnt  <= 16'd0;
                        state    <= S_LOW;
                    end
                end

                S_LOW: begin
                    if (clk_cnt == HALF - 1) begin
                        clk_cnt  <= 16'd0;
                        sclk     <= 1'b1;
                        shift_rx <= {shift_rx[6:0], miso};
                        state    <= S_HIGH;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_HIGH: begin
                    if (clk_cnt == HALF - 1) begin
                        clk_cnt <= 16'd0;
                        sclk    <= 1'b0;
                        if (bit_cnt == 3'd7) begin
                            state <= S_DONE;
                        end else begin
                            bit_cnt  <= bit_cnt + 1'b1;
                            shift_tx <= {shift_tx[6:0], 1'b0};
                            mosi     <= shift_tx[6];
                            state    <= S_LOW;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_DONE: begin
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    mosi    <= 1'b0;
                    rx_data <= shift_rx;
                    state   <= S_IDLE;
                end
            endcase
        end
    end

endmodule
