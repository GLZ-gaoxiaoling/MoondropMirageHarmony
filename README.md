# MirageHarmony（水月雨 Mirage 耳机 · 鸿蒙版）

FreeBuds 7 风格设备页 + 逆向落地的 9ECA BLE 协议。协议证据链见 [PROTOCOL.md](./PROTOCOL.md)。

## 环境

- DevEco Studio（`C:\Program Files\Huawei\DevEco Studio`）+ API 26 SDK（`%LOCALAPPDATA%\OpenHarmony\Sdk\26.0.0`）
- 构建：用 DevEco 直接打开本目录，或 `tools/hvigor` + `tools/ohpm`（DevEco 自带）命令行构建
- 真机调试：`toolchains/hdc.exe`（SDK 自带）

## 构建（DevEco 内）

1. 打开本目录 → 等待 Sync 完成（会自动拉 `oh-package` 依赖）。
2. `compatibleSdkVersion` 模板默认 `5.0.0(12)`；目标鸿蒙 7 请在 Project Structure 里切到已安装的 API 26 SDK。
3. 签名：Run 前先配自动签名（File → Project Structure → Signing Configs）。
4. 权限：`ACCESS_BLUETOOTH / GET_BLUETOOTH_PEERS_MAC / LOCATION` 已在 `entry/.../module.json5` 声明，首次连接时系统弹窗授权。

## 真机抓包指南（回填协议用，主人操作）

逆向缺的最后一块拼图是**真实空中包**，用来确认：响应帧 status 字节、电量上报通道、ANC 三档 opcode、EQ/PEQ 回包字段。

Android 手机操作：

1. 开发者选项 → 打开 **“启用蓝牙 HCI 信息收集日志”（btsnoop）**。
2. 复现以下动作（每个动作间隔 3 秒，默念记下时间点）：
   - 打开 MOONDROP App → 连接 Mirage（记录连接时刻）
   - 首页电量刷新（下拉/等待电量数字出现）
   - 噪声控制：关闭 → 透传 → 降噪，各停 3 秒
   - EQ 预设切换 + 自定义 PEQ 改一个频点并保存
   - 音量加减各一次；改一次提示音语言/查一次序列号（如 App 支持）
   - 关机/断开一次（如有该按钮）
3. 开发者选项 → **“获取 bug 报告”**（或 `adb bugreport`），解压出 `btsnoop_hci.log` 发给小雪。
4. 同时记下：Mirage 的**蓝牙广播名** + App 显示的**固件版本号**。

小雪收到后：用 `rea` 对照解帧，回填 `MirageBle.ets` 的响应解码 + ANC 通道 + 电量通道，然后 DevicePage 接真实数据。

## 当前状态

- ✅ 工程骨架（DevEco 模板）+ 包名 `com.moondrop.mirage`
- ✅ `ble/MirageBle.ets`：UUID/帧编解码/命令字/扫描连接/命令配对（均为逆向实锤）
- ✅ `pages/DevicePage.ets`：图 2 复刻页（静态 + 连接流程已接）
- ⏳ 电量/ANC/EQ 真实数据：待 btsnoop 回填
- ⏳ OTA（杰理/蓝讯/Airoha/Gaia 四通道）：第二阶段
