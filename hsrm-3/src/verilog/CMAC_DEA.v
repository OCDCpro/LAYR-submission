// INCLUDES 
//`include "SPI_Master_With_Single_CS.v" 
//`include "AesIterative.v"
//`include "ASG.v"

/* verilator lint_off SYNCASYNCNET */
module cmac_handshake ( 
    input clk, 
    input rst, 
    input in, 
    output reg lock_state, // 0 = locked, 1 = unlocked
    // SPI Interface 
    output o_SPI_Clk, 
    input i_SPI_MISO, 
    output o_SPI_MOSI, 
    output o_SPI_CS_n
    );

// Internal wire so o_SPI_CS_n can be read back without Yosys
// complaining about an output port driving constant bits.
wire spi_cs_n_int;
assign o_SPI_CS_n = spi_cs_n_int;

// State definitions
localparam S0 = 3'b000; // IDLE 
localparam S1 = 3'b001; // REC_CHALLENGE -> start SPI transfer 
localparam S2 = 3'b010; // GEN_CHALLENGE 
localparam S3 = 3'b011; // STORE_EPH_KEY 
localparam S4 = 3'b100; // REQUEST_AUTH
localparam S5 = 3'b101; // KEYCARD_AUTHENTICATED
localparam S6 = 3'b110; // VALID_ID
localparam S7 = 3'b111; // UNLOCKED

// APDU class/instruction bytes
localparam CLA_PROPRIETARY = 8'h80;
localparam INS_AUTH_INIT   = 8'h10;
localparam INS_AUTH        = 8'h11;
localparam INS_GET_ID      = 8'h12;


// --- Control flags (all registers, driven only in clocked always block) ---
reg send_flag_1;
reg send_flag_2;
reg send_flag_3;
reg w_RX_DV_last_clk;
reg state2_flag0;
reg state2_flag1;
reg state2_flag2;
reg state2_flag3;
reg io_done_last_clk;
reg state3_flag1;
reg sampled_done_last_clk;
reg state3_flag2;
reg state3_flag3;
reg S4_done;
reg state4_flag1;
reg state4_flag2;
reg state4_flag3;
reg mAuthRes_valid;
reg state5_flag1;
reg state5_flag2;
reg state5_flag3;
reg is_decrypting;
reg is_buffering;
reg wait_for_mAuthRes_valid;
reg state6_flag1;
reg state6_flag2;
reg state6_flag3;
reg wait_for_valid_ID_valid;
reg [15:0] unlocked_timer;
reg state7_flag1;


reg [2:0] state;
reg [2:0] next_state;
reg       next_lock_state;

reg valid_ID;
reg [127:0] rec_ID;
reg [63:0]  rec_Challenge;
reg [127:0] cAuthCmd_dec;
reg [127:0] cAuthCmd_enc;
reg [127:0] ephKey;
reg [127:0] mAuthRes;
//                           "{  A U T H _ S U C C E S S 0 0 0 0 }"
reg [127:0] auth_success    = 128'h415554485F5355434345535300000000; 
reg [127:0] KeycardAvalidID = 128'hbbe8278a67f960605adafd6f63cf7ba7;
reg [127:0] preSharedKey    = 128'h39558d1f193656ab8b4b65e25ac48474; // KEYCARD KEY


// --- SPI signals ---
localparam MAX_BYTES_PER_CS = 2; 
wire w_TX_Ready; 
wire w_RX_DV; 
wire [7:0] w_RX_Byte; 
/* verilator lint_off UNUSEDSIGNAL */
wire [$clog2(MAX_BYTES_PER_CS+1)-1:0] w_RX_Count;
/* verilator lint_on UNUSEDSIGNAL */

reg [$clog2(MAX_BYTES_PER_CS+1)-1:0] i_TX_Count_reg;
reg [7:0]  i_TX_Byte_reg;
reg        i_TX_DV_reg;

reg [7:0] tx_buf [0:15];
reg [4:0] tx_len;
reg [4:0] tx_idx;   // 5-bit: matches tx_len, avoids WIDTHEXPAND on comparisons
reg [7:0] rx_buf [0:15];
integer   i;

reg [3:0] received_byte_count; // 4-bit: indexes rx_buf[15:0], avoids WIDTHEXPAND
reg [4:0] RX_large_received_byte_count;

// --- Instantiate SPI Master ---
SPI_Master_With_Single_CS
  #(.SPI_MODE(3),
    .CLKS_PER_HALF_BIT(5),
    .MAX_BYTES_PER_CS(MAX_BYTES_PER_CS),
    .CS_INACTIVE_CLKS(10))
