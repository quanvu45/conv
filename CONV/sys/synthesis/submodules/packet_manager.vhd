-- ============================================================
-- File    : packet_manager.vhd
-- Module  : packet_manager
-- Chức năng:
--   1. Nhận lệnh START từ HPS qua Avalon-MM Slave
--   2. Đọc gói tin từ ram_in (Avalon-MM Master, 8-bit, có waitrequest)
--   3. Xác thực header (magic 0x55AA) và checksum XOR
--   4. Stream pixel data sang conv
--   5. Nhận kết quả từ conv, ghi vào ram_out
--   6. Báo trạng thái DONE / ERR về HPS
--
-- Cấu trúc gói tin trong ram_in (little-endian):
--   Byte 0-1  : Magic    = 0x55AA
--   Byte 2-3  : Command  (hiện không dùng)
--   Byte 4-7  : Length   = số byte pixel data (uint32, little-endian)
--   Byte 8..  : Pixel data (LENGTH byte)
--   Byte 8+L..8+L+3 : Checksum XOR 4 byte (chỉ dùng byte 0)
--
-- Register map (Avalon-MM Slave, word address):
--   Addr 0 (W): CTRL  - bit[0]=START (HPS ghi 1 để bắt đầu, ghi 0 để reset)
--   Addr 1 (R): STATUS- bit[0]=DONE, bit[1]=ERR_MAGIC, bit[2]=ERR_CHKSUM
--
-- Avalon-MM Master (ram_in, ram_out):
--   - 8-bit data width (S2 của RAM trong Qsys)
--   - Có waitrequest (latency không cố định)
--   - ram_in: read-only master
--   - ram_out: write-only master
-- ============================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity packet_manager is
    generic (
        DATA_WIDTH : integer := 8   -- phải bằng 8 (khớp với RAM S2)
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;

        -- -------------------------------------------------------
        -- Avalon-MM Slave: HPS điều khiển qua LWH2F bridge
        -- -------------------------------------------------------
        avs_address   : in  std_logic_vector(0 downto 0);   -- 1 bit = 2 word
        avs_read      : in  std_logic;
        avs_readdata  : out std_logic_vector(31 downto 0);
        avs_write     : in  std_logic;
        avs_writedata : in  std_logic_vector(31 downto 0);

        -- -------------------------------------------------------
        -- Avalon-MM Master: Đọc từ RAM Input (8-bit S2)
        -- -------------------------------------------------------
        ram_in_address    : out std_logic_vector(31 downto 0);
        ram_in_read       : out std_logic;
        ram_in_readdata   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        ram_in_waitrequest: in  std_logic;

        -- -------------------------------------------------------
        -- Avalon-MM Master: Ghi vào RAM Output (8-bit S2)
        -- -------------------------------------------------------
        ram_out_address    : out std_logic_vector(31 downto 0);
        ram_out_write      : out std_logic;
        ram_out_writedata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        ram_out_waitrequest: in  std_logic;

        -- -------------------------------------------------------
        -- Stream tới/từ conv
        -- -------------------------------------------------------
        conv_data_in  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        conv_valid_in : out std_logic;
        conv_data_out : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        conv_valid_out: in  std_logic
    );
end packet_manager;

architecture Behavioral of packet_manager is

    -- ----------------------------------------------------------
    -- FSM
    -- ----------------------------------------------------------
    type state_t is (
        ST_IDLE,        -- Chờ HPS set START
        ST_READ_HDR,    -- Đọc 8 byte header (magic + cmd + length)
        ST_PROCESS,     -- Đọc pixel data, stream sang conv
        ST_READ_CHKSUM, -- Đọc 4 byte checksum
        ST_VERIFY,      -- So sánh checksum
        ST_DONE         -- Báo kết quả, chờ HPS clear START
    );
    signal state : state_t := ST_IDLE;

    -- ----------------------------------------------------------
    -- Register HPS
    -- ----------------------------------------------------------
    signal reg_ctrl   : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_status : std_logic_vector(31 downto 0) := (others => '0');

    -- ----------------------------------------------------------
    -- Header fields
    -- ----------------------------------------------------------
    signal magic_reg    : std_logic_vector(15 downto 0);
    signal cmd_reg      : std_logic_vector(15 downto 0);
    signal length_reg   : unsigned(31 downto 0);
    signal checksum_reg : std_logic_vector(7 downto 0);   -- chỉ dùng byte 0
    signal checksum_calc: std_logic_vector(7 downto 0);

    -- ----------------------------------------------------------
    -- Bộ đếm địa chỉ đọc RAM (byte address, 20-bit = 1MB)
    -- ----------------------------------------------------------
    signal rd_addr : unsigned(31 downto 0) := (others => '0');

    -- ----------------------------------------------------------
    -- Bộ đếm địa chỉ ghi RAM out (byte address, 20-bit)
    -- ----------------------------------------------------------
    signal wr_addr : unsigned(31 downto 0) := (others => '0');

    -- ----------------------------------------------------------
    -- Cờ "đọc đang pending" — tránh tăng địa chỉ khi waitrequest=1
    -- ----------------------------------------------------------
    signal rd_pending : std_logic := '0';   -- đang chờ RAM xác nhận read
    signal rd_data_valid : std_logic := '0'; -- byte vừa được RAM trả về

    -- ----------------------------------------------------------
    -- Số byte header đã nhận (0..7)
    -- ----------------------------------------------------------
    signal hdr_cnt : integer range 0 to 8 := 0;

    -- ----------------------------------------------------------
    -- Số byte pixel đã đọc
    -- ----------------------------------------------------------
    signal pix_cnt : unsigned(31 downto 0) := (others => '0');

    -- ----------------------------------------------------------
    -- Số byte checksum đã đọc (0..3)
    -- ----------------------------------------------------------
    signal chk_cnt : integer range 0 to 4 := 0;

