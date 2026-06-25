/*
 * FPGA Inference Communicator for DE1-SoC (Cyclone V)
 * * Features:
 * - Map AXI Bridge for Image RAM (PS <-> PL)
 * - Map Lightweight H2F Bridge for Control Registers
 * - TCP Client to receive images and send back results
 * - Packet-based communication (Header + Payload + Checksum) with FPGA
 *
 * Build: arm-linux-gnueabihf-gcc -o fpga_app fpga_app.c -Wall -lpthread
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/mman.h>
#include <pthread.h>
#include <stdint.h>

/* ====================================================================
 * Inference Hardware Map (Linux <-> FPGA)
 * ==================================================================== */

/* AXI Bridge for Image RAM mapping */
#define H2F_AXI_BASE           0xFF200000
#define H2F_AXI_SPAN           0x00400000 // 4MB span
#define FPGA_INPUT_IMG_OFFSET  0x00000000
#define FPGA_OUTPUT_IMG_OFFSET 0x00200000

/* Lightweight Bridge for Control Registers */
#define LWH2F_BASE             0xFF200000
#define LWH2F_SPAN             0x00010000 // 64KB span
#define FPGA_CTRL_REG_OFFSET   0x00
#define FPGA_STATUS_REG_OFFSET 0x04

#define FPGA_CTRL_START        (1 << 0)
#define FPGA_STATUS_DONE       (1 << 0)

/* ====================================================================
 * Network Configuration
 * ==================================================================== */
#define SERVER_IP              "192.168.10.100"
#define SERVER_PORT            9001

/* ====================================================================
 * Giao thức truyền tin PS <-> PL
 * ==================================================================== */
#define MSG_MAGIC_WORD         0xAA55
#define CMD_INFERENCE          0x0001
#define CMD_ECHO               0x0002

typedef struct __attribute__((packed)) {
    uint16_t magic;      // 0xAA55
    uint16_t cmd;        // Lệnh điều khiển
    uint32_t length;     // Kích thước payload
} MsgHeader;

/* ====================================================================
 * Global State
 * ==================================================================== */

static volatile int g_running = 1;

/* Inference mapped pointers */
static void *g_axi_base = MAP_FAILED;
static void *g_lwh2f_base = MAP_FAILED;
static volatile uint8_t *g_fpga_in_img;
static volatile uint8_t *g_fpga_out_img;
static volatile uint32_t *g_fpga_ctrl;
static volatile uint32_t *g_fpga_status;

/* ====================================================================
 * Signal Handlers
 * ==================================================================== */

static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

/* ====================================================================
 * Hardware Access - Map Memory
 * ==================================================================== */

static int hw_init(void) {
    int fd = open("/dev/mem", (O_RDWR | O_SYNC));
    if (fd < 0) {
        perror("APP: cannot open /dev/mem");
        return -1;
    }

    /* Map AXI for Inference Data */
    g_axi_base = mmap(NULL, H2F_AXI_SPAN, (PROT_READ | PROT_WRITE), MAP_SHARED, fd, H2F_AXI_BASE);
    if (g_axi_base == MAP_FAILED) {
        printf("APP: ERROR - mmap AXI failed.\n");
        close(fd);
        return -1;
    }
    g_fpga_in_img = (volatile uint8_t *)((char *)g_axi_base + FPGA_INPUT_IMG_OFFSET);
    g_fpga_out_img = (volatile uint8_t *)((char *)g_axi_base + FPGA_OUTPUT_IMG_OFFSET);

    /* Map LWH2F for Control Registers */
    g_lwh2f_base = mmap(NULL, LWH2F_SPAN, (PROT_READ | PROT_WRITE), MAP_SHARED, fd, LWH2F_BASE);
    if (g_lwh2f_base == MAP_FAILED) {
        printf("APP: ERROR - mmap LWH2F failed.\n");
        munmap(g_axi_base, H2F_AXI_SPAN);
        close(fd);
        return -1;
    }
    g_fpga_ctrl = (volatile uint32_t *)((char *)g_lwh2f_base + FPGA_CTRL_REG_OFFSET);
    g_fpga_status = (volatile uint32_t *)((char *)g_lwh2f_base + FPGA_STATUS_REG_OFFSET);

    close(fd);
    printf("APP: Hardware mapped successfully.\n");
    return 0;
}