spi_inst (
    .i_Rst_L(~rst),
    .i_Clk(clk),
    .i_TX_Count(i_TX_Count_reg),
    .i_TX_Byte(i_TX_Byte_reg),
    .i_TX_DV(i_TX_DV_reg),
    .o_TX_Ready(w_TX_Ready),
    .o_RX_Count(w_RX_Count),
    .o_RX_DV(w_RX_DV),
    .o_RX_Byte(w_RX_Byte),
    .o_SPI_Clk(o_SPI_Clk),
    .i_SPI_MISO(i_SPI_MISO),
    //.i_SPI_MISO(o_SPI_MOSI),  // !! changed for testing
    .o_SPI_MOSI(o_SPI_MOSI),
    .o_SPI_CS_n(spi_cs_n_int)
);


// --- AES ---
reg           io_start;
reg           io_decrypt;
reg  [127:0]  io_key;
reg  [127:0]  io_dataIn;
wire [127:0]  io_dataOut;
/* verilator lint_off UNUSEDSIGNAL */
wire          io_busy;
/* verilator lint_on UNUSEDSIGNAL */
wire          io_done;

AesIterative AES1 (
    io_start,
    io_decrypt,
    io_key,
    io_dataIn,
    io_dataOut,
    io_busy,
    io_done,
    clk,
    rst
);


// --- ASG ---
reg  [1:0] loadIt;
reg        load;
reg        enable;
wire       newBit;

ASG asg1 (
    loadIt,
    load,
    enable,
    newBit,
    clk,
    rst
);

reg        init_done;
reg  [5:0] count;
reg [63:0] own_Challenge;
reg        sampling;
reg        enable_sample;
reg        sampled_done;

// ASG seed constants
localparam integer R1_LEN = 20;
localparam [R1_LEN-1:0] R1_SEED = 20'b11101111011110111101;

localparam integer R2_LEN = 127;
localparam [R2_LEN-1:0] R2_SEED =
    127'b0110011001100110110101101011010110101101011010110101101011010001001001001001001001001;

