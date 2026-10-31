# Mirage BLE 协议逆向结论（证据链）

> 目标：`android-release.apk`（SHA256 `04756b49…795d2d5`）
> 包名 `com.moondroplab.moondrop.moondrop_app`，版本 `2.25.0c-260813ai`
> 签名 `C=CN/ST=szechuan/L=chengdu/O=moondroplab/OU=moondrop/CN=kasuga` ——水月雨官方包
> 方法：REA `inspect-apk-signature / decode-android-resources / inspect-android-package / search-android-classes / inspect-android-class / inspect-android-method`（jadx-headless-mcp 0.7.1，SHA256 `6e5eac…73ff75` 已校验）+ strings 交叉验证
> 复现环境变量：`$env:REA_JADX_MCP_JAR=<…/jadx-headless-mcp-0.7.1-all.jar>`，`$env:JAVA_HOME=<Temurin 21>`，`$env:REA_JADX_OPERATION_TIMEOUT_MS='600000'`

## 1. 传输层（已实锤）

- **BLE GATT 自定义服务**（`BleSourceSwitchUuids.<clinit>` smali 实锤）：
  - SERVICE `9ECA0000-7F3A-4F32-9A38-A91B2C6E0100`
  - COMMAND（写）`9ECA0001-7F3A-4F32-9A38-A91B2C6E0100`
  - NOTIFICATION（通知）`9ECA0003-7F3A-4F32-9A38-A91B2C6E0100`
  - CCCD `00002902-…-00805F9B34FB`（标准）
- 注：`9ECA0002` 不存在，命令走 0001、通知走 0003。
- 扫描：`BleSourceSwitchScanner`，按厂商广播数据过滤（`parseManufacturerData` + `PROTOCOL_ID_AUDIO_SOURCE_FAST_CONTROL = 161 (0xA1)`），默认扫 5s（`DEFAULT_SCAN_TIMEOUT_MS = 5000`）。

## 2. 帧格式（已实锤，`BleSourceSwitchFrames.buildCommand` Java 反编译原文）

```
out = byte[payload.len + 4]
out[0] = 0xA5            // MAGIC = 165
out[1] = 0x01            // PROTOCOL_VERSION = 1
out[2] = cmd.id          // 命令字（下表）
out[3] = payload.length  // ≤255（MAX_PAYLOAD_SIZE），超限直接抛错返回 null
out[4..] = payload       // 原样拷贝，无校验和
```

响应/通知对称解析：`parseFrame / parseResponse / parseNotification`（同类）。
常量：`HEADER_SIZE = 4`，`MAGIC = 165`，`PROTOCOL_VERSION = 1`。

## 3. 命令字（已实锤，`BleSourceCommand.<clinit>` smali，ordinal→id）

| id | 命令 | 备注 |
|----|------|------|
| 0x00 | GET_FW_VERSION | 固件版本 |
| 0x01 / 0x02 | GET/SET_AUDIO_SOURCE | 音源切换（双设备）——“SourceSwitch”即多点切换 |
| 0x03 | GET_CAPABILITY | 能力集 |
| 0x04 | SET_POWER_OFF | 关机 |
| 0x05 / 0x06 | GET/SET_DEVICE_VOLUME | 设备音量 |
| 0x07 / 0x08 | GET/SET_PRESET_EQ | 预设 EQ |
| 0x09 | GET_PEQ_CONFIG | PEQ 配置 |
| 0x0A | SET_PEQ_PREGAIN | PEQ 前级增益 |
| 0x0B / 0x0C | GET/SET_PEQ_POINT | PEQ 频点 |
| 0x0D | COMMIT_PEQ | PEQ 提交生效 |
| 0x0E / 0x0F | GET/SET_MIC_GAIN | 麦克风增益 |
| 0x11 | GET_EARBUD_COLOR | 耳机颜色 |
| 0x13 | GET_EARBUD_LANGUAGE | 提示音语言 |
| 0x15 / 0x17 | GET_EARBUD_SN_LEFT/RIGHT | 左右序列号（分片回传，见 `BleEarbudSnChunk`） |

