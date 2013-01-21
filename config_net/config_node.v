module config_node
  #(parameter             // node specific parameters 
    id_p = -1,            // unique ID of this node
    data_bits_p = -1,     // number of bits of configurable register associated with this node
    default_p = -1        // default/reset value of configurable register associated with this node
   )
   (input clk_i,
    input bit_i,
    
    output [data_bits_p - 1 : 0] data_o,
    output bit_o
   );

  // local parameters same for all nodes in the configuration chain
  localparam frame_bit_size_lp  = 1;
  localparam data_frame_len_lp  = 8;  // bit '0' is inserted every data_frame_len_lp in data bits
  localparam id_width_lp        = 8;  // number of bits to represent the ID of a node, should be able to keep the max ID in the whole chain
  localparam len_width_lp       = 8;  // number of bits to represent number of bits in the configuration packet

  localparam data_rx_len_lp     = (data_bits_p + (data_bits_p / data_frame_len_lp) + frame_bit_size_lp);
                                      // + frame_bit_size_lp means the end, or msb of received data is always framing bits
                                      // if data_bits_p is a multiple of data_frame_len_lp, "00" is expected at the end of received data

  localparam shift_width_lp     = (data_rx_len_lp + frame_bit_size_lp + id_width_lp + frame_bit_size_lp + len_width_lp + frame_bit_size_lp);
                                      // shift register width of this node

  /* The communication packet is defined as follows:
   * msb                                                                                 lsb
   * |  data_rx  |  frame bits  |  node id  |  frame bits  |  packet length  |  valid bit  |
   *             |<------------------------------ reset ---------------------------------->|
   *
   * valid bit is defined as '0'.
   * packet length equals the number of bits in one complete packet, i.e. msb - lsb + 1.
   * frame bits are certain patterns to separate packet content, defined as '0'.
   * node id is an unique integer to identify current node.
   * data_rx contains the data payload and framing bits inserted every data_frame_len_lp bits.
   *
   * Before use, reset the configuration node is mandatory by sending continuous '1's, and the
   * minimum length of the reset sequence is (frame_bit_size_lp * 3 + id_width_lp + len_width_lp),
   * or the indicated field above.
   *
   * Each node contains a shift register that represents the same structure of a complete packet,
   * and the node begins interpret received packet once it sees a '0' in the lsb of the shift
   * register. The node determines if it is the target according to the node id bits. If so, the 
   * node captures received data, remove framing bits and write the data to its internal register.
   * Otherwise, the node simply passes every bit to its subsequent node.
   */

  typedef struct packed {
    logic [data_rx_len_lp - 1 : 0]       rx;
    logic                                f1;
    logic [id_width_lp - 1 : 0]          id;
    logic [frame_bit_size_lp - 1 : 0]    f0;
    logic [len_width_lp - 1 : 0]        len;
    logic                             valid;
  } node_packet_s;

  node_packet_s shift_n, shift_r;
  logic [id_width_lp - 1 : 0]    node_id;
  logic                          reset;
  logic                          valid;
  logic                          match;
  logic                          data_en;

  logic [len_width_lp - 1 : 0] packet_len;
  logic [len_width_lp - 1 : 0] count_n, count_r;
  logic                        count_non_zero;

  logic [data_rx_len_lp - 1 : 0] data_rx;
  logic [data_bits_p - 1 : 0] data_n, data_r;

  assign count_n = (valid) ? (packet_len - 1) : ((count_non_zero) ? (count_r - 1) : count_r);
  assign shift_n = {bit_i, shift_r[1 +: shift_width_lp - 1]};

  always_ff @ (posedge clk_i) begin
    if (reset) begin
      count_r <= 0;
      data_r <= default_p;
    end else begin
      count_r <= count_n;
      if (data_en)
        data_r <= data_n;
    end

    shift_r <= shift_n;
  end

  assign reset = & shift_r[0 +: frame_bit_size_lp * 3 + id_width_lp + len_width_lp];
  assign valid = (~count_non_zero) ? (~shift_r.valid) : 1'b0;
  assign packet_len = shift_r.len;
  assign node_id    = shift_r.id;
  assign data_rx    = shift_r.rx;

  genvar i;
  generate
    for(i = 0; i < data_rx_len_lp - frame_bit_size_lp; i++) begin // the end, or msb of a transferred data is always '0' which is discarded
      if((i + 1) % (data_frame_len_lp + frame_bit_size_lp)) begin
        assign data_n[i - i / (data_frame_len_lp + frame_bit_size_lp)] = data_rx[i];
      end
    end
  endgenerate

  assign match = node_id == id_p;
  assign data_en = valid & match;
  assign count_non_zero = | count_r;

  assign data_o = data_r;
  assign bit_o = shift_r[0];

endmodule
