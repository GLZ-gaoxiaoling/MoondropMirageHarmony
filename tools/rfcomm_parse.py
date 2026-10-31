#!/usr/bin/env python3
"""RFCOMM UIH 解析 + 按 DLCI 分流（读 l2cap_reassemble 落盘的流文件）。

用法: python rfcomm_parse.py <hXXX_cidXXXX_[rt]x.bin>... [--skip N] [--dump DIR]
输出: 每 DLCI 的帧列表；--dump 落 data DLCI 的 info 字节（4 字节长度前缀）。
"""
import os
import struct
import sys

POLY = 0xE0
_CRC = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ POLY if _c & 1 else _c >> 1
    _CRC.append(_c)


def fcs(hdr: bytes) -> int:
    c = 0xFF
    for b in hdr:
        c = _CRC[c ^ b]
    return c ^ 0xFF


def parse_rfcomm(buf: bytes):
    """返回 ([('ctrl',dlci,c,info) | (dlci,cr,info)], stop_offset)。"""
    out, i, n = [], 0, len(buf)
    while i + 4 <= n:
        addr, ctrl = buf[i], buf[i + 1]
        if ctrl in (0xEF, 0xE3):
            lb = buf[i + 2]
            if lb & 1:
                ln, o = lb >> 1, 3
            else:
                if i + 4 > n:
                    break
                ln, o = ((lb >> 1) | (buf[i + 3] << 7)), 4
            credit = 1 if ctrl == 0xE3 else 0
            end = i + o + credit + ln + 1
            if end > n:
                break
            if fcs(buf[i:i + o + credit]) != buf[end - 1]:
                return out, i
            out.append((addr >> 2, (addr >> 1) & 1, bytes(buf[i + o + credit:end - 1])))
            i = end
        elif (ctrl & 0x03) == 0x01 or ctrl in (0x2F, 0x3F, 0x63, 0x73, 0x0F, 0x1F,
                                              0x43, 0x53, 0x87, 0x97):
            if (ctrl & 0x03) == 0x01:
                o, ln = 2, 0
            else:
                if i + 3 > n:
                    break
                lb = buf[i + 2]
                o = 3 if lb & 1 else 4
                if o == 4 and i + 4 > n:
                    break
                ln = (lb >> 1) if lb & 1 else ((lb >> 1) | (buf[i + 3] << 7))
            end = i + o + ln + 1
            if end > n:
                break
            if fcs(buf[i:i + o]) != buf[end - 1]:
                return out, i
            out.append(('ctrl', addr >> 2, ctrl, bytes(buf[i + o:end - 1])))
            i = end
        else:
            return out, i
    return out, i


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    dump = sys.argv[sys.argv.index('--dump') + 1] if '--dump' in sys.argv else None
    skip = int(sys.argv[sys.argv.index('--skip') + 1]) if '--skip' in sys.argv else 0
    for name in sorted(bufs):
        raw = bytes(bufs[name])
        direction = '_rx' in name
        tag = 'D->H' if direction else 'H->D'
        frames, stop = parse_rfcomm(raw[skip:])
        print('== %s %s frames=%d bytes=%d skip=%d stop=%d' % (name, tag, len(frames), len(raw), skip, stop))
        n_data = 0
        for fr in frames:
            if fr[0] == 'ctrl':
                print('   ctrl DLCI=%s c=0x%02X %s' % (fr[1], fr[2], fr[3].hex()))
            else:
                dlci, cr, info = fr
                if n_data < 30:
                    try:
                        txt = bytes(info).decode('ascii')
                    except Exception:
                        txt = ''
                    print('   DLCI=%d len=%d %s %r' % (dlci, len(info), bytes(info[:64]).hex(), txt[:56]))
                n_data += 1
                if dump and dlci != 0:
                    import os
                    os.makedirs(dump, exist_ok=True)
                    fh = open('%s/dlci%d_%s.bin' % (dump, dlci, 'rx' if direction else 'tx'), 'ab')
                    fh.write(struct.pack('>I', len(info)))
                    fh.write(bytes(info))
                    fh.close()
        if n_data > 30:
            print('   ... +%d more data frames' % (n_data - 30))

if __name__ == '__main__':
    main()
