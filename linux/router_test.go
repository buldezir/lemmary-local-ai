package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeLlama stands in for a llama-server: a chat completion answers with
// pageID of its image, anything else is echoed.
type fakeLlama struct {
	mu       sync.Mutex
	requests []map[string]any
	paths    []string
}

func (f *fakeLlama) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var req map[string]any
	json.Unmarshal(body, &req)
	f.mu.Lock()
	f.requests = append(f.requests, req)
	f.paths = append(f.paths, r.URL.Path)
	f.mu.Unlock()
	if r.URL.Path == "/v1/chat/completions" && req["stream"] == true {
		w.Header().Set("Content-Type", "text/event-stream")
		for _, tok := range []string{"Hal", "lo"} {
			fmt.Fprintf(w, "data: %q\n\n", tok)
			w.(http.Flusher).Flush()
		}
		return
	}
	if r.URL.Path == "/v1/chat/completions" && req["model"] != "gemma-4-e4b" {
		writeJSON(w, 200, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": " " + pageID(body) + " \n"}, "finish_reason": "stop"}}})
		return
	}
	w.Write(body)
}

// pageID names a page by its image, whichever order pages are read in.
func pageID(body []byte) string {
	_, rest, _ := strings.Cut(string(body), "base64,")
	sum := sha256.Sum256([]byte(rest[:strings.IndexByte(rest, '"')]))
	return hex.EncodeToString(sum[:4])
}

func newTestApp(t *testing.T, textOn bool) (*app, *fakeLlama, *httptest.Server) {
	fake := &fakeLlama{}
	upstream := httptest.NewServer(fake)
	t.Cleanup(upstream.Close)
	u, _ := url.Parse(upstream.URL)
	port, _ := strconv.Atoi(u.Port())
	a := &app{embed: &server{role: "embeddings"}, ocr: &server{role: "ocr"}, ocrModel: lightOnOCR,
		embedContext: 8192, textContext: 16384, pageTimeout: 10 * time.Second, parallel: 2}
	a.embed.port.Store(int32(port))
	a.ocr.port.Store(int32(port))
	if textOn {
		a.text = &server{role: "text"}
		a.textModel, _ = findText("gemma-4-e4b")
		a.text.port.Store(int32(port))
	}
	srv := httptest.NewServer(a.routes())
	t.Cleanup(srv.Close)
	return a, fake, srv
}

