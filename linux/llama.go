package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// server supervises one llama-server: it starts it on a free loopback port,
// waits for it to load its model, and restarts it with a backoff when it
// exits. Only the router talks to it.
type server struct {
	role    string // embeddings, ocr or text: its log's name and what errors call it
	exe     string
	args    []string // all but --host and --port
	logPath string
	port    atomic.Int32 // 0 unless it is up and has loaded its model
}

func (s *server) Port() int { return int(s.port.Load()) }

func (s *server) run(ctx context.Context) {
	backoff := time.Second
	for {
		started := time.Now()
		err := s.runOnce(ctx)
		if ctx.Err() != nil {
			return
		}
		if time.Since(started) > 5*time.Minute {
			backoff = time.Second
		}
		log.Printf("%s: llama-server stopped (%v); restarting in %s. Its log ends:\n%s", s.role, err, backoff, tail(s.logPath))
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(2*backoff, time.Minute)
	}
}

func (s *server) runOnce(ctx context.Context) error {
	port, err := freePort()
	if err != nil {
		return err
	}
	logFile, err := os.Create(s.logPath)
	if err != nil {
		return err
	}
	defer logFile.Close()

	cmd := exec.CommandContext(ctx, s.exe, append(s.args, "--host", "127.0.0.1", "--port", strconv.Itoa(port))...)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	// The release tarball keeps its libraries beside the binaries.
	cmd.Env = append(os.Environ(), "LD_LIBRARY_PATH="+filepath.Dir(s.exe)+":"+os.Getenv("LD_LIBRARY_PATH"))
	// A llama-server outliving this process would hold its model in VRAM
	// beside the next one's. The Mac app reaps those through pid files; Linux
	// can have the kernel kill them.
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 10 * time.Second
	if err := cmd.Start(); err != nil {
		return err
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()

	if err := waitHealthy(ctx, port, exited); err != nil {
		cmd.Process.Kill()
		<-exited
		return err
	}
	log.Printf("%s: ready", s.role)
	s.port.Store(int32(port))
	defer s.port.Store(0)
	return <-exited
}

// waitHealthy polls /health, which answers 503 until the model is loaded.
// Ten minutes covers an 18 GB model from a slow disk.
func waitHealthy(ctx context.Context, port int, exited <-chan error) error {
	deadline := time.After(10 * time.Minute)
	url := fmt.Sprintf("http://127.0.0.1:%d/health", port)
	for {
		select {
		case err := <-exited:
			return fmt.Errorf("exited while loading: %v", err)
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline:
			return errors.New("not ready after 10 minutes")
		case <-time.After(500 * time.Millisecond):
		}
		if resp, err := http.Get(url); err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
	}
}

// ponytail: the port can be taken between Close and llama-server's bind; the
// restart loop covers that rare case.
func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func tail(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	if st, err := f.Stat(); err == nil && st.Size() > 4096 {
		f.Seek(-4096, io.SeekEnd)
	}
	b, _ := io.ReadAll(f)
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return strings.Join(lines[max(0, len(lines)-8):], "\n")
}
