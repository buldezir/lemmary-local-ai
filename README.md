# Lemmary Local AI

A macOS menu bar app that serves [Lemmary](../lemmary)'s local embeddings and
local OCR from an Apple Silicon Mac, and optionally a small text model for
Lemmary's metadata extraction. It replaces the hand-built setup in Lemmary's
`docs/local_ai_macos.md`: three LaunchAgents, Homebrew's llama.cpp, a 2 GB
Python environment for docling-serve, an ocrmac patch and a watchdog script.

| | Embeddings | OCR | Text model (optional) |
|---|---|---|---|
| Engine | `llama-server` (llama.cpp, Metal), bundled | Apple Vision `RecognizeDocumentsRequest` | a second `llama-server` |
| Model | `BAAI/bge-m3`, F16 GGUF, downloaded and checksummed on first run | built into macOS | Gemma 4 E4B or Ornith 1.5 9B, 4-bit GGUF, downloaded and checksummed when turned on |
| API | OpenAI `/v1/embeddings` | docling-serve's `POST /v1/convert/file` | OpenAI `/v1/chat/completions` |
| Lemmary SDK | Local Embeddings (`local`) | Local OCR (`docling`) | OpenAI (`openai`) with a base URL |
| Default URL | `http://<mac>:8080/v1` | `http://<mac>:5001` | `http://<mac>:8081/v1` |

Lemmary needs no change: the ports, the model name and the API shapes are the
ones its guide already uses, and the text model speaks the API its OpenAI
provider type does.

## Requirements

