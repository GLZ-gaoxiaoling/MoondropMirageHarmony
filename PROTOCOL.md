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

- `entry/src/main/ets/ble/MirageBle.ets`：UUID/帧编解码/命令字已按上表落地；ANC/EQ-opcode 标 TODO，待抓包回填。
- 传输统一走 `@kit.ConnectivityKit` 的 `ble.createGattClientDevice`。
