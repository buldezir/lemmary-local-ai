package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
)

// llamaBuild is the llama.cpp release the Dockerfile installs, the same build
// the Mac app bundles (macos/Scripts/fetch-llama.sh): bge-m3 vectors from a
// different build could mean re-embedding Lemmary's archive.
const llamaBuild = "b11936"

type purpose string

// Lemmary's own names for the jobs (aiprovider.ModelPurpose).
const (
	purposeLLM       purpose = "llm"
	purposeOCR       purpose = "ocr"
	purposeEmbedding purpose = "embedding"
)

type file struct {
	URL    string
	SHA256 string
	Size   int64
}

func (f file) name() string { return path.Base(f.URL) }

type model struct {
	ID, Title string
	Purpose   purpose
	// The model, then its vision projector if it reads images.
	Files []file
	// OCR only: the instruction the model was trained to read a page with, if
	// it needs one.
	Prompt string
	// Text only: the smallest VRAM tier it fits in beside embeddings and OCR.
	MinVRAMGB int
}

// hf pins a file to a repository commit, so a re-upload on Hugging Face cannot
// turn every download into a checksum failure.
func hf(repo, commit, name, sha string, size int64) file {
	return file{fmt.Sprintf("https://huggingface.co/%s/resolve/%s/%s", repo, commit, name), sha, size}
}

// The same file, name and flags as the Mac app's, so its vectors are the ones
// Lemmary already holds: llama.cpp's CPU build matched sentence-transformers
// at cosine 0.99998, its CUDA build the CPU one at 0.9995 or better.
var bgeM3 = model{ID: "BAAI/bge-m3", Title: "BAAI/bge-m3 embeddings", Purpose: purposeEmbedding, Files: []file{
	{"https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-FP16.gguf", "daec91ffb5dd0c27411bd71f29932917c49cf529a641d0168496c3a501e3062c", 1_157_671_200},
}}

// LightOnOCR-2 reads a whole page to markdown without being asked. Of the
// five OCR models llama.cpp serves, it alone kept every word of 22 German,
// English and Russian documents, scanned or not, in reading order; the others
// dropped letterheads and footers (GLM-OCR, HunyuanOCR, dots.ocr) or looped on
// a scanned table (PaddleOCR-VL 1.6). 3.6 s a page on an RTX 5000 Ada, one at
// a time, and 0.9 GB of VRAM a slot.
var lightOnOCR = model{ID: "lightonocr-2", Title: "LightOnOCR-2 1B", Purpose: purposeOCR, Files: []file{
	hf("ggml-org/LightOnOCR-2-1B-GGUF", "7d4daf70c2856a155b1413def00f4ae59843a9cf", "LightOnOCR-2-1B-Q8_0.gguf", "f4cfc0ea9765a4cac22a235191c48aefa94df223419f5ab658b6201f36206d58", 639_443_584),
	hf("ggml-org/LightOnOCR-2-1B-GGUF", "7d4daf70c2856a155b1413def00f4ae59843a9cf", "mmproj-LightOnOCR-2-1B-Q8_0.gguf", "e9b45eb85b0f0afb3cc138236eec7adb75879420130e5e2049ee9af3f24e337f", 449_452_288),
}}

