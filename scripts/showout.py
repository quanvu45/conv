import math
from PIL import Image
import os
# Thay đổi width mặc định thành 638
def txt_to_image(txt_path, output_image_path, width=638):
    pixels = []
    with open(txt_path, 'r') as f:
        for line in f:
            val = line.strip()
            if val:
                pixels.append(int(val))
    
    # Tính lại chiều cao dựa trên width thực tế
    height = len(pixels) // width
    
    # Cắt bỏ vài pixel rác dư thừa cuối cùng (nếu có)
    valid_pixels = pixels[:width * height]
    
    img = Image.new('L', (width, height))
    img.putdata(valid_pixels)
    img.save(output_image_path)
    print(f"Đã tạo thành công ảnh: {output_image_path} (Kích thước: {width}x{height})")
scripts_dir = os.path.dirname(os.path.abspath(__file__))
base_dir = os.path.dirname(scripts_dir)
input_path = os.path.join(base_dir, "image", "img_out.txt")
output_path = os.path.join(base_dir, "image", "output.jpg")
txt_to_image(input_path,output_path, width=638)