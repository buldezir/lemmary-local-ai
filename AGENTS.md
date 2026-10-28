# Lemmary Local AI

A macOS menu bar app that serves Lemmary's two local AI endpoints from an Apple
Silicon Mac: bge-m3 embeddings through a bundled `llama-server`, and OCR through
Apple Vision behind a docling-serve-compatible API. It replaces the LaunchAgent
setup in Lemmary's `docs/local_ai_macos.md` and must stay a drop-in for it:
same ports, same model name, same response shapes.

## Layout

- `Sources/LocalAIKit/`: everything decided without a window, Vision or a
  model, and the half with tests. `HTTP/` (a small HTTP/1.1 server on
  Network.framework, the request parser, multipart), `Docling/` (the
  docling-compatible endpoint and media types), `Layout/` (Vision's page layout
  reduced to plain structs, and the markdown renderer), `Worker/` (the worker
  protocol, `PersistentWorker`, `WorkerPool`), `Embeddings/` (the llama-server
  command line, the model's URL and hash, restart backoff), `LogFile`.
- `Sources/VisionOCR/`: Vision and page rendering. Only the worker links it.
- `Sources/OCRWorker/`: `ocr-worker serve`, the long-lived worker the app
  pools, and `ocr-worker convert <file> <kind>` for trying a file by hand.
- `Sources/LemmaryLocalAI/`: the SwiftUI app. `EmbeddingsService` supervises
  llama-server, `OCRService` runs the HTTP server and the worker pool,
  `ModelStore` downloads the model, `UI/` the popover and Settings.
- `Scripts/fetch-llama.sh` pins the upstream llama.cpp build by tag and
  SHA-256; `bundle.sh` assembles and signs the `.app`; `dev.sh` / `release.sh`
  drive it. `Scripts/appicon.swift` draws `Resources/LemmaryLocalAI.icns`
  (checked in; run it only to change the design).

## Architecture

```
Lemmary ──POST /v1/convert/file──> HTTPServer (in the app)
                                     │ DoclingEndpoint: multipart, media type, temp file
                                     ▼
                                   PoolConverter ── checkout ──> WorkerPool
                                                                  │ N × `ocr-worker serve`
                                     request line on stdin ──────>│ Vision, one page at a time
                                     progress/result lines <──────│
Lemmary ──POST /v1/embeddings────> llama-server (child process, restarted with backoff)
```

## Constraints agents should not re-break

- **Vision runs in workers, never in the app.** On macOS 27.0 and 27.0.1 Vision
  can accept a recognition and never answer, at 0% CPU, with nothing logged. In
  the app that would be a request that never returns and a server slot gone for
  good. In a worker it is a request whose progress stops: `PersistentWorker`
  kills the process after `stallTimeout` without a page finishing,
  `PoolConverter` retries the document once on another worker, and the pool
  starts a replacement. This is what replaced docling's log-scraping watchdog.
- **Workers are long-lived.** macOS unloads Vision's models as soon as no
  process holds them; reloading took 25 to 37 seconds. A process per document
  paid that on nearly every upload. A worker loads once, warms up, and still
  answered in 0.2 s after five idle minutes.
- **Language correction stays off.** With it on, explicit languages and the
  accurate recognizer, Vision hung after 404 calls in a stress test; with it
  off, more than 14,000 calls ran clean across both language modes. It also
  changed nothing in the test documents' text. Languages are detected
  automatically, which read German, Russian and English on one page correctly.
- **`minimumTextHeightFraction` stays at Vision's default.** Lower values recover
  short isolated tokens ("Q1", position numbers) but every value tried also
  stopped lists being detected.
- **Pages reach Vision as one bitmap format** (8-bit sRGB, no alpha;
  `CanonicalBitmap`), whatever the file was. Transparent areas become white.
- **Reading order comes from Vision's paragraph order**, which follows columns.
  Tables and lists are slotted into it (`MarkdownRenderer.insertionIndex`);
  sorting blocks by height interleaves the lines of a two-column page.
- **A document-level failure is HTTP 200 with `status: failure` and an
  `errors` entry**, as docling answers it. Lemmary reads `errors` when
  `md_content` is empty, which is how "the PDF is password-protected" reaches
  the user. Worker stalls are 504, crashes 500.
- **Every HTTP response closes its connection** and request bodies need a
  `Content-Length`; chunked uploads get 411. Lemmary's Go client, curl -F and
  Python requests all send a length. `Expect: 100-continue` is answered, or
  curl waits a second before every upload.
- **The embeddings flags are measured ones** (`LlamaServerConfig`). `-ub` must be
  at least ~6144 or Lemmary's longest inputs fail; `--pooling cls` and the
  `BAAI/bge-m3` alias are what make the vectors and the model name match TEI and
  Lemmary. See Lemmary's guide for the numbers.
- **llama-server is upstream's release binary, unmodified** except for an added
  rpath to `Contents/Frameworks`. Vectors from the bundled build matched the
  Homebrew build at cosine 1.000000. Changing `LLAMA_BUILD` means re-checking
  that, because a different build's vectors would mean re-embedding Lemmary's
  archive.
- **A llama-server left by a crashed app is reaped** on the next start through
  `llama-server.pid` in Application Support, and only if its path is inside a
  `LemmaryLocalAI` bundle. Otherwise it holds the port and the new one
  restart-loops.
- **Writes to a worker's stdin use `F_SETNOSIGPIPE`.** A worker can die between
  the check and the write; without it the app would die of SIGPIPE.
- **One copy at a time.** A second instance hands over to the first and quits;
  two would fight for both ports.
- **The ad-hoc signature in `bundle.sh` is not decoration.** Nested code is
  signed inside out (dylibs, helpers, then the app). `SIGN_IDENTITY` switches to
  a Developer ID with the hardened runtime, which notarization needs.

## Verify

```bash
swift test                              # LocalAIKit with real processes and sockets; VisionOCR with Vision
Scripts/dev.sh --run -EmbeddingsPort 18080 -OCRPort 15001 -ModelPath ~/ai/models/bge-m3-f16.gguf
curl -s localhost:15001/ready           # 503 while workers warm up, then 200
curl -s -F to_formats=md -F 'files=@some.pdf;type=application/pdf' localhost:15001/v1/convert/file
curl -s localhost:18080/v1/embeddings -H 'Content-Type: application/json' -d '{"model":"BAAI/bge-m3","input":["test"]}'
```

The first conversion after a worker starts can take about 12 seconds once
while Vision loads a model the warm-up page did not touch; the default page
limit of 60 s allows for it. Test with a lower `-PageTimeout` only after a
document of the same kind has gone through.

## Not built yet

- **Authentication.** Neither service checks a key, the same as the setup it
  replaces. llama-server takes `--api-key-file`; the OCR endpoint would check
  `X-Api-Key`, which Lemmary's docling client already sends when one is set.
- **PDF text layers.** Born-digital PDFs are rendered and recognized like scans.
  Reading their text layer would be faster and exact.
- **Launch-at-login as a LaunchAgent** (`SMAppService.agent`) for restart after
  a crash. Today a crashed app stays down until the next login.

## Icon

`Scripts/appicon.swift` draws it: Lemmary's cream block "L" on its oxblood
(the web app's favicon colours) inside viewfinder corners, the same idea as the
menu bar symbol, `text.viewfinder`. The plate follows Apple's template, an
824-point squircle on the 1024 canvas. Below 32 px the corners are left out and
the L drawn larger, because at 16 px they blurred into it. Shadow blur is
scaled by hand, since Core Graphics does not scale it with the context.
