`include "bsg_defines.sv"

module stream_prefetcher #(
    parameter addr_width_p = 32,
    parameter data_width_p = 32
) (
    input logic clk_i,
    input logic reset_i,
    input logic [addr_width_p-1:0] miss_addr_i,
    input logic miss_v_i,
    input logic dma_pkt_v_i,
    input logic cache_pkt_v_i,
    input logic [addr_width_p-1:0] cache_pkt_addr_i,
    output logic [addr_width_p-1:0] prefetch_addr_o,
    output logic prefetch_v_o,
    output logic [data_width_p-1:0] prefetch_data_o
);

    // Parameters
    localparam int PREFETCH_DEGREE = 4;
    localparam int STREAM_TABLE_SIZE = 8;

    // Stream table entry structure
    typedef struct packed {
        logic [addr_width_p-1:0] start_address;
        logic [addr_width_p-1:0] last_address;
        logic [1:0] miss_count;
        logic valid;
    } stream_entry_t;

    // Stream table
    stream_entry_t stream_table[STREAM_TABLE_SIZE];

    // Prefetch buffer
    logic [addr_width_p-1:0] prefetch_buffer[STREAM_TABLE_SIZE];
    logic [STREAM_TABLE_SIZE-1:0] prefetch_buffer_valid;

    // FSM states
    typedef enum logic [2:0] {
        IDLE,
        CHECK_STREAM,
        UPDATE_STREAM,
        CREATE_STREAM,
        PREFETCH,
        STORE_CLEAN
    } state_t;

    // State variables
    state_t current_state, next_state;

    // Internal signals
    logic [2:0] current_stream;
    logic [addr_width_p-1:0] stride;
    logic [addr_width_p-1:0] next_prefetch_addr;
    logic next_prefetch_v;

    // State transition logic
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            current_state <= IDLE;
            prefetch_buffer_valid <= '0;
        end else begin
            current_state <= next_state;
        end
    end

    // Next state and output logic
    always_comb begin
        next_state = current_state;
        next_prefetch_addr = prefetch_addr_o;
        next_prefetch_v = 1'b0;

        case (current_state)
            IDLE: begin
                if (miss_v_i) next_state = CHECK_STREAM;
            end

            CHECK_STREAM: begin
                for (int i = 0; i < STREAM_TABLE_SIZE; i++) begin
                    if (stream_table[i].valid && 
                        (miss_addr_i > stream_table[i].last_address) && 
                        (miss_addr_i - stream_table[i].last_address <= 64)) begin
                        current_stream = i[2:0];
                        next_state = UPDATE_STREAM;
                        break;
                    end
                end
                if (next_state == CHECK_STREAM) next_state = CREATE_STREAM;
            end

            UPDATE_STREAM: begin
                if (stream_table[current_stream].miss_count == 2'd1) begin
                    next_state = PREFETCH;
                    stride = miss_addr_i - stream_table[current_stream].start_address;
                    next_prefetch_addr = miss_addr_i + stride;
                    next_prefetch_v = 1'b1;

                    if (dma_pkt_v_i) begin
                        prefetch_buffer[current_stream] <= next_prefetch_addr;
                        prefetch_buffer_valid[current_stream] <= 1'b1;
                    end
                end else begin
                    next_state = IDLE;
                end
            end

            CREATE_STREAM: begin
                for (int i = 0; i < STREAM_TABLE_SIZE; i++) begin
                    if (!stream_table[i].valid) begin
                        current_stream = i[2:0];
                        break;
                    end
                end
                next_state = IDLE;
            end

            PREFETCH: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Output and state update logic
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            foreach (stream_table[i]) begin
                stream_table[i] <= '0;
            end
            
            prefetch_addr_o <= '0;
            prefetch_v_o <= 1'b0;
            prefetch_data_o <= '0;

            foreach(prefetch_buffer[i]) begin 
                prefetch_buffer[i] <= '0; 
                prefetch_buffer_valid[i] <= '0; 
            end
            
        end else begin
            prefetch_addr_o <= next_prefetch_addr; 
            prefetch_v_o <= next_prefetch_v;

            case (current_state)
                UPDATE_STREAM: begin
                    stream_table[current_stream].last_address <= miss_addr_i; 
                    stream_table[current_stream].miss_count <= stream_table[current_stream].miss_count + 1'b1;

                    if(dma_pkt_v_i) begin 
                        prefetch_buffer[current_stream] <= next_prefetch_addr;
                        prefetch_buffer_valid[current_stream] <= 1'b1; 
                    end
                end
                
                CREATE_STREAM: begin
                    stream_table[current_stream].start_address <= miss_addr_i; 
                    stream_table[current_stream].last_address <= miss_addr_i; 
                    stream_table[current_stream].miss_count <= 2'd1; 
                    stream_table[current_stream].valid <= 1'b1;
                end
                
                default: ;
            endcase
            
            if(cache_pkt_v_i && cache_pkt_addr_i == prefetch_buffer[current_stream]) begin
                prefetch_data_o <= prefetch_buffer[current_stream]; 
                prefetch_buffer_valid[current_stream] <= 1'b0;
            end 
        end 
    end 

endmodule