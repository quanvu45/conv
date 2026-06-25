-- ============================================================
-- File    : conv.vhd
-- Module  : conv
-- Chức năng: Gaussian Blur 3x3 pipeline 5 tầng, streaming 8-bit
-- Kernel  : [1 2 1 / 2 4 2 / 1 2 1] / 16
-- Latency : 5 clock sau valid_in đầu tiên có valid_out
-- ============================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity conv is
    generic (
        IMG_WIDTH  : integer := 640;   -- Số pixel một hàng
        DATA_WIDTH : integer := 8      -- Độ rộng pixel (bit)
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        -- Input stream (từ packet_manager)
        data_in   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        valid_in  : in  std_logic;
        -- Output stream (ra packet_manager → ram_out)
        data_out  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        valid_out : out std_logic
    );
end conv;

architecture Behavioral of conv is

    -- ----------------------------------------------------------
    -- Line Buffer: 2 hàng x IMG_WIDTH pixel
    -- Quartus infer tự động thành M10K BRAM
    -- ----------------------------------------------------------
    type line_buf_t is array (0 to IMG_WIDTH-1) of unsigned(DATA_WIDTH-1 downto 0);
    signal line_buf_1 : line_buf_t := (others => (others => '0'));
    signal line_buf_2 : line_buf_t := (others => (others => '0'));

    signal wr_ptr : integer range 0 to IMG_WIDTH-1 := 0;

    -- Stage 1 outputs
    signal s1_lb1      : unsigned(DATA_WIDTH-1 downto 0);   -- pixel hàng Y-2
    signal s1_lb2      : unsigned(DATA_WIDTH-1 downto 0);   -- pixel hàng Y-1
    signal s1_cur      : unsigned(DATA_WIDTH-1 downto 0);   -- pixel hàng Y (hiện tại)
    signal s1_valid    : std_logic;
    signal s1_col      : integer range 0 to IMG_WIDTH-1;
    signal s1_row      : integer range 0 to 1023;

    -- Stage 2: cửa sổ 3x3
    signal p00, p01, p02 : unsigned(DATA_WIDTH-1 downto 0); -- hàng Y-2 (cũ nhất)
    signal p10, p11, p12 : unsigned(DATA_WIDTH-1 downto 0); -- hàng Y-1
    signal p20, p21, p22 : unsigned(DATA_WIDTH-1 downto 0); -- hàng Y (mới nhất)
    signal s2_valid      : std_logic;
    signal s2_col        : integer range 0 to IMG_WIDTH-1;
    signal s2_row        : integer range 0 to 1023;

    -- Stage 3: tổng từng hàng
    -- max mỗi hàng: 4 * 255 = 1020 → cần 10 bit; dùng 12 bit để an toàn
    signal sum_row0 : unsigned(11 downto 0);  -- 1*p02 + 2*p01 + 1*p00
    signal sum_row1 : unsigned(11 downto 0);  -- 2*p12 + 4*p11 + 2*p10
    signal sum_row2 : unsigned(11 downto 0);  -- 1*p22 + 2*p21 + 1*p20
    signal s3_valid : std_logic;
    signal s3_col   : integer range 0 to IMG_WIDTH-1;
    signal s3_row   : integer range 0 to 1023;

    -- Stage 4: tổng toàn bộ
    -- max: 1020 + 2040 + 1020 = 4080 → cần 12 bit
    signal total    : unsigned(11 downto 0);
    signal s4_valid : std_logic;
    signal s4_col   : integer range 0 to IMG_WIDTH-1;
    signal s4_row   : integer range 0 to 1023;

    -- Bộ đếm toạ độ pixel đầu vào
    signal col_cnt : integer range 0 to IMG_WIDTH-1 := 0;
    signal row_cnt : integer range 0 to 1023        := 0;

