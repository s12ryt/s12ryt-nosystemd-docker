#!/usr/bin/env python3
"""docker-scrub.py — Rewrite an OCI-layout docker archive with every layer
entry uid/gid zeroed, then cascade re-sign the content-addressed blobs.

Purpose: on unprivileged DinD (dockerd wrapped in unshare -Ur, single-id
mapping), `docker pull` dies with
    failed to Lchown "home" for UID 65534 ... invalid argument
because layer tars contain entries owned outside the tiny id map.
Zeroing every uid/gid to 0:0 keeps Lchown inside the mapping, and
`docker load` of the scrubbed archive succeeds.

Content-addressed blobs force a cascade re-sign:
  layer blob (tar or gzip tar) -> cleaned -> new blob digest
                                 -> new uncompressed sha256 -> new diff_id
  config json  (rootfs.diff_ids)         -> new config digest
  manifest json (config/layers digests)  -> new manifest digest
  index.json   (manifest digest)         -> rewritten
  legacy manifest.json (Config/Layers)   -> old hex refs replaced

Usage: docker-scrub.py <src.tar> <dst.tar> [-q|--quiet]
"""
import gzip
import hashlib
import io
import json
import sys
import tarfile

QUIET = False


def log(msg: str) -> None:
    if not QUIET:
        print(msg, file=sys.stderr)


def die(msg: str) -> None:
    print(f"docker-scrub: error: {msg}", file=sys.stderr)
    sys.exit(1)


def sha_hex(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def clean_tar_bytes(tar_bytes: bytes) -> bytes:
    """Rewrite a tar stream with uid/gid=0, uname/gname=root on every entry."""
    buf = io.BytesIO()
    try:
        with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tin, \
             tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tout:
            for m in tin:
                m.uid = 0
                m.gid = 0
                m.uname = "root"
                m.gname = "root"
                if m.isreg():
                    tout.addfile(m, tin.extractfile(m))
                else:
                    tout.addfile(m)
    except tarfile.TarError as e:
        die(f"layer is not a valid tar: {e}")
    return buf.getvalue()


def jdump(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode()


def load_members(src: str) -> dict:
    members = {}
    try:
        with tarfile.open(src) as t:
            for m in t:
                if m.isreg():
                    members[m.name.removeprefix("./")] = t.extractfile(m).read()
    except tarfile.TarError as e:
        die(f"input is not a readable tar: {e}")
    if "index.json" not in members:
        die("input tar has no index.json (not an OCI/docker archive?)")
    return members


def scrub(src: str, dst: str) -> None:
    members = load_members(src)

    def blob(hex64: str) -> bytes:
        key = f"blobs/sha256/{hex64}"
        if key not in members:
            die(f"blob not found: {key}")
        return members[key]

    index = json.loads(members["index.json"])
    new_blobs: dict = {}
    hex_map: dict = {}  # old hex -> new hex (legacy manifest.json rewrite)

    for desc in index.get("manifests", []):
        if not desc["digest"].startswith("sha256:"):
            die(f"unsupported digest algo: {desc['digest']}")
        m_hex = desc["digest"].split(":", 1)[1]
        manifest = json.loads(blob(m_hex))
        hex_map[m_hex] = None

        cfg_hex = manifest["config"]["digest"].split(":", 1)[1]
        config = json.loads(blob(cfg_hex))

        diff_ids = config["rootfs"]["diff_ids"]
        if len(diff_ids) != len(manifest["layers"]):
            die("config diff_ids / manifest layers count mismatch")

        for i, layer in enumerate(manifest["layers"]):
            l_hex = layer["digest"].split(":", 1)[1]
            data = blob(l_hex)
            media = layer.get("mediaType", "")
            if media.endswith("gzip"):
                try:
                    raw = gzip.decompress(data)
                except OSError as e:
                    die(f"layer {l_hex[:12]}: gzip decode failed: {e}")
                new_raw = clean_tar_bytes(raw)
                new_blob = gzip.compress(new_raw, 9, mtime=0)
                diff_ids[i] = "sha256:" + sha_hex(new_raw)
            elif media.endswith("+tar") or media == "application/vnd.oci.image.layer.v1.tar":
                new_raw = clean_tar_bytes(data)
                new_blob = new_raw
                diff_ids[i] = "sha256:" + sha_hex(new_raw)
            else:
                die(f"unsupported layer mediaType: {media} (head={data[:4]!r})")
            layer["digest"] = "sha256:" + sha_hex(new_blob)
            layer["size"] = len(new_blob)
            new_blobs["blobs/sha256/" + sha_hex(new_blob)] = new_blob
            hex_map[l_hex] = sha_hex(new_blob)
            log(f"layer {i}: {l_hex[:12]} -> {layer['digest'][7:19]} ({media})")

        cfg_bytes = jdump(config)
        manifest["config"]["digest"] = "sha256:" + sha_hex(cfg_bytes)
        manifest["config"]["size"] = len(cfg_bytes)
        new_blobs["blobs/sha256/" + sha_hex(cfg_bytes)] = cfg_bytes
        hex_map[cfg_hex] = sha_hex(cfg_bytes)

        mf_bytes = jdump(manifest)
        desc["digest"] = "sha256:" + sha_hex(mf_bytes)
        desc["size"] = len(mf_bytes)
        new_blobs["blobs/sha256/" + sha_hex(mf_bytes)] = mf_bytes
        hex_map[m_hex] = sha_hex(mf_bytes)
        log(f"image id: {manifest['config']['digest'][7:19]} (was {cfg_hex[:12]})")

    members["index.json"] = jdump(index)

    # docker load REQUIRES legacy manifest.json inside tar archives (even 29.x);
    # rewrite any old hex references (Config/Layers paths) to the new digests.
    if "manifest.json" in members:
        raw = members["manifest.json"]
        for old, new in hex_map.items():
            if new:
                raw = raw.replace(old.encode(), new.encode())
        members["manifest.json"] = raw
    else:
        die("input tar has no legacy manifest.json (docker load would reject it)")

    with tarfile.open(dst, "w", format=tarfile.GNU_FORMAT) as tout:
        names = ["oci-layout", "index.json", "manifest.json"] + sorted(new_blobs) + ["repositories"]
        for name in names:
            if name in new_blobs:
                data = new_blobs[name]
            elif name in members:
                data = members[name]
            else:
                continue
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mtime = 0
            ti.mode = 0o644
            tout.addfile(ti, io.BytesIO(data))
    log(f"wrote {dst}")


def main() -> None:
    global QUIET
    args = [a for a in sys.argv[1:] if a not in ("-q", "--quiet")]
    if "--help" in args or "-h" in args or len(args) != 2:
        print(__doc__)
        sys.exit(0 if "--help" in args or "-h" in args else 2)
    QUIET = True if QUIET else any(a in ("-q", "--quiet") for a in sys.argv[1:])
    scrub(args[0], args[1])


if __name__ == "__main__":
    main()
