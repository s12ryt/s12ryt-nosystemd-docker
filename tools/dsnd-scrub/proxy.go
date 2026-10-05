package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// scrubProxy is a local pull-through Docker Registry v2 proxy that zeroes
// uid/gid of every layer on the fly and re-signs the digest chain, so a
// dockerd running in single-mapping userns mode (Lchown(x,0,0) only) can
// pull any image transparently.
//
// Environment knobs (all overridable for tests):
//
//	DSND_PROXY_ADDR     listen address          (default 127.0.0.1:5200)
//	DSND_PROXY_UPSTREAM upstream registry       (default https://registry-1.docker.io)
//	DSND_PROXY_AUTH     token endpoint base     (default https://auth.docker.io/token)
//	DSND_PROXY_CACHE    blob cache directory    (default /var/cache/dsnd-scrub-proxy)
type scrubProxy struct {
	upstream string
	authBase string
	cacheDir string
	client   *http.Client

	mu     sync.Mutex
	tokens map[string]string // repo -> bearer token
	hits   map[string]int    // upstream fetch counters (tests)
}

func newScrubProxy(upstream, authBase, cacheDir string) *scrubProxy {
	return &scrubProxy{
		upstream: strings.TrimSuffix(upstream, "/"),
		authBase: strings.TrimSuffix(authBase, "/"),
		cacheDir: cacheDir,
		client:   &http.Client{Timeout: 120 * time.Second},
		tokens:   map[string]string{},
		hits:     map[string]int{},
	}
}

func runProxy() int {
	addr := envOr("DSND_PROXY_ADDR", "127.0.0.1:5200")
	upstream := envOr("DSND_PROXY_UPSTREAM", "https://registry-1.docker.io")
	auth := envOr("DSND_PROXY_AUTH", "https://auth.docker.io/token")
	cache := envOr("DSND_PROXY_CACHE", "/var/cache/dsnd-scrub-proxy")
	if err := os.MkdirAll(cache, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "error: create cache dir %s: %v\n", cache, err)
		return 1
	}
	p := newScrubProxy(upstream, auth, cache)
	fmt.Fprintf(os.Stderr, "[dsnd-scrub] proxy listening on http://%s (upstream %s, cache %s)\n", addr, upstream, cache)
	mux := http.NewServeMux()
	mux.HandleFunc("/v2/", p.handleV2)
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintf(os.Stderr, "error: proxy: %v\n", err)
		return 1
	}
	return 0
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// handleV2 routes /v2/, /v2/<name>/manifests/<ref>, /v2/<name>/blobs/<digest>.
func (p *scrubProxy) handleV2(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v2/")
	if path == "" || path == "/" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("{}"))
		return
	}
	// Split <name>/manifests/<ref> or <name>/blobs/<digest>; name may contain slashes.
	i := strings.LastIndex(path, "/manifests/")
	j := strings.LastIndex(path, "/blobs/")
	switch {
	case i >= 0:
		name, ref := path[:i], path[i+len("/manifests/"):]
		p.serveManifest(w, r, name, ref)
	case j >= 0:
		name, dig := path[:j], path[j+len("/blobs/"):]
		p.serveBlob(w, r, name, dig)
	default:
		http.NotFound(w, r)
	}
}

const manifestAccept = "application/vnd.docker.distribution.manifest.list.v2+json," +
	"application/vnd.docker.distribution.manifest.v2+json," +
	"application/vnd.oci.image.index.v1+json," +
	"application/vnd.oci.image.manifest.v1+json"