func post(t *testing.T, url string, body any) (int, string) {
	t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post(url, "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(out)
}

func get(t *testing.T, url string) (int, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(out)
}

func ocrRequest(model string, parts ...any) map[string]any {
	content := append([]any{map[string]any{"type": "text", "text": "Extract all text from this document."}}, parts...)
	return map[string]any{"model": model, "messages": []any{
		map[string]any{"role": "system", "content": "You transcribe documents for an archive."},
		map[string]any{"role": "user", "content": content},
	}}
}

func filePart(t *testing.T, path, mime string) any {
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"type": "file", "file": map[string]any{"filename": "doc.pdf", "file_data": "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(data)}}
}

func needTool(t *testing.T, name string) {
	if _, err := exec.LookPath(name); err != nil {
		t.Skip(name + " is not installed")
	}
}

func TestModelsSayWhatEachIsFor(t *testing.T) {
	_, _, srv := newTestApp(t, true)
	_, body := get(t, srv.URL+"/v1/models")
	var list struct {
		Data []modelEntry `json:"data"`
	}
	json.Unmarshal([]byte(body), &list)
	got := map[string]string{}
	for _, m := range list.Data {
		got[m.ID] = fmt.Sprint(m.Purposes, m.ContextLength)
	}
	want := map[string]string{"BAAI/bge-m3": "[embedding] 8192", "lightonocr-2": "[ocr] 0", "gemma-4-e4b": "[llm] 16384"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("models %v, want %v", got, want)
	}
	if status, _ := get(t, srv.URL+"/v1/models/BAAI/bge-m3"); status != 200 {
		t.Fatalf("GET /v1/models/BAAI/bge-m3: %d", status)
	}
	if status, _ := get(t, srv.URL+"/models/nope"); status != 404 {
		t.Fatalf("GET /models/nope: %d", status)
	}

	_, _, off := newTestApp(t, false)
	if _, body := get(t, off.URL+"/v1/models"); strings.Contains(body, "gemma") {
		t.Fatalf("text model listed while off: %s", body)
	}
}

func TestEmbeddingsAndTextAreForwarded(t *testing.T) {
	_, fake, srv := newTestApp(t, true)
	if status, body := post(t, srv.URL+"/embeddings", map[string]any{"model": "BAAI/bge-m3", "input": []string{"x"}}); status != 200 || !strings.Contains(body, `"input":["x"]`) {
		t.Fatalf("embeddings: %d %s", status, body)
	}
	if status, body := post(t, srv.URL+"/v1/chat/completions", map[string]any{"model": "gemma-4-e4b", "stream": true}); status != 200 || body != "data: \"Hal\"\n\ndata: \"lo\"\n\n" {
		t.Fatalf("stream: %d %q", status, body)
	}
	if fmt.Sprint(fake.paths) != "[/v1/embeddings /v1/chat/completions]" {
		t.Fatalf("upstream paths %v", fake.paths)
	}
}

func TestTextModelOffOrDown(t *testing.T) {
	_, _, off := newTestApp(t, false)
	if status, _ := post(t, off.URL+"/v1/chat/completions", map[string]any{"model": "gemma-4-e4b"}); status != 404 {
		t.Fatalf("text model off: %d", status)
	}
	a, _, srv := newTestApp(t, true)
	a.text.port.Store(0)
	if status, body := post(t, srv.URL+"/v1/chat/completions", map[string]any{"model": "gemma-4-e4b"}); status != 503 || !strings.Contains(body, "server_error") {
		t.Fatalf("text model down: %d %s", status, body)
	}
	if status, _ := get(t, srv.URL+"/ready"); status != 503 {
		t.Fatalf("ready while text is down: %d", status)
	}
}

func TestOCRReadsEveryPageInOrder(t *testing.T) {
	needTool(t, "pdftoppm")
	_, fake, srv := newTestApp(t, false)
	pages, err := render(t.Context(), attachment{"application/pdf", must(os.ReadFile("testdata/two-pages.pdf"))}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, p := range pages {
		want = append(want, pageID([]byte(`"base64,`+base64.StdEncoding.EncodeToString(must(os.ReadFile(p)))+`"`)))
	}
	// apple-vision-ocr is what Lemmary sends when the OCR model is left blank.
	for _, model := range []string{"lightonocr-2", appleVisionOCR} {
		fake.requests = nil
		status, body := post(t, srv.URL+"/v1/chat/completions", ocrRequest(model, filePart(t, "testdata/two-pages.pdf", "application/pdf")))
		var resp struct {
			Choices []struct{ Message struct{ Content string } }
		}
		json.Unmarshal([]byte(body), &resp)
		if status != 200 || resp.Choices[0].Message.Content != strings.Join(want, "\n\n") {
			t.Fatalf("%s: %d %s", model, status, body)
		}
	}
	// Each page goes to the OCR model as a PNG, without Lemmary's prompt:
	// LightOnOCR-2 reads a page unprompted.
	content := fake.requests[0]["messages"].([]any)[0].(map[string]any)["content"].([]any)
	image := content[0].(map[string]any)["image_url"].(map[string]any)["url"].(string)
	if !strings.HasPrefix(image, "data:image/png;base64,") || len(content) != 1 {
		t.Fatalf("page request %.200v", content)
	}
}

func TestOCRDocumentFailuresAreNot400(t *testing.T) {
	needTool(t, "pdftoppm")
	_, _, srv := newTestApp(t, false)
	// Lemmary would take a 400 mentioning a file as the model refusing PDFs.
	if status, body := post(t, srv.URL+"/v1/chat/completions", ocrRequest("lightonocr-2", filePart(t, "testdata/locked.pdf", "application/pdf"))); status != 422 || !strings.Contains(body, "password-protected") {
		t.Fatalf("locked PDF: %d %s", status, body)
	}
	if status, _ := post(t, srv.URL+"/v1/chat/completions", ocrRequest("lightonocr-2", filePart(t, "go.mod", "text/plain"))); status != 415 {
		t.Fatalf("text file: %d", status)
	}
	if status, _ := post(t, srv.URL+"/v1/chat/completions", ocrRequest("lightonocr-2")); status != 400 {
		t.Fatalf("no document: %d", status)
	}
}

func TestOCRImageIsFlattenedOntoWhite(t *testing.T) {
	needTool(t, "convert")
	_, fake, srv := newTestApp(t, false)
	img := image.NewNRGBA(image.Rect(0, 0, 40, 20)) // fully transparent
	img.Set(1, 1, color.NRGBA{0, 0, 0, 255})
	var buf bytes.Buffer
	png.Encode(&buf, img)
	part := map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(buf.Bytes())}}
	if status, body := post(t, srv.URL+"/v1/chat/completions", ocrRequest("lightonocr-2", part)); status != 200 {
		t.Fatalf("image: %d %s", status, body)
	}
	content := fake.requests[0]["messages"].([]any)[0].(map[string]any)["content"].([]any)
	data, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(content[0].(map[string]any)["image_url"].(map[string]any)["url"].(string), "data:image/png;base64,"))
	sent, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if r, g, b, a := sent.At(20, 10).RGBA(); r>>8 != 255 || g>>8 != 255 || b>>8 != 255 || a>>8 != 255 {
		t.Fatalf("transparent pixel sent as %d %d %d %d, want opaque white", r>>8, g>>8, b>>8, a>>8)
	}
}

func TestCollapseRepeats(t *testing.T) {
	loop := "Grid fee\n01.12.2025 – 31.12.2025\n\n01.12.2025 – 31.12.2025\n\n01.12.2025 – 31.12.2025\n\n01.12.2025"
	if got := collapseRepeats(loop); got != "Grid fee\n01.12.2025 – 31.12.2025\n\n01.12.2025" {
		t.Fatalf("collapseRepeats = %q", got)
	}
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func TestVRAMTiers(t *testing.T) {
	for gb, want := range map[int]int{8: 0, 16: 16, 24: 24, 30: 32, 48: 32} {
		if got, _ := vramTier(gb); got != want {
			t.Errorf("vramTier(%d) = %d, want %d", gb, got, want)
		}
	}
}