static void hw_cleanup(void) {
    if (g_axi_base != MAP_FAILED) {
        munmap(g_axi_base, H2F_AXI_SPAN);
    }
    if (g_lwh2f_base != MAP_FAILED) {
        munmap(g_lwh2f_base, LWH2F_SPAN);
    }
}

/* ====================================================================
 * Packet Logic & FPGA Communication
 * ==================================================================== */

static uint32_t calculate_checksum(const uint8_t *data, uint32_t length) {
    uint32_t checksum = 0;
    uint32_t i;
    for (i = 0; i < length; i++) {
        checksum ^= data[i];
    }
    return checksum;
}

/* Hàm hỗ trợ in dữ liệu dạng Hex (tối đa 16 byte để tránh ngập console) */
static void print_hex_dump(const char *label, const uint8_t *data, uint32_t len) {
    printf("%s (len=%u): ", label, len);
    uint32_t print_len = len > 16 ? 16 : len; 
    for (uint32_t i = 0; i < print_len; i++) {
        printf("%02X ", data[i]);
    }
    if (len > 16) printf("... ");
    printf("\n");
}

/**
 * Đóng gói bản tin và gửi xuống FPGA
 */
static int fpga_send_message_and_wait(uint16_t cmd, const uint8_t *payload, uint32_t payload_len, uint8_t *result_buf) {
    if (g_axi_base == MAP_FAILED || g_lwh2f_base == MAP_FAILED) {
        printf("APP_INF: Hardware not mapped!\n");
        return -1;
    }

    MsgHeader header;
    header.magic = MSG_MAGIC_WORD;
    header.cmd = cmd;
    header.length = payload_len;

    uint32_t checksum = calculate_checksum(payload, payload_len);
    uint32_t offset = 0;
    
    /* Ghi Header -> Payload -> Checksum vào AXI RAM */
    memcpy((void *)(g_fpga_in_img + offset), &header, sizeof(MsgHeader));
    offset += sizeof(MsgHeader);
    
    memcpy((void *)(g_fpga_in_img + offset), payload, payload_len);
    offset += payload_len;
    
    memcpy((void *)(g_fpga_in_img + offset), &checksum, sizeof(uint32_t));

    /* THÊM LOG DUMP BẢN TIN TRƯỚC KHI GỬI (TX) */
    printf("\n--- TX PACKET DUMP (PC -> FPGA) ---\n");
    uint8_t *tx_ptr = (uint8_t *)g_fpga_in_img;
    print_hex_dump("  HEADER  ", tx_ptr, sizeof(MsgHeader));
    print_hex_dump("  PAYLOAD ", tx_ptr + sizeof(MsgHeader), payload_len);
    print_hex_dump("  CHECKSUM", tx_ptr + sizeof(MsgHeader) + payload_len, sizeof(uint32_t));
    printf("-----------------------------------\n");

    printf("APP_INF: Packed Msg [Cmd:0x%04X, Len:%u, Checksum:0x%08X]. Starting FPGA...\n", 
            cmd, payload_len, checksum);

    /* Kích hoạt FPGA */
    *g_fpga_ctrl = FPGA_CTRL_START;

    /* Chờ FPGA xử lý xong (Polling) */
    int timeout = 500; /* 5 giây max */
    while ((*g_fpga_status & FPGA_STATUS_DONE) == 0 && timeout > 0) {
        usleep(10000); /* 10ms */
        timeout--;
    }

    *g_fpga_ctrl = 0; /* Reset START */

    if (timeout <= 0) {
        printf("APP_INF: FPGA Timeout!\n");
        return -1;
    }

    /* Đọc kết quả từ FPGA */
    printf("APP_INF: FPGA Done. Copying %u bytes result back...\n", payload_len);
    memcpy(result_buf, (void *)g_fpga_out_img, payload_len); 

    /* THÊM LOG DUMP BẢN TIN NHẬN VỀ (RX) */
    printf("\n--- RX PACKET DUMP (FPGA -> PC) ---\n");
    print_hex_dump("  RESULT  ", result_buf, payload_len);
    printf("-----------------------------------\n\n");

    return 0;
}

/* ====================================================================
 * Network Thread - Receive from Server -> FPGA -> Send to Server
 * ==================================================================== */

