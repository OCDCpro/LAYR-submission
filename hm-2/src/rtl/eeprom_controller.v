// ============================================================================
// EEPROM Controller — extracted from LAYR Guardian top-level
//
// Handshake interface for external state machine:
//   eeprom_cache_start / eeprom_cache_done — read 32 bytes from addr 0x00
//   eeprom_id_data [127:0]                 — 16-byte stored ID  (bytes 0-15)
//   eeprom_key_data [127:0]                — 16-byte AES PSK    (bytes 16-31)
//
// Reads 32 bytes from SPI EEPROM starting at address 0x00 using the
// standard 0x03 (READ) command.
// ============================================================================
module eeprom_controller (
    input  wire        clk,
    input  wire        rst,

    // --- Cache handshake ---
    input  wire        eeprom_cache_start,
    output reg         eeprom_cache_done,

    // --- Data output ---
    output wire [127:0] eeprom_id_data,
    output wire [127:0] eeprom_key_data,

    // --- SPI to EEPROM ---
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_sclk,
    output reg         spi_cs_n_eeprom
);

    // =====================================================================
    // SPI Master instance
    // =====================================================================
    reg        spi_start;
    reg  [7:0] spi_txd;
    wire [7:0] spi_rxd;
    wire       spi_busy, spi_done;

    spi_master #(.CLK_DIV(100)) u_spi (
        .clk     (clk),
        .rst     (rst),
        .tx_data (spi_txd),
        .tx_start(spi_start),
        .miso    (spi_miso),
        .rx_data (spi_rxd),
        .busy    (spi_busy),
        .done    (spi_done),
        .mosi    (spi_mosi),
        .sclk    (spi_sclk)
    );

    // =====================================================================
    // EEPROM data storage (32 bytes packed): byte 0 at [255:248], byte 31 at [7:0]
    // =====================================================================
    reg [255:0] eed_flat;

    assign eeprom_id_data  = eed_flat[255:128];
    assign eeprom_key_data = eed_flat[127:0];

    // =====================================================================
    // FSM States
    // =====================================================================
    localparam [2:0]
        IDLE    = 3'd0,
        EE_CS   = 3'd1,   // assert CS, send READ cmd
        EE_ADDR = 3'd2,   // send address byte
        EE_DATA = 3'd3,   // clock out 32 data bytes
        EE_DONE = 3'd4;

    reg [2:0] state;
    reg [5:0] eidx;

    // =====================================================================
    // Main FSM
    // =====================================================================
    always @(posedge clk) begin
        if (rst) begin
            state           <= IDLE;
            spi_cs_n_eeprom <= 1'b1;
            spi_start       <= 1'b0;
            spi_txd         <= 8'd0;
            eidx            <= 6'd0;
            eed_flat        <= 256'd0;
            eeprom_cache_done <= 1'b0;
        end else begin
            spi_start         <= 1'b0;
            eeprom_cache_done <= 1'b0;

            case (state)

            // --- Wait for start pulse ---
            IDLE: begin
                if (eeprom_cache_start) begin
                    spi_cs_n_eeprom <= 1'b0;
                    eidx            <= 6'd0;
                    state           <= EE_CS;
                end
            end

            // --- Send READ command (0x03) ---
            EE_CS: begin
                if (!spi_busy) begin
                    spi_txd   <= 8'h03;
                    spi_start <= 1'b1;
                    state     <= EE_ADDR;
                end
            end

            // --- Send address 0x00 ---
            EE_ADDR: begin
                if (spi_done) begin
                    spi_txd   <= 8'h00;
                    spi_start <= 1'b1;
                    state     <= EE_DATA;
                end
            end

            // --- Clock out 32 data bytes ---
            EE_DATA: begin
                if (spi_done) begin
                    if (eidx > 0)
                        eed_flat[255 - ((eidx - 6'd1) * 8) -: 8] <= spi_rxd;

                    if (eidx < 32) begin
                        spi_txd   <= 8'h00;
                        spi_start <= 1'b1;
                        eidx      <= eidx + 1;
                    end else begin
                        eed_flat[7:0]   <= spi_rxd;
                        spi_cs_n_eeprom <= 1'b1;
                        state           <= EE_DONE;
                    end
                end
            end

            // --- Signal completion ---
            EE_DONE: begin
                eeprom_cache_done <= 1'b1;
                state             <= IDLE;
            end

            default: state <= IDLE;
            endcase
        end
    end

endmodule
