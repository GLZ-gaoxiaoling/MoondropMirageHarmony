import { ble } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Mirage BLE 协议客户端（水月雨 9ECA 私有服务）。
 *
 * 逆向证据见 ../../../PROTOCOL.md：
 * - GATT 表来自 BleSourceSwitchUuids.<clinit> smali
 * - 帧格式来自 BleSourceSwitchFrames.buildCommand Java 反编译
 * - 命令字来自 BleSourceCommand.<clinit> smali
 * 未经真机抓包验证的部分标 TODO，禁止自行脑补 opcode。
 */
export namespace MirageBle {
  /** GATT 服务与特征 UUID（已实锤） */
  export const UUID_SERVICE = '9ECA0000-7F3A-4F32-9A38-A91B2C6E0100';
  export const UUID_COMMAND = '9ECA0001-7F3A-4F32-9A38-A91B2C6E0100';
  export const UUID_NOTIFY = '9ECA0003-7F3A-4F32-9A38-A91B2C6E0100';

  /** 帧常量（已实锤） */
  export const MAGIC = 0xA5;
  export const PROTOCOL_VERSION = 0x01;
  export const HEADER_SIZE = 4;
  export const MAX_PAYLOAD_SIZE = 255;

  /** 命令字（已实锤，见 PROTOCOL.md 第 3 节） */
  export enum Cmd {
    GET_FW_VERSION = 0x00,
    GET_AUDIO_SOURCE = 0x01,
    SET_AUDIO_SOURCE = 0x02,
    GET_CAPABILITY = 0x03,
    SET_POWER_OFF = 0x04,
    GET_DEVICE_VOLUME = 0x05,
    SET_DEVICE_VOLUME = 0x06,
    GET_PRESET_EQ = 0x07,
    SET_PRESET_EQ = 0x08,
    GET_PEQ_CONFIG = 0x09,
    SET_PEQ_PREGAIN = 0x0A,
    GET_PEQ_POINT = 0x0B,
    SET_PEQ_POINT = 0x0C,
    COMMIT_PEQ = 0x0D,
    GET_MIC_GAIN = 0x0E,
    SET_MIC_GAIN = 0x0F,
    GET_EARBUD_COLOR = 0x11,
    GET_EARBUD_LANGUAGE = 0x13,
    GET_EARBUD_SN_LEFT = 0x15,
    GET_EARBUD_SN_RIGHT = 0x17,
  }

  export interface Frame {
    cmd: number;
    payload: Uint8Array;
  }

  /** 组帧：[A5][01][CMD][LEN][payload...]（无校验和，已实锤） */
  export function buildCommand(cmd: number, payload?: Uint8Array): Uint8Array {
    const body: Uint8Array = payload ?? new Uint8Array(0);
    if (body.length > MAX_PAYLOAD_SIZE) {
      throw new Error(`payload length ${body.length} exceeds 255 bytes`);
    }
    const out = new Uint8Array(body.length + HEADER_SIZE);
    out[0] = MAGIC;
    out[1] = PROTOCOL_VERSION;
    out[2] = cmd & 0xFF;
    out[3] = body.length & 0xFF;
    out.set(body, HEADER_SIZE);
    return out;
  }

  /** 解帧：校验 MAGIC/VERSION/LEN，返回 cmd + payload；非法返回 null */
  export function parseFrame(buf: Uint8Array): Frame | null {
    if (buf.length < HEADER_SIZE) {
      return null;
    }
    if (buf[0] !== MAGIC || buf[1] !== PROTOCOL_VERSION) {
      return null;
    }
    const cmd: number = buf[2];
    const len: number = buf[3];
    if (buf.length < HEADER_SIZE + len) {
      return null;
    }
    return { cmd: cmd, payload: buf.slice(HEADER_SIZE, HEADER_SIZE + len) };
  }
}

/** 9ECA 会话：连接 → 发现服务 → 开通知 → 命令/响应配对（按 cmd id 配对） */
export class MirageSession {
  private client: ble.GattClientDevice | null = null;
  private cmdChar: ble.BLECharacteristic | null = null;
  private notifyChar: ble.BLECharacteristic | null = null;
  private pendings: Map<number, (payload: Uint8Array) => void> = new Map();
  private deviceId: string = '';

  /** 扫描带 9ECA 服务的设备；调用前先在 UI 侧完成权限申请 */
  static scan(onFound: (devices: ble.ScanResult[]) => void): void {
    ble.on('BLEDeviceFind', onFound);
    ble.startBLEScan([{ serviceUuid: MirageBle.UUID_SERVICE }]);
  }

  static stopScan(): void {
    try {
      ble.stopBLEScan();
    } catch (e) {
      hilog.warn(0x0000, 'Mirage', 'stopBLEScan failed: %{public}s', JSON.stringify(e));
    }
  }