static void *inference_network_thread(void *arg) {
    (void)arg;
    struct sockaddr_in serv_addr;
    
    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(SERVER_PORT);
    if (inet_pton(AF_INET, SERVER_IP, &serv_addr.sin_addr) <= 0) {
        printf("APP_NET: Invalid server address\n");
        return NULL;
    }

    uint8_t *img_buf = malloc(1024 * 1024); // 1MB buffer
    uint8_t *res_buf = malloc(1024 * 1024);

    while (g_running) {
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            sleep(2);
            continue;
        }

        if (connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
            close(sock);
            sleep(2);
            continue;
        }

        const char *reg_msg = "REGISTER_INFERENCE\n";
        send(sock, reg_msg, strlen(reg_msg), 0);
        printf("APP_NET: Connected to Server\n");

        while (g_running) {
            char cmd_buf[256];
            int cmd_len = 0;
            char c;
            
            /* Read command line */
            while (1) {
                int n = recv(sock, &c, 1, 0);
                if (n <= 0) break;
                if (c == '\n') {
                    cmd_buf[cmd_len] = '\0';
                    break;
                }
                if (cmd_len < sizeof(cmd_buf) - 1) {
                    cmd_buf[cmd_len++] = c;
                }
            }
            if (c != '\n') break; /* Connection dropped */

            if (strncmp(cmd_buf, "PROCESS_IMAGE ", 14) == 0) {
                int size = atoi(cmd_buf + 14);
                if (size <= 0 || size > 1024*1024) {
                    printf("APP_NET: Invalid image size %d\n", size);
                    continue;
                }

                printf("APP_NET: Receiving Image (%d bytes)...\n", size);
                int received = 0;
                
                /* VÒNG LẶP NHẬN DATA VỚI LOG TIẾN ĐỘ */
                while (received < size) {
                    int n = recv(sock, img_buf + received, size - received, 0);
                    if (n <= 0) {
                        printf("\nAPP_NET: Loi mang hoac Server ngat ket noi (n=%d)\n", n);
                        break;
                    }
                    received += n;
                    
                    /* In log tiến độ và ép hiển thị ngay lập tức */
                    printf("\rAPP_NET: Downloaded %d / %d bytes", received, size);
                    fflush(stdout); 
                }
                printf("\n"); // Xuống dòng sau khi nhận xong

                if (received < size) {
                    printf("APP_NET: Nhan thieu du lieu. Huy bo khung hinh nay.\n");
                    break;
                }

                printf("APP_NET: Da nhan du %d bytes! Chuan bi ghi xuong FPGA...\n", size);
                fflush(stdout);

                /* --- GỌI HÀM GIAO TIẾP VỚI FPGA (PACKET-BASED) --- */
                if (fpga_send_message_and_wait(CMD_INFERENCE, img_buf, size, res_buf) == 0) {
                    
                    /* Trả kết quả về Server TCP */
                    char resp_hdr[64];
                    snprintf(resp_hdr, sizeof(resp_hdr), "RESULT_IMAGE %d\n", size);
                    send(sock, resp_hdr, strlen(resp_hdr), 0);
                    
                    int sent = 0;
                    while (sent < size) {
                        int n = send(sock, res_buf + sent, size - sent, 0);
                        if (n <= 0) break;
                        sent += n;
                    }
                    if (sent < size) break;
                    printf("APP_NET: Result sent back to server.\n");

                } else {
                    printf("APP_NET: FPGA Inference failed.\n");
                    break;
                }
            }
        }
        
        printf("APP_NET: Disconnected. Retrying in 2s...\n");
        close(sock);
        sleep(2);
    }
    
    free(img_buf);
    free(res_buf);
    return NULL;
}

/* ====================================================================
 * Main Entry Point
 * ==================================================================== */

int main(void) {
    printf("================================================\n");
    printf("  FPGA Inference Communicator\n");
    printf("  Target Server: %s:%d\n", SERVER_IP, SERVER_PORT);
    printf("================================================\n");

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    if (hw_init() < 0) {
        fprintf(stderr, "APP: Failed to map hardware. Exiting...\n");
        return -1;
    }

    pthread_t inf_thread;
    if (pthread_create(&inf_thread, NULL, inference_network_thread, NULL) != 0) {
        fprintf(stderr, "APP: Failed to create inference thread\n");
        hw_cleanup();
        return -1;
    }

    printf("APP: Running main loop. Press Ctrl+C to exit.\n\n");

    /* Main loop: Nothing else to do but wait, thread handles everything */
    while (g_running) {
        sleep(1);
    }

    printf("\nAPP: Shutting down...\n");
    pthread_join(inf_thread, NULL);
    hw_cleanup();
    printf("APP: Goodbye.\n");

    return 0;
}