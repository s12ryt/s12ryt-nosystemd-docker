package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// ---- fixture helpers ----

type ent struct {
	name              string
	uid, gid          int
	typ               byte
	data              string
}

func buildLayer(entries []ent) []byte {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, e := range entries {
		hdr := &tar.Header{Name: e.name, Uid: e.uid, Gid: e.gid, Typeflag: e.typ, Format: tar.FormatGNU}
		if e.typ == tar.TypeDir {
			hdr.Mode = 0o755
		} else {
			hdr.Mode = 0o644
			hdr.Size = int64(len(e.data))
		}
		_ = tw.WriteHeader(hdr)
		if e.typ == tar.TypeReg {
			_, _ = tw.Write([]byte(e.data))
		}
	}
	_ = tw.Close()
	return buf.Bytes()
}

func sha(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// buildArchive assembles an OCI-layout docker-save tar with one manifest,
// one config, and layers derived from entries (uncompressed or gzip).
func buildArchive(t *testing.T, layers [][]byte, gzipLayers bool) ([]byte, []string, []string, []string) {
	t.Helper()
	layerHex := make([]string, len(layers))
	diffHex := make([]string, len(layers))
	blobs := map[string][]byte{}
	for i, l := range layers {
		diffHex[i] = sha(l)
		if gzipLayers {
			var zb bytes.Buffer
			zw := gzip.NewWriter(&zb)
			_, _ = zw.Write(l)
			_ = zw.Close()
			l = zb.Bytes()
		}
		layerHex[i] = sha(l)
		blobs[layerHex[i]] = l
	}
	diffs := make([]any, len(layers))
	for i, d := range diffHex {
		diffs[i] = "sha256:" + d
	}
	cfg := map[string]any{"architecture": "amd64", "os": "linux", "rootfs": map[string]any{"type": "layers", "diff_ids": diffs}}
	cfgRaw, _ := json.Marshal(cfg)
	cfgHex := sha(cfgRaw)
	blobs[cfgHex] = cfgRaw

	layerRefs := make([]any, len(layers))
	for i, h := range layerHex {
		mt := "application/vnd.oci.image.layer.v1.tar"
		if gzipLayers {
			mt = "application/vnd.docker.image.rootfs.diff.tar.gzip"
		}
		layerRefs[i] = map[string]any{"mediaType": mt, "digest": "sha256:" + h, "size": len(blobs[h])}
	}
	mf := map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.manifest.v1+json",
		"config":        map[string]any{"mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:" + cfgHex, "size": len(cfgRaw)},
		"layers":        layerRefs,
	}
	mfRaw, _ := json.Marshal(mf)
	mfHex := sha(mfRaw)
	blobs[mfHex] = mfRaw

	index := map[string]any{"schemaVersion": 2, "manifests": []any{map[string]any{
		"mediaType": "application/vnd.oci.image.manifest.v1+json",
		"digest":    "sha256:" + mfHex, "size": len(mfRaw),
		"annotations": map[string]any{"io.docker.reference.name": "fixture/app:latest"},
	}}}
	idxRaw, _ := json.Marshal(index)
	legacy := `[{"Config":"blobs/sha256/` + cfgHex + `","RepoTags":["fixture/app:latest"],"Layers":["blobs/sha256/` + layerHex[0] + `"]}]`

	var out bytes.Buffer
	tw := tar.NewWriter(&out)
	add := func(name string, data []byte) {
		_ = tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data)), Format: tar.FormatGNU})
		_, _ = tw.Write(data)
	}
	add("oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))
	add("index.json", idxRaw)
	add("manifest.json", []byte(legacy))
	add("repositories", []byte(`{"fixture/app":{"latest":"blobs/sha256/`+mfHex+`"}}`))
	for h, b := range blobs {
		add("blobs/sha256/"+h, b)
	}
	_ = tw.Close()
	return out.Bytes(), layerHex, []string{cfgHex}, []string{mfHex}
}

func readArchive(t *testing.T, path string) map[string][]byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	m, err := readMembers(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("parse output: %v", err)
	}
	return m
}

func layerEntries(t *testing.T, raw []byte) map[string][2]int {
	t.Helper()
	tr := tar.NewReader(bytes.NewReader(raw))
	got := map[string][2]int{}
	for {
		hdr, err := tr.Next()
		if err != nil {
			break
		}
		got[hdr.Name] = [2]int{hdr.Uid, hdr.Gid}
	}
	return got
}

// ---- tests ----

