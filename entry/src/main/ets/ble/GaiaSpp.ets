/**
 * Gaia V3 over RFCOMM SPP — MOONDROP MIRAGE 主控协议。
 *
 * 证据：PROTOCOL.md 附录 A（btsnoop 194 帧链式验证 + jadx 反编译交叉印证）
 * - transport: [FF][VER][FLAGS][LEN(1B)][V3PDU = LEN+4]，无 checksum
 * - V3PDU:    vendor U16BE | command U16BE | payload
 *             command = feature[9:15] | type[7:8] | cmd[0:6]
 * - 9ECA GATT（PROTOCOL.md §1-§2）是双设备音频源切换专用，本控制器走 SPP。
 *
 * 链路：socket.sppConnect(uuid=1101) → V1 握手 → V3 命令/响应配对
 */

import { socket } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** transport 常量（GaiaFormatter$Rfcomm.Frame.Header 反编译值） */
export const GAIA_SOF: number = 0xFF;
export const GAIA_VER_V1: number = 0x01;
export const GAIA_VER_V3: number = 0x04;
/** QTILVendorIDs 反编译值 */
export const VENDOR_QTIL_V1V2: number = 10;
export const VENDOR_QTIL_V3: number = 29;
/** 标准串口服务 UUID（Gaia 走该 UUID 的 RFCOMM 通道） */
export const GAIA_SPP_UUID: string = '00001101-0000-1000-8000-00805F9B34FB';

/** V3 包类型（V3PacketType 实锤） */
export enum PktType {
  CMD = 0,
  NOTIF = 1,
  RESP = 2,
  ERR = 3
}

/** QTILFeature（实锤，全表见 PROTOCOL.md A.4） */
export enum Feat {
  BASIC = 0,
  ANC = 2,
  MUSIC_PROCESSING = 5,
  BATTERY = 13,
  VOICE = 14,
  DAC_GAIN = 15,
  CODEC_TYPE = 16,
  LED = 19,
  ONEBRINGTWO = 20,
  TOUCHV2 = 22,
  ANC_V2 = 32
}

/** ANC_V2 命令（V3AncV2Plugin$COMMANDS 实锤） */
export enum AncCmd {
  GET_MODE = 3,
  SET_MODE = 4,
  GET_SWITCH_CONF = 41,
  SET_SWITCH_CONF = 42
}

/** ANC 模式（AncV2Handler 常量 + 主人确认语义） */
export enum AncMode {
  OFF = 0,
  ANC_ON = 1,
  TRANSPARENT = 2,
  ANTI_WIND = 3,
  /** 04 = App 上的“降噪”档（自适应降噪） */
  ADAPTIVE = 4,
  LIVE = 5
}

/** BATTERY 命令（空中包行为归纳） */
export enum BattCmd {
  GET_SUPPORTED = 0,
  GET_LEVELS = 1
}

/** BASIC 命令（空中包行为归纳） */
export enum BasicCmd {
  GET_VERSION = 5,
  GET_SN_LEFT = 20,
  GET_SN_RIGHT = 21
}

/** ONEBRINGTWO（双设备）命令 */
export enum DuplexCmd {
  GET_STATUS = 1,
  GET_SWITCH = 3,
  GET_PEERS = 5
}

/** 解出的一帧 V3 */
export interface V3Frame {
  vendor: number;
  type: number;
  feature: number;
  command: number;
  payload: Uint8Array;
}

/** 一帧解析结果（next = 下一帧起始偏移） */
export interface ParsedFrame {
  frame: V3Frame;
  next: number;
}

/** 电量 TLV 解析结果：left/right/case 为 -1 表示未上报 */
export interface BatteryLevels {
  left: number;
  right: number;
  caseBatt: number;
}

/** 命令收发配对项 */
interface Pending {
  key: number;
  resolve: (payload: Uint8Array) => void;
  timer: number;
}

