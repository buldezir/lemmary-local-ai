package main

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	_ "embed"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// Indra OCR (datalab-to/indra) on ONNX Runtime, on the CPU: a relocatable
// CPython (python-build-standalone), the five packages Indra imports,
// unpacked straight into its site-packages, and the models from a tag of
// datalab-to/indra-ocr, every file pinned by SHA-256 and downloaded into the
// data directory at the first start, as the models are. Nothing else is
// needed: onnxruntime's declared dependencies are for its tools, and
// huggingface_hub only downloads models, which this program does itself. The
// Mac app pins the same versions (macos/Sources/LocalAIKit/OCR/
// IndraRuntime.swift); change both together, and indraRuntimeID with them.
var indraOCR = model{ID: "indra-ocr", Title: "Indra OCR", Purpose: purposeOCR, Files: []file{
	indraModel("det.onnx", "f2bd4cba23e9c328cf7ec824634e423e191a2c6aacbbf35c62bd79dd70f62f59", 389_948),
	indraModel("rec.onnx", "475972a2710be4a3cbfeb2bc7f3624ffd563de07de42476fc7a290d4e1ece484", 5_042_161),
	indraModel("rec_cjk.onnx", "4a035516a17e62cdf33a4fe2d88077654cb8841cff024685cdef4e351694ef50", 10_176_018),
	indraModel("rec_rtl.onnx", "468796bd684486a8388c30c8b4ed2a26e3eeb1f8ff02831c24c2e12c79a2a834", 4_812_710),
	indraModel("rec_world.onnx", "c8d1e59f21b04966f179d2d2d8e22b230d22110b3f89855bbbf2624a58c40043", 5_627_990),
	indraModel("script.onnx", "b6ce4e926e19c243faaf37bd46880398bf2cb4ae56a29e1177a3b017c1280e36", 191_630),
	indraModel("orient.onnx", "20eaf670f55a7cf9facfe1bdd6c7b8e40be75bbf4d48a3df43f66aa3bbd874fd", 371_802),
	indraModel("order.onnx", "a42db2e8b536ad3d84045a4b7f9b0a72667cf8be4aa02d63f7b38004719fb180", 2_973_138),
	indraModel("lm.npz", "6c0fb618a363a0acdd05d4f5b0edd9e8146d2d990541b87f6130bbfe17cea58d", 15_695_957),
	indraModel("lm_cjk.npz", "6d64f13f4f90f4e529bd63340c6df76238d007feaef2abb903d8cd28d92bc2f3", 18_955_160),
	indraModel("lm_world.npz", "34df5e74a2fcbb9cf5e7f360a559375ffa2e04d2d2943a42308c177bcb444d5d", 11_641_215),
	indraModel("meta.json", "4ce4c94b46f5d644033c02e718322014ff4081270f385038c571912b56696339", 211_869),
	// The weights' licence, which has to travel with them.
	indraModel("LICENSE", "50c88a018a7ee322e89f6b09401b237beb0cd331685879405b3db48993950a5f", 14_750),
}}

// indraModel is a file of the tag v1.1.0, which indra-ocr 1.1.2 was built
// against, without the math models: math is off.
func indraModel(name, sha string, size int64) file {
	return hf("datalab-to/indra-ocr", "bd02167fdf2005a19962cc15188f8496a2c87d3b", name, sha, size)
}

// indraRuntimeID names the runtime's directory, and so its version.
const indraRuntimeID = "indra-1.1.2-cpython-3.12.15-20261013"

var indraPython = file{"https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
	"178d3d83b6e8e99285a65d3fce9c16b87952cc5efdb4d1a0e3ff3be18ff0fc9c", 34_340_172}

// The wheels at PyPI's own addresses, for CPython 3.12 on x86-64 glibc 2.28
// or newer.
var indraWheels = []file{
	pypi("3f/9a/ad0b5a2d72acc47bf321fc9c73c559b4c7743228c59f55949d2c050e4328/indra_ocr-1.1.2-py3-none-any.whl", "22c82720968dd91b11ae137865fa01edaed29d7c1c11dd5d9c4a084bc3654da2", 96_141),
	pypi("43/a3/c799c62e19c337e6d3770b08e475887fb30ce8477d3c09efca6b2f0228a6/numpy-2.5.4-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", "fbde6962867ee75b48b0ee29b2b9372ec5d617799dbaf38e82dc0596f2f7738a", 16_727_283),
	pypi("eb/27/c6a823bac55b2977bea2027c3ec9393a2c1002cb9a09eb40354563e02730/onnxruntime-1.31.1-cp312-cp312-manylinux_2_28_x86_64.whl", "1f3dea47f2f0e5117c2404cea7d21fd253ae7836a3bf167a501cdfbb2600d536", 23_760_988),
	pypi("9b/21/f6ef335f6e65724aa78b8d792b48d40a48c381715f1e62f5a5049e09d07e/opencv_python_headless-5.0.0.93-cp37-abi3-manylinux_2_28_x86_64.whl", "ed709fdf9aa0bd1f2ed8549e71d19449b03a675bb581eb292285f6861953be37", 61_204_038),
	pypi("4f/a3/c9cc797fc8bdfb8f37b9b0f8b9d02a5fc196b2015f408d53624cab5b0519/pypdfium2-5.14.0-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl", "11f281613fa22313d9c7ab89947665e84eccf8ebe40e1198a84a88352305648d", 3_799_581),
}

