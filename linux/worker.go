package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// The Mac app's OCR worker protocol (macos/Sources/LocalAIKit/Worker/
// WorkerProtocol.swift), which indra_worker.py speaks: the worker loads its
// models and says ready, then takes one request a line on stdin and answers
// with progress lines and one result line on stdout. stderr is its log.
type workerRequest struct {
	ID   string `json:"id"`
	Path string `json:"path"`
	Kind string `json:"kind"`
}

type workerResult struct {
	Markdown string `json:"markdown"`
	Pages    int    `json:"pages"`
	// A document that cannot be read (locked, corrupt): answered as a failed
	// conversion, not a server error.
	Error string `json:"error"`
}

type workerMessage struct {
	Event  string        `json:"event"`
	ID     string        `json:"id"`
	Page   int           `json:"page"`
	Total  int           `json:"total"`
	Result *workerResult `json:"result"`
	Error  string        `json:"error"`
}

var (
	errStalled = errors.New("made no progress")
	errCrashed = errors.New("exited")
)

// worker is one OCR worker process, one request at a time. A page that makes
// no progress for the page timeout gets the process killed, as on the Mac.
type worker struct {
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	messages chan workerMessage // closed when its stdout ends
	seq      atomic.Int64
}

func startWorker(exe string, args []string, logw io.Writer) (*worker, error) {
	cmd := exec.Command(exe, args...)
	cmd.Stderr = logw
	cmd.SysProcAttr = killedWithUs()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	w := &worker{cmd: cmd, stdin: stdin, messages: make(chan workerMessage, 16)}
	go func() {
		defer close(w.messages)
		lines := bufio.NewScanner(stdout)
		lines.Buffer(make([]byte, 1<<20), 64<<20) // a result is a whole document's markdown
		for lines.Scan() {
			var m workerMessage
			if json.Unmarshal(lines.Bytes(), &m) != nil {
				fmt.Fprintf(logw, "unreadable worker output: %.200s\n", lines.Text())
				continue
			}
			w.messages <- m
		}
		cmd.Wait()
	}()
	return w, nil
}

// waitReady waits for the worker's ready line, which comes once its models
// are loaded and warmed up.
func (w *worker) waitReady(timeout time.Duration) error {
	deadline := time.After(timeout)
	for {
		select {
		case m, ok := <-w.messages:
			if !ok {
				return errors.New("exited while loading")
			}
			if m.Event == "ready" {
				if m.Error != "" {
					log.Printf("ocr worker warm-up: %s", m.Error)
				}
				return nil
			}
		case <-deadline:
			w.kill()
			return fmt.Errorf("not ready after %s", timeout)
		}
	}
}

func (w *worker) convert(path, kind string, stall, hard time.Duration) (workerResult, error) {
	id := fmt.Sprintf("r%d", w.seq.Add(1))
	line, _ := json.Marshal(workerRequest{id, path, kind})
	if _, err := w.stdin.Write(append(line, '\n')); err != nil {
		return workerResult{}, fmt.Errorf("%w: %v", errCrashed, err)
	}
	stalled := time.NewTimer(stall)
	defer stalled.Stop()
	timedOut := time.After(hard)
	for {
		select {
		case m, ok := <-w.messages:
			if !ok {
				return workerResult{}, errCrashed
			}
			if m.ID != id {
				continue
			}
			if m.Event == "progress" {
				stalled.Reset(stall)
				continue
			}
			if m.Event == "result" && m.Result != nil {
				return *m.Result, nil
			}
		case <-stalled.C:
			w.kill()
			return workerResult{}, fmt.Errorf("%w for %s", errStalled, stall)
		case <-timedOut:
			w.kill()
			return workerResult{}, fmt.Errorf("%w for %s", errStalled, hard)
		}
	}
}

func (w *worker) kill() { w.cmd.Process.Kill() }

// stop closes stdin, the worker's signal to exit; SIGTERM makes sure.
func (w *worker) stop() {
	w.stdin.Close()
	w.cmd.Process.Signal(syscall.SIGTERM)
}

// workerPool keeps size workers running and warm, replaces one that dies or
// is killed, and retries one that fails to start with a backoff.
type workerPool struct {
	exe     string
	args    []string
	size    int
	logw    io.Writer
	startup time.Duration

	idle  chan *worker
	done  chan struct{}
	ready atomic.Int32
	mu    sync.Mutex
	live  map[*worker]bool
}

func newWorkerPool(exe string, args []string, size int, logw io.Writer) *workerPool {
	return &workerPool{exe: exe, args: args, size: size, logw: logw, startup: 2 * time.Minute,
		idle: make(chan *worker, size), done: make(chan struct{}), live: map[*worker]bool{}}
}

func (p *workerPool) start() {
	for range p.size {
		go p.spawn()
	}
}

func (p *workerPool) stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	select {
	case <-p.done:
		return
	default:
	}
	close(p.done)
	for w := range p.live {
		w.stop()
	}
	p.live = map[*worker]bool{}
	p.ready.Store(0)
}

func (p *workerPool) stopped() bool {
	select {
	case <-p.done:
		return true
	default:
		return false
	}
}

func (p *workerPool) spawn() {
	backoff := time.Second
	for !p.stopped() {
		w, err := startWorker(p.exe, p.args, p.logw)
		if err == nil {
			p.mu.Lock()
			p.live[w] = true
			p.mu.Unlock()
			if err = w.waitReady(p.startup); err == nil {
				p.mu.Lock()
				defer p.mu.Unlock()
				if p.stopped() {
					w.stop()
					return
				}
				p.ready.Add(1)
				p.idle <- w
				return
			}
			p.forget(w)
		}
		log.Printf("ocr worker: %v; trying again in %s", err, backoff)
		select {
		case <-p.done:
			return
		case <-time.After(backoff):
		}
		backoff = min(2*backoff, time.Minute)
	}
}

func (p *workerPool) forget(w *worker) {
	p.mu.Lock()
	delete(p.live, w)
	p.mu.Unlock()
}

// convert reads a document on the next idle worker. A stall is retried once,
// on another worker; a crash is not, since a crash on a file usually repeats.
func (p *workerPool) convert(ctx context.Context, path, kind string, stall, hard time.Duration) (workerResult, error) {
	for attempt := 1; ; attempt++ {
		var w *worker
		select {
		case w = <-p.idle:
		case <-p.done:
			return workerResult{}, errors.New("OCR is stopping")
		case <-ctx.Done():
			return workerResult{}, ctx.Err()
		}
		res, err := w.convert(path, kind, stall, hard)
		if err == nil {
			p.idle <- w
			return res, nil
		}
		p.ready.Add(-1)
		w.kill()
		p.forget(w)
		go p.spawn()
		if !errors.Is(err, errStalled) || attempt > 1 {
			return res, err
		}
		log.Printf("ocr worker %v; trying once more on another worker", err)
	}
}