localparam integer R3_LEN = 60;
localparam [R3_LEN-1:0] R3_SEED = {60{1'b1}};

// ASG init state machine — kept as separate enum-style parameter set
localparam [2:0] ASG_S_R1_CLEAR = 3'd0,
                 ASG_S_R1_LOAD  = 3'd1,
                 ASG_S_R2_CLEAR = 3'd2,
                 ASG_S_R2_LOAD  = 3'd3,
                 ASG_S_R3_CLEAR = 3'd4,
                 ASG_S_R3_LOAD  = 3'd5,
                 ASG_S_DONE     = 3'd6;

reg [2:0]  ASG_state;
reg [31:0] asg_idx;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ASG_state <= ASG_S_R1_CLEAR;
        asg_idx   <= 0;
        loadIt    <= 2'b00;
        load      <= 1'b0;
        enable    <= 1'b1;
        init_done <= 1'b0;
    end else begin
        case (ASG_state)

        ASG_S_R1_CLEAR: begin
            loadIt <= 2'b01;
            load   <= 1'b0;
            if (asg_idx == 31) begin
                asg_idx   <= 0;
                ASG_state <= ASG_S_R1_LOAD;
            end else
                asg_idx <= asg_idx + 1;
        end

        ASG_S_R1_LOAD: begin
            loadIt <= 2'b01;
            load   <= R1_SEED[R1_LEN-1-asg_idx];
            if (asg_idx == R1_LEN-1) begin
                asg_idx   <= 0;
                ASG_state <= ASG_S_R2_CLEAR;
            end else
                asg_idx <= asg_idx + 1;
        end

        ASG_S_R2_CLEAR: begin
            loadIt <= 2'b10;
            load   <= 1'b0;
            if (asg_idx == 127) begin
                asg_idx   <= 0;
                ASG_state <= ASG_S_R2_LOAD;
            end else
                asg_idx <= asg_idx + 1;
        end

        ASG_S_R2_LOAD: begin
            loadIt <= 2'b10;
            load   <= R2_SEED[R2_LEN-1-asg_idx];
            if (asg_idx == R2_LEN-1) begin
                asg_idx   <= 0;
                ASG_state <= ASG_S_R3_CLEAR;
            end else
                asg_idx <= asg_idx + 1;
        end

        ASG_S_R3_CLEAR: begin
            loadIt <= 2'b11;
            load   <= 1'b0;
            if (asg_idx == 89) begin
                asg_idx   <= 0;
                ASG_state <= ASG_S_R3_LOAD;
            end else
                asg_idx <= asg_idx + 1;
        end

        ASG_S_R3_LOAD: begin
            loadIt <= 2'b11;
            load   <= R3_SEED[R3_LEN-1-asg_idx];
            if (asg_idx == R3_LEN-1)
                ASG_state <= ASG_S_DONE;
            else
                asg_idx <= asg_idx + 1;
        end

        ASG_S_DONE: begin
            loadIt    <= 2'b00;
            load      <= 1'b0;
            init_done <= 1'b1;
        end

        default: ASG_state <= ASG_S_R1_CLEAR;
        endcase
    end
end


// =========================================================================
// State register
// =========================================================================
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state      <= S0;
        lock_state <= 1'b0;
    end else begin
        state      <= next_state;
        lock_state <= next_lock_state;
    end
end

// =========================================================================
// Next-state logic — PURELY combinatorial, no reg assignments, no side effects
// All signals driven here must be registered elsewhere or be next_* wires.
// =========================================================================
always @(*) begin
    // Default: stay in current state
    next_state      = state;
    next_lock_state = lock_state;

    case (state)
        S0: begin
            next_lock_state = 1'b0;
            if (in)
                next_state = S1;
        end

        S1: begin
            if (spi_cs_n_int && w_RX_DV_last_clk && state2_flag0)
                next_state = S2;
        end

        S2: begin
            if (!io_done && io_done_last_clk && state2_flag1)
                next_state = S3;
        end

        S3: begin
            if (!sampled_done && sampled_done_last_clk && state3_flag1)
                next_state = S4;
        end

        S4: begin
            if (spi_cs_n_int && S4_done && state4_flag3)
                next_state = S5;
        end

        S5: begin
            if (!io_done && io_done_last_clk && state5_flag3) begin
                if (wait_for_mAuthRes_valid) begin
                    if (mAuthRes_valid)
                        next_state = S6;
                    else
                        next_state = S0;
                end
            end
        end

        S6: begin
            if (!io_done && io_done_last_clk && state6_flag1) begin
                if (wait_for_valid_ID_valid) begin
                    if (valid_ID)
                        next_state = S7;
                    else
                        next_state = S0;
                end
            end
        end

        S7: begin
            next_lock_state = 1'b1;
            if (state7_flag1 && (unlocked_timer == 16'hFFFF))
                next_state = S0;
        end

        default: next_state = S0;
    endcase
end


// =========================================================================
// Clocked datapath & flag logic
// =========================================================================
always @(posedge clk or posedge rst) begin
    if (rst) begin
        for (i = 0; i < 16; i = i + 1) tx_buf[i] <= 8'h00;
        for (i = 0; i < 16; i = i + 1) rx_buf[i] <= 8'h00;

        tx_idx         <= 5'd0;
        tx_len                    <= 5'd0;
        i_TX_DV_reg               <= 1'b0;
        i_TX_Byte_reg             <= 8'h00;
        i_TX_Count_reg            <= 2'd0;
        received_byte_count <= 4'd0;
        RX_large_received_byte_count <= 5'd0;
        unlocked_timer            <= 16'd0;

        send_flag_1               <= 1'b0;
        send_flag_2               <= 1'b0;
        send_flag_3               <= 1'b0;
        w_RX_DV_last_clk          <= 1'b0;
        state2_flag0              <= 1'b0;
        state2_flag1              <= 1'b0;
        state2_flag2              <= 1'b0;
        state2_flag3              <= 1'b0;
        io_done_last_clk          <= 1'b0;
        state3_flag1              <= 1'b0;
        sampled_done_last_clk     <= 1'b0;
        state3_flag2              <= 1'b0;
        state3_flag3              <= 1'b0;
        S4_done                   <= 1'b0;
        state4_flag1              <= 1'b0;
        state4_flag2              <= 1'b0;
        state4_flag3              <= 1'b0;
        mAuthRes_valid            <= 1'b0;
        state5_flag1              <= 1'b0;
        state5_flag2              <= 1'b0;
        state5_flag3              <= 1'b0;
        is_decrypting             <= 1'b0;
        is_buffering              <= 1'b0;
        wait_for_mAuthRes_valid   <= 1'b0;
        state6_flag1              <= 1'b0;
        state6_flag2              <= 1'b0;
        state6_flag3              <= 1'b0;
        wait_for_valid_ID_valid   <= 1'b0;
        state7_flag1              <= 1'b0;
        enable_sample             <= 1'b0;
        valid_ID                  <= 1'b0;

        io_start                  <= 1'b0;
        io_decrypt                <= 1'b0;
        io_key                    <= 128'd0;
        io_dataIn                 <= 128'd0;

        sampling                  <= 1'b0;
        count                     <= 6'd0;
        own_Challenge             <= 64'd0;
        sampled_done              <= 1'b0;

        rec_Challenge             <= 64'd0;
        cAuthCmd_dec              <= 128'd0;
        cAuthCmd_enc              <= 128'd0;
        ephKey                    <= 128'd0;
        mAuthRes                  <= 128'd0;
        rec_ID                    <= 128'd0;

    end else begin

        // ------------------------------------------------------------------
        // S0 -> S1 : Load INS_AUTH_INIT header into TX buffer
        // ------------------------------------------------------------------
        if (state == S0 && next_state == S1) begin
            tx_buf[0]      <= CLA_PROPRIETARY;
            tx_buf[1]      <= INS_AUTH_INIT;
            tx_buf[2]      <= 8'h00;
            tx_buf[3]      <= 8'h00;
            tx_len         <= 5'd4;
            tx_idx         <= 5'd0;
            i_TX_Count_reg <= 2'd2; // MAX_BYTES_PER_CS width
            received_byte_count <= 4'd0;
        end

        // ------------------------------------------------------------------
        // S1 : Capture RX bytes
        // ------------------------------------------------------------------
        if (state == S1 && w_RX_DV) begin
            w_RX_DV_last_clk                    <= 1'b1;
            rx_buf[received_byte_count]         <= w_RX_Byte;
            received_byte_count                 <= received_byte_count + 1'b1;
        end

        // S1 : Set state2_flag0 to gate S1->S2 transition
        if (state == S1 && spi_cs_n_int && w_RX_DV_last_clk && !state2_flag0) begin
            state2_flag0 <= 1'b1;
        end
        // S1->S2 cleanup
        if (state == S1 && next_state == S2) begin
            w_RX_DV_last_clk <= 1'b0;
            state2_flag0     <= 1'b0;
        end

        // S1 : Send INS_AUTH_INIT bytes
        if (state == S1 && w_TX_Ready && (tx_idx < tx_len)) begin
            if (send_flag_1) begin
                if (!send_flag_2) begin
                    send_flag_2 <= 1'b1;
                end else begin
                    i_TX_Byte_reg  <= tx_buf[tx_idx[3:0]];
                    i_TX_Count_reg <= i_TX_Count_reg; // already set
                    i_TX_DV_reg    <= 1'b1;
                    tx_idx         <= tx_idx + 1'b1;
                end
            end else begin
                send_flag_1 <= 1'b1;
            end
        end else if (state == S1 && send_flag_1 && send_flag_2) begin
            if (!send_flag_3) begin
                send_flag_3 <= 1'b1;
            end else begin
                i_TX_DV_reg <= 1'b0;
                send_flag_1 <= 1'b0;
                send_flag_2 <= 1'b0;
                send_flag_3 <= 1'b0;
            end
        end

        // ------------------------------------------------------------------
        // S2 : Decrypt 16-byte challenge
        // ------------------------------------------------------------------
        if (state == S2 && next_state == S2) begin
            if (!state2_flag2) begin
                io_dataIn[7:0]     <= rx_buf[0];
                io_dataIn[15:8]    <= rx_buf[1];
                io_dataIn[23:16]   <= rx_buf[2];
                io_dataIn[31:24]   <= rx_buf[3];
                io_dataIn[39:32]   <= rx_buf[4];
                io_dataIn[47:40]   <= rx_buf[5];
                io_dataIn[55:48]   <= rx_buf[6];
                io_dataIn[63:56]   <= rx_buf[7];
                io_dataIn[71:64]   <= rx_buf[8];
                io_dataIn[79:72]   <= rx_buf[9];
                io_dataIn[87:80]   <= rx_buf[10];
                io_dataIn[95:88]   <= rx_buf[11];
                io_dataIn[103:96]  <= rx_buf[12];
                io_dataIn[111:104] <= rx_buf[13];
                io_dataIn[119:112] <= rx_buf[14];
                io_dataIn[127:120] <= rx_buf[15];
                io_key             <= preSharedKey;
                io_decrypt         <= 1'b1;
                io_start           <= 1'b1;
                state2_flag2       <= 1'b1;
            end else begin
                io_start <= 1'b0;
                if (!state2_flag3) begin
                    state2_flag3 <= 1'b1;
                end else begin
                    if (io_done) begin
                        io_done_last_clk   <= 1'b1;
                        rx_buf[0]          <= io_dataOut[7:0];
                        rx_buf[1]          <= io_dataOut[15:8];
                        rx_buf[2]          <= io_dataOut[23:16];
                        rx_buf[3]          <= io_dataOut[31:24];
                        rx_buf[4]          <= io_dataOut[39:32];
                        rx_buf[5]          <= io_dataOut[47:40];
                        rx_buf[6]          <= io_dataOut[55:48];
                        rx_buf[7]          <= io_dataOut[63:56];
                        rx_buf[8]          <= io_dataOut[71:64];
                        rx_buf[9]          <= io_dataOut[79:72];
                        rx_buf[10]         <= io_dataOut[87:80];
                        rx_buf[11]         <= io_dataOut[95:88];
                        rx_buf[12]         <= io_dataOut[103:96];
                        rx_buf[13]         <= io_dataOut[111:104];
                        rx_buf[14]         <= io_dataOut[119:112];
                        rx_buf[15]         <= io_dataOut[127:120];
                        rec_Challenge[63:0]<= io_dataOut[127:64];
                        state2_flag2       <= 1'b0;
                        state2_flag3       <= 1'b0;
                    end
                end
            end
        end

        // S2 flag gate for S2->S3
        if (state == S2 && !io_done && io_done_last_clk && !state2_flag1) begin
            state2_flag1 <= 1'b1;
        end
        // S2->S3 cleanup
        if (state == S2 && next_state == S3) begin
            io_done_last_clk <= 1'b0;
            enable_sample    <= 1'b1;
            state2_flag1     <= 1'b0;
            io_decrypt       <= 1'b0;
        end

        // ------------------------------------------------------------------
        // S3.1 : Generate own 8-byte challenge via ASG
        // ------------------------------------------------------------------
        if (state == S3 && next_state == S3 && init_done) begin
            //$display("S3: init_done");
            if (!sampling) begin
                sampled_done <= 1'b0;
                if (enable_sample) begin
                    sampling      <= 1'b1;
                    count         <= 6'd0;
                    own_Challenge <= 64'h0;
                end
            end else begin
                own_Challenge <= {own_Challenge[62:0], newBit};
                if (count == 6'd63) begin
                    sampling      <= 1'b0;
                    sampled_done  <= 1'b1;
                    count         <= 6'd0;
                    enable_sample <= 1'b0;
                    // init_done stays asserted; enable_sample will be cleared below
                    //sampled_done_last_clk <= 1'b1;
                end else begin
                    count <= count + 6'd1;
                end
            end
        end

        // S3.2 : Build cAuthCmd_dec
        if (state == S3 && next_state == S3 && sampled_done) begin
            //$display("S3: sampled_done");

            cAuthCmd_dec[127:64]   <= rec_Challenge;
            cAuthCmd_dec[63:0]     <= own_Challenge;
            state3_flag2           <= 1'b1;
            sampled_done           <= 1'b0;
        end

        // S3.3 : Encrypt cAuthCmd_dec
        if (state == S3 && next_state == S3 && state3_flag2) begin
            //$display("S3: state3_flag2");
            io_dataIn  <= cAuthCmd_dec;
            io_key     <= preSharedKey;
            io_decrypt <= 1'b0;
            io_start   <= 1'b1;
            //$display("[0%t] S3: io_start   <= 1'b1;  %X", $time, io_start);
            state3_flag2 <= 1'b0;
            state3_flag3 <= 1'b1;
        end

        // S3.4 : Deassert io_start
        if (state == S3 && next_state == S3 && state3_flag3) begin
            //$display("S3: state3_flag3");
            io_start     <= 1'b0;
            //$display("[0%t] S3: io_start   <= 1'b0;  %X", $time, io_start);
            //state3_flag3 <= 1'b0;
        end

        // S3.5 : Store encrypted cAuthCmd_enc
        if (state == S3 && next_state == S3 && io_done && state3_flag3) begin
            //$display("S3: io_done");
            cAuthCmd_enc          <= io_dataOut;
            state3_flag3 <= 1'b0;
            sampled_done_last_clk <= 1'b1;
        end

        // S3 flag gate for S3->S4
        if (state == S3 && !sampled_done && sampled_done_last_clk && !state3_flag1) begin
            //$display("S3: whatever the funk");
            state3_flag1 <= 1'b1;
        end
        // S3->S4 cleanup
        if (state == S3 && next_state == S4) begin
            sampled_done_last_clk <= 1'b0;
            state3_flag1          <= 1'b0;
            for (i = 0; i < 16; i = i + 1) rx_buf[i] <= 8'h00;
            tx_buf[0]      <= CLA_PROPRIETARY;
            tx_buf[1]      <= INS_AUTH;
            tx_buf[2]      <= 8'h00;
            tx_buf[3]      <= 8'h00;
            tx_len         <= 5'd4;
            tx_idx         <= 5'd0;
            i_TX_Count_reg <= 2'd2;
            state4_flag2   <= 1'b0;
        end

        // ------------------------------------------------------------------
        // S4 : Send INS_AUTH header + cAuthCmd, receive cAuthRes
        // ------------------------------------------------------------------

        // S4 send header bytes
        if (state == S4 && next_state == S4 && w_TX_Ready && (tx_idx < tx_len)) begin
            if (send_flag_1) begin
                if (!send_flag_2) begin
                    send_flag_2 <= 1'b1;
                end else begin
                    i_TX_Byte_reg  <= tx_buf[tx_idx[3:0]];
                    i_TX_DV_reg    <= 1'b1;
                    tx_idx         <= tx_idx + 1'b1;
                end
            end else begin
                send_flag_1 <= 1'b1;
            end
        end else if (state == S4 && send_flag_1 && send_flag_2) begin
            if (!send_flag_3) begin
                send_flag_3 <= 1'b1;
            end else begin
                i_TX_DV_reg <= 1'b0;
                send_flag_1 <= 1'b0;
                send_flag_2 <= 1'b0;
                send_flag_3 <= 1'b0;
                if (tx_idx == tx_len && !state4_flag2 && state == S4) begin
                    state4_flag1 <= 1'b1;
                end
            end
        end

        // S4 : Receive cAuthRes bytes
        if (state == S4 && next_state == S4 && w_RX_DV && state4_flag2) begin
            if (tx_idx == 16) begin
                S4_done      <= 1'b1;
                state4_flag2 <= 1'b0;
            end
            rx_buf[RX_large_received_byte_count - 1] <= w_RX_Byte;
            RX_large_received_byte_count             <= RX_large_received_byte_count + 1'b1;
        end

        // S4 : Build cAuthCmd payload
        if (state == S4 && next_state == S4 && state4_flag1) begin
            tx_buf[0]  <= cAuthCmd_enc[7:0];
            tx_buf[1]  <= cAuthCmd_enc[15:8];
            tx_buf[2]  <= cAuthCmd_enc[23:16];
            tx_buf[3]  <= cAuthCmd_enc[31:24];
            tx_buf[4]  <= cAuthCmd_enc[39:32];
            tx_buf[5]  <= cAuthCmd_enc[47:40];
            tx_buf[6]  <= cAuthCmd_enc[55:48];
            tx_buf[7]  <= cAuthCmd_enc[63:56];
            tx_buf[8]  <= cAuthCmd_enc[71:64];
            tx_buf[9]  <= cAuthCmd_enc[79:72];
            tx_buf[10] <= cAuthCmd_enc[87:80];
            tx_buf[11] <= cAuthCmd_enc[95:88];
            tx_buf[12] <= cAuthCmd_enc[103:96];
            tx_buf[13] <= cAuthCmd_enc[111:104];
            tx_buf[14] <= cAuthCmd_enc[119:112];
            tx_buf[15] <= cAuthCmd_enc[127:120];
            tx_len         <= 5'd16;
            tx_idx         <= 5'd0;
            i_TX_Count_reg <= 2'd2;
            state4_flag1   <= 1'b0;
            state4_flag2   <= 1'b1;
        end

        // S4 flag gate for S4->S5
        if (state == S4 && spi_cs_n_int && S4_done && !state4_flag3) begin
            state4_flag3 <= 1'b1;
        end
        // S4->S5 cleanup
        if (state == S4 && next_state == S5) begin
            S4_done                      <= 1'b0;
            state4_flag3                 <= 1'b0;
            state4_flag2                 <= 1'b0;
            RX_large_received_byte_count <= 5'd0;
        end

        // ------------------------------------------------------------------
        // S5.1 : Build ephKey
        // ------------------------------------------------------------------
        if (state == S5 && next_state == S5 && ~mAuthRes_valid) begin
            //$display("S5 start");
            ephKey[127:64] <= own_Challenge[63:0];
            ephKey[63:0]   <= rec_Challenge[63:0];
            state5_flag1   <= 1'b1;
        end

        // S5.2 : Decrypt cAuthRes using ephKey
        if (state == S5 && next_state == S5 && state5_flag1) begin
            //$display("S5 state5_flag1");
            if (!is_decrypting) begin
                //$display("ephKey: %X", ephKey);
                io_dataIn[7:0]     <= rx_buf[0];
                io_dataIn[15:8]    <= rx_buf[1];
                io_dataIn[23:16]   <= rx_buf[2];
                io_dataIn[31:24]   <= rx_buf[3];
                io_dataIn[39:32]   <= rx_buf[4];
                io_dataIn[47:40]   <= rx_buf[5];
                io_dataIn[55:48]   <= rx_buf[6];
                io_dataIn[63:56]   <= rx_buf[7];
                io_dataIn[71:64]   <= rx_buf[8];
                io_dataIn[79:72]   <= rx_buf[9];
                io_dataIn[87:80]   <= rx_buf[10];
                io_dataIn[95:88]   <= rx_buf[11];
                io_dataIn[103:96]  <= rx_buf[12];
                io_dataIn[111:104] <= rx_buf[13];
                io_dataIn[119:112] <= rx_buf[14];
                io_dataIn[127:120] <= rx_buf[15];

                    //io_dataIn <= 128'Hf226f408245529a5f71722a242eb87d3; // !! test dings

                io_key             <= ephKey;
                io_decrypt         <= 1'b1;
                io_start           <= 1'b1;
                is_decrypting      <= 1'b1;
            end else begin
                io_start <= 1'b0;
                if (!is_buffering) begin
                    is_buffering <= 1'b1;
                end else begin
                    if (io_done) begin
                        io_done_last_clk   <= 1'b1;
                        rx_buf[0]          <= io_dataOut[7:0];
                        rx_buf[1]          <= io_dataOut[15:8];
                        rx_buf[2]          <= io_dataOut[23:16];
                        rx_buf[3]          <= io_dataOut[31:24];
                        rx_buf[4]          <= io_dataOut[39:32];
                        rx_buf[5]          <= io_dataOut[47:40];
                        rx_buf[6]          <= io_dataOut[55:48];
                        rx_buf[7]          <= io_dataOut[63:56];
                        rx_buf[8]          <= io_dataOut[71:64];
                        rx_buf[9]          <= io_dataOut[79:72];
                        rx_buf[10]         <= io_dataOut[87:80];
                        rx_buf[11]         <= io_dataOut[95:88];
                        rx_buf[12]         <= io_dataOut[103:96];
                        rx_buf[13]         <= io_dataOut[111:104];
                        rx_buf[14]         <= io_dataOut[119:112];
                        rx_buf[15]         <= io_dataOut[127:120];
                        mAuthRes[127:0]    <= io_dataOut[127:0];
                        is_decrypting      <= 1'b0;
                        is_buffering       <= 1'b0;
                        state5_flag1       <= 1'b0;
                        state5_flag2       <= 1'b1;
                    end
                end
            end
        end

        // S5.3 : Validate mAuthRes plaintext
        if (state == S5 && next_state == S5 && state5_flag2) begin
            //$display("S5 state5_flag2");
            if (mAuthRes == auth_success) begin
                //$display("valid mAuthRes");
                mAuthRes_valid <= 1'b1;
            end
            else begin
                //$display("invalid mAuthRes");
                mAuthRes_valid <= 1'b0;
            end
            state5_flag2 <= 1'b0;
        end

        // S5 flag gate for S5->S6/S0
        if (state == S5 && !io_done && io_done_last_clk && !state5_flag3) begin
            //$display("S5 weird shit");
            state5_flag1 <= 1'b0;
            state5_flag3 <= 1'b1;
        end
        if (state == S5 && !io_done && io_done_last_clk && state5_flag3 && !wait_for_mAuthRes_valid) begin
            //$display("S5 state5_flag3");
            wait_for_mAuthRes_valid <= 1'b1;
        end
        // S5->S6 or S5->S0 cleanup
        if (state == S5 && (next_state == S6 || next_state == S0)) begin
            //$display("S5 cleanup");
            io_done_last_clk        <= 1'b0;
            wait_for_mAuthRes_valid <= 1'b0;
            state5_flag3            <= 1'b0;
            io_decrypt              <= 1'b0;
            io_start                <= 1'b0;
        end

        // S5->S6 : Load INS_GET_ID into TX buffer
        if (state == S5 && next_state == S6) begin
            for (i = 0; i < 16; i = i + 1) rx_buf[i] <= 8'h00;
            for (i = 0; i < 16; i = i + 1) tx_buf[i] <= 8'h00;
            tx_buf[0]      <= CLA_PROPRIETARY;
            tx_buf[1]      <= INS_GET_ID;
            tx_buf[2]      <= 8'h00;
            tx_buf[3]      <= 8'h00;
            tx_len         <= 5'd4;
            tx_idx         <= 5'd0;
            i_TX_Count_reg <= 2'd2;
            RX_large_received_byte_count <= 5'd0;
        end

        // ------------------------------------------------------------------
        // S6 : Send INS_GET_ID, receive and decrypt rec_ID
        // ------------------------------------------------------------------

        // S6 : Receive encrypted ID bytes
        if (state == S6 && w_RX_DV) begin
            w_RX_DV_last_clk                             <= 1'b1;
            rx_buf[RX_large_received_byte_count - 1]     <= w_RX_Byte;
            RX_large_received_byte_count                 <= RX_large_received_byte_count + 1'b1;
        end

        // S6 : Transmit INS_GET_ID command
        if (state == S6 && next_state == S6 && w_TX_Ready && (tx_idx < tx_len)) begin
            if (send_flag_1) begin
                if (!send_flag_2) begin
                    send_flag_2 <= 1'b1;
                end else begin
                    i_TX_Byte_reg  <= tx_buf[tx_idx[3:0]];
                    i_TX_Count_reg <= i_TX_Count_reg;
                    i_TX_DV_reg    <= 1'b1;
                    tx_idx         <= tx_idx + 1'b1;
                end
            end else begin
                send_flag_1 <= 1'b1;
            end
        end else if (state == S6 && send_flag_1 && send_flag_2) begin
            if (!send_flag_3) begin
                send_flag_3 <= 1'b1;
            end else begin
                i_TX_DV_reg  <= 1'b0;
                send_flag_1  <= 1'b0;
                send_flag_2  <= 1'b0;
                send_flag_3  <= 1'b0;
                state6_flag2 <= 1'b1;
            end
        end

        // S6.2 : Decrypt rec_ID_enc using ephKey
        if (state == S6 && next_state == S6 && state6_flag2) begin
            if (!is_decrypting) begin
                io_dataIn[7:0]     <= rx_buf[0];
                io_dataIn[15:8]    <= rx_buf[1];
                io_dataIn[23:16]   <= rx_buf[2];
                io_dataIn[31:24]   <= rx_buf[3];
                io_dataIn[39:32]   <= rx_buf[4];
                io_dataIn[47:40]   <= rx_buf[5];
                io_dataIn[55:48]   <= rx_buf[6];
                io_dataIn[63:56]   <= rx_buf[7];
                io_dataIn[71:64]   <= rx_buf[8];
                io_dataIn[79:72]   <= rx_buf[9];
                io_dataIn[87:80]   <= rx_buf[10];
                io_dataIn[95:88]   <= rx_buf[11];
                io_dataIn[103:96]  <= rx_buf[12];
                io_dataIn[111:104] <= rx_buf[13];
                io_dataIn[119:112] <= rx_buf[14];
                io_dataIn[127:120] <= rx_buf[15];

                    //io_dataIn <= 128'Hc2ddfe589a4d58582e05c149f97ae49d; /// !! test

                io_key             <= ephKey;
                io_decrypt         <= 1'b1;
                io_start           <= 1'b1;
                is_decrypting      <= 1'b1;
            end else begin
                io_start <= 1'b0;
                if (!is_buffering) begin
                    is_buffering <= 1'b1;
                end else begin
                    if (io_done) begin
                        io_done_last_clk <= 1'b1;
                        rec_ID[127:0]    <= io_dataOut[127:0];
                        is_decrypting    <= 1'b0;
                        is_buffering     <= 1'b0;
                        state6_flag2     <= 1'b0;
                        state6_flag3     <= 1'b1;
                    end
                end
            end
        end

        // S6.3 : Validate rec_ID
        if (state == S6 && next_state == S6 && state6_flag3) begin
            if (rec_ID == KeycardAvalidID) begin
                //$display("valid KeyCard A");
                valid_ID <= 1'b1;
            end
            else begin
                //$display("invalid KeyCard");
                valid_ID <= 1'b0;
            end
            state6_flag3 <= 1'b0;
        end

        // S6 flag gate for S6->S7/S0
        if (state == S6 && !io_done && io_done_last_clk && !state6_flag1) begin
            state6_flag1 <= 1'b1;
        end
        if (state == S6 && !io_done && io_done_last_clk && state6_flag1 && !wait_for_valid_ID_valid) begin
            wait_for_valid_ID_valid <= 1'b1;
        end
        // S6->S7 or S6->S0 cleanup
        if (state == S6 && (next_state == S7 || next_state == S0)) begin
            io_done_last_clk        <= 1'b0;
            wait_for_valid_ID_valid <= 1'b0;
            state6_flag1            <= 1'b0;
        end

        // ------------------------------------------------------------------
        // S7 : Unlocked — count down timer
        // ------------------------------------------------------------------
        if (state == S7) begin
            if (!state7_flag1) begin
                state7_flag1   <= 1'b1;
                unlocked_timer <= 16'd0;
            end else if (unlocked_timer == 16'hFFFF) begin
                state7_flag1   <= 1'b0;
                unlocked_timer <= 16'd0;
            end else begin
                unlocked_timer <= unlocked_timer + 1'b1;
            end
        end

    end // else (not rst)
end

endmodule
/* verilator lint_on SYNCASYNCNET */