func pypi(path, sha string, size int64) file {
	return file{"https://files.pythonhosted.org/packages/" + path, sha, size}
}

// The worker the Mac app runs too (macos/Resources/indra_worker.py).
//
//go:embed indra_worker.py
var indraWorkerScript []byte

// indraInstall is where Indra's runtime, worker and models are once
// installIndra has put them there.
type indraInstall struct {
	python, script, models string
}

// installIndra makes sure the runtime and models are in data, downloading
// what is missing, and writes the worker script beside them. A runtime is
// unpacked into a directory of its own, marked complete last, so one cut
// off half unpacked is unpacked again.
func installIndra(ctx context.Context, data string, python file, wheels []file) (indraInstall, error) {
	models := filepath.Join(data, "models", "indra-ocr-v1.1.0")
	if _, err := fetch(ctx, models, indraOCR); err != nil {
		return indraInstall{}, err
	}
	root := filepath.Join(data, "indra")
	runtime := filepath.Join(root, indraRuntimeID)
	marker := filepath.Join(runtime, ".installed")
	inst := indraInstall{filepath.Join(runtime, "python", "bin", "python3"), filepath.Join(root, "indra_worker.py"), models}
	if _, err := os.Stat(marker); err != nil {
		downloads := filepath.Join(root, "downloads")
		defer os.RemoveAll(downloads)
		paths, err := fetch(ctx, downloads, model{ID: "indra-runtime", Files: append([]file{python}, wheels...)})
		if err != nil {
			return indraInstall{}, err
		}
		log.Printf("indra-ocr: unpacking")
		if err := os.RemoveAll(runtime); err != nil {
			return indraInstall{}, err
		}
		if err := untar(paths[0], runtime); err != nil {
			return indraInstall{}, fmt.Errorf("unpack %s: %w", python.name(), err)
		}
		site := filepath.Join(runtime, "python", "lib", "python3.12", "site-packages")
		for i, w := range wheels {
			if err := unzip(paths[i+1], site); err != nil {
				return indraInstall{}, fmt.Errorf("unpack %s: %w", w.name(), err)
			}
		}
		if err := os.WriteFile(marker, []byte(indraRuntimeID), 0o644); err != nil {
			return indraInstall{}, err
		}
		entries, _ := os.ReadDir(root)
		for _, e := range entries {
			if e.IsDir() && strings.HasPrefix(e.Name(), "indra-") && e.Name() != indraRuntimeID {
				os.RemoveAll(filepath.Join(root, e.Name()))
			}
		}
	}
	// Written at every start, so it is always this binary's.
	if err := os.WriteFile(inst.script, indraWorkerScript, 0o644); err != nil {
		return indraInstall{}, err
	}
	return inst, nil
}

// inside joins name to dir, refusing a name that would land outside it.
func inside(dir, name string) (string, error) {
	p := filepath.Join(dir, name)
	if p != filepath.Clean(dir) && !strings.HasPrefix(p, filepath.Clean(dir)+string(os.PathSeparator)) {
		return "", fmt.Errorf("%q is outside the archive", name)
	}
	return p, nil
}

// untar unpacks a .tar.gz into dir: Python's archive, with its symlinks.
func untar(archive, dir string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		p, err := inside(dir, h.Name)
		if err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			err = os.MkdirAll(p, 0o755)
		case tar.TypeReg:
			err = writeFile(p, tr, h.FileInfo().Mode().Perm())
		case tar.TypeSymlink:
			if err = os.MkdirAll(filepath.Dir(p), 0o755); err == nil {
				err = os.Symlink(h.Linkname, p)
			}
		case tar.TypeLink:
			var target string
			if target, err = inside(dir, h.Linkname); err == nil {
				err = os.Link(target, p)
			}
		}
		if err != nil {
			return err
		}
	}
}

// unzip unpacks a wheel into site-packages: a wheel is a zip of exactly what
// goes there.
func unzip(archive, dir string) error {
	zr, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer zr.Close()
	for _, f := range zr.File {
		p, err := inside(dir, f.Name)
		if err != nil {
			return err
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(p, 0o755); err != nil {
				return err
			}
			continue
		}
		r, err := f.Open()
		if err != nil {
			return err
		}
		err = writeFile(p, r, f.Mode().Perm()|0o644)
		r.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func writeFile(p string, r io.Reader, perm os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, r); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
