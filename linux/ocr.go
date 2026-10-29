package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// appleVisionOCR is the Mac app's OCR model, which Lemmary uses when a
// lemmary_local_ai provider's OCR model is left blank.
const appleVisionOCR = "apple-vision-ocr"

// pageEdge is the longest side a page is rendered at, the same as Lemmary's
// for a vision model (ocr.llmOCRPageEdge).
const pageEdge = 2000

// maxPageTokens ends a page whose model keeps repeating itself; a dense page
// of text is about 1500.
const maxPageTokens = 4096

// statusError is a failure with the HTTP status it is answered with.
type statusError struct {
	status  int
	message string
}

func (e *statusError) Error() string { return e.message }

// ocrChat answers a chat completion whose user message carries documents, the
// way Lemmary's OpenAI client reads one: a file part for a PDF, an image_url
// part for an image, each a base64 data URL. The prompt is not read. model is
// the OCR model to read them with, which is put in memory first.
func (a *app) ocrChat(w http.ResponseWriter, r *http.Request, body []byte, model string) {
	start := time.Now()
	docs, err := attachments(body)
	if err != nil {
		openAIError(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(docs) == 0 {
		openAIError(w, http.StatusBadRequest, model+" reads documents: send a PDF or an image as a content part of the user message")
		return
	}
	release, err := a.ocrs.acquire(r.Context(), model)
	if err != nil {
		fail(w, err)
		return
	}
	defer release()
	dir, err := os.MkdirTemp("", "lemmary-ocr-")
	if err != nil {
		openAIError(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer os.RemoveAll(dir)

	var texts []string
	pages := 0
	for i, doc := range docs {
		in := filepath.Join(dir, strconv.Itoa(i))
		if model == indraOCR.ID {
			text, n, err := a.readDocument(r.Context(), doc, in)
			if err != nil {
				fail(w, err)
				return
			}
			texts, pages = append(texts, text), pages+n
			continue
		}
		images, err := render(r.Context(), doc, in)
		if err != nil {
			fail(w, err)
			return
		}
		read, err := a.readPages(r.Context(), images)
		if err != nil {
			fail(w, err)
			return
		}
		texts, pages = append(texts, read...), pages+len(read)
	}
	content := strings.Join(texts, "\n\n")
	log.Printf("ocr: %s, %d pages in %.1fs, %d characters", model, pages, time.Since(start).Seconds(), len(content))
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      fmt.Sprintf("chatcmpl-%d", time.Now().UnixNano()),
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   model,
		"choices": []any{map[string]any{"index": 0, "message": map[string]string{"role": "assistant", "content": content}, "finish_reason": "stop"}},
		"usage":   map[string]int{"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
	})
}

// fail answers a document that cannot be read with 422, never 400: Lemmary
// takes a 400 that mentions a file as a model refusing PDFs, and would send
// the pages again as images.
func fail(w http.ResponseWriter, err error) {
	var se *statusError
	if errors.As(err, &se) {
		openAIError(w, se.status, se.message)
		return
	}
	openAIError(w, http.StatusInternalServerError, err.Error())
}

type attachment struct {
	mime string
	data []byte
}

// attachments returns every image and file part of the request's messages, in
// order.
func attachments(body []byte) ([]attachment, error) {
	var req struct {
		Messages []struct {
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, errors.New("the request body is not a chat completion")
	}
	var found []attachment
	for _, m := range req.Messages {
		var parts []struct {
			Type     string `json:"type"`
			ImageURL struct {
				URL string `json:"url"`
			} `json:"image_url"`
			File struct {
				FileData string `json:"file_data"`
				FileID   string `json:"file_id"`
			} `json:"file"`
		}
		if json.Unmarshal(m.Content, &parts) != nil {
			continue // a plain string: the prompt
		}
		for _, p := range parts {
			var url string
			switch p.Type {
			case "image_url":
				url = p.ImageURL.URL
			case "file":
				if p.File.FileData == "" && p.File.FileID != "" {
					return nil, errors.New("there is no Files API here; send the document inline as file_data")
				}
				url = p.File.FileData
			default:
				continue
			}
			a, err := decodeDataURL(url)
			if err != nil {
				return nil, err
			}
			found = append(found, a)
		}
	}
	return found, nil
}

// decodeDataURL reads data:<type>[;params];base64,<data>, the only form
// Lemmary sends.
func decodeDataURL(url string) (attachment, error) {
	bad := errors.New("send the document inline as a base64 data: URL")
	header, payload, ok := strings.Cut(strings.TrimPrefix(url, "data:"), ",")
	params := strings.Split(header, ";")
	if !ok || !strings.HasPrefix(url, "data:") || !strings.EqualFold(params[len(params)-1], "base64") {
		return attachment{}, bad
	}
	data, err := base64.StdEncoding.DecodeString(payload)
	if err != nil {
		return attachment{}, bad
	}
	mime := params[0]
	if mime == "" || mime == "application/octet-stream" {
		mime = http.DetectContentType(data)
	}
	return attachment{mime, data}, nil
}

// render turns a document into PNG pages in dir, at most pageEdge on their
// longest side. PDFs go through poppler, as in Lemmary; images through
// ImageMagick, which reads what llama.cpp cannot (WebP, TIFF, AVIF), turns a
// phone photo upright and puts transparency on white.
func render(ctx context.Context, doc attachment, dir string) ([]string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	in := filepath.Join(dir, "in")
	if err := os.WriteFile(in, doc.data, 0o600); err != nil {
		return nil, err
	}
	var cmd *exec.Cmd
	switch {
	case doc.mime == "application/pdf":
		cmd = exec.CommandContext(ctx, "pdftoppm", "-png", "-scale-to", strconv.Itoa(pageEdge), in, filepath.Join(dir, "p"))
	case strings.HasPrefix(doc.mime, "image/"):
		cmd = exec.CommandContext(ctx, "convert", in, "-auto-orient", "-background", "white", "-alpha", "remove", "-alpha", "off",
			"-colorspace", "sRGB", "-resize", fmt.Sprintf("%dx%d>", pageEdge, pageEdge), "-scene", "1", filepath.Join(dir, "p-%04d.png"))
	default:
		return nil, &statusError{http.StatusUnsupportedMediaType, "the OCR model reads PDFs and images, not " + doc.mime}
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		msg := strings.TrimSpace(stderr.String())
		switch {
		case strings.Contains(msg, "Incorrect password"):
			return nil, &statusError{http.StatusUnprocessableEntity, "the PDF is password-protected"}
		case strings.Contains(msg, "no decode delegate"):
			return nil, &statusError{http.StatusUnsupportedMediaType, "cannot read images of type " + doc.mime}
		}
		return nil, &statusError{http.StatusUnprocessableEntity, "cannot read the document: " + strings.SplitN(msg, "\n", 2)[0]}
	}
	pages, _ := filepath.Glob(filepath.Join(dir, "p-*.png"))
	sort.Strings(pages) // pdftoppm pads page numbers to one width
	if len(pages) == 0 {
		return nil, &statusError{http.StatusUnprocessableEntity, "the document has no pages"}
	}
	return pages, nil
}

// readDocument has an Indra worker read a whole document: a PDF as it came,
// so that Indra reads its text layer where it passes Indra's checks, or an
// image, which the worker converts itself if OpenCV cannot read it.
func (a *app) readDocument(ctx context.Context, doc attachment, dir string) (string, int, error) {
	var kind, ext string
	switch {
	case doc.mime == "application/pdf":
		kind, ext = "pdf", ".pdf"
	case strings.HasPrefix(doc.mime, "image/"):
		kind, ext = "image", "."+strings.TrimPrefix(doc.mime, "image/")
	default:
		return "", 0, &statusError{http.StatusUnsupportedMediaType, indraOCR.ID + " reads PDFs and images, not " + doc.mime}
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", 0, err
	}
	in := filepath.Join(dir, "in"+ext)
	if err := os.WriteFile(in, doc.data, 0o600); err != nil {
		return "", 0, err
	}
	res, err := a.indra.convert(ctx, in, kind, a.pageTimeout)
	switch {
	case errors.Is(err, errStalled):
		return "", 0, &statusError{http.StatusGatewayTimeout, fmt.Sprintf("the OCR worker %v and was stopped", err)}
	case err != nil:
		return "", 0, &statusError{http.StatusInternalServerError, "the OCR worker failed: " + err.Error()}
	case res.Error != "":
		return "", 0, &statusError{http.StatusUnprocessableEntity, res.Error}
	}
	return strings.TrimSpace(res.Markdown), res.Pages, nil
}

// readPages reads a document's pages as many at a time as the OCR server has
// slots: generating a page's text leaves the GPU mostly idle, so pages side by
// side cost little more than one. Another document's pages queue for a slot.
func (a *app) readPages(ctx context.Context, pages []string) ([]string, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	texts := make([]string, len(pages))
	slots := make(chan struct{}, a.parallel)
	var wg sync.WaitGroup
	var once sync.Once
	var first error
	for i, page := range pages {
		wg.Go(func() {
			slots <- struct{}{}
			defer func() { <-slots }()
			text, err := a.readPage(ctx, page)
			if err != nil {
				once.Do(func() { first = err; cancel() })
				return
			}
			texts[i] = text
		})
	}
	wg.Wait()
	return texts, first
}

// readPage asks the OCR model for one page's text.
func (a *app) readPage(ctx context.Context, png string) (string, error) {
	port := a.ocr.Port()
	if port == 0 {
		return "", &statusError{http.StatusServiceUnavailable, "the OCR model is not running"}
	}
	data, err := os.ReadFile(png)
	if err != nil {
		return "", err
	}
	content := []any{map[string]any{"type": "image_url", "image_url": map[string]string{"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(data)}}}
	if lightOnOCR.Prompt != "" {
		content = append(content, map[string]string{"type": "text", "text": lightOnOCR.Prompt})
	}
	body, _ := json.Marshal(map[string]any{
		"model":       lightOnOCR.ID,
		"messages":    []any{map[string]any{"role": "user", "content": content}},
		"temperature": 0,
		"max_tokens":  maxPageTokens,
	})
	ctx, cancel := context.WithTimeout(ctx, a.pageTimeout)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "POST", fmt.Sprintf("http://127.0.0.1:%d/v1/chat/completions", port), bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "", &statusError{http.StatusGatewayTimeout, fmt.Sprintf("a page took longer than %s", a.pageTimeout)}
	}
	if err != nil {
		return "", &statusError{http.StatusBadGateway, "the OCR model did not answer: " + err.Error()}
	}
	defer resp.Body.Close()
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || resp.StatusCode != http.StatusOK || len(out.Choices) == 0 {
		return "", &statusError{http.StatusBadGateway, fmt.Sprintf("the OCR model failed a page: %s", resp.Status)}
	}
	text := strings.TrimSpace(out.Choices[0].Message.Content)
	if out.Choices[0].FinishReason == "length" {
		log.Printf("ocr: a page ran past %d tokens; dropping repeated lines", maxPageTokens)
		text = collapseRepeats(text)
	}
	return text, nil
}

// collapseRepeats keeps one line of each run of identical lines, blank lines
// between them aside: what is left of a page whose model looped (PaddleOCR-VL
// wrote one table cell 169 times on a scan).
func collapseRepeats(text string) string {
	var out []string
	last := ""
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" && trimmed == last {
			continue
		}
		if trimmed == "" && len(out) > 0 && strings.TrimSpace(out[len(out)-1]) == "" {
			continue
		}
		if trimmed != "" {
			last = trimmed
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}