/** Gaia 载荷编解码（纯函数，无状态） */
export class Gaia {
  static key(feature: number, cmd: number): number {
    return (feature << 8) | cmd;
  }

  /** 组 transport 帧（FLAGS 全 0，无 checksum） */
  static buildFrame(ver: number, v3: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(4 + v3.length);
    out[0] = GAIA_SOF;
    out[1] = ver & 0xFF;
    out[2] = 0x00;
    out[3] = (v3.length - 4) & 0xFF;
    out.set(v3, 4);
    return out;
  }

  /** 组 V3 包 */
  static buildV3(vendor: number, feat: number, type: number, cmd: number,
    payload?: Uint8Array): Uint8Array {
    const body: Uint8Array = payload === undefined ? new Uint8Array(0) : payload;
    const out: Uint8Array = new Uint8Array(4 + body.length);
    out[0] = (vendor >> 8) & 0xFF;
    out[1] = vendor & 0xFF;
    const desc: number = ((feat & 0x7F) << 9) | ((type & 0x03) << 7) | (cmd & 0x7F);
    out[2] = (desc >> 8) & 0xFF;
    out[3] = desc & 0xFF;
    out.set(body, 4);
    return out;
  }

  /** 业务帧便捷构造 */
  static v3frame(feat: number, type: number, cmd: number, payload?: Uint8Array): Uint8Array {
    return Gaia.buildFrame(GAIA_VER_V3, Gaia.buildV3(VENDOR_QTIL_V3, feat, type, cmd, payload));
  }

  /** 解析一帧；不是完整帧返回 null */
  static parseFrame(buf: Uint8Array): ParsedFrame | null {
    if (buf.length < 5 || buf[0] !== GAIA_SOF) {
      return null;
    }
    const len: number = buf[3];
    const total: number = 4 + len + 4;
    if (buf.length < total) {
      return null;
    }
    const pdu: Uint8Array = buf.slice(4, total);
    const vendor: number = (pdu[0] << 8) | pdu[1];
    const desc: number = (pdu[2] << 8) | pdu[3];
    const f: V3Frame = {
      vendor: vendor,
      type: (desc >> 7) & 0x03,
      feature: (desc >> 9) & 0x7F,
      command: desc & 0x7F,
      payload: pdu.slice(4)
    };
    return { frame: f, next: total };
  }

  /** ANC 设置帧 */
  static ancSet(mode: number): Uint8Array {
    return Gaia.v3frame(Feat.ANC_V2, PktType.CMD, AncCmd.SET_MODE, new Uint8Array([mode & 0xFF]));
  }

  /** ANC 查询帧 */
  static ancGet(): Uint8Array {
    return Gaia.v3frame(Feat.ANC_V2, PktType.CMD, AncCmd.GET_MODE);
  }

  /** 电量轮询两帧（与官方 App 一致） */
  static batteryPoll(): Array<Uint8Array> {
    const out: Array<Uint8Array> = [];
    out.push(Gaia.v3frame(Feat.BATTERY, PktType.CMD, BattCmd.GET_SUPPORTED));
    out.push(Gaia.v3frame(Feat.BATTERY, PktType.CMD, BattCmd.GET_LEVELS, new Uint8Array([0x01, 0x02])));
    return out;
  }

  /** 固件版本查询 */
  static getVersion(): Uint8Array {
    return Gaia.v3frame(Feat.BASIC, PktType.CMD, BasicCmd.GET_VERSION);
  }

  /** 序列号查询 */
  static getSn(left: boolean): Uint8Array {
    return Gaia.v3frame(Feat.BASIC, PktType.CMD,
      left ? BasicCmd.GET_SN_LEFT : BasicCmd.GET_SN_RIGHT);
  }

  /** 双设备对端查询 */
  static getPeers(): Uint8Array {
    return Gaia.v3frame(Feat.ONEBRINGTWO, PktType.CMD, DuplexCmd.GET_PEERS);
  }

