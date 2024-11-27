module stream_prefetcher (
    input logic clk,
    input logic rst,
    input logic [31:0] miss_address,
    input logic miss,
    input logic store_clean,
    input logic dma_pkt_v_o, // Snoop signal for DMA packet valid
    input logic cache_pkt_v_o, // Snoop signal for cache valid output
    output logic [31:0] prefetch_address,
    output logic prefetch_valid,
    output logic [31:0] prefetch_buffer_data_out // Prefetch buffer data output
);

// Parameters
localparam int PREFETCH_DEGREE = 4;
localparam int STREAM_TABLE_SIZE = 8;

// Stream table entry structure
typedef struct packed {
    logic [31:0] start_address;
    logic [31:0] last_address;
    logic [1:0] miss_count;
    logic valid;
} stream_entry_t;

// Stream table
stream_entry_t stream_table[STREAM_TABLE_SIZE];

// Prefetch buffer
logic [31:0] prefetch_buffer[STREAM_TABLE_SIZE];
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
logic [31:0] stride;
logic [31:0] next_prefetch_address;
logic next_prefetch_valid;

// State transition logic
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        current_state <= IDLE;
        prefetch_buffer_valid <= '0; // Reset prefetch buffer validity
    end else begin
        current_state <= next_state;
    end
end

// Next state and output logic
always_comb begin
    next_state = current_state;
    next_prefetch_address = prefetch_address;
    next_prefetch_valid = 1'b0;

    case (current_state)
        IDLE: begin
            if (miss) next_state = CHECK_STREAM;
            else if (store_clean) next_state = STORE_CLEAN;
        end

        CHECK_STREAM: begin
            for (int i = 0; i < STREAM_TABLE_SIZE; i++) begin
                if (stream_table[i].valid && 
                    (miss_address > stream_table[i].last_address) && 
                    (miss_address - stream_table[i].last_address <= 32'd64)) begin
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
                stride = miss_address - stream_table[current_stream].start_address;
                next_prefetch_address = miss_address + stride;
                next_prefetch_valid = 1'b1;

                // Store prefetched data in buffer if DMA packet is valid (indicating a miss)
                if (dma_pkt_v_o) begin
                    prefetch_buffer[current_stream] <= next_prefetch_address; // Example assignment, replace with actual data handling
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

        STORE_CLEAN: begin
            for (int i = 0; i < STREAM_TABLE_SIZE; i++) begin
                if (stream_table[i].valid && stream_table[i].miss_count == 2'd2) begin
                    next_prefetch_address = stream_table[i].last_address + stride;
                    next_prefetch_valid = 1'b1;
                    break;
                end
            end
            next_state = IDLE;
        end

        default: next_state = IDLE;

    endcase

end

// Output and state update logic with snooping and buffer handling.
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        foreach (stream_table[i]) begin
            stream_table[i] <= '0;
        end
        
        prefetch_address <= '0;
        prefetch_valid <= 1'b0;

        // Reset all buffers and validity flags on reset.
        foreach(prefetch_buffer[i]) begin 
            prefetch_buffer[i] <= '0; 
            prefetch_buffer_valid[i] <= '0; 
        end
        
    end else begin
        
        // Update outputs based on FSM state.
        prefetch_address <= next_prefetch_address; 
        prefetch_valid <= next_prefetch_valid;

        case (current_state)
            
            UPDATE_STREAM: begin
                
                // Update stream table with new miss address and increment miss count.
                stream_table[current_stream].last_address <= miss_address; 
                stream_table[current_stream].miss_count <= stream_table[current_stream].miss_count + 1'b1;

                // Store prefetched data in buffer if DMA packet is valid.
                if(dma_pkt_v_o) begin 
                    prefetch_buffer[current_stream] <= dma_pkt_o.addr; // Example assignment, replace with actual data handling.
                    prefetch_buffer_valid[current_stream] <= 1'b1; 
                end
                
            end
            
            CREATE_STREAM: begin
                
                // Create new entry in stream table for current miss address.
                stream_table[current_stream].start_address <= miss_address; 
                stream_table[current_stream].last_address <= miss_address; 
                stream_table[current_stream].miss_count <= 2'd1; 
                stream_table[current_stream].valid <= 1'b1;

            end
            
            STORE_CLEAN: begin
                
                // Iterate over all streams and store prefetched data in buffer.
                for(int i=0;i<STREAM_TABLE_SIZE;i++)begin 
                    if(stream_table[i].valid && stream_table[i].miss_count==2'd2)begin 
                        prefetch_buffer[i]<=stream_table[i].last_address+stride; 
                        prefetch_buffer_valid[i]<=1'b1; 
                        break; 
                    end 
                end
                
            end
            
            default:;
            
        endcase
        
        
        // Handle reading from buffer instead of cache when requested.
        
        if(cache_pkt_v_o && cache_pkt_i.addr==prefetch_buffer[current_stream])begin
            
             // Check if requested address matches any prefetched address in buffer.
             prefetch_buffer_data_out<=prefetch_buffer[current_stream]; 
             prefetch_buffer_valid[current_stream]<=1'b0; // Mark as invalid after use.
             
         end 
        
     end 
    
end 

endmodule
