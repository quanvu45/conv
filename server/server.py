#!/usr/bin/env python3
"""
FPGA Inference Server

Runs on PC, sends images to DE1-SoC via TCP and receives processed results.
Requires: pip install Pillow
"""

import os
import sys
import socket
import threading
import time
import shlex

DEFAULT_PORT = 9001

# Trạng thái kết nối với board PS
active_conn = None
active_lock = threading.Lock()

# ====================================================================
# Client Handler (Lắng nghe từ PS gửi lên)
# ====================================================================
def handle_client(conn, addr):
    global active_conn
    print(f"\n[{addr}] PS Board connected!")

    try:
        data = b""
        while True:
            # Đọc cho đến khi gặp ký tự xuống dòng (newline)
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk

            line, data = data.split(b"\n", 1)
            command = line.decode('utf-8', errors='replace').strip()
            if not command:
                continue

            # ---- Board đăng ký kết nối ----
            if command == "REGISTER_INFERENCE":
                with active_lock:
                    active_conn = conn
                print(f"[{addr}] PS is Ready. You can now use the 'send' command.")

            # ---- Board trả kết quả xử lý ảnh về ----
            elif command.startswith("RESULT_IMAGE"):
                parts = command.split()
                if len(parts) < 2:
                    continue
                
                size = int(parts[1])
                print(f"[{addr}] Receiving processed image ({size} bytes)...")
                
                result_data = data
                while len(result_data) < size:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    result_data += chunk
                
                img_bytes = result_data[:size]
                data = result_data[size:] # Giữ lại phần dư nếu có
                
                # Lưu file kết quả
                try:
                    from PIL import Image
                    if size == 640 * 640:
                        res_img = Image.frombytes('L', (640, 640), img_bytes)
                        filename = f"result_{int(time.time())}.jpg"
                        res_img.save(filename)
                        print(f"[{addr}] SUCCESS! Image saved as {filename}")
                    else:
                        raise ValueError("Size mismatch for 640x640")
                except Exception:
                    filename = f"result_{int(time.time())}.raw"
                    with open(filename, "wb") as f:
                        f.write(img_bytes)
                    print(f"[{addr}] SUCCESS! Raw data saved as {filename}")

    except ConnectionResetError:
        pass
    except Exception as e:
        print(f"[{addr}] Error: {e}")
    finally:
        with active_lock:
            if active_conn == conn:
                active_conn = None
        conn.close()
        print(f"[{addr}] PS Board disconnected")

# ====================================================================
# Console Interface (Giao diện nhập lệnh từ PC để gửi ảnh)
# ====================================================================
def console_thread():
    global active_conn
    print("Interactive console ready. Type 'help' for commands.")
    
    while True:
        try:
            cmd_line = input("Server> ")
            if not cmd_line.strip():
                continue
            
            args = shlex.split(cmd_line)
            
            if args[0] == "send":
                if len(args) < 2:
                    print("Usage: send <path_to_image>")
                    continue
                    
                path = args[1]
                if not os.path.isfile(path):
                    print(f"File not found: {path}")
                    continue
                    
                with active_lock:
                    if active_conn is None:
                        print("Error: No PS board connected yet! Wait for connection.")
                        continue
                    
                    try:
                        from PIL import Image
                        print(f"Loading {path}...")
                        img = Image.open(path).convert('L') # Chuyển sang ảnh xám
                        if img.size != (640, 640):
                            print(f"Resizing from {img.size} to 640x640...")
                            img = img.resize((640, 640))
                        
                        raw_data = img.tobytes()
                        size = len(raw_data)
                    except ImportError:
                        print("WARNING: 'Pillow' (PIL) not found. Sending raw file.")
                        with open(path, "rb") as f:
                            raw_data = f.read()
                        size = len(raw_data)
                    except Exception as e:
                        print(f"Failed to process image: {e}")
                        continue
                        
                    print(f"Sending {size} bytes to PS...")
                    try:
                        # Gửi Header Lệnh mạng (PC -> PS)
                        active_conn.sendall(f"PROCESS_IMAGE {size}\n".encode('utf-8'))
                        # Gửi Payload ảnh
                        active_conn.sendall(raw_data)
                        print("Image sent! Waiting for FPGA to process...")
                    except Exception as e:
                        print(f"Failed to send: {e}")
                        active_conn = None
                        
            elif args[0] == "help":
                print("Commands:")
                print("  send <image>  : Send a JPG/PNG to the FPGA for processing")
                print("  help          : Show this message")
            else:
                print(f"Unknown command: {args[0]}")
                
        except EOFError:
            break
        except Exception as e:
            print(f"Console error: {e}")

# ====================================================================
# Main Server Setup
# ====================================================================
def main():
    print("==================================================")
    print("  FPGA Image Inference Server (TCP)")
    print(f"  Listening on Port: {DEFAULT_PORT}")
    print("==================================================\n")

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        server.bind(('0.0.0.0', DEFAULT_PORT))
    except OSError as e:
        print(f"ERROR: Cannot bind to port {DEFAULT_PORT}: {e}")
        sys.exit(1)

    server.listen(5)

    c_thread = threading.Thread(target=console_thread, daemon=True)
    c_thread.start()

    try:
        while True:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
            t.start()
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        server.close()

if __name__ == "__main__":
    main()