`0x10/0x12/0x14/0x16` 空缺（疑似保留/已删除命令，真机抓包时留意）。

## 4. 相关协议面（类级实锤，opcode 待抓包）

- `ble.source.eq.*`：PEQ 编解码（`BleEqProtocolCodec`，频点/增益/Q 值结构）。
- `ble.source.identity.*`：身份识别（`BleDeviceIdentityProtocolCodec`，SN/颜色/语言）。
- `ble.source.mic.*`：麦增益。
- **ANC 不走 9ECA 服务**：`BleSourceCommand` 无 ANC 条目；ANC 经 `handlers/AncHandler`、`AncV2Handler` + 高通 **Gaia v1v2/v3 + QTIL**（`com.qualcomm.qti.gaia.*`，含 ANCInfo/CodecInfo/EarbudInfo/Gesture/TouchV2-V4/SpatialAudio 等）或芯片原厂通道（`AirohaHandler` 络达 / `BluetrumFotaHandler` 中科蓝讯 / `JieliFotaHandler` 杰理，三家 OTA 并存，`libjl_ota_auth.so` 佐证杰理）。
- OTA：`FotaManager` + `FirmwareUpdateActivity`（杰理/蓝讯/Airoha 三通道 + Gaia QTIL Upgrade）。
- `libmoondrop_rust_test.so` 仅含 `moondrop_rust_abi_version / fibonacci` ——占位库，非协议核心。
- `43484152/5052494D-…` 系测试 UUID（ASCII "CHAR"/"PRIM"），非设备协议。

## 5. “Mirage”命名

- dex + libapp.so 全量 strings 无 `mirage`（大小写皆无）；本 2.25.0c 版 probable 未显式命名 Mirage，或靠 9ECA 服务/广播名识别。
- **待主人真机抓包确认**：BLE 广播名 + `btsnoop_hci.log`（见 README 抓包指南），重点抓：连接建立、读写 9ECA0001/0003、电量上报、ANC 三档切换、EQ/PEQ 读写。

## 6. 鸿蒙映射（本工程）

- `entry/src/main/ets/ble/MirageBle.ets`：9ECA GATT（双设备音频源切换专用）。
- `entry/src/main/ets/ble/GaiaSpp.ets`：**主控协议**——Gaia V3 over RFCOMM SPP（本节全部内容）。
- 传输统一走 `@kit.ConnectivityKit`（BLE GATT 用 `ble`，SPP 用 `socket.spp*`，见 GaiaSpp.ets 注释）。

---

# 附录 A：Gaia 主控链路（btsnoop 实锤，2026-10-31 真机抓包）

> 包：`mirage-bugreport.zip`（100MB）→ `FS/data/misc/bluetooth/logs/btsnoop_hci_20261031_153418.log`（6637 条，覆盖操作窗口约 3.7min）
> 解析工具：本仓库 `tools/parse_btsnoop.py / analyze_capture.py / l2cap_reassemble.py / rfcomm_parse.py / rfcomm_lenparse.py / gaia_split.py / gaia_decode.py`
> 抓包动作：连接 → 等电量 → 噪声控制 关闭→透传→降噪 → EQ 预设切换 + PEQ 改频点保存 → 音量加减。

## A.1 结论总览（先看这个）

1. **主控走经典蓝牙 SPP（RFCOMM），协议是高通 Gaia V3**（不是 BLE 9ECA——窗口内零 GATT/ATT 包；9ECA 仅用于音频源切换，见 §1-§2）。
2. 同链路另有标准 HFP（AT+BRSF/BAC/CIND/CMER，DLCI 8）和 AVRCP（AVCTP，音量），与自研协议无关。
3. 音频走 A2DP（另一条 ACL `0xEDC`，SBC），与控制无关。
4. **잡음注意**：该耳机固件 RFCOMM UIH 的 FCS 不符合标准（内容全对、校验全错；SABM/UA 标准）。实测 2/2 HFP 帧的 FCS = `CRC8(addr, ctrl)`（只覆盖 2 字节）。**我方发送必须用标准全头 FCS**（对端手机栈接受标准帧；耳机是否校验未知，Motorola 机型不校验）。`GaiaSpp.ets` 默认发标准 FCS，收包不校验（只按长度链 + SDU 边界切分）。