func (p *scrubProxy) serveManifest(w http.ResponseWriter, r *http.Request, name, ref string) {
	body, dig, ctype, err := p.scrubManifest(name, ref)
	if err != nil {
		http.Error(w, "proxy: "+err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Docker-Content-Digest", "sha256:"+dig)
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(body)
	}
}

// scrubManifest pulls (and scrubs) the manifest for name:ref, returning the
// re-signed manifest bytes, its new digest and the original content type.
func (p *scrubProxy) scrubManifest(name, ref string) ([]byte, string, string, error) {
	status, ctype, body, err := p.upstreamGet(name, "manifests", ref, manifestAccept)
	if err != nil {
		return nil, "", "", fmt.Errorf("upstream manifest %s:%s: %w", name, ref, err)
	}
	if status != http.StatusOK {
		return nil, "", "", fmt.Errorf("upstream manifest %s:%s: status %d", name, ref, status)
	}
	var mf map[string]any
	if err := json.Unmarshal(body, &mf); err != nil {
		return nil, "", "", fmt.Errorf("parse manifest: %w", err)
	}
	if _, isList := mf["manifests"]; isList {
		if err := p.scrubIndex(name, mf); err != nil {
			return nil, "", "", err
		}
	} else if err := p.scrubImageManifest(name, mf); err != nil {
		return nil, "", "", err
	}
	out, err := compactJSON(mf)
	if err != nil {
		return nil, "", "", err
	}
	dig := hashBytes(out)
	p.storeBlob(dig, out)
	return out, dig, ctype, nil
}

// scrubIndex re-signs a manifest list / OCI index: every child manifest is
// fetched, scrubbed and re-signed, then the index references are updated.
func (p *scrubProxy) scrubIndex(name string, idx map[string]any) error {
	kids, _ := idx["manifests"].([]any)
	for i := range kids {
		ref, _ := kids[i].(map[string]any)
		if ref == nil {
			continue
		}
		d, _ := ref["digest"].(string)
		parts := strings.SplitN(d, ":", 2)
		if len(parts) != 2 {
			return fmt.Errorf("index child digest %q", d)
		}
		child, _, _, err := p.scrubManifest(name, parts[1]) // by digest
		if err != nil {
			return err
		}
		newHex := hashBytes(child)
		setDigestSize(ref, newHex, int64(len(child)))
	}
	return nil
}

// scrubImageManifest pulls config + layers, scrubs each layer tar, updates
// diff_ids / digests / sizes and re-signs config first, then the manifest.
func (p *scrubProxy) scrubImageManifest(name string, mf map[string]any) error {
	cfgRef, _ := mf["config"].(map[string]any)
	cfgHex, err := refHex(cfgRef)
	if err != nil {
		return err
	}
	cfgRaw, err := p.fetchOrScrubbedBlob(name, cfgHex)
	if err != nil {
		return fmt.Errorf("config blob: %w", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(cfgRaw, &cfg); err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	rootfs, _ := cfg["rootfs"].(map[string]any)
	diffIDs, _ := rootfs["diff_ids"].([]any)

	layers, _ := mf["layers"].([]any)
	if len(layers) != len(diffIDs) {
		return fmt.Errorf("layers(%d) != diff_ids(%d)", len(layers), len(diffIDs))
	}
	for li := range layers {
		lref, _ := layers[li].(map[string]any)
		lHex, err := refHex(lref)
		if err != nil {
			return err
		}
		lRaw, err := p.fetchOrScrubbedBlob(name, lHex)
		if err != nil {
			return fmt.Errorf("layer blob: %w", err)
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
			newBlob, err = gzipBytes(clean)
			if err != nil {
				return fmt.Errorf("layer %s: %w", short(lHex), err)
			}
		case strings.HasSuffix(mt, "tar"):
			clean, err := cleanTar(lRaw)
			if err != nil {
				return fmt.Errorf("layer %s: %w", short(lHex), err)
			}
			newBlob = clean
			newDiffHex = hashBytes(clean)
		default:
			return fmt.Errorf("layer %s: unsupported mediaType %q", short(lHex), mt)
		}
		newHex := hashBytes(newBlob)
		setDigestSize(lref, newHex, int64(len(newBlob)))
		diffIDs[li] = "sha256:" + newDiffHex
		p.storeBlob(newHex, newBlob)
		p.storeBlob(lHex, newBlob) // cache under upstream key too: idempotent re-scrub on hit
	}
	cfgOut, err := compactJSON(cfg)
	if err != nil {
		return err
	}
	newCfgHex := hashBytes(cfgOut)
	setDigestSize(cfgRef, newCfgHex, int64(len(cfgOut)))
	p.storeBlob(newCfgHex, cfgOut)
	p.storeBlob(cfgHex, cfgOut) // cache under upstream key too
	return nil
}

// fetchOrScrubbedBlob pulls a raw blob from upstream (layers arrive un-scrubbed
// on first request; cached copies are already scrubbed and pass through
// cleanTar unchanged because uid/gid are already 0).
func (p *scrubProxy) fetchOrScrubbedBlob(name, hexStr string) ([]byte, error) {
	if b, ok := p.loadBlob(hexStr); ok {
		return b, nil
	}
	status, _, body, err := p.upstreamGet(name, "blobs", "sha256:"+hexStr, "")
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("upstream blob %s: status %d", short(hexStr), status)
	}
	return body, nil
}

func (p *scrubProxy) serveBlob(w http.ResponseWriter, r *http.Request, name, digest string) {
	parts := strings.SplitN(digest, ":", 2)
	if len(parts) != 2 || len(parts[1]) != 64 {
		http.Error(w, "bad digest", http.StatusBadRequest)
		return
	}
	b, ok := p.loadBlob(parts[1])
	if !ok {
		// Not scrubbed yet (daemon asks for the OLD digest): fetch raw,
		// scrub, and serve the scrubbed bytes under the requested digest so
		// the daemon-side chain stays consistent with the re-signed manifest.
		raw, err := p.fetchOrScrubbedBlob(name, parts[1])
		if err != nil {
			http.Error(w, "proxy: "+err.Error(), http.StatusBadGateway)
			return
		}
		mt := http.DetectContentType(raw)
		var clean []byte
		isGzip := strings.Contains(mt, "gzip") || (len(raw) > 1 && raw[0] == 0x1f && raw[1] == 0x8b)
		if isGzip {
			c, err := gunzipClean(raw)
			if err != nil {
				http.Error(w, "proxy: scrub: "+err.Error(), http.StatusInternalServerError)
				return
			}
			clean, err = gzipBytes(c)
			if err != nil {
				http.Error(w, "proxy: scrub: "+err.Error(), http.StatusInternalServerError)
				return
			}
		} else {
			c, err := cleanTar(raw)
			if err != nil {
				http.Error(w, "proxy: scrub: "+err.Error(), http.StatusInternalServerError)
				return
			}
			clean = c
		}
		p.storeBlob(parts[1], clean) // serve scrubbed bytes under requested key
		b = clean
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Docker-Content-Digest", digest)
	w.Header().Set("Content-Length", fmt.Sprint(len(b)))
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(b)
	}
}

// upstreamGet performs a GET against the upstream v2 API with bearer token.
func (p *scrubProxy) upstreamGet(name, kind, ref, accept string) (int, string, []byte, error) {
	url := fmt.Sprintf("%s/v2/%s/%s/%s", p.upstream, name, kind, ref)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return 0, "", nil, err
	}
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	tok, err := p.token(name)
	if err != nil {
		return 0, "", nil, fmt.Errorf("auth token: %w", err)
	}
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return 0, "", nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, "", nil, err
	}
	p.mu.Lock()
	p.hits["upstream:"+name+"/"+kind]++
	p.mu.Unlock()
	return resp.StatusCode, resp.Header.Get("Content-Type"), body, nil
}

