package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ocrEngine is one OCR model's server or workers, started and stopped by
// ocrSwitch.
type ocrEngine interface {
	// available says why the engine cannot start now, e.g. its files are
	// still downloading.
	available() error
	// start returns once the engine can read a page.
	start(ctx context.Context) error
	stop()
	ready() bool
}

// ocrSwitch keeps one OCR model in memory, the one used last: LightOnOCR's
// llama-server holds 1.4 GB of VRAM and more a slot, Indra's workers 0.4 to
// 0.6 GB of RAM each, and Lemmary binds one OCR model, so the other's would
// only sit there. A request for the other model waits for the requests in
// flight, then its engine replaces the running one. While a request waits for
// a switch, later ones for the model in memory queue behind it, so neither
// model can keep the other out. The Mac app does the same (OCRSwitch.swift).
type ocrSwitch struct {
	ctx      context.Context // the engines' lifetime
	engines  map[string]ocrEngine
	lastFile string // where the model used last is kept across restarts

	mu        sync.Mutex
	cond      *sync.Cond
	active    string
	switching bool
	inflight  int
	queue     []*string // the models waiting, in order
	last      string
}

func newOCRSwitch(ctx context.Context, engines map[string]ocrEngine, lastFile, fallback string) *ocrSwitch {
	s := &ocrSwitch{ctx: ctx, engines: engines, lastFile: lastFile, last: fallback}
	s.cond = sync.NewCond(&s.mu)
	if b, err := os.ReadFile(lastFile); err == nil {
		if id := strings.TrimSpace(string(b)); engines[id] != nil {
			s.last = id
		}
	}
	return s
}

// current is the model in memory, or else the one used last: what a request
// for the Mac's apple-vision-ocr gets, which is what Lemmary sends when its
// provider's OCR model is left blank.
func (s *ocrSwitch) current() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active != "" {
		return s.active
	}
	return s.last
}

// ready says whether the model in memory can read a page now.
func (s *ocrSwitch) ready() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active != "" && !s.switching && s.engines[s.active].ready()
}

// preload starts model before any request asks for it, at start or once its
// files are in place. Nothing happens while a model is loaded or loading.
func (s *ocrSwitch) preload(model string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active != "" || s.switching || s.ctx.Err() != nil {
		return
	}
	s.last = model
	if err := s.switchTo(model); err != nil {
		log.Printf("ocr: %s: %v", model, err)
	}
	s.cond.Broadcast()
}

// acquire waits until model is in memory and nothing ahead of this request
// wants the other one, switching models when it is this request's turn. The
// caller reads its document, then calls release.
func (s *ocrSwitch) acquire(ctx context.Context, model string) (release func(), err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ticket := &model
	s.queue = append(s.queue, ticket)
	defer s.cond.Broadcast()
	stop := context.AfterFunc(ctx, func() {
		s.mu.Lock()
		s.cond.Broadcast()
		s.mu.Unlock()
	})
	defer stop()
	for {
		if err := ctx.Err(); err != nil {
			s.leave(ticket)
			return nil, err
		}
		if !s.switching && s.active == model && !s.otherAhead(ticket) {
			s.leave(ticket)
			s.inflight++
			// Used once it reads a request: a model that could not start is
			// not what apple-vision-ocr gets.
			s.last = model
			return s.release, nil
		}
		if !s.switching && s.inflight == 0 && s.queue[0] == ticket {
			if err := s.switchTo(model); err != nil {
				s.leave(ticket)
				return nil, err
			}
			continue
		}
		s.cond.Wait()
	}
}

func (s *ocrSwitch) release() {
	s.mu.Lock()
	s.inflight--
	s.cond.Broadcast()
	s.mu.Unlock()
}

// otherAhead says whether a request queued before ticket wants another model.
func (s *ocrSwitch) otherAhead(ticket *string) bool {
	for _, t := range s.queue {
		if t == ticket {
			return false
		}
		if *t != *ticket {
			return true
		}
	}
	return false
}

func (s *ocrSwitch) leave(ticket *string) {
	for i, t := range s.queue {
		if t == ticket {
			s.queue = append(s.queue[:i], s.queue[i+1:]...)
			return
		}
	}
}

