import { connection, access, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Gaia, GaiaLink, AncMode, BatteryLevels } from '../ble/GaiaSpp';

const TAG: string = 'Mirage';
const MIRAGE_NAME: string = 'MOONDROP MIRAGE';
const POLL_MS: number = 3000;

interface FoundDev {
  id: string;
  name: string;
  rssi: number;
}

@Entry
@Component
struct DevicePage {
  @State statusText: string = '未连接';
  @State deviceName: string = 'Mirage';
  @State fwVersion: string = '';
  @State snInfo: string = '';
  @State leftBatt: number = -1;
  @State rightBatt: number = -1;
  @State caseBatt: number = -1;
  @State ancMode: number = -1;
  @State found: Array<FoundDev> = [];
  @State paired: Array<FoundDev> = [];
  @State peers: Array<string> = [];
  @State scanning: boolean = false;
  @State connected: boolean = false;

  private link: GaiaLink = new GaiaLink();
  private timerId: number = -1;
  private manualDisconnected: boolean = false;
  private autoConnecting: boolean = false;

  private log(msg: string): void {
    hilog.info(0x0000, TAG, '%{public}s', msg);
  }

  private logErr(msg: string): void {
    hilog.error(0x0000, TAG, '%{public}s', msg);
  }

  aboutToAppear(): void {
    connection.on('discoveryResult', (results: Array<connection.DiscoveryResult>) => {
      this.onFound(results);
    });
    this.loadPaired();
    this.tryAutoConnect();
  }

  /** 每次回到前台再探一次：耳机可能刚连上手机 */
  onPageShow(): void {
    if (!this.connected && !this.manualDisconnected) {
      this.loadPaired();
      this.tryAutoConnect();
    }
  }

  /**
   * 进页面自动接管：耳机已与手机连接时，直接建 Gaia 会话进入降噪控制台，
   * 用户不必再点一次「连接」。没连则安静地保持扫描/已配对列表。
   */
  private async tryAutoConnect(): Promise<void> {
    if (this.connected || this.autoConnecting || this.manualDisconnected) {
      return;
    }
    let mirageId: string = '';
    let mirageName: string = '';
    for (let i = 0; i < this.paired.length; i++) {
      const n: string = this.paired[i].name;
      if (n === MIRAGE_NAME || n.indexOf('MIRAGE') >= 0) {
        mirageId = this.paired[i].id;
        mirageName = n;
        break;
      }
    }
    if (mirageId.length === 0) {
      return;
    }
    // 没连任何蓝牙设备就别白等 SPP 超时
    let anyConnected: boolean = false;
    try {
      anyConnected = connection.getProfileConnectionState() ===
        constant.ProfileConnectionState.STATE_CONNECTED;
    } catch (e) {
      anyConnected = false;
    }
    if (!anyConnected) {
      return;
    }
    this.autoConnecting = true;
    this.statusText = '自动连接中…';
    try {
      await this.startSession(mirageId, mirageName);
    } catch (e) {
      this.statusText = '未连接';
      this.link.disconnect();
      this.connected = false;
      this.log('auto connect skipped');
    }
    this.autoConnecting = false;
  }

  /** 建链后的统一初始化（手动连接 / 自动接管共用） */
  private async startSession(id: string, name: string): Promise<void> {
    await this.link.connect(id);
    this.connected = true;
    this.manualDisconnected = false;
    this.deviceName = name.length === 0 ? 'Mirage' : name;
    this.statusText = '已连接';
    await this.refreshAll();
    if (this.timerId < 0) {
      this.timerId = setInterval(() => {
        this.refreshBattery();
      }, POLL_MS) as number;
    }
  }

  /** 已配对设备：耳机连着时不会出现在扫描结果里，这条路径是必需的 */
  private loadPaired(): void {
    try {
      const ids: Array<string> = connection.getPairedDevices();
      const list: Array<FoundDev> = [];
      for (let i = 0; i < ids.length; i++) {
        let name: string = '';
        try {
          name = connection.getRemoteDeviceName(ids[i]);
        } catch (e) {
          name = '';
        }
        list.push({ id: ids[i], name: name, rssi: 0 });
      }
      list.sort((a: FoundDev, b: FoundDev) => {
        const am: number = a.name === MIRAGE_NAME ? 0 : 1;
        const bm: number = b.name === MIRAGE_NAME ? 0 : 1;
        return am - bm;
      });
      this.paired = list;
    } catch (e) {
      this.log('paired list skipped');
    }
  }

