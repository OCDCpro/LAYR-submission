// ============================================================================
// LFSR-64 — maximal-length 64-bit PRNG for challenge generation
//
// Polynomial: x^64 + x^63 + x^61 + x^60 + 1  (maximal length)
// Free-runs every clock cycle. Sample output when needed for rt.
// Seeded with a non-zero constant (all-zeros is a lockup state).
// ============================================================================
module lfsr64 (
    input  wire        clk,
    input  wire        rst,
    output wire [63:0] rng_out
);

    reg [63:0] lfsr;

    assign rng_out = lfsr;

    wire feedback = lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59];

    always @(posedge clk) begin
        if (rst)
            lfsr <= 64'hDEAD_BEEF_CAFE_BABE;   // non-zero seed
        else
            lfsr <= {lfsr[62:0], feedback};
    end

endmodule
