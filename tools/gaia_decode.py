#!/usr/bin/env python3
"""Gaia V3 有序解码：transport[FF][VER][FLAGS][LEN(1B)][V3=LEN+4]，V3=[vendor(2BE)][cmd(2BE)][payload]。
cmd = command[0:6] | type[7:8] | feature[9:15]；vendor 29=QTIL-V3，10=QTIL-v1v2。
用法: python gaia_decode.py <dlci2.bin> [--dir tx|rx]
"""
import struct
import sys

FEATURES = {
    0: 'BASIC', 1: 'EARBUD', 2: 'ANC', 3: 'VOICE_UI', 4: 'DEBUG', 5: 'MUSIC_PROCESSING',
    6: 'UPGRADE', 7: 'HANDSET_SERVICE', 8: 'AUDIO_CURATION', 9: 'EARBUD_FIT',
    10: 'VOICE_PROCESSING', 11: 'GESTURE_CONFIGURATION', 12: 'STATISTICS', 13: 'BATTERY',
    14: 'VOICE', 15: 'DAC_GAIN', 16: 'CODEC_TYPE', 17: 'LIGHT_SENSOR', 18: 'SPATIAL_AUDIO',
    19: 'LED', 20: 'ONEBRINGTWO', 21: 'BT_ADDRESS', 22: 'TOUCHV2', 23: 'AUDIO_RESOURCE',
    24: 'POWER_CONTROL', 25: 'POWER_TIMEOUT', 26: 'TOUCHV3', 27: 'DYBASS', 29: 'AUDIO_FILE_STORAGE',
    30: 'LR_CHANNEL', 31: 'TOUCHV4', 32: 'ANC_V2',
}
VENDORS = {10: 'QTIL-v1v2', 29: 'QTIL-V3'}
TYPES = {0: 'CMD', 1: 'NOTIF', 2: 'RESP', 3: 'ERR'}


def main() -> None:
    path = sys.argv[1]
    direction = sys.argv[sys.argv.index('--dir') + 1] if '--dir' in sys.argv else '?'
    with open(path, 'rb') as f:
        g = f.read()
    i, n, k = 0, len(g), 0
    while i + 4 <= n:
        if g[i] != 0xFF:
            print('  [off %d] 非 FF 起始，剩余 %d 字节(HEX): %s' % (i, n - i, bytes(g[i:i + 32]).hex()))
            break
        ver, flags, ln = g[i + 1], g[i + 2], g[i + 3]
        v3 = g[i + 4:i + 4 + ln + 4]
        if len(v3) < ln + 4:
            print('  [off %d] 截断' % i)
            break
        vendor = struct.unpack('>H', v3[0:2])[0]
        cmd = struct.unpack('>H', v3[2:4])[0]
        ctype, feat, ccmd = (cmd >> 7) & 3, cmd >> 9, cmd & 0x7F
        payload = v3[4:]
        vname = VENDORS.get(vendor, str(vendor))
        fname = FEATURES.get(feat, str(feat))
        print('#%d %s VER=%d FLAGS=0x%02X LEN=%d vendor=%s feat=%s(%d) %s cmd=%d payload=%s'
              % (k, direction, ver, flags, ln, vname, fname, feat,
                 TYPES.get(ctype, ctype), ccmd, bytes(payload).hex() or '-'))
        i += 4 + ln + 4
        k += 1
    print('total=%d covered=%d/%d' % (k, i, n))


if __name__ == '__main__':
    main()
