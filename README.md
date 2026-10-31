# MirageHarmony（水月雨 MOONDROP MIRAGE · 鸿蒙版）

FreeBuds 7 风格设备页 + 从官方 APK 逆向落地的 **Gaia V3 over RFCOMM SPP** 控制协议。

- 协议证据链：[PROTOCOL.md](./PROTOCOL.md)（jadx 反编译 + btsnoop 真机抓包双向印证）
- 解析工具链：[tools/](./tools)（btsnoop → L2CAP 重组 → RFCOMM → Gaia 解码，可复现全部结论）

## 功能（均已实测链路）

| 能力 | 实现 |
| --- | --- |
| 扫描耳机 | 经典蓝牙发现 `connection.discoveryResult`，`MOONDROP MIRAGE` 自动置顶；耳机已连接时不在发现结果里，另有 `getPairedDevices()` 的「已配对设备」入口 |
| 自动接管 | 进页面/回前台时若耳机已与手机连接，自动建 Gaia 会话直接进控制台（无需手动点连接）；手动「断开连接」后不再自动重连 |
| 配对 + 建链 | `connection.pairDevice` + `socket.sppConnect(uuid=1101, SPP_RFCOMM)` + V1 握手 |
| 电量（左/右/仓） | `BATTERY(13)` cmd0/cmd1 轮询 + TLV 解析，3 秒刷新 |
| 降噪四档 | `ANC_V2(32)` cmd4：关闭 `00` / 透传 `02` / 降噪 `04`(自适应降噪) / 风噪 `03`(抗风噪) |
| 固件版本 | `BASIC(0)` cmd5 → ASCII（实测 `3.5.2`） |
| 左右 SN | `BASIC(0)` cmd20/cmd21 → ASCII |
| 双设备对端 | `ONEBRINGTWO(20)` cmd5 → 对端名 |
| UI | 图 2 复刻：深紫渐变 + 电量胶囊 + 设备卡 + 噪声控制四档 + 底部三 Tab |

## 真机验收（2026-10-31，HUAWEI Pura 80 Ultra / HarmonyOS）

`entry-default-signed.hap` 经 `hdc install` 安装成功，`aa start` 启动，实测通过：

| 项 | 实测结果 |
| --- | --- |
| 签名 | `verify-app` → `verify codesign success`（Huawei CBG 证书链，profile type=debug） |
| 安装 | `install bundle successfully` |
| 建链 | SPP 连上 `MOONDROP MIRAGE`（`8A:99:9A:EC:02:4F`），状态「已连接」 |
| 电量 | 原始 `01 54 02 56 03 ff` → 左 **84%** / 右 **85%** / 仓 `--`（`0xFF`=仓未接入，正确显示占位） |
| 降噪四档 | 关闭/透传/降噪/风噪 四个按钮均写入生效并回读确认（状态栏显示「已连接 · 透传 / · 抗风噪 / · 降噪」） |
| 双设备 | 读回对端 **Pura 80 Ultra**（耳机上报的另一台设备） |
| 固件/SN | 走 `BASIC(0)` cmd5 / cmd20 / cmd21（ASCII），「我的」页展示 |

踩坑记录（都已修）：

1. `ohos.permission.GET_BLUETOOTH_PEERS_MAC` 受 ACL 管控，普通应用安装直接失败（`9568289 grant request permissions failed`）——本 App 用不到真实 MAC，已移除。
2. 电量 `0xFF` 是「该路未上报」哨兵值，不能当 255 显示。
3. `@Builder` 的**值参数不订阅状态**，电量变化不重绘——已改为内联节点。
4. 耳机已连接时不会出现在扫描结果里，必须走 `connection.getPairedDevices()`，App 已加「已配对设备」区块。

## 构建（命令行，已实测通过）

```powershell
# SDK 用 DevEco 自带的那套（结构完整，含 sdk-pkg.json 元数据）
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'

# 装依赖（无第三方依赖，仅初始化）
& 'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\ohpm.bat' install

# 编译（产物：entry/build/default/outputs/default/entry-default-unsigned.hap）
node 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' assembleHap -p product=default -p buildMode=debug
```

实测结果：`COMPILE RESULT` 0 error，`BUILD SUCCESSFUL`，产物 `entry-default-unsigned.hap` ≈ 203 KB。

> 注意：**不要**用 `C:\Users\tiany\AppData\Local\OpenHarmony\Sdk` 当 `DEVECO_SDK_HOME`——那是版本化布局（`Sdk/26.0.0/toolchains`），
> 而 hvigor 的 HarmonyOS SDK 加载器要求扁平布局且需要 `sdk-pkg.json` 元数据（该目录没有），会报 `00303168 SDK component missing`。
> `local.properties` 里已把 `hwsdk.dir` / `sdk.dir` 指向 DevEco 自带 SDK。

## 在 DevEco 里运行

1. DevEco Studio → Open → 选本目录。
2. 首次运行会要求签名：Project Structure → Signing Configs → 勾选 **Automatically generate signature**（登录华为开发者账号后一键生成）。
   这是 HarmonyOS 的平台硬门槛：调试签名里的 profile 由 AGC 签发并绑定 **bundleName + 设备 UDID**，
   无法离线伪造（本机 `~/.ohos/config` 里现有的两套是别的 bundleName 的 profile，不能复用）。
3. 连手机 Run 即可安装。

签名身份（已固定，供生成 profile 时核对）：

- bundleName：`com.moondrop.mirage`
- 设备类型：phone / tablet
- 权限：`ohos.permission.ACCESS_BLUETOOTH`、`GET_BLUETOOTH_PEERS_MAC`、`APPROXIMATELY_LOCATION`（均为 user_grant，首次连接时弹窗）

## 协议要点（详见 PROTOCOL.md）

```
transport: FF | VER(01=V1协商, 04=V3业务) | FLAGS(00) | LEN(1B) | V3PDU(=LEN+4)   无 checksum
V3PDU:     vendor(U16BE) | command(U16BE) | payload
command:   feature[9:15] | type[7:8](0=CMD 1=NOTIF 2=RESP 3=ERR) | cmd[0:6]
vendor:    29 = QTIL-V3（本机全部业务帧）
```

## 真机抓包（如需再补协议）

1. 手机开发者选项打开「蓝牙数据包日志 / HCI 收集」。
2. 复现动作（每步隔 3 秒）。
3. `adb bugreport mirage.zip`，解压出 `FS/data/misc/bluetooth/logs/btsnoop_hci_*.log`。
4. 解析：

```powershell
python tools/l2cap_reassemble.py <btsnoop.log> --dump out      # 按 handle+cid 重组 SDU
python tools/gaia_split.py out/h004_cid0041_rx.bin --dump out2 # RFCOMM UIH 按 DLCI 分流
python tools/gaia_decode.py out2/h004_cid0041_rx_dlci2.bin --dir rx   # Gaia V3 逐帧解码
```
