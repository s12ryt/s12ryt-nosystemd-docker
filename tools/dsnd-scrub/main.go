package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// scrubFile reads an OCI-layout docker-archive tar, zeroes uid/gid of every
// entry in every layer, re-signs the digest chain (layer -> config diff_ids
// -> manifest -> index -> legacy manifest.json) and writes a new archive.
func scrubFile(src, dst string) error {
	raw, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("read %s: %w", src, err)
	}
	members, err := readMembers(bytes.NewReader(raw))
	if err != nil {
		return err
	}
	idxRaw, ok := members["index.json"]
	if !ok {
		return fmt.Errorf("invalid archive: index.json not found (not an OCI/docker-save tar?)")
	}
	var index map[string]any
	if err := json.Unmarshal(idxRaw, &index); err != nil {
		return fmt.Errorf("parse index.json: %w", err)
	}
	manifests, _ := index["manifests"].([]any)
	if len(manifests) == 0 {
		return fmt.Errorf("index.json has no manifests")
	}
	hexMap := map[string]string{} // old hex -> new hex (bytes replace for legacy)

	for mi := range manifests {
		mref, _ := manifests[mi].(map[string]any)
		mfHex, err := refHex(mref)
		if err != nil {
			return err
		}
		mfRaw, ok := blob(members, mfHex)
		if !ok {
			return fmt.Errorf("manifest blob %s not found", short(mfHex))
		}
		var mf map[string]any
		if err := json.Unmarshal(mfRaw, &mf); err != nil {
			return fmt.Errorf("parse manifest %s: %w", short(mfHex), err)
		}
		cfgRef, _ := mf["config"].(map[string]any)
		cfgHex, err := refHex(cfgRef)
		if err != nil {
			return err
		}
		cfgRaw, ok := blob(members, cfgHex)
		if !ok {
			return fmt.Errorf("config blob %s not found", short(cfgHex))
		}
		var cfg map[string]any
		if err := json.Unmarshal(cfgRaw, &cfg); err != nil {
			return fmt.Errorf("parse config %s: %w", short(cfgHex), err)
		}
		rootfs, _ := cfg["rootfs"].(map[string]any)
		diffIDs, _ := rootfs["diff_ids"].([]any)

		layers, _ := mf["layers"].([]any)
		if len(layers) != len(diffIDs) {
			return fmt.Errorf("manifest %s: layers(%d) != diff_ids(%d)", short(mfHex), len(layers), len(diffIDs))
		}
		for li := range layers {
			lref, _ := layers[li].(map[string]any)
			lHex, err := refHex(lref)
			if err != nil {
				return err
			}
			lRaw, ok := blob(members, lHex)
			if !ok {
				return fmt.Errorf("layer blob %s not found", short(lHex))
			}
			mt, _ := lref["mediaType"].(string)
			var newBlob []byte
		var newDiffHex string
			switch {
			case strings.HasSuffix(mt, "gzip"):
				clean, err := gunzipClean(lRaw)
				if err != nil {
					return fmt.Errorf("layer %s: %w", short(lHex), err)
				}
				newDiffHex = hashBytes(clean)
				out, err := gzipBytes(clean)
				if err != nil {
					return fmt.Errorf("layer %s: %w", short(lHex), err)
				}
				newBlob = out
			case strings.HasSuffix(mt, "tar"):
				clean, err := cleanTar(lRaw)
				if err != nil {
					return fmt.Errorf("layer %s: %w", short(lHex), err)
				}
				newBlob = clean
				newDiffHex = hashBytes(clean)
			default:
				return fmt.Errorf("layer %s: unsupported mediaType %q (head %q)", short(lHex), mt, head(lRaw))
			}
			newHex := hashBytes(newBlob)
			setDigestSize(lref, newHex, int64(len(newBlob)))
			diffIDs[li] = "sha256:" + newDiffHex
			replaceBlob(members, lHex, newHex, newBlob)
			hexMap[lHex] = newHex
		}
		// config
		cfgOut, err := compactJSON(cfg)
		if err != nil {
			return fmt.Errorf("encode config: %w", err)
		}
		newCfgHex := hashBytes(cfgOut)
		setDigestSize(cfgRef, newCfgHex, int64(len(cfgOut)))
		replaceBlob(members, cfgHex, newCfgHex, cfgOut)
		hexMap[cfgHex] = newCfgHex

		// manifest
		mfOut, err := compactJSON(mf)
		if err != nil {
			return fmt.Errorf("encode manifest: %w", err)
		}
		newMfHex := hashBytes(mfOut)
		setDigestSize(mref, newMfHex, int64(len(mfOut)))
		replaceBlob(members, mfHex, newMfHex, mfOut)
		hexMap[mfHex] = newMfHex
		manifests[mi] = mref
	}

	// index rewrite
	idxOut, err := compactJSON(index)
	if err != nil {
		return fmt.Errorf("encode index.json: %w", err)
	}
	members["index.json"] = idxOut

	// legacy manifest.json (required by docker load): byte-replace digests
	if leg, ok := members["manifest.json"]; ok {
		replaced := leg
		for oldH, newH := range hexMap {
			replaced = bytes.ReplaceAll(replaced, []byte(oldH), []byte(newH))
		}
		members["manifest.json"] = replaced
	} else {
		return fmt.Errorf("invalid archive: legacy manifest.json not found (docker load requires it)")
	}

	return writeArchive(members, dst)
}