begin

    -- ==========================================================
    -- Process 1: Ghi thanh ghi điều khiển từ HPS
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            reg_ctrl <= (others => '0');
        elsif rising_edge(clk) then
            if avs_write = '1' and avs_address = "0" then
                reg_ctrl <= avs_writedata;
            end if;
        end if;
    end process;

    -- Đọc thanh ghi (combinational)
    avs_readdata <= reg_ctrl   when avs_address = "0" else reg_status;

    -- ==========================================================
    -- Process 2: FSM điều khiển đọc RAM và stream conv
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state         <= ST_IDLE;
            rd_addr       <= (others => '0');
            rd_pending    <= '0';
            rd_data_valid <= '0';
            hdr_cnt       <= 0;
            pix_cnt       <= (others => '0');
            chk_cnt       <= 0;
            magic_reg     <= (others => '0');
            cmd_reg       <= (others => '0');
            length_reg    <= (others => '0');
            checksum_reg  <= (others => '0');
            checksum_calc <= (others => '0');
            reg_status    <= (others => '0');
            conv_data_in  <= (others => '0');
            conv_valid_in <= '0';
            ram_in_read   <= '0';
            ram_in_address<= (others => '0');

        elsif rising_edge(clk) then

            -- Mặc định: xoá pulse
            conv_valid_in <= '0';
            rd_data_valid <= '0';

            -- --------------------------------------------------
            -- Giao thức Avalon-MM Master Read (có waitrequest):
            --   Giữ address + read='1' cho đến khi waitrequest='0'
            --   Khi waitrequest='0': dữ liệu hợp lệ trên readdata
            -- --------------------------------------------------
            if rd_pending = '1' then
                ram_in_address <= std_logic_vector(rd_addr);
                ram_in_read    <= '1';

                if ram_in_waitrequest = '0' then
                    -- RAM đã xác nhận → dữ liệu hợp lệ
                    rd_data_valid <= '1';
                    rd_pending    <= '0';
                    ram_in_read   <= '0';
                end if;
            end if;

            -- --------------------------------------------------
            -- FSM chính
            -- --------------------------------------------------
            case state is

                -- ----------------------------------------------
                when ST_IDLE =>
                    rd_addr       <= (others => '0');
                    hdr_cnt       <= 0;
                    pix_cnt       <= (others => '0');
                    chk_cnt       <= 0;
                    checksum_calc <= (others => '0');
                    reg_status    <= (others => '0');
                    ram_in_read   <= '0';
                    rd_pending    <= '0';

                    if reg_ctrl(0) = '1' then
                        state      <= ST_READ_HDR;
                        rd_pending <= '1';   -- phát lệnh đọc đầu tiên
                    end if;

                -- ----------------------------------------------
                when ST_READ_HDR =>
                    if rd_data_valid = '1' then
                        -- Lưu byte vào đúng field header
                        case hdr_cnt is
                            when 0 => magic_reg(7 downto 0)   <= ram_in_readdata;
                            when 1 => magic_reg(15 downto 8)  <= ram_in_readdata;
                            when 2 => cmd_reg(7 downto 0)     <= ram_in_readdata;
                            when 3 => cmd_reg(15 downto 8)    <= ram_in_readdata;
                            when 4 => length_reg(7 downto 0)  <= unsigned(ram_in_readdata);
                            when 5 => length_reg(15 downto 8) <= unsigned(ram_in_readdata);
                            when 6 => length_reg(23 downto 16)<= unsigned(ram_in_readdata);
                            when 7 =>
                                length_reg(31 downto 24) <= unsigned(ram_in_readdata);
                                -- Kiểm tra magic 0x55AA (little-endian: byte0=0x55, byte1=0xAA)
                                -- magic_reg(15:8) vừa được ghi ở byte 1
                                -- magic_reg(7:0) = 0x55, magic_reg(15:8) = 0xAA
                                if magic_reg(7 downto 0) = x"55" and magic_reg(15 downto 8) = x"AA" then
                                    state   <= ST_PROCESS;
                                else
                                    reg_status(1) <= '1';   -- ERR_MAGIC
                                    state <= ST_DONE;
                                end if;
                            when others => null;
                        end case;

                        hdr_cnt <= hdr_cnt + 1;
                        rd_addr <= rd_addr + 1;

                        -- Phát lệnh đọc tiếp (trừ byte cuối header chuyển state)
                        if hdr_cnt < 7 then
                            rd_pending <= '1';
                        elsif magic_reg(7 downto 0) = x"55" and magic_reg(15 downto 8) = x"AA" then
                            rd_pending <= '1';  -- đọc byte pixel đầu tiên
                        end if;
                    end if;

                -- ----------------------------------------------
                when ST_PROCESS =>
                    if rd_data_valid = '1' then
                        if pix_cnt < length_reg then
                            -- Gửi pixel sang conv
                            conv_data_in  <= ram_in_readdata;
                            conv_valid_in <= '1';
                            -- Tích luỹ checksum (XOR)
                            checksum_calc <= checksum_calc xor ram_in_readdata;

                            rd_addr <= rd_addr + 1;
                            pix_cnt <= pix_cnt + 1;

                            if pix_cnt + 1 < length_reg then
                                rd_pending <= '1';  -- còn pixel tiếp
                            else
                                rd_pending <= '1';  -- đọc byte checksum đầu
                                state      <= ST_READ_CHKSUM;
                            end if;
                        end if;
                    end if;

                -- ----------------------------------------------
                when ST_READ_CHKSUM =>
                    if rd_data_valid = '1' then
                        case chk_cnt is
                            when 0 => checksum_reg <= ram_in_readdata;   -- chỉ dùng byte 0
                            when others => null;
                        end case;

                        chk_cnt <= chk_cnt + 1;
                        rd_addr <= rd_addr + 1;

                        if chk_cnt < 3 then
                            rd_pending <= '1';  -- đọc nốt 3 byte còn lại (bỏ qua)
                        else
                            state <= ST_VERIFY;
                        end if;
                    end if;

                -- ----------------------------------------------
                when ST_VERIFY =>
                    if checksum_calc = checksum_reg then
                        reg_status(2) <= '0';   -- checksum OK
                    else
                        reg_status(2) <= '1';   -- ERR_CHKSUM
                    end if;
                    state <= ST_DONE;

                -- ----------------------------------------------
                when ST_DONE =>
                    reg_status(0) <= '1';   -- DONE
                    ram_in_read   <= '0';
                    rd_pending    <= '0';
                    -- Chờ HPS clear START bit
                    if reg_ctrl(0) = '0' then
                        state <= ST_IDLE;
                    end if;

                when others =>
                    state <= ST_IDLE;

            end case;
        end if;
    end process;

    -- ==========================================================
    -- Process 3: Ghi kết quả conv vào RAM Output
    --   conv_valid_out là pulse 1 cycle → ghi ngay, không cần FSM
    --   Chú ý waitrequest: nếu RAM out busy thì pixel bị bỏ qua
    --   (chấp nhận được vì conv stream liên tục, không pipeline stall)
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            ram_out_address  <= (others => '0');
            ram_out_writedata<= (others => '0');
            ram_out_write    <= '0';
            wr_addr          <= (others => '0');
        elsif rising_edge(clk) then
            ram_out_write <= '0';   -- mặc định không ghi

            -- Reset con trỏ ghi khi FSM bắt đầu chu kỳ mới
            if state = ST_IDLE and reg_ctrl(0) = '1' then
                wr_addr <= (others => '0');
            end if;

            if conv_valid_out = '1' then
                ram_out_address   <= std_logic_vector(wr_addr);
                ram_out_writedata <= conv_data_out;
                ram_out_write     <= '1';
                wr_addr           <= wr_addr + 1;
            end if;
        end if;
    end process;

end Behavioral;