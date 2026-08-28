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
//  SCOPE. Stage 1: the register file, RESET, SELECT, and TRANSFER INFO with
//  data moving through the DATA register a byte at a time. That is enough for
//  the PROM's bus scan - TEST UNIT READY and INQUIRY - which is what clears
//  the POST failure. Select-and-Transfer (the chip's automatic mode, which is
//  what IRIX actually uses) and the HPC3 DMA path come after.
//============================================================================

module wd33c93 #(
    // The initiator's own SCSI ID. SGI uses 0 for the host adapter.
    parameter logic [2:0] HOST_ID = 3'd0
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    // ---- register interface ---------------------------------------------
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

    output logic        irq
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
    localparam logic [7:0] S_SELECT_OK      = 8'h11;
    localparam logic [7:0] S_XFER_DATA_OUT  = 8'h18;  // target wants DATA OUT
    localparam logic [7:0] S_XFER_DATA_IN   = 8'h19;  // target is sending DATA IN
    localparam logic [7:0] S_XFER_STATUS_IN = 8'h1B;
    localparam logic [7:0] S_XFER_MSG_IN    = 8'h1F;
    localparam logic [7:0] S_XFER_CMD_OUT   = 8'h1A;  // target wants COMMAND
    localparam logic [7:0] S_INVALID_CMD    = 8'h40;
    localparam logic [7:0] S_SELECT_TIMEOUT = 8'h42;
    localparam logic [7:0] S_DISCONNECT     = 8'h85;

    // ---- COMMAND PHASE register values -------------------------------------
    // The chip walks this register through a Select-and-Transfer so a driver
    // that takes an interrupt part way can tell how far it got and resume.
    // Values from IRIS's src/wd33c93a.rs, which matches IRIX's wd93.h.
    localparam logic [7:0] CP_DISCONNECTED = 8'h00;
    localparam logic [7:0] CP_SELECTED     = 8'h10;
    localparam logic [7:0] CP_CMD_START    = 8'h30;   // +n as CDB bytes go out
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
    localparam logic [2:0] PH_MSG_IN   = 3'b111;

    // ---- transfer counter --------------------------------------------------
    // 24 bits, MSB first across three registers, as the chip presents it.
    wire [23:0] xfer_count = {reg_file[R_COUNT_MSB],
                              reg_file[R_COUNT_2ND],
                              reg_file[R_COUNT_LSB]};

    // ---- sequencer ----------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_SEL_ASSERT,      // drive SEL with the target's ID
        ST_SEL_WAIT,        // wait for the target to answer with BSY
        ST_SEL_DONE,
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

    // The byte in flight, and which way it is going.
    logic [7:0] data_latch;
    // How far through the CDB a Select-and-Transfer has got. The length comes
    // from the group code in the top three bits of the opcode: group 0 is a
    // 6-byte CDB, groups 1 and 2 are 10, group 5 is 12. Anything else is
    // treated as 6, which is what the chip does with an unknown group beyond
    // also flagging it.
    logic [3:0] cdb_idx;
    wire  [2:0] cdb_group = reg_file[R_CDB1][7:5];
    wire  [3:0] cdb_len   = (cdb_group == 3'd1 || cdb_group == 3'd2) ? 4'd10
                          : (cdb_group == 3'd5)                      ? 4'd12
                          :                                            4'd6;
    wire        to_target = (phase == PH_DATA_OUT) || (phase == PH_COMMAND);

    assign scsi_dout = data_latch;
    assign scsi_rst  = 1'b0;         // driven by the RESET command below, not held
    assign irq       = int_pending;

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

    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) reg_file[i] <= 8'h00;
            reg_file[R_OWN_ID] <= {5'b0, HOST_ID};
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
            dout_r      <= 8'h00;
        end else if (ce) begin

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
                                if (cip) begin
                                    // The chip ignores a command issued while
                                    // one is running and says so in LCI rather
                                    // than corrupting the one in flight.
                                    lci <= 1'b1;
                                end else begin
                                    reg_file[R_COMMAND] <= din;
                                    lci <= 1'b0;
                                    case (din)
                                        C_RESET: begin
                                            reg_file[R_SCSI_STATUS] <= S_RESET;
                                            int_pending <= 1'b1;
                                            state       <= ST_IDLE;
                                            scsi_sel    <= 1'b0;
                                            scsi_ack    <= 1'b0;
                                            scsi_atn    <= 1'b0;
                                            dbr         <= 1'b0;
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
                                            scsi_atn  <= (din == C_SEL_ATN_XFER);
                                            cip       <= 1'b1;
                                            sel_timer <= 16'h0;
                                            cdb_idx   <= 4'd0;
                                            reg_file[R_CMD_PHASE] <= CP_DISCONNECTED;
                                            state     <= ST_SAT_SEL;
                                        end
                                        C_NEGATE_ACK: scsi_ack <= 1'b0;
                                        C_ASSERT_ATN: scsi_atn <= 1'b1;
                                        C_DISCONNECT: begin
                                            scsi_sel <= 1'b0;
                                            scsi_ack <= 1'b0;
                                            scsi_atn <= 1'b0;
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
                        if (ar == R_SCSI_STATUS) int_pending <= 1'b0;
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
                    scsi_sel  <= 1'b1;
                    data_latch<= (8'h01 << HOST_ID) | (8'h01 << reg_file[R_DEST_ID][2:0]);
                    state     <= ST_SEL_WAIT;
                end

                // A present target answers selection by asserting BSY. An
                // absent one never does, and the timeout is the only thing
                // that ends a scan of the seven IDs with nothing on them.
                ST_SEL_WAIT: begin
                    sel_timer <= sel_timer + 16'd1;
                    if (scsi_bsy) begin
                        scsi_sel <= 1'b0;
                        state    <= ST_SEL_DONE;
                    end else if (sel_timer >= SEL_TIMEOUT) begin
                        scsi_sel <= 1'b0;
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
                    state <= ST_IDLE;
                end

                // One byte per REQ. The driver either wrote the byte into the
                // data register before issuing TRANSFER INFO (to-target
                // phases) or reads it out afterwards (from-target phases);
                // DBR is what tells it which way round it is.
                ST_XFER: begin
                    if (!scsi_bsy) begin
                        // The target let go of the bus mid-transfer.
                        cip <= 1'b0;
                        reg_file[R_SCSI_STATUS] <= S_DISCONNECT;
                        int_pending <= 1'b1;
                        state <= ST_IDLE;
                    end else if (scsi_req) begin
                        if (!to_target) data_latch <= scsi_din;
                        state <= ST_XFER_ACK;
                    end
                end

                ST_XFER_ACK: begin
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
                        PH_MSG_IN:   reg_file[R_SCSI_STATUS] <= S_XFER_MSG_IN;
                        default:     reg_file[R_SCSI_STATUS] <= S_XFER_DATA_IN;
                    endcase
                    int_pending <= 1'b1;
                    state <= ST_IDLE;
                end

                // ---- Select-and-Transfer -------------------------------
                ST_SAT_SEL: begin
                    scsi_sel   <= 1'b1;
                    data_latch <= (8'h01 << HOST_ID) | (8'h01 << reg_file[R_DEST_ID][2:0]);
                    state      <= ST_SAT_WAIT;
                end

                ST_SAT_WAIT: begin
                    sel_timer <= sel_timer + 16'd1;
                    if (scsi_bsy) begin
                        scsi_sel <= 1'b0;
                        reg_file[R_CMD_PHASE] <= CP_SELECTED;
                        state    <= ST_SAT_PHASE;
                    end else if (sel_timer >= SEL_TIMEOUT) begin
                        scsi_sel <= 1'b0;
                        cip      <= 1'b0;
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
                    if (!scsi_bsy) begin
                        // Bus free: the target is done.
                        state <= ST_SAT_END;
                    end else if (scsi_req) begin
                        case (phase)
                            PH_COMMAND: begin
                                data_latch <= reg_file[R_CDB1 + cdb_idx];
                                state      <= ST_SAT_ACK;
                            end
                            PH_DATA_OUT: begin
                                // Initiator sends. The driver must have put a
                                // byte in the data register; DBR says we want
                                // one, and we wait here until it does.
                                if (!dbr) state <= ST_SAT_ACK;
                                else      dbr   <= 1'b1;
                            end
                            PH_DATA_IN: begin
                                // Target sends. Take the byte and hold it in
                                // the data register until the driver reads it.
                                if (!dbr) begin
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

                ST_SAT_ACK: begin
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
                    reg_file[R_SCSI_STATUS] <= S_SELECT_XFER_OK;
                    int_pending <= 1'b1;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