  /** 电量 TLV：`01 54 02 56 03 ff` → left=84 right=86 case=-1（0xFF = 该路未上报/仓未接入） */
  static parseBattery(payload: Uint8Array): BatteryLevels {
    const levels: number[] = [-1, -1, -1, -1];
    for (let i = 0; i + 1 < payload.length; i += 2) {
      const id: number = payload[i];
      const val: number = payload[i + 1];
      if (id >= 0 && id <= 3 && val !== 0xFF && val <= 100) {
        levels[id] = val;
      }
    }
    return { left: levels[1], right: levels[2], caseBatt: levels[3] };
  }

  /** HEX 打印（调试用） */
  static hex(buf: Uint8Array): string {
    let s: string = '';
    for (let i = 0; i < buf.length; i++) {
      const h: string = buf[i].toString(16);
      s += (h.length === 1 ? '0' + h : h) + (i + 1 < buf.length ? ' ' : '');
    }
    return s;
  }

  /** ASCII 解码（固件版本 / SN / 对端名都是 ASCII） */
  static ascii(buf: Uint8Array, from: number): string {
    let s: string = '';
    for (let i = from; i < buf.length; i++) {
      const c: number = buf[i];
      if (c === 0) {
        break;
      }
      if (c >= 32 && c < 127) {
        s += String.fromCharCode(c);
      }
    }
    return s;
  }
}

/** Gaia SPP 会话（连接 / 收发 / 命令配对） */
export class GaiaLink {
  private clientSock: number = -1;
  private rx: Uint8Array = new Uint8Array(0);
  private pendings: Array<Pending> = [];
  private nextTimer: number = 1;

