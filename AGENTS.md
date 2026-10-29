# Lemmary Local AI

Two apps serving the same API: the macOS app in `macos/` and its Linux
counterpart in `linux/` (see its README). Everything below is the macOS app's,
with paths relative to `macos/`, unless it names `linux/` or the repository
root.

`macos/` is a menu bar app that serves Lemmary's local AI from an Apple Silicon Mac,
all on one port so Lemmary needs one provider of its OpenAI type: bge-m3
embeddings through a bundled `llama-server`, OCR through Apple Vision or
Indra OCR as OpenAI chat models (`apple-vision-ocr`, `indra-ocr`) and behind a
docling-serve-compatible API, and, off by default, a small text model through a second `llama-server`
for Lemmary's metadata extraction. It replaces the LaunchAgent setup in
Lemmary's `docs/local_ai_macos.md`: same docling port (5001), embeddings model
name and response shapes, so Lemmary's `local` and `docling` provider types
still work against it.

## Layout

- `Sources/LocalAIKit/`: everything decided without a window, Vision or a
  model, and the half with tests. `HTTP/` (a small HTTP/1.1 server on
  Network.framework, the request parser, multipart), `API/` (the one port's
  router, OCR as a chat model, the proxy to the llama-servers), `Docling/` (the
  docling-compatible endpoint and media types), `Layout/` (Vision's page layout
  reduced to plain structs, and the markdown renderer), `Worker/` (the worker
  protocol, `PersistentWorker`, `WorkerPool`), `OCR/` (the two OCR models,
  `OCRSwitch`, which keeps one in memory, and `IndraRuntime`: Indra's pinned
  Python, packages and models and their install), `Llama/` (both llama-server
  command lines, the models' URLs and hashes, restart backoff), `LogFile`.
- `Sources/VisionOCR/`: Vision and page rendering. Only the worker links it.
- `Sources/OCRWorker/`: `ocr-worker serve`, the long-lived worker the app
  pools, and `ocr-worker convert <file> <kind>` for trying a file by hand.
- `Sources/LemmaryLocalAI/`: the SwiftUI app. `APIService` runs the one port,
  `LlamaService` supervises one llama-server (there are two: embeddings and the
  text model), `OCRService` the OCR switch and Indra's download, `ModelStore`
  downloads one model, `UI/` the popover and Settings.
- `Resources/indra_worker.py`: Indra's worker, speaking `ocr-worker serve`'s
  protocol; the same file as `linux/indra_worker.py` (a Go test checks).
- `Scripts/fetch-llama.sh` pins the upstream llama.cpp build by tag and
  SHA-256; `bundle.sh` assembles and signs the `.app`; `dev.sh` / `release.sh`
  drive it. `appcast.sh` and `sign-sparkle.sh` are the same files as in the
  other Sparkle apps (proxmacs, zonetab, Herdglass); keep them in step.
  `Scripts/appicon.swift` draws `Resources/LemmaryLocalAI.icns` (checked in;
  run it only to change the design).
- `.github/workflows/build.yml`, at the repository root, builds, signs,
  notarizes and publishes a release for a `v*` tag; README's Releases section
  has the details and the secrets it needs. Its `linux` job adds the Linux
  binary to the release and pushes the Linux image to GHCR.
- `linux/`, at the repository root: the Linux counterpart for an NVIDIA GPU, a
  Go program with no dependencies serving the same API on one port:
  llama-servers for bge-m3, OCR with LightOnOCR-2 (pages rendered by
  `pdftoppm` and ImageMagick) and the optional text model, offered by VRAM
  tier, and Indra OCR in Python workers (`indra.go` the runtime, `worker.go`
  the protocol and pool, `ocrswitch.go` one OCR model in memory). Without a
  GPU it serves the embeddings and Indra, on the CPU: LightOnOCR there took
  minutes a page. Its Dockerfile pins the same llama.cpp build for CUDA; its
  README has the measurements. Verify with `go test ./...` in `linux/`, which
  runs on a Mac too.

## Architecture

```
Lemmary ──:5001──> HTTPServer (in the app) ── APIRouter
                     │
                     ├ GET /v1/models: bge-m3, apple-vision-ocr, indra-ocr, the text model
                     ├ POST /v1/chat/completions, an OCR model ─────────────┐ OCRChatEndpoint: data URL parts
                     ├ POST /v1/convert/file, ocr_engine ───────────────────┤ DoclingEndpoint: multipart
                     │                                                      ▼ media type, temp file
                     │       OCRSwitch: one model in memory, the last used ── PoolConverter ── checkout ──> WorkerPool
                     │                                             │ N × `ocr-worker serve` (Vision)
                     │                                             │   or `python3 -I indra_worker.py serve` (Indra)
                     │                request line on stdin ──────>│ one page at a time
                     │                progress/result lines <──────│
                     ├ POST /v1/embeddings ─────── UpstreamProxy ──> llama-server on 127.0.0.1:<free port>
                     └ POST /v1/chat/completions, any other model ─> llama-server with the text model (optional)
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
  the user. Worker stalls are 504, crashes 500. The OCR chat model answers the
  same failure with 422 and OpenAI's error shape, never 400: Lemmary takes a
  400 that mentions a file as a model refusing PDFs and sends the pages again
  as images.
- **One port, and the llama-servers on loopback.** Lemmary's OpenAI provider
  type is the only one that serves embeddings, OCR and chat, so everything is
  reachable through it at one base URL; OCR is a chat model because that is
  how the type reads a document (`internal/ocr/llm.go`). `/v1/models` says
  what each model is for, as `purposes` in Lemmary's own words
  (`aiprovider.ModelPurpose`: `llm`, `ocr`, `embedding`) and as Mistral's
  `capabilities` object, which Lemmary already parses. Until Lemmary reads them
  for its OpenAI type it guesses: a model is offered for embeddings only if its
  id or name contains "embed", hence bge-m3's name. The llama-servers listen
  on free loopback ports chosen at each start, and only the router talks to
  them.
- **A streamed completion is passed on as it arrives** (`UpstreamProxy`,
  `StreamingFetch`), chunked. Nothing holds llama-server back for a slow
  client: what it sends waits in the stream between the two, which for tokens
  is little. A client that hangs up ends the stream, which cancels the upstream
  request, and llama-server stops generating ("stop: cancel task" in its log).
  `StreamingFetch` keeps only the stream's writing end: the session holds it
  until the request ends, and holding the reading end too would keep the
  stream alive after the client left, so generation would run on.
- **Every HTTP response closes its connection** and request bodies need a
  `Content-Length`; chunked uploads get 411. Responses have a
  `Content-Length`, except a stream, which is chunked so a client can tell a
  finished stream from a cut one. Lemmary's Go client, curl -F and
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
  `llama-server-<port>-<role>.pid` in Application Support, and only if its path
  is inside a `LemmaryLocalAI` bundle. Otherwise it keeps its model in memory,
  up to 19 GB, beside the new one. Keyed by the app's port, so a development
  copy on another port never reaps the installed app's servers.
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
  Russian documents; the README has what the current five did. Settings offers
  the larger ones by the Mac's memory (`TextModel.minimumMemoryGB`: 24 GB for
  Gemma 4 12B and 26B-A4B, 32 GB for Qwen3.6 35B-A3B), sized from what each
  took beside the embeddings and OCR plus about 5 GB for macOS.
- **One OCR model in memory, the one used last** (`OCRSwitch`, and
  `ocrswitch.go` on Linux). Each worker holds its model, 0.4 to 0.6 GB, and
  Lemmary binds one OCR model. A request for the other waits for the requests
  in flight, then its pool replaces the running one; while it waits, later
  requests for the model in memory queue behind it, so neither starves the
  other. A model that cannot start (Indra still downloading) refuses its
  requests with 503 and leaves the running one loaded. A request naming no
  model (a docling client without `ocr_engine`, or `apple-vision-ocr` on
  Linux) gets the model used last, or Vision for Word and HTML, which Indra
  does not read. The last model is kept across launches (`OCRModel`; on Linux
  `ocr-model` in the data directory). One worker by default.
- **Indra's runtime is downloaded, not bundled** (`IndraRuntime`,
  `linux/indra.go`): python-build-standalone and five wheels unpacked straight
  into its site-packages, and the models of the tag v1.1.0, each pinned by
  SHA-256, into Application Support or the data directory. Bundled, it would
  add about 100 MB to the app and to every Sparkle update. Nothing else is
  installed: onnxruntime's declared dependencies are for its tools, and
  huggingface_hub only downloads. The two apps pin the same versions; change
  them together, and the runtime id with them, so an old runtime is replaced.
  The worker runs Python with `-I`, so no Python of the user's leaks in.
- **`indra_worker.py` owns its stdout**: it moves fd 1 to stderr at start and
  keeps a private copy for the protocol, so anything Indra, ONNX Runtime or
  OpenCV prints cannot corrupt a message.
- **`HF_TOKEN` goes to huggingface.co only** (`linux/catalog.go`): Indra's
  runtime downloads from GitHub and PyPI.
- **A copy running from `.build` does not save the OCR model it loads**: it
  shares the installed app's settings.
- **Writes to a worker's stdin use `F_SETNOSIGPIPE`.** A worker can die between
  the check and the write; without it the app would die of SIGPIPE.
- **One copy at a time.** A second instance hands over to the first and quits;
  two would fight for the port. A build running from `.build` is exempt, for
  testing beside the installed app on another port; it shares the installed
  app's settings, so give it settings on the command line only, and do not
  open its Settings window: the port field writes its value back when the
  window closes.
- **The ad-hoc signature in `bundle.sh` is not decoration.** Nested code is
  signed inside out (dylibs, helpers, Sparkle's helpers, then the app).
  `IDENTITY` switches to a Developer ID with the hardened runtime, which
  notarization needs; an ad hoc build must stay without the runtime, or library
  validation stops it loading Sparkle.framework.
- **Only a release updates itself** (`AppUpdater.isRelease`): its version is
  X.Y.Z from a tag. A local build is `0.1` and never starts Sparkle, so a
  development copy cannot replace the installed app. An update quits the app,
  which stops every service until the new version has started them, a few
  seconds. `SUPublicEDKey` must stay the public half of the key in the
  repository's `SPARKLE_PRIVATE_KEY`; `appcast.sh` refuses a mismatch, since a
  release signed with another key could never update again.

## Verify

```bash
cd macos
swift test                              # LocalAIKit with real processes and sockets; VisionOCR with Vision
Scripts/dev.sh --run -Port 18080 -ModelPath ~/ai/models/bge-m3-f16.gguf -TextModelEnabled YES
curl -s localhost:18080/ready           # 503 while OCR workers warm up, then 200
curl -s localhost:18080/v1/models
curl -s -F to_formats=md -F 'files=@some.pdf;type=application/pdf' localhost:18080/v1/convert/file
curl -s localhost:18080/v1/chat/completions -H 'Content-Type: application/json' -d "{\"model\":\"apple-vision-ocr\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"file\":{\"file_data\":\"data:application/pdf;base64,$(base64 -i some.pdf)\"}}]}]}"
curl -s -F to_formats=md -F ocr_engine=indra-ocr -F 'files=@some.pdf;type=application/pdf' localhost:18080/v1/convert/file   # switches to Indra
curl -s localhost:18080/v1/embeddings -H 'Content-Type: application/json' -d '{"model":"BAAI/bge-m3","input":["test"]}'
curl -s localhost:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"gemma-4-e4b","messages":[{"role":"user","content":"Say hi"}]}'
```

Lemmary's own clients are the real test: with its repository checked out, a
small Go program under `backend/cmd/` can call `aiprovider.ListModels`,
`ai.NewEmbedder`, `ocr.NewFromAIProvider` and `ai.NewExtractor` against
`http://127.0.0.1:18080/v1` (and `ocr.NewDoclingProvider` without `/v1`).

