#!/usr/bin/env bash
set -euo pipefail

# ============================
# Config (change if needed)
# ============================
APP_NAME="photoenhancer"
APP_USER="photoenhancer"
APP_DIR="/opt/${APP_NAME}"
INTERNAL_PORT=8000          # uvicorn internal port (not public)
PUBLIC_PORT=80              # Nginx listen port (80 by default)
DOMAIN="_"                 # Nginx server_name; use _ for any
PYTHON="python3"

# Parse flags
for arg in "$@"; do
  case $arg in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --public-port=*) PUBLIC_PORT="${arg#*=}" ;;
  esac
done

echo "[1/8] Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y curl git nginx ${PYTHON}-venv ${PYTHON}-dev build-essential libglib2.0-0 libsm6 libxrender1 libxext6

# Create app user & directory
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  sudo useradd -r -s /usr/sbin/nologin "$APP_USER"
fi
sudo mkdir -p "$APP_DIR"/{app,static,uploads,outputs,models}
sudo chown -R "$USER":"$USER" "$APP_DIR"
cd "$APP_DIR"

# ============================
# Write project files
# ============================
echo "[2/8] Writing project files..."

cat > requirements.txt <<'REQ'
fastapi==0.115.2
uvicorn[standard]==0.30.6
opencv-python-headless==4.10.0.84
numpy==1.26.4
REQ

mkdir -p app
cat > app/main.py <<'PY'
import os
from pathlib import Path
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from .enhance import enhance_image

BASE_DIR = Path(__file__).resolve().parent.parent
UPLOAD_DIR = BASE_DIR / "uploads"
OUTPUT_DIR = BASE_DIR / "outputs"
STATIC_DIR = BASE_DIR / "static"

UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
STATIC_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Photo Enhancer (CPU)")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

@app.get("/", response_class=HTMLResponse)
async def index():
    index_path = STATIC_DIR / "index.html"
    if not index_path.exists():
        return HTMLResponse("<h1>Photo Enhancer</h1><p>Frontend missing. Did you copy static files?</p>")
    return HTMLResponse(index_path.read_text(encoding="utf-8"))

@app.post("/api/enhance")
async def api_enhance(file: UploadFile = File(...)):
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Please upload an image file.")

    suffix = os.path.splitext(file.filename or "upload.jpg")[1].lower() or ".jpg"
    in_path = UPLOAD_DIR / ("in_" + next_tmp_name() + suffix)
    with open(in_path, "wb") as f:
        f.write(await file.read())

    out_path = OUTPUT_DIR / ("out_" + in_path.stem + ".png")
    try:
        enhance_image(str(in_path), str(out_path))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Enhancement failed: {e}")

    return {
        "original": f"/file/{in_path.name}",
        "enhanced": f"/file/{out_path.name}",
    }

@app.get("/file/{name}")
async def get_file(name: str):
    path = None
    for folder in (UPLOAD_DIR, OUTPUT_DIR):
        p = folder / name
        if p.exists():
            path = p
            break
    if not path:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(str(path))

_counter = 0

def next_tmp_name():
    global _counter
    _counter += 1
    return f"{_counter:08d}"
PY

cat > app/enhance.py <<'PY'
import os
import cv2
import numpy as np
from pathlib import Path

MODEL_PATH = Path(os.getenv("MODEL_PATH", "models/EDSR_x4.pb"))
_superres = None

def _load_model():
    global _superres
    if _superres is None:
        _superres = cv2.dnn_superres.DnnSuperResImpl_create()
        if not MODEL_PATH.exists():
            raise RuntimeError(f"Model not found at {MODEL_PATH}")
        _superres.readModel(str(MODEL_PATH))
        _superres.setModel("edsr", 4)
    return _superres

def _denoise_and_sharpen(img: np.ndarray) -> np.ndarray:
    den = cv2.fastNlMeansDenoisingColored(img, None, 8, 8, 7, 21)
    blur = cv2.GaussianBlur(den, (0, 0), 1.0)
    sharp = cv2.addWeighted(den, 1.3, blur, -0.3, 0)
    return sharp

