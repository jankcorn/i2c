module master #(
    // 50 MHz is commonly available in many FPGAs. Must be at least 4 times the scl rate.
    parameter INPUT_CLK_RATE = 50000000,
    // Targeted i2c frequency. Maximum depends on the desired mode.
    parameter TARGET_SCL_RATE = 100000,

    // Is a slave on the bus capable of clock stretching? (if unsure, safer to assume yes)
    parameter CLOCK_STRETCHING = 1,

    // Are there multiple masters? (if unsure, safer to assume yes but more efficient to assume no)
    parameter MULTI_MASTER = 0,

    // If there are multiple masters, detecting an scl line stuck LOW for bus_clear depends on knowing how slow the slowest master is.
    parameter SLOWEST_MASTER_RATE = 100,

    // "For a single master application, the master’s SCL output can be a push-pull driver design if there are no devices on the bus which would stretch the clock."
    // When using a push-pull driver, driving the scl line to HIGH while another device is driving it to LOW will create a short circuit, damaging your FPGA.
    // If you enable the below parameter, you must be certain that this will not happen, and you accept the risks if it does.
    parameter FORCE_PUSH_PULL = 0
) (
    inout logic scl,
    input logic clk_in, // an arbitrary clock, used to derive the scl clock
    output logic bus_clear,

    inout logic sda,
    input logic mode, // 0 = transmit, 1 = receive

    // These two flags are exclusive; a transfer can't continue if a new one is starting
    input logic transfer_start, // begin a new transfer asap (repeated START, START)
    input logic transfer_continue, // whether transfer continues AFTER this transaction. If not, a STOP or repeated START is issued.

    output logic transfer_ready, // ready for a new transfer (bus is not busy)

    output logic interrupt = 1'b1, // A transaction has completed or an error occurred.
    output logic transaction_complete, // ready for a new transaction
    output logic nack = 1'b0, // Whether an ACK/NACK was received/sent for the last transaction (0 = ACK, 1 = NACK)

    input logic [7:0] data_tx,
    output logic [7:0] data_rx,

    // The below outputs matter ONLY IF there are multiple masters on the bus
    output logic start_err = 1'd0, // Another master illegally issued a START condition while the bus was busy
    output logic arbitration_err = 1'b0 // Another master won the transaction due to arbitration, (or issued a START condition, when the user of this master wanted to)
);
localparam MODE = $unsigned(TARGET_SCL_RATE) <= 100000 ? 0 : $unsigned(TARGET_SCL_RATE) <= 400000 ? 1 : $unsigned(TARGET_SCL_RATE) <= 1000000 ? 2 : -1;
localparam COUNTER_WIDTH = $clog2($unsigned(INPUT_CLK_RATE) / $unsigned(TARGET_SCL_RATE));
localparam COUNTER_END = COUNTER_WIDTH'($unsigned(INPUT_CLK_RATE) / $unsigned(TARGET_SCL_RATE) - 1);
// Conforms to Table 10 tLOW, tHIGH for SCL clock.
localparam COUNTER_HIGH = COUNTER_WIDTH'(MODE == 0 ? (COUNTER_END + 1) / 2 : ((COUNTER_END + 1) * 2) / 3);
// Conforms to Table 10 tr, rise time for SCL clock.
localparam COUNTER_RISE = COUNTER_WIDTH'($ceil($unsigned(INPUT_CLK_RATE) / 1.0E9 * $unsigned(MODE == 0 ? 1000 : MODE == 1 ? 300 : MODE == 2  ? 120 : 0)));
localparam WAIT_WIDTH = $clog2(2 * $unsigned(INPUT_CLK_RATE) / $unsigned(SLOWEST_MASTER_RATE));
localparam WAIT_END = WAIT_WIDTH'(2 * $unsigned(INPUT_CLK_RATE) / $unsigned(SLOWEST_MASTER_RATE) - 1);

logic [COUNTER_WIDTH-1:0] counter;
logic [COUNTER_WIDTH-1:0] countdown = COUNTER_WIDTH'(0); // hold high counter
logic busy = 1'b0;
logic [3:0] transaction_progress = 4'd0;

logic release_line;
assign release_line = (!busy && transaction_progress == 4'd0) || countdown > 0 || (busy && transaction_progress == 4'd0 && MULTI_MASTER);