## A.2 信道地图（ACL handle `0x004`，另一条 `0xEDC` = A2DP 音频）

| 本端 CID | 对端 CID | 承载 | 说明 |
|---|---|---|---|
| 0x0001 | — | L2CAP 信令 | 连接/配置全程可见 |
| 0x40(rx)/0x140(tx) | SDP | 服务发现（含 SPP/HFP/AVRCP/A2DP UUID） |
| 0x41(rx)/0x140复用(tx) | RFCOMM | HFP（DLCI 8）+ **Gaia（DLCI 2）**；tx 前 27 字节是 SDP，之后 `03 3F 01` SABM 开 RFCOMM |
| 0x43/0x44 等 | AVDTP | 音频信令/传输 |
| 0x46/0x47 等 | AVCTP | AVRCP（绝对音量等标准协议） |

## A.3 Gaia transport 帧（`GaiaFormatter$Rfcomm.Frame` 反编译 + 空中包双向印证）

```
[FF][VER][FLAGS][LEN(1B)][V3PDU = LEN+4 字节]   // 无 checksum（194 帧链式覆盖 2468B 验证）
SOF: offset 0 = 0xFF（SOF.value = -1）
VER: offset 1（观察到 0x01=V1 版本协商，0x04=V3/V4 业务）
FLAGS: offset 2（全 0x00）
LEN: offset 3（1B；>255 时才用 2B lengthWithExtension，本次未出现）
```

## A.4 Gaia V3 PDU（`V3PacketFactory.buildPacket` 反编译原文 + 空中包印证）

```
vendor  = U16BE(b[0:2])     // 10 = QTIL v1v2，29 = QTIL V3（QTILVendorIDs 实锤）
cmdDesc = U16BE(b[2:4])     // = feature[9:15] | type[7:8] | command[0:6]
payload = b[4:]
command = cmdDesc & 0x7F; type = (cmdDesc >> 7) & 3; feature = cmdDesc >> 9
type: 0=CMD 1=NOTIF 2=RESP 3=ERR（V3PacketType 实锤：COMMAND/NOTIFICATION/RESPONSE/ERROR）
```

Feature ID 表（`QTILFeature.<clinit>` 实锤）：BASIC=0, EARBUD=1, ANC=2, VOICE_UI=3, DEBUG=4,
MUSIC_PROCESSING=5, UPGRADE=6, HANDSET_SERVICE=7, AUDIO_CURATION=8, EARBUD_FIT=9,
VOICE_PROCESSING=10, GESTURE_CONFIGURATION=11, STATISTICS=12, **BATTERY=13**,
VOICE=14, DAC_GAIN=15, CODEC_TYPE=16, LIGHT_SENSOR=17, SPATIAL_AUDIO=18, LED=19,
ONEBRINGTWO=20, BT_ADDRESS=21, TOUCHV2=22, AUDIO_RESOURCE=23, POWER_CONTROL=24,
POWER_TIMEOUT=25, TOUCHV3=26, DYBASS=27, AUDIO_FILE_STORAGE=29, LR_CHANNEL=30,
TOUCHV3=26, TOUCHV4=31, **ANC_V2=32**。

## A.5 ANC（feature 32 = ANC_V2，`V3AncV2Plugin$COMMANDS` 实锤）

