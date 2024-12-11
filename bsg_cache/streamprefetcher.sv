`include "bsg_defines.sv"

module streamprefetcher #(
  parameter addr_width_p = 32,
  parameter data_width_p = 32
) (
  input logic clk_i,
  input logic reset_i,

  // Miss interface from bsg_cache
  input logic [addr_width_p-1:0] miss_addr_i,
  input logic miss_v_i,

  // Indicates if DMA is currently busy (from bsg_cache_miss)
  input logic dma_busy_i,

  // Prefetch data returned from DMA after a prefetch request
  input logic [data_width_p-1:0] dma_prefetch_data_i,
  input logic dma_prefetch_data_v_i,

  // Cache request interface to check if prefetched data is useful
  input logic cache_pkt_v_i,
  input logic [addr_width_p-1:0] cache_pkt_addr_i,

  // Prefetch request output to miss handler
  output logic prefetch_dma_req_o,
  output logic [addr_width_p-1:0] prefetch_dma_addr_o,

  // Prefetched data to cache if it matches request
  output logic [data_width_p-1:0] prefetch_data_o,
  output logic prefetch_data_v_o
);

  // FSM states
  typedef enum logic [2:0] {
    IDLE,
    ONE_MISS,
    DETECT_STRIDE,
    ISSUE_PREFETCH,
    WAIT_DMA,
    HAVE_LINE
  } fsm_state_e;

  fsm_state_e state_r, state_n;

  // Registers
  logic have_last_miss_r;
  logic [addr_width_p-1:0] last_miss_addr_r;
  logic [addr_width_p-1:0] stride_r;
  logic [addr_width_p-1:0] prefetched_addr_r;
  logic [data_width_p-1:0] prefetched_data_r;
  logic prefetched_valid_r;

  // Outputs default
  always_comb begin
    prefetch_dma_req_o = 1'b0;
    prefetch_dma_addr_o = '0;
    prefetch_data_v_o = 1'b0;
    prefetch_data_o = '0;

    case (state_r)
      ISSUE_PREFETCH: begin
        // Request a prefetch if not busy
        if (!dma_busy_i && stride_r != '0) begin
          prefetch_dma_req_o = 1'b1;
          prefetch_dma_addr_o = last_miss_addr_r + stride_r;
        end
      end

      HAVE_LINE: begin
        // If the CPU requests the prefetched line
        if (cache_pkt_v_i && prefetched_valid_r && (cache_pkt_addr_i == prefetched_addr_r)) begin
          prefetch_data_v_o = 1'b1;
          prefetch_data_o = prefetched_data_r;
        end
      end

      default: ;
    endcase
  end

  // Next state logic
  always_comb begin
    state_n = state_r; // default no change

    case (state_r)
      IDLE: begin
        // No stride known yet. Wait for first miss.
        if (miss_v_i) begin
          // Record first miss
          state_n = ONE_MISS;
        end
      end

      ONE_MISS: begin
        // We have one miss recorded.
        // Wait for another miss to determine stride
        if (miss_v_i) begin
          state_n = DETECT_STRIDE;
        end
      end

      DETECT_STRIDE: begin
        // Just got second miss, can compute stride and attempt a prefetch
        // If stride != 0 and not busy, go to ISSUE_PREFETCH
        // Otherwise, go back to ONE_MISS or IDLE
        if (stride_r != '0) begin
          // If DMA busy, we can wait or just attempt prefetch next cycle
          // We'll attempt prefetch now:
          state_n = ISSUE_PREFETCH;
        end else begin
          // Zero stride means no linear pattern, just record last miss as first miss again
          state_n = ONE_MISS;
        end
      end

      ISSUE_PREFETCH: begin
        // Attempting to issue prefetch
        if (!dma_busy_i && stride_r != '0) begin
          // Prefetch request accepted by miss unit this cycle (assumption).
          // After requesting, go to WAIT_DMA
          state_n = WAIT_DMA;
        end
        else begin
          // DMA busy, stay in ISSUE_PREFETCH until DMA frees up
          state_n = ISSUE_PREFETCH;
        end
      end

      WAIT_DMA: begin
        // Waiting for prefetch data to return
        if (dma_prefetch_data_v_i) begin
          // Data arrived
          state_n = HAVE_LINE;
        end
      end

      HAVE_LINE: begin
        // We have prefetched line stored
        // If CPU uses it, we return it and then revert to a known state.
        // After serving once, let's reset to ONE_MISS state with the last miss_addr_r as baseline
        if (cache_pkt_v_i && prefetched_valid_r && (cache_pkt_addr_i == prefetched_addr_r)) begin
          // Once consumed, let's fall back to ONE_MISS (we still have last_miss_addr from previous events)
          state_n = ONE_MISS;
        end
      end

      default: state_n = IDLE;
    endcase
  end

  // State registers and data updates
  always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
      state_r <= IDLE;
      have_last_miss_r <= 1'b0;
      last_miss_addr_r <= '0;
      stride_r <= '0;
      prefetched_valid_r <= 1'b0;
      prefetched_data_r <= '0;
      prefetched_addr_r <= '0;
    end else begin
      state_r <= state_n;

      // Update logic based on transitions and inputs
      case (state_r)
        IDLE: begin
          if (miss_v_i) begin
            last_miss_addr_r <= miss_addr_i;
            have_last_miss_r <= 1'b1;
          end
        end

        ONE_MISS: begin
          if (miss_v_i) begin
            // Compute stride
            stride_r <= miss_addr_i - last_miss_addr_r;
            // Update last miss
            last_miss_addr_r <= miss_addr_i;
          end
        end

        DETECT_STRIDE: begin
          // Already computed stride in ONE_MISS->DETECT_STRIDE transition
          // Nothing extra here
        end

        ISSUE_PREFETCH: begin
          // If we can issue prefetch this cycle (no dma_busy_i)
          // The output logic tries to issue prefetch continuously until accepted
          // Once accepted next state WAIT_DMA: no immediate data changes here
        end

        WAIT_DMA: begin
          // Wait for data return
          if (dma_prefetch_data_v_i) begin
            prefetched_data_r <= dma_prefetch_data_i;
            // Prefetch addr = last_miss_addr_r + stride_r (recorded in ISSUE_PREFETCH)
            prefetched_addr_r <= last_miss_addr_r + stride_r;
            prefetched_valid_r <= 1'b1;
          end
        end

        HAVE_LINE: begin
          if (cache_pkt_v_i && prefetched_valid_r && (cache_pkt_addr_i == prefetched_addr_r)) begin
            // Consumed the prefetched line
            prefetched_valid_r <= 1'b0;
            // We remain with last_miss_addr_r as baseline for next detection
          end
        end
      endcase

    end
  end

endmodule