// switchTo replaces the engine in memory with model's. Called with mu held
// and nothing in flight; it lets go of mu while engines stop and start. A
// model that cannot start leaves the running one alone.
func (s *ocrSwitch) switchTo(model string) error {
	e := s.engines[model]
	if e == nil {
		return &statusError{404, model + " is not served"}
	}
	if err := e.available(); err != nil {
		return &statusError{503, err.Error()}
	}
	s.switching = true
	old := s.active
	s.active = ""
	s.mu.Unlock()
	if old != "" {
		s.engines[old].stop()
		log.Printf("ocr: unloaded %s", old)
	}
	started := time.Now()
	err := e.start(s.ctx)
	s.mu.Lock()
	s.switching = false
	if err != nil {
		return &statusError{503, fmt.Sprintf("%s could not start: %v", model, err)}
	}
	s.active = model
	log.Printf("ocr: loaded %s in %.1fs", model, time.Since(started).Seconds())
	os.WriteFile(s.lastFile, []byte(model+"\n"), 0o644)
	return nil
}

func (s *ocrSwitch) stop() {
	s.mu.Lock()
	active := s.active
	s.active = ""
	s.mu.Unlock()
	if active != "" {
		s.engines[active].stop()
	}
}

// llamaOCR is LightOnOCR-2's llama-server, run only while it is the model in
// memory. Its files download at start; until then it is unavailable.
type llamaOCR struct {
	s        *server
	prepared atomic.Bool
	cancel   context.CancelFunc
	done     chan struct{}
}

func (l *llamaOCR) available() error {
	if !l.prepared.Load() {
		return errors.New(lightOnOCR.ID + " is still downloading its model; try again in a few minutes")
	}
	return nil
}

func (l *llamaOCR) start(ctx context.Context) error {
	ctx, l.cancel = context.WithCancel(ctx)
	l.done = make(chan struct{})
	go func() {
		defer close(l.done)
		l.s.run(ctx)
	}()
	// Ten minutes, as for any llama-server loading its model.
	deadline := time.After(10 * time.Minute)
	for l.s.Port() == 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline:
			l.stop()
			return errors.New("not ready after 10 minutes")
		case <-time.After(200 * time.Millisecond):
		}
	}
	return nil
}

func (l *llamaOCR) stop() {
	if l.cancel != nil {
		l.cancel()
		<-l.done
		l.cancel = nil
	}
}

func (l *llamaOCR) ready() bool { return l.s.Port() != 0 }

// indraEngine is Indra's workers, run only while it is the model in memory.
// Its runtime and models download at start; until then it is unavailable.
type indraEngine struct {
	workers, threads int
	logw             io.Writer

	mu      sync.Mutex
	install indraInstall
	err     error // why the install failed, if it did
	pool    *workerPool
}

func (ix *indraEngine) installed(inst indraInstall, err error) {
	ix.mu.Lock()
	defer ix.mu.Unlock()
	ix.install, ix.err = inst, err
}

func (ix *indraEngine) available() error {
	ix.mu.Lock()
	defer ix.mu.Unlock()
	switch {
	case ix.err != nil:
		return fmt.Errorf("%s could not be installed: %v", indraOCR.ID, ix.err)
	case ix.install.python == "":
		return errors.New(indraOCR.ID + " is still downloading its runtime and models; try again in a minute")
	}
	return nil
}

func (ix *indraEngine) start(ctx context.Context) error {
	ix.mu.Lock()
	// -I: isolated from any Python of the host's (PYTHONPATH, user site-packages).
	pool := newWorkerPool(ix.install.python, []string{"-I", ix.install.script, "serve", "--models", ix.install.models,
		"--threads", fmt.Sprint(ix.threads)}, ix.workers, ix.logw)
	ix.pool = pool
	ix.mu.Unlock()
	pool.start()
	deadline := time.After(pool.startup)
	for pool.ready.Load() == 0 {
		select {
		case <-ctx.Done():
			pool.stop()
			return ctx.Err()
		case <-deadline:
			pool.stop()
			return errors.New("no worker ready after 2 minutes")
		case <-time.After(100 * time.Millisecond):
		}
	}
	return nil
}

func (ix *indraEngine) stop() {
	if p := ix.workerPool(); p != nil {
		p.stop()
	}
}

func (ix *indraEngine) ready() bool {
	p := ix.workerPool()
	return p != nil && !p.stopped() && p.ready.Load() > 0
}

// convert reads a document on a worker. A document is at most half an hour,
// as on the Mac.
func (ix *indraEngine) convert(ctx context.Context, path, kind string, pageTimeout time.Duration) (workerResult, error) {
	p := ix.workerPool()
	if p == nil {
		return workerResult{}, errors.New(indraOCR.ID + " is not running")
	}
	return p.convert(ctx, path, kind, pageTimeout, 30*time.Minute)
}

func (ix *indraEngine) workerPool() *workerPool {
	ix.mu.Lock()
	defer ix.mu.Unlock()
	return ix.pool
}
