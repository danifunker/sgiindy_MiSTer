//============================================================================
//  wd33c93 - the Western Digital WD33C93B SCSI initiator, as fitted to IP24.
//
//  TWO PORTS, NOT THIRTY-TWO. The chip has 32 internal registers reached
//  through one address latch: writing the address port sets the register
//  pointer, and the data port then reads or writes whatever it points at,
//  auto-incrementing afterwards. Reading the *address* port does not read
//  back the pointer - it returns the Auxiliary Status Register, which is the
//  only register readable without touching the pointer, and is what a driver
//  polls. Both ports live in IOC's HD0 window:
//
//    0x1FBC0003   address port (write) / Auxiliary Status (read)
//    0x1FBC0007   data port    - the register AR points at
//
//  Byte-wide registers at word stride four, value in the low byte of the
//  big-endian word - the same convention as every other IOC-adjacent device
//  here. Controller 1 is the same layout at 0x1FBC8000; only controller 0 is
//  fitted.
//
//  Both addresses come out of the PROM's own device descriptor table at
//  0xBFC7B410, not from a datasheet reading - see docs/02-address-map.md.
//
//  WHAT THIS DRIVES. The SCSI bus side talks to scsi.v, a target-only device
//  vendored from the MacLC core. This module is the initiator: it arbitrates,
//  selects, and runs the REQ/ACK handshake through whatever phase the target
//  asks for. See rtl/scsi/README.md for the phase encoding, which reads
//  backwards from scsi.v's own phase names.
//
//  PIO OR DMA, and the driver chooses. Control[7:5] is the DMA mode select:
//  000 is polled I/O, where a data byte sits in the DATA register behind DBR
//  until the driver comes for it, and anything else hands the byte to the
//  HPC3's SCSI DMA channel instead. IRIS reads the same field the same way
//  (`Wd33c93a::use_dma` is `mode != 0`), and the IP24 PROM writes 0x8D, so
//  every data phase in a real boot goes through DMA and none through DBR.
//
//  Both paths are here and the PIO one is untouched, because it is what the
//  chip's own diagnostics and the data-path test use, and because a driver may
//  legitimately mix them. The DMA handshake is a byte at a time with the
//  engine in rtl/sgi/hpc3_scsi_dma.sv: `dma_req` says a byte is due, its
//  direction comes from the SCSI phase rather than from anything the driver
//  wrote, and `dma_ack` says it has moved. `dma_eop` is the other half of it -
//  the target, not the count, decides when a data phase ends, and a response
//  shorter than the allocation length has to finish the descriptor anyway.
//
//  SCOPE. The register file, RESET, SELECT, TRANSFER INFO through the DATA
//  register, and Select-and-Transfer in both PIO and DMA. TRANSFER INFO in DMA
//  mode is NOT implemented - it stays on the DBR path - because nothing this
//  machine runs asks for it: the PROM and IRIX both use Select-and-Transfer.
//============================================================================

