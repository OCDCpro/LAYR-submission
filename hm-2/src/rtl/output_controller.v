module output_controller(
    input [2:0] state,
    output busy,
    output fault,
    output unlock
);

    localparam IDLE = 3'b00;
    localparam BUSY = 3'b01;
    localparam FAULT = 3'b10;
    localparam UNLOCK = 3'b11;
    localparam RESET = 3'b100;

    assign busy   = (state == BUSY || state == RESET);
    assign fault  = (state == FAULT || state == RESET);
    assign unlock = (state == UNLOCK);

endmodule