begin

    -- ==========================================================
    -- STAGE 1: Đọc / Ghi line buffer
    --   - Đọc pixel cũ của cột hiện tại từ 2 line buffer
    --   - Ghi pixel hiện tại vào line_buf_1
    --   - Dịch line_buf_1 → line_buf_2
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            wr_ptr  <= 0;
            col_cnt <= 0;
            row_cnt <= 0;
            s1_valid <= '0';
        elsif rising_edge(clk) then
            s1_valid <= valid_in;

            if valid_in = '1' then
                -- Đọc giá trị cũ (đọc trước ghi để tránh read-during-write)
                s1_lb1 <= line_buf_1(wr_ptr);   -- hàng Y-1
                s1_lb2 <= line_buf_2(wr_ptr);   -- hàng Y-2

                -- Ghi pixel mới vào line_buf_1; dịch hàng cũ xuống line_buf_2
                line_buf_1(wr_ptr) <= unsigned(data_in);
                line_buf_2(wr_ptr) <= line_buf_1(wr_ptr);

                -- Lưu pixel hiện tại để dùng ở Stage 2
                s1_cur <= unsigned(data_in);

                -- Lưu toạ độ tại thời điểm valid_in
                s1_col <= col_cnt;
                s1_row <= row_cnt;

                -- Cập nhật con trỏ ghi (wrap-around)
                if wr_ptr = IMG_WIDTH - 1 then
                    wr_ptr <= 0;
                else
                    wr_ptr <= wr_ptr + 1;
                end if;

                -- Cập nhật bộ đếm cột / hàng
                if col_cnt = IMG_WIDTH - 1 then
                    col_cnt <= 0;
                    if row_cnt = 1023 then
                        row_cnt <= 0;
                    else
                        row_cnt <= row_cnt + 1;
                    end if;
                else
                    col_cnt <= col_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- ==========================================================
    -- STAGE 2: Cập nhật cửa sổ trượt 3x3
    --   Thứ tự pixel trong mỗi hàng (trái → phải):
    --   pX2 (cũ nhất) ← pX1 ← pX0 (mới nhất vừa vào)
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            s2_valid <= '0';
            p00 <= (others=>'0'); p01 <= (others=>'0'); p02 <= (others=>'0');
            p10 <= (others=>'0'); p11 <= (others=>'0'); p12 <= (others=>'0');
            p20 <= (others=>'0'); p21 <= (others=>'0'); p22 <= (others=>'0');
        elsif rising_edge(clk) then
            s2_valid <= s1_valid;
            s2_col   <= s1_col;
            s2_row   <= s1_row;

            if s1_valid = '1' then
                -- Hàng Y-2 (cũ nhất): s1_lb2
                p02 <= p01; p01 <= p00; p00 <= s1_lb2;
                -- Hàng Y-1: s1_lb1
                p12 <= p11; p11 <= p10; p10 <= s1_lb1;
                -- Hàng Y (hiện tại): s1_cur
                p22 <= p21; p21 <= p20; p20 <= s1_cur;
            end if;
        end if;
    end process;

    -- ==========================================================
    -- STAGE 3: Tính tổng từng hàng với trọng số Gaussian
    --   Kernel: [1 2 1]
    --           [2 4 2]
    --           [1 2 1]
    --   Dùng shift để tránh phép nhân phần cứng
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            s3_valid <= '0';
            sum_row0 <= (others=>'0');
            sum_row1 <= (others=>'0');
            sum_row2 <= (others=>'0');
        elsif rising_edge(clk) then
            s3_valid <= s2_valid;
            s3_col   <= s2_col;
            s3_row   <= s2_row;

            if s2_valid = '1' then
                -- Hàng 0: 1*p02 + 2*p01 + 1*p00
                sum_row0 <= resize(p02, 12)
                          + shift_left(resize(p01, 12), 1)
                          + resize(p00, 12);

                -- Hàng 1: 2*p12 + 4*p11 + 2*p10
                sum_row1 <= shift_left(resize(p12, 12), 1)
                          + shift_left(resize(p11, 12), 2)
                          + shift_left(resize(p10, 12), 1);

                -- Hàng 2: 1*p22 + 2*p21 + 1*p20
                sum_row2 <= resize(p22, 12)
                          + shift_left(resize(p21, 12), 1)
                          + resize(p20, 12);
            end if;
        end if;
    end process;

    -- ==========================================================
    -- STAGE 4: Tổng toàn bộ
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            s4_valid <= '0';
            total    <= (others=>'0');
        elsif rising_edge(clk) then
            s4_valid <= s3_valid;
            s4_col   <= s3_col;
            s4_row   <= s3_row;

            if s3_valid = '1' then
                total <= sum_row0 + sum_row1 + sum_row2;
            end if;
        end if;
    end process;

    -- ==========================================================
    -- STAGE 5: Chuẩn hoá và xuất kết quả
    --   Tổng trọng số kernel = 16 → chia 16 = dịch phải 4 bit
    --   total(11 downto 4) = total / 16
    --   Loại bỏ 2 cột đầu và 2 hàng đầu (không đủ dữ liệu 3x3)
    -- ==========================================================
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            data_out  <= (others => '0');
            valid_out <= '0';
        elsif rising_edge(clk) then
            if s4_valid = '1' then
                data_out <= std_logic_vector(total(11 downto 4));

                if s4_row >= 2 and s4_col >= 2 then
                    valid_out <= '1';
                else
                    valid_out <= '0';
                end if;
            else
                valid_out <= '0';
            end if;
        end if;
    end process;

end Behavioral;