  /** 建链并完成 V1 握手（RFCOMM 由系统栈负责，无需手工组 UIH） */
  connect(deviceId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const opts: socket.SppOptions = {
        uuid: GAIA_SPP_UUID,
        secure: false,
        type: socket.SppType.SPP_RFCOMM
      };
      socket.sppConnect(deviceId, opts, (err, sock: number) => {
        if (err && err.code !== 0) {
          reject(new Error('sppConnect failed: ' + err.code));
          return;
        }
        this.clientSock = sock;
        socket.on('sppRead', sock, (data: ArrayBuffer) => {
          this.onBytes(new Uint8Array(data));
        });
        // V1 版本协商帧（空中包原文回放）
        this.writeRaw(new Uint8Array([0xFF, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x03, 0x00]));
        resolve();
      });
    });
  }

  isReady(): boolean {
    return this.clientSock >= 0;
  }

  private writeRaw(frame: Uint8Array): void {
    if (this.clientSock < 0) {
      return;
    }
    const buf: ArrayBuffer = frame.buffer.slice(frame.byteOffset,
      frame.byteOffset + frame.byteLength) as ArrayBuffer;
    socket.sppWrite(this.clientSock, buf);
  }

  private onBytes(chunk: Uint8Array): void {
    const merged: Uint8Array = new Uint8Array(this.rx.length + chunk.length);
    merged.set(this.rx, 0);
    merged.set(chunk, this.rx.length);
    this.rx = merged;
    while (true) {
      if (this.rx.length < 5) {
        break;
      }
      // 重同步：丢弃 SOF 之前的杂散字节（btsnoop 实测有零星失步）
      if (this.rx[0] !== GAIA_SOF) {
        let i: number = 1;
        while (i < this.rx.length && this.rx[i] !== GAIA_SOF) {
          i++;
        }
        this.rx = this.rx.slice(i);
        continue;
      }
      const parsed: ParsedFrame | null = Gaia.parseFrame(this.rx);
      if (parsed === null) {
        break;
      }
      this.rx = this.rx.slice(parsed.next);
      this.dispatch(parsed.frame);
    }
  }

  private dispatch(f: V3Frame): void {
    if (f.type !== PktType.RESP && f.type !== PktType.NOTIF) {
      return;
    }
    const k: number = Gaia.key(f.feature, f.command);
    for (let i = 0; i < this.pendings.length; i++) {
      if (this.pendings[i].key === k) {
        const p: Pending = this.pendings[i];
        this.pendings.splice(i, 1);
        clearTimeout(p.timer);
        p.resolve(f.payload);
        return;
      }
    }
  }

  /** 发一帧并等同 feature+cmd 的 RESP/NOTIF */
  send(frame: Uint8Array, feature: number, cmd: number, timeoutMs: number = 4000): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve, reject) => {
      if (this.clientSock < 0) {
        reject(new Error('gaia link not ready'));
        return;
      }
      const k: number = Gaia.key(feature, cmd);
      const item: Pending = {
        key: k,
        resolve: resolve,
        timer: setTimeout(() => {
          for (let i = 0; i < this.pendings.length; i++) {
            if (this.pendings[i].key === k) {
              this.pendings.splice(i, 1);
              break;
            }
          }
          reject(new Error('gaia timeout f=' + feature + ' c=' + cmd));
        }, timeoutMs) as number
      };
      this.pendings.push(item);
      this.writeRaw(frame);
    });
  }

  /** ANC 设置（图 2 三档：关闭 0 / 透传 2 / 降噪 4） */
  async setAnc(mode: number): Promise<number> {
    const r: Uint8Array = await this.send(Gaia.ancSet(mode), Feat.ANC_V2, AncCmd.SET_MODE);
    return r.length > 0 ? r[0] : mode;
  }

  /** ANC 查询 */
  async getAnc(): Promise<number> {
    const r: Uint8Array = await this.send(Gaia.ancGet(), Feat.ANC_V2, AncCmd.GET_MODE);
    return r.length > 0 ? r[0] : -1;
  }

  /** 电量轮询 */
  async getBattery(): Promise<BatteryLevels> {
    const frames: Array<Uint8Array> = Gaia.batteryPoll();
    const sup: Uint8Array = await this.send(frames[0], Feat.BATTERY, BattCmd.GET_SUPPORTED);
    const levels: Uint8Array = await this.send(frames[1], Feat.BATTERY, BattCmd.GET_LEVELS);
    hilog.info(0x0000, 'Mirage', 'batt supported=%{public}s levels=%{public}s',
      Gaia.hex(sup), Gaia.hex(levels));
    return Gaia.parseBattery(levels);
  }

  /** 固件版本（ASCII） */
  async getFirmware(): Promise<string> {
    const r: Uint8Array = await this.send(Gaia.getVersion(), Feat.BASIC, BasicCmd.GET_VERSION);
    return Gaia.ascii(r, 0);
  }

  /** 左右序列号（ASCII） */
  async getSn(): Promise<string> {
    const l: Uint8Array = await this.send(Gaia.getSn(true), Feat.BASIC, BasicCmd.GET_SN_LEFT);
    const r: Uint8Array = await this.send(Gaia.getSn(false), Feat.BASIC, BasicCmd.GET_SN_RIGHT);
    return Gaia.ascii(l, 0) + ' / ' + Gaia.ascii(r, 0);
  }

  /** 双设备对端列表（`00 + MAC 12B + ASCII 名`） */
  async getPeers(): Promise<Array<string>> {
    const r: Uint8Array = await this.send(Gaia.getPeers(), Feat.ONEBRINGTWO, DuplexCmd.GET_PEERS);
    const out: Array<string> = [];
    if (r.length > 13) {
      const name: string = Gaia.ascii(r, 13);
      if (name.length > 0) {
        out.push(name);
      }
    }
    return out;
  }

  disconnect(): void {
    for (let i = 0; i < this.pendings.length; i++) {
      clearTimeout(this.pendings[i].timer);
    }
    this.pendings = [];
    this.rx = new Uint8Array(0);
    if (this.clientSock >= 0) {
      try {
        socket.off('sppRead', this.clientSock);
        socket.sppCloseClientSocket(this.clientSock);
      } catch (e) {
        // 已断开，忽略
      }
      this.clientSock = -1;
    }
  }
}
