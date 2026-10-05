package main

import (
	"archive/tar"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const (
	fakeManifestMT = "application/vnd.docker.distribution.manifest.v2+json"
	fakeConfigMT   = "application/vnd.docker.container.image.v1+json"
	fakeLayerTarMT = "application/vnd.docker.image.rootfs.diff.tar"
	fakeGzipMT     = "application/vnd.docker.image.rootfs.diff.tar.gzip"
)

// fakeReg serves a minimal single-layer busybox-like image over the v2 API.
type fakeReg struct {
	manifestHits int
	blobHits     int
	mfRaw        []byte
	cfgRaw       []byte
	layRaw       []byte
	cfgHex       string
	layHex       string
}

func startFakeRegistry(t *testing.T, gzipLayer bool) (*httptest.Server, *httptest.Server, *fakeReg) {
	t.Helper()
	fr := &fakeReg{}
	layer := buildLayer([]ent{
		{"home/", 65534, 65534, tar.TypeDir, ""},
		{"etc/shadow", 0, 42, tar.TypeReg, "root:shadow-hash\n"},
		{"srv/app.txt", 1000, 1000, tar.TypeReg, "hello\n"},
	})
	diffHex := sha(layer)
	layerMT := fakeLayerTarMT
	fr.layRaw = layer
	if gzipLayer {
		gz, err := gzipBytes(layer)
		if err != nil {
			t.Fatalf("gzipBytes: %v", err)
		}
		fr.layRaw = gz
		layerMT = fakeGzipMT
	}
	fr.layHex = sha(fr.layRaw)

	cfg := map[string]any{
		"architecture": "amd64",
		"os":           "linux",
		"rootfs":       map[string]any{"type": "layers", "diff_ids": []any{"sha256:" + diffHex}},
	}
	fr.cfgRaw, _ = json.Marshal(cfg)
	fr.cfgHex = sha(fr.cfgRaw)

	mf := map[string]any{
		"schemaVersion": 2,
		"mediaType":     fakeManifestMT,
		"config":        map[string]any{"mediaType": fakeConfigMT, "digest": "sha256:" + fr.cfgHex, "size": len(fr.cfgRaw)},
		"layers":        []any{map[string]any{"mediaType": layerMT, "digest": "sha256:" + fr.layHex, "size": len(fr.layRaw)}},
	}
	fr.mfRaw, _ = json.Marshal(mf)

	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v2/busybox/manifests/latest":
			fr.manifestHits++
			w.Header().Set("Content-Type", fakeManifestMT)
			w.Header().Set("Docker-Content-Digest", "sha256:"+sha(fr.mfRaw))
			_, _ = w.Write(fr.mfRaw)
		case r.URL.Path == "/v2/busybox/blobs/sha256:"+fr.cfgHex:
			fr.blobHits++
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(fr.cfgRaw)
		case r.URL.Path == "/v2/busybox/blobs/sha256:"+fr.layHex:
			fr.blobHits++
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(fr.layRaw)
		default:
			http.NotFound(w, r)
		}
	}))
	auth := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"token":"fake-token"}`))
	}))
	t.Cleanup(up.Close)
	t.Cleanup(auth.Close)
	return up, auth, fr
}

func proxyGet(t *testing.T, url string) (*http.Response, []byte) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body %s: %v", url, err)
	}
	return resp, body
}

func TestProxyScrubsManifestAndBlobs(t *testing.T) {
	up, auth, fr := startFakeRegistry(t, false)
	p := newScrubProxy(up.URL, auth.URL, t.TempDir())
	px := httptest.NewServer(http.HandlerFunc(p.handleV2))
	defer px.Close()

	// 1. health endpoint
	resp, _ := proxyGet(t, px.URL+"/v2/")
	if resp.StatusCode != 200 {
		t.Fatalf("GET /v2/ = %d, want 200", resp.StatusCode)
	}

	// 2. manifest: re-signed, digest header consistent, content-type preserved
	resp, body := proxyGet(t, px.URL+"/v2/busybox/manifests/latest")
	if resp.StatusCode != 200 {
		t.Fatalf("manifest = %d", resp.StatusCode)
	}
	if cd := resp.Header.Get("Docker-Content-Digest"); cd != "sha256:"+sha(body) {
		t.Errorf("Docker-Content-Digest %q != body digest", cd)
	}
	if ct := resp.Header.Get("Content-Type"); ct != fakeManifestMT {
		t.Errorf("Content-Type %q, want %q", ct, fakeManifestMT)
	}
	var mf map[string]any
	if err := json.Unmarshal(body, &mf); err != nil {
		t.Fatalf("manifest json: %v", err)
	}
	newLayDig := mf["layers"].([]any)[0].(map[string]any)["digest"].(string)
	newCfgDig := mf["config"].(map[string]any)["digest"].(string)
	if newLayDig == "sha256:"+fr.layHex {
		t.Error("layer digest not re-signed")
	}
	if newCfgDig == "sha256:"+fr.cfgHex {
		t.Error("config digest not re-signed")
	}

	// 3. new layer blob: zeroed + digest self-consistent
	newLayHex := strings.TrimPrefix(newLayDig, "sha256:")
	resp, layBody := proxyGet(t, px.URL+"/v2/busybox/blobs/sha256:"+newLayHex)
	if resp.StatusCode != 200 {
		t.Fatalf("layer blob = %d", resp.StatusCode)
	}
	if sha(layBody) != newLayHex {
		t.Error("layer blob digest mismatch")
	}
	ents := layerEntries(t, layBody)
	if len(ents) < 3 {
		t.Fatalf("layer entries = %d, want >= 3", len(ents))
	}
	for name, eg := range ents {
		if eg != [2]int{0, 0} {
			t.Errorf("layer entry %s uid/gid = %v, want 0/0", name, eg)
		}
	}

	// 4. new config blob: diff_ids updated to cleaned layer
	newCfgHex := strings.TrimPrefix(newCfgDig, "sha256:")
	resp, cfgBody := proxyGet(t, px.URL+"/v2/busybox/blobs/sha256:"+newCfgHex)
	if resp.StatusCode != 200 {
		t.Fatalf("config blob = %d", resp.StatusCode)
	}
	if sha(cfgBody) != newCfgHex {
		t.Error("config blob digest mismatch")
	}
	var cfg map[string]any
	if err := json.Unmarshal(cfgBody, &cfg); err != nil {
		t.Fatalf("config json: %v", err)
	}
	diffs := cfg["rootfs"].(map[string]any)["diff_ids"].([]any)
	if diffs[0] != "sha256:"+sha(layBody) {
		t.Errorf("diff_ids[0] = %v, want digest of cleaned layer", diffs[0])
	}

	// 5. cache: second manifest request must not re-fetch blobs upstream
	blobsBefore := fr.blobHits
	resp, body = proxyGet(t, px.URL+"/v2/busybox/manifests/latest")
	if resp.StatusCode != 200 {
		t.Fatalf("second manifest = %d", resp.StatusCode)
	}
	if sha(body) != sha(fr.mfRaw) && fr.blobHits != blobsBefore {
		t.Errorf("blob upstream hits grew %d -> %d on cached pass", blobsBefore, fr.blobHits)
	}
}

func TestProxyGzipLayer(t *testing.T) {
	up, auth, _ := startFakeRegistry(t, true)
	p := newScrubProxy(up.URL, auth.URL, t.TempDir())
	px := httptest.NewServer(http.HandlerFunc(p.handleV2))
	defer px.Close()

	resp, body := proxyGet(t, px.URL+"/v2/busybox/manifests/latest")
	if resp.StatusCode != 200 {
		t.Fatalf("manifest = %d", resp.StatusCode)
	}
	var mf map[string]any
	if err := json.Unmarshal(body, &mf); err != nil {
		t.Fatalf("manifest json: %v", err)
	}
	newLayDig := mf["layers"].([]any)[0].(map[string]any)["digest"].(string)
	newLayHex := strings.TrimPrefix(newLayDig, "sha256:")

	resp, zBody := proxyGet(t, px.URL+"/v2/busybox/blobs/sha256:"+newLayHex)
	if resp.StatusCode != 200 {
		t.Fatalf("gzip layer blob = %d", resp.StatusCode)
	}
	if len(zBody) < 2 || zBody[0] != 0x1f || zBody[1] != 0x8b {
		t.Fatal("returned layer blob is not gzip")
	}
	if sha(zBody) != newLayHex {
		t.Error("gzip layer digest mismatch")
	}
	raw := mustGunzip(t, zBody)
	ents := layerEntries(t, raw)
	for name, eg := range ents {
		if eg != [2]int{0, 0} {
			t.Errorf("gzip layer entry %s uid/gid = %v, want 0/0", name, eg)
		}
	}
}