clock #(
    .COUNTER_WIDTH(COUNTER_WIDTH),
    .COUNTER_END(COUNTER_END),
    .COUNTER_HIGH(COUNTER_HIGH),
    .COUNTER_RISE(COUNTER_RISE),
    .MULTI_MASTER(MULTI_MASTER),
    .CLOCK_STRETCHING(CLOCK_STRETCHING),
    .WAIT_WIDTH(WAIT_WIDTH),
    .WAIT_END(WAIT_END),
    .PUSH_PULL(!CLOCK_STRETCHING && !MULTI_MASTER && FORCE_PUSH_PULL)
) clock (.scl(scl), .clk_in(clk_in), .release_line(release_line), .bus_clear(bus_clear), .counter(counter));

logic sda_internal = 1'b1;
assign sda = sda_internal ? 1'bz : 1'b0;


// See Section 3.1.4: START and STOP conditions
logic start_by_another_master = 1'b0;
`ifdef MODEL_TECH
always @(sda === 1'bz or sda === 1'b0)
begin
    if (scl === 1'bz)
    begin
        busy <= sda === 1'b0;
        if (sda === 1'b0)
            $display("Master becomes busy @ %d %d", counter, transaction_progress);
        else
            $display("Master becomes free @ %d %d", counter, transaction_progress);
        // See Note 4 in Section 3.1.10
        // Should only trigger if a start occurs while this master was in the middle of something.
        if (busy && sda == 1'b0 && transaction_progress != 4'd0 && transaction_progress != 4'd11 && MULTI_MASTER)
            start_by_another_master <= 1'd1;
    end
end
`else
always @(posedge sda or negedge sda)
begin
    if (scl)
    begin
        busy <= !sda;
        // See Note 4 in Section 3.1.10
        // Should only trigger if a start occurs while this master was in the middle of something.
        if (busy && !sda && transaction_progress != 4'd0 && transaction_progress != 4'd11 && MULTI_MASTER)
            start_by_another_master <= 1'd1;
    end
