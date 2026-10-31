#!/usr/bin/env python3
"""L2CAP 正确重组（按 handle+cid 跟踪，续包挂到同 handle 最近未完成 SDU）。

用法: python l2cap_reassemble.py <btsnoop_hci.log> [--dump DIR]
输出: 每个 (handle, cid, 方向) 的 SDU 字节流摘要；--dump 落盘供后续解析。
SDU 方向: 以首包方向为准。
"""
import struct
import sys
from collections import defaultdict


def main():
    path = sys.argv[1]
    dump = sys.argv[sys.argv.index('--dump') + 1] if '--dump' in sys.argv else None
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'btsnoop\x00'
    off = 16
    inprog = {}   # (h, cid) -> [buf, want, direction, ts0]
    order = []    # (h, cid) 创建顺序，续包挂到最近一个未完成的
    streams = defaultdict(bytearray)
    counts = defaultdict(int)
    while off + 24 <= len(data):
        orig, incl, flags, drops, ts = struct.unpack_from('>IIIIQ', data, off)
        pkt = data[off + 24:off + 24 + incl]
        off += 24 + incl
        if not pkt or pkt[0] != 0x02 or len(pkt) < 5:
            continue
        hf = struct.unpack_from('<H', pkt, 1)[0]
        h, pb = hf & 0x0FFF, (hf >> 12) & 0x3
        dr = flags & 1
        if pb in (0, 2):
            if len(pkt) < 9:
                continue
            l2len, cid = struct.unpack_from('<HH', pkt, 5)
            key = (h, cid)
            inprog[key] = [bytearray(pkt[9:9 + l2len]), l2len, dr, ts]
            if key in order:
                order.remove(key)
            order.append(key)
        elif pb == 1:
            # 挂到同 handle 最近创建且未完成的 SDU
            target = None
            for key in reversed(order):
                if key[0] == h and key in inprog and len(inprog[key][0]) < inprog[key][1]:
                    target = key
                    break
            if target is None:
                continue
            inprog[target][0].extend(pkt[5:])
        # 收割完成的
        for key in [k for k in order if k in inprog and len(inprog[k][0]) >= inprog[k][1]]:
            buf, want, dr0, ts0 = inprog.pop(key)
            order.remove(key)
            streams[(key[0], key[1], dr0)].extend(bytes(buf[:want]))
            counts[(key[0], key[1], dr0)] += 1
    # 收尾：未完成的也输出（截断 SDU，标注）
    for key, (buf, want, dr0, ts0) in inprog.items():
        streams[(key[0], key[1], dr0)].extend(bytes(buf))
        counts[(key[0], key[1], dr0)] += 1
    for (h, cid, dr), n in sorted(counts.items()):
        b = bytes(streams[(h, cid, dr)])
        tag = 'D->H(耳机回)' if dr else 'H->D(手机发)'
        print(f'h=0x{h:03X} cid=0x{cid:04X} {tag} sdus={n} bytes={len(b)} head={b[:48].hex()}')
        if dump:
            import os
            os.makedirs(dump, exist_ok=True)
            with open(f'{dump}/h{h:03x}_cid{cid:04x}_{"rx" if dr else "tx"}.bin', 'wb') as f:
                f.write(b)


if __name__ == '__main__':
    main()
