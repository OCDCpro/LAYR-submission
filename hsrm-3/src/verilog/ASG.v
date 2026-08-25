`include "LSFR_2.v"
`include "LSFR_1.v"
`include "LSFR.v"



module ASG (
  input  wire [1:0]    loadIt,
  input  wire          load,
  input  wire          enable,
  output wire          newBit,
  input  wire          clk,
  input  wire          reset
);

  wire                R1_enable;
  wire                R2_enable;
  wire                R3_enable;
  wire                R1_newBit;
  wire                R2_newBit;
  wire                R3_newBit;
  wire                loadR1;
  wire                loadR2;
  wire                loadR3;

  LSFR R1 (
    .load   (load     ), //i
    .loadIt (loadR1   ), //i
    .enable (R1_enable), //i
    .newBit (R1_newBit), //o
    .clk    (clk      ), //i
    .reset  (reset    )  //i
  );
  LSFR_1 R2 (
    .load   (load     ), //i
    .loadIt (loadR2   ), //i
    .enable (R2_enable), //i
    .newBit (R2_newBit), //o
    .clk    (clk      ), //i
    .reset  (reset    )  //i
  );
  LSFR_2 R3 (
    .load   (load     ), //i
    .loadIt (loadR3   ), //i
    .enable (R3_enable), //i
    .newBit (R3_newBit), //o
    .clk    (clk      ), //i
    .reset  (reset    )  //i
  );
  assign loadR1 = (loadIt == 2'b01);
  assign loadR2 = (loadIt == 2'b10);
  assign loadR3 = (loadIt == 2'b11);
  assign R1_enable = (enable || loadR1);
  assign R2_enable = ((enable && R1_newBit) || loadR2);
  assign R3_enable = ((enable && (! R1_newBit)) || loadR3);
  assign newBit = (R2_newBit ^ R3_newBit);

endmodule

