#!/usr/bin/env python3
"""Mirage 抓包分析：LE 广播名 + L2CAP PSM/CID 映射 + RFCOMM UIH 分流。

用法: python analyze_capture.py <btsnoop_hci.log> [--dump DIR]
"""
import struct
import sys
from collections import Counter, defaultdict


def records(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'btsnoop\x00'
    off = 16
    while off + 24 <= len(data):
        orig, incl, flags, drops, ts = struct.unpack_from('>IIIIQ', data, off)
        pkt = data[off + 24:off + 24 + incl]
        off += 24 + incl
        if pkt:
            yield ts, bool(flags & 1), pkt  # received = flags&1


def main():
    path = sys.argv[1]
    dump_dir = sys.argv[sys.argv.index('--dump') + 1] if '--dump' in sys.argv else None
    adv_names = Counter()
    psm_map = {}   # dcid -> (psm, dir)
    rfcomm = defaultdict(list)  # dlci -> [(recv, bytes)]
    l2cap_sig = []
    n_acl = n_evt = 0

    for ts, recv, pkt in records(path):
        t = pkt[0]
        if t == 0x04:  # EVT
            n_evt += 1
            if len(pkt) >= 4 and pkt[1] == 0x3E:  # LE Meta
                sub = pkt[3]
                if sub == 0x02 and len(pkt) >= 5:  # Adv Report
                    try:
                        n = pkt[4]; o = 5
                        for _ in range(n):
                            o += 1 + 6
                            dlen = pkt[o]; o += 1
                            adv = pkt[o:o + dlen]; o += dlen
                            o += 1
                            i = 0
                            while i + 1 < len(adv):
                                ln = adv[i]
                                if ln == 0 or i + 1 + ln > len(adv):
                                    break
                                typ, val = adv[i + 1], adv[i + 2:i + 1 + ln]
                                if typ in (0x08, 0x09):
                                    adv_names[val.decode('utf-8', 'replace')] += 1
                                i += 1 + ln
                    except (IndexError, struct.error):
                        pass
        elif t == 0x02:  # ACL
            n_acl += 1
            if len(pkt) < 9:
                continue
            handle = struct.unpack_from('<H', pkt, 1)[0] & 0x0FFF
            l2len, cid = struct.unpack_from('<HH', pkt, 5)
            pl = pkt[9:9 + l2len]
            if cid == 0x0001 and len(pl) >= 4:  # L2CAP 信令
                code, ident, slen = pl[0], pl[1], struct.unpack_from('<H', pl, 2)[0]
                body = pl[4:4 + slen]
                l2cap_sig.append((ts, recv, code, body.hex()))
                if code == 0x02 and len(body) >= 4:  # Connect Req
                    psm, scid = struct.unpack_from('<HH', body, 0)
                    psm_map[('out' if not recv else 'in', scid)] = psm
                elif code == 0x03 and len(body) >= 8:  # Connect Rsp
                    dcid, scid, res, status = struct.unpack_from('<HHHH', body, 0)
                    if res == 0:
                        psm_map[('rsp', dcid if not recv else scid)] = psm_map.get(
                            ('in' if not recv else 'out', scid if not recv else dcid), '?')
            elif len(pl) > 0:
                rfcomm[(handle, cid)].append((recv, pl))

    print(f'ACL={n_acl} EVT={n_evt}')
    print('== LE 广播名 ==')
    for n_, c in adv_names.most_common(20):
        print(f'  {n_!r} x{c}')
    print('== L2CAP 信令 ==')
    for ts, recv, code, body in l2cap_sig[:40]:
        print(f"  {'D→H' if recv else 'H→D'} code=0x{code:02X} {body[:120]}")
    print('== L2CAP 数据通道(按handle,cid分组) ==')
    for (h, cid), pkts in sorted(rfcomm.items()):
        total = sum(len(p) for _, p in pkts)
        first = pkts[0][1][:16].hex() if pkts else ''
        print(f'  h=0x{h:03X} cid=0x{cid:04X} n={len(pkts)} bytes={total} head={first}')
        if dump_dir and total < 200000:
            import os
            os.makedirs(dump_dir, exist_ok=True)
            fn = f'{dump_dir}/h{h:03x}_cid{cid:04x}.bin'
            with open(fn, 'wb') as f:
                for recv, p in pkts:
                    f.write(b'\x01' if recv else b'\x00')
                    f.write(struct.pack('>I', len(p)))
                    f.write(p)
            print(f'    -> {fn}')


if __name__ == '__main__':
    main()