  aboutToDisappear(): void {
    this.stopAll();
    connection.off('discoveryResult');
  }

  private stopAll(): void {
    try {
      connection.stopBluetoothDiscovery();
    } catch (e) {
      this.log('stop discovery skipped');
    }
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.link.disconnect();
    this.scanning = false;
    this.connected = false;
  }

  private battText(v: number): string {
    return v < 0 ? '--' : v.toString() + '%';
  }

  private ancText(): string {
    if (this.ancMode === AncMode.OFF) {
      return '关闭';
    } else if (this.ancMode === AncMode.TRANSPARENT) {
      return '透传';
    } else if (this.ancMode === AncMode.ADAPTIVE) {
      return '降噪';
    } else if (this.ancMode === AncMode.ANC_ON) {
      return '降噪(标准)';
    } else if (this.ancMode === AncMode.ANTI_WIND) {
      return '抗风噪';
    } else if (this.ancMode === AncMode.LIVE) {
      return '现场感';
    }
    return '未知';
  }

  private async ensureReady(): Promise<boolean> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = [
        'ohos.permission.ACCESS_BLUETOOTH',
        'ohos.permission.APPROXIMATELY_LOCATION'
      ];
      await at.requestPermissionsFromUser(ctx, perms);
    } catch (e) {
      this.log('permission request skipped');
    }
    try {
      if (access.getState() !== access.BluetoothState.STATE_ON) {
        await access.enableBluetoothAsync();
      }
    } catch (e) {
      this.statusText = '请先打开蓝牙';
      return false;
    }
    return true;
  }

  private onFound(results: Array<connection.DiscoveryResult>): void {
    const list: Array<FoundDev> = this.found.slice();
    for (let i = 0; i < results.length; i++) {
      const r: connection.DiscoveryResult = results[i];
      const item: FoundDev = { id: r.deviceId, name: r.deviceName, rssi: r.rssi };
      let hit: number = -1;
      for (let j = 0; j < list.length; j++) {
        if (list[j].id === r.deviceId) {
          hit = j;
          break;
        }
      }
      if (hit >= 0) {
        list[hit] = item;
      } else {
        list.push(item);
      }
    }
    list.sort((a: FoundDev, b: FoundDev) => {
      const am: number = a.name === MIRAGE_NAME ? 0 : 1;
      const bm: number = b.name === MIRAGE_NAME ? 0 : 1;
      if (am !== bm) {
        return am - bm;
      }
      return b.rssi - a.rssi;
    });
    this.found = list;
  }

  private async onScan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    const ok: boolean = await this.ensureReady();
    if (!ok) {
      return;
    }
    this.found = [];
    this.statusText = '扫描中…';
    this.scanning = true;
    try {
      connection.startBluetoothDiscovery();
    } catch (e) {
      this.statusText = '扫描启动失败';
      this.scanning = false;
      return;
    }
    setTimeout(() => {
      try {
        connection.stopBluetoothDiscovery();
      } catch (e) {
        this.log('stop discovery skipped');
      }
      this.scanning = false;
      if (!this.connected) {
        this.statusText = this.found.length === 0 ? '未发现设备' : '发现 ' + this.found.length.toString() + ' 台';
      }
    }, 12000);
  }

  private async onConnect(id: string, name: string): Promise<void> {
    if (this.connected) {
      return;
    }
    this.statusText = '连接中…';
    try {
      const bonded: boolean = connection.getPairState(id) === connection.BondState.BOND_STATE_BONDED;
      if (!bonded) {
        await connection.pairDevice(id);
      }
    } catch (e) {
      this.log('pair skipped');
    }
    try {
      await this.startSession(id, name);
    } catch (e) {
      this.logErr('connect failed');
      this.statusText = '连接失败';
      this.link.disconnect();
      this.connected = false;
    }
  }

  private async refreshAll(): Promise<void> {
    // 电量先查：连上就能看到数字，其余信息随后补齐
    await this.refreshBattery();
    try {
      this.fwVersion = await this.link.getFirmware();
    } catch (e) {
      this.log('firmware skipped');
    }
    try {
      this.snInfo = await this.link.getSn();
    } catch (e) {
      this.log('sn skipped');
    }
    try {
      this.ancMode = await this.link.getAnc();
    } catch (e) {
      this.log('anc query skipped');
    }
    try {
      this.peers = await this.link.getPeers();
    } catch (e) {
      this.log('peers skipped');
    }
    await this.refreshBattery();
  }

  private async refreshBattery(): Promise<void> {
    if (!this.connected) {
      return;
    }
    try {
      const b: BatteryLevels = await this.link.getBattery();
      if (b.left >= 0) {
        this.leftBatt = b.left;
      }
      if (b.right >= 0) {
        this.rightBatt = b.right;
      }
      if (b.caseBatt >= 0) {
        this.caseBatt = b.caseBatt;
      }
    } catch (e) {
      this.log('battery poll skipped');
    }
  }

  private async onAnc(mode: number): Promise<void> {
    if (!this.connected) {
      this.statusText = '请先连接耳机';
      return;
    }
    try {
      this.ancMode = await this.link.setAnc(mode);
      this.statusText = '已连接 · ' + this.ancText();
    } catch (e) {
      this.statusText = '降噪切换失败';
    }
  }

  private onDisconnect(): void {
    this.manualDisconnected = true;
    this.stopAll();
    this.statusText = '未连接';
    this.deviceName = 'Mirage';
    this.leftBatt = -1;
    this.rightBatt = -1;
    this.caseBatt = -1;
    this.ancMode = -1;
    this.fwVersion = '';
    this.snInfo = '';
    this.peers = [];
    this.loadPaired();
  }

  build() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        Scroll() {
          Column({ space: 12 }) {
            Row() {
              Text(this.deviceName + ' ▾')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.statusText)
                .fontSize(11)
                .fontColor('#AAAAAA')
                .maxLines(1)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 16 })

            Row() {
              Text('M I R A G E')
                .fontSize(12)
                .fontColor('#E8C87A')
                .backgroundColor('rgba(232,200,122,0.15)')
                .borderRadius(12)
                .padding({ left: 14, right: 14, top: 4, bottom: 4 })
            }
            .width('100%')
            .padding({ left: 20 })

            Row({ space: 20 }) {
              Column() {
                Text('L')
                  .fontSize(28)
                  .fontColor('rgba(255,255,255,0.75)')
                  .width(84)
                  .height(150)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('rgba(255,255,255,0.10)')
                  .borderRadius(42)
                Text(this.battText(this.leftBatt)).fontSize(14).fontColor(Color.White).margin({ top: 6 })
              }
              Column() {
                Text('R')
                  .fontSize(28)
                  .fontColor('rgba(255,255,255,0.75)')
                  .width(84)
                  .height(150)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('rgba(255,255,255,0.10)')
                  .borderRadius(42)
                Text(this.battText(this.rightBatt)).fontSize(14).fontColor(Color.White).margin({ top: 6 })
              }
              Column() {
                Text('仓')
                  .fontSize(28)
                  .fontColor('rgba(255,255,255,0.75)')
                  .width(84)
                  .height(150)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('rgba(255,255,255,0.10)')
                  .borderRadius(42)
                Text(this.battText(this.caseBatt)).fontSize(14).fontColor(Color.White).margin({ top: 6 })
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 8 })

            Button(this.connected ? '断开连接' : (this.scanning ? '扫描中…' : '扫描耳机'),
              { type: ButtonType.Capsule })
              .width('60%')
              .onClick(() => {
                if (this.connected) {
                  this.onDisconnect();
                } else {
                  this.onScan();
                }
              })

            if (this.paired.length > 0 && !this.connected) {
              Column({ space: 6 }) {
                Text('已配对设备').fontSize(13).fontColor('#999999').width('92%')
                ForEach(this.paired, (d: FoundDev) => {
                  Row() {
                    Column() {
                      Text(d.name.length === 0 ? d.id : d.name)
                        .fontSize(15)
                        .fontColor(Color.White)
                      Text(d.id).fontSize(11).fontColor('#888888')
                    }
                    .alignItems(HorizontalAlign.Start)
                    Blank()
                    Button('连接', { type: ButtonType.Capsule })
                      .fontSize(13)
                      .onClick(() => {
                        this.onConnect(d.id, d.name);
                      })
                  }
                  .width('92%')
                  .padding(12)
                  .backgroundColor(d.name === MIRAGE_NAME ? 'rgba(232,200,122,0.12)' : 'rgba(255,255,255,0.04)')
                  .borderRadius(16)
                }, (d: FoundDev) => 'p' + d.id)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }

            if (this.found.length > 0 && !this.connected) {
              Column({ space: 6 }) {
                ForEach(this.found, (d: FoundDev) => {
                  Row() {
                    Column() {
                      Text(d.name.length === 0 ? d.id : d.name)
                        .fontSize(15)
                        .fontColor(Color.White)
                      Text(d.id).fontSize(11).fontColor('#888888')
                    }
                    .alignItems(HorizontalAlign.Start)
                    Blank()
                    Button('连接', { type: ButtonType.Capsule })
                      .fontSize(13)
                      .onClick(() => {
                        this.onConnect(d.id, d.name);
                      })
                  }
                  .width('92%')
                  .padding(12)
                  .backgroundColor(d.name === MIRAGE_NAME ? 'rgba(232,200,122,0.12)' : 'rgba(255,255,255,0.06)')
                  .borderRadius(16)
                }, (d: FoundDev) => d.id)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }

            if (this.peers.length > 0) {
              Column({ space: 6 }) {
                Text('已连接设备').fontSize(14).fontColor('#CCCCCC').width('92%')
                ForEach(this.peers, (p: string) => {
                  Text(p)
                    .fontSize(14)
                    .fontColor(Color.White)
                    .width('92%')
                    .padding(12)
                    .backgroundColor('rgba(255,255,255,0.06)')
                    .borderRadius(16)
                }, (p: string) => p)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }

            Text('声音')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .width('100%')
              .padding({ left: 20 })
              .margin({ top: 8 })

            Column({ space: 8 }) {
              Row() {
                Text('噪声控制').fontSize(16).fontColor(Color.White)
                Blank()
                Text(this.ancText()).fontSize(13).fontColor('#E8C87A')
              }
              .width('100%')
              Row({ space: 8 }) {
                Button('关闭')
                  .flexGrow(1)
                  .fontSize(13)
                  .type(this.ancMode === AncMode.OFF ? ButtonType.Capsule : ButtonType.Normal)
                  .onClick(() => {
                    this.onAnc(AncMode.OFF);
                  })
                Button('透传')
                  .flexGrow(1)
                  .fontSize(13)
                  .type(this.ancMode === AncMode.TRANSPARENT ? ButtonType.Capsule : ButtonType.Normal)
                  .onClick(() => {
                    this.onAnc(AncMode.TRANSPARENT);
                  })
                Button('降噪')
                  .flexGrow(1)
                  .fontSize(13)
                  .type(this.ancMode === AncMode.ADAPTIVE ? ButtonType.Capsule : ButtonType.Normal)
                  .onClick(() => {
                    this.onAnc(AncMode.ADAPTIVE);
                  })
                Button('风噪')
                  .flexGrow(1)
                  .fontSize(13)
                  .type(this.ancMode === AncMode.ANTI_WIND ? ButtonType.Capsule : ButtonType.Normal)
                  .onClick(() => {
                    this.onAnc(AncMode.ANTI_WIND);
                  })
              }
              .width('100%')
            }
            .width('92%')
            .padding(16)
            .backgroundColor('rgba(255,255,255,0.06)')
            .borderRadius(20)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
      }
      .tabBar('设备')

      TabContent() {
        Column({ space: 8 }) {
          Text('发现').fontSize(24).fontColor(Color.White)
          Text('固件与新品信息（占位）').fontSize(14).fontColor('#AAAAAA')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .tabBar('发现')

      TabContent() {
        Column({ space: 8 }) {
          Text('我的').fontSize(24).fontColor(Color.White)
          Text(this.fwVersion.length === 0 ? '固件：未连接' : '固件：' + this.fwVersion)
            .fontSize(14)
            .fontColor('#AAAAAA')
          if (this.snInfo.length > 0) {
            Text('SN：' + this.snInfo).fontSize(12).fontColor('#888888')
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .tabBar('我的')
    }
    .barMode(BarMode.Fixed)
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0B12')
    .linearGradient({
      angle: 180,
      colors: [['#3A2E5C', 0], ['#14141F', 0.45], ['#0B0B12', 1]]
    })
  }
}