// token fetches (and caches) an anonymous pull token for the repository.
func (p *scrubProxy) token(name string) (string, error) {
	p.mu.Lock()
	if t, ok := p.tokens[name]; ok {
		p.mu.Unlock()
		return t, nil
	}
	p.mu.Unlock()
	url := fmt.Sprintf("%s?service=registry.docker.io&scope=repository:%s:pull", p.authBase, name)
	resp, err := p.client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var tr struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil {
		return "", err
	}
	tok := tr.Token
	if tok == "" {
		tok = tr.AccessToken
	}
	p.mu.Lock()
	p.tokens[name] = tok
	p.mu.Unlock()
	return tok, nil
}

// storeBlob / loadBlob: content-addressed on-disk cache.
func (p *scrubProxy) storeBlob(hexStr string, data []byte) {
	dir := filepath.Join(p.cacheDir, "sha256")
	_ = os.MkdirAll(dir, 0o755)
	path := filepath.Join(dir, hexStr)
	if _, err := os.Stat(path); err == nil {
		return
	}
	_ = os.WriteFile(path, data, 0o644)
}

func (p *scrubProxy) loadBlob(hexStr string) ([]byte, bool) {
	path := filepath.Join(p.cacheDir, "sha256", hexStr)
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	return b, true
}