// The Mac app's five text models, the same files, offered by the GPU's
// memory. Each tier is the peak VRAM of everything together (embeddings, OCR
// with two slots, the text model at 16,384 tokens) measured on an RTX 5000
// Ada under OCR and embeddings load, with a GB or more to spare. Lemmary's
// extraction took 2 to 4 s a document on its own and 3.4 to 7.3 s under load.
var textModels = []model{
	// 8.9 GB.
	{ID: "gemma-4-e4b", Title: "Gemma 4 E4B", Purpose: purposeLLM, MinVRAMGB: 16, Files: []file{
		hf("unsloth/gemma-4-E4B-it-GGUF", "bfc15c382204943c3a8fff0c750b94ae2364d7a3", "gemma-4-E4B-it-Q4_K_M.gguf", "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87", 4_977_171_584),
	}},
	// 11.1 GB. Summaries in English for German and Russian documents.
	{ID: "ornith-1.5-9b", Title: "Ornith 1.5 9B", Purpose: purposeLLM, MinVRAMGB: 16, Files: []file{
		hf("ornith-ai/Ornith-1.5-9B-GGUF", "abdd624b12ebf020b767fff532ff44fe552b28c3", "Ornith-1.5-9B-Q4_K_M.gguf", "70c112196e0b7023803c9762752e46d29e612a92c83f995bc3ba1ceb07e8fab6", 5_780_090_816),
	}},
	// 12.8 GB.
	{ID: "gemma-4-12b", Title: "Gemma 4 12B", Purpose: purposeLLM, MinVRAMGB: 16, Files: []file{
		hf("unsloth/gemma-4-12B-it-qat-GGUF", "980b060c40a8539ac159e0501a3e0f66a6365af3", "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf", "90fd44e29e0d7cffeb0fd00dc73cfdab9ed0b0e95306ecf7821ea634c940c370", 6_716_356_800),
	}},
	// 19.9 GB, and the fastest: a mixture of experts reading 4B a token.
	{ID: "gemma-4-26b-a4b", Title: "Gemma 4 26B-A4B", Purpose: purposeLLM, MinVRAMGB: 24, Files: []file{
		hf("unsloth/gemma-4-26B-A4B-it-qat-GGUF", "7b92b5b28818151e8669af2e45e88d6086f490dd", "gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf", "a7c5bc715f5ff8e99a3e8901ce7d2b42b402c669bf24f7c5250747633d0f5891", 14_249_047_104),
	}},
	// 22.5 GB: fits a 24 GB GPU that drives no display.
	{ID: "qwen3.6-35b-a3b", Title: "Qwen3.6 35B-A3B", Purpose: purposeLLM, MinVRAMGB: 24, Files: []file{
		hf("unsloth/Qwen3.6-35B-A3B-GGUF", "a483e9e6cbd595906af30beda3187c2663a1118c", "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf", "649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3", 17_730_509_792),
	}},
}

func findText(id string) (model, bool) {
	for _, m := range textModels {
		if m.ID == id {
			return m, true
		}
	}
	return model{}, false
}

// fetch makes sure every file of m is in dir and returns their paths. A file
// of the right size is trusted: hashing 18 GB at every start costs a minute.
func fetch(ctx context.Context, dir string, m model) ([]string, error) {
	var paths []string
	for _, f := range m.Files {
		p := filepath.Join(dir, f.name())
		if st, err := os.Stat(p); err != nil || st.Size() != f.Size {
			if err := download(ctx, f, p); err != nil {
				return nil, err
			}
		}
		paths = append(paths, p)
	}
	return paths, nil
}

// ponytail: no resume; a cut download starts over.
func download(ctx context.Context, f file, dst string) error {
	log.Printf("downloading %s (%.1f MB)", f.URL, float64(f.Size)/1e6)
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, "GET", f.URL, nil)
	if err != nil {
		return err
	}
	// Hugging Face's token for Hugging Face alone: Indra's runtime comes from
	// GitHub and PyPI.
	if token := os.Getenv("HF_TOKEN"); token != "" && req.URL.Host == "huggingface.co" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: %s", f.URL, resp.Status)
	}
	tmp := dst + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, hash, &progress{name: f.name(), total: f.Size}), resp.Body)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return fmt.Errorf("download %s: %w", f.URL, err)
	}
	if sum := hex.EncodeToString(hash.Sum(nil)); n != f.Size || sum != f.SHA256 {
		return fmt.Errorf("download %s: got %d bytes with SHA-256 %s, want %d bytes with %s", f.URL, n, sum, f.Size, f.SHA256)
	}
	return os.Rename(tmp, dst)
}

// progress logs a download every tenth of the way.
type progress struct {
	name        string
	total, done int64
}

func (p *progress) Write(b []byte) (int, error) {
	before := p.done * 10 / max(p.total, 1)
	p.done += int64(len(b))
	if after := p.done * 10 / max(p.total, 1); after != before {
		log.Printf("%s: %d%%", p.name, after*10)
	}
	return len(b), nil
}