- Apple Silicon, macOS 26 or newer (Vision's document reader is new in 26).
- About 1.5 GB of memory for embeddings (mostly the model) and 0.1 to 0.3 GB
  per OCR worker. The text model adds 5.4 GB (Gemma 4 E4B) or 6.3 GB
  (Ornith 1.5 9B); with everything on, a 16 GB Mac still had about half its
  memory free.
- To build: Xcode 26 or newer.

## Install

Download `LemmaryLocalAI-macOS-arm64.zip` from the latest
[release](https://github.com/buldezir/lemmary-local-ai/releases), unzip it and
drag `LemmaryLocalAI.app` into Applications before you open it: macOS runs an
app opened where it was downloaded from a temporary copy, which can't update
itself (`xattr -dr com.apple.quarantine /Applications/LemmaryLocalAI.app`
fixes one that says it can't be updated). A release is signed with Developer
ID, notarized, and updates itself: **Check for Updates…** is in the menu bar
panel, and Settings turns the daily checks and automatic installs on and off.
Embeddings, OCR and the text model stop for a few seconds while it updates.

Or build it on the Mac that runs it:

```bash
Scripts/release.sh --install       # builds /Applications/LemmaryLocalAI.app
open /Applications/LemmaryLocalAI.app
```

That build is ad hoc signed for this Mac only, with version 0.1 and the commit
as its build number, and doesn't update itself; installing it over a release
replaces the copy that would have.

The menu bar icon opens a panel with the services, their URLs (with a copy
button for Lemmary's settings) and their state. On first launch it asks for the
embeddings model: **Download** fetches bge-m3 (1.16 GB) and verifies its
SHA-256, or **Use Existing File…** points at a GGUF you already have, such as
`~/ai/models/bge-m3-f16.gguf` from the old setup.

Turn on **Launch at login** in Settings. Like the LaunchAgents it replaces, it
runs in a logged-in session: on a headless Mac, enable automatic login and
never sleep.

### Moving from the LaunchAgent setup

The app uses the same ports, so stop the old services first:

```bash
launchctl bootout gui/$(id -u)/<prefix>.docling-watchdog
launchctl bootout gui/$(id -u)/<prefix>.docling-serve
launchctl bootout gui/$(id -u)/<prefix>.llama-embeddings
```

In Lemmary, leave both providers as they are. Embedding vectors are identical
to the Homebrew llama-server's (same model file, cosine 1.000000), so nothing
needs re-embedding. OCR text comes from Vision instead of docling's layout
models; documents already processed keep their text.

## Settings

| | Default | |
|---|---|---|
| Accept connections from other computers | on | off binds both services to 127.0.0.1 |
| Embeddings / OCR port | 8080 / 5001 | |
| Longest input | 8192 tokens | 6144 uses less memory but fails Lemmary's longest inputs |
| Documents at once | 2 | one warm OCR worker process per document |
| Give up on a page after | 60 s | a page normally takes 0.1 to 0.3 s |
| Serve a text model | off | |
| Text model | Gemma 4 E4B | or Ornith 1.5 9B; see below |
| Text model port | 8081 | |
| Text model context | 16,384 tokens | 32,768 costs 0.3 to 0.6 GB more |

Any setting can be overridden for one run, which is how a second copy runs
beside an installed one:

```bash
Scripts/dev.sh --run -EmbeddingsPort 18080 -OCRPort 15001 -TextModelPort 18081 \
  -ModelPath ~/ai/models/bge-m3-f16.gguf
```

A copy started from `.build` shares the installed app's settings (same bundle
identifier), so change its settings this way, not in its Settings window.

Logs are in `~/Library/Logs/LemmaryLocalAI/`: `llama-server.log`,
`text-model.log`, and `ocr.log` with one line per document.

## Text model

Turn on **Serve a text model** in Settings, pick the model, and press **Apply
and Restart Services**; the menu bar panel then offers the download (5.0 or
5.8 GB, checked against its SHA-256). In Lemmary, add a provider of type
**OpenAI** with:

- base URL: the one the panel shows, e.g. `http://<mac>:8081/v1`
- model: the model name the panel shows, `gemma-4-e4b` or `ornith-1.5-9b`
- API key: anything. Lemmary refuses an empty one; this service checks none.

Use it for extraction (title, date, type, correspondent, tags, suggested tags,
summary) and keep chat and Deep Search on a hosted model: a model this size is
weak at tool use and long conversations.

Both models were run on Lemmary's own extraction prompt and client, on German
and Russian documents up to Lemmary's 24 KB limit, on a Mac mini M4 with 16 GB
next to the embeddings and OCR:

| | Gemma 4 E4B (default) | Ornith 1.5 9B |
|---|---|---|
| A document | 9 to 25 s | 10 to 45 s |
| Memory | 5.4 GB | 6.3 GB |
| Summaries | always in the document's language | in the document's language, with amounts and dates |
| Titles | bare on invoices ("Rechnung") | the most useful ("Stromrechnung Stadtwerke Musterstadt Nr. 2024-4711") |
| Tags | only from the list | once a tag not on the list |
| Fields | every one asked for | sometimes no `suggested_tags` or `references` |

Qwen3.5 4B and 9B and Granite 4.2 8B were tried too and did worse: summaries
in the wrong language, made-up tags, and Granite took up to a minute and 9 GB.
Apple's built-in model costs no memory but does not support Russian.

The service reads one document at a time and queues the rest. Lemmary's
worker sends one at a time and allows 90 s (`AI_TIMEOUT_SEC`); if several
Lemmary instances share this Mac, raise that. While it reads a document,
embeddings slow down (a 64-text batch took 18 s instead of 4; a search query
200 ms instead of 20), and OCR about doubles; nothing fails.

## OCR compared with docling-serve

Measured on a Mac mini M4, warm:

| | docling-serve 1.35 + ocrmac | this app |
|---|---|---|
| One invoice page | 2 to 4 s | 0.2 s |
| 10-page scanned PDF | 6.0 s | 2.1 s |
| Memory | 1.5 to 3.9 GB | 0.1 to 0.3 GB per worker |
| On disk | 2.6 GB | part of macOS |

Text, amounts, IBANs and umlauts came out the same on the test invoices. The
first document of some kinds costs a one-off 12 seconds in each worker while
Vision loads a further model; after that it is 0.2 s.
docling's table model lines up borderless tables better; Vision keeps every
value but sometimes merges or shifts cells. Vision also drops some short
isolated tokens, such as a lone "Q1" in a table's first column. PPTX and XLSX
are refused (Lemmary extracts XLSX itself); DOCX and HTML are converted as text.

## Releases

`.github/workflows/build.yml` builds releases only: a `v*` tag, or a run by
hand. Pushes to `main` and pull requests build nothing. It runs on GitHub's
Apple silicon `xcode-27` runner, builds the app with `Scripts/release.sh`,
uploads it, then runs `swift test --no-parallel`; the release job publishes
only after the tests pass.

- The tag sets the version, and a build number that only grows
  (`0.3.0-beta.2` → 30002, `0.3.0` → 30099), which Sparkle compares;
  `bundle.sh` takes them as `VERSION` and `BUILD`. A local build is version
  `0.1`, with the commit as its build, and doesn't update.
- `bundle.sh` signs every binary in the app (`IDENTITY`) with the Developer ID
  certificate in the repository's secrets (`MACOS_CERTIFICATE_P12_BASE64`,
  `MACOS_CERTIFICATE_PASSWORD`): llama-server and its dylibs, ocr-worker,
  Sparkle's helpers (`Scripts/sign-sparkle.sh`) and the app, with the hardened
  runtime and a secure timestamp. The workflow notarizes it with an App Store
  Connect API key (`NOTARY_API_KEY_BASE64`, `NOTARY_API_KEY_ID`,
  `NOTARY_API_ISSUER_ID`) and staples the ticket. An ad hoc build goes without
  the runtime, whose library validation would stop it loading
  Sparkle.framework.
- `Scripts/appcast.sh` writes the app's Sparkle feed,
  `LemmaryLocalAI-macOS-appcast.xml`: the zip's EdDSA signature
  (`SPARKLE_PRIVATE_KEY`, checked against the app's `SUPublicEDKey`) and the
  release's notes up to its `## Downloads`, if the release is written by then.
  The release job uploads the zip and `SHA256SUMS`, then the feed, which
  `SUFeedURL` reads from the latest release.
- A tag without the secrets fails. A run by hand takes a `version`, such as
  `0.2.0-test.1`, to build an app that offers and takes updates, and a
  `bundle_id`, such as `eu.buldezir.lemmary-local-ai.updatetest`, to keep it
  apart from the installed one.

The app updates itself with Sparkle (`AppUpdater`). `bundle.sh` copies
Sparkle.framework into the app, where the binary finds it through
`@executable_path/../Frameworks`; the helpers it starts never load it.
Sparkle installs only updates signed with the key whose public half is
`SUPublicEDKey` in `Resources/Info.plist`. Its private half is in the login
keychain of the Mac mini that serves Lemmary (account `lemmary-local-ai`) and
belongs in the repository's secrets; keep a backup, since without it the app
can never update again:

```bash
swift build                                  # fetches Sparkle's tools into .build/artifacts
sparkle=.build/artifacts/sparkle/Sparkle/bin
$sparkle/generate_keys --account lemmary-local-ai -p      # prints the public key
$sparkle/generate_keys --account lemmary-local-ai -x private-key
gh secret set SPARKLE_PRIVATE_KEY < private-key && rm private-key
```

## How it works

See [AGENTS.md](AGENTS.md).

## License of bundled components

`llama-server` and its libraries are llama.cpp's, MIT-licensed; the license is
in the app at `Contents/Resources/llama.cpp-LICENSE`.
