import zipfile, struct, sys

PATH = r"D:\44455b90420546559b11d9b39cc4c1f5.zip"
z = zipfile.ZipFile(PATH)

print("=== metadata ===")
print(z.read("META-INF/com/android/metadata").decode("utf-8", "replace").strip())

print("\n=== payload_properties ===")
print(z.read("payload_properties.txt").decode("utf-8", "replace").strip())

# ---------- payload header ----------
f = z.open("payload.bin")
hdr = f.read(24)
magic = hdr[:4]
ver, msize = struct.unpack(">QQ", hdr[4:20])
print(f"\n=== payload header ===")
print("magic:", magic, "version:", ver, "manifest_size:", msize)

manifest = f.read(msize)
meta_sig_size = 0
if ver >= 2:
    meta_sig_size = struct.unpack(">I", f.read(4))[0]
data_start = 24 + msize + (4 + meta_sig_size if ver >= 2 else 0)
print("metadata_sig_size:", meta_sig_size, "data_start:", data_start)

# ---------- minimal protobuf reader ----------
def rv(buf, p):
    r = 0; s = 0
    while True:
        b = buf[p]; p += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80):
            return r, p
        s += 7

def fields(buf):
    """yield (field_no, wire_type, payload)"""
    p = 0; n = len(buf)
    while p < n:
        key, p = rv(buf, p)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, p = rv(buf, p); yield fn, wt, v
        elif wt == 2:
            ln, p = rv(buf, p); yield fn, wt, buf[p:p+ln]; p += ln
        elif wt == 5:
            yield fn, wt, buf[p:p+4]; p += 4
        elif wt == 1:
            yield fn, wt, buf[p:p+8]; p += 8
        else:
            raise ValueError(f"wire type {wt} at {p}")

# ---------- manifest ----------
block_size = 4096
partitions = []
for fn, wt, val in fields(manifest):
    if fn == 3 and wt == 0:
        block_size = val
    elif fn == 13 and wt == 2:
        partitions.append(val)

print("block_size:", block_size, "partitions:", len(partitions))

TYPE = {0: "REPLACE", 1: "REPLACE_BZ", 2: "MOVE", 3: "BSDIFF", 4: "SOURCE_COPY",
        5: "SOURCE_BSDIFF", 6: "ZERO", 7: "DISCARD", 8: "REPLACE_XZ",
        9: "PUFFDIFF", 10: "BROTLI_BSDIFF", 11: "ZUCCHINI", 12: "LZ4DIFF_BSDIFF",
        13: "LZ4DIFF_PUFFDIFF"}

print(f"\n{'分区':22s} {'大小(MB)':>10s}  操作类型统计")
print("-" * 90)
alltypes = set()
for pbuf in partitions:
    name = "?"
    ops = []
    nbytes = None
    for fn, wt, val in fields(pbuf):
        if fn == 1 and wt == 2:
            name = val.decode("utf-8", "replace")
        elif fn == 8 and wt == 2:
            ops.append(val)
        elif fn == 7 and wt == 2:      # new_partition_info
            for f2, w2, v2 in fields(val):
                if f2 == 1 and w2 == 0:
                    nbytes = v2
    hist = {}
    for ob in ops:
        t = None
        for f2, w2, v2 in fields(ob):
            if f2 == 1 and w2 == 0:
                t = v2
                break
        tn = TYPE.get(t, str(t))
        alltypes.add(tn)
        hist[tn] = hist.get(tn, 0) + 1
    sz = f"{nbytes/1024/1024:.1f}" if nbytes else "?"
    h = ", ".join(f"{k}×{v}" for k, v in sorted(hist.items()))
    print(f"{name:22s} {sz:>10s}  {h}")

print("\n出现的操作类型:", sorted(alltypes))
print("是否纯全量（无 SOURCE_* / BSDIFF / PUFFDIFF）:",
      not any(t.startswith(("SOURCE_", "BSDIFF", "PUFFDIFF", "BROTLI", "LZ4DIFF")) for t in alltypes))
