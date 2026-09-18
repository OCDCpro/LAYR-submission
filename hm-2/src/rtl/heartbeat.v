module heartbeat(
    input logic clk,
    output logic led
);

localparam COUNTER_TARGET = 100_000_000;
logic [31:0] counter;

always_ff @(posedge clk) begin
    if (counter == COUNTER_TARGET) begin
        led <= ~led;
        counter <= 0;
    end else begin
        counter <= counter + 1;
    end
end
endmodule
