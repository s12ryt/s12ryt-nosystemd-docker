#!/usr/bin/env bash
# test_scrub.sh — tools/docker-scrub.py 單元測試(OCI 映像層 uid/gid 歸零 + 級聯重簽)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tests/lib.sh"

SCRUB="$SCRIPT_DIR/tools/docker-scrub.py"

# 構造最小 OCI layout tar(單層,層內含 65534/42/1000 等非零 uid/gid 條目),
# 回顯 "layer_hex config_hex manifest_hex" 供 bash 斷言舊 hex 替換。
_make_scrub_fixture() { # $1=out.tar
  python3 - "$1" <<'PYEOF'
import hashlib, io, json, sys, tarfile

def sha(b): return hashlib.sha256(b).hexdigest()

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as t:
    def add(name, uid, gid, typ=tarfile.REGTYPE, data=b""):
        ti = tarfile.TarInfo(name)
        ti.uid, ti.gid, ti.uname, ti.gname = uid, gid, "", ""
        ti.size = len(data)
        ti.type = typ
        t.addfile(ti, io.BytesIO(data) if data else None)
    add("home/", 65534, 65534, tarfile.DIRTYPE)
    add("etc/shadow", 0, 42, data=b"root:x:0:0:\n")
    add("srv/app.txt", 1000, 1000, data=b"hello\n")
layer = buf.getvalue()
l_hex = sha(layer)

cfg_obj = {
    "architecture": "amd64", "os": "linux", "config": {},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + l_hex]},
}
cfg = json.dumps(cfg_obj, separators=(",", ":")).encode()
c_hex = sha(cfg)

mf_obj = {
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
               "digest": "sha256:" + c_hex, "size": len(cfg)},
    "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar",
                "digest": "sha256:" + l_hex, "size": len(layer)}],
}
mf = json.dumps(mf_obj, separators=(",", ":")).encode()
m_hex = sha(mf)

index = {"schemaVersion": 2, "manifests": [
    {"mediaType": "application/vnd.oci.image.manifest.v1+json",
     "digest": "sha256:" + m_hex, "size": len(mf)}]}
idx = json.dumps(index, separators=(",", ":")).encode()

legacy = json.dumps([{"Config": "blobs/sha256/" + c_hex,
                      "RepoTags": ["fixture/app:latest"],
                      "Layers": ["blobs/sha256/" + l_hex]}]).encode()

with tarfile.open(sys.argv[1], "w", format=tarfile.GNU_FORMAT) as t:
    def put(name, data):
        ti = tarfile.TarInfo(name); ti.size = len(data); ti.mtime = 0
        t.addfile(ti, io.BytesIO(data))
    put("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
    put("index.json", idx)
    put("manifest.json", legacy)
    put("blobs/sha256/" + l_hex, layer)
    put("blobs/sha256/" + c_hex, cfg)
    put("blobs/sha256/" + m_hex, mf)
    put("repositories", b"{}")

print(l_hex, c_hex, m_hex)
PYEOF
}

test_scrub_zeroes_layer_ids() {
  local T; T="$(t_tmpdir)"
  local fix="$T/fix.tar" out="$T/out.tar" l_old c_old m_old
  read -r l_old c_old m_old < <(_make_scrub_fixture "$fix")
  assert_file_exists "fixture 已建立" "$fix"

  _t_assert
  if python3 "$SCRUB" "$fix" "$out" >"$T/scrub.out" 2>"$T/scrub.err"; then
    _t_pass
  else
    _t_fail "docker-scrub.py 執行失敗: $(head -2 "$T/scrub.err")"
    return 0
  fi
  assert_file_exists "輸出 tar 已建立" "$out"

  local vout
  vout="$(python3 - "$out" "$l_old" "$c_old" <<'PYEOF'
import hashlib, io, json, sys, tarfile
out, l_old, c_old = sys.argv[1], sys.argv[2], sys.argv[3]
def sha(b): return hashlib.sha256(b).hexdigest()
m = {}
with tarfile.open(out) as t:
    for x in t:
        if x.isreg():
            m[x.name.removeprefix("./")] = t.extractfile(x).read()
idx = json.loads(m["index.json"])
mf_hex = idx["manifests"][0]["digest"].split(":", 1)[1]
mf = json.loads(m["blobs/sha256/" + mf_hex])
cfg_hex = mf["config"]["digest"].split(":", 1)[1]
cfg = json.loads(m["blobs/sha256/" + cfg_hex])
lay_hex = mf["layers"][0]["digest"].split(":", 1)[1]
layer = m["blobs/sha256/" + lay_hex]
bad = 0
with tarfile.open(fileobj=io.BytesIO(layer)) as t:
    for x in t:
        if x.uid != 0 or x.gid != 0:
            bad += 1
print("ZERO_OK" if bad == 0 else "ZERO_BAD %d" % bad)
print("DIFF_OK" if cfg["rootfs"]["diff_ids"][0] == "sha256:" + sha(layer) else "DIFF_BAD")
print("CFG_OK" if sha(m["blobs/sha256/" + cfg_hex]) == cfg_hex else "CFG_BAD")
print("MF_OK" if sha(m["blobs/sha256/" + mf_hex]) == mf_hex else "MF_BAD")
legacy = m.get("manifest.json", b"")
ok = l_old.encode() not in legacy and c_old.encode() not in legacy
print("LEG_OK" if ok else "LEG_BAD")
print("NOOLD_OK" if ("blobs/sha256/" + l_old) not in m else "NOOLD_BAD")
PYEOF
)"
  assert_contains "層內 uid/gid 全歸零" "ZERO_OK" "$vout"
  assert_contains "diff_id 與新層 sha256 一致" "DIFF_OK" "$vout"
  assert_contains "config digest 自洽" "CFG_OK" "$vout"
  assert_contains "manifest digest 自洽" "MF_OK" "$vout"
  assert_contains "legacy manifest.json 舊 hex 已替換" "LEG_OK" "$vout"
  assert_contains "舊層 blob 不殘留" "NOOLD_OK" "$vout"
}

test_scrub_rejects_bad_input() {
  local T; T="$(t_tmpdir)"
  printf 'not a tar at all' > "$T/junk.tar"
  assert_fails "非 tar 輸入應失敗" python3 "$SCRUB" "$T/junk.tar" "$T/x.tar"
  assert_fails "缺少參數應失敗" python3 "$SCRUB"
}