- 命令：`GET_CURRENT_MODE=3` / `SET_CURRENT_MODE=4` / `GET_CURRENT_ANC_SWITCH_CONF=41` / `SET_ANC_SWITCH_CONF=42`；通知 `ANC_MODE_CHANGE=1` / `ANC_SWITCH_CONF_CHANGE=2`。
- 模式值（`AncV2Handler` 常量实锤）：`OFF=0 / ANC_ON=1 / TRANSPARENT=2 / ANTI_WIND=3 / ADAPTIVE=4 / LIVE=5`。
- **空中包（用户连点三下）**：`CMD 4 + [00]` → RESP `00`；`CMD 4 + [02]` → RESP `02`；`CMD 4 + [04]` → RESP `04`。
- 结论：三连击 = **OFF → TRANSPARENT → ADAPTIVE**。⚠️ 若主人点的第三下标签是“降噪”而非“自适应”，则该 App 把“降噪”映射到了 ADAPTIVE(4)——待主人确认 ANC 页选项文案（App 内有 `/adaptiveancV2` 路由与自适应降噪文案，见 libapp.so strings）。
- 开机查询：`CMD 3` → RESP 当前模式；`CMD 41` → RESP `01 01 01 01 00`（切换配置）。

## A.6 电量（feature 13 = BATTERY）

- 查询对：`CMD 0`（空载荷；RESP 回 `01 02`）+ `CMD 1` 载荷 `01 02`（查询 1/2 号电池）。
- 上报：`RESP/NOTIF cmd=1` 载荷 TLV：`01 64 02 64 03 64` = [id=1,val=0x64] [id=2,val=0x64] [id=3,val=0x64]，即 **左100/右100/仓100**（id 疑似 1=左 2=右 3=仓；待低电量包二次确认）。
- App 全程高频轮询（cmd0+cmd1 交替，约每秒一次）；耳机也会主动 NOTIF 上报。
- `BASIC cmd 5` → RESP ASCII 固件版本（本次 `"3.5.2"`）；`BASIC cmd 20/21` → RESP ASCII 左右 SN（本次 `20630023126082200162 / …1288`）；`BASIC cmd 7/12/13` → 能力集查询；`cmd 22` → ERR（不支持）。

## A.7 EQ（feature 5 = MUSIC_PROCESSING）

- `CMD 3` 载荷 `3f`（取预设，RESP 回 `3f`）；`CMD 6` = 下发 PEQ（RESP 原样 echo）。
- 抓到两种 blob：53B（全量，`00 06 …`，疑似 7 频段）与 25B（增量，`07 09 …`，疑似 3 频段），均为 `V3MusicProcessingPlugin.setUserSetGains` 系打包：
  `[startBand U8][endBand U8][每频段 7B：freq S16 + Q定点 S16 + ? + gain定点 S16]`（`BandInfo.formatQ/formatGain`，精确 offsets 待定——decompile 显示的 loop 下标疑似混淆，需专项抓包：逐个频段扫值 + 读回 `sendGetUserConfiguration` 比对）。
- ⚠️ 本轮未做“逐频段扫值”对照，EQ blob 字节语义标 TODO，待补抓。

## A.8 双设备（feature 20 = ONEBRINGTWO，与截图“两台手机”对应）

- `CMD 1/3` → RESP `00`；`CMD 5` → RESP 29B：`[MAC 12B?][ASCII 对端名]`，本次为 `…REDMI K90 Ultra`（与截图“Pul3的REDMI K90 Ultra”一致，主人另一台 Pura 80 应在另一条记录里）。
- TOUCHV2 `CMD 2` → RESP `11 23 66 77 00`（手势配置，回包待解）。

## A.9 待补抓清单（V2 轮）

1. ANC 页选项文案确认 + 逐项点一遍（重点：01=ANC_ON 何时出现）。
2. EQ 专项：固定其他频段、逐个频段扫 gain（-12/0/+12dB），每次读回；预设逐一切换。
3. 低电量包（电量 TLV id 语义二次确认）。
4. 音量：走标准 AVRCP（无需逆向）。
5. 9ECA GATT：本次零包——需进“双设备切换/音频源切换”页触发扫描连接才能抓到。