`-TextModelPath-gemma-4-e4b <file>` points the text model at a GGUF already on
disk instead of the download.

Indra's real download, unpacking and worker have a test each, off by default:
`INDRA_LIVE=1 swift test --filter indraInstallsAndReads` in `macos/`, and
`INDRA_LIVE=1 go test -run TestIndraLive` in `linux/` (the Mac's files on a
Mac, Linux's on Linux; `INDRA_DATA` keeps the download).

On the Mac mini, SwiftPM can stall for good on a keychain prompt nobody sees
when it downloads Sparkle's binary; `swift package --disable-keychain resolve`
fetches it without asking the keychain, and later builds use that copy.

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

## Screenshots

`docs/*.png` in the README are window captures (`screencapture -l <window id>`)
of a copy run from outside `.build`, so Settings has no development caption,
with `-AppleLocale en_US`, on the default port and with the models in
Application Support, after one request to each service so the panel shows real
figures. Settings is cut to whole sections, without the footer and its version.

## Icon

`Scripts/appicon.swift` draws it: Lemmary's cream block "L" on its oxblood
(the web app's favicon colours) inside viewfinder corners, the same idea as the
menu bar symbol, `text.viewfinder`. The plate follows Apple's template, an
824-point squircle on the 1024 canvas. Below 32 px the corners are left out and
the L drawn larger, because at 16 px they blurred into it. Shadow blur is
scaled by hand, since Core Graphics does not scale it with the context.