func TestScrubFileZeroesAndResigns(t *testing.T) {
	layer := buildLayer([]ent{
		{"home/", 65534, 65534, tar.TypeDir, ""},
		{"etc/shadow", 0, 42, tar.TypeReg, "root:shadow-hash\n"},
		{"srv/app.txt", 1000, 1000, tar.TypeReg, "hello\n"},
	})
	arc, layerHex, cfgHex, mfHex := buildArchive(t, [][]byte{layer}, false)
	dir := t.TempDir()
	src := filepath.Join(dir, "in.tar")
	dst := filepath.Join(dir, "out.tar")
	if err := os.WriteFile(src, arc, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := scrubFile(src, dst); err != nil {
		t.Fatalf("scrubFile: %v", err)
	}
	m := readArchive(t, dst)

	// 1. layer zeroed
	var newLayer []byte
	var newLayerHex string
	for n, b := range m {
		if len(n) == len("blobs/sha256/")+64 && n != "blobs/sha256/"+cfgHex[0] {
			// candidates: layer / config / manifest; identify by content (tar magic)
			if len(b) > 257 && b[257] == 'u' && b[258] == 's' && b[259] == 't' && b[260] == 'a' && b[261] == 'r' {
				newLayer = b
				newLayerHex = n[len("blobs/sha256/"):]
			}
		}
	}
	if newLayer == nil {
		t.Fatal("no layer blob with tar magic found in output")
	}
	ents := layerEntries(t, newLayer)
	for name, want := range map[string][2]int{"home/": {0, 0}, "etc/shadow": {0, 0}, "srv/app.txt": {0, 0}} {
		if got := ents[name]; got != want {
			t.Errorf("entry %s uid/gid = %v, want 0/0", name, got)
		}
	}
	// 2. layer digest consistent
	if sha(newLayer) != newLayerHex {
		t.Error("layer blob digest mismatch")
	}
	// 3. diff_ids == uncompressed layer digest
	var idx map[string]any
	_ = json.Unmarshal(m["index.json"], &idx)
	mfs := idx["manifests"].([]any)
	mfDigest := mfs[0].(map[string]any)["digest"].(string)
	mfNewHex := mfDigest[len("sha256:"):]
	mfRaw, ok := m["blobs/sha256/"+mfNewHex]
	if !ok {
		t.Fatal("new manifest blob missing")
	}
	if sha(mfRaw) != mfNewHex {
		t.Error("manifest digest mismatch")
	}
	var mf map[string]any
	_ = json.Unmarshal(mfRaw, &mf)
	cfgDigest := mf["config"].(map[string]any)["digest"].(string)
	cfgNewHex := cfgDigest[len("sha256:"):]
	cfgRaw2 := m["blobs/sha256/"+cfgNewHex]
	if cfgRaw2 == nil || sha(cfgRaw2) != cfgNewHex {
		t.Error("config digest mismatch")
	}
	var cfg2 map[string]any
	_ = json.Unmarshal(cfgRaw2, &cfg2)
	diffs := cfg2["rootfs"].(map[string]any)["diff_ids"].([]any)
	if diffs[0] != "sha256:"+sha(newLayer) {
		t.Errorf("diff_ids[0] = %v, want sha256 of cleaned layer", diffs[0])
	}
	// 4. legacy manifest.json updated
	leg := string(m["manifest.json"])
	if bytes.Contains(m["manifest.json"], []byte(layerHex[0])) || bytes.Contains(m["manifest.json"], []byte(cfgHex[0])) {
		t.Error("legacy manifest.json still references old digests")
	}
	if !bytes.Contains(m["manifest.json"], []byte(cfgNewHex)) {
		t.Error("legacy manifest.json missing new config digest")
	}
	_ = leg
	// 5. old blobs gone
	for _, h := range append(append(layerHex, cfgHex...), mfHex...) {
		if _, exists := m["blobs/sha256/"+h]; exists {
			t.Errorf("old blob %s still present", h[:12])
		}
	}
}

func TestScrubFileGzipLayer(t *testing.T) {
	layer := buildLayer([]ent{{"home/", 65534, 65534, tar.TypeDir, ""}, {"a.txt", 5, 5, tar.TypeReg, "x"}})
	arc, _, _, _ := buildArchive(t, [][]byte{layer}, true)
	dir := t.TempDir()
	src := filepath.Join(dir, "in.tar")
	dst := filepath.Join(dir, "out.tar")
	if err := os.WriteFile(src, arc, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := scrubFile(src, dst); err != nil {
		t.Fatalf("scrubFile gzip: %v", err)
	}
	m := readArchive(t, dst)
	// find gzip layer blob (magic 1f 8b)
	var found bool
	for n, b := range m {
		if len(b) > 2 && b[0] == 0x1f && b[1] == 0x8b {
			found = true
			zr, err := gzip.NewReader(bytes.NewReader(b))
			if err != nil {
				t.Fatalf("output layer not gunzip-able: %v", err)
			}
			_ = zr.Close()
			hexName := n[len("blobs/sha256/"):]
			if sha(b) != hexName {
				t.Error("gzip layer digest mismatch")
			}
			ents := layerEntries(t, mustGunzip(t, b))
			if ents["home/"] != [2]int{0, 0} {
				t.Error("gzip layer home/ not zeroed")
			}
		}
	}
	if !found {
		t.Fatal("no gzip layer in output")
	}
}

func mustGunzip(t *testing.T, b []byte) []byte {
	t.Helper()
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	var out bytes.Buffer
	buf := make([]byte, 4096)
	for {
		n, err := zr.Read(buf)
		out.Write(buf[:n])
		if err != nil {
			break
		}
	}
	return out.Bytes()
}

func TestScrubFileRejectsBadInput(t *testing.T) {
	dir := t.TempDir()
	notTar := filepath.Join(dir, "not.tar")
	if err := os.WriteFile(notTar, []byte("this is not a tar file at all"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := scrubFile(notTar, filepath.Join(dir, "o.tar")); err == nil {
		t.Error("expected error for non-tar input")
	}
	// tar without index.json
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	_ = tw.WriteHeader(&tar.Header{Name: "random.txt", Mode: 0o644, Size: 3})
	_, _ = tw.Write([]byte("abc"))
	_ = tw.Close()
	yesTar := filepath.Join(dir, "yes.tar")
	if err := os.WriteFile(yesTar, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := scrubFile(yesTar, filepath.Join(dir, "o2.tar")); err == nil {
		t.Error("expected error for tar without index.json")
	}
}
