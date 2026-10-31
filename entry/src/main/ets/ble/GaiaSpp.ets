/**
 * Gaia V3 over RFCOMM SPP（水月雨 Mirage 主控协议）。
 *
 * 证据：PROTOCOL.md 附录 A（btsnoop 194 帧链式验证 + jadx 反编译交叉印证）。
 * - transport: [FF][VER][FLAGS][LEN(1B)][V3PDU = LEN+4]，无 checksum
 *   （GaiaFormatter$Rfcomm.Frame.format + length/lengthWithExtension/getChecksum 反编译）
 * - V3: vendor U16BE | command U16BE[type(2b)<<7 | feature(7b)<<9 | cmd(7b)] | payload
 *   （V3PacketFactory.buildPacket / V3Command / V3PacketType / QTILVendorIDs / QTILFeature 反编译）
 * - RFCOMM UIH 的 FCS：本耳机固件不符合标准（内容对、校验错；SABM/UA 标准）。
 *   发送一律用标准全头 FCS；接收不校验（按长度链 + L2CAP SDU 边界切分）。
 *   （Motorola 官方栈亦不校验，双方互通正常。）
 *
 * Harmony 侧传输：@kit.ConnectivityKit 的 socket.sppClient* 系列（哦对，SPP 在
 * @ohos.bluetooth.socket 下：sppConnect/sppWrite/on('sppRead')，应用层自行 RFCOMM 组帧即可——
 * 本模块只负责 Gaia 载荷编解码，RFCOMM UIH 组帧见底部的 RfcUIH 辅助函数。）
 */
export namespace Gaia {
  /** Gaia transport 常量（Header.SOF/Version/Flags/Length 反编译值） */
  export const SOF = 0xFF;
  export const VER_V1 = 0x01; // 版本协商阶段
  export const VER_V3 = 0x04; // 业务阶段（本包全部 VER=04）
  export const VENDOR_QTIL_V1V2 = 10; // QTIL_V3_VENDOR_ID 的兄弟值
  export const VENDOR_QTIL_V3 = 29;

  /** V3 包类型（V3PacketType 实锤） */
  export const enum PktType { CMD = 0, NOTIF = 1, RESP = 2, ERR = 3 }

  /** Feature（QTILFeature 实锤，常用子集，全表见 PROTOCOL.md A.4） */
  export const enum Feat {
    BASIC = 0, ANC = 2, MUSIC_PROCESSING = 5, BATTERY = 13, ONEBRINGTWO = 20,
    TOUCHV2 = 22, DAC_GAIN = 15, CODEC_TYPE = 16, LED = 19, ANC_V2 = 32,
  }

  /** ANC_V2 命令（V3AncV2Plugin$COMMANDS 实锤） */
  export const enum AncCmd { GET_MODE = 3, SET_MODE = 4, GET_SWITCH_CONF = 41, SET_SWITCH_CONF = 42 }
  /** ANC 模式值（AncV2Handler 常量实锤） */
  export const enum AncMode {
    OFF = 0, ANC_ON = 1, TRANSPARENT = 2, ANTI_WIND = 3, ADAPTIVE = 4, LIVE = 5,
  }
  /** 电池命令（空中包行为归纳：cmd0 查支持→`01 02`，cmd1+`01 02` 查电量） */
  export const enum BattCmd { GET_SUPPORTED = 0, GET_LEVELS = 1 }
  /** EQ 命令（空中包行为归纳：cmd3+`3f` 取预设，cmd6 下发 PEQ blob） */
  export const enum EqCmd { GET_PRESET = 3, SET_PEQ = 6 }
  /** BASIC 命令（空中包行为归纳） */
  export const enum BasicCmd { GET_VERSION = 5, GET_SN_LEFT = 20, GET_SN_RIGHT = 21 }

  export interface V3 {
    vendor: number;
    type: number;
    feature: number;
    command: number;
    payload: Uint8Array;
  }

  /** 组 transport 帧：[FF][VER][0][LEN][V3PDU]（FLAGS 全 0，无 checksum，194 帧验证） */
  export function buildFrame(ver: number, v3: Uint8Array): Uint8Array {
    const out = new Uint8Array(4 + v3.length);
    out[0] = SOF;
    out[1] = ver & 0xFF;
    out[2] = 0x00;
    out[3] = (v3.length - 4) & 0xFF;
    out.set(v3, 4);
    return out;
  }

