// Command lemmary-local-ai serves Lemmary's local AI from an NVIDIA GPU on
// Linux, all on one port: bge-m3 embeddings, OCR by a vision model, and
// optionally a text model for metadata extraction, each in a llama-server of
// its own on loopback; without a GPU, the embeddings alone, on the CPU. It is
// the Linux counterpart of the macOS app in this repository and answers the
// same API, so Lemmary's lemmary_local_ai provider type works against either.
package main

import (
	"cmp"
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// embedContext is bge-m3's window. An encoder fits each input in one
// micro-batch, and Lemmary's longest chunks are ~5.9k tokens.
const embedContext = 8192

// ocrSlotContext holds a page: ~2.4k image tokens at 2000 px and up to
// maxPageTokens of text.
const ocrSlotContext = 8192

func main() {
	addr := flag.String("addr", ":5001", "address to serve on; 127.0.0.1:5001 keeps it to this machine")
	data := flag.String("data", defaultDataDir(), "where models are downloaded and llama-server logs written")
	llama := flag.String("llama-server", defaultLlamaServer(), "llama-server from llama.cpp's release "+llamaBuild)
	parallel := flag.Int("ocr-parallel", 2, "pages OCR reads at once, of one document or several")
	pageTimeout := flag.Duration("page-timeout", 2*time.Minute, "give up on a page after this long")
	textID := flag.String("text-model", "off", "text model for Lemmary's metadata extraction, or off: "+ids(32))
	textContext := flag.Int("text-context", 16384, "the text model's context in tokens")
	vramGB := flag.Int("vram-gb", 0, "the GPU's memory in GB, if nvidia-smi cannot tell")
	flag.Parse()

	// Without a GPU, embeddings alone: OCR by a vision model took minutes a
	// page on a CPU.
	tier, err := vramTier(*vramGB)
	gpu := err == nil
	if !gpu && *textID != "off" {
		log.Fatalf("%v; a text model needs one", err)
	}
	ocrModel := lightOnOCR
	logs := filepath.Join(*data, "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		log.Fatal(err)
	}
	newServer := func(role string) *server {
		return &server{role: role, exe: *llama, logPath: filepath.Join(logs, role+".log")}
	}
	a := &app{embed: newServer("embeddings"), ocrModel: ocrModel,
		embedContext: embedContext, textContext: *textContext, pageTimeout: *pageTimeout, parallel: *parallel}

	// Each llama-server, its model, and its command line given the model's files.
	type service struct {
		s    *server
		m    model
		args func(paths []string) []string
	}
	services := []service{
		{a.embed, bgeM3, func(p []string) []string {
			return []string{"-m", p[0], "--alias", bgeM3.ID, "--embeddings",
				// bge-m3's dense vector is the CLS token, L2-normalised by
				// llama.cpp as by text-embeddings-inference.
				"--pooling", "cls", "-ngl", "99", "-fa", "on",
				"-c", strconv.Itoa(embedContext), "-b", strconv.Itoa(embedContext), "-ub", strconv.Itoa(embedContext),
				"-np", "1", "--no-webui"}
		}},
	}
	if gpu {
		a.ocr = newServer("ocr")
		services = append(services, service{a.ocr, ocrModel, func(p []string) []string {
			args := []string{"-m", p[0], "--alias", ocrModel.ID, "-ngl", "99", "-fa", "on",
				// One slot per page read at once. Two read a four-page document
				// in 13.4 s instead of 15.5; four were no faster.
				"-np", strconv.Itoa(*parallel), "-c", strconv.Itoa(ocrSlotContext * *parallel),
				// Every page is a new image: nothing to gain from keeping prompts.
				"--cache-ram", "0", "--no-webui"}
			if len(p) > 1 {
				args = append(args, "--mmproj", p[1])
			}
			return args
		}})
	}

	if *textID != "off" {
		m, ok := findText(*textID)
		if !ok {
			log.Fatalf("no text model %q; there are %s", *textID, ids(32))
		}
		if m.MinVRAMGB > tier {
			log.Fatalf("%s needs a GPU of %d GB or more, and this one is in the %d GB tier; models that fit: %s",
				m.ID, m.MinVRAMGB, tier, cmp.Or(ids(tier), "none"))
		}
		a.text, a.textModel = newServer("text"), m
		services = append(services, service{a.text, m, func(p []string) []string {
			return []string{"-m", p[0], "--alias", m.ID, "-ngl", "99", "-fa", "on",
				"-c", strconv.Itoa(*textContext),
				// One document at a time, as Lemmary's worker sends them.
				"-np", "1", "--jinja",
				// Lemmary's requests do not turn thinking off, and thinking
				// took Gemma 4 E4B from ~10 s to 30-60 s a document.
				"--chat-template-kwargs", `{"enable_thinking":false}`,
				// Kept prompts grew RAM ~180 MB a document; the slot still
				// reuses the system prompt.
				"--cache-ram", "0", "--no-webui"}
		}})
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	var wg sync.WaitGroup
	for _, sv := range services {
		wg.Go(func() {
			paths, err := fetch(ctx, filepath.Join(*data, "models"), sv.m)
			if err != nil {
				if ctx.Err() == nil {
					log.Fatalf("%s: %v", sv.s.role, err)
				}
				return
			}
			sv.s.args = sv.args(paths)
			sv.s.run(ctx)
		})
	}

	srv := &http.Server{Addr: *addr, Handler: a.routes(), ReadHeaderTimeout: 30 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	on, ocr, text := fmt.Sprintf("a %d GB GPU", tier), ocrModel.ID, "off"
	if !gpu {
		log.Print(err)
		on, ocr = "the CPU", "off (it needs a GPU)"
	}
	if a.text != nil {
		text = a.textModel.ID
	}
	log.Printf("serving on %s from %s: embeddings %s, OCR %s, text model %s. In Lemmary, add a provider of type Lemmary Local AI with base URL http://<this host>:<port>/v1",
		*addr, on, bgeM3.ID, ocr, text)

	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	srv.Shutdown(shutdown)
	wg.Wait()
}

// vramTier is the largest of 16, 24 and 32 GB the GPU reaches, 0 below 16.
// The thresholds sit under the nominal sizes because the driver and ECC take
// some: a 32 GB RTX 5000 Ada reports 30,712 MiB.
func vramTier(override int) (int, error) {
	mib := override * 1024
	if override == 0 {
		out, err := exec.Command("nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits").Output()
		if err != nil {
			return 0, fmt.Errorf("no NVIDIA GPU found (nvidia-smi: %v); pass -vram-gb if there is one", err)
		}
		// ponytail: the largest single GPU; llama.cpp would split across
		// several, which is not counted.
		for _, line := range strings.Fields(string(out)) {
			n, _ := strconv.Atoi(line)
			mib = max(mib, n)
		}
	}
	for _, t := range []struct{ gb, minMiB int }{{32, 30_000}, {24, 22_000}, {16, 15_000}} {
		if mib >= t.minMiB {
			return t.gb, nil
		}
	}
	return 0, nil
}

// ids lists the text models that fit a GPU of tier GB.
func ids(tier int) string {
	var out []string
	for _, m := range textModels {
		if m.MinVRAMGB <= tier {
			out = append(out, fmt.Sprintf("%s (%d GB)", m.ID, m.MinVRAMGB))
		}
	}
	return strings.Join(out, ", ")
}

func defaultDataDir() string {
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		return filepath.Join(dir, "lemmary-local-ai")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "lemmary-local-ai")
}

// defaultLlamaServer is the one beside this binary, as the release and the
// image ship them, or else the one on PATH.
func defaultLlamaServer() string {
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), "llama-server")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "llama-server"
}
