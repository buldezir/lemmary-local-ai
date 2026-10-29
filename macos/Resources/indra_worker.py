"""Indra OCR as a Lemmary Local AI OCR worker, for both apps.

    python3 -I indra_worker.py serve --models DIR [--threads N]
    python3 -I indra_worker.py convert FILE KIND --models DIR [--threads N]

`serve` speaks the protocol of `ocr-worker serve` (macos/Sources/LocalAIKit/
Worker/WorkerProtocol.swift): it loads the models, says `ready`, then reads one
request per line on stdin ({"id", "path", "kind"}) and answers each with
`progress` lines and one `result` line on stdout. It exits when stdin closes.
`convert` reads one file and prints its result, for trying things by hand.

The same file is linux/indra_worker.py and macos/Resources/indra_worker.py;
keep the two identical (a test in linux/ checks).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

# The protocol owns stdout. Anything a library prints goes to stderr, which the
# apps log, instead of corrupting a message.
_protocol = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr


def send(message):
    _protocol.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")


def log(line):
    print(line, file=sys.stderr, flush=True)


class Unreadable(Exception):
    """The document itself cannot be read: answered as a failed conversion."""


def load(models, threads):
    import indra_ocr

    # auto reads a PDF's text layer where it passes Indra's checks: exact and
    # fast for born-digital PDFs, and OCR for scans and the pages that fail
    # them. Headers and footers are kept, as Vision keeps them, since
    # Lemmary's extraction reads bank details and registry numbers there.
    return indra_ocr.load(path=models, threads=threads, mode="auto", furniture=True, math=False)


def warm_up(converter):
    """One small line of text through detection and recognition, so the first
    document does not pay for ONNX Runtime's first runs."""
    import cv2
    import numpy as np

    image = np.full((96, 640), 255, np.uint8)
    cv2.putText(image, "Lemmary 2024", (20, 64), cv2.FONT_HERSHEY_SIMPLEX, 1.6, 0, 3)
    converter.ocr(image)


def page_count(path):
    import pypdfium2 as pdfium

    try:
        doc = pdfium.PdfDocument(path)
    except pdfium.PdfiumError as e:
        raise Unreadable("the PDF is password-protected" if "password" in str(e).lower() else "not a readable PDF") from e
    try:
        return len(doc)
    finally:
        doc.close()


def readable_image(path, scratch):
    """The image as OpenCV can read it, which is how Indra reads images.

    Transparent areas go on white, as the Mac's Vision path puts them; read
    straight to grey they would come out black. Formats OpenCV does not decode
    (HEIC, AVIF, GIF) are converted to PNG first by the system's converter:
    sips on macOS, ImageMagick on Linux."""
    import cv2
    import numpy as np

    image = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if image is None:
        converted = os.path.join(scratch, "converted.png")
        if sys.platform == "darwin":
            command = ["/usr/bin/sips", "-s", "format", "png", path, "--out", converted]
        else:
            tool = shutil.which("magick") or shutil.which("convert")
            if tool is None:
                raise Unreadable("cannot read this image format")
            command = [tool, path + "[0]", converted]
        if subprocess.run(command, capture_output=True).returncode != 0 or not os.path.exists(converted):
            raise Unreadable("cannot read this image format")
        path = converted
        image = cv2.imread(path, cv2.IMREAD_UNCHANGED)
        if image is None:
            raise Unreadable("cannot read this image format")
    if image.ndim == 3 and image.shape[2] == 4:
        alpha = image[..., 3:4].astype(np.float32) / (255.0 if image.dtype == np.uint8 else 65535.0)
        colour = image[..., :3].astype(np.float32)
        white = 255.0 if image.dtype == np.uint8 else 65535.0
        flat = (colour * alpha + white * (1 - alpha)).astype(image.dtype)
        path = os.path.join(scratch, "flattened.png")
        cv2.imwrite(path, flat)
    return path


def read(converter, path, kind, progress):
    if kind == "text":
        with open(path, "rb") as f:
            return {"markdown": f.read().decode("utf-8", errors="replace"), "pages": 1}
    if kind not in ("pdf", "image"):
        raise Unreadable(f"indra-ocr reads PDFs and images, not {kind}")
    with tempfile.TemporaryDirectory(prefix="indra-") as scratch:
        if kind == "pdf":
            total = page_count(path)
        else:
            path, total = readable_image(path, scratch), 1
        progress(0, total)
        texts, pages, errors = [], 0, []
        try:
            for _, page in converter.convert(path):
                pages += 1
                if page.source == "error":
                    errors.append(page.note)
                    log(f"page {pages}: {page.note}")
                elif page.markdown.strip():
                    texts.append(page.markdown.strip())
                progress(pages, max(total, pages))
        except Exception as e:  # noqa: BLE001  (Indra's InputError: a file it cannot open)
            raise Unreadable(str(e).split(": ", 1)[-1]) from e
        if pages and len(errors) == pages:
            raise Unreadable(f"Indra could not read the document: {errors[0]}")
        return {"markdown": "\n\n".join(texts), "pages": pages}


def answer(converter, path, kind, progress):
    try:
        return read(converter, path, kind, progress)
    except Unreadable as e:
        return {"error": str(e), "pages": 0}
    except Exception as e:  # noqa: BLE001  (anything else fails this document, not the worker)
        return {"error": f"Indra could not read the document: {type(e).__name__}: {e}", "pages": 0}


def serve(converter):
    try:
        warm_up(converter)
        send({"event": "ready"})
    except Exception as e:  # noqa: BLE001
        send({"event": "ready", "error": f"warm-up: {type(e).__name__}: {e}"})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            rid, path, kind = request["id"], request["path"], request["kind"]
        except (ValueError, KeyError, TypeError):
            log(f"unreadable request: {line[:200]}")
            continue

        def progress(page, total):
            send({"event": "progress", "id": rid, "page": page, "total": total})

        send({"event": "result", "id": rid, "result": answer(converter, path, kind, progress)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["serve", "convert"])
    parser.add_argument("file", nargs="?")
    parser.add_argument("kind", nargs="?")
    parser.add_argument("--models", required=True)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    converter = load(args.models, max(1, args.threads))
    if args.command == "serve":
        serve(converter)
    elif args.file and args.kind:
        result = answer(converter, args.file, args.kind, lambda page, total: log(f"page {page} of {total}"))
        _protocol.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    else:
        parser.error("convert needs FILE and KIND")


if __name__ == "__main__":
    main()