func refHex(ref map[string]any) (string, error) {
	if ref == nil {
		return "", fmt.Errorf("missing digest reference")
	}
	d, _ := ref["digest"].(string)
	parts := strings.SplitN(d, ":", 2)
	if len(parts) != 2 || parts[0] != "sha256" || len(parts[1]) != 64 {
		return "", fmt.Errorf("bad digest %q", d)
	}
	return parts[1], nil
}

func setDigestSize(ref map[string]any, hexStr string, size int64) {
	ref["digest"] = "sha256:" + hexStr
	ref["size"] = size
}

func blob(members map[string][]byte, hexStr string) ([]byte, bool) {
	b, ok := members["blobs/sha256/"+hexStr]
	return b, ok
}

func replaceBlob(members map[string][]byte, oldHex, newHex string, data []byte) {
	delete(members, "blobs/sha256/"+oldHex)
	members["blobs/sha256/"+newHex] = data
}

func hashBytes(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func compactJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

func gunzipClean(raw []byte) ([]byte, error) {
	zr, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("gunzip: %w", err)
	}
	defer zr.Close()
	unc, err := io.ReadAll(zr)
	if err != nil {
		return nil, fmt.Errorf("gunzip read: %w", err)
	}
	return cleanTar(unc)
}

func gzipBytes(clean []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Header.ModTime = time.Time{} // deterministic output
	if _, err := zw.Write(clean); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// cleanTar rewrites every entry with uid/gid 0 (uname/gname root),
// preserving names, modes, types and contents.
func cleanTar(raw []byte) ([]byte, error) {
	tr := tar.NewReader(bytes.NewReader(raw))
	var out bytes.Buffer
	tw := tar.NewWriter(&out)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("tar read: %w", err)
		}
		hdr.Uid = 0
		hdr.Gid = 0
		hdr.Uname = "root"
		hdr.Gname = "root"
		hdr.Format = tar.FormatGNU
		if err := tw.WriteHeader(hdr); err != nil {
			return nil, fmt.Errorf("tar write header %s: %w", hdr.Name, err)
		}
		if hdr.Typeflag == tar.TypeReg {
			if _, err := io.Copy(tw, tr); err != nil {
				return nil, fmt.Errorf("tar copy %s: %w", hdr.Name, err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func readMembers(r io.Reader) (map[string][]byte, error) {
	tr := tar.NewReader(r)
	members := map[string][]byte{}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("not a tar archive: %w", err)
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		name := strings.TrimPrefix(hdr.Name, "./")
		data, err := io.ReadAll(tr)
		if err != nil {
			return nil, fmt.Errorf("read member %s: %w", name, err)
		}
		members[name] = data
	}
	if len(members) == 0 {
		return nil, fmt.Errorf("not a tar archive (no regular members)")
	}
	return members, nil
}

func writeArchive(members map[string][]byte, dst string) error {
	f, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("create %s: %w", dst, err)
	}
	defer f.Close()
	tw := tar.NewWriter(f)
	names := make([]string, 0, len(members))
	for n := range members {
		if strings.HasPrefix(n, "blobs/") {
			continue
		}
		names = append(names, n)
	}
	sortStrings(names)
	blobNames := make([]string, 0)
	for n := range members {
		if strings.HasPrefix(n, "blobs/") {
			blobNames = append(blobNames, n)
		}
	}
	sortStrings(blobNames)
	names = append(names, blobNames...)
	for _, n := range names {
		data := members[n]
		hdr := &tar.Header{Name: n, Mode: 0o644, Size: int64(len(data)), Format: tar.FormatGNU}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if _, err := tw.Write(data); err != nil {
			return err
		}
	}
	return tw.Close()
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

func head(b []byte) string {
	if len(b) > 16 {
		b = b[:16]
	}
	return fmt.Sprintf("%x", b)
}

func short(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

func usage() {
	fmt.Fprint(os.Stderr, `dsnd-scrub — docker image uid/gid scrubber for Lchown-EPERM sandboxes

Usage:
  dsnd-scrub file <in.tar> <out.tar>   Scrub an OCI-layout docker archive
                                       (uid/gid -> 0:0, digest chain re-signed)
  dsnd-scrub proxy                     Run local pull-through registry proxy
                                       (scrubs layers on the fly; env-tunable)
  dsnd-scrub -h | --help               Show this help

Proxy env: DSND_PROXY_ADDR (127.0.0.1:5200), DSND_PROXY_UPSTREAM
(registry-1.docker.io), DSND_PROXY_AUTH (auth.docker.io/token),
DSND_PROXY_CACHE (/var/cache/dsnd-scrub-proxy).
`)
}

func run(args []string) int {
	if len(args) == 0 {
		usage()
		return 2
	}
	switch args[0] {
	case "-h", "--help", "help":
		usage()
		return 0
	case "file":
		if len(args) != 3 {
			fmt.Fprintln(os.Stderr, "error: file subcommand needs <in.tar> <out.tar>")
			return 2
		}
		if err := scrubFile(args[1], args[2]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			return 1
		}
		return 0
	case "proxy":
		return runProxy()
	default:
		fmt.Fprintf(os.Stderr, "error: unknown subcommand %q\n\n", args[0])
		usage()
		return 2
	}
}

func main() {
	os.Exit(run(os.Args[1:]))
}
