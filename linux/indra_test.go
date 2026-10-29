package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeEngine stands in for LightOnOCR's llama-server, whose port the tests
// set themselves.
type fakeEngine struct {
	started atomic.Int32
	up      atomic.Bool
}

func (f *fakeEngine) available() error { return nil }
func (f *fakeEngine) start(context.Context) error {
	f.started.Add(1)
	f.up.Store(true)
	return nil
}
func (f *fakeEngine) stop()       { f.up.Store(false) }
func (f *fakeEngine) ready() bool { return f.up.Load() }

// fakeWorker is indra_worker.py's protocol in shell, so the pool and the
// switch are tested against real processes and pipes. It answers by the
// file's contents: locked, hang, or anything else, read.
const fakeWorker = `#!/bin/sh
echo '{"event":"ready"}'
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed 's/.*"id":"\([^"]*\)".*/\1/')
  path=$(printf '%s' "$line" | sed 's/.*"path":"\([^"]*\)".*/\1/')
  if grep -q locked "$path"; then
    echo "{\"event\":\"result\",\"id\":\"$id\",\"result\":{\"error\":\"the PDF is password-protected\",\"pages\":0}}"
  elif grep -q hang "$path"; then
    echo "{\"event\":\"progress\",\"id\":\"$id\",\"page\":0,\"total\":1}"; sleep 30
  else
    echo "{\"event\":\"result\",\"id\":\"$id\",\"result\":{\"markdown\":\"indra read $(basename "$path")\",\"pages\":1}}"
  fi
done
`

// fakeIndra is an Indra engine whose "python" is fakeWorker: it ignores the
// arguments it is started with.
func fakeIndra(t *testing.T) *indraEngine {
	exe := filepath.Join(t.TempDir(), "python3")
	if err := os.WriteFile(exe, []byte(fakeWorker), 0o755); err != nil {
		t.Fatal(err)
	}
	ix := &indraEngine{workers: 1, threads: 1, logw: io.Discard}
	ix.installed(indraInstall{python: exe, script: "indra_worker.py", models: t.TempDir()}, nil)
	return ix
}

func TestTheWorkerScriptIsTheMacApps(t *testing.T) {
	mac, err := os.ReadFile("../macos/Resources/indra_worker.py")
	if err != nil {
		t.Skip("no macos/ beside linux/")
	}
	if !bytes.Equal(mac, indraWorkerScript) {
		t.Fatal("linux/indra_worker.py and macos/Resources/indra_worker.py differ; keep them identical")
	}
}

func TestAnUninstalledIndraIsUnavailable(t *testing.T) {
	ix := &indraEngine{workers: 1, threads: 1, logw: io.Discard}
	s := newOCRSwitch(context.Background(), map[string]ocrEngine{indraOCR.ID: ix}, t.TempDir()+"/ocr-model", indraOCR.ID)
	_, err := s.acquire(context.Background(), indraOCR.ID)
	if se, ok := err.(*statusError); !ok || se.status != 503 || !strings.Contains(se.message, "downloading") {
		t.Fatalf("acquire before the install: %v", err)
	}
}

func TestARequestWaitsForTheSwitch(t *testing.T) {
	light := &fakeEngine{}
	ix := fakeIndra(t)
	s := newOCRSwitch(context.Background(), map[string]ocrEngine{lightOnOCR.ID: light, indraOCR.ID: ix}, t.TempDir()+"/ocr-model", lightOnOCR.ID)
	defer s.stop()
	release, err := s.acquire(context.Background(), lightOnOCR.ID)
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan error)
	go func() {
		r, err := s.acquire(context.Background(), indraOCR.ID)
		if err == nil {
			r()
		}
		got <- err
	}()
	select {
	case <-got:
		t.Fatal("indra-ocr was let in while lightonocr-2 had a request in flight")
	case <-time.After(300 * time.Millisecond):
	}
	// A later request for the model in memory queues behind the switch.
	later := make(chan struct{})
	go func() {
		r, _ := s.acquire(context.Background(), lightOnOCR.ID)
		r()
		close(later)
	}()
	release()
	if err := <-got; err != nil {
		t.Fatal(err)
	}
	<-later
	if light.started.Load() != 2 {
		t.Fatalf("LightOnOCR started %d times, want 2 (before and after Indra)", light.started.Load())
	}
}