module wd33c93 #(
    // The initiator's own SCSI ID. SGI uses 0 for the host adapter.
    parameter logic [2:0] HOST_ID = 3'd0
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    // ---- register interface ---------------------------------------------
    // The HPC3 channel's ch_reset, as a pulse. The spec's words are "resets
    // both external controller and this DMA channel", and this is the external
    // controller half: everything the chip's own Reset command does, plus RST
    // asserted on the bus, because the driver that writes it prints
    // "resetting SCSI bus" and expects to get a free bus back.
    input  logic        chip_reset,

    input  logic        sel,        // one-cycle access pulse
    input  logic        we,
    input  logic        is_data,    // 0 = address port / ASR, 1 = data port
    input  logic  [7:0] din,
    output logic  [7:0] dout,

    // ---- SCSI bus, initiator side ----------------------------------------
    output logic        scsi_rst,
    output logic        scsi_sel,
    output logic        scsi_atn,
    output logic        scsi_ack,
    output logic  [7:0] scsi_dout,  // initiator -> target
    input  logic        scsi_bsy,
    input  logic        scsi_msg,
    input  logic        scsi_cd,
    input  logic        scsi_io,
    input  logic        scsi_req,
    input  logic  [7:0] scsi_din,   // target -> initiator

    // ---- HPC3 SCSI DMA channel -------------------------------------------
    // Held, not pulsed: `dma_req` stays up until the engine answers, because
    // the engine may be part way through a descriptor fetch when it is raised.
    output logic        dma_req,
    output logic        dma_dir_in, // 1 = DATA IN, device -> main memory
    output logic  [7:0] dma_wdata,  // the byte taken off the SCSI bus
    output logic        dma_eop,    // pulse: the target ended the data phase
    input  logic        dma_ack,
    input  logic  [7:0] dma_rdata,  // the byte from main memory

    output logic        irq,

    // SGI: DDR3 debug beacon word (docs/28) - counters and live chip state,
    // pure observation. Bit map at the assembly, next to scsi_rst.
    output logic [63:0] dbg_bcn
);

    // ---- indirect register file ------------------------------------------
    localparam logic [4:0] R_OWN_ID      = 5'h00;
    localparam logic [4:0] R_CONTROL     = 5'h01;
    localparam logic [4:0] R_TIMEOUT     = 5'h02;
    localparam logic [4:0] R_CDB1        = 5'h03;   // .. 0x0E is CDB byte 12
    localparam logic [4:0] R_TARGET_LUN  = 5'h0F;
    localparam logic [4:0] R_CMD_PHASE   = 5'h10;
    localparam logic [4:0] R_SYNC_XFER   = 5'h11;
    localparam logic [4:0] R_COUNT_MSB   = 5'h12;
    localparam logic [4:0] R_COUNT_2ND   = 5'h13;
    localparam logic [4:0] R_COUNT_LSB   = 5'h14;
    localparam logic [4:0] R_DEST_ID     = 5'h15;
    localparam logic [4:0] R_SRC_ID      = 5'h16;
    localparam logic [4:0] R_SCSI_STATUS = 5'h17;
    localparam logic [4:0] R_COMMAND     = 5'h18;
    localparam logic [4:0] R_DATA        = 5'h19;
    localparam logic [4:0] R_QUEUE_TAG   = 5'h1A;
    localparam logic [4:0] R_AUX_STATUS  = 5'h1F;

    logic [7:0] reg_file [32];
    logic [4:0] ar;                 // the address latch

    // ---- Auxiliary Status Register ---------------------------------------
    // bit 0 DBR - a data byte is ready to read, or the chip wants one written
    // bit 4 CIP - a command is in progress; the driver must not issue another
    // bit 5 BSY - the chip holds the SCSI bus
    // bit 6 LCI - the last command was ignored (issued while CIP)
    // bit 7 INT - an interrupt is pending. Reading SCSI_STATUS clears it, and
    //             that read is what a driver uses to find out what happened.
    logic dbr, cip, lci, int_pending;
    wire [7:0] asr = {int_pending, lci, scsi_bsy, cip, 3'b000, dbr};

    // ---- commands ---------------------------------------------------------
    localparam logic [7:0] C_RESET        = 8'h00;
    localparam logic [7:0] C_ABORT        = 8'h01;
    localparam logic [7:0] C_ASSERT_ATN   = 8'h02;
    localparam logic [7:0] C_NEGATE_ACK   = 8'h03;
    localparam logic [7:0] C_DISCONNECT   = 8'h04;
    localparam logic [7:0] C_SELECT_ATN   = 8'h06;
    localparam logic [7:0] C_SELECT       = 8'h07;
    localparam logic [7:0] C_SEL_ATN_XFER = 8'h08;
    localparam logic [7:0] C_SEL_XFER     = 8'h09;
    localparam logic [7:0] C_TRANSFER_INFO= 8'h20;

    // ---- SCSI Status Register values --------------------------------------
    // Only the ones this stage can produce. The full list, with the IRIX
    // wd93.h names beside each, is in IRIS's src/wd33c93a.rs.
    localparam logic [7:0] S_RESET          = 8'h00;
    // Reset with advanced features enabled - see the Reset command below for
    // why answering the wrong one of these two misconfigures the driver.
    localparam logic [7:0] S_RESET_EAF      = 8'h01;
    localparam logic [7:0] S_SELECT_OK      = 8'h11;
    localparam logic [7:0] S_XFER_DATA_OUT  = 8'h18;  // target wants DATA OUT
    localparam logic [7:0] S_XFER_DATA_IN   = 8'h19;  // target is sending DATA IN
    localparam logic [7:0] S_XFER_STATUS_IN = 8'h1B;
    localparam logic [7:0] S_XFER_MSG_IN    = 8'h1F;
    localparam logic [7:0] S_XFER_CMD_OUT   = 8'h1A;  // target wants COMMAND
    localparam logic [7:0] S_XFER_MSG_OUT  = 8'h1E;
    // "Service required": the target has asked for a phase and the chip is not
    // in a command that handles it, so it hands the question to the driver.
    // The BASE IS 0x88, NOT 0x80, and the low three bits are the phase:
    // 0x88 DATA OUT, 0x89 DATA IN, 0x8A COMMAND, 0x8B STATUS, 0x8E MSG OUT,
    // 0x8F MSG IN. The list is IRIS's src/wd33c93a.rs, which matches IRIX's
    // own wd93.h names, and it matters that the base is right: 0x80..0x87 are
    // a different group entirely - 0x85 is "disconnected" - so an off-by-eight
    // here does not produce an unrecognised code, it produces a plausible and
    // wrong one. `0x80 | phase` made a MESSAGE OUT request arrive as 0x86, and
    // the PROM answered a status it did not recognise by disconnecting.
    localparam logic [7:0] S_SERVICE_REQ    = 8'h88;
    // "Unexpected information phase": the same low-three-bits-are-the-phase
    // encoding as S_SERVICE_REQ, but the 0x48 base means "a command WAS in
    // progress when the target asked for this" - it is how the chip reports a
    // Select-and-Transfer paused by its own Transfer Count while the target
    // still wants a data phase. IRIX's wd93 routes the whole group through
    // unex_info(), reloads the count and the DMA chain, and resumes with
    // another Select-and-Transfer (see the resume arm at C_SEL_XFER below).
    // IRIS posts exactly these values from the same situation
    // (src/wd33c93a.rs queue_interrupt(TRANSFER_COUNT, 0x48/0x49) in its
    // chunked DMA paths), and 0x4A/0x4B/0x4E/0x4F in its table confirm the
    // base|phase rule (COMMAND/STATUS/MSG OUT/MSG IN land on their phase
    // codes exactly).
    localparam logic [7:0] S_UNEX_INFO      = 8'h48;
    localparam logic [7:0] S_INVALID_CMD    = 8'h40;
    localparam logic [7:0] S_SELECT_TIMEOUT = 8'h42;
    localparam logic [7:0] S_DISCONNECT     = 8'h85;

    // ---- COMMAND PHASE register values -------------------------------------
    // The chip walks this register through a Select-and-Transfer so a driver
    // that takes an interrupt part way can tell how far it got and resume.
    // Values from IRIS's src/wd33c93a.rs, which matches IRIX's wd93.h.
    localparam logic [7:0] CP_DISCONNECTED = 8'h00;
    localparam logic [7:0] CP_SELECTED     = 8'h10;
    // IDENTIFY (and anything after it) has gone out; COMMAND is next.
    localparam logic [7:0] CP_IDENTIFY_SENT = 8'h20;
    localparam logic [7:0] CP_CMD_START    = 8'h30;   // +n as CDB bytes go out
    // A clean disconnect sets BOTH of these. The PROM's SCSI interrupt handler
    // at 0xBFC1E304 reads COMMAND_PHASE, and on status 0x85 prints "illegal
    // disconnection interrupt: phase %x" unless the phase is exactly 0x43:
    //     bfc1e248  beq  $v1, 0x85, ...      ; status == DISCONNECT
    //     bfc1e30c  bne  $a3, 0x43, ...      ; phase != 0x43 -> complain
    // Reporting 0x85 with the phase left at zero is what made a scan of the
    // empty IDs print six of those lines a boot.
    localparam logic [7:0] CP_DISCONNECT_OK = 8'h43;
    localparam logic [7:0] CP_XFER_COUNT   = 8'h46;   // data done, TC = 0
    localparam logic [7:0] CP_RECV_STATUS  = 8'h47;
    localparam logic [7:0] CP_STATUS_RECVD = 8'h50;   // status byte in TARGET_LUN
    localparam logic [7:0] CP_COMPLETE_MSG = 8'h60;

    localparam logic [7:0] S_SELECT_XFER_OK = 8'h16;  // ST_SATOK

    // ---- phase decode ------------------------------------------------------
    // Standard {MSG, C/D, I/O}. scsi.v drives these to the SCSI meanings even
    // though its internal phase names read from the target's side.
    wire [2:0] phase = {scsi_msg, scsi_cd, scsi_io};
    localparam logic [2:0] PH_DATA_OUT = 3'b000;   // initiator -> target
    localparam logic [2:0] PH_DATA_IN  = 3'b001;   // target -> initiator
    localparam logic [2:0] PH_COMMAND  = 3'b010;
    localparam logic [2:0] PH_STATUS   = 3'b011;
    localparam logic [2:0] PH_MSG_OUT  = 3'b110;   // initiator -> target
    localparam logic [2:0] PH_MSG_IN   = 3'b111;

    // Control[7:5] selects the DMA mode; zero is polled I/O. See the header.
    wire use_dma = |reg_file[R_CONTROL][7:5];

    // ---- transfer counter --------------------------------------------------
    // 24 bits, MSB first across three registers, as the chip presents it.
    wire [23:0] xfer_count = {reg_file[R_COUNT_MSB],
                              reg_file[R_COUNT_2ND],
                              reg_file[R_COUNT_LSB]};

    // ---- sequencer ----------------------------------------------------------
    // Five bits, not four: the sequencer passed sixteen states when the plain
    // SELECT grew its second, phase-reporting interrupt.
    typedef enum logic [4:0] {
        ST_IDLE,
        ST_SEL_ASSERT,      // drive SEL with the target's ID
        ST_SEL_WAIT,        // wait for the target to answer with BSY
        ST_SEL_DONE,
        ST_SEL_PHASE,       // selected: report the phase the target asks for
        ST_XFER,            // wait for REQ in the current phase
        ST_XFER_ACK,        // data taken or presented; raise ACK
        ST_XFER_REL,        // wait for the target to drop REQ
        ST_DONE,
        // Select-and-Transfer: the chip's automatic mode, and the only one
        // this machine's driver uses. One state per bus phase, walked without
        // the driver in the loop except to feed or drain data bytes.
        ST_SAT_SEL,
        ST_SAT_WAIT,
        ST_SAT_PHASE,       // look at what the target is asking for
        ST_SAT_REQ,         // a byte is due in the current phase
        ST_SAT_ACK,
        ST_SAT_REL,
        ST_SAT_DIN,         // DATA IN: let the target's byte settle first
        ST_SAT_DMA,         // a data byte is with the HPC3 DMA engine
        ST_SAT_END
    } state_t;

    state_t state;

    // Selection has to give up eventually or a scan of eight IDs on a machine
    // with one disk wedges on the first empty one. The chip takes its timeout
    // from R_TIMEOUT in units of 80us; nothing here depends on matching that
    // exactly, only on it being long enough that a present target always wins
    // and short enough that eight absent ones do not take visible time.
    localparam int SEL_TIMEOUT = 4096;
    logic [15:0] sel_timer;

    // Confirms a Transfer-Count-exhausted data phase is REALLY a paused
    // multi-segment transfer before interrupting. A normally completed
    // transfer also passes through {count==0, REQ up, data phase} for a cycle
    // or two - the target holds REQ past the last byte before it moves the
    // phase lines (see the PH_DATA_OUT comment in ST_SAT_PHASE) - so the
    // pause must outlast that tail. 4096 cycles is ~126 us at clk_sys: three
    // orders above the tail, three under the driver's 60 s watchdog.
    logic [11:0] sat_pause_cnt;

    // BSY is the OR of every target's, so "a target is on the bus" and "the
    // target I just selected answered" are not the same question. Selection
    // has to start from a free bus and then watch BSY *rise*; taking the level
    // means that once one target is holding the bus, every later selection
    // appears to succeed instantly. That is what made a scan of eight IDs on a
    // machine with one disk report six phantom disconnects: ID 1 answered and
    // held BSY, and 2 through 7 then "selected" it.
    logic bsy_q;

    // The byte in flight, and which way it is going.
    logic [7:0] data_latch;
    // How far through the CDB a Select-and-Transfer has got. The length comes
    // from the group code in the top three bits of the opcode: group 0 is a
    // 6-byte CDB, groups 1 and 2 are 10, group 5 is 12. Anything else is
    // treated as 6, which is what the chip does with an unknown group beyond
    // also flagging it.
    logic [3:0] cdb_idx;
    // Clocks to wait after REQ before believing the target's DATA IN byte.
    // See PH_DATA_IN. MEASURED, not chosen: tests/run-scsiwr.sh fails at 1, 2
    // and 3 and passes at 4, 5 and 6, so four is what this target needs and
    // six is two clocks of headroom. It costs nothing worth counting - the DMA
    // round trip that follows it is longer than the wait - and the headroom is
    // deliberate, because the number belongs to scsi.v's RAM timing rather
    // than to anything specified, and scsi.v is vendored.
    localparam int DIN_SETTLE = 6;
    logic [2:0] din_settle;
    // True while a DMA data phase is running, so that leaving the phase can be
    // reported to the engine as an end of transfer exactly once.
    logic       dma_in_data;
    // Select-and-Transfer's IDENTIFY is ONE byte, and this is what stops it
    // being two. A target needs a clock to leave MESSAGE OUT after the last
    // ACK falls; the sequencer is back in ST_SAT_PHASE before that, sees
    // MESSAGE OUT and REQ still asserted, and sends the message again. The
    // second byte then lands as the first byte of the CDB - which presents as
    // a target that answers selection and then never recognises the command,
    // with cmd[0] = 0x80.
    logic       sat_identify_sent;
    // AND THIS IS THE SAME BUG ONE PHASE LATER. The CDB is cdb_len bytes and
    // the chip sends exactly that many; the target needs a clock to leave
    // COMMAND after the last ACK falls, and the sequencer is back in
    // ST_SAT_PHASE before that, sees COMMAND and REQ still asserted, and sends
    // a seventh byte. Clamping cdb_idx at cdb_len-1 does not stop it - it just
    // makes the extra byte a copy of the last one.
    //
    // What that costs is a whole block of data, and only on a WRITE. The extra
    // ACK lands in the cycle the target has already moved to DATA OUT, so the
    // target takes the stale data_latch - the CDB's control byte, 0x00 - as
    // data byte 0 and every real byte arrives one place late, with the last
    // one dropped off the end. A READ survives it because the target is the
    // one driving data and an extra initiator ACK there does not manufacture a
    // byte, which is why every boot this project has ever done looked fine.
    logic       sat_cdb_sent;
    wire  [2:0] cdb_group = reg_file[R_CDB1][7:5];
    wire  [3:0] cdb_len   = (cdb_group == 3'd1 || cdb_group == 3'd2) ? 4'd10
                          : (cdb_group == 3'd5)                      ? 4'd12
                          :                                            4'd6;
    wire        to_target = (phase == PH_DATA_OUT) || (phase == PH_COMMAND)
                          || (phase == PH_MSG_OUT);

    assign scsi_dout = data_latch;
    assign irq       = int_pending;

    // ---- SCSI bus reset ---------------------------------------------------
    // RST is the only way to get a wedged target off the bus, and until this
    // existed there was none: a target that had been selected and then
    // abandoned held BSY forever, the ASR read 0x20 for the rest of the boot,
    // and every command after it failed. The driver's own recovery path is
    // built on this - it writes HPC3's ch_reset, prints "resetting SCSI bus",
    // and expects a free bus back.
    //
    // The bus specifies a minimum RST of 25 microseconds. Nothing here needs
    // that: scsi.v samples the line on the system clock, so the hold below is
    // "long enough to be unmissable" rather than a timing figure, and a real
    // implementation on hardware should widen it.
    localparam int RST_HOLD = 256;
    logic [8:0] rst_timer;
    assign scsi_rst = (rst_timer != 9'd0);

    // SGI: DDR3 debug beacon (docs/28) - counters and live chip state, pure
    // observation, read on hardware through ddr3_peek.py while wedged. The
    // counters answer the question the wedge poses: does IRIX's 60 s
    // "Resetting SCSI bus" recovery ever produce a bus-visible scsi_rst
    // (rst_load), or only the chip-local C_RESET the targets never see?
    //   [63:56] chip_reset pulses       [55:48] scsi_rst rising edges
    //   [47:40] accepted C_RESET writes [39:32] accepted C_SEL(_ATN)_XFER
    //   [31:24] refused commands (LCI)  [23:16] R_COMMAND  [15:8] R_CMD_PHASE
    //   [7] cip  [6] int_pending  [5] lci  [4:0] state
    logic [7:0] bcn_chiprst, bcn_rstload, bcn_creset, bcn_selxfer, bcn_lci;
    logic       bcn_rst_d;
    logic [4:0] bcn_state;
    assign bcn_state = state;
    always_ff @(posedge clk) begin
        if (reset) begin
            bcn_chiprst <= 8'd0;
            bcn_rstload <= 8'd0;
            bcn_creset  <= 8'd0;
            bcn_selxfer <= 8'd0;
            bcn_lci     <= 8'd0;
            bcn_rst_d   <= 1'b0;
        end else if (ce) begin
            bcn_rst_d <= scsi_rst;
            if (chip_reset) bcn_chiprst <= bcn_chiprst + 8'd1;
            if (scsi_rst && !bcn_rst_d) bcn_rstload <= bcn_rstload + 8'd1;
            if (sel && we && is_data && (ar == R_COMMAND)) begin
                if ((cip || int_pending) && din != C_RESET)
                    bcn_lci <= bcn_lci + 8'd1;
                else if (din == C_RESET)
                    bcn_creset <= bcn_creset + 8'd1;
                else if (din == C_SEL_XFER || din == C_SEL_ATN_XFER)
                    bcn_selxfer <= bcn_selxfer + 8'd1;
            end
        end
    end
    assign dbg_bcn = { bcn_chiprst, bcn_rstload, bcn_creset, bcn_selxfer,
                       bcn_lci, reg_file[R_COMMAND], reg_file[R_CMD_PHASE],
                       cip, int_pending, lci, bcn_state };

    // Register reads. The address port is the ASR; the data port is whatever
    // AR points at, with two registers answering from live state rather than
    // storage.
    logic [7:0] dout_r;
    assign dout = dout_r;

    function automatic logic [7:0] read_indirect(input logic [4:0] a);
        case (a)
            R_AUX_STATUS: read_indirect = asr;
            R_DATA:       read_indirect = data_latch;
            default:      read_indirect = reg_file[a];
        endcase
    endfunction

    integer i;

    // Latched from Own ID's EAF bit by the Reset command, the way the part
    // does it. Nothing reads it yet - the transfer paths here already behave
    // as a 93A - but the driver's view of the chip now depends on this bit
    // being remembered rather than assumed, so it is kept where the rest of
    // the advanced-feature behaviour will hang off it.
    logic advanced_mode;

    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) reg_file[i] <= 8'h00;
            // A POWER-ON reset clears Own ID too; the ID below is only a sane
            // value to answer with before the driver programs one, and it
            // leaves EAF clear, which is the correct state until asked for.
            reg_file[R_OWN_ID] <= {5'b0, HOST_ID};
            advanced_mode      <= 1'b0;
            ar          <= 5'h00;
            state       <= ST_IDLE;
            dbr         <= 1'b0;
            cip         <= 1'b0;
            lci         <= 1'b0;
            int_pending <= 1'b0;
            scsi_sel    <= 1'b0;
            scsi_atn    <= 1'b0;
            scsi_ack    <= 1'b0;
            data_latch  <= 8'h00;
            sel_timer   <= 16'h0;
            bsy_q       <= 1'b0;
            dout_r      <= 8'h00;
            dma_req     <= 1'b0;
            dma_eop     <= 1'b0;
            dma_dir_in  <= 1'b0;
            dma_wdata   <= 8'h00;
            dma_in_data <= 1'b0;
            sat_identify_sent <= 1'b0;
            sat_pause_cnt <= 12'd0;
            rst_timer   <= 9'd0;
        end else if (ce) begin
            bsy_q   <= scsi_bsy;
            dma_eop <= 1'b0;
            if (rst_timer != 9'd0) rst_timer <= rst_timer - 9'd1;

            // ---- the HPC3 channel's ch_reset -------------------------------
            // Ahead of the register access below, so a driver that resets the
            // channel and issues a command in the same breath gets the reset.
            if (chip_reset) begin
                // A hardware reset, unlike the Reset COMMAND below, clears Own
                // ID as well - so advanced features go off with it and the
                // status is the plain 0x00 either way.
                for (i = 0; i < 32; i = i + 1) reg_file[i] <= 8'h00;
                reg_file[R_OWN_ID] <= {5'b0, HOST_ID};
                reg_file[R_SCSI_STATUS] <= S_RESET;
                advanced_mode <= 1'b0;
                ar          <= 5'h00;
                state       <= ST_IDLE;
                dbr         <= 1'b0;
                cip         <= 1'b0;
                lci         <= 1'b0;
                int_pending <= 1'b1;
                scsi_sel    <= 1'b0;
                scsi_atn    <= 1'b0;
                scsi_ack    <= 1'b0;
                dma_req     <= 1'b0;
                dma_in_data <= 1'b0;
                rst_timer   <= RST_HOLD[8:0];
            end

            // ---- register access -------------------------------------------
            if (sel) begin
                if (we) begin
                    if (!is_data) begin
                        ar <= din[4:0];
                    end else begin
                        // A write to the command register starts something; any
                        // other write is storage. AR auto-increments either way,
                        // except across the command and status registers, which
                        // a driver rewrites in place.
                        case (ar)
                            R_COMMAND: begin
                                // A command is refused, and LCI says so, while
                                // one is still running OR while an interrupt
                                // has not been serviced. The second half is not
                                // a detail: the SCSI Status register holds the
                                // result of the *last* command, so accepting a
                                // new one before the driver has read it would
                                // destroy the answer it is about to ask for.
                                //
                                // The PROM's command-issue routine is written
                                // around exactly this, and reading it is how
                                // the rule was established rather than guessed.
                                // FUN_bfc1f64c: wait for CIP to clear, write
                                // COMMAND, wait for CIP again, then test LCI -
                                // and on LCI, call FUN_bfc1f230 ("is INT
                                // pending?"), read register 0x17 to clear it,
                                // and re-issue.
                                //
                                // Without it, a scan of the empty SCSI IDs
                                // printed six "illegal disconnection interrupt"
                                // lines a boot. The handler at 0xBFC1E304 is
                                // silent on status 0x85 only while COMMAND
                                // still reads 0x04, and the driver leaves the
                                // DISCONNECT interrupt unserviced while it sets
                                // up the next ID. On real hardware that next
                                // command bounces off LCI and the driver eats
                                // the stale interrupt itself; here it was
                                // accepted, so the handler ran late against a
                                // COMMAND register that had moved to 0x08.
                                //
                                // RESET is the exception, as it is on the part:
                                // it is the escape hatch out of any state,
                                // clears the interrupt itself, and a driver
                                // with a wedged chip has nothing else left.
                                if ((cip || int_pending) && din != C_RESET) begin
                                    lci <= 1'b1;
                                end else begin
                                    reg_file[R_COMMAND] <= din;
                                    lci <= 1'b0;
                                    case (din)
                                        C_RESET: begin
                                            // A SOFTWARE RESET IS NOT A POWER-ON
                                            // RESET, AND THE DIFFERENCE IS HOW THE
                                            // DRIVER LEARNS WHICH PART IT HAS.
                                            //
                                            // The Reset command clears registers
                                            // 0x01..0x16 and the Command register,
                                            // but PRESERVES Own ID (0x00) - and then
                                            // reports back through SCSI Status which
                                            // of the two reset flavours happened:
                                            // 0x01 if Own ID's EAF bit (0x08, Enable
                                            // Advanced Features) was set, 0x00 if it
                                            // was not. That is the handshake by
                                            // which a driver turns the 93A's
                                            // advanced features on and confirms they
                                            // took: write Own ID with EAF, Reset,
                                            // read the status back.
                                            //
                                            // This model used to answer 0x00
                                            // unconditionally and clear nothing,
                                            // which tells IRIX its request did not
                                            // take however it asks. The rule is
                                            // IRIS's (src/wd33c93a.rs, BSD-3-Clause,
                                            // (c) 2026 Dominik Behr), whose comment
                                            // states it outright and which boots
                                            // this same IRIX.
                                            for (i = 1; i <= 8'h16; i = i + 1)
                                                reg_file[i] <= 8'h00;
                                            reg_file[R_COMMAND]     <= 8'h00;
                                            reg_file[R_SCSI_STATUS] <=
                                                reg_file[R_OWN_ID][3] ? S_RESET_EAF : S_RESET;
                                            advanced_mode <= reg_file[R_OWN_ID][3];
                                            int_pending <= 1'b1;
                                            state       <= ST_IDLE;
                                            scsi_sel    <= 1'b0;
                                            scsi_ack    <= 1'b0;
                                            scsi_atn    <= 1'b0;
                                            dbr         <= 1'b0;
                                            // Whatever the engine was waiting
                                            // for is gone with the bus.
                                            dma_req     <= 1'b0;
                                            dma_in_data <= 1'b0;
                                        end
                                        C_SELECT, C_SELECT_ATN: begin
                                            scsi_atn  <= (din == C_SELECT_ATN);
                                            cip       <= 1'b1;
                                            sel_timer <= 16'h0;
                                            state     <= ST_SEL_ASSERT;
                                        end
                                        C_TRANSFER_INFO: begin
                                            cip   <= 1'b1;
                                            state <= ST_XFER;
                                        end
                                        C_SEL_XFER, C_SEL_ATN_XFER: begin
                                            // RESUME, NOT SELECTION, when the
                                            // command-phase register says a
                                            // transfer paused at count zero
                                            // and the target still holds the
                                            // bus: the driver has reloaded
                                            // the count (and its DMA chain)
                                            // and wants the same connection
                                            // continued. No new selection, no
                                            // IDENTIFY, no CDB - straight
                                            // back to following the target's
                                            // phase. NetBSD's wd33c93
                                            // xferdone issues exactly this
                                            // write after the LAST segment
                                            // too; then the target is already
                                            // in STATUS and the ordinary
                                            // phase walk concludes the
                                            // command. IRIS implements both
                                            // halves (src/wd33c93a.rs, the
                                            // cmd_phase==0x46 arm).
                                            if (reg_file[R_CMD_PHASE] == CP_XFER_COUNT
                                                && scsi_bsy) begin
                                                cip               <= 1'b1;
                                                scsi_atn          <= 1'b0;
                                                sat_identify_sent <= 1'b1;
                                                sat_cdb_sent      <= 1'b1;
                                                state             <= ST_SAT_PHASE;
                                            end else begin
                                                scsi_atn  <= (din == C_SEL_ATN_XFER);
                                                cip       <= 1'b1;
                                                sel_timer <= 16'h0;
                                                cdb_idx   <= 4'd0;
                                                dma_in_data <= 1'b0;
                                                sat_identify_sent <= 1'b0;
                                                sat_cdb_sent      <= 1'b0;
                                                reg_file[R_CMD_PHASE] <= CP_DISCONNECTED;
                                                state     <= ST_SAT_SEL;
                                            end
                                        end
                                        C_NEGATE_ACK: scsi_ack <= 1'b0;
                                        C_ASSERT_ATN: scsi_atn <= 1'b1;
                                        C_DISCONNECT: begin
                                            scsi_sel <= 1'b0;
                                            scsi_ack <= 1'b0;
                                            scsi_atn <= 1'b0;
                                            // Phase 0, not 0x43: IRIS uses
                                            // command_phase::DISCONNECTED here
                                            // (wd33c93a.rs:1778) and the PROM's
                                            // handler accepts it, given the
                                            // COMMAND register still reads 0x04.
                                            reg_file[R_CMD_PHASE]   <= CP_DISCONNECTED;
                                            reg_file[R_SCSI_STATUS] <= S_DISCONNECT;
                                            int_pending <= 1'b1;
                                        end
                                        C_ABORT: begin
                                            state    <= ST_IDLE;
                                            cip      <= 1'b0;
                                            scsi_sel <= 1'b0;
                                            scsi_ack <= 1'b0;
                                        end
                                        default: begin
                                            // Select-and-Transfer and the
                                            // reselection commands land here
                                            // until stage 2. Answering
                                            // "invalid command" is honest and
                                            // keeps a driver from waiting on an
                                            // interrupt that will never come.
                                            reg_file[R_SCSI_STATUS] <= S_INVALID_CMD;
                                            int_pending <= 1'b1;
                                        end
                                    endcase
                                end
                            end
                            R_DATA: begin
                                data_latch <= din;
                                dbr        <= 1'b0;
                            end
                            default: begin
                                reg_file[ar] <= din;
                                if (ar != R_SCSI_STATUS) ar <= ar + 5'd1;
                            end
                        endcase
                    end
                end else begin
                    // Reads. The address port is the ASR and never moves AR.
                    if (!is_data) begin
                        dout_r <= asr;
                    end else begin
                        dout_r <= read_indirect(ar);
                        // Reading the status register is how a driver
                        // acknowledges the interrupt, so it is the one read
                        // with a side effect.
                        if (ar == R_SCSI_STATUS) begin
                            int_pending <= 1'b0;
                            // The status read is also how LCI is acknowledged:
                            // the driver reads it, then re-issues the command
                            // that was ignored. Left set, it makes the PROM's
                            // handler take its last-command-ignored path on
                            // every interrupt from then on.
                            lci <= 1'b0;
                        end
                        if (ar == R_DATA)        dbr         <= 1'b0;
                        if (ar != R_SCSI_STATUS && ar != R_DATA && ar != R_AUX_STATUS)
                            ar <= ar + 5'd1;
                    end
                end
            end

            // ---- the sequencer ----------------------------------------------
            case (state)
                ST_IDLE: ;

                ST_SEL_ASSERT: begin
                    sel_timer <= sel_timer + 16'd1;
                    if (!scsi_bsy) begin
                        scsi_sel  <= 1'b1;
                        data_latch<= (8'h01 << HOST_ID) | (8'h01 << reg_file[R_DEST_ID][2:0]);
                        state     <= ST_SEL_WAIT;
                    end else if (sel_timer >= SEL_TIMEOUT) begin
                        scsi_atn <= 1'b0;
                        cip      <= 1'b0;
                        reg_file[R_SCSI_STATUS] <= S_SELECT_TIMEOUT;
                        int_pending <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                // A present target answers selection by asserting BSY. An
                // absent one never does, and the timeout is the only thing
                // that ends a scan of the seven IDs with nothing on them.
                ST_SEL_WAIT: begin
                    sel_timer <= sel_timer + 16'd1;
                    if (scsi_bsy && !bsy_q) begin
                        scsi_sel <= 1'b0;
                        state    <= ST_SEL_DONE;
                    end else if (sel_timer >= SEL_TIMEOUT) begin
                        scsi_sel <= 1'b0;
                        // ATN has to come down with it. Left asserted from a
                        // SELECT-with-ATN, it is still up when the driver
                        // tries the next ID, and every selection after the
                        // first empty one starts polluted.
                        scsi_atn <= 1'b0;
                        cip      <= 1'b0;
                        reg_file[R_SCSI_STATUS] <= S_SELECT_TIMEOUT;
                        int_pending <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                ST_SEL_DONE: begin
                    cip <= 1'b0;
                    reg_file[R_SCSI_STATUS] <= S_SELECT_OK;
                    int_pending <= 1'b1;
                    state <= ST_SEL_PHASE;
                end

                // A PLAIN SELECT IS TWO INTERRUPTS, NOT ONE. The first says
                // the target answered; the second says which phase it has
                // asked for, and a driver that has just selected with ATN is
                // waiting for exactly that before it sends anything. This
                // model used to stop at the first one and sit in ST_IDLE, so
                // the IP24 PROM's synchronous-transfer negotiation waited out
                // its 5000-tick timeout on every boot and reset the bus.
                //
                // The driver's own code is the specification here:
                // 0xBFC1CB24 reads the status register and tests
                // `andi $t0, $v0, 7; bne $t0, 6` - the low three bits are the
                // phase and 6 is MESSAGE OUT.
                //
                // The wait for the status read matters: the SCSI status
                // register holds one result at a time, and overwriting the
                // select-complete status before the driver has read it
                // destroys the answer it is about to ask for. Same rule the
                // LCI path is built on - see the command register above.
                ST_SEL_PHASE: begin
`ifdef MSG_DEBUG
                    $display("[INI] SEL_PHASE bsy=%b req=%b phase=%b int=%b atn=%b", scsi_bsy, scsi_req, phase, int_pending, scsi_atn);
`endif
                    if (!scsi_bsy) begin
                        state <= ST_IDLE;
                    end else if (!int_pending && scsi_req) begin
                        reg_file[R_SCSI_STATUS] <= S_SERVICE_REQ | {5'b0, phase};   // 0x88 | phase
                        int_pending <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                // One byte per REQ. The driver either wrote the byte into the
                // data register before issuing TRANSFER INFO (to-target
                // phases) or reads it out afterwards (from-target phases);
                // DBR is what tells it which way round it is.
                ST_XFER: begin
`ifdef MSG_DEBUG
                    $display("[INI] XFER bsy=%b req=%b phase=%b cnt=%0d atn=%b", scsi_bsy, scsi_req, phase, xfer_count, scsi_atn);
`endif
                    if (!scsi_bsy) begin
                        // The target let go of the bus mid-transfer. Still a
                        // clean disconnect as far as the driver is concerned,
                        // so the phase has to say so - see CP_DISCONNECT_OK.
                        cip <= 1'b0;
                        reg_file[R_CMD_PHASE]   <= CP_DISCONNECT_OK;
                        reg_file[R_SCSI_STATUS] <= S_DISCONNECT;
                        int_pending <= 1'b1;
                        state <= ST_IDLE;
                    end else if (scsi_req) begin
                        if (!to_target) data_latch <= scsi_din;
                        // A message ends by the initiator negating ATN before
                        // it acknowledges the last byte - that is how the
                        // target knows how long the message was without
                        // parsing it. ACK goes up in the next state, so
                        // dropping ATN here is in time.
                        if ((phase == PH_MSG_OUT) && (xfer_count <= 24'd1)) begin
                            scsi_atn <= 1'b0;
                            // AND RECORD THAT THE MESSAGE WENT OUT. The
                            // Command Phase register is how a driver knows
                            // where in the connection the chip is, and 0x20 is
                            // "IDENTIFY sent, COMMAND phase next" - the value
                            // IRIS reports here (command_phase::IDENTIFY_SENT
                            // beside REQ_CMD_PHASE, src/wd33c93a.rs). This
                            // model never produced 0x20 at all: it went from
                            // 0x10 SELECTED straight to 0x30 COMMAND_START as
                            // the CDB began, so the one moment the driver asks
                            // about after negotiating had no answer.
                            // docs/13-scsi-dma-plan.md records that the
                            // missing piece after MESSAGE OUT was on the
                            // initiator side and unidentified. This is a
                            // candidate for it.
                            reg_file[R_CMD_PHASE] <= CP_IDENTIFY_SENT;
                        end
                        state <= ST_XFER_ACK;
                    end
                end

                // The same rule on the polled path. Its window is one cycle
                // rather than tens - the REQ test is in the state before this
                // one - so it has never been seen to fire, but a one-cycle
                // race that corrupts a disk silently is not worth keeping for
                // the sake of a cycle. See the note on ST_SAT_ACK.
                ST_XFER_ACK: if (scsi_req) begin
                    scsi_ack <= 1'b1;
                    state    <= ST_XFER_REL;
                end

                ST_XFER_REL: begin
                    if (!scsi_req) begin
                        scsi_ack <= 1'b0;
                        // Count down. Reaching zero ends the command and
                        // raises the interrupt whose status says which phase
                        // the target is asking for next - that is how a
                        // driver walks COMMAND -> DATA -> STATUS -> MESSAGE.
                        if (xfer_count <= 24'd1) begin
                            {reg_file[R_COUNT_MSB],
                             reg_file[R_COUNT_2ND],
                             reg_file[R_COUNT_LSB]} <= 24'd0;
                            cip <= 1'b0;
                            dbr <= !to_target;
                            state <= ST_DONE;
                        end else begin
                            {reg_file[R_COUNT_MSB],
                             reg_file[R_COUNT_2ND],
                             reg_file[R_COUNT_LSB]} <= xfer_count - 24'd1;
                            dbr   <= !to_target;
                            state <= ST_XFER;
                        end
                    end
                end

                ST_DONE: begin
                    case (phase)
                        PH_DATA_OUT: reg_file[R_SCSI_STATUS] <= S_XFER_DATA_OUT;
                        PH_DATA_IN:  reg_file[R_SCSI_STATUS] <= S_XFER_DATA_IN;
                        PH_COMMAND:  reg_file[R_SCSI_STATUS] <= S_XFER_CMD_OUT;
                        PH_STATUS:   reg_file[R_SCSI_STATUS] <= S_XFER_STATUS_IN;
                        // A completed MESSAGE OUT normally does not land here:
                        // the target moves to COMMAND as the last ACK falls,
                        // so `phase` is already PH_COMMAND by now and the arm
                        // above is the one taken. Command Phase was set to
                        // 0x20 back where ATN was dropped.
                        PH_MSG_OUT:  reg_file[R_SCSI_STATUS] <= S_XFER_MSG_OUT;
                        PH_MSG_IN:   reg_file[R_SCSI_STATUS] <= S_XFER_MSG_IN;
                        default:     reg_file[R_SCSI_STATUS] <= S_XFER_DATA_IN;
                    endcase
                    int_pending <= 1'b1;
                    // ST_IDLE, not the phase-reporting state. A real chip does
                    // report the next phase the target asks for after a
                    // completed TRANSFER INFO, and that was tried here; it
                    // changed nothing this machine does and it puts an extra
                    // interrupt into every PIO transfer, so it is left out
                    // until something needs it.
                    state <= ST_IDLE;
                end

                // ---- Select-and-Transfer -------------------------------
                ST_SAT_SEL: begin
                    sel_timer <= sel_timer + 16'd1;
                    if (!scsi_bsy) begin
                        scsi_sel   <= 1'b1;
                        data_latch <= (8'h01 << HOST_ID) | (8'h01 << reg_file[R_DEST_ID][2:0]);
                        state      <= ST_SAT_WAIT;
                    end else if (sel_timer >= SEL_TIMEOUT) begin
                        scsi_atn <= 1'b0;
                        cip      <= 1'b0;
                        reg_file[R_CMD_PHASE]   <= CP_DISCONNECTED;
                        reg_file[R_SCSI_STATUS] <= S_SELECT_TIMEOUT;
                        int_pending <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                ST_SAT_WAIT: begin
                    sel_timer <= sel_timer + 16'd1;
                    if (scsi_bsy && !bsy_q) begin
                        scsi_sel <= 1'b0;
                        reg_file[R_CMD_PHASE] <= CP_SELECTED;
                        state    <= ST_SAT_PHASE;
                    end else if (sel_timer >= SEL_TIMEOUT) begin
                        scsi_sel <= 1'b0;
                        scsi_atn <= 1'b0;   // see the note in ST_SEL_WAIT
                        cip      <= 1'b0;
                        reg_file[R_CMD_PHASE]   <= CP_DISCONNECTED;
                        reg_file[R_SCSI_STATUS] <= S_SELECT_TIMEOUT;
                        int_pending <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                // The target drives the whole sequence from here: it asks for
                // COMMAND, then whichever data direction the command implies,
                // then STATUS, then MESSAGE IN, then drops BSY. Following it
                // rather than driving a fixed order is what makes this work
                // for commands with no data phase as well as ones with.
                ST_SAT_PHASE: begin
// One line per bus phase the sequencer is offered. Build with
// +define+MSG_DEBUG; silent and free without it.
`ifdef MSG_DEBUG
                    $display("[INI] SAT_PHASE bsy=%b req=%b phase=%b atn=%b cdb_idx=%0d ident=%b", scsi_bsy, scsi_req, phase, scsi_atn, cdb_idx, sat_identify_sent);
`endif
                    // TRANSFER COUNT EXHAUSTED WITH THE TARGET STILL IN A
                    // DATA PHASE IS A PAUSE, NOT A WAIT - and not reporting
                    // it is what wedged fsck (docs/29). IRIX splits any
                    // transfer over its DMA map into segments (fsck's Phase 1
                    // inode read is 804,352 bytes; the map is 64 pages, so
                    // segment 1 was 261,808) and programs the count per
                    // segment. The real chip interrupts with 0x48|phase and
                    // COMMAND PHASE already at 0x46, unex_info() re-arms the
                    // count and the descriptor chain, and a new
                    // Select-and-Transfer resumes the same connection. This
                    // model set CP to 0x46 and then waited "for the target to
                    // move on" - which a target with 542 KB still to give
                    // never does. Beacon capture of the livelock: chip_rst /
                    // rst_load / c_reset / sel_xfer counters stepping every
                    // 60 s around an identical re-park at data_cnt=261808 of
                    // 804352, R_CMDPH=46, cip=1, intp=0.
                    //
                    // The settle counter exists because a NORMALLY completed
                    // transfer also shows {count==0, REQ, data phase} for a
                    // cycle or two while the target holds REQ past its last
                    // byte. ~126 us tells the two apart with three orders of
                    // margin each way.
                    if (scsi_bsy && scsi_req && (xfer_count == 24'd0) &&
                        (phase == PH_DATA_IN || phase == PH_DATA_OUT)) begin
                        sat_pause_cnt <= sat_pause_cnt + 12'd1;
                        if (&sat_pause_cnt) begin
                            cip         <= 1'b0;
                            dbr         <= 1'b0;
                            reg_file[R_SCSI_STATUS] <=
                                S_UNEX_INFO | {5'b0, phase};
                            int_pending <= 1'b1;
                            // dma_in_data is left alone: the data phase is
                            // still open, and the resume path below re-enters
                            // this state to finish it (or to take the STATUS
                            // phase transition, which is what pulses eop).
                            state       <= ST_IDLE;
                        end
                    end else
                        sat_pause_cnt <= 12'd0;

                    if (!scsi_bsy) begin
                        // Bus free: the target is done. If a DMA data phase
                        // was running it ends here too - see below.
                        if (dma_in_data) begin
                            dma_eop     <= 1'b1;
                            dma_in_data <= 1'b0;
                        end
                        state <= ST_SAT_END;
                    end else if (dma_in_data && phase != PH_DATA_IN
                                             && phase != PH_DATA_OUT) begin
                        // THE TARGET DECIDES WHEN A DATA PHASE ENDS, not the
                        // transfer count. A MODE SENSE answer shorter than the
                        // allocation length leaves count and descriptor both
                        // with room left, and the descriptor still has to
                        // complete or the channel never goes inactive and the
                        // next command finds it busy. One pulse, on the
                        // transition out of the data phase, is what says so.
                        dma_eop     <= 1'b1;
                        dma_in_data <= 1'b0;
                        // Stay here: the byte this new phase is asking for is
                        // handled on the next pass.
                    end else if (scsi_req) begin
                        case (phase)
                            // SELECT-WITH-ATN-AND-TRANSFER SENDS ITS OWN
                            // IDENTIFY. That is the whole difference between
                            // command 0x08 and 0x09, and the IP24 PROM issues
                            // 0x08. The chip builds the message from
                            // TARGET_LUN rather than taking it from the
                            // driver, and one byte is the whole message, so
                            // ATN comes down with it.
                            PH_MSG_OUT: begin
                                if (!sat_identify_sent) begin
                                    data_latch <= 8'h80 | {5'b0, reg_file[R_TARGET_LUN][2:0]};
                                    scsi_atn   <= 1'b0;
                                    sat_identify_sent <= 1'b1;
                                    state      <= ST_SAT_ACK;
                                end
                                // Otherwise wait here, without acknowledging
                                // anything, until the target moves on.
                            end
                            PH_COMMAND: begin
                                if (!sat_cdb_sent) begin
                                    data_latch <= reg_file[R_CDB1 + cdb_idx];
                                    state      <= ST_SAT_ACK;
                                end
                                // Otherwise wait here, exactly as MESSAGE OUT
                                // does above, until the target moves on.
                            end
                            // AND ONCE MORE AT THE END OF THE DATA PHASE.
                            // The target holds REQ for a cycle past the last
                            // byte of every phase before it changes the phase
                            // lines, and this sequencer reads REQ as a level,
                            // so each phase needs its own bound or it sends
                            // one byte too many. MESSAGE OUT's bound is
                            // sat_identify_sent, COMMAND's is sat_cdb_sent,
                            // and a data phase's is the Transfer Count - which
                            // is what the register is for on the real part: a
                            // Select-and-Transfer moves exactly the count it
                            // was given.
                            //
                            // Overrunning it costs more than a byte here. The
                            // descriptor has run out too, so the engine has
                            // nothing to answer with, and the initiator waits
                            // in ST_SAT_DMA forever with dma_req asserted -
                            // the command never interrupts and the driver
                            // times out.
                            PH_DATA_OUT: begin
                                if (xfer_count == 24'd0) begin
                                    // Count exhausted: no byte moves. A target
                                    // that promptly ends the phase is the
                                    // normal completion; one that stays is a
                                    // paused multi-segment transfer, and the
                                    // pause watchdog above this case reports
                                    // it to the driver.
                                end else if (use_dma) begin
                                    dma_req     <= 1'b1;
                                    dma_dir_in  <= 1'b0;
                                    dma_in_data <= 1'b1;
                                    state       <= ST_SAT_DMA;
                                end else if (!dbr) begin
                                    // Initiator sends. The driver must have
                                    // put a byte in the data register; DBR
                                    // says we want one, and we wait here until
                                    // it does.
                                    state <= ST_SAT_ACK;
                                end else begin
                                    dbr <= 1'b1;
                                end
                            end
                            // THE TARGET'S DATA IS NOT VALID THE CYCLE REQ
                            // RISES. scsi.v serves DATA IN out of a dual-port
                            // RAM whose output register is addressed by the
                            // byte counter, and that counter advances on the
                            // FALLING edge of the previous ACK - so the byte
                            // lands a few clocks after REQ. Its own header
                            // says so: the prefetch controller's timing
                            // contract in scsi_dpram is that q_b/q_c/q_d are
                            // consistent "no later than 7 clocks after the
                            // advance", and the MacLC initiator it was written
                            // for holds DREQ down for `dma_settle` = 8 cycles
                            // to cover exactly that.
                            //
                            // This sequencer had no equivalent and sampled on
                            // the cycle it saw REQ, which is one to two clocks
                            // after the advance. The result is subtle enough
                            // to have survived every boot: byte 0 is right,
                            // because the phase change gives it time, and
                            // every byte after it is the previous one. An
                            // INQUIRY response of mostly zeroes and a volume
                            // header of all zeroes both read back correct
                            // under that, which is why DATA IN has looked
                            // finished since the day it was written.
                            PH_DATA_IN: begin
                                if (xfer_count == 24'd0) begin
                                    // See PH_DATA_OUT.
                                end else if (use_dma) begin
                                    dma_dir_in  <= 1'b1;
                                    dma_in_data <= 1'b1;
                                    din_settle  <= DIN_SETTLE;
                                    state       <= ST_SAT_DIN;
                                end else if (!dbr) begin
                                    // Target sends. Take the byte and hold it
                                    // in the data register until the driver
                                    // reads it.
                                    data_latch <= scsi_din;
                                    dbr        <= 1'b1;
                                    state      <= ST_SAT_ACK;
                                end
                            end
                            PH_STATUS: begin
                                // The status byte lands in TARGET_LUN, which is
                                // where the driver looks for it after a
                                // Select-and-Transfer completes.
                                reg_file[R_TARGET_LUN] <= scsi_din;
                                reg_file[R_CMD_PHASE]  <= CP_RECV_STATUS;
                                state <= ST_SAT_ACK;
                            end
                            PH_MSG_IN: begin
                                reg_file[R_CMD_PHASE] <= CP_STATUS_RECVD;
                                state <= ST_SAT_ACK;
                            end
                            default: state <= ST_SAT_ACK;
                        endcase
                    end
                end

                // Wait out the target's access time, then take the byte.
                // data_latch is loaded too, so a driver that reads the DATA
                // register mid-transfer sees the last byte rather than stale
                // bus state; DBR stays clear, because nothing is waiting to be
                // collected.
                ST_SAT_DIN: begin
                    if (din_settle != 0) din_settle <= din_settle - 3'd1;
                    else begin
                        data_latch <= scsi_din;
                        dma_wdata  <= scsi_din;
                        dma_req    <= 1'b1;
                        state      <= ST_SAT_DMA;
                    end
                end

                // The byte is with the HPC3 DMA engine. It may be several
                // cycles away - the engine could be part way through fetching
                // a descriptor - so REQ is left asserted and the ACK the
                // target is waiting for is not raised until the byte has
                // actually moved.
                ST_SAT_DMA: begin
                    if (dma_ack) begin
                        dma_req <= 1'b0;
                        if (!dma_dir_in) data_latch <= dma_rdata;
                        state <= ST_SAT_ACK;
                    end
                end

                // ACK ONLY IN ANSWER TO A REQ THAT IS STILL THERE, and this
                // guard is not pedantry about the standard - without it this
                // core corrupts every long disk write.
                //
                // REQ/ACK is interlocked: the target asserts REQ, the
                // initiator answers with ACK, and the target latches the byte
                // on the ACK edge. But the target is also allowed to WITHDRAW
                // REQ before it has been answered, and scsi.v does exactly
                // that for flow control - `io_busy` drops REQ while the next
                // byte would land in the buffer half that is still being
                // flushed to the card (see the wr_pending note at
                // rtl/scsi/scsi.v:474). Acknowledging anyway makes it latch
                // the byte into the block it is writing out.
                //
                // The window is wide precisely here, because ST_SAT_DMA is
                // where the byte comes from and its own comment says so: the
                // engine "could be part way through fetching a descriptor".
                // Tens of cycles, every byte, with a real DDR3 behind it.
                //
                // MEASURED, on the disk the IRIX 5.3 installer wrote: of
                // 26,214,400 bytes copied from the CD, 37,925 wrong ones sat
                // at offset 0 of a 512-byte block and the other 511 offsets
                // were clean. Over the blocks whose ONLY bad byte was offset
                // 0, the byte that landed there was the first byte of block
                // N+2 in 4924 cases out of 4924 - and N+2 is the block that
                // shares a buffer half with N. tools/misterdeploy/imgdiff.py
                // and firstbyte.py are that measurement.
                //
                // Waiting cannot deadlock: the target still wants this byte,
                // so `data_cnt` has not advanced, `data_done` is false, and
                // REQ returns as soon as the flush completes.
                //
                // This is the third REQ-as-a-level race in this initiator,
                // after MESSAGE OUT (sat_identify_sent) and the CDB byte too
                // many. It is also the third fault this month that no
                // simulation could see, because verilator/sim_scsi.h answers a
                // flush instantly and the fill never gets two blocks ahead of
                // one in flight.
                ST_SAT_ACK: if (scsi_req) begin
                    scsi_ack <= 1'b1;
                    state    <= ST_SAT_REL;
                end

                ST_SAT_REL: begin
                    if (!scsi_req) begin
                        scsi_ack <= 1'b0;
                        case (phase)
                            PH_COMMAND: begin
                                reg_file[R_CMD_PHASE] <= CP_CMD_START + {4'h0, cdb_idx} + 8'd1;
                                if (cdb_idx + 4'd1 < cdb_len) cdb_idx <= cdb_idx + 4'd1;
                                else                          sat_cdb_sent <= 1'b1;
                            end
                            PH_DATA_OUT, PH_DATA_IN: begin
                                if (xfer_count != 24'd0) begin
                                    {reg_file[R_COUNT_MSB],
                                     reg_file[R_COUNT_2ND],
                                     reg_file[R_COUNT_LSB]} <= xfer_count - 24'd1;
                                    if (xfer_count == 24'd1)
                                        reg_file[R_CMD_PHASE] <= CP_XFER_COUNT;
                                end
                            end
                            PH_MSG_IN: reg_file[R_CMD_PHASE] <= CP_COMPLETE_MSG;
                            default: ;
                        endcase
                        state <= ST_SAT_PHASE;
                    end
                end

                ST_SAT_END: begin
                    cip      <= 1'b0;
                    scsi_atn <= 1'b0;
                    dbr      <= 1'b0;
                    dma_req  <= 1'b0;
                    reg_file[R_SCSI_STATUS] <= S_SELECT_XFER_OK;
                    int_pending <= 1'b1;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
