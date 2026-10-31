#!/usr/bin/env python3
"""btsnoop 解析器：专捞水月雨 Mirage 9ECA 私有服务的 ATT 流量。

用法: python parse_btsnoop.py <btsnoop_hci.log> [--full FILE]
输出: 每条 ATT 包 (时间, 方向, opcode, handle, 值hex)；--full 写完整时间线到 FILE。
与 PROTOCOL.md 交叉验证：SERVICE 9ECA0000 / CMD 0001 / NOTIFY 0003，帧 [A5][01][CMD][LEN][payload]。
"""
import struct
import sys

ATT_NAMES = {
    0x02: 'MTU_REQ', 0x03: 'MTU_RSP', 0x04: 'FIND_INFO_REQ', 0x05: 'FIND_INFO_RSP',
    0x06: 'FIND_BY_TYPE_REQ', 0x07: 'FIND_BY_TYPE_RSP', 0x08: 'READ_BY_TYPE_REQ',
    0x09: 'READ_BY_TYPE_RSP', 0x0A: 'READ_REQ', 0x0B: 'READ_RSP', 0x0C: 'READ_BLOB_REQ',
    0x0D: 'READ_BLOB_RSP', 0x10: 'READ_BY_GRP_REQ', 0x11: 'READ_BY_GRP_RSP',
    0x12: 'WRITE_REQ', 0x13: 'WRITE_RSP', 0x16: 'PREP_WRITE_REQ', 0x17: 'PREP_WRITE_RSP',
    0x18: 'EXEC_WRITE_REQ', 0x19: 'EXEC_WRITE_RSP', 0x1B: 'NOTIFY', 0x1D: 'INDICATE',
    0x1E: 'INDICATE_CONF', 0x1F: 'SIGNED_WRITE', 0x52: 'WRITE_CMD', 0xD2: 'SIGNED_WRITE_CMD',
}

MIRAGE_SVC_SUFFIX = bytes.fromhex('9A38A91B2C6E0100')  # 9ECAxxxx-7F3A-4F32-9A38-A91B2C6E0100 后半


def parse_btsnoop(path):
    """返回 [(ts_us, sent(bool), hci_type, payload)]。"""
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'btsnoop\x00', 'not a btsnoop file'
    off = 8 + 4 + 4
    pkts = []
    while off + 24 <= len(data):
        orig, incl, flags, drops, ts = struct.unpack_from('>IIIIQ', data, off)
        off += 24
        pkt = data[off:off + incl]
        off += incl
        if not pkt:
            continue
        sent = not (flags & 1)
        pkts.append((ts, sent, pkt[0], pkt[1:]))
    return pkts


def main():
    path = sys.argv[1]
    full_path = None
    if '--full' in sys.argv:
        full_path = sys.argv[sys.argv.index('--full') + 1]
    pkts = parse_btsnoop(path)

    att_lines = []
    handles = {}  # handle -> uuid 描述（从发现回包学）
    mirage_handles = set()  # 出现 9ECA 的 conn handle
    ad_names = {}
    cur_conn = {}  # handle -> addr

    for ts, sent, htype, p in pkts:
        if htype == 0x04 and len(p) >= 2:  # HCI EVT
            code = p[0]
            if code == 0x3E and len(p) >= 3:  # LE Meta
                sub = p[2]
                if sub == 0x01 and len(p) >= 11:  # LE Conn Complete
                    h = struct.unpack_from('<H', p, 4)[0] & 0x0FFF
                    addr = ':'.join(f'{b:02X}' for b in p[8:14][::-1])
                    cur_conn[h] = addr
                elif sub in (0x02, 0x0D):  # Adv Report(s)
                    try:
                        if sub == 0x02:
                            n = p[3]
                            o = 4
                            for _ in range(n):
                                o += 1 + 6  # evt type + addr
                                dlen = p[o]; o += 1
                                adv = p[o:o + dlen]; o += dlen
                                o += 1  # rssi
                                i = 0
                                while i + 1 < len(adv):
                                    ln = adv[i]
                                    if ln == 0 or i + 1 + ln > len(adv):
                                        break
                                    typ, val = adv[i + 1], adv[i + 2:i + 1 + ln]
                                    if typ in (0x08, 0x09):
                                        name = val.decode('utf-8', 'replace')
                                        ad_names.setdefault(name, 0)
                                        ad_names[name] += 1
                                    i += 1 + ln
                    except (IndexError, struct.error):
                        pass
        if htype != 0x02 or len(p) < 8:  # 仅 ACL
            continue
        h = struct.unpack_from('<H', p, 0)[0] & 0x0FFF
        l2len, cid = struct.unpack_from('<HH', p, 4)
        if cid != 0x0004 or len(p) < 8:  # 仅 ATT
            continue
        att = p[8:8 + l2len]
        if not att:
            continue
        op = att[0]
        name = ATT_NAMES.get(op, f'0x{op:02X}')
        handle = struct.unpack_from('<H', att, 1)[0] if len(att) >= 3 else 0
        val = att[3:] if len(att) > 3 else b''
        # 学 handle→UUID（发现回包）
        if op in (0x09, 0x11) and len(att) >= 4:
            entry_len = att[1]
            entries = att[2:]
            for i in range(0, len(entries), entry_len):
                e = entries[i:i + entry_len]
                if len(e) < entry_len:
                    break
                if op == 0x09 and entry_len >= 7:  # char 声明: h, props, vh, uuid
                    hh = struct.unpack_from('<H', e, 0)[0]
                    vh = struct.unpack_from('<H', e, 3)[0]
                    uu = e[5:]
                    handles[hh] = f'char-decl props={e[2]:02X} vh={vh:04X} uuid={uu.hex()}'
                    handles[vh] = f'char-value uuid={uu.hex()}'
                elif op == 0x11 and entry_len in (6, 20):  # service 声明
                    sh, eh = struct.unpack_from('<HH', e, 0)
                    uu = e[4:]
                    handles[sh] = f'svc {sh:04X}-{eh:04X} uuid={uu.hex()}'
        is_mirage = MIRAGE_SVC_SUFFIX in att
        if is_mirage:
            mirage_handles.add(h)
        # A5 01 帧嗅探
        frame_note = ''
        for j in range(len(att) - 3):
            if att[j] == 0xA5 and att[j + 1] == 0x01:
                ln = att[j + 3]
                if j + 4 + ln <= len(att):
                    frame_note = (f' FRAME cmd=0x{att[j+2]:02X} '
                                  f'payload={att[j+4:j+4+ln].hex()}')
                    mirage_handles.add(h)
                    break
        direction = 'H→D' if sent else 'D→H'
        line = f'{ts} {direction} h=0x{h:03X} {name} hdl=0x{handle:04X} {val.hex()}{frame_note}'
        att_lines.append((h, line))

    print(f'== 广播名(去重计数) ==')
    for n, c in sorted(ad_names.items(), key=lambda x: -x[1])[:20]:
        print(f'  {n!r} x{c}')
    print(f'== 连接句柄 == {cur_conn}')
    print(f'== 疑似 Mirage 句柄(出现9ECA/A501) == {sorted(f"0x{h:03X}" for h in mirage_handles)}')
    print(f'== ATT 总包数 == {len(att_lines)}')
    if full_path:
        with open(full_path, 'w', encoding='utf-8') as f:
            for _, line in att_lines:
                f.write(line + '\n')
        print(f'完整时间线 -> {full_path}')
    else:
        # 默认只打印 Mirage 句柄 + 发现回包
        for h, line in att_lines:
            if h in mirage_handles or 'READ_By' in line or 'FIND' in line:
                print(line)


if __name__ == '__main__':
    main()