  async connect(deviceId: string): Promise<void> {
    this.deviceId = deviceId;
    this.client = ble.createGattClientDevice(deviceId);
    this.client.on('BLEConnectionStateChange', (state) => {
      hilog.info(0x0000, 'Mirage', 'conn state: %{public}s', JSON.stringify(state));
    });
    this.client.on('BLECharacteristicChange', (ch) => this.onNotify(ch));
    this.client.connect();
    // 等待连接成功的同步点：以服务发现成功为准（调用侧可加超时）
    const services: ble.GattService[] = await this.client.getServices();
    const svc: ble.GattService | undefined = services.find(
      (s) => s.serviceUuid.toUpperCase() === MirageBle.UUID_SERVICE.toUpperCase());
    if (!svc) {
      throw new Error('9ECA service not found on device');
    }
    const chars: ble.BLECharacteristic[] = svc.characteristics ?? [];
    this.cmdChar = chars.find(
      (c) => c.characteristicUuid.toUpperCase() === MirageBle.UUID_COMMAND.toUpperCase()) ?? null;
    this.notifyChar = chars.find(
      (c) => c.characteristicUuid.toUpperCase() === MirageBle.UUID_NOTIFY.toUpperCase()) ?? null;
    if (!this.cmdChar || !this.notifyChar || !this.client) {
      throw new Error('9ECA command/notify characteristic missing');
    }
    await this.client.setCharacteristicChangeNotification(this.notifyChar, true);
    hilog.info(0x0000, 'Mirage', '%{public}s', '9ECA session ready');
  }

  private onNotify(ch: ble.BLECharacteristic): void {
    const raw = ch.characteristicValue;
    if (!raw) {
      return;
    }
    const frame = MirageBle.parseFrame(new Uint8Array(raw as ArrayBuffer));
    if (!frame) {
      hilog.warn(0x0000, 'Mirage', '%{public}s', 'drop malformed notify frame');
      return;
    }
    const resolve = this.pendings.get(frame.cmd);
    if (resolve) {
      this.pendings.delete(frame.cmd);
      resolve(frame.payload);
    }
  }

  /** 发命令并等同 cmd 回包；响应体语义见 BleSourceResponse，字段解码待抓包回填 */
  sendCommand(cmd: number, payload?: Uint8Array, timeoutMs: number = 5000): Promise<Uint8Array> {
    if (!this.client || !this.cmdChar) {
      return Promise.reject(new Error('session not ready'));
    }
    const req: Uint8Array = MirageBle.buildCommand(cmd, payload);
    const char: ble.BLECharacteristic = {
      serviceUuid: MirageBle.UUID_SERVICE,
      characteristicUuid: MirageBle.UUID_COMMAND,
      characteristicValue: req.buffer as ArrayBuffer,
    } as ble.BLECharacteristic;
    return new Promise((resolve, reject) => {
      this.pendings.set(cmd, resolve);
      setTimeout(() => {
        if (this.pendings.delete(cmd)) {
          reject(new Error(`cmd 0x${cmd.toString(16)} timeout`));
        }
      }, timeoutMs);
      this.client!.writeCharacteristicValue(char, ble.GattWriteType.WRITE).catch((e) => {
        this.pendings.delete(cmd);
        reject(e);
      });
    });
  }

  // ---- 常用只读命令（回包字段解码待 btsnoop 回填，见 PROTOCOL.md 第 5 节） ----
  getFwVersion(): Promise<Uint8Array> {
    return this.sendCommand(MirageBle.Cmd.GET_FW_VERSION);
  }

  getCapability(): Promise<Uint8Array> {
    return this.sendCommand(MirageBle.Cmd.GET_CAPABILITY);
  }

  getAudioSource(): Promise<Uint8Array> {
    return this.sendCommand(MirageBle.Cmd.GET_AUDIO_SOURCE);
  }

  getDeviceVolume(): Promise<Uint8Array> {
    return this.sendCommand(MirageBle.Cmd.GET_DEVICE_VOLUME);
  }

  getPresetEq(): Promise<Uint8Array> {
    return this.sendCommand(MirageBle.Cmd.GET_PRESET_EQ);
  }

  setPresetEq(index: number): Promise<Uint8Array> {
    return this.sendCommand(MirageBle.Cmd.SET_PRESET_EQ, new Uint8Array([index & 0xFF]));
  }

  // TODO(抓包回填): ANC 三档（关闭/透传/降噪）不走 9ECA（BleSourceCommand 无 ANC 条目），
  // 疑似经 Gaia QTIL(AncHandler/AncV2Handler) 或 Airoha 原厂通道，需 btsnoop 确认后再落地。
  // TODO(抓包回填): 电量上报通道（标准 BAS 0x180F 或 DeviceInfoHandler），需 btsnoop 确认。

  disconnect(): void {
    try {
      this.client?.disconnect();
      this.client?.close();
    } catch (e) {
      hilog.warn(0x0000, 'Mirage', 'disconnect failed: %{public}s', JSON.stringify(e));
    }
    this.client = null;
    this.cmdChar = null;
    this.notifyChar = null;
    this.pendings.clear();
  }
}
