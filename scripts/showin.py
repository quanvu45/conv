from PIL import Image
import os
def verify_input_txt(txt_path, output_jpg_path, width=640, height=640):
    pixels = []
    
    print(f"Đang đọc file {txt_path}...")
    with open(txt_path, 'r') as f:
        for line in f:
            val = line.strip()
            if val:
                pixels.append(int(val))
    
    # Kiểm tra xem dữ liệu có đủ cho khung hình 640x640 không
    expected_pixels = width * height
    print(f"Tổng số pixel đọc được: {len(pixels)} (Dự kiến: {expected_pixels})")
    
    # Cắt lấy đúng lượng pixel cần thiết
    valid_pixels = pixels[:expected_pixels]
    
    # Tạo ảnh mới ở chế độ 'L' (Grayscale - 8bit Xám)
    img = Image.new('L', (width, height))
    img.putdata(valid_pixels)
    
    # 1. Hiển thị ảnh trực tiếp lên màn hình (mở bằng trình xem ảnh mặc định của máy)
    img.show()
    
    # 2. Lưu lại thành file JPG
    img.save(output_jpg_path)
    print(f"Đã phục hồi và lưu thành công ảnh: {output_jpg_path}")
scripts_dir = os.path.dirname(os.path.abspath(__file__))
base_dir = os.path.dirname(scripts_dir)
input_path = os.path.join(base_dir, "image", "img_in.txt")
output_path = os.path.join(base_dir, "image", "input.jpg")
verify_input_txt(input_path,output_path, width=640, height=640)