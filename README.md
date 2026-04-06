Project Overview
This repository contains the VHDL source code for an FPGA-based experimental platform comparing OOK, BPSK, and FSK digital modulation schemes for Bi-Phasic Quasistatic Brain Communication (BP-QBC) through a tissue-equivalent phantom. The platform was implemented on a Xilinx Basys 3 (Artix-7) FPGA using Vivado 2024.

Repository Structure
Transmitter:

nco.vhd — Numerically Controlled Oscillator, 32-bit phase accumulator, 32-entry sine LUT
prbs_generator.vhd — PRBS-15 generator using primitive polynomial x¹⁵ + x¹⁴ + 1
ook_modulator.vhd — OOK modulation core
bpsk_modulator.vhd — BPSK modulation core
fsk_modulator.vhd — FSK dual-NCO modulation core (90 kHz and 110 kHz)
modulation_top.vhd — Top-level module with switch-selectable scheme selection

Receiver:

basys3_receiver.vhd — Complete FSK/OOK receiver with XADC interface, zero-crossing demodulator, adaptive threshold, PRBS-15 BER counter, and UART output


Hardware Setup

Transmitter: Basys 3 FPGA, Pmod R-2R DAC, 1 µF DC-blocking capacitor
Receiver: Second Basys 3 FPGA, JXADC header, LM358 op-amp analog front-end
Channel: Agarose-PBS tissue phantom (σ ≈ 0.3 S/m), Ag/AgCl ECG electrodes
SYNC_CLK wire between boards for bit boundary alignment
Common ground between both FPGAs and op-amp


Modulation Scheme Selection
SW1:SW0 = "00" → OOK
SW1:SW0 = "01" → BPSK
SW1:SW0 = "10" → FSK

Key Parameters

Carrier frequency: 100 kHz
Data rate: 8.7 kbps
Sampling rate: 1 MSPS
Samples per bit: 115
FSK frequencies: 90 kHz (binary 0), 110 kHz (binary 1)
PRBS sequence length: 32,767 bits


Tools

Xilinx Vivado 2024
MATLAB R2024b with Communications Toolbox
PuTTY for UART serial outpu
