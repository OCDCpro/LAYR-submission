// ============================================================================
// LAYR Guardian — Top-Level with AES-128 Mutual Authentication
//
// Pinout:
//   Pin1  rst            Pin2  sys_clk        Pin3  uart_clk (unused)
//   Pin4  user_io_0      Pin5  uart_rx (unused) Pin6  uart_tx (unused)
//   Pin7  user_io_1      Pin8  user_io_2      Pin9  user_io_3
//   Pin10 user_io_4      Pin13 cs_1 (RC522)   Pin14 cs_2 (EEPROM)
//   Pin15 spi_miso       Pin16 spi_mosi       Pin17 spi_sclk
//   Pin21 status_unlock  Pin22 status_fault   Pin23 status_busy
// ============================================================================
module chip (
    input  wire rst,
    input  wire sys_clk,
    output wire user_io_0,
    output wire user_io_1,
    output wire user_io_2,
    output wire user_io_3,
    output wire user_io_4,
    output wire cs_1,           // SPI CS for RC522
    output wire cs_2,           // SPI CS for EEPROM
    input  wire spi_miso,
    output wire spi_mosi,
    output wire spi_sclk,
    output wire status_unlock,
    output wire status_fault,
    output wire status_busy
);

    // === Power-On Reset ===

    reg [7:0] por_cnt = 8'd0;
    always @(posedge sys_clk) begin
        if (!por_cnt[7]) por_cnt <= por_cnt + 1'b1;
    end
    reg [1:0] rst_pipe = 2'b00;
    wire rst_int = rst_pipe[1] | ~por_cnt[7];
    always @(posedge sys_clk) begin
        rst_pipe <= {rst_pipe[0], rst};
    end

    // === Debug / Heartbeat ===
    reg [26:0] hb_cnt;
    always @(posedge sys_clk) begin
        if (rst_int) hb_cnt <= 0;
        else         hb_cnt <= hb_cnt + 1;
    end
    assign user_io_0 = hb_cnt[26];

    // === Output Controller ===
    wire [2:0] out_state;

    output_controller u_out (
        .state  (out_state),
        .busy   (status_busy),
        .fault  (status_fault),
        .unlock (status_unlock)
    );

    // === LFSR PRNG ===
    wire [63:0] lfsr_out;

    lfsr64 u_lfsr (
        .clk     (sys_clk),
        .rst     (rst_int),
        .rng_out (lfsr_out)
    );

    // === AES-128 Core ===
    wire        aes_start;
    wire        aes_mode;
    wire [127:0] aes_key;
    wire [127:0] aes_data_in;
    wire        aes_done;
    wire [127:0] aes_data_out;

    aes128 u_aes (
        .clk      (sys_clk),
        .rst      (rst_int),
        .start    (aes_start),
        .mode     (aes_mode),
        .key      (aes_key),
        .data_in  (aes_data_in),
        .done     (aes_done),
        .data_out (aes_data_out)
    );

    // === RC Controller ===
    wire         rc_init_start;
    wire         rc_init_done;
    wire         rc_poll_start;
    wire         rc_poll_done;
    wire         rc_poll_card_found;
    wire         rc_card_init_start;
    wire         rc_card_init_done;
    wire         rc_card_init_failure;
    wire         rc_read_id_start;
    wire         rc_read_id_done;
    wire         rc_read_id_failure;
    wire [127:0] rc_id_data;
    wire         rc_auth_init_start;
    wire         rc_auth_init_done;
    wire         rc_auth_init_failure;
    wire         rc_auth_start;
    wire         rc_auth_done;
    wire         rc_auth_failure;
    wire [127:0] rc_auth_data;
    wire         rc_mosi, rc_sclk;

    rc_controller u_rc (
        .clk                 (sys_clk),
        .rst                 (rst_int),
        .rc_init_start       (rc_init_start),
        .rc_init_done        (rc_init_done),
        .rc_poll_start       (rc_poll_start),
        .rc_poll_done        (rc_poll_done),
        .rc_poll_card_found  (rc_poll_card_found),
        .rc_card_init_start  (rc_card_init_start),
        .rc_card_init_done   (rc_card_init_done),
        .rc_card_init_failure(rc_card_init_failure),
        .rc_read_id_start    (rc_read_id_start),
        .rc_read_id_done     (rc_read_id_done),
        .rc_read_id_failure  (rc_read_id_failure),
        .rc_id_data          (rc_id_data),
        .rc_auth_init_start  (rc_auth_init_start),
        .rc_auth_init_done   (rc_auth_init_done),
        .rc_auth_init_failure(rc_auth_init_failure),
        .rc_auth_start       (rc_auth_start),
        .rc_auth_done        (rc_auth_done),
        .rc_auth_failure     (rc_auth_failure),
        .rc_auth_data        (rc_auth_data),
        .spi_mosi            (rc_mosi),
        .spi_miso            (spi_miso),
        .spi_sclk            (rc_sclk),
        .spi_cs_n_rc         (cs_1)
    );

    // === EEPROM Controller ===
    wire         eeprom_cache_start;
    wire         eeprom_cache_done;
    wire [127:0] eeprom_id_data;
    wire [127:0] eeprom_key_data;
    wire         ee_mosi, ee_sclk;

    eeprom_controller u_ee (
        .clk                (sys_clk),
        .rst                (rst_int),
        .eeprom_cache_start (eeprom_cache_start),
        .eeprom_cache_done  (eeprom_cache_done),
        .eeprom_id_data     (eeprom_id_data),
        .eeprom_key_data    (eeprom_key_data),
        .spi_mosi           (ee_mosi),
        .spi_miso           (spi_miso),
        .spi_sclk           (ee_sclk),
        .spi_cs_n_eeprom    (cs_2)
    );

    // === SPI Bus Mux ===
    wire [1:0] spi_device_select;

    assign spi_mosi = (spi_device_select == 2'b10) ? ee_mosi : rc_mosi;
    assign spi_sclk = (spi_device_select == 2'b10) ? ee_sclk : rc_sclk;

    // === Main FSM (orchestrator) ===
    wire [4:0] fsm_state_out;

    main_fsm u_fsm (
        .clk                 (sys_clk),
        .reset               (rst_int),
        .state_out           (fsm_state_out),
        .out_state           (out_state),

        .eeprom_cache_start  (eeprom_cache_start),
        .eeprom_cache_done   (eeprom_cache_done),
        .eeprom_id_data      (eeprom_id_data),
        .eeprom_key_data     (eeprom_key_data),

        .rc_init_start       (rc_init_start),
        .rc_init_done        (rc_init_done),

        .rc_poll_start       (rc_poll_start),
        .rc_poll_done        (rc_poll_done),
        .rc_poll_card_found  (rc_poll_card_found),

        .rc_card_init_start  (rc_card_init_start),
        .rc_card_init_done   (rc_card_init_done),
        .rc_card_init_failure(rc_card_init_failure),

        .rc_read_id_start    (rc_read_id_start),
        .rc_read_id_done     (rc_read_id_done),
        .rc_read_id_failure  (rc_read_id_failure),
        .rc_id_data          (rc_id_data),

        .rc_auth_init_start  (rc_auth_init_start),
        .rc_auth_init_done   (rc_auth_init_done),
        .rc_auth_init_failure(rc_auth_init_failure),

        .rc_auth_start       (rc_auth_start),
        .rc_auth_done        (rc_auth_done),
        .rc_auth_failure     (rc_auth_failure),
        .rc_auth_data        (rc_auth_data),

        .aes_start           (aes_start),
        .aes_mode            (aes_mode),
        .aes_key             (aes_key),
        .aes_data_in         (aes_data_in),
        .aes_done            (aes_done),
        .aes_data_out        (aes_data_out),

        .lfsr_out            (lfsr_out),

        .spi_device_select   (spi_device_select)
    );

    // === Debug: first EEPROM ID byte upper nibble on user_io 1-4 ===
    assign user_io_1 = eeprom_id_data[127];  // bit 7 (MSB)
    assign user_io_2 = eeprom_id_data[126];  // bit 6
    assign user_io_3 = eeprom_id_data[125];  // bit 5
    assign user_io_4 = eeprom_id_data[124];  // bit 4

endmodule
