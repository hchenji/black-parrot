/*
 * bp_fe_pc_gen.v
 *
 * Description:
 *   The PC generation module provides the next PC for the I$ to fetch. It also
 *   send as well as managing the branch prediction metadata. This module needs
 *   to be kept in sync with I$ cycles for performance reasons.
*/

module bp_fe_pc_gen
 import bp_common_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_fe_pkg::*;
 import bp_common_aviary_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_fe_be_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p)
   )
  (input                                             clk_i
   , input                                           reset_i

   // Cycle -1: Fetch goes out to I$ and I-TLB
   //   A negative branch resolution from the backend
   //   Information is used to update the predictors and next PC.
   //   valid-only to avoid putting pressure on the backend
   , input                                           redirect_v_i
   , input [vaddr_width_p-1:0]                       redirect_pc_i
   , input                                           redirect_br_v_i
   , input [branch_metadata_fwd_width_p-1:0]         redirect_br_metadata_i
   , input                                           redirect_br_taken_i
   , input                                           redirect_br_ntaken_i
   //   The next PC to fetch
   , output logic [vaddr_width_p-1:0]                next_pc_o

   // Cycle 0: Exceptions are raised by the TLB
   //   The fetch unit may poison TL in the cache if the prediction is
   //   determined to be wrong
   , input                                           tl_we_i
   , input [vaddr_width_p-1:0]                       tl_pc_i

   // Cycle 1:
   //   The fetch packet coming from the I$, containing both the fetch PC
   //   and the next fetch PC
   , input [instr_width_p-1:0]                       fetch_instr_i
   , output logic [branch_metadata_fwd_width_p-1:0]  fetch_br_metadata_o
   , output logic                                    fetch_v_o
   , input                                           fetch_yumi_i
   , input                                           tv_we_i
   , input [vaddr_width_p-1:0]                       tv_pc_i

   // Pipeline asynchronous 
   //   An affirmative branch resolution from the backend
   //   Information is used to update the predictors
   //   valid-yumi, because we may not be able to consume predictor data right away
   , input [branch_metadata_fwd_width_p-1:0]         attaboy_br_metadata_i
   , input                                           attaboy_taken_i
   , input                                           attaboy_ntaken_i
   , input                                           attaboy_v_i
   , output                                          attaboy_yumi_o
   );

  `declare_bp_fe_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `declare_bp_fe_pc_gen_stage_s(vaddr_width_p, ghist_width_p);
  `declare_bp_fe_branch_metadata_fwd_s(btb_tag_width_p, btb_idx_width_p, bht_idx_width_p, ghist_width_p);

  `bp_cast_o(bp_fe_branch_metadata_fwd_s, fetch_br_metadata);
  `bp_cast_i(bp_fe_branch_metadata_fwd_s, redirect_br_metadata);
  `bp_cast_i(bp_fe_branch_metadata_fwd_s, attaboy_br_metadata);

  // The main stage registers
  bp_fe_pc_gen_stage_s [1:0] pc_gen_stage_n, pc_gen_stage_r;

  // Branch prediction structures
  logic [1:0]               bht_val_lo;
  logic [vaddr_width_p-1:0] btb_br_tgt_lo;
  logic                     btb_br_tgt_v_lo;
  logic                     btb_br_tgt_jmp_lo;
  logic [vaddr_width_p-1:0] return_addr_n, return_addr_r;
  logic [vaddr_width_p-1:0] br_target;
  logic                     ovr_ret, ovr_taken;
  logic                     btb_taken;
  
  // Branch site information
  logic is_br, is_jal, is_jalr, is_call, is_ret;
  logic is_br_site, is_jal_site, is_jalr_site, is_call_site, is_ret_site;
  logic [btb_tag_width_p-1:0] btb_tag_site;
  logic [btb_idx_width_p-1:0] btb_idx_site;
  logic [bht_idx_width_p-1:0] bht_idx_site;

  // Global history
  logic [ghist_width_p-1:0] ghistory_n, ghistory_r;
  wire ghistory_w_v_li = (fetch_yumi_i & is_br_site) | (redirect_br_v_i & redirect_br_metadata_cast_i.is_br);
  assign ghistory_n = (redirect_br_v_i & redirect_br_metadata_cast_i.is_br)
                      ? redirect_br_metadata_cast_i.ghist
                      : {ghistory_r[0+:ghist_width_p-1], pc_gen_stage_r[1].taken};
  bsg_dff_reset_en
   #(.width_p(ghist_width_p))
   ghist_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(ghistory_w_v_li)
  
     ,.data_i(ghistory_n)
     ,.data_o(ghistory_r)
     );
 
  // BHT
  // Gselect predictor
  wire bht_r_v_li = tl_we_i;
  wire [bht_idx_width_p+ghist_width_p-1:0] bht_idx_r_li =
    {next_pc_o[2+:bht_idx_width_p], pc_gen_stage_n[0].ghist};
  wire bht_w_v_li =
    (redirect_br_v_i & redirect_br_metadata_cast_i.is_br) | (attaboy_yumi_o & attaboy_br_metadata_cast_i.is_br);
  wire [bht_idx_width_p+ghist_width_p-1:0] bht_idx_w_li = redirect_br_v_i
    ? {redirect_br_metadata_cast_i.bht_idx, redirect_br_metadata_cast_i.ghist}
    : {attaboy_br_metadata_cast_i.bht_idx, attaboy_br_metadata_cast_i.ghist};
  wire [1:0] bht_val_li = redirect_v_i ? redirect_br_metadata_cast_i.bht_val : attaboy_br_metadata_cast_i.bht_val;
  bp_fe_bht
   #(.vaddr_width_p(vaddr_width_p)
     ,.bht_idx_width_p(bht_idx_width_p+ghist_width_p)
     )
   bp_fe_bht
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
  
     ,.r_v_i(bht_r_v_li)
     ,.idx_r_i(bht_idx_r_li)
     ,.val_o(bht_val_lo)
  
     ,.w_v_i(bht_w_v_li)
     ,.idx_w_i(bht_idx_w_li)
     ,.correct_i(attaboy_yumi_o)
     ,.val_i(bht_val_li)
     );

  // BTB
  wire redirect_jmp = redirect_br_v_i & (redirect_br_metadata_cast_i.is_jal | redirect_br_metadata_cast_i.is_jalr);
  wire redirect_br = redirect_br_v_i & redirect_br_metadata_cast_i.is_br;
  wire redirect_br_nonbr = ~(redirect_jmp | redirect_br);
  wire btb_r_v_li = tl_we_i & ~ovr_taken & ~ovr_ret;
  wire btb_w_v_li = (redirect_br_v_i & redirect_br_nonbr & redirect_br_metadata_cast_i.src_btb)
                    | (redirect_br_v_i & redirect_br_taken_i)
                    | (attaboy_yumi_o & attaboy_taken_i & ~attaboy_br_metadata_cast_i.src_btb);
  bp_fe_btb
   #(.vaddr_width_p(vaddr_width_p)
     ,.btb_tag_width_p(btb_tag_width_p)
     ,.btb_idx_width_p(btb_idx_width_p)
     )
   btb
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
  
     ,.r_addr_i(next_pc_o)
     ,.r_v_i(btb_r_v_li)
     ,.br_tgt_o(btb_br_tgt_lo)
     ,.br_tgt_v_o(btb_br_tgt_v_lo)
     ,.br_tgt_jmp_o(btb_br_tgt_jmp_lo)
  
     ,.w_v_i(btb_w_v_li)
     ,.w_clr_i(redirect_br_nonbr)
     ,.w_jmp_i(redirect_jmp)
     ,.w_tag_i(redirect_br_metadata_cast_i.btb_tag)
     ,.w_idx_i(redirect_br_metadata_cast_i.btb_idx)
     ,.br_tgt_i(redirect_pc_i)
     );
  assign btb_taken = btb_br_tgt_v_lo & (bht_val_lo[1] | btb_br_tgt_jmp_lo);

  // Return address stack
  assign return_addr_n = tv_pc_i + vaddr_width_p'(4);
  bsg_dff_reset_en
   #(.width_p(vaddr_width_p))
   ras
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(is_call)
  
     ,.data_i(return_addr_n)
     ,.data_o(return_addr_r)
     );

  // Instruction scan
  // Detects different branch characteristics and immediate information
  `declare_bp_fe_instr_scan_s(vaddr_width_p)
  bp_fe_instr_scan_s scan_instr;
  bp_fe_instr_scan
   #(.bp_params_p(bp_params_p))
   instr_scan
    (.instr_i(fetch_instr_i)
  
     ,.scan_o(scan_instr)
     );

  assign is_br        = fetch_yumi_i & scan_instr.branch;
  assign is_jal       = fetch_yumi_i & scan_instr.jal;
  assign is_jalr      = fetch_yumi_i & scan_instr.jalr;
  assign is_call      = fetch_yumi_i & scan_instr.call;
  assign is_ret       = fetch_yumi_i & scan_instr.ret;
  wire btb_miss_ras   = ~pc_gen_stage_r[0].btb | (tl_pc_i != return_addr_r);
  wire btb_miss_br    = ~pc_gen_stage_r[0].btb | (tl_pc_i != br_target);
  assign ovr_ret      = fetch_yumi_i & btb_miss_ras & is_ret;
  assign ovr_taken    = fetch_yumi_i & btb_miss_br & ((is_br & pc_gen_stage_r[0].bht[1]) | is_jal);
  assign br_target    = tv_pc_i + scan_instr.imm;

  assign fetch_br_metadata_cast_o =
    '{src_btb   : pc_gen_stage_r[1].btb
      ,src_ret  : pc_gen_stage_r[1].ret
      ,src_ovr  : pc_gen_stage_r[1].ovr
      ,ghist    : pc_gen_stage_r[1].ghist
      ,bht_val  : pc_gen_stage_r[1].bht 
      ,is_br    : is_br_site
      ,is_jal   : is_jal_site
      ,is_jalr  : is_jalr_site
      ,is_call  : is_call_site
      ,is_ret   : is_ret_site
      ,btb_tag  : btb_tag_site
      ,btb_idx  : btb_idx_site
      ,bht_idx  : bht_idx_site
      };

  // For now accept all attaboys immediately.  In the future we may not be able to
  //   accept all attaboys immediately, since RAMs may be 1rw. 
  assign attaboy_yumi_o = attaboy_v_i;

  // Update the PC and branch stage information 
  always_comb
    if (redirect_v_i)
      begin
        // TODO: This maybe should all be blanked?
        pc_gen_stage_n[0] = '0;
        pc_gen_stage_n[0].v     = 1'b1;
        pc_gen_stage_n[0].taken = redirect_br_taken_i;
        pc_gen_stage_n[0].btb   = redirect_br_metadata_cast_i.src_btb;
        pc_gen_stage_n[0].bht   = redirect_br_metadata_cast_i.bht_val;
        pc_gen_stage_n[0].ret   = redirect_br_metadata_cast_i.src_ret;
        pc_gen_stage_n[0].ovr   = '0; // Does not come from metadata
        pc_gen_stage_n[0].ghist = ghistory_n;
        next_pc_o               = redirect_pc_i;

        pc_gen_stage_n[1] = pc_gen_stage_r[0];
        pc_gen_stage_n[1].v = '0;
      end
    else
      begin
        pc_gen_stage_n[0] = '0;
        pc_gen_stage_n[0].v     = 1'b1;
        pc_gen_stage_n[0].taken = ovr_taken | btb_taken | ovr_ret;
        pc_gen_stage_n[0].btb   = btb_br_tgt_v_lo;
        pc_gen_stage_n[0].bht   = bht_val_lo;
        pc_gen_stage_n[0].ret   = ovr_ret;
        pc_gen_stage_n[0].ovr   = ovr_taken;
        pc_gen_stage_n[0].ghist = ghistory_n;
  
        // Next PC calculation
        if (ovr_ret)
            next_pc_o = return_addr_r;
        else if (ovr_taken)
            next_pc_o = br_target;
        else if (btb_taken)
            next_pc_o = btb_br_tgt_lo;
        else
          begin
            next_pc_o = tl_pc_i + vaddr_width_p'(4);
          end

        pc_gen_stage_n[1] = pc_gen_stage_r[0];
        pc_gen_stage_n[1].v &= ~ovr_taken & ~ovr_ret;
      end

  assign fetch_v_o = pc_gen_stage_r[1].v;

  always_ff @(posedge clk_i)
    begin
      if (tl_we_i | redirect_v_i)
        pc_gen_stage_r[0] <= pc_gen_stage_n[0];
      if (tv_we_i | redirect_v_i)
        pc_gen_stage_r[1] <= pc_gen_stage_n[1];
    end

  // Save branch site information
  always_ff @(posedge clk_i)
    begin
      if (redirect_v_i)
        begin
          is_br_site   <= redirect_br_metadata_cast_i.is_br;
          is_jal_site  <= redirect_br_metadata_cast_i.is_br;
          is_jalr_site <= redirect_br_metadata_cast_i.is_jalr;
          is_call_site <= redirect_br_metadata_cast_i.is_call;
          is_ret_site  <= redirect_br_metadata_cast_i.is_ret;
          btb_tag_site <= redirect_br_metadata_cast_i.btb_tag;
          btb_idx_site <= redirect_br_metadata_cast_i.btb_idx;
          bht_idx_site <= redirect_br_metadata_cast_i.bht_idx;
        end
      else if (fetch_yumi_i)
        begin
          is_br_site   <= is_br;
          is_jal_site  <= is_jal;
          is_jalr_site <= is_jalr;
          is_call_site <= is_call;
          is_ret_site  <= is_ret;
          btb_tag_site <= tv_pc_i[2+btb_idx_width_p+:btb_tag_width_p];
          btb_idx_site <= tv_pc_i[2+:btb_idx_width_p];
          bht_idx_site <= tv_pc_i[2+:bht_idx_width_p];
        end
    end

endmodule

