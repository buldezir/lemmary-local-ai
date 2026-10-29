# Lemmary Local AI for Linux

The Linux counterpart of the macOS app, for an NVIDIA GPU: the same API on one
port, 5001, so Lemmary's **Lemmary Local AI** provider type works against
either. Embeddings (`BAAI/bge-m3`) and OCR (`lightonocr-2`) always run; a text
model for metadata extraction runs when chosen. Each is a llama-server from
llama.cpp's release `b11936` on loopback, started, health-checked and
restarted by this program; models download on first start and are checked by
SHA-256.

```bash
docker run --gpus all -p 5001:5001 -v lemmary-local-ai:/data \
  ghcr.io/buldezir/lemmary-local-ai:linux-draft -text-model gemma-4-e4b
curl -s localhost:5001/ready     # 503 while models download and load
```

In Lemmary, add a provider of type **Lemmary Local AI** with base URL
`http://<host>:5001/v1`. Its pickers list `BAAI/bge-m3` for embeddings,
`lightonocr-2` for OCR and the text model for General AI; an OCR model left
blank also works (the app answers to the Mac's `apple-vision-ocr`).

## Settings

Settings are flags, given after the image name with `docker run`, as
`command:` in Compose, or on the `ExecStart` line of the systemd unit below.
Change one by restarting with the new flags.

| Flag | Default | |
|---|---|---|
| `-text-model` | `off` | serve a text model, and which: one of the [text models](#text-models) the GPU has room for; a larger one is refused at start |
| `-text-context` | 16384 | the text model's context in tokens |
| `-addr` | `:5001` | the one port, on every interface; `127.0.0.1:5001` keeps it to this machine |
| `-ocr-parallel` | 2 | pages OCR reads at once, of one document or several; each takes 0.9 GB of VRAM |
| `-page-timeout` | `2m` | give up on a page after this long |
| `-data` | `~/.local/share/lemmary-local-ai`, `/data` in the image | where models download and llama-server logs go |
| `-vram-gb` | from `nvidia-smi` | the GPU's memory in GB, if `nvidia-smi` cannot tell |
| `-llama-server` | beside this program, else on `PATH` | the llama-server to run |

The embeddings context is fixed at bge-m3's 8192 tokens, the Mac's default:
the memory that 6144 would save does not matter on a GPU.

```yaml
services:
  local-ai:
    image: ghcr.io/buldezir/lemmary-local-ai:latest
    command: ["-text-model", "gemma-4-26b-a4b"]
    ports: ["5001:5001"]
    volumes: ["local-ai:/data"]
    restart: unless-stopped
    deploy:
      resources:
        reservations:
          devices: [{driver: nvidia, count: all, capabilities: [gpu]}]
volumes:
  local-ai:
```

## OCR

LightOnOCR-2 1B reads each page, rendered at 2000 px (`pdftoppm` for PDFs,
ImageMagick for images), two pages at a time. Of the five OCR models llama.cpp
serves, run through this app on 22 German, English and Russian documents, born
digital and as degraded scans, scored against their text layer:

| | Words kept, digital / scans | s a page | VRAM with embeddings |
|---|---|---|---|
| **LightOnOCR-2 1B** | **100% / 100%** | 3.6 | 5.2 GB |
| PaddleOCR-VL 1.6 | 99% / 97%, looped on a scanned table | 1.5 to 2.3 | 3.8 GB |
| HunyuanOCR | 94% / 93%, no headers or footers | 3.0 | 5.1 GB |
| dots.ocr | 92% / 89% | 4.0 | 6.2 GB |
| GLM-OCR | 90% / 93%, no letterheads | 2.0 | 4.8 GB |

On an RTX 5000 Ada. A page that runs past 4096 tokens has its repeated lines
dropped. Lemmary's OCR timeout (`OCR_TIMEOUT_SEC`, 90 s) covers about 25 pages
at this speed; raise it for longer documents.

## Text models

By the GPU's memory (`nvidia-smi`, or `-vram-gb`). VRAM is the peak of
everything together under load; extraction is Lemmary's own extractor on four
German, Russian and English documents, alone and while OCR and embeddings ran:

| Model | GPU | VRAM | A document | Under load |
|---|---|---|---|---|
| `gemma-4-e4b` | 16 GB | 8.9 GB | 1.8 to 2.1 s | 3.8 to 4.2 s |
| `ornith-1.5-9b` | 16 GB | 11.1 GB | 2.4 to 2.9 s | 4.6 to 5.7 s; English summaries |
| `gemma-4-12b` | 16 GB | 12.8 GB | 3.2 to 4.0 s | 5.9 to 7.3 s |
| `gemma-4-26b-a4b` | 24 GB | 19.9 GB | 1.8 to 1.9 s | 3.4 to 3.9 s |
| `qwen3.6-35b-a3b` | 24 GB | 22.5 GB | 1.8 to 2.2 s | 3.6 to 4.8 s; made-up tags |

Thinking is off and streamed answers pass through as they are generated.

`lemmary-local-ai -h` lists every flag. llama-server logs are in `/data/logs`.

## Without Docker

It needs a distribution with glibc 2.38 or newer, such as Ubuntu 24.04 or
Debian 13: llama.cpp's release build does not start on Ubuntu 22.04 or
Debian 12, so use the image there. Also the NVIDIA driver, 570 or newer, with
`nvidia-smi`, and Go 1.27 or newer to build.

```bash
sudo apt install ca-certificates libgomp1 libssl3 poppler-utils imagemagick

# llama.cpp's build b11936 for CUDA 12.8, the one the image pins
mkdir -p ~/lemmary-local-ai && cd ~/lemmary-local-ai
B=https://github.com/ggml-org/llama.cpp/releases/download/b11936
curl -fLO $B/llama-b11936-bin-ubuntu-cuda-12.8-x64.tar.gz
curl -fLO $B/cudart-llama-b11936-bin-ubuntu-cuda-12.8-x64.tar.gz
sha256sum -c <<'EOF'
8c87c0623f7eba2056b13cec093f464365d0bb7e05f60beff9a09accdd5f9b49  llama-b11936-bin-ubuntu-cuda-12.8-x64.tar.gz
30193f90b2317d6f0ef9e1f87498a0e0863769e975af7b66637d795eb4d89bb5  cudart-llama-b11936-bin-ubuntu-cuda-12.8-x64.tar.gz
EOF
for f in *.tar.gz; do tar xzf "$f" --strip-components=1 && rm "$f"; done

# This program, beside llama-server, which is where it looks for it
git clone https://github.com/buldezir/lemmary-local-ai /tmp/lemmary-local-ai
CGO_ENABLED=0 go build -C /tmp/lemmary-local-ai/linux -o ~/lemmary-local-ai/lemmary-local-ai .

~/lemmary-local-ai/lemmary-local-ai -text-model gemma-4-e4b
```

Models and llama-server logs go to `~/.local/share/lemmary-local-ai`
(`-data` changes it); `-llama-server` names a llama-server elsewhere.

To keep it running, as a systemd service in `/opt/lemmary-local-ai`, with
its models in `/var/lib/lemmary-local-ai`:

```bash
sudo mv ~/lemmary-local-ai /opt/
sudo tee /etc/systemd/system/lemmary-local-ai.service <<'EOF'
[Unit]
Description=Lemmary Local AI
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/opt/lemmary-local-ai/lemmary-local-ai -data /var/lib/lemmary-local-ai -text-model gemma-4-e4b
DynamicUser=yes
StateDirectory=lemmary-local-ai
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now lemmary-local-ai
journalctl -u lemmary-local-ai -f
```

## Build and test

```bash
docker build -t lemmary-local-ai linux/
cd linux && go test ./...    # the OCR tests need pdftoppm and ImageMagick
```