  /** 组 V3 包：[vendor BE][command BE][payload]，command = feature<<9 | type<<7 | cmd */
  export function buildV3(vendor: number, feat: number, type: number, cmd: number,
    payload?: Uint8Array): Uint8Array {
    const body: Uint8Array = payload ?? new Uint8Array(0);
    const out = new Uint8Array(4 + body.length);
    out[0] = (vendor >> 8) & 0xFF;
    out[1] = vendor & 0xFF;
    const desc: number = ((feat & 0x7F) << 9) | ((type & 0x03) << 7) | (cmd & 0x7F);
    out[2] = (desc >> 8) & 0xFF;
    out[3] = desc & 0xFF;
    out.set(body, 4);
    return out;
  }

  /** 解一帧 transport（调用方保证以 0xFF 开头）；返回 {v3, next}，next 为下一帧偏移 */
  export function parseFrame(buf: Uint8Array): { v: V3, next: number } | null {
    if (buf.length < 5 || buf[0] !== SOF) {
      return null;
    }
    const len: number = buf[3];
    const total: number = 4 + len + 4;
    if (buf.length < total) {
      return null;
    }
    const v3: Uint8Array = buf.slice(4, 4 + len + 4);
    const vendor: number = (v3[0] << 8) | v3[1];
    const desc: number = (v3[2] << 8) | v3[3];
    return {
      v: {
        vendor: vendor,
        type: (desc >> 7) & 0x03,
        feature: (desc >> 9) & 0x7F,
        command: desc & 0x7F,
        payload: v3.slice(4),
      },
      next: total,
    };
  }

  // ---- 高频业务封装（载荷语义见 PROTOCOL.md A.5/A.6/A.7） ----

  /** ANC 设置帧（DLCI 2 下发）；mode 取 AncMode */
  export function ancSet(mode: number): Uint8Array {
    return buildFrame(VER_V3, buildV3(VENDOR_QTIL_V3, Feat.ANC_V2, PktType.CMD,
      AncCmd.SET_MODE, new Uint8Array([mode & 0xFF])));
  }

  /** ANC 查询帧 */
  export function ancGet(): Uint8Array {
    return buildFrame(VER_V3, buildV3(VENDOR_QTIL_V3, Feat.ANC_V2, PktType.CMD,
      AncCmd.GET_MODE));
  }

  /** 电量轮询对（和官方 App 一样连发两帧） */
  export function batteryPoll(): Uint8Array[] {
    return [
      buildFrame(VER_V3, buildV3(VENDOR_QTIL_V3, Feat.BATTERY, PktType.CMD, BattCmd.GET_SUPPORTED)),
      buildFrame(VER_V3, buildV3(VENDOR_QTIL_V3, Feat.BATTERY, PktType.CMD, BattCmd.GET_LEVELS,
        new Uint8Array([0x01, 0x02]))),
    ];
  }

  /** 电量 TLV 解析：`01 64 02 64 03 64` → [100, 100, 100]（id 疑似 左/右/仓，待低电量包二次确认） */
  export function parseBattery(payload: Uint8Array): number[] {
    const levels: number[] = [];
    for (let i = 0; i + 1 < payload.length; i += 2) {
      levels[payload[i]] = payload[i + 1];
    }
    return levels;
  }

  /** EQ 预设查询帧 */
  export function eqGetPreset(): Uint8Array {
    return buildFrame(VER_V3, buildV3(VENDOR_QTIL_V3, Feat.MUSIC_PROCESSING, PktType.CMD,
      EqCmd.GET_PRESET, new Uint8Array([0x3F])));
  }

  /** PEQ 下发帧（blob 语义待专项抓包，见 PROTOCOL.md A.7；此处只做透传封装） */
  export function eqSetPeq(blob: Uint8Array): Uint8Array {
    return buildFrame(VER_V3, buildV3(VENDOR_QTIL_V3, Feat.MUSIC_PROCESSING, PktType.CMD,
      EqCmd.SET_PEQ, blob));
  }
}