func TestUnpacking(t *testing.T) {
	dir := t.TempDir()
	var tgz bytes.Buffer
	gz := gzip.NewWriter(&tgz)
	tw := tar.NewWriter(gz)
	tw.WriteHeader(&tar.Header{Name: "python/bin/", Typeflag: tar.TypeDir, Mode: 0o755})
	tw.WriteHeader(&tar.Header{Name: "python/bin/python3.12", Typeflag: tar.TypeReg, Mode: 0o755, Size: 2})
	tw.Write([]byte("py"))
	tw.WriteHeader(&tar.Header{Name: "python/bin/python3", Typeflag: tar.TypeSymlink, Linkname: "python3.12"})
	tw.Close()
	gz.Close()
	archive := filepath.Join(dir, "python.tar.gz")
	os.WriteFile(archive, tgz.Bytes(), 0o644)
	if err := untar(archive, filepath.Join(dir, "rt")); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(dir, "rt/python/bin/python3")); err != nil || string(b) != "py" {
		t.Fatalf("python3 through its symlink: %q %v", b, err)
	}
	if st, _ := os.Stat(filepath.Join(dir, "rt/python/bin/python3.12")); st.Mode().Perm()&0o100 == 0 {
		t.Fatal("python3.12 lost its executable bit")
	}

	var whl bytes.Buffer
	zw := zip.NewWriter(&whl)
	w, _ := zw.Create("indra_ocr/__init__.py")
	w.Write([]byte("x = 1"))
	zw.Close()
	wheel := filepath.Join(dir, "a.whl")
	os.WriteFile(wheel, whl.Bytes(), 0o644)
	if err := unzip(wheel, filepath.Join(dir, "site")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "site/indra_ocr/__init__.py")); err != nil {
		t.Fatal(err)
	}

	whl.Reset()
	zw = zip.NewWriter(&whl)
	zw.Create("../escape.py")
	zw.Close()
	os.WriteFile(wheel, whl.Bytes(), 0o644)
	if err := unzip(wheel, filepath.Join(dir, "site")); err == nil {
		t.Fatal("a wheel writing outside site-packages was unpacked")
	}
}

// The Mac's runtime, for TestIndraLive on a Mac: the same versions as Linux's
// (macos/Sources/LocalAIKit/OCR/IndraRuntime.swift).
var macPython = file{"https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-aarch64-apple-darwin-install_only_stripped.tar.gz",
	"9866e11cf2ae9caa1e671383786f248859a52dd8bfb702fb4c0dc2c65f1d36de", 25_052_618}
var macWheels = []file{
	indraWheels[0],
	pypi("31/2f/5ea3570fcb8ccd0882bea99436a513b2c85dad8f774a2057849130a8fb99/numpy-2.5.4-cp312-cp312-macosx_14_0_arm64.whl", "9cb18a327b49c5c337f972b03682f6a49855525faaf3c0d3e9c96cd0fd8880a8", 5_451_717),
	pypi("0e/f7/cecc0efeeea83bff2f7789ae1b80f27fa0f0210d6d9d66d1f0031a6b5e47/onnxruntime-1.31.1-cp312-cp312-macosx_14_0_arm64.whl", "96dd2564b10ea7153ad9c207e7cd8e5917cb3ba521e0e0a62ac03486fdc8d56c", 20_882_125),
	pypi("53/7c/8c8097891c509d98cd128493835c95631c80be6a8f37ed9d25716c2e16f1/opencv_python_headless-5.0.0.93-cp37-abi3-macosx_13_0_arm64.whl", "030ca5e0837a2963ab36ef896baa9767eb8d2b83353fb28af5a521e40dd8756f", 48_322_581),
	pypi("d1/ea/14673bc9d8b7beeaa1eb46e9951b22543edaf2a4676c586e3b1e032ff6ee/pypdfium2-5.14.0-py3-none-macosx_13_0_arm64.whl", "2de384df66ba55fcaab0775f30f28ec1090af3dfa60276a07821efc96d993118", 3_542_294),
}

// TestIndraLive downloads and unpacks the real runtime and models, about
// 180 MB, and reads a PDF with them: INDRA_LIVE=1 go test -run TestIndraLive.
// Set INDRA_DATA to keep the download between runs.
func TestIndraLive(t *testing.T) {
	if os.Getenv("INDRA_LIVE") != "1" {
		t.Skip("set INDRA_LIVE=1 to download Indra and read with it")
	}
	python, wheels := indraPython, indraWheels
	if runtime.GOOS == "darwin" {
		python, wheels = macPython, macWheels
	}
	data := os.Getenv("INDRA_DATA")
	if data == "" {
		data = t.TempDir()
	}
	inst, err := installIndra(t.Context(), data, python, wheels)
	if err != nil {
		t.Fatal(err)
	}
	ix := &indraEngine{workers: 1, threads: 2, logw: os.Stderr}
	ix.installed(inst, nil)
	if err := ix.start(t.Context()); err != nil {
		t.Fatal(err)
	}
	defer ix.stop()
	pdf, _ := filepath.Abs("testdata/two-pages.pdf")
	res, err := ix.convert(t.Context(), pdf, "pdf", time.Minute)
	if err != nil || res.Pages != 2 || !strings.Contains(res.Markdown, "Rechnung Seite eins") || !strings.Contains(res.Markdown, "Счёт страница два") {
		t.Fatalf("two-pages.pdf: %+v %v", res, err)
	}
	locked, _ := filepath.Abs("testdata/locked.pdf")
	if res, err := ix.convert(t.Context(), locked, "pdf", time.Minute); err != nil || res.Error != "the PDF is password-protected" {
		t.Fatalf("locked.pdf: %+v %v", res, err)
	}
}
