// ============================================================================
// RC522 RFID Controller — extracted from LAYR Guardian top-level
//
// Handshake interface for external state machine:
//   rc_init_start / rc_init_done           — RC522 soft-reset + register init
//   rc_poll_start / rc_poll_done/found     — Send REQA, report card presence
//   rc_card_init_start / done / failure    — Anticollision + CRC + SELECT + RATS
//   rc_read_id_start / done / failure      — I-Block SELECT AID + AUTH_INIT/AUTH/GET_ID
//   rc_auth_init_start / done / failure    — I-Block AUTH_INIT (response in rc_id_data)
//   rc_auth_start / done / failure         — I-Block AUTH (sends rc_auth_data to card)
//   rc_id_data [127:0]                     — 16-byte response from card
//
// NOTE: spi_miso is an input (data from RC522 to FPGA).
// ============================================================================
module rc_controller (
    input  wire        clk,
    input  wire        rst,

    // --- Init handshake ---
    input  wire        rc_init_start,
    output reg         rc_init_done,

    // --- Poll handshake ---
    input  wire        rc_poll_start,
    output reg         rc_poll_done,
    output reg         rc_poll_card_found,

    // --- Card init (anticol + select + RATS) handshake ---
    input  wire        rc_card_init_start,
    output reg         rc_card_init_done,
    output reg         rc_card_init_failure,

    // --- Read ID (I-Block SELECT AID + GET_ID) handshake ---
    input  wire        rc_read_id_start,
    output reg         rc_read_id_done,
    output reg         rc_read_id_failure,
    output wire [127:0] rc_id_data,

    // --- AUTH_INIT (I-Block, response in rc_id_data) ---
    input  wire        rc_auth_init_start,
    output reg         rc_auth_init_done,
    output reg         rc_auth_init_failure,

    // --- AUTH (I-Block, sends 16-byte payload) ---
    input  wire        rc_auth_start,
    output reg         rc_auth_done,
    output reg         rc_auth_failure,
    input  wire [127:0] rc_auth_data,

    // --- SPI to RC522 ---
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_sclk,
    output reg         spi_cs_n_rc
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
    // Register Addresses (RC522)
    // =====================================================================
    localparam [5:0]
        CommandReg     = 6'h01,
        ComIrqReg      = 6'h04,
        DivIrqReg      = 6'h05,
        ErrorReg        = 6'h06,
        FIFODataReg    = 6'h09,
        FIFOLevelReg   = 6'h0A,
        ControlReg     = 6'h0C,
        BitFramingReg  = 6'h0D,
        CollReg        = 6'h0E,
        ModeReg        = 6'h11,
        TxModeReg      = 6'h12,
        RxModeReg      = 6'h13,
        TxControlReg   = 6'h14,
        TxASKReg       = 6'h15,
        CRCResultRegH  = 6'h21,
        CRCResultRegL  = 6'h22,
        ModWidthReg    = 6'h24,
        TModeReg       = 6'h2A,
        TPrescalerReg  = 6'h2B,
        TReloadRegH    = 6'h2C,
        TReloadRegL    = 6'h2D,
        VersionReg     = 6'h37;

    // =====================================================================
    // FSM States
    // =====================================================================
    localparam [7:0]
        // SPI register sub-FSM
        S0           = 8'd1,
        S1           = 8'd2,
        S2           = 8'd3,
        S3           = 8'd4,

        // Top-level wait states
        IDLE         = 8'd20,

        // Init
        I_RST        = 8'd10,
        I_W50        = 8'd11,
        I_CHK        = 8'd12,
        I_EVAL       = 8'd13,
        I_WR         = 8'd14,
        I_WR2        = 8'd15,
        I_ANT        = 8'd16,
        I_ANT2       = 8'd17,
        I_VER        = 8'd18,
        I_VER2       = 8'd19,

        // REQA (poll)
        RQ0          = 8'd30,
        RQ1          = 8'd31,
        RQ2          = 8'd32,
        RQ3          = 8'd33,

        // Transceive engine
        T_IDLE       = 8'd40,
        T_CIRQ       = 8'd41,
        T_FLUSH      = 8'd42,
        T_FIFO       = 8'd43,
        T_BFR        = 8'd44,
        T_XCV        = 8'd45,
        T_RDBF       = 8'd46,
        T_SS         = 8'd47,
        T_PRD        = 8'd48,
        T_PCHK       = 8'd49,
        T_ERD        = 8'd50,
        T_ECHK       = 8'd51,
        T_LRD        = 8'd52,
        T_LCHK       = 8'd53,
        T_FRD        = 8'd54,
        T_FST        = 8'd55,

        // Anticollision
        AC0          = 8'd60,
        AC1          = 8'd61,
        AC2          = 8'd62,

        // CRC calculation
        CR0          = 8'd63,
        CR1          = 8'd64,
        CR2          = 8'd65,
        CR3          = 8'd66,
        CR4          = 8'd67,
        CR5          = 8'd68,
        CR6          = 8'd69,
        CR7          = 8'd70,
        CR8          = 8'd71,
        CR9          = 8'd72,

        // SELECT done
        SELDONE      = 8'd73,

        // RATS
        RT0          = 8'd80,
        RT1          = 8'd81,
        RT2          = 8'd82,
        RP0          = 8'd83,
        RP1          = 8'd84,
        RP2          = 8'd85,
        RP3          = 8'd86,
        RP_DLY       = 8'd87,

        // I-Block SELECT AID
        IS0          = 8'd90,
        IS1          = 8'd91,
        IS_CHK       = 8'd92,

        // I-Block GET_ID
        IG0          = 8'd95,
        IG1          = 8'd96,
        IG_CHK       = 8'd97,
        IG_CP        = 8'd98,
        IG_CP2       = 8'd99,

        // I-Block AUTH_INIT (0x80 0x10)
        IA0          = 8'd100,
        IA1          = 8'd101,
        IA_CHK       = 8'd102,
        IA_CP        = 8'd103,
        IA_CP2       = 8'd104,

        // I-Block AUTH (0x80 0x11)
        AU0          = 8'd110,
        AU1          = 8'd111,
        AU_CHK       = 8'd112,

        // Terminal states (signal done/failure back to IDLE)
        DONE_OK      = 8'd200,
        DONE_FAIL    = 8'd201;

    // =====================================================================
    // Internal Registers
    // =====================================================================
    reg [7:0] state, ret;

    // SPI register sub-FSM parameters
    reg        rw;          // 1=write, 0=read
    reg [5:0]  ra;          // register address
    reg [7:0]  wd;          // write data
    reg [7:0]  rd;          // read data (latched)

    // Transceive buffers
    (* ram_style = "registers" *)  reg [7:0]  txb [0:31];
    reg [4:0]  txn;
    reg [255:0] rxb_flat;
    reg [4:0]  rxn;
    reg [4:0]  idx;
    reg [7:0]  bfv;         // BitFramingReg value
    reg [7:0]  tok, tfail;  // transceive return states

    // Timers
    reg [23:0] tmo;
    reg [28:0] dly;
    localparam DLY50M = 29'd5_000_000;
    localparam DLY10M = 29'd1_000_000;
    localparam TMO    = 24'd15_000_000;

    // Protocol
    reg [3:0]  iidx;       // init sequence index
    reg        itgl;       // I-Block toggle bit
    reg [7:0]  crcl, crch;
    reg [3:0]  rcnt;       // retry count

    // Card ID / response storage (16 bytes)
    reg [127:0] cid_flat;

    function [7:0] rxb_byte;
        input [4:0] i;
        begin
            rxb_byte = rxb_flat[255 - (i * 8) -: 8];
        end
    endfunction

    // Which operation is active (to route DONE_OK / DONE_FAIL)
    localparam [2:0]
        OP_NONE      = 3'd0,
        OP_INIT      = 3'd1,
        OP_POLL      = 3'd2,
        OP_CARD_INIT = 3'd3,
        OP_READ_ID   = 3'd4,
        OP_AUTH_INIT = 3'd5,
        OP_AUTH      = 3'd6;
    reg [2:0] active_op;

    // Poll result latch
    reg poll_found_latch;

    // =====================================================================
    // Output: rc_id_data (byte 0 at [127:120], byte 15 at [7:0])
    // =====================================================================
    assign rc_id_data = cid_flat;

    // =====================================================================
    // Main FSM
    // =====================================================================
    always @(posedge clk) begin
        if (rst) begin
            state          <= IDLE;
            ret            <= IDLE;
            spi_cs_n_rc    <= 1'b1;
            spi_start      <= 1'b0;
            spi_txd        <= 8'd0;
            rw <= 0; ra <= 0; wd <= 0; rd <= 0;
            txn <= 0; rxn <= 0; idx <= 0; bfv <= 0;
            rxb_flat <= 256'd0;
            tok <= IDLE; tfail <= IDLE;
            tmo <= 0; dly <= 0;
            iidx <= 0; itgl <= 0;
            crcl <= 0; crch <= 0; rcnt <= 0;
            cid_flat <= 128'd0;
            active_op      <= OP_NONE;
            poll_found_latch <= 0;

            rc_init_done         <= 1'b0;
            rc_poll_done         <= 1'b0;
            rc_poll_card_found   <= 1'b0;
            rc_card_init_done    <= 1'b0;
            rc_card_init_failure <= 1'b0;
            rc_read_id_done      <= 1'b0;
            rc_read_id_failure   <= 1'b0;
            rc_auth_init_done    <= 1'b0;
            rc_auth_init_failure <= 1'b0;
            rc_auth_done         <= 1'b0;
            rc_auth_failure      <= 1'b0;
        end else begin
            spi_start <= 1'b0;

            // Auto-clear done/failure pulses after one cycle in IDLE
            if (state == IDLE) begin
                rc_init_done         <= 1'b0;
                rc_poll_done         <= 1'b0;
                rc_poll_card_found   <= 1'b0;
                rc_card_init_done    <= 1'b0;
                rc_card_init_failure <= 1'b0;
                rc_read_id_done      <= 1'b0;
                rc_read_id_failure   <= 1'b0;
                rc_auth_init_done    <= 1'b0;
                rc_auth_init_failure <= 1'b0;
                rc_auth_done         <= 1'b0;
                rc_auth_failure      <= 1'b0;
            end

            case (state)

            // =============================================================
            // IDLE — wait for a start signal from the external state machine
            // =============================================================
            IDLE: begin
                if (rc_init_start) begin
                    active_op <= OP_INIT;
                    state     <= I_RST;
                end else if (rc_poll_start) begin
                    active_op        <= OP_POLL;
                    poll_found_latch <= 1'b0;
                    state            <= RQ0;
                end else if (rc_card_init_start) begin
                    active_op <= OP_CARD_INIT;
                    state     <= AC0;
                end else if (rc_read_id_start) begin
                    active_op <= OP_READ_ID;
                    state     <= IG0;   // GET_ID only (SELECT AID already done)
                end else if (rc_auth_init_start) begin
                    active_op <= OP_AUTH_INIT;
                    state     <= IS0;   // SELECT AID first, then AUTH_INIT
                end else if (rc_auth_start) begin
                    active_op <= OP_AUTH;
                    state     <= AU0;
                end
            end

            // =============================================================
            // SPI register sub-FSM  (unchanged from original)
            // Set rw, ra, wd (if write), ret before jumping to S0
            // =============================================================
            S0: begin
                if (!spi_busy) begin
                    spi_cs_n_rc <= 1'b0;
                    spi_txd     <= rw ? {1'b0, ra, 1'b0} : {1'b1, ra, 1'b0};
                    spi_start   <= 1'b1;
                    state       <= S1;
                end
            end
            S1: if (spi_done) begin
                spi_txd   <= rw ? wd : 8'h00;
                spi_start <= 1'b1;
                state     <= S2;
            end
            S2: if (spi_done) begin
                if (!rw) rd <= spi_rxd;
                spi_cs_n_rc <= 1'b1;
                state       <= S3;
            end
            S3: state <= ret;

            // =============================================================
            // INIT  (rc_init_start → rc_init_done)
            // =============================================================
            I_RST: begin
                rw<=1; ra<=CommandReg; wd<=8'h0F; ret<=I_W50;
                rcnt<=0; dly<=0; state<=S0;
            end
            I_W50: begin
                if (dly >= DLY50M) begin dly<=0; state<=I_CHK; end
                else dly <= dly + 1;
            end
            I_CHK: begin
                rw<=0; ra<=CommandReg; ret<=I_EVAL; state<=S0;
            end
            I_EVAL: begin
                if ((rd & 8'h10) == 0) begin iidx<=0; state<=I_WR; end
                else if (rcnt < 3) begin rcnt<=rcnt+1; dly<=0; state<=I_W50; end
                else begin
                    state <= DONE_OK;
                end
            end
            I_WR: begin
                rw <= 1; ret <= I_WR2; state <= S0;
                case (iidx)
                    0: begin ra<=TxModeReg;     wd<=8'h00; end
                    1: begin ra<=RxModeReg;     wd<=8'h00; end
                    2: begin ra<=ModWidthReg;   wd<=8'h26; end
                    3: begin ra<=TModeReg;      wd<=8'h80; end
                    4: begin ra<=TPrescalerReg; wd<=8'hA9; end
                    5: begin ra<=TReloadRegH;   wd<=8'h03; end
                    6: begin ra<=TReloadRegL;   wd<=8'hE8; end
                    7: begin ra<=TxASKReg;      wd<=8'h40; end
                    8: begin ra<=ModeReg;       wd<=8'h3D; end
                    default: state <= I_ANT;
                endcase
            end
            I_WR2: begin iidx <= iidx + 1; state <= I_WR; end

            // Antenna on
            I_ANT: begin rw<=0; ra<=TxControlReg; ret<=I_ANT2; state<=S0; end
            I_ANT2: begin
                if ((rd & 8'h03) != 8'h03) begin
                    rw<=1; ra<=TxControlReg; wd<=rd|8'h03; ret<=I_VER; state<=S0;
                end else state <= I_VER;
            end

            // Version check
            I_VER: begin rw<=0; ra<=VersionReg; ret<=I_VER2; state<=S0; end
            I_VER2: begin
                state <= DONE_OK;
            end

            // =============================================================
            // REQA / POLL  (rc_poll_start → rc_poll_done + rc_poll_card_found)
            // =============================================================
            RQ0: begin rw<=1; ra<=TxModeReg;   wd<=8'h00; ret<=RQ1; state<=S0; end
            RQ1: begin rw<=1; ra<=RxModeReg;   wd<=8'h00; ret<=RQ2; state<=S0; end
            RQ2: begin rw<=1; ra<=ModWidthReg; wd<=8'h26; ret<=RQ3; state<=S0; end
            RQ3: begin
                txb[0]<=8'h26; txn<=1; bfv<=8'h07;
                tok<=AC0;
                tfail<=DONE_FAIL;
                state<=T_IDLE;
            end

            // =============================================================
            // TRANSCEIVE ENGINE  (unchanged from original)
            // =============================================================
            T_IDLE:  begin rw<=1; ra<=CommandReg;    wd<=8'h00; ret<=T_CIRQ;  state<=S0; end
            T_CIRQ:  begin rw<=1; ra<=ComIrqReg;     wd<=8'h7F; ret<=T_FLUSH; state<=S0; end
            T_FLUSH: begin rw<=1; ra<=FIFOLevelReg;   wd<=8'h80; ret<=T_FIFO;  idx<=0; state<=S0; end

            T_FIFO: begin
                if (idx < txn) begin
                    rw<=1; ra<=FIFODataReg; wd<=txb[idx]; ret<=T_FIFO;
                    idx<=idx+1; state<=S0;
                end else state <= T_BFR;
            end

            T_BFR: begin rw<=1; ra<=BitFramingReg; wd<=bfv; ret<=T_XCV; state<=S0; end
            T_XCV: begin rw<=1; ra<=CommandReg;     wd<=8'h0C; ret<=T_RDBF; state<=S0; end
            T_RDBF: begin rw<=0; ra<=BitFramingReg; ret<=T_SS; state<=S0; end
            T_SS: begin rw<=1; ra<=BitFramingReg; wd<=rd|8'h80; ret<=T_PRD; tmo<=0; state<=S0; end

            T_PRD: begin
                if (tmo >= TMO) state <= tfail;
                else begin rw<=0; ra<=ComIrqReg; ret<=T_PCHK; state<=S0; end
            end
            T_PCHK: begin
                tmo <= tmo + 1;
                if (rd & 8'h30)      state <= T_ERD;
                else if (rd & 8'h01) state <= tfail;
                else                 state <= T_PRD;
            end

            T_ERD: begin rw<=0; ra<=ErrorReg; ret<=T_ECHK; state<=S0; end
            T_ECHK: begin
                if (rd & 8'h13) state <= tfail;
                else            state <= T_LRD;
            end

            T_LRD: begin rw<=0; ra<=FIFOLevelReg; ret<=T_LCHK; state<=S0; end
            T_LCHK: begin
                rxn <= rd[4:0]; idx <= 0;
                if (rd[4:0] == 0) state <= tok;
                else              state <= T_FRD;
            end

            T_FRD: begin rw<=0; ra<=FIFODataReg; ret<=T_FST; state<=S0; end
            T_FST: begin
                rxb_flat[255 - (idx * 8) -: 8] <= rd;
                if (idx + 1 >= rxn) state <= tok;
                else begin idx <= idx + 1; state <= T_FRD; end
            end

            // =============================================================
            // ANTICOLLISION  (part of rc_card_init OR post-poll check)
            // =============================================================
            AC0: begin
                if (active_op == OP_POLL) begin
                    if (rxn == 2) begin
                        poll_found_latch <= 1'b1;
                        state <= DONE_OK;
                    end else begin
                        poll_found_latch <= 1'b0;
                        state <= DONE_OK;
                    end
                end else begin
                    rw<=1; ra<=CollReg; wd<=8'h80; ret<=AC1; state<=S0;
                end
            end
            AC1: begin
                txb[0]<=8'h93; txb[1]<=8'h20; txn<=2; bfv<=8'h00;
                tok<=AC2; tfail<=DONE_FAIL; state<=T_IDLE;
            end
            AC2: begin
                if (rxn < 5) state <= DONE_FAIL;
                else begin
                    txb[0]<=8'h93; txb[1]<=8'h70;
                    txb[2]<=rxb_byte(5'd0); txb[3]<=rxb_byte(5'd1);
                    txb[4]<=rxb_byte(5'd2); txb[5]<=rxb_byte(5'd3); txb[6]<=rxb_byte(5'd4);
                    state <= CR0;
                end
            end

            // =============================================================
            // CRC CALCULATION  (over txb[0..6])
            // =============================================================
            CR0: begin rw<=1; ra<=CommandReg;    wd<=8'h00; ret<=CR1; state<=S0; end
            CR1: begin rw<=1; ra<=DivIrqReg;     wd<=8'h04; ret<=CR2; state<=S0; end
            CR2: begin rw<=1; ra<=FIFOLevelReg;   wd<=8'h80; ret<=CR3; idx<=0; state<=S0; end
            CR3: begin
                if (idx < 7) begin
                    rw<=1; ra<=FIFODataReg; wd<=txb[idx]; ret<=CR3;
                    idx<=idx+1; state<=S0;
                end else begin
                    rw<=1; ra<=CommandReg; wd<=8'h03; ret<=CR4;
                    tmo<=0; state<=S0;
                end
            end
            CR4: begin
                if (tmo >= TMO) state <= DONE_FAIL;
                else begin rw<=0; ra<=DivIrqReg; ret<=CR5; state<=S0; end
            end
            CR5: begin
                tmo <= tmo + 1;
                if (rd & 8'h04) begin
                    rw<=1; ra<=CommandReg; wd<=8'h00; ret<=CR6; state<=S0;
                end else state <= CR4;
            end
            CR6: begin rw<=0; ra<=CRCResultRegL; ret<=CR7; state<=S0; end
            CR7: begin crcl<=rd; rw<=0; ra<=CRCResultRegH; ret<=CR8; state<=S0; end
            CR8: begin crch<=rd; state<=CR9; end
            CR9: begin
                txb[7]<=crcl; txb[8]<=crch; txn<=9; bfv<=8'h00;
                tok<=SELDONE; tfail<=DONE_FAIL; state<=T_IDLE;
            end

            // SELECT done
            SELDONE: begin
                if (rxn < 3) state <= DONE_FAIL;
                else state <= RT0;
            end

            // =============================================================
            // RATS  (final part of rc_card_init)
            // =============================================================
            RT0: begin rw<=1; ra<=TxModeReg; wd<=8'h80; ret<=RT1; state<=S0; end
            RT1: begin rw<=1; ra<=RxModeReg; wd<=8'h00; ret<=RT2; state<=S0; end
            RT2: begin
                txb[0]<=8'hE0; txb[1]<=8'h50; txn<=2; bfv<=8'h00;
                tok<=RP0; tfail<=DONE_FAIL; state<=T_IDLE;
            end
            RP0: begin rw<=1; ra<=RxModeReg;     wd<=8'h80; ret<=RP1; state<=S0; end
            RP1: begin rw<=1; ra<=BitFramingReg;  wd<=8'h00; ret<=RP2; state<=S0; end
            RP2: begin rw<=1; ra<=TModeReg;       wd<=8'h8D; ret<=RP3; state<=S0; end
            RP3: begin rw<=1; ra<=TPrescalerReg;  wd<=8'h3E; ret<=RP_DLY; dly<=0; state<=S0; end
            RP_DLY: begin
                if (dly >= DLY10M) state <= DONE_OK;
                else dly <= dly + 1;
            end

            // =============================================================
            // I-Block: SELECT AID  (part of rc_read_id)
            // =============================================================
            IS0: begin rw<=1; ra<=FIFOLevelReg; wd<=8'h80; ret<=IS1; state<=S0; end
            IS1: begin
                txb[0] <= {7'd0, itgl} | 8'h02;
                txb[1] <= 8'h00; txb[2] <= 8'hA4; txb[3] <= 8'h04;
                txb[4] <= 8'h00; txb[5] <= 8'h06; txb[6] <= 8'hF0;
                txb[7] <= 8'h00; txb[8] <= 8'h00; txb[9] <= 8'h0C;
                txb[10]<= 8'hDC; txb[11]<= 8'h01;
                txn<=12; bfv<=8'h00;
                tok<=IS_CHK; tfail<=DONE_FAIL; state<=T_IDLE;
            end
            IS_CHK: begin
                if (rxn >= 3 && rxb_byte(rxn-2)==8'h90 && rxb_byte(rxn-1)==8'h00) begin
                    itgl <= ~itgl;
                    if (active_op == OP_AUTH_INIT)
                        state <= IA0;   // SELECT AID done, proceed to AUTH_INIT
                    else
                        state <= IG0;   // Original: proceed to GET_ID
                end else state <= DONE_FAIL;
            end

            // =============================================================
            // I-Block: GET_ID  (second part of rc_read_id)
            // =============================================================
            IG0: begin rw<=1; ra<=FIFOLevelReg; wd<=8'h80; ret<=IG1; state<=S0; end
            IG1: begin
                txb[0] <= {7'd0, itgl} | 8'h02;
                txb[1] <= 8'h80; txb[2] <= 8'h12;
                txb[3] <= 8'h00; txb[4] <= 8'h00; txb[5] <= 8'h10;
                txn<=6; bfv<=8'h00;
                tok<=IG_CHK; tfail<=DONE_FAIL; state<=T_IDLE;
            end
            IG_CHK: begin
                // Expect: PCB(1) + data(16) + SW1(90) + SW2(00) = 19 bytes min
                if (rxn >= 19 && rxb_byte(rxn-2)==8'h90 && rxb_byte(rxn-1)==8'h00) begin
                    itgl <= ~itgl; idx <= 0; state <= IG_CP2;
                end else state <= DONE_FAIL;
            end
            IG_CP: begin itgl<=~itgl; idx<=0; state<=IG_CP2; end
            IG_CP2: begin
                if (idx < 16) begin
                    cid_flat[127 - (idx[3:0] * 8) -: 8] <= rxb_byte(idx+1);
                    idx <= idx + 1;
                end else state <= DONE_OK;
            end

            // =============================================================
            // I-Block: AUTH_INIT (0x80 0x10)
            // Sends: PCB, CLA=0x80, INS=0x10, P1=0x00, P2=0x00, Le=0x10
            // Expects: PCB + 16 data bytes + SW1(90) + SW2(00)
            // =============================================================
            IA0: begin rw<=1; ra<=FIFOLevelReg; wd<=8'h80; ret<=IA1; state<=S0; end
            IA1: begin
                txb[0] <= {7'd0, itgl} | 8'h02;
                txb[1] <= 8'h80; txb[2] <= 8'h10;
                txb[3] <= 8'h00; txb[4] <= 8'h00; txb[5] <= 8'h10;
                txn<=6; bfv<=8'h00;
                tok<=IA_CHK; tfail<=DONE_FAIL; state<=T_IDLE;
            end
            IA_CHK: begin
                // Expect: PCB(1) + data(16) + SW1(90) + SW2(00) = 19 bytes min
                if (rxn >= 19 && rxb_byte(rxn-2)==8'h90 && rxb_byte(rxn-1)==8'h00) begin
                    itgl <= ~itgl; idx <= 0; state <= IA_CP;
                end else state <= DONE_FAIL;
            end
            IA_CP: begin
                // Copy 16 response bytes into cid[0..15]
                if (idx < 16) begin
                    cid_flat[127 - (idx[3:0] * 8) -: 8] <= rxb_byte(idx+1);
                    idx <= idx + 1;
                end else state <= DONE_OK;
            end

            // =============================================================
            // I-Block: AUTH (0x80 0x11)
            // Sends: PCB, CLA=0x80, INS=0x11, P1=0x00, P2=0x00, Lc=0x10,
            //        + 16 data bytes from rc_auth_data
            // Expects: PCB + SW1(90) + SW2(00) = 3 bytes min
            // =============================================================
            AU0: begin rw<=1; ra<=FIFOLevelReg; wd<=8'h80; ret<=AU1; state<=S0; end
            AU1: begin
                txb[0] <= {7'd0, itgl} | 8'h02;
                txb[1] <= 8'h80; txb[2] <= 8'h11;
                txb[3] <= 8'h00; txb[4] <= 8'h00; txb[5] <= 8'h10;
                // Unpack rc_auth_data[127:0] into txb[6..21]
                txb[6]  <= rc_auth_data[127:120];
                txb[7]  <= rc_auth_data[119:112];
                txb[8]  <= rc_auth_data[111:104];
                txb[9]  <= rc_auth_data[103:96];
                txb[10] <= rc_auth_data[95:88];
                txb[11] <= rc_auth_data[87:80];
                txb[12] <= rc_auth_data[79:72];
                txb[13] <= rc_auth_data[71:64];
                txb[14] <= rc_auth_data[63:56];
                txb[15] <= rc_auth_data[55:48];
                txb[16] <= rc_auth_data[47:40];
                txb[17] <= rc_auth_data[39:32];
                txb[18] <= rc_auth_data[31:24];
                txb[19] <= rc_auth_data[23:16];
                txb[20] <= rc_auth_data[15:8];
                txb[21] <= rc_auth_data[7:0];
                txn<=22; bfv<=8'h00;
                tok<=AU_CHK; tfail<=DONE_FAIL; state<=T_IDLE;
            end
            AU_CHK: begin
                // Expect: PCB + SW1(90) + SW2(00) = 3 bytes minimum
                if (rxn >= 3 && rxb_byte(rxn-2)==8'h90 && rxb_byte(rxn-1)==8'h00) begin
                    itgl <= ~itgl; state <= DONE_OK;
                end else state <= DONE_FAIL;
            end

            // =============================================================
            // TERMINAL STATES — signal completion back to external FSM
            // =============================================================
            DONE_OK: begin
                case (active_op)
                    OP_INIT: begin
                        rc_init_done <= 1'b1;
                    end
                    OP_POLL: begin
                        rc_poll_done       <= 1'b1;
                        rc_poll_card_found <= poll_found_latch;
                    end
                    OP_CARD_INIT: begin
                        rc_card_init_done    <= 1'b1;
                        rc_card_init_failure <= 1'b0;
                    end
                    OP_READ_ID: begin
                        rc_read_id_done    <= 1'b1;
                        rc_read_id_failure <= 1'b0;
                    end
                    OP_AUTH_INIT: begin
                        rc_auth_init_done    <= 1'b1;
                        rc_auth_init_failure <= 1'b0;
                    end
                    OP_AUTH: begin
                        rc_auth_done    <= 1'b1;
                        rc_auth_failure <= 1'b0;
                    end
                    default: ;
                endcase
                active_op <= OP_NONE;
                state     <= IDLE;
            end

            DONE_FAIL: begin
                case (active_op)
                    OP_POLL: begin
                        rc_poll_done       <= 1'b1;
                        rc_poll_card_found <= 1'b0;
                    end
                    OP_CARD_INIT: begin
                        rc_card_init_done    <= 1'b1;
                        rc_card_init_failure <= 1'b1;
                    end
                    OP_READ_ID: begin
                        rc_read_id_done    <= 1'b1;
                        rc_read_id_failure <= 1'b1;
                    end
                    OP_AUTH_INIT: begin
                        rc_auth_init_done    <= 1'b1;
                        rc_auth_init_failure <= 1'b1;
                    end
                    OP_AUTH: begin
                        rc_auth_done    <= 1'b1;
                        rc_auth_failure <= 1'b1;
                    end
                    default: ;
                endcase
                active_op <= OP_NONE;
                state     <= IDLE;
            end

            default: state <= IDLE;
            endcase
        end
    end

endmodule
