import { MirageBle, MirageSession } from './ble/MirageBle';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 设备页：对标图 2（FreeBuds 7 风格深紫渐变 + 电量胶囊 + 设备卡 + 噪声控制 + 底部 Tab）。
 * 耳机渲染图暂用占位胶囊，待主人提供 Mirage 官方渲染图后替换 $media:mirage_buds。
 */
@Entry
@Component
struct DevicePage {
  @State deviceName: string = 'Mirage';
  @State statusText: string = '未连接';
  @State leftBattery: number = -1;
  @State rightBattery: number = -1;
  @State caseBattery: number = -1;
  @State ancMode: number = 0; // 0 关闭 1 透传 2 降噪
  @State fwVersion: string = '';
  @State currentTab: number = 0;

  private session: MirageSession = new MirageSession();

  /** 电量文案：-1 显示 --（未上报通道，待抓包回填，见 PROTOCOL.md） */
  private battText(v: number): string {
    return v < 0 ? '--' : `${v}%`;
  }

  private async onConnect(): Promise<void> {
    this.statusText = '扫描中…';
    MirageSession.scan((devices) => {
      if (devices.length === 0) {
        return;
      }
      MirageSession.stopScan();
      const id: string = devices[0].deviceId;
      this.statusText = `连接中…`;
      this.session.connect(id).then(async () => {
        this.statusText = '已连接';
        // TODO(抓包回填): 电量/左右/充电仓字段解码，回包原文先打日志
        const fw: Uint8Array = await this.session.getFwVersion();
        this.fwVersion = Array.from(fw).map((b) => b.toString(16).padStart(2, '0')).join(' ');
        hilog.info(0x0000, 'Mirage', 'fw raw: %{public}s', this.fwVersion);
      }).catch((e) => {
        this.statusText = `失败：${JSON.stringify(e)?.slice(0, 60)}`;
      });
    });
  }

  private onAnc(mode: number): void {
    this.ancMode = mode;
    // TODO(抓包回填): ANC 不走 9ECA，待 btsnoop 确认 Gaia/Airoha 通道后再下发
    hilog.info(0x0000, 'Mirage', 'anc select(仅本地态): %{public}d', mode);
  }

  build() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        Scroll() {
          Column({ space: 12 }) {
            // 标题栏
            Row() {
              Text(`${this.deviceName} ▾`).fontSize(26).fontWeight(FontWeight.Bold).fontColor(Color.White);
              Blank();
              Text(this.statusText).fontSize(12).fontColor('#AAAAAA');
            }.width('100%').padding({ left: 20, right: 20, top: 16 });

            // 品牌徽标
            Row() {
              Text('M I R A G E').fontSize(12).fontColor('#E8C87A')
                .backgroundColor('rgba(232,200,122,0.15)')
                .borderRadius(12).padding({ left: 14, right: 14, top: 4, bottom: 4 });
            }.width('100%').padding({ left: 20 });

            // 耳机占位区（待替换渲染图）
            Row({ space: 24 }) {
              Column() {
                Text('L').fontSize(40).fontColor('rgba(255,255,255,0.75)')
                  .width(84).height(150).textAlign(TextAlign.Center)
                  .backgroundColor('rgba(255,255,255,0.10)').borderRadius(42);
                Text(this.battText(this.leftBattery)).fontSize(14).fontColor(Color.White).margin({ top: 6 });
              }
              Column() {
                Text('R').fontSize(40).fontColor('rgba(255,255,255,0.75)')
                  .width(84).height(150).textAlign(TextAlign.Center)
                  .backgroundColor('rgba(255,255,255,0.10)').borderRadius(42);
                Text(this.battText(this.rightBattery)).fontSize(14).fontColor(Color.White).margin({ top: 6 });
              }
            }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 8 });

            // 连接按钮
            Button('连接耳机', { type: ButtonType.Capsule })
              .onClick(() => this.onConnect())
              .width('60%').margin({ top: 4 });
            if (this.fwVersion !== '') {
              Text(`FW: ${this.fwVersion}`).fontSize(11).fontColor('#888888');
            }

            // 声音
            Text('声音').fontSize(18).fontWeight(FontWeight.Medium).fontColor(Color.White)
              .width('100%').padding({ left: 20 }).margin({ top: 8 });
            Column({ space: 8 }) {
              Text('噪声控制').fontSize(16).fontColor(Color.White).width('100%');
              Row() {
                Button('关闭').flexGrow(1).type(this.ancMode === 0 ? ButtonType.Capsule : ButtonType.Normal)
                  .onClick(() => this.onAnc(0));
                Button('透传').flexGrow(1).type(this.ancMode === 1 ? ButtonType.Capsule : ButtonType.Normal)
                  .onClick(() => this.onAnc(1));
                Button('降噪').flexGrow(1).type(this.ancMode === 2 ? ButtonType.Capsule : ButtonType.Normal)
                  .onClick(() => this.onAnc(2));
              }.width('100%')
            }
            .width('92%').padding(16)
            .backgroundColor('rgba(255,255,255,0.06)').borderRadius(20);
          }.width('100%')
        }.scrollBar(BarState.Off)
      }.tabBar('设备')

      TabContent() {
        Column() {
          Text('发现').fontSize(24).fontColor(Color.White);
          Text('新品 / 活动位（占位）').fontSize(14).fontColor('#AAAAAA');
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }.tabBar('发现')

      TabContent() {
        Column() {
          Text('我的').fontSize(24).fontColor(Color.White);
          Text(`固件：${this.fwVersion === '' ? '未连接' : this.fwVersion}`).fontSize(14).fontColor('#AAAAAA');
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }.tabBar('我的')
    }
    .barMode(BarMode.Fixed)
    .width('100%').height('100%')
    .backgroundColor('#0B0B12')
    .linearGradient({
      angle: 180,
      colors: [['#3A2E5C', 0], ['#14141F', 0.45], ['#0B0B12', 1]]
    })
    .onChange((i: number) => { this.currentTab = i; })
  }
}
