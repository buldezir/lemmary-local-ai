package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"strings"
	"time"
)

// Lemmary sends a document of up to 47 MiB, base64 in JSON. The Mac app takes
// the same.
const maxBody = 128 << 20

// app answers everything on one port, so Lemmary needs one provider of its
// lemmary_local_ai type: embeddings and the text model are forwarded to their
// llama-servers, OCR pages are read here one at a time by the OCR model's.
type app struct {
	embed, ocr, text *server // text is nil when off
	ocrModel         model
	textModel        model
	embedContext     int
	textContext      int
	pageTimeout      time.Duration
	parallel         int // the OCR server's slots
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	// Like llama-server, with and without /v1.
	for _, prefix := range []string{"/v1", ""} {
		mux.HandleFunc("GET "+prefix+"/models", func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": a.models()})
		})
		// An id may hold a slash (BAAI/bge-m3).
		mux.HandleFunc("GET "+prefix+"/models/{id...}", a.model)
		mux.HandleFunc("POST "+prefix+"/embeddings", func(w http.ResponseWriter, r *http.Request) {
			proxy(w, r, a.embed, "/v1/embeddings")
		})
		mux.HandleFunc("POST "+prefix+"/chat/completions", a.chat)
	}
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })
	mux.HandleFunc("GET /ready", a.ready)
	return mux
}

type modelEntry struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int    `json:"created"`
	OwnedBy string `json:"owned_by"`
	// Lemmary shows "id (name)" in its pickers.
	Name string `json:"name"`
	// What the model is for: Lemmary's pickers list a model only for these.
	Purposes []purpose `json:"purposes"`
	// Mistral's capabilities object, which Lemmary also reads.
	Capabilities struct {
		CompletionChat bool `json:"completion_chat"`
		OCR            bool `json:"ocr"`
		Embeddings     bool `json:"embeddings"`
	} `json:"capabilities"`
	ContextLength int `json:"context_length,omitempty"`
}

func entry(m model, title string, context int) modelEntry {
	e := modelEntry{ID: m.ID, Object: "model", OwnedBy: "lemmary-local-ai", Name: title, Purposes: []purpose{m.Purpose}, ContextLength: context}
	e.Capabilities.CompletionChat = m.Purpose == purposeLLM
	e.Capabilities.OCR = m.Purpose == purposeOCR
	e.Capabilities.Embeddings = m.Purpose == purposeEmbedding
	return e
}

func (a *app) models() []modelEntry {
	list := []modelEntry{entry(bgeM3, bgeM3.Title, a.embedContext), entry(a.ocrModel, a.ocrModel.Title+" OCR", 0)}
	if a.text != nil {
		list = append(list, entry(a.textModel, a.textModel.Title, a.textContext))
	}
	return list
}

func (a *app) model(w http.ResponseWriter, r *http.Request) {
	for _, e := range a.models() {
		if e.ID == r.PathValue("id") {
			writeJSON(w, http.StatusOK, e)
			return
		}
	}
	openAIError(w, http.StatusNotFound, fmt.Sprintf("The model '%s' does not exist", r.PathValue("id")))
}

// chat sends the OCR model's requests to OCR and any other to the text model,
// whichever one is running.
func (a *app) chat(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		openAIError(w, http.StatusRequestEntityTooLarge, err.Error())
		return
	}
	var req struct {
		Model string `json:"model"`
	}
	json.Unmarshal(body, &req)
	if req.Model == a.ocrModel.ID || req.Model == appleVisionOCR {
		a.ocrChat(w, r, body)
		return
	}
	if a.text == nil {
		openAIError(w, http.StatusNotFound, fmt.Sprintf("%s is not served: start with -text-model to serve a text model", req.Model))
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	proxy(w, r, a.text, "/v1/chat/completions")
}

func (a *app) ready(w http.ResponseWriter, r *http.Request) {
	var waiting []string
	for _, s := range []*server{a.embed, a.ocr, a.text} {
		if s != nil && s.Port() == 0 {
			waiting = append(waiting, s.role)
		}
	}
	if len(waiting) > 0 {
		http.Error(w, "starting: "+strings.Join(waiting, ", "), http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(w, "ready")
}

// proxy forwards to a llama-server and streams its answer back as it comes:
// a streamed completion's tokens go out as they are generated, and a client
// that hangs up cancels the request, which stops llama-server generating.
func proxy(w http.ResponseWriter, r *http.Request, s *server, path string) {
	port := s.Port()
	if port == 0 {
		openAIError(w, http.StatusServiceUnavailable, fmt.Sprintf("the %s model is not running", s.role))
		return
	}
	(&httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = "http"
			pr.Out.URL.Host = fmt.Sprintf("127.0.0.1:%d", port)
			pr.Out.URL.Path = path
		},
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			openAIError(w, http.StatusBadGateway, fmt.Sprintf("the %s model did not answer: %v", s.role, err))
		},
	}).ServeHTTP(w, r)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// openAIError writes OpenAI's error shape, whose message the openai-go client
// Lemmary uses reports as the reason.
func openAIError(w http.ResponseWriter, status int, message string) {
	kind := "invalid_request_error"
	if status >= 500 {
		kind = "server_error"
	}
	writeJSON(w, status, map[string]any{"error": map[string]string{"message": message, "type": kind}})
}
