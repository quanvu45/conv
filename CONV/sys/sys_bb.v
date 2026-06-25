
module sys (
	clk_clk,
	reset_reset_n,
	memory_mem_a,
	memory_mem_ba,
	memory_mem_ck,
	memory_mem_ck_n,
	memory_mem_cke,
	memory_mem_cs_n,
	memory_mem_ras_n,
	memory_mem_cas_n,
	memory_mem_we_n,
	memory_mem_reset_n,
	memory_mem_dq,
	memory_mem_dqs,
	memory_mem_dqs_n,
	memory_mem_odt,
	memory_mem_dm,
	memory_oct_rzqin,
	hps_io_hps_io_emac0_inst_TX_CLK,
	hps_io_hps_io_emac0_inst_TXD0,
	hps_io_hps_io_emac0_inst_TXD1,
	hps_io_hps_io_emac0_inst_TXD2,
	hps_io_hps_io_emac0_inst_TXD3,
	hps_io_hps_io_emac0_inst_RXD0,
	hps_io_hps_io_emac0_inst_MDIO,
	hps_io_hps_io_emac0_inst_MDC,
	hps_io_hps_io_emac0_inst_RX_CTL,
	hps_io_hps_io_emac0_inst_TX_CTL,
	hps_io_hps_io_emac0_inst_RX_CLK,
	hps_io_hps_io_emac0_inst_RXD1,
	hps_io_hps_io_emac0_inst_RXD2,
	hps_io_hps_io_emac0_inst_RXD3,
	hps_0_h2f_mpu_events_eventi,
	hps_0_h2f_mpu_events_evento,
	hps_0_h2f_mpu_events_standbywfe,
	hps_0_h2f_mpu_events_standbywfi);	

	input		clk_clk;
	input		reset_reset_n;
	output	[12:0]	memory_mem_a;
	output	[2:0]	memory_mem_ba;
	output		memory_mem_ck;
	output		memory_mem_ck_n;
	output		memory_mem_cke;
	output		memory_mem_cs_n;
	output		memory_mem_ras_n;
	output		memory_mem_cas_n;
	output		memory_mem_we_n;
	output		memory_mem_reset_n;
	inout	[7:0]	memory_mem_dq;
	inout		memory_mem_dqs;
	inout		memory_mem_dqs_n;
	output		memory_mem_odt;
	output		memory_mem_dm;
	input		memory_oct_rzqin;
	output		hps_io_hps_io_emac0_inst_TX_CLK;
	output		hps_io_hps_io_emac0_inst_TXD0;
	output		hps_io_hps_io_emac0_inst_TXD1;
	output		hps_io_hps_io_emac0_inst_TXD2;
	output		hps_io_hps_io_emac0_inst_TXD3;
	input		hps_io_hps_io_emac0_inst_RXD0;
	inout		hps_io_hps_io_emac0_inst_MDIO;
	output		hps_io_hps_io_emac0_inst_MDC;
	input		hps_io_hps_io_emac0_inst_RX_CTL;
	output		hps_io_hps_io_emac0_inst_TX_CTL;
	input		hps_io_hps_io_emac0_inst_RX_CLK;
	input		hps_io_hps_io_emac0_inst_RXD1;
	input		hps_io_hps_io_emac0_inst_RXD2;
	input		hps_io_hps_io_emac0_inst_RXD3;
	input		hps_0_h2f_mpu_events_eventi;
	output		hps_0_h2f_mpu_events_evento;
	output	[1:0]	hps_0_h2f_mpu_events_standbywfe;
	output	[1:0]	hps_0_h2f_mpu_events_standbywfi;
endmodule
