`include "bsg_defines.sv"

module streamprefetcher #(
  parameter addr_width_p = 32,
  parameter data_width_p = 32,
  parameter block_size_in_words_p = 8
) (
  input logic clk_i,
  input logic reset_i,

  // Miss interface from bsg_cache
  input logic [addr_width_p-1:0] miss_addr_i,
  input logic miss_v_i,

  // Indicates if DMA is currently busy (from bsg_cache_miss)
  input logic dma_busy_i,

  // Prefetch line (entire block) returned from DMA after a prefetch request
  // It's assumed that dma_prefetch_data_i is the entire line: data_width_p*block_size_in_words_p bits
  input logic [data_width_p*block_size_in_words_p-1:0] dma_prefetch_data_i,
  input logic dma_prefetch_data_v_i,

  // Cache request interface to check if prefetched data is useful
  input logic cache_pkt_v_i,
  input logic [addr_width_p-1:0] cache_pkt_addr_i,

  // Prefetch request output to miss handler
  output logic prefetch_dma_req_o,
  output logic [addr_width_p-1:0] prefetch_dma_addr_o,

  // Prefetched data to cache if it matches request
  output logic [data_width_p*block_size_in_words_p-1:0] prefetch_data_o,
  output logic prefetch_data_v_o
);

  // FSM states
  typedef enum logic [2:0] {
    IDLE,
    CHECK_STREAM,
    UPDATE_STREAM,
    CREATE_STREAM,
    PREFETCH,
    STORE_CLEAN
  } state_t;

  state_t state_r, state_n;

  // Internal registers
  logic have_first_miss_r, have_first_miss_n;
  logic [addr_width_p-1:0] last_miss_addr_r, last_miss_addr_n;
  logic [addr_width_p-1:0] stride_r, stride_n;
  logic valid_stride_r, valid_stride_n;

  // Prefetched line storage
  logic [data_width_p*block_size_in_words_p-1:0] prefetched_line_r, prefetched_line_n;
  logic prefetched_valid_r, prefetched_valid_n;
  logic [addr_width_p-1:0] prefetched_addr_r, prefetched_addr_n;

  // Outputs default
  always_comb begin
    prefetch_dma_req_o = 1'b0;
    prefetch_dma_addr_o = '0;
    prefetch_data_v_o = 1'b0;
    prefetch_data_o = '0;

    // Default next-state assignments
    state_n = state_r;
    have_first_miss_n = have_first_miss_r;
    last_miss_addr_n = last_miss_addr_r;
    stride_n = stride_r;
    valid_stride_n = valid_stride_r;
    prefetched_line_n = prefetched_line_r;
    prefetched_valid_n = prefetched_valid_r;
    prefetched_addr_n = prefetched_addr_r;

    unique case (state_r)
      IDLE: begin
        // Wait for a miss
        if (miss_v_i) begin
          have_first_miss_n = 1'b1;
          last_miss_addr_n = miss_addr_i;
          valid_stride_n = 1'b0;
          state_n = CHECK_STREAM;
        end
      end

      CHECK_STREAM: begin
        // We have one miss recorded. Wait for another miss to determine stride.
        if (miss_v_i) begin
          logic [addr_width_p-1:0] new_stride = miss_addr_i - last_miss_addr_r;
          last_miss_addr_n = miss_addr_i;
          if (new_stride != '0) begin
            // We found a potential stride
            stride_n = new_stride;
            valid_stride_n = 1'b1;
          end else begin
            // no valid stride yet
            valid_stride_n = 1'b0;
          end
          state_n = UPDATE_STREAM;
        end
      end

      UPDATE_STREAM: begin
        // If we have a valid stride, we can attempt to prefetch.
        if (valid_stride_r) begin
          // Move on to create a "stream" concept and request prefetch
          state_n = CREATE_STREAM;
        end else begin
          // No stride found yet, go back to IDLE and wait for more misses
          state_n = IDLE;
        end
      end

      CREATE_STREAM: begin
        // Attempt to issue a prefetch if not busy
        // Prefetch next block: last_miss_addr_r + stride_r
        if (!dma_busy_i && valid_stride_r) begin
          prefetch_dma_req_o = 1'b1;
          prefetch_dma_addr_o = last_miss_addr_r + stride_r;
          // Store the prefetch target address, so we know what we fetched
          prefetched_addr_n = last_miss_addr_r + stride_r;
          state_n = PREFETCH;
        end else begin
          // Wait until DMA is free
          state_n = CREATE_STREAM;
        end
      end

      PREFETCH: begin
        // Waiting for DMA data
        if (dma_prefetch_data_v_i) begin
          // Store the entire prefetched line
          prefetched_line_n = dma_prefetch_data_i;
          prefetched_valid_n = 1'b1;
          // Once we have data, move to STORE_CLEAN
          state_n = STORE_CLEAN;
        end
      end

      STORE_CLEAN: begin
        // We have a prefetched line stored.
        // If CPU requests it at prefetched_addr_r, give it out once.
        if (cache_pkt_v_i && prefetched_valid_r && (cache_pkt_addr_i == prefetched_addr_r)) begin
          prefetch_data_v_o = 1'b1;
          prefetch_data_o = prefetched_line_r;
          prefetched_valid_n = 1'b0; // consumed
        end
        // After serving once, let's reset and go back to IDLE
        // In a more complex design, we might attempt another prefetch here.
        state_n = IDLE;
      end

      default: state_n = IDLE;
    endcase
  end

  // State registers and data updates
  always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
      state_r <= IDLE;
      have_first_miss_r <= 1'b0;
      last_miss_addr_r <= '0;
      stride_r <= '0;
      valid_stride_r <= 1'b0;
      prefetched_valid_r <= 1'b0;
      prefetched_line_r <= '0;
      prefetched_addr_r <= '0;
    end else begin
      state_r <= state_n;
      have_first_miss_r <= have_first_miss_n;
      last_miss_addr_r <= last_miss_addr_n;
      stride_r <= stride_n;
      valid_stride_r <= valid_stride_n;
      prefetched_line_r <= prefetched_line_n;
      prefetched_valid_r <= prefetched_valid_n;
      prefetched_addr_r <= prefetched_addr_n;
    end
  end

endmodule
