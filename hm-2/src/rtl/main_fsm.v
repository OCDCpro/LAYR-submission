// ============================================================================
// main_fsm — LAYR Guardian orchestrator with AES-128 mutual authentication
//
// Protocol flow after card detection:
//   1. Card init (anticol + SELECT + RATS)
//   2. AUTH_INIT (includes SELECT AID + AUTH_INIT APDU) → get ciphertext
//   3. Decrypt ciphertext with PSK → recover rc, verify padding
//   4. Generate rt (LFSR), encrypt AES_psk(rt || rc) → auth_response
//   5. AUTH → send auth_response to card
//   6. Compute k_eph = AES_psk(rc || rt)
//   7. GET_ID → get AES_keph(ID)
//   8. Decrypt → recover ID, compare with EEPROM
// ============================================================================
module main_fsm (
    input  wire        clk,
    input  wire        reset,

    output wire [4:0]  state_out,
    output reg  [2:0]  out_state,

    // EEPROM
    output reg         eeprom_cache_start,
    input  wire        eeprom_cache_done,
    input  wire [127:0] eeprom_id_data,
    input  wire [127:0] eeprom_key_data,

    // RC522 — init
    output reg         rc_init_start,
    input  wire        rc_init_done,

    // RC522 — poll
    output reg         rc_poll_start,
    input  wire        rc_poll_done,
    input  wire        rc_poll_card_found,

    // RC522 — card init (anticol + select + RATS)
    output reg         rc_card_init_start,
    input  wire        rc_card_init_done,
    input  wire        rc_card_init_failure,

    // RC522 — GET_ID only (after auth)
    output reg         rc_read_id_start,
    input  wire        rc_read_id_done,
    input  wire        rc_read_id_failure,
    input  wire [127:0] rc_id_data,

    // RC522 — AUTH_INIT (SELECT AID + AUTH_INIT APDU)
    output reg         rc_auth_init_start,
    input  wire        rc_auth_init_done,
    input  wire        rc_auth_init_failure,

    // RC522 — AUTH
    output reg         rc_auth_start,
    input  wire        rc_auth_done,
    input  wire        rc_auth_failure,
    output reg  [127:0] rc_auth_data,

    // AES-128 core
    output reg         aes_start,
    output reg         aes_mode,       // 0=encrypt, 1=decrypt
    output reg  [127:0] aes_key,
    output reg  [127:0] aes_data_in,
    input  wire        aes_done,
    input  wire [127:0] aes_data_out,

    // LFSR PRNG
    input  wire [63:0] lfsr_out,

    // SPI bus select
    output reg  [1:0]  spi_device_select
);

    // =====================================================================
    // State encoding (5-bit)
    // =====================================================================
    localparam [4:0]
        S_BOOT             = 5'd0,
        S_CACHE_EEPROM     = 5'd1,
        S_INIT_RC          = 5'd2,
        S_IDLE             = 5'd3,
        S_CARD_INIT        = 5'd4,
        S_AUTH_INIT        = 5'd5,
        S_AES_DEC1         = 5'd6,
        S_VERIFY_RC        = 5'd7,
        S_AES_ENC1         = 5'd8,
        S_AUTH             = 5'd9,
        S_AES_ENC2         = 5'd10,
        S_READ_ID          = 5'd11,
        S_AES_DEC2         = 5'd12,
        S_CHECK_ID         = 5'd13,
        S_TIMEOUT_DENY     = 5'd14,
        S_TIMEOUT_SUCCESS  = 5'd15,
        S_SOFT_RESET       = 5'd16;

    // SPI device selection
    localparam [1:0]
        SPI_DEVICE_NONE   = 2'b00,
        SPI_DEVICE_RC     = 2'b01,
        SPI_DEVICE_EEPROM = 2'b10;

    // Output-controller state encoding
    localparam [2:0]
        OC_IDLE   = 3'b000,
        OC_BUSY   = 3'b001,
        OC_FAULT  = 3'b010,
        OC_UNLOCK = 3'b011,
        OC_RESET  = 3'b100;

    // =====================================================================
    // Internal registers
    // =====================================================================
    reg [4:0]  state;
    assign state_out = state;

    // Sub-operation tracking
    reg eeprom_cache_started;
    reg rc_init_started;
    reg rc_poll_started;
    reg rc_card_init_started;
    reg rc_auth_init_started;
    reg aes_started;
    reg rc_auth_started;
    reg rc_read_id_started;

    // Failure counters
    localparam [3:0] MAX_FAILURES = 4'd5;
    reg [3:0] card_init_fail_count;
    reg [3:0] auth_fail_count;
    reg [3:0] poll_fail_count;

    // Timeout counters (3 s at 100 MHz = 300_000_000)
    localparam [31:0] TIMEOUT_DENY    = 32'd300_000_000;
    localparam [31:0] TIMEOUT_SUCCESS = 32'd300_000_000;
    reg [31:0] deny_timeout_counter;
    reg [31:0] success_timeout_counter;

    // Authentication state
    reg [63:0]  rc_challenge;      // card's 8-byte challenge
    reg [63:0]  rt_challenge;      // our 8-byte challenge
    reg [63:0]  rc_padding;        // lower 8 bytes from decrypted AUTH_INIT
    reg [127:0] k_eph;             // ephemeral session key
    reg [127:0] decrypted_id;      // decrypted card ID

    // =====================================================================
    // Output-state mapping (combinational)
    // =====================================================================
    always @(*) begin
        case (state)
            S_BOOT:            out_state = OC_RESET;
            S_CACHE_EEPROM:    out_state = OC_RESET;
            S_INIT_RC:         out_state = OC_RESET;
            S_IDLE:            out_state = OC_IDLE;
            S_CARD_INIT:       out_state = OC_BUSY;
            S_AUTH_INIT:       out_state = OC_BUSY;
            S_AES_DEC1:        out_state = OC_BUSY;
            S_VERIFY_RC:       out_state = OC_BUSY;
            S_AES_ENC1:        out_state = OC_BUSY;
            S_AUTH:            out_state = OC_BUSY;
            S_AES_ENC2:        out_state = OC_BUSY;
            S_READ_ID:         out_state = OC_BUSY;
            S_AES_DEC2:        out_state = OC_BUSY;
            S_CHECK_ID:        out_state = OC_BUSY;
            S_TIMEOUT_DENY:    out_state = OC_FAULT;
            S_TIMEOUT_SUCCESS: out_state = OC_UNLOCK;
            S_SOFT_RESET:      out_state = OC_RESET;
            default:           out_state = OC_RESET;
        endcase
    end

    // =====================================================================
    // Main FSM (synchronous reset)
    // =====================================================================
    always @(posedge clk) begin
        if (reset) begin
            state                   <= S_SOFT_RESET;
            spi_device_select       <= SPI_DEVICE_NONE;

            eeprom_cache_start      <= 1'b0;
            eeprom_cache_started    <= 1'b0;

            rc_init_start           <= 1'b0;
            rc_init_started         <= 1'b0;

            rc_poll_start           <= 1'b0;
            rc_poll_started         <= 1'b0;

            rc_card_init_start      <= 1'b0;
            rc_card_init_started    <= 1'b0;

            rc_auth_init_start      <= 1'b0;
            rc_auth_init_started    <= 1'b0;

            aes_start               <= 1'b0;
            aes_started             <= 1'b0;
            aes_mode                <= 1'b0;
            aes_key                 <= 128'd0;
            aes_data_in             <= 128'd0;

            rc_auth_start           <= 1'b0;
            rc_auth_started         <= 1'b0;
            rc_auth_data            <= 128'd0;

            rc_read_id_start        <= 1'b0;
            rc_read_id_started      <= 1'b0;

            card_init_fail_count    <= 4'd0;
            auth_fail_count         <= 4'd0;
            poll_fail_count         <= 4'd0;

            deny_timeout_counter    <= 32'd0;
            success_timeout_counter <= 32'd0;

            rc_challenge            <= 64'd0;
            rt_challenge            <= 64'd0;
            rc_padding              <= 64'd0;
            k_eph                   <= 128'd0;
            decrypted_id            <= 128'd0;
        end else begin

            // Default: deassert all start pulses every cycle
            eeprom_cache_start  <= 1'b0;
            rc_init_start       <= 1'b0;
            rc_poll_start       <= 1'b0;
            rc_card_init_start  <= 1'b0;
            rc_auth_init_start  <= 1'b0;
            aes_start           <= 1'b0;
            rc_auth_start       <= 1'b0;
            rc_read_id_start    <= 1'b0;

            case (state)

            // =============================================================
            S_BOOT: begin
                state <= S_CACHE_EEPROM;
            end

            // =============================================================
            S_CACHE_EEPROM: begin
                if (!eeprom_cache_started) begin
                    spi_device_select    <= SPI_DEVICE_EEPROM;
                    eeprom_cache_started <= 1'b1;
                    eeprom_cache_start   <= 1'b1;
                end else if (eeprom_cache_done) begin
                    spi_device_select    <= SPI_DEVICE_NONE;
                    eeprom_cache_started <= 1'b0;
                    state                <= S_INIT_RC;
                end
            end

            // =============================================================
            S_INIT_RC: begin
                if (!rc_init_started) begin
                    spi_device_select <= SPI_DEVICE_RC;
                    rc_init_started   <= 1'b1;
                    rc_init_start     <= 1'b1;
                end else if (rc_init_done) begin
                    rc_init_started <= 1'b0;
                    state           <= S_IDLE;
                end
            end

            // =============================================================
            S_IDLE: begin
                if (poll_fail_count >= MAX_FAILURES ||
                    card_init_fail_count >= MAX_FAILURES ||
                    auth_fail_count >= MAX_FAILURES) begin
                    state <= S_SOFT_RESET;
                end else if (!rc_poll_started) begin
                    spi_device_select <= SPI_DEVICE_RC;
                    rc_poll_started   <= 1'b1;
                    rc_poll_start     <= 1'b1;
                end else if (rc_poll_done) begin
                    rc_poll_started <= 1'b0;
                    if (rc_poll_card_found)
                        state <= S_CARD_INIT;
                end
            end

            // =============================================================
            S_CARD_INIT: begin
                if (!rc_card_init_started) begin
                    spi_device_select    <= SPI_DEVICE_RC;
                    rc_card_init_started <= 1'b1;
                    rc_card_init_start   <= 1'b1;
                end else if (rc_card_init_done) begin
                    rc_card_init_started <= 1'b0;
                    if (rc_card_init_failure) begin
                        card_init_fail_count <= card_init_fail_count + 1;
                        state <= S_IDLE;
                    end else begin
                        state <= S_AUTH_INIT;
                    end
                end
            end

            // =============================================================
            // AUTH_INIT: rc_controller sends SELECT AID + AUTH_INIT APDU,
            // returns 16-byte ciphertext in rc_id_data
            // =============================================================
            S_AUTH_INIT: begin
                if (!rc_auth_init_started) begin
                    spi_device_select    <= SPI_DEVICE_RC;
                    rc_auth_init_started <= 1'b1;
                    rc_auth_init_start   <= 1'b1;
                end else if (rc_auth_init_done) begin
                    rc_auth_init_started <= 1'b0;
                    if (rc_auth_init_failure) begin
                        auth_fail_count <= auth_fail_count + 1;
                        state <= S_IDLE;
                    end else begin
                        state <= S_AES_DEC1;
                    end
                end
            end

            // =============================================================
            // AES Decrypt: ciphertext with PSK → (rc || zeros)
            // =============================================================
            S_AES_DEC1: begin
                if (!aes_started) begin
                    aes_started <= 1'b1;
                    aes_mode    <= 1'b1;               // decrypt
                    aes_key     <= eeprom_key_data;     // PSK
                    aes_data_in <= rc_id_data;          // ciphertext
                    aes_start   <= 1'b1;
                end else if (aes_done) begin
                    aes_started  <= 1'b0;
                    rc_challenge <= aes_data_out[127:64];
                    rc_padding   <= aes_data_out[63:0];
                    state        <= S_VERIFY_RC;
                end
            end

            // =============================================================
            // Verify padding: last 8 bytes must be 0x00
            // =============================================================
            S_VERIFY_RC: begin
                if (rc_padding != 64'd0) begin
                    auth_fail_count <= auth_fail_count + 1;
                    state           <= S_TIMEOUT_DENY;
                end else begin
                    rt_challenge <= lfsr_out;
                    state        <= S_AES_ENC1;
                end
            end

            // =============================================================
            // AES Encrypt: (rt || rc) with PSK → auth_response
            // =============================================================
            S_AES_ENC1: begin
                if (!aes_started) begin
                    aes_started <= 1'b1;
                    aes_mode    <= 1'b0;               // encrypt
                    aes_key     <= eeprom_key_data;
                    aes_data_in <= {rt_challenge, rc_challenge};
                    aes_start   <= 1'b1;
                end else if (aes_done) begin
                    aes_started  <= 1'b0;
                    rc_auth_data <= aes_data_out;
                    state        <= S_AUTH;
                end
            end

            // =============================================================
            // AUTH: Send auth_response to card
            // =============================================================
            S_AUTH: begin
                if (!rc_auth_started) begin
                    spi_device_select <= SPI_DEVICE_RC;
                    rc_auth_started   <= 1'b1;
                    rc_auth_start     <= 1'b1;
                end else if (rc_auth_done) begin
                    rc_auth_started <= 1'b0;
                    if (rc_auth_failure) begin
                        auth_fail_count <= auth_fail_count + 1;
                        state <= S_TIMEOUT_DENY;
                    end else begin
                        state <= S_AES_ENC2;
                    end
                end
            end

            // =============================================================
            // k_eph = rc || rt (direct concatenation, per protocol spec)
            // =============================================================
            S_AES_ENC2: begin
                k_eph <= {rc_challenge, rt_challenge};
                state <= S_READ_ID;
            end

            // =============================================================
            // GET_ID: Send GET_ID APDU, get AES_keph(ID)
            // =============================================================
            S_READ_ID: begin
                if (!rc_read_id_started) begin
                    spi_device_select  <= SPI_DEVICE_RC;
                    rc_read_id_started <= 1'b1;
                    rc_read_id_start   <= 1'b1;
                end else if (rc_read_id_done) begin
                    rc_read_id_started <= 1'b0;
                    if (rc_read_id_failure) begin
                        auth_fail_count <= auth_fail_count + 1;
                        state <= S_IDLE;
                    end else begin
                        state <= S_AES_DEC2;
                    end
                end
            end

            // =============================================================
            // AES Decrypt: encrypted ID with k_eph → plaintext ID
            // =============================================================
            S_AES_DEC2: begin
                if (!aes_started) begin
                    aes_started <= 1'b1;
                    aes_mode    <= 1'b1;               // decrypt
                    aes_key     <= k_eph;
                    aes_data_in <= rc_id_data;          // encrypted ID
                    aes_start   <= 1'b1;
                end else if (aes_done) begin
                    aes_started  <= 1'b0;
                    decrypted_id <= aes_data_out;
                    state        <= S_CHECK_ID;
                end
            end

            // =============================================================
            // Compare decrypted ID with EEPROM stored ID
            // =============================================================
            S_CHECK_ID: begin
                if (decrypted_id == eeprom_id_data)
                    state <= S_TIMEOUT_SUCCESS;
                else
                    state <= S_TIMEOUT_DENY;
            end

            // =============================================================
            S_TIMEOUT_DENY: begin
                if (deny_timeout_counter >= TIMEOUT_DENY) begin
                    deny_timeout_counter <= 32'd0;
                    state                <= S_IDLE;
                end else begin
                    deny_timeout_counter <= deny_timeout_counter + 1;
                end
            end

            // =============================================================
            S_TIMEOUT_SUCCESS: begin
                if (success_timeout_counter >= TIMEOUT_SUCCESS) begin
                    success_timeout_counter <= 32'd0;
                    state                   <= S_IDLE;
                end else begin
                    success_timeout_counter <= success_timeout_counter + 1;
                end
            end

            // =============================================================
            S_SOFT_RESET: begin
                state                   <= S_BOOT;
                spi_device_select       <= SPI_DEVICE_NONE;

                eeprom_cache_started    <= 1'b0;
                rc_init_started         <= 1'b0;
                rc_poll_started         <= 1'b0;
                rc_card_init_started    <= 1'b0;
                rc_auth_init_started    <= 1'b0;
                aes_started             <= 1'b0;
                rc_auth_started         <= 1'b0;
                rc_read_id_started      <= 1'b0;

                card_init_fail_count    <= 4'd0;
                auth_fail_count         <= 4'd0;
                poll_fail_count         <= 4'd0;

                deny_timeout_counter    <= 32'd0;
                success_timeout_counter <= 32'd0;
            end

            // =============================================================
            default: state <= S_SOFT_RESET;

            endcase
        end
    end

endmodule
