# MirageHarmony

**MOONDROP MIRAGE（水月雨 Mirage）的非官方鸿蒙客户端** —— 从官方 Android APK 逆向出
**Gaia V3 over RFCOMM SPP** 控制协议，在 HarmonyOS 上实现电量、四档降噪、设备信息与双设备查看。

> ⚠️ 第三方非官方项目，与 MOONDROP 无关。详见 [DISCLAIMER.md](./DISCLAIMER.md)。
> 仅用于**互操作性研究**与**控制自己拥有的耳机**。

- 协议证据链：[`PROTOCOL.md`](./PROTOCOL.md)（jadx 反编译原文 + 真机 btsnoop 抓包，双向印证）
- 抓包解析工具链：[`tools/`](./tools)（btsnoop → L2CAP 重组 → RFCOMM 分流 → Gaia 解码，可复现全部结论）
- 许可：[MIT](./LICENSE)

## 已实测验证（HUAWEI Pura 80 Ultra / HarmonyOS）

| 能力 | 实现 |
| --- | --- |
| 自动接管 | 进页面/回前台时若耳机已与手机连接，自动建 Gaia 会话直接进控制台，无需手动点连接；手动「断开连接」后不再自动重连 |
| 扫描耳机 | 经典蓝牙发现 `connection.discoveryResult`，`MOONDROP MIRAGE` 自动置顶；耳机已连接时不在发现结果里，另有 `getPairedDevices()` 的「已配对设备」入口 |
| 配对 + 建链 | `connection.pairDevice` + `socket.sppConnect(uuid=1101, SPP_RFCOMM)` + V1 握手 |
| 电量（左/右/仓） | `BATTERY(13)` cmd0/cmd1 轮询 + TLV 解析（`0xFF` = 该路未上报），3 秒刷新 |
| 降噪四档 | `ANC_V2(32)` cmd4：关闭 `00` / 透传 `02` / 降噪 `04`（自适应降噪）/ 风噪 `03`（抗风噪） |
| 固件版本 | `BASIC(0)` cmd5 → ASCII（实测 `3.5.2`） |
| 左右 SN | `BASIC(0)` cmd20 / cmd21 → ASCII |
| 双设备对端 | `ONEBRINGTWO(20)` cmd5 → 对端设备名 |
| UI | 深紫渐变 + L/R/仓 电量胶囊 + 设备卡 + 噪声控制四档 + 底部三 Tab |

真机实测数据：电量原始帧 `01 54 02 55 03 ff` → 84% / 84% / `--`（仓未接入）；
四档切换均写入生效并回读确认；双设备读回 `Pura 80 Ultra`；固件 `3.5.2`。

## 协议速览

```
transport: FF | VER(01=V1协商, 04=V3业务) | FLAGS(00) | LEN(1B) | V3PDU(=LEN+4)   无 checksum
V3PDU:     vendor(U16BE) | command(U16BE) | payload
command:   feature[9:15] | type[7:8](0=CMD 1=NOTIF 2=RESP 3=ERR) | cmd[0:6]
vendor:    29 = QTIL-V3
```

完整命令表（ANC / 电量 / 固件 / 双设备 / 9ECA GATT）、抓包方法与反编译出处见 [`PROTOCOL.md`](./PROTOCOL.md)。

## 目录结构

```
entry/src/main/ets/
├── ble/GaiaSpp.ets      # 协议核心：transport 组帧/解帧、V3 编解码、会话与命令配对
└── pages/DevicePage.ets # 设备页（自动接管 → 电量轮询 → 四档降噪 → 设备信息）
tools/                   # 抓包解析链（Python，无第三方依赖）
PROTOCOL.md              # 协议证据链（含 jadx 反编译原文摘录与帧序）
```

## 构建

环境：DevEco Studio（API 26 SDK）+ `ohpm` + `hvigor`。

```powershell
# SDK 用 DevEco 自带那套（结构完整，含 sdk-pkg.json 元数据）
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'

& 'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\ohpm.bat' install

node 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' assembleHap -p product=default -p buildMode=debug
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

### 签名（务必看）

仓库**不包含任何签名配置**（`signingConfigs` 为空），这是刻意的：调试签名 profile 由 AGC 签发并
绑定 **bundleName + 设备 UDID**，属于个人凭据，不该入库。

首次构建请在 DevEco Studio 里：

1. Project Structure → Signing Configs → 勾选 **Automatically generate signature**（需登录华为开发者账号）；
2. 之后 `hvigorw assembleHap` 即可产出已签名 HAP。

安装到设备：

```powershell
hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.moondrop.mirage
```

> 注意：`DEVECO_SDK_HOME` **不要**指向 `AppData\Local\OpenHarmony\Sdk`——那是版本化布局且没有
> `sdk-pkg.json` 元数据，hvigor 会报 `00303168 SDK component missing`。

## 自己再补抓协议

1. 手机开发者选项打开「蓝牙数据包日志 / HCI 收集」；
2. 复现动作（每步间隔 3 秒）；
3. `adb bugreport mirage.zip`，解压出 `FS/data/misc/bluetooth/logs/btsnoop_hci_*.log`；
4. 解析：

```powershell
python tools/l2cap_reassemble.py <btsnoop.log> --dump out      # 按 handle+cid 重组 SDU
python tools/gaia_split.py out/h004_cid0041_rx.bin --dump out2 # RFCOMM UIH 按 DLCI 分流
python tools/gaia_decode.py out2/h004_cid0041_rx_dlci2.bin --dir rx   # Gaia V3 逐帧解码
```

## 范围

本版覆盖：扫描 / 配对 / 建链 / 电量 / 四档降噪 / 固件 / SN / 双设备。

**不在范围**：EQ/PEQ、OTA 固件升级、手势配置、提示音语言、9ECA GATT 音频源切换、音量（系统 AVRCP）。
详见 `PROTOCOL.md` 附录 A.9。

## 许可与免责

- 代码：[MIT](./LICENSE)
- **使用前请阅读 [DISCLAIMER.md](./DISCLAIMER.md)**：非官方项目、逆向协议出于互操作目的、
  写入设备状态存在风险、商标与固件权利归原厂。
