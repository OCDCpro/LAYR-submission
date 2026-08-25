module LSFR_1 (
  input  wire          load,
  input  wire          loadIt,
  input  wire          enable,
  output wire          newBit,
  input  wire          clk,
  input  wire          reset
);

  wire       [126:0]  fsRegN;
  reg        [126:0]  fsReg;
  wire                taps_0;
  wire                taps_1;
  reg                 genBit;

  assign taps_0 = fsReg[0];
  assign taps_1 = fsReg[126];
  always @(*) begin
    genBit = (taps_0 ^ taps_1);
    if(loadIt) begin
      genBit = load;
    end
  end

  assign newBit = fsReg[0];
  assign fsRegN = {genBit,fsReg[126 : 1]};
  always @(posedge clk) begin
    if(reset) begin
      fsReg <= 127'h0;
    end else begin
      if(enable) begin
        fsReg <= fsRegN;
      end
    end
  end


endmodule