end
`endif

localparam TLOW_MIN = MODE == 0 ? 4.7 : MODE == 1 ? 1.3 : MODE == 2 ? 0.5 : 0; // in microseconds
localparam THIGH_MIN = MODE == 0 ? 4.0 : MODE == 1 ? 0.6 : MODE == 2 ? 0.26 : 0; // in microseconds
localparam COUNTER_SETUP_REPEATED_START = COUNTER_WIDTH'($ceil($unsigned(INPUT_CLK_RATE)/1E6 * TLOW_MIN));
localparam COUNTER_HOLD_REPEATED_START = COUNTER_WIDTH'($ceil($unsigned(INPUT_CLK_RATE)/1E6 * THIGH_MIN));
localparam COUNTER_SETUP_STOP = COUNTER_HOLD_REPEATED_START;
localparam COUNTER_BUS_FREE = COUNTER_SETUP_REPEATED_START;

localparam COUNTER_TRANSMIT = COUNTER_WIDTH'(COUNTER_HIGH / 2);
localparam COUNTER_RECEIVE = COUNTER_WIDTH'((COUNTER_END - COUNTER_HIGH + 1) / 2 + COUNTER_HIGH);
// There's a one time-step difference above from the clock generator.

logic latched_mode;
logic [7:0] latched_data;
logic latched_transfer_continue;
logic latched_transfer_start;

assign data_rx = latched_data;
assign transfer_ready = counter == COUNTER_HIGH && !busy && countdown == 0;

always @(posedge clk_in)
begin
    start_err = start_by_another_master;

    // transmitter listens for loss of arbitration on receive
    // treats a start by another master as no loss of arbitration
    arbitration_err = counter == COUNTER_RECEIVE && busy && transaction_progress >= 4'd2 && transaction_progress < 4'd10 && !latched_mode && MULTI_MASTER && sda != latched_data[4'd9 - transaction_progress] && !start_by_another_master;

    transaction_complete = counter == COUNTER_RECEIVE - 1 && busy && transaction_progress == 4'd10 && !start_by_another_master;
    // transmitter notes whether ACK/NACK was received
    // receiver notes whether ACK/NACK was sent
    // treats a start by another master as as an ACK
    `ifdef MODEL_TECH
        nack = transaction_complete && sda === 1'bz && !start_by_another_master;
    `else
        nack = transaction_complete && sda && !start_by_another_master;
    `endif

    interrupt = start_err || arbitration_err || transaction_complete;

    // See Note 4 in Section 3.1.10
    if (start_err || arbitration_err)
    begin
        sda_internal <= 1'b1; // release line
        transaction_progress <= 4'd0;
        start_by_another_master <= 1'b0; // synchronous reset
        countdown <= COUNTER_WIDTH'(0);
    end
    // Keep current state to meet setup/hold constraints
    else if (countdown > 0)
    begin
        countdown <= countdown - 1'b1;
    end
    else if (counter == COUNTER_HIGH)
    begin
        // TODO: what if the user saw transfer_ready and put in some stuff, but then busy went high before COUNTER_RECEIVE and now the transaction can't start? user thinks transaction began but it didn't, and there should be an arbitration error later on
        if (((!busy && transaction_progress == 4'd0) || (busy && transaction_progress == 4'd11)) && transfer_start)
        begin
            transaction_progress <= 4'd1;
            latched_mode <= mode;
            // if (!mode) // Mode doesn't matter, save some logic cells
            latched_data <= data_tx;
            latched_transfer_continue <= transfer_continue;
        end
        if (transaction_progress == 4'd11) // Setup time padding for repeated start, stop
        begin
            if (transfer_start)
                countdown <= COUNTER_SETUP_REPEATED_START - (COUNTER_RECEIVE - COUNTER_HIGH);
            else
                countdown <= COUNTER_SETUP_STOP - (COUNTER_RECEIVE - COUNTER_HIGH);
        end
    end
    // "The data on the SDA line must be stable during the HIGH period of the clock."
    else if (counter == COUNTER_RECEIVE)
    begin
        if (transaction_progress > 0)
        // START or repeated START condition
        if (!busy && (transaction_progress == 4'd1 || transaction_progress == 4'd11))
        begin
            sda_internal <= 1'b0;
            if (transaction_progress == 4'd11) // Hold time padding
                countdown <= COUNTER_HOLD_REPEATED_START - (COUNTER_END - COUNTER_RECEIVE);
        end
        // See Section 3.1.5. Shift in data.
        else if (busy && transaction_progress >= 4'd2 && transaction_progress < 4'd10 && latched_mode)
        begin
            `ifdef MODEL_TECH
                latched_data[4'd9 - transaction_progress] <= sda === 1'bz;
            `else
                latched_data[4'd9 - transaction_progress] <= sda;
            `endif
                sda_internal <= 1'b1; // Helps reduce slave rise time
        end
        // See Section 3.1.6. Transmitter got an acknowledge bit or receiver sent it.
        // sda value must be ACK, agnostic of transmit/receive
        // transaction continues immediately in the next LOW, latch now
        // delayed by a clock here so that user input after transaction_complete can be ready
        else if (busy && transaction_progress == 4'd10 && latched_transfer_continue && !sda)
        begin
            transaction_progress <= 4'd1;
            latched_mode <= mode;
            // if (!mode) // Mode doesn't matter, save some logic cells
            latched_data <= data_tx;
            latched_transfer_continue <= transfer_continue;
        end
        // STOP condition
        else if (busy && transaction_progress == 4'd11 && !sda)
        begin
            sda_internal <= 1'b1;
            transaction_progress <= 4'd0;
            countdown <= COUNTER_BUS_FREE - (COUNTER_END - COUNTER_RECEIVE);
        end
        // Another master is doing a transaction (void messages tolerated, see Note 5 in Section 3.1.10)
        else if (busy && transaction_progress == 4'd0 && MULTI_MASTER)
            sda_internal <= 1'b1;
    end
    // "The HIGH or LOW state of the data line can only change when the clock signal on the SCL line is LOW"
    else if (counter == COUNTER_TRANSMIT && busy && transaction_progress != 4'd0)
    begin
        transaction_progress <= transaction_progress + 4'd1;
        // See Section 3.1.5. Shift out data.
        if (transaction_progress < 4'd9)
        begin
            if (!latched_mode)
                sda_internal <= latched_data[4'd8 - transaction_progress];
            else
                sda_internal <= 1'b1; // release line for RX
        end
        // See Section 3.1.6. Expecting an acknowledge bit transfer in the next HIGH.
        else if (transaction_progress == 4'd9)
            sda_internal <= !(latched_mode && latched_transfer_continue); // receiver sends ACK / NACK, transmitter releases line
        // See Section 3.1.4
        else if (transaction_progress == 4'd10)
        begin
            sda_internal <= transfer_start; // prepare for repeated START condition or STOP condition
        end
    end
end

endmodule
