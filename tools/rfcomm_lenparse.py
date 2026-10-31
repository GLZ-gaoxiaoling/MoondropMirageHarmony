#!/usr/bin/env python3
"""RFCOMM 容错解析：按长度链推进（FCS 仅记录，不作为同步依据；实测该耳机 UIH FCS 与标准算法不符）。

用法: rfcomm_lenparse.py <stream.bin> [--skip N]
要求: 输入为单 direction 单 CID 的 L2CAP SDU 拼接流（l2cap_reassemble 落盘文件）。
SDU 边界未知——仅做帧链打印；调用方自行对照 SDU 长度校验。
"""
import sys


def walk(buf: bytes):
    """返回帧列表 [(kind, dlci, ctrl, info)]；kind ∈ UIH/CTRL/S/UNK。"""
    out, i, n = [], 0, len(buf)
    while i + 2 <= n:
        addr, ctrl = buf[i], buf[i + 1]
        if addr & 1 == 0:
            out.append(('UNK_ADDR2', addr, ctrl, b''))
            break
        if ctrl in (0xEF, 0xE3):
            if i + 3 > n:
                break
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
                out.append(('TRUNC_UIH', addr >> 2, ctrl, buf[i:]))
                break
            out.append(('UIH', addr >> 2, ctrl, bytes(buf[i + o + credit:end - 1])))
            i = end
        elif (ctrl & 0x03) == 0x01:
            if i + 3 > n:
                break
            out.append(('S', addr >> 2, ctrl, b''))
            i += 3
        elif ctrl in (0x2F, 0x3F, 0x63, 0x73, 0x0F, 0x1F, 0x43, 0x53, 0x87, 0x97):
            if i + 3 > n:
                break
            lb = buf[i + 2]
            if lb & 1:
                ln, o = lb >> 1, 3
            else:
                if i + 4 > n:
                    break
                ln, o = ((lb >> 1) | (buf[i + 3] << 7)), 4
            end = i + o + ln + 1
            if end > n:
                out.append(('TRUNC_U', addr >> 2, ctrl, buf[i:]))
                break
            out.append(('U', addr >> 2, ctrl, bytes(buf[i + o:end - 1])))
            i = end
        else:
            out.append(('UNK_CTRL', addr, ctrl, bytes(buf[i:i + 16])))
            break
    return out


def main() -> None:
    path = sys.argv[1]
    skip = int(sys.argv[sys.argv.index('--skip') + 1]) if '--skip' in sys.argv else 0
    with open(path, 'rb') as f:
        buf = f.read()[skip:]
    frames = walk(buf)
    print('bytes=%d skip=%d frames=%d' % (len(buf), skip, len(frames)))
    for k, fr in enumerate(frames):
        if fr[0] == 'UIH':
            _, dlci, ctrl, info = fr
            try:
                txt = bytes(info).decode('ascii')
            except Exception:
                txt = ''
            print('%3d UIH DLCI=%d ln=%d %s %r' % (k, dlci, len(info), bytes(info[:48]).hex(), txt[:64]))
        elif fr[0] == 'U':
            print('%3d U DLCI=%d c=0x%02X %s' % (k, fr[1], fr[2], fr[3].hex()))
        else:
            print('%3d %s %s' % (k, fr[0], str(fr[1:])))
            break


if __name__ == '__main__':
    main()
