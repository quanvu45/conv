-- ============================================================
-- File    : top.vhd
-- Module  : top
-- Chức năng: Wrapper ghép packet_manager + conv
--            Đây là Custom IP được add vào Qsys
--
-- Kết nối trong Qsys:
--   Slave  avs_*        ← LWH2F bridge (HPS điều khiển)
--   Master ram_in_*     → ram_in  (S2 8-bit)
--   Master ram_out_*    → ram_out (S2 8-bit)
-- ============================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity top is
    generic (
        IMG_WIDTH  : integer := 640;   -- Số pixel mỗi hàng ảnh
        DATA_WIDTH : integer := 8      -- Độ rộng pixel (phải = 8)
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- ---------------------------------------------------
        -- Avalon-MM Slave (HPS → top qua LWH2F)
        -- 2 word address: 0=CTRL, 1=STATUS
        -- ---------------------------------------------------
        avs_address   : in  std_logic_vector(0 downto 0);
        avs_read      : in  std_logic;
        avs_readdata  : out std_logic_vector(31 downto 0);
        avs_write     : in  std_logic;
        avs_writedata : in  std_logic_vector(31 downto 0);

        -- ---------------------------------------------------
        -- Avalon-MM Master: Đọc RAM Input (S2, 8-bit)
        -- ---------------------------------------------------
        ram_in_address    : out std_logic_vector(31 downto 0);
        ram_in_read       : out std_logic;
        ram_in_readdata   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        ram_in_waitrequest: in  std_logic;

        -- ---------------------------------------------------
        -- Avalon-MM Master: Ghi RAM Output (S2, 8-bit)
        -- ---------------------------------------------------
        ram_out_address    : out std_logic_vector(31 downto 0);
        ram_out_write      : out std_logic;
        ram_out_writedata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        ram_out_waitrequest: in  std_logic
    );
end top;

architecture Behavioral of top is

    -- ----------------------------------------------------------
    -- Component: packet_manager
    -- ----------------------------------------------------------
    component packet_manager is
        generic (
            DATA_WIDTH : integer := 8
        );
        port (
            clk   : in std_logic;
            rst_n : in std_logic;

            avs_address   : in  std_logic_vector(0 downto 0);
            avs_read      : in  std_logic;
            avs_readdata  : out std_logic_vector(31 downto 0);
            avs_write     : in  std_logic;
            avs_writedata : in  std_logic_vector(31 downto 0);

            ram_in_address    : out std_logic_vector(31 downto 0);
            ram_in_read       : out std_logic;
            ram_in_readdata   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
            ram_in_waitrequest: in  std_logic;

            ram_out_address    : out std_logic_vector(31 downto 0);
            ram_out_write      : out std_logic;
            ram_out_writedata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
            ram_out_waitrequest: in  std_logic;

            conv_data_in  : out std_logic_vector(DATA_WIDTH-1 downto 0);
            conv_valid_in : out std_logic;
            conv_data_out : in  std_logic_vector(DATA_WIDTH-1 downto 0);
            conv_valid_out: in  std_logic
        );
    end component;

    -- ----------------------------------------------------------
    -- Component: conv
    -- ----------------------------------------------------------
    component conv is
        generic (
            IMG_WIDTH  : integer := 640;
            DATA_WIDTH : integer := 8
        );
        port (
            clk       : in  std_logic;
            rst_n     : in  std_logic;
            data_in   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
            valid_in  : in  std_logic;
            data_out  : out std_logic_vector(DATA_WIDTH-1 downto 0);
            valid_out : out std_logic
        );
    end component;

    -- ----------------------------------------------------------
    -- Tín hiệu nội bộ nối packet_manager ↔ conv
    -- ----------------------------------------------------------
    signal conv_data_in_s  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal conv_valid_in_s : std_logic;
    signal conv_data_out_s : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal conv_valid_out_s: std_logic;

begin

    -- ----------------------------------------------------------
    -- Instantiate packet_manager
    -- ----------------------------------------------------------
    u_pkt : packet_manager
        generic map (
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk   => clk,
            rst_n => rst_n,

            avs_address   => avs_address,
            avs_read      => avs_read,
            avs_readdata  => avs_readdata,
            avs_write     => avs_write,
            avs_writedata => avs_writedata,

            ram_in_address     => ram_in_address,
            ram_in_read        => ram_in_read,
            ram_in_readdata    => ram_in_readdata,
            ram_in_waitrequest => ram_in_waitrequest,

            ram_out_address     => ram_out_address,
            ram_out_write       => ram_out_write,
            ram_out_writedata   => ram_out_writedata,
            ram_out_waitrequest => ram_out_waitrequest,

            conv_data_in   => conv_data_in_s,
            conv_valid_in  => conv_valid_in_s,
            conv_data_out  => conv_data_out_s,
            conv_valid_out => conv_valid_out_s
        );

    -- ----------------------------------------------------------
    -- Instantiate conv
    -- IMG_WIDTH truyền từ generic của top để dễ thay đổi
    -- ----------------------------------------------------------
    u_conv : conv
        generic map (
            IMG_WIDTH  => IMG_WIDTH,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk       => clk,
            rst_n     => rst_n,
            data_in   => conv_data_in_s,
            valid_in  => conv_valid_in_s,
            data_out  => conv_data_out_s,
            valid_out => conv_valid_out_s
        );

end Behavioral;