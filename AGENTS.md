# Lemmary Local AI

A macOS menu bar app that serves Lemmary's two local AI endpoints from an Apple
Silicon Mac: bge-m3 embeddings through a bundled `llama-server`, and OCR through
Apple Vision behind a docling-serve-compatible API. It replaces the LaunchAgent
setup in Lemmary's `docs/local_ai_macos.md` and must stay a drop-in for it:
same ports, same model name, same response shapes. A third service, off by
default, serves a small text model through a second `llama-server` for
Lemmary's metadata extraction, reached with Lemmary's OpenAI provider type.

## Layout

- `Sources/LocalAIKit/`: everything decided without a window, Vision or a
  model, and the half with tests. `HTTP/` (a small HTTP/1.1 server on
  Network.framework, the request parser, multipart), `Docling/` (the
  docling-compatible endpoint and media types), `Layout/` (Vision's page layout
  reduced to plain structs, and the markdown renderer), `Worker/` (the worker
  protocol, `PersistentWorker`, `WorkerPool`), `Llama/` (both llama-server
  command lines, the models' URLs and hashes, restart backoff), `LogFile`.
- `Sources/VisionOCR/`: Vision and page rendering. Only the worker links it.
- `Sources/OCRWorker/`: `ocr-worker serve`, the long-lived worker the app
  pools, and `ocr-worker convert <file> <kind>` for trying a file by hand.
- `Sources/LemmaryLocalAI/`: the SwiftUI app. `LlamaService` supervises one
  llama-server (there are two: embeddings and the text model), `OCRService`
  runs the HTTP server and the worker pool, `ModelStore` downloads one model,
  `UI/` the popover and Settings.
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
Lemmary ──POST /v1/chat/completions> llama-server with the text model (optional, same supervision)
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
- **The embeddings flags are measured ones** (`EmbeddingsServerConfig`). `-ub` must be
  at least ~6144 or Lemmary's longest inputs fail; `--pooling cls` and the
  `BAAI/bge-m3` alias are what make the vectors and the model name match TEI and
  Lemmary. See Lemmary's guide for the numbers.
- **llama-server is upstream's release binary, unmodified** except for an added
  rpath to `Contents/Frameworks`. Vectors from the bundled build matched the
  Homebrew build at cosine 1.000000. Changing `LLAMA_BUILD` means re-checking
  that, because a different build's vectors would mean re-embedding Lemmary's
  archive.
- **A llama-server left by a crashed app is reaped** on the next start through
  `llama-server-<port>.pid` in Application Support, and only if its path is
  inside a `LemmaryLocalAI` bundle. Otherwise it holds the port and the new one
  restart-loops. Per port, so a development copy on other ports never reaps
  the installed app's servers.
- **The text model runs with thinking off and no prompt cache in RAM**
  (`TextServerConfig`). Both models think unless the request says otherwise,
  and Lemmary's does not: Gemma 4 E4B went from about 10 s to 30 to 60 s a
  document for the same JSON. llama-server keeps earlier prompts in RAM up to
  8 GB by default, and its memory grew about 180 MB a document; with
  `--cache-ram 0` it stayed flat and the slot still reused the system prompt.
- **The text model is its own llama-server.** One process holds one model, and
  `--embeddings` turns the chat endpoints off. llama-server's router mode
  (`--models-preset`) puts both behind one port but starts a child server per
  model anyway, plus itself.
- **Text model downloads are pinned to a repository commit** (`TextModel`), so
  a re-upload on Hugging Face cannot turn every download into a checksum
  failure. Changing a model means re-running Lemmary's extraction on German and
  Russian documents; the README has what the current two did.
- **Writes to a worker's stdin use `F_SETNOSIGPIPE`.** A worker can die between
  the check and the write; without it the app would die of SIGPIPE.
- **One copy at a time.** A second instance hands over to the first and quits;
  two would fight for the ports. A build running from `.build` is exempt, for
  testing beside the installed app on other ports; it shares the installed
  app's settings, so give it settings on the command line only.
- **The ad-hoc signature in `bundle.sh` is not decoration.** Nested code is
  signed inside out (dylibs, helpers, then the app). `SIGN_IDENTITY` switches to
  a Developer ID with the hardened runtime, which notarization needs.

## Verify

```bash
swift test                              # LocalAIKit with real processes and sockets; VisionOCR with Vision
Scripts/dev.sh --run -EmbeddingsPort 18080 -OCRPort 15001 -TextModelPort 18081 \
  -ModelPath ~/ai/models/bge-m3-f16.gguf -TextModelEnabled YES
curl -s localhost:15001/ready           # 503 while workers warm up, then 200
curl -s -F to_formats=md -F 'files=@some.pdf;type=application/pdf' localhost:15001/v1/convert/file
curl -s localhost:18080/v1/embeddings -H 'Content-Type: application/json' -d '{"model":"BAAI/bge-m3","input":["test"]}'
curl -s localhost:18081/v1/chat/completions -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"Say hi"}]}'
```

`-TextModelPath-gemma-4-e4b <file>` points the text model at a GGUF already on
disk instead of the download.

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
