#!/usr/bin/env python3
"""RFCOMM UIH 按 DLCI 分流 + Gaia transport 帧链解析。

用法:
  python gaia_split.py <rfcomm_stream.bin> [--skip N] [--dump DIR]
    长度链走流，按 DLCI 落盘 info 字节。
  python gaia_split.py --gaia <dlci_stream.bin>
    尝试 (1/2字节长度)×(BE/LE)×(有/无checksum) 8 种组合链解 Gaia transport 帧。
"""
import os
import struct
import sys
from collections import defaultdict


def walk(buf):
    """返回 [(dlci, info)] + 停止偏移。长度链，不校验 FCS。"""
    out, i, n = [], 0, len(buf)
    while i + 3 <= n:
        addr, ctrl = buf[i], buf[i + 1]
        if addr & 1 == 0:
            break
        if ctrl in (0xEF, 0xE3, 0xFF):
            lb = buf[i + 2]
            if not (lb & 1):
                if i + 4 > n:
                    break
                ln = ((lb >> 1) | (buf[i + 3] << 7))
                o = 4
            else:
                ln, o = lb >> 1, 3
            credit = 1 if ctrl in (0xE3,) or ctrl == 0xFF else 0
            end = i + o + credit + ln + 1
            if end > n:
                break
            out.append((addr >> 2, bytes(buf[i + o + credit:end - 1])))
            i = end
        elif (ctrl & 0x03) == 0x01:
            i += 3
        elif ctrl in (0x2F, 0x3F, 0x63, 0x73, 0x0F, 0x1F, 0x43, 0x53, 0x87, 0x97):
            lb = buf[i + 2]
            if lb & 1:
                ln, o = lb >> 1, 3
            else:
                if i + 4 > n:
                    break
                ln, o = ((lb >> 1) | (buf[i + 3] << 7)), 4
            i += o + ln + 1
        else:
            break
    return out, i


def gaia_chain(g, lenbytes, le, chk):
    """返回 (frames, stop)。frames 元素 (ver, flags, len, v3head_hex)。"""
    i, n, frames = 0, len(g), []
    while i + 5 <= n:
        if g[i] != 0xFF:
            return frames, i
        ver, flags = g[i + 1], g[i + 2]
        if lenbytes == 1:
            ln, o = g[i + 3], 4
        else:
            raw = g[i + 3:i + 5]
            ln = int.from_bytes(raw, 'little' if le else 'big')
            o = 5
        total = o + ln + 4 + (1 if chk else 0)
        if i + total > n:
            return frames, ('TRUNC', i)
        frames.append((ver, flags, ln, bytes(g[i + o:i + o + 16]).hex()))
        i += total
    return frames, i


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    skip = int(sys.argv[sys.argv.index('--skip') + 1]) if '--skip' in sys.argv else 0
    dump = sys.argv[sys.argv.index('--dump') + 1] if '--dump' in sys.argv else None
    if '--gaia' in sys.argv:
        for path in args:
            with open(path, 'rb') as f:
                g = f.read()
            print('== %s bytes=%d' % (path, len(g)))
            for lb in (1, 2):
                for le in (False, True):
                    for chk in (False, True):
                        fr, stop = gaia_chain(g, lb, le, chk)
                        desc = 'lenbytes=%d %s chk=%s' % (lb, 'LE' if le else 'BE', chk)
                        if isinstance(stop, tuple) or stop < len(g):
                            print('  %s: frames=%d stop=%s %s'
                                  % (desc, len(fr), stop,
                                     str([(v, hex(f), ln, h[:16]) for v, f, ln, h in fr[:3]])))
                        else:
                            print('  %s: COMPLETE frames=%d %s'
                                  % (desc, len(fr),
                                     str([(v, hex(f), ln, h[:16]) for v, f, ln, h in fr[:6]])))
        return
    for path in args:
        with open(path, 'rb') as f:
            buf = f.read()[skip:]
        fr, stop = walk(buf)
        print('== %s bytes=%d skip=%d frames=%d stop=%s' % (path, len(buf), skip, len(fr), stop))
        dlcis = defaultdict(bytearray)
        for dlci, info in fr:
            dlcis[dlci].extend(info)
        for k in sorted(dlcis):
            b = bytes(dlcis[k])
            print('  DLCI %d: %d bytes head=%s' % (k, len(b), b[:64].hex()))
            if dump:
                os.makedirs(dump, exist_ok=True)
                base = os.path.basename(path).replace('.bin', '')
                with open('%s/%s_dlci%d.bin' % (dump, base, k), 'wb') as f:
                    f.write(b)


if __name__ == '__main__':
    main()
