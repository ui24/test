#!/bin/bash
set -e

echo "🚀 Updating system..."
apt update && apt upgrade -y

echo "📦 Installing dependencies..."
apt install -y python3 python3-venv python3-pip git nginx curl wget

# ---------- Add Swap (for low RAM VPS) ----------
if ! swapon --show | grep -q '/swapfile'; then
  echo "💾 Creating 2G swap..."
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
else
  echo "ℹ️ Swap already exists, skipping..."
fi

# ---------- Python Environment ----------
echo "🐍 Setting up Python virtual environment..."
mkdir -p /opt/photoenhancer
cd /opt/photoenhancer

if [ ! -d "venv" ]; then
  python3 -m venv venv
fi

source venv/bin/activate

# ---------- Install Python Packages ----------
echo "📥 Installing Python packages (force reinstall, CPU version)..."
pip install --upgrade pip
pip install --force-reinstall torch torchvision --extra-index-url https://download.pytorch.org/whl/cpu
pip install --force-reinstall fastapi uvicorn pillow opencv-python rembg realesrgan

# ---------- Backend Code ----------
echo "💻 Creating FastAPI backend..."
cat > /opt/photoenhancer/app.py << 'EOF'
from fastapi import FastAPI, UploadFile
from fastapi.responses import FileResponse
import os, uuid, subprocess
from PIL import Image
from rembg import remove

app = FastAPI()
UPLOAD_DIR = "uploads"
RESULT_DIR = "results"
os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(RESULT_DIR, exist_ok=True)

@app.post("/process/")
async def process_image(file: UploadFile, enhance: bool = True, remove_bg: bool = False, size: str = "original"):
    file_id = str(uuid.uuid4())
    input_path = f"{UPLOAD_DIR}/{file_id}.png"
    output_path = f"{RESULT_DIR}/{file_id}.png"

    with open(input_path, "wb") as f:
        f.write(await file.read())

    # Enhance with Real-ESRGAN (CPU)
    if enhance:
        subprocess.run(["realesrgan-ncnn-vulkan", "-i", input_path, "-o", output_path, "-s", "2"], check=True)
    else:
        output_path = input_path

    img = Image.open(output_path)

    if remove_bg:
        img = remove(img)

    if size != "original":
        try:
            w, h = map(int, size.lower().split("x"))
            img = img.resize((w, h))
        except:
            pass

    img.save(output_path)
    return {"download_url": f"/download/{file_id}.png"}

@app.get("/download/{file_name}")
async def download(file_name: str):
    path = f"{RESULT_DIR}/{file_name}"
    return FileResponse(path, media_type="image/png", filename=file_name)
EOF

# ---------- Systemd Service ----------
echo "⚙️ Creating Systemd service..."
cat > /etc/systemd/system/photoenhancer.service << 'EOF'
[Unit]
Description=Photo Enhancer FastAPI Service
After=network.target

[Service]
User=root
WorkingDirectory=/opt/photoenhancer
ExecStart=/opt/photoenhancer/venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable photoenhancer
systemctl restart photoenhancer

# ---------- Nginx ----------
echo "🌐 Setting up Nginx..."
cat > /etc/nginx/sites-available/photoenhancer << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        root /opt/photoenhancer/frontend;
        index index.html;
    }

    location /process/ {
        proxy_pass http://127.0.0.1:8000/process/;
    }

    location /download/ {
        proxy_pass http://127.0.0.1:8000/download/;
    }
}
EOF

ln -sf /etc/nginx/sites-available/photoenhancer /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# ---------- Frontend ----------
echo "🎨 Creating frontend..."
mkdir -p /opt/photoenhancer/frontend
cat > /opt/photoenhancer/frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>AI Photo Enhancer</title>
  <style>
    body { font-family: sans-serif; padding: 20px; }
    img { max-width: 400px; margin-top: 20px; border: 1px solid #ccc; }
  </style>
  <script>
    async function uploadImage() {
      const file = document.getElementById("file").files[0];
      if (!file) { alert("Please select a file"); return; }
      const formData = new FormData();
      formData.append("file", file);
      formData.append("enhance", document.getElementById("enhance").checked);
      formData.append("remove_bg", document.getElementById("remove_bg").checked);
      formData.append("size", document.getElementById("size").value);

      document.getElementById("status").innerText = "⏳ Processing...";
      let res = await fetch("/process/", { method: "POST", body: formData });
      let data = await res.json();
      document.getElementById("result").src = data.download_url;
      document.getElementById("download").href = data.download_url;
      document.getElementById("status").innerText = "✅ Done!";
    }
  </script>
</head>
<body>
  <h2>AI Photo Enhancer (CPU Only)</h2>
  <input type="file" id="file"><br><br>
  <label><input type="checkbox" id="enhance" checked> Enhance</label>
  <label><input type="checkbox" id="remove_bg"> Remove Background</label><br><br>
  <label>Resize: <input type="text" id="size" placeholder="e.g. 1024x1024 or original"></label><br><br>
  <button onclick="uploadImage()">Process</button>
  <p id="status"></p>
  <img id="result">
  <br>
  <a id="download" download>Download Enhanced Image</a>
</body>
</html>
EOF

echo "✅ Setup complete! Visit http://YOUR_SERVER_IP"
