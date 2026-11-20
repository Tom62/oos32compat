import zipfile, struct, sys, os, lzma, bz2, hashlib

PATH = r"D:\44455b90420546559b11d9b39cc4c1f5.zip"
OUTDIR = r"C:\Users\Tom96\Documents\deepseek-harness\default-workspace\fw"
BLOCK = 4096

def rv(buf, p):
    r = 0; s = 0
    while True:
        b = buf[p]; p += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80):
            return r, p
        s += 7

def fields(buf):
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
            raise ValueError(f"wt {wt}")

z = zipfile.ZipFile(PATH)
info = z.getinfo("payload.bin")
print("payload compress_type:", info.compress_type, "(0=stored)")

f = z.open("payload.bin")
hdr = f.read(24)
magic = hdr[:4]
assert magic == b"CrAU", magic
ver = struct.unpack(">Q", hdr[4:12])[0]
msize = struct.unpack(">Q", hdr[12:20])[0]
sig_size = struct.unpack(">I", hdr[20:24])[0]
manifest = f.read(msize)
data_start = 24 + msize + sig_size
print(f"version={ver} manifest={msize} sig={sig_size} data_start={data_start}")

block_size = BLOCK
parts = []
for fn, wt, val in fields(manifest):
    if fn == 3 and wt == 0:
        block_size = val
    elif fn == 13 and wt == 2:
        parts.append(val)
print("block_size:", block_size, "partitions:", len(parts))

def parse_part(pbuf):
    name = None; ops = []; nsize = None
    for fn, wt, val in fields(pbuf):
        if fn == 1 and wt == 2: name = val.decode()
        elif fn == 8 and wt == 2: ops.append(val)
        elif fn == 7 and wt == 2:
            for f2, w2, v2 in fields(val):
                if f2 == 1 and w2 == 0: nsize = v2
    return name, ops, nsize

def parse_op(ob):
    t = None; doff = 0; dlen = 0; dst = []
    for fn, wt, val in fields(ob):
        if fn == 1 and wt == 0: t = val
        elif fn == 2 and wt == 0: doff = val
        elif fn == 3 and wt == 0: dlen = val
        elif fn == 6 and wt == 2:
            sb = nb = 0
            for f2, w2, v2 in fields(val):
                if f2 == 1 and w2 == 0: sb = v2
                elif f2 == 2 and w2 == 0: nb = v2
            dst.append((sb, nb))
    return t, doff, dlen, dst

TYPES = {0:"REPLACE",1:"REPLACE_BZ",6:"ZERO",8:"REPLACE_XZ"}

def dump(target):
    for pbuf in parts:
        name, ops, nsize = parse_part(pbuf)
        if name != target: continue
        os.makedirs(OUTDIR, exist_ok=True)
        out = os.path.join(OUTDIR, name + ".img")
        print(f"\n>>> {name}: {nsize/1024/1024:.1f} MB, {len(ops)} ops -> {out}")
        with open(out, "wb") as o:
            if nsize: o.truncate(nsize)
            done = 0
            for ob in ops:
                t, doff, dlen, dst = parse_op(ob)
                tn = TYPES.get(t, str(t))
                if tn == "ZERO":
                    for sb, nb in dst:
                        o.seek(sb*block_size); o.write(b"\0"*(nb*block_size))
                    continue
                f.seek(data_start + doff)
                raw = f.read(dlen)
                if tn == "REPLACE": buf = raw
                elif tn == "REPLACE_BZ": buf = bz2.decompress(raw)
                elif tn == "REPLACE_XZ": buf = lzma.decompress(raw)
                else:
                    raise SystemExit(f"unsupported op type {tn}")
                pos = 0
                for sb, nb in dst:
                    ln = nb*block_size
                    o.seek(sb*block_size)
                    o.write(buf[pos:pos+ln])
                    pos += ln
                done += 1
                if done % 100 == 0:
                    print(f"    {done}/{len(ops)}", flush=True)
        print("    done, size:", os.path.getsize(out))
        with open(out, "rb") as chk:
            head = chk.read(2048)
        print("    前 4 字节:", head[:4].hex(), " offset1024 magic:", head[1024:1028])
        return True
    print(f"未找到分区 {target}")
    return False

targets = sys.argv[1:] or ["product"]
for t in targets:
    dump(t)
