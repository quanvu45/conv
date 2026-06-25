from PIL import Image
import os
def image_to_txt(image_path, txt_path, width=640, height=640):
    # Mở ảnh và chuyển sang GrayScale (ảnh xám 8-bit)
    img = Image.open(image_path).convert('L')
    img = img.resize((width, height))
    
    pixels = list(img.getdata())
    
    # Ghi từng pixel ra file text (mỗi dòng 1 số thập phân)
    with open(txt_path, 'w') as f:
        for p in pixels:
            f.write(f"{p}\n")
            
    print(f"Đã xuất file {txt_path} với {len(pixels)} pixels.")
scripts_dir = os.path.dirname(os.path.abspath(__file__))
base_dir = os.path.dirname(scripts_dir)
input_path = os.path.join(base_dir, "image", "flower.jpg")
output_path = os.path.join(base_dir, "image", "img_in.txt")
# Chạy thử
image_to_txt(input_path,output_path)