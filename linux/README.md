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

## Build

```bash
docker build -t lemmary-local-ai linux/
cd linux && go test ./...    # the OCR tests need pdftoppm and ImageMagick
```
