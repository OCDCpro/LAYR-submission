module out_fsm(
    input logic [3:0] main_state,
    output logic [2:0] out_state
);

localparam OUT_IDLE = 3'b00;
localparam OUT_BUSY = 3'b01;
localparam OUT_FAULT = 3'b10;
localparam OUT_UNLOCK = 3'b11;
localparam OUT_RESET = 3'b100;


localparam IN_BOOT = 4'b0000;
localparam IN_CACHE_EEPROM = 4'b0001;
localparam IN_INIT_RC = 4'b0010;
localparam IN_IDLE = 4'b0011;
localparam IN_CARD_INIT = 4'b0100;
localparam IN_READ_ID = 4'b0101;
localparam IN_CHECK_ID = 4'b0110;
localparam IN_TIMEOUT_DENY = 4'b0111;
localparam IN_TIMEOUT_SUCCESS = 4'b1000;
localparam IN_SOFT_RESET = 4'b1001;

always_comb begin
    case(main_state)
        IN_BOOT: out_state = OUT_RESET;
        IN_CACHE_EEPROM: out_state = OUT_RESET;
        IN_INIT_RC: out_state = OUT_RESET;
        IN_IDLE: out_state = OUT_IDLE;
        IN_CARD_INIT: out_state = OUT_BUSY;
        IN_READ_ID: out_state = OUT_BUSY;
        IN_CHECK_ID: out_state = OUT_BUSY;
        IN_TIMEOUT_DENY: out_state = OUT_FAULT;
        IN_TIMEOUT_SUCCESS: out_state = OUT_UNLOCK;
        IN_SOFT_RESET: out_state = OUT_RESET;
        default: out_state = OUT_IDLE;
    endcase
end


endmodule
