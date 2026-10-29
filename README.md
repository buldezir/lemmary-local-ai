# Lemmary Local AI

Serves [Lemmary](https://github.com/buldezir/lemmary)'s local AI on your own
hardware, all on one port: bge-m3 embeddings, OCR, and optionally a text model
for metadata extraction. Lemmary reaches it as one provider of its **Lemmary
Local AI** type, and documents never leave your network.

| | Runs on | OCR |
|---|---|---|
| [**macOS**](macos/README.md) | a menu bar app for Apple Silicon, signed and self-updating; [download](https://github.com/buldezir/lemmary-local-ai/releases/latest) | Apple Vision |
| [**Linux**](linux/README.md) | a command or Docker image for an NVIDIA GPU; 16 GB or more for a text model; embeddings alone without a GPU | LightOnOCR-2 |

Both answer the same API and serve the same embeddings model, so Lemmary can
move between them without re-embedding its archive.
