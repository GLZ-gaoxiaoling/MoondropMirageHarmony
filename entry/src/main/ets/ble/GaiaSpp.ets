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
 * Harmony 侧传输：`import { socket } from '@kit.ConnectivityKit'`（API 26 实测 d.ts）：
 * `socket.sppConnect(deviceId, { uuid: SPP_UUID })` 建链（RFCOMM SABM/PN/MSC 由系统栈完成），
 * `socket.sppWrite(sock, buf)` 下发 Gaia 帧，`socket.on('sppRead', sock, cb)` 收包。
 * 本模块只负责 Gaia 载荷编解码；链路管理见底部 GaiaLink。
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

  /** SPP 服务 UUID（标准串口；抓包证实 Gaia 走该 UUID 的 RFCOMM 通道，SDP 走配对缓存） */
  export const SPP_UUID = '00001101-0000-1000-8000-00805F9B34FB';
  /** V1 版本协商帧（空中包原文回放；V1V2Packet 格式待按需反编译，见 PROTOCOL.md） */
  export const V1_HELLO: Uint8Array = new Uint8Array([0xFF, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x03, 0x00]);
}

/**
 * Gaia SPP 会话：sppConnect → V1 握手回放 → V3 命令/响应配对（按 command id）。
 *
 * Harmony 侧 RFCOMM UIH 组帧/SABM/PN/MSC 由系统蓝牙栈完成（Motorola 对端互通实测），
 * 本类只负责 Gaia 载荷。接收不校验 transport checksum（空中包无 checksum）。
 */
export class GaiaLink {
  private sock: number = -1;
  private rxBuf: Uint8Array = new Uint8Array(0);
  private pendings: Map<number, (payload: Uint8Array) => void> = new Map();

  private static key(feature: number, cmd: number): number {
    return (feature << 8) | cmd;
  }

  async connect(deviceId: string,
    socketApi: {
      sppConnect(id: string, opt: object, cb: (e: object, n: number) => void): void;
      sppWrite(s: number, d: ArrayBuffer): void;
      on(t: string, s: number, cb: (d: ArrayBuffer) => void): void;
      sppCloseClientSocket(s: number): void;
    },
    uuid: string = Gaia.SPP_UUID): Promise<void> {
    const self: GaiaLink = this;
    this.sock = await new Promise<number>((resolve, reject) => {
      socketApi.sppConnect(deviceId, { uuid: uuid }, (err: object, n: number) => {
        const code: number = (err as { code?: number }).code ?? -1;
        if (code !== 0 && n < 0) {
          reject(err);
        } else {
          resolve(n);
        }
      });
    });
    socketApi.on('sppRead', this.sock, (data: ArrayBuffer) => self.onBytes(new Uint8Array(data)));
    // V1 握手（原文回放，见上）
    socketApi.sppWrite(this.sock, Gaia.V1_HELLO.buffer as ArrayBuffer);
    this.socketApi = socketApi;
  }

  private socketApi: {
    sppWrite(s: number, d: ArrayBuffer): void;
    sppCloseClientSocket(s: number): void;
  } | null = null;

  private onBytes(chunk: Uint8Array): void {
    const merged = new Uint8Array(this.rxBuf.length + chunk.length);
    merged.set(this.rxBuf, 0);
    merged.set(chunk, this.rxBuf.length);
    this.rxBuf = merged;
    for (;;) {
      const r: { v: Gaia.V3, next: number } | null = Gaia.parseFrame(this.rxBuf);
      if (!r) {
        // 按 SOF 重同步（耳机固件偶发杂散字节，btsnoop 实测有零星失步）
        const i: number = this.rxBuf.indexOf(Gaia.SOF);
        if (i < 0) {
          this.rxBuf = new Uint8Array(0);
        } else if (i > 0) {
          this.rxBuf = this.rxBuf.slice(i);
          continue;
        }
        break;
      }
      this.rxBuf = this.rxBuf.slice(r.next);
      const k: number = GaiaLink.key(r.v.feature, r.v.command);
      const resolve: ((p: Uint8Array) => void) | undefined = this.pendings.get(k);
      if ((r.v.type === Gaia.PktType.RESP || r.v.type === Gaia.PktType.NOTIF) && resolve) {
        this.pendings.delete(k);
        resolve(r.v.payload);
      }
    }
  }

  /** 发 V3 命令并等同 feature+command 的 RESP/NOTIF（5s 超时） */
  send(v3frame: Uint8Array, feature: number, command: number,
    timeoutMs: number = 5000): Promise<Uint8Array> {
    if (!this.socketApi || this.sock < 0) {
      return Promise.reject(new Error('gaia link not ready'));
    }
    const self: GaiaLink = this;
    return new Promise<Uint8Array>((resolve, reject) => {
      const k: number = GaiaLink.key(feature, command);
      self.pendings.set(k, resolve);
      setTimeout(() => {
        if (self.pendings.delete(k)) {
          reject(new Error('gaia cmd timeout f=' + feature + ' c=' + command));
        }
      }, timeoutMs);
      try {
        self.socketApi!.sppWrite(self.sock, v3frame.buffer as ArrayBuffer);
      } catch (e) {
        self.pendings.delete(k);
        reject(e);
      }
    });
  }

  /** ANC 设置（mode 取 Gaia.AncMode；图 2 三档：关闭 0 / 透传 2 / 降噪 4=ADAPTIVE） */
  ancSet(mode: number): Promise<Uint8Array> {
    return this.send(Gaia.buildFrame(Gaia.VER_V3,
      Gaia.buildV3(Gaia.VENDOR_QTIL_V3, Gaia.Feat.ANC_V2, Gaia.PktType.CMD, Gaia.AncCmd.SET_MODE,
        new Uint8Array([mode & 0xFF]))), Gaia.Feat.ANC_V2, Gaia.AncCmd.SET_MODE);
  }

  /** 电量轮询对（和官方 App 一样连发两帧；回包见 Gaia.parseBattery） */
  async batteryPoll(): Promise<Uint8Array[]> {
    const r0: Uint8Array = await this.send(Gaia.buildFrame(Gaia.VER_V3,
      Gaia.buildV3(Gaia.VENDOR_QTIL_V3, Gaia.Feat.BATTERY, Gaia.PktType.CMD, Gaia.BattCmd.GET_SUPPORTED)),
      Gaia.Feat.BATTERY, Gaia.BattCmd.GET_SUPPORTED);
    const r1: Uint8Array = await this.send(Gaia.buildFrame(Gaia.VER_V3,
      Gaia.buildV3(Gaia.VENDOR_QTIL_V3, Gaia.Feat.BATTERY, Gaia.PktType.CMD, Gaia.BattCmd.GET_LEVELS,
        new Uint8Array([0x01, 0x02]))), Gaia.Feat.BATTERY, Gaia.BattCmd.GET_LEVELS);
    return [r0, r1];
  }

  disconnect(): void {
    try {
      this.socketApi?.sppCloseClientSocket(this.sock);
    } catch (e) {
    }
    this.sock = -1;
    this.pendings.clear();
    this.rxBuf = new Uint8Array(0);
  }
}
