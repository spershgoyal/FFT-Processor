# ===========================================================================
#  nexys_a7.xdc  --  Digilent Nexys A7-100T (Artix-7 xc7a100tcsg324-1)
# ---------------------------------------------------------------------------
#  Pin/timing constraints for the SPECTRA SoCs. The board has an on-board PDM
#  MEMS mic, a 12-bit 4-4-4 VGA port, USB-UART, 16 LEDs and 16 switches -- ideal
#  for the audio-spectrum and electrical-diagnostics demos out of the box. The
#  electrical ADC and the OV7670 camera attach via the Pmod headers (JA/JB).
#
#  Uncomment the block for the top you are building. A clocking wizard / MMCM
#  should derive the 25.175 MHz VGA pixel clock from the 100 MHz oscillator for
#  the audio/vision tops; the electrical top runs straight off 100 MHz.
# ===========================================================================

## 100 MHz system clock
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -name sys_clk -period 10.000 [get_ports clk]

## Reset  (use BTNC, active-high)
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports rst]

## ------------------------------------------------------------------ LEDs ---
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN V11 IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## ----------------------------------------------------------------- UART ---
## (FPGA TX -> USB)  spectra_elec_top.uart_tx
set_property -dict { PACKAGE_PIN D4 IOSTANDARD LVCMOS33 } [get_ports uart_tx]

## --------------------------------------------------- on-board PDM mic ------
## spectra_audio_top : pdm_clk -> M_CLK, pdm_data <- M_DATA  (tie M_LRSEL low)
# set_property -dict { PACKAGE_PIN J5 IOSTANDARD LVCMOS33 } [get_ports pdm_clk]
# set_property -dict { PACKAGE_PIN H5 IOSTANDARD LVCMOS33 } [get_ports pdm_data]
# set_property -dict { PACKAGE_PIN F5 IOSTANDARD LVCMOS33 } [get_ports m_lrsel]

## --------------------------------------------------- VGA 4-4-4 -------------
## spectra_audio_top / spectra_vision_top
# set_property -dict { PACKAGE_PIN A3 IOSTANDARD LVCMOS33 } [get_ports {vga_r[0]}]
# set_property -dict { PACKAGE_PIN B4 IOSTANDARD LVCMOS33 } [get_ports {vga_r[1]}]
# set_property -dict { PACKAGE_PIN C5 IOSTANDARD LVCMOS33 } [get_ports {vga_r[2]}]
# set_property -dict { PACKAGE_PIN A4 IOSTANDARD LVCMOS33 } [get_ports {vga_r[3]}]
# set_property -dict { PACKAGE_PIN C6 IOSTANDARD LVCMOS33 } [get_ports {vga_g[0]}]
# set_property -dict { PACKAGE_PIN A5 IOSTANDARD LVCMOS33 } [get_ports {vga_g[1]}]
# set_property -dict { PACKAGE_PIN B6 IOSTANDARD LVCMOS33 } [get_ports {vga_g[2]}]
# set_property -dict { PACKAGE_PIN A6 IOSTANDARD LVCMOS33 } [get_ports {vga_g[3]}]
# set_property -dict { PACKAGE_PIN B7 IOSTANDARD LVCMOS33 } [get_ports {vga_b[0]}]
# set_property -dict { PACKAGE_PIN C7 IOSTANDARD LVCMOS33 } [get_ports {vga_b[1]}]
# set_property -dict { PACKAGE_PIN D7 IOSTANDARD LVCMOS33 } [get_ports {vga_b[2]}]
# set_property -dict { PACKAGE_PIN D8 IOSTANDARD LVCMOS33 } [get_ports {vga_b[3]}]
# set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports hsync]
# set_property -dict { PACKAGE_PIN B12 IOSTANDARD LVCMOS33 } [get_ports vsync]

## --------------------------------------------------- Pmod JA : ADC / camera
## spectra_elec_top ADC (e.g. Pmod AD1) or spectra_vision_top OV7670 lives here
# set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports {pmod_ja[0]}]
# set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {pmod_ja[1]}]
# set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports {pmod_ja[2]}]
# set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports {pmod_ja[3]}]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
