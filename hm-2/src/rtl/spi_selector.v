// ============================================================================
// SPI Bus Selector — muxes SPI signals between RC522 and EEPROM
//
// device_select encoding:
//   00 = NONE    — bus idle, both CS high
//   01 = RC522   — route RC controller SPI to physical bus
//   10 = EEPROM  — route EEPROM controller SPI to physical bus
// ============================================================================
module spi_selector (
    input  wire [1:0] device_select,

    // --- RC522 controller side ---
    input  wire       rc_mosi,
    output reg        rc_miso,
    input  wire       rc_sclk,
    input  wire       rc_cs_n,

    // --- EEPROM controller side ---
    input  wire       eeprom_mosi,
    output reg        eeprom_miso,
    input  wire       eeprom_sclk,
    input  wire       eeprom_cs_n,

    // --- Physical SPI bus ---
    output reg        spi_mosi,
    input  wire       spi_miso,
    output reg        spi_sclk,
    output reg        spi_cs_n_rc,
    output reg        spi_cs_n_eeprom
);

    localparam [1:0]
        DEVICE_NONE   = 2'b00,
        DEVICE_RC     = 2'b01,
        DEVICE_EEPROM = 2'b10;

    always_comb begin
        // Defaults — bus idle, both deselected
        spi_mosi        = 1'b0;
        spi_sclk        = 1'b0;
        rc_miso         = 1'b0;
        eeprom_miso     = 1'b0;
        spi_cs_n_rc     = 1'b1;
        spi_cs_n_eeprom = 1'b1;

        case (device_select)
            DEVICE_RC: begin
                spi_mosi        = rc_mosi;
                spi_sclk        = rc_sclk;
                rc_miso         = spi_miso;
                spi_cs_n_rc     = rc_cs_n;
            end
            DEVICE_EEPROM: begin
                spi_mosi        = eeprom_mosi;
                spi_sclk        = eeprom_sclk;
                eeprom_miso     = spi_miso;
                spi_cs_n_eeprom = eeprom_cs_n;
            end
            default: ; // defaults above handle DEVICE_NONE
        endcase
    end

endmodule
