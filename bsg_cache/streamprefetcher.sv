`include "bsg_defines.sv"

module streamprefetcher #(
  parameter addr_width_p = 32,
  parameter data_width_p = 32
) (
  input  logic                     clk_i,
  input  logic                     reset_i,

  // Miss information from bsg_cache
  input  logic [addr_width_p-1:0]  miss_addr_i,
  input  logic                     miss_v_i,

  // DMA busy indicator from bsg_cache_miss
  input  logic                     dma_busy_i,

  // DMA returned data after prefetch request
  input  logic [data_width_p-1:0]  dma_prefetch_data_i,
  input  logic                     dma_prefetch_data_v_i,

  // Cache request interface
  input  logic                     cache_pkt_v_i,
  input  logic [addr_width_p-1:0]  cache_pkt_addr_i,

  // Prefetch request to miss handler
  output logic                     prefetch_dma_req_o,
  output logic [addr_width_p-1:0]  prefetch_dma_addr_o,

  // Prefetched data to cache if requested
  output logic [data_width_p-1:0]  prefetch_data_o,
  output logic                     prefetch_data_v_o
);

  // FSM states
  typedef enum logic [2:0] {
    IDLE,
    CHECK_STREAM,
    UPDATE_STREAM,
    CREATE_STREAM,
    PREFETCH
  } state_e;

  state_e state_r, state_n;

  // Registers to store intermediate info
  logic [addr_width_p-1:0] last_miss_addr_r;
  logic have_miss_info_r;
  logic [addr_width_p-1:0] stride_r;
  logic [addr_width_p-1:0] stream_start_addr_r;
  logic [addr_width_p-1:0] prefetched_addr_r;
  logic prefetched_valid_r;
  logic [data_width_p-1:0] prefetched_data_r;

  // By default
  always_comb begin
    prefetch_dma_req_o = 1'b0;
    prefetch_dma_addr_o = '0;
    prefetch_data_v_o = 1'b0;
    prefetch_data_o = '0;

    case (state_r)
      IDLE: begin
        // Just waiting, no outputs here
      end

      CHECK_STREAM: begin
        // We got a miss. From here we check if we can form a pattern.
        // No direct output unless we know stride already. Typically none.
      end

      UPDATE_STREAM: begin
        // We have two misses now, so we can compute stride.
        // No immediate outputs, just internal updates.
      end

      CREATE_STREAM: begin
        // After computing stride, if we have a valid stride, we create a stream entry.
        // No immediate prefetch request yet, but we finalize the stream info.
      end

      PREFETCH: begin
        // Issue a prefetch request if we have a valid stride and DMA is free
        if (!dma_busy_i && stride_r != '0' && prefetched_valid_r == 1'b0) begin
          prefetch_dma_req_o = 1'b1;
          prefetch_dma_addr_o = stream_start_addr_r + stride_r;
        end
        // If dma_prefetch_data_v_i is received, we have prefetched data available.
        // If the cache requests this address, we return it immediately.
        if (prefetched_valid_r && cache_pkt_v_i && (cache_pkt_addr_i == prefetched_addr_r)) begin
          prefetch_data_v_o = 1'b1;
          prefetch_data_o = prefetched_data_r;
        end
      end

      default: ;
    endcase
  end

  // Next state logic
  always_comb begin
    state_n = state_r;
    case (state_r)
      IDLE: begin
        // Wait for a miss to start analyzing a stream
        if (miss_v_i) begin
          state_n = CHECK_STREAM;
        end
      end

      CHECK_STREAM: begin
        // We got a miss; if we had a previous miss (have_miss_info_r), we can now compute stride
        if (have_miss_info_r && miss_v_i) begin
          state_n = UPDATE_STREAM;
        end else if (!have_miss_info_r && miss_v_i) begin
          // First miss recorded, need another miss to find stride
          state_n = IDLE; // We store the info and go back to IDLE or stay in a stable state
        end
      end

      UPDATE_STREAM: begin
        // Now we have two misses, compute stride and decide if we can create a stream
        // If stride != 0, we can create a stream, else go back to IDLE
        if (stride_r != '0) begin
          state_n = CREATE_STREAM;
        end else begin
          // No pattern found, go back to IDLE and wait for another opportunity
          state_n = IDLE;
        end
      end

      CREATE_STREAM: begin
        // Stream created with known stride and start address
        // Move to PREFETCH state to attempt a prefetch
        state_n = PREFETCH;
      end

      PREFETCH: begin
        // In this state, we continuously attempt to prefetch if not busy and stride > 0
        // Once data arrives (dma_prefetch_data_v_i), we store it.
        // If CPU uses the line, after that we can either attempt next prefetch or go IDLE
        // For simplicity, after prefetch data is consumed, go back to IDLE to detect new patterns
        if (dma_prefetch_data_v_i) begin
          // got data, store it
          // After CPU consumes it (cache_pkt_v_i == prefetched_addr_r), go to IDLE
          // If already consumed this cycle or next cycle, go IDLE
          // To simplify: after one consumption, go IDLE
          // If prefetched data consumed:
          if (prefetched_valid_r && cache_pkt_v_i && (cache_pkt_addr_i == prefetched_addr_r)) begin
            state_n = IDLE;
          end else begin
            // Otherwise stay in PREFETCH to potentially prefetch next line in future misses
            state_n = PREFETCH;
          end
        end else begin
          // No new data or not consumed yet, remain in PREFETCH
          state_n = PREFETCH;
        end
      end

      default: state_n = IDLE;
    endcase
  end

  // State, register updates
  always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
      state_r <= IDLE;
      have_miss_info_r <= 1'b0;
      last_miss_addr_r <= '0;
      stride_r <= '0;
      prefetched_valid_r <= 1'b0;
      prefetched_addr_r <= '0;
      prefetched_data_r <= '0;
      stream_start_addr_r <= '0;
    end else begin
      state_r <= state_n;

      case (state_r)
        IDLE: begin
          if (miss_v_i) begin
            // Record first miss info
            last_miss_addr_r <= miss_addr_i;
            have_miss_info_r <= 1'b1;
          end
          // Clear any old prefetched line
          prefetched_valid_r <= 1'b0;
        end

        CHECK_STREAM: begin
          if (miss_v_i && have_miss_info_r) begin
            // We have second miss, next cycle in UPDATE_STREAM we compute stride
          end else if (miss_v_i && !have_miss_info_r) begin
            // First miss recorded, next state back to IDLE
            last_miss_addr_r <= miss_addr_i;
            have_miss_info_r <= 1'b1;
          end
        end

        UPDATE_STREAM: begin
          // Compute stride = difference between current and last miss
          stride_r <= miss_addr_i - last_miss_addr_r;
          // Update last_miss_addr for future references
          last_miss_addr_r <= miss_addr_i;
        end

        CREATE_STREAM: begin
          // We have a stride now, set start addr
          stream_start_addr_r <= last_miss_addr_r;
          // no prefetched line yet
          prefetched_valid_r <= 1'b0;
        end

        PREFETCH: begin
          // If DMA returns data this cycle
          if (dma_prefetch_data_v_i) begin
            prefetched_data_r <= dma_prefetch_data_i;
            prefetched_addr_r <= stream_start_addr_r + stride_r;
            prefetched_valid_r <= 1'b1;
          end
          // If CPU consumes it this cycle
          if (prefetched_valid_r && cache_pkt_v_i && (cache_pkt_addr_i == prefetched_addr_r)) begin
            // Once consumed, we decided to go IDLE or keep streaming
            // For simplicity, next cycle we move to IDLE in state machine
            prefetched_valid_r <= 1'b0;
          end
        end
      endcase
    end
  end

endmodule