def enhance_image(in_path: str, out_path: str) -> None:
    img = cv2.imdecode(np.fromfile(in_path, dtype=np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("Failed to read image")
    sr = _load_model()
    up = sr.upsample(img)
    out = _denoise_and_sharpen(up)
    ok, buf = cv2.imencode(".png", out)
    if not ok:
        raise ValueError("Failed to encode output")
    buf.tofile(out_path)
PY

# Static files
mkdir -p static
cat > static/index.html <<'HTML'
<!doctype html>
<html lang="bn">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Photo Enhancer (CPU)</title>
  <link rel="stylesheet" href="/static/style.css" />
</head>
<body>
  <div class="container">
    <h1>ফটো এনহ্যান্সার</h1>
    <p>GPU ছাড়াই CPU‑only আপস্কেলার (EDSR x4)। নিচে ছবি ড্রপ/আপলোড করুন।</p>

    <label class="uploader" id="uploader">
      <input type="file" id="file" accept="image/*" hidden />
      <span id="prompt">এখানে ক্লিক করুন বা ছবি টেনে আনুন</span>
    </label>

    <button id="enhanceBtn" disabled>Enhance</button>

    <div id="result" class="result hidden">
      <div class="compare" id="compare">
        <img id="imgBefore" alt="Before" />
        <div class="divider" id="divider"></div>
        <img id="imgAfter" alt="After" />
      </div>
      <a id="downloadBtn" class="download" href="#" download>Download enhanced</a>
    </div>
  </div>
  <script src="/static/main.js"></script>
</body>
</html>
HTML

cat > static/style.css <<'CSS'
* { box-sizing: border-box; }
body { font-family: system-ui, Arial, sans-serif; margin: 0; padding: 2rem; background: #0f172a; color: #e2e8f0; }
.container { max-width: 900px; margin: 0 auto; }
h1 { margin: 0 0 0.5rem; }
.uploader { display: block; border: 2px dashed #334155; padding: 2rem; border-radius: 16px; text-align: center; cursor: pointer; background: #111827; }
.uploader:hover { border-color: #64748b; }
#enhanceBtn { margin-top: 1rem; padding: 0.75rem 1.25rem; border: 0; border-radius: 12px; background: #2563eb; color: white; font-weight: 600; cursor: pointer; }
#enhanceBtn:disabled { opacity: .5; cursor: not-allowed; }
.result { margin-top: 2rem; }
.compare { position: relative; width: 100%; max-height: 70vh; overflow: hidden; border-radius: 16px; background: #0b1220; }
.compare img { display: block; width: 100%; height: auto; }
.compare #imgAfter { position: absolute; top: 0; left: 0; clip-path: inset(0 0 0 50%); }
.divider { position: absolute; top:0; bottom:0; left:50%; width:2px; background:#f8fafc; box-shadow: 0 0 0 9999px rgba(0,0,0,0); cursor: ew-resize; }
.download { display: inline-block; margin-top: 1rem; padding: 0.75rem 1rem; background: #22c55e; color: #052e16; font-weight: 700; border-radius: 12px; text-decoration: none; }
.hidden { display: none; }
CSS

cat > static/main.js <<'JS'
const fileInput = document.getElementById('file');
const uploader = document.getElementById('uploader');
const prompt = document.getElementById('prompt');
const enhanceBtn = document.getElementById('enhanceBtn');
const result = document.getElementById('result');
const imgBefore = document.getElementById('imgBefore');
const imgAfter = document.getElementById('imgAfter');
const divider = document.getElementById('divider');
let selectedFile = null;

uploader.addEventListener('click', () => fileInput.click());
uploader.addEventListener('dragover', (e) => { e.preventDefault(); uploader.classList.add('hover'); });
uploader.addEventListener('dragleave', (e) => { uploader.classList.remove('hover'); });
uploader.addEventListener('drop', (e) => {
  e.preventDefault();
  uploader.classList.remove('hover');
  if (e.dataTransfer.files && e.dataTransfer.files[0]) {
    fileInput.files = e.dataTransfer.files;
    onFileSelected();
  }
});

fileInput.addEventListener('change', onFileSelected);

function onFileSelected() {
  selectedFile = fileInput.files[0];
  if (!selectedFile) return;
  prompt.textContent = `Selected: ${selectedFile.name}`;
  enhanceBtn.disabled = false;
  const url = URL.createObjectURL(selectedFile);
  imgBefore.src = url;
  result.classList.add('hidden');
}

enhanceBtn.addEventListener('click', async () => {
  if (!selectedFile) return;
  enhanceBtn.disabled = true;
  enhanceBtn.textContent = 'Enhancing…';
  try {
    const fd = new FormData();
    fd.append('file', selectedFile);
    const res = await fetch('/api/enhance', { method: 'POST', body: fd });
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json();

    imgAfter.onload = () => { result.classList.remove('hidden'); enhanceBtn.textContent = 'Enhance again'; enhanceBtn.disabled = false; };
    imgAfter.src = data.enhanced;
    downloadBtn.href = data.enhanced;
    downloadBtn.download = 'enhanced.png';

    initCompare();
  } catch (err) {
    alert('Enhancement failed: ' + err);
    enhanceBtn.textContent = 'Enhance';
    enhanceBtn.disabled = false;
  }
});

function initCompare() {
  const compare = document.getElementById('compare');
  const downloadBtn = document.getElementById('downloadBtn');
  let isDragging = false;

  function setSplit(clientX) {
    const rect = compare.getBoundingClientRect();
    let x = Math.min(Math.max(clientX - rect.left, 0), rect.width);
    const pct = (x / rect.width) * 100;
    imgAfter.style.clipPath = `inset(0 0 0 ${pct}%)`;
    divider.style.left = pct + '%';
  }

  divider.addEventListener('mousedown', () => { isDragging = true; });
  window.addEventListener('mouseup', () => { isDragging = false; });
  window.addEventListener('mousemove', (e) => { if (isDragging) setSplit(e.clientX); });
  compare.addEventListener('click', (e) => setSplit(e.clientX));
}
JS

# ============================
# Python venv & model
# ============================
echo "[3/8] Creating Python venv & installing deps..."
$PYTHON -m venv .venv
source .venv/bin/activate
pip install --upgrade pip wheel
pip install -r requirements.txt

MODEL_PATH="$APP_DIR/models/EDSR_x4.pb"
if [ ! -f "$MODEL_PATH" ]; then
  echo "[4/8] Downloading EDSR_x4 model..."
  curl -L -o "$MODEL_PATH" \
    https://github.com/Saafke/EDSR_Tensorflow/raw/master/models/EDSR_x4.pb
fi

# ============================
# systemd service
# ============================
echo "[5/8] Configuring systemd service..."
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
sudo bash -c "cat > $SERVICE_FILE" <<SERVICE
[Unit]
Description=Photo Enhancer (CPU) - FastAPI
After=network.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
Environment=MODEL_PATH=$MODEL_PATH
ExecStart=$APP_DIR/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $INTERNAL_PORT --workers 2
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

sudo chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
sudo systemctl daemon-reload
sudo systemctl enable ${APP_NAME}

# ============================
# Nginx reverse proxy on port 80
# ============================
echo "[6/8] Configuring Nginx on port ${PUBLIC_PORT} (server_name ${DOMAIN})..."
NCONF="/etc/nginx/sites-available/${APP_NAME}.conf"
sudo bash -c "cat > $NCONF" <<NGINX
server {
    listen ${PUBLIC_PORT};
    server_name ${DOMAIN};

    client_max_body_size 50M;

    location /static/ {
        alias ${APP_DIR}/static/;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
sudo ln -sf "$NCONF" "/etc/nginx/sites-enabled/${APP_NAME}.conf"
if [ -f /etc/nginx/sites-enabled/default ]; then
  sudo rm -f /etc/nginx/sites-enabled/default
fi
sudo nginx -t

# ============================
# Start / restart services
# ============================
echo "[7/8] Starting services..."
sudo systemctl restart ${APP_NAME}
sudo systemctl restart nginx

# (optional) open firewall if ufw is active
if command -v ufw >/dev/null 2>&1; then
  if sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow ${PUBLIC_PORT}/tcp || true
  fi
fi

echo "[8/8] Done!"
IP=$(hostname -I | awk '{print $1}')
echo "App is live on: http://${IP}:${PUBLIC_PORT}/ (or http://${DOMAIN}:${PUBLIC_PORT}/ if DNS points here)"
