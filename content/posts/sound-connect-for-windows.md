+++
title = '给 Sony WH-1000XM6 写一个 Windows 控制端：从 APK 逆向到 WinUI 3'
date = '2026-11-25T11:00:00+08:00'
draft = false
author = 'Thomas'
categories = ['技术']
tags = ['蓝牙', 'BLE', '逆向', 'Sony', 'WH-1000XM6', 'WinUI 3', '.NET', 'Tandem']
description = '在没有 root、没有 HCI 抓包的情况下，从官方 APK 反推 WH-1000XM6 的 Tandem V2 控制协议，在 Windows 上完成 GATT 握手，并逐项实现降噪、EQ、聆听模式、DSEE、多点连接，最后做成 WinUI 3 托盘应用。'
keywords = ['WH-1000XM6', 'Tandem', 'BLE', 'GATT', 'WinUI 3', '蓝牙逆向', 'Sony', 'Sound Connect']
toc = true
autoCollapseToc = true
comment = true
+++

> Sony 的耳机控制 App 只有 Android 和 iOS。本文记录如何在没有 root、抓不到 HCI 日志的情况下，从官方 APK 反推出 WH-1000XM6 的 Tandem V2 控制协议，在 Windows 上完成 GATT 握手，并逐项验证降噪、EQ、聆听模式、DSEE、多点连接，最后做成一个本地优先的 WinUI 3 托盘应用。

## 背景与边界

目标设备是 Sony WH-1000XM6，固件 3.1.5，Windows 11 x64，蓝牙适配器支持 BLE。

想要的东西很明确：

- 在 Windows 上直接控制耳机，不经过手机，也不经过云服务。
- 托盘常驻，常用功能一两次点击就能到。
- 中文优先，同时保留英文。
- 本地实现，不上传设备数据，不加遥测。

同时也划了明确的边界：

- 不做固件刷写、恢复出厂或任何破坏性写入。
- 不做 LE Audio、Auracast、360 Reality Audio。
- 不实现账号、云同步、广告、分析。
- 不复制 Sony 的反编译代码、资源、图标或固件；只提取协议事实，然后独立实现。

这是一份个人用途的互操作性实现，不是 Sony 官方产品。

## 第一关：抓不到 HCI 日志

做蓝牙协议逆向，最理想的证据是 Android 的 HCI snoop log：手机和耳机之间的每一帧、每一个 GATT 操作都在里面，方向、UUID、时间戳一应俱全。

理想很丰满，现实是手机没有 root：

```text
/data/misc/bluetooth/logs/btsnoop_hci.log
```

直接访问被拒绝，bugreport 里也没有可用的 HCI 日志。抓包这条路暂时走不通。

于是转到第二条路：**反编译官方 Android App**。用 JADX 1.5.6 打开 `classes2.dex`、`classes3.dex`、`classes4.dex`，从代码结构里还原协议。

这条路的原则是：

- 反编译只用来理解结构，不照抄代码。
- 所有写操作最终以实机读回为准。
- 未知消息保持未知，不猜状态变更命令。

## 第二关：找对控制服务

Windows 第一次枚举 GATT，得到 **14 个服务、45 个特征值**。设备信息服务能正常读出：

```text
Manufacturer: Sony
Model:        WH-1000XM6
Firmware:     3.1.5
PnP ID:       02 4c 05 8a 0f 15 03
```

PnP ID 解码后是 Sony 的 vendor `0x054C`、product `0x0F8A`，身份没问题。但真正的控制服务在哪？

### 诱饵：dc405470 不是控制服务

广播里有一个很显眼的服务：

```text
dc405470-a351-4a59-97d8-2e2e3b207fbb
```

它同时有 write 和 notify 特征值，看起来很像控制通道。但 `ServiceUuid.java` 里写得很清楚：**这是 Airoha FOTA，固件升级服务**，不是日常控制。

真正的控制服务是：

```text
5b833e20-6bc7-4802-8e9a-723ceca4bd8f   Tandem V2 HPC
```

它的特征值分工如下：

| 特征值 | 方向 | 用途 |
|--------|------|------|
| `5b833c60-...` | write | `TANDEM_HPC_TO_ACC`，主机发给耳机 |
| `5b833c61-...` | notify | `TANDEM_HPC_FROM_ACC`，耳机发给主机 |
| `5b833c91-...` | read | `WRITABLE_VALUE_LENGTH` |
| `5b833c92-...` | — | `BEACON_INFO` |
| `5b833c93-...` | notify | `DETERMINE_MTU` |

如果 `5b833e20` 不存在，官方 App 会直接判定 Tandem 会话失败。我们的第一次枚举，恰恰就没有这个服务。

## 第三关：服务消失，驱动背锅

更奇怪的是：设备信息服务能读，说明 BLE 链路是通的；但 Tandem 服务就是不在 Windows 的服务列表里。

试过的手段包括：

- 重新配对。
- 向 `5b833e26` 的 `5b833c11` 写 `[0x01]`（官方 App 的 inquiry scan 触发）。
- BLE unpair / re-pair。

结果：

```text
write: Success
status notification: 01
complete-name notification: timeout
Tandem service after refresh: still missing
```

重新配对更糟：

```text
unpair: Unpaired
pair:   Failed
```

BLE bond 被移除，配对失败，Classic 音频还能用，但控制通道彻底没了。

### 转折：禁用第三方 A2DP 驱动

真正的突破来自一个和协议无关的地方：本机安装了 **Alternative A2DP Driver**。把它禁用后，Windows 重新枚举 GATT，`5b833e20` 出现了，Tandem 握手一次成功。

这说明：**BLE 服务是否可见，不只由耳机决定，Windows 的蓝牙栈和第三方驱动也会影响。** 当"服务不存在"时，先排除主机侧，再怀疑设备。

不过，对 Classic RFCOMM 路径，禁用这个驱动并不是原因。后面会看到，table1 服务仍然不暴露，table2 仍然不响应。驱动只是 BLE 服务可见性的变量，不是全部答案。

### 另一个隐藏条件：GattSession

即使服务出现了，第一次连接也经常返回 `Unreachable` 或者枚举出 0 个服务。问题不在地址，而在 Windows 还没有建立 GATT 会话。

可靠的做法是显式创建并保持会话：

```csharp
var session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
session.MaintainConnection = true;
// 等待 GattSessionStatus.Active
```

设置 `MaintainConnection = true` 并等到会话进入 `Active` 后，服务枚举才稳定。后面的所有读写都复用这个会话。

## 第四关：帧格式

Tandem 的帧格式来自 `qm0.b`、`cp0.b`、`cp0.f`、`qm0.e` 这几个类。最终确认的结构是：

```text
0x3E  [escaped body]  0x3C
body = type(1) seq(1) length(4, big-endian) payload(N) checksum(1)
```

- 起始字节：`0x3E`
- 结束字节：`0x3C`
- 转义字节：`0x3D`
  - `0x3C -> 0x3D 0x2C`
  - `0x3D -> 0x3D 0x2D`
  - `0x3E -> 0x3D 0x2E`
- 校验和：`type + seq + length + payload` 的低字节
- `DATA_MDR = 0x0C`
- `ACK = 0x01`
- ACK 帧：`3E 01 seq 00 00 00 00 checksum 3C`

这里踩了四个坑，每一个都足以让握手"看起来连上了，但没有任何反应"：

1. **字段顺序**：最初写成 `seq(1) type(1) length(4)`，实际是 `type` 在前、`seq` 在后。
2. **ACK 序号**：主机的 ACK 序号是 `1 - receivedSequence`，不是把收到的序号原样回传。
3. **发送序号**：主机的发送序号跟随最后一个收到的 ACK，在 0/1 之间交替，不是单调递增计数器。
4. **写模式**：Tandem 写入使用 GATT **Write Without Response**，不是 Write With Response。

修正这四点之后，握手才稳定下来。

## 第五关：握手

握手阶段主要发四条消息：

| 命令 | 字节 | payload |
|------|------|---------|
| `CONNECT_GET_PROTOCOL_INFO` | `0x00` | `[0x00, 0x00]` |
| `CONNECT_GET_CAPABILITY_INFO` | `0x02` | `[0x02, 0x00]` |
| `CONNECT_GET_SUPPORT_FUNCTION` | `0x06` | `[0x06, 0x00]` |
| `CONNECT_GET_DEVICE_INFO` | `0x04` | `[0x04, type]`，type 1=型号，2=固件 |

实机结果：

```text
status: ok
tandemServicePresent: true
model: WH-1000XM6
firmware: 3.1.5
supportFunctions: 45
protocolVersion: 50343986 (0x03003032)
```

`CONNECT_RET_PROTOCOL_INFO` 的布局是：

```text
[0x01, 0x00, version(4), flag1, flag2]
```

`0x03003032` 的确切语义还没有完全对上，先把它当作能力协商的一部分记录下来，不参与功能判断。

**握手成功之前，不要发任何控制写入。** 这是整个项目最重要的一条纪律。

## 第六关：功能逐个点亮

握手只是拿到"入场券"。真正的工作，是把每个功能的消息格式、参数范围、读写语义搞清楚，并且**每次写入都读回验证**。

### 6.1 NC/ASM：能力 type 21，状态 type 25

XM6 的降噪能力查询用 inquired type **21**：

```text
NCASM capability type 21:
  Normal 1..20 step 1
  Voice  1..20 step 1
```

但当前状态和写入用的是 type **25**：

```text
MODE_NC_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS_NA
```

状态通知 `0x69` / 返回 `0x67` 的布局：

```text
69 19 changeStatus onOff mode ambient level noiseAdaptive sensitivity
```

一个真实例子：

```text
69 19 01 01 00 01 14 01 00
```

解码：

```text
onOff = On
mode = NC
ambient = Voice
level = 20
noiseAdaptive = On
sensitivity = Standard
```

写入用 `0x68`：

```text
68 19 01 <onOff> <mode> <ambient> <level> <noiseAdaptive> <sensitivity>
```

参数含义：

| 字段 | 值 |
|------|-----|
| onOff | 0=Off, 1=On |
| mode | NC=0, ASM=1 |
| ambient | Normal=0, Voice/Focus on voice=1 |
| noiseAdaptive | 0=Off, 1=On |
| sensitivity | Standard=0, High=1, Low=2 |

这里有一个很反直觉的行为：**从 ASM 切到 NC 时，耳机忽略 `ambient/level/noiseAdaptive`，保留上一次 ASM 的值。**

也就是说，如果先设了"环境声 15 级、高灵敏度、关注语音"，再切到降噪，底层 ASM 参数仍然是 15 级那一套。想恢复一个精确的 "NC + 底层 ASM 参数" 状态，必须先写 ASM 参数，再切 NC。

实测验证过的组合：

```text
off mode:  onOff=0                                   -> 读回一致
nc on:     onOff=1, mode=NC                          -> 读回一致
asm:       level 15, noiseAdaptive=On,
           sensitivity=High, voice focus             -> 读回一致
asm:       level 10, noiseAdaptive=Off,
           sensitivity=Low, voice focus off          -> 读回一致
```

### 6.2 EQ：10 段，预设和自定义是两条路

EQ 相关命令：

```text
EQEBB_GET_CAPABILITY 0x50
EQEBB_GET_STATUS     0x52
EQEBB_GET_PARAM      0x56
EQEBB_SET_PARAM      0x58
```

一个已验证的写入例子：

```text
58 04 a1 0a 06 02 06 06 0a 08 08 09 07 0b
```

拆开看：

```text
0x58  SET_PARAM
0x04  PresetEqAndErrorCode
0xa1  UserSetting1
0x0a  10 段
0x06 0x02 0x06 0x06 0x0a 0x08 0x08 0x09 0x07 0x0b  10 个 band
```

这里有一个关键区别：

- **内置预设**（Heavy、Clear、Hard、Soft 等）：发送 `bandCount = 0`，不带 band 数据，让耳机应用它自己存的曲线。
- **Custom**：发送 10 个 slider 值。

如果对内置预设发送旧的 slider 值，结果会不对。XM6 上读回的内置曲线是：

| 预设 | 10 段曲线 |
|------|-----------|
| Off | 6,6,6,6,6,6,6,6,6,6 |
| Heavy | 10,10,5,5,6,6,6,6,6,6 |
| Clear | 6,6,6,6,6,6,6,8,8,9 |
| Hard | 10,10,5,5,6,6,6,8,8,9 |
| Soft | 3,4,5,7,7,7,6,6,4,3 |
| GamingEq | 0,4,8,9,7,5,7,9,6,4 |
| UserSetting1 | 7,2,6,6,10,8,8,9,7,11 |
| UserSetting2 | 5,2,6,6,10,8,8,9,7,11 |

另一个坑是：`0x58` 写入后**不会返回一个直接的响应**。不能像请求/响应那样等它回包，否则只会超时。正确做法是写完再用 `0x56` 读一次，比较 preset 和 band 是否一致。

实测改一个 band 再恢复，两次读回都匹配：

```text
before:    UserSetting1 bands = 7,2,6,6,10,8,8,9,7,11
requested: UserSetting1 bands = 6,2,6,6,10,8,8,9,7,11
after:     UserSetting1 bands = 6,2,6,6,10,8,8,9,7,11
verified:  true
```

### 6.3 聆听模式：不是一个命令，是两个音频效果

官方 App 里的"聆听模式"看起来像单选：标准、背景音乐、电影。但协议里没有一条"set listening mode"命令，它是两个音频效果组合出来的：

```text
BGM_MODE                 3
UPMIX_CINEMA             4
BGM_MODE_AND_ERRORCODE   9
UPMIX_SERIES            10
```

背景音乐：

```text
E8 <type 9 or 3> <onOff> <roomSize>
onOff:    0 = ON, 1 = OFF
roomSize: 0 = Small / My Room
          1 = Middle / Living Room
          2 = Large / Cafe
```

注意 `onOff` 是反的：**0 才是开启**。这个和大多数布尔命令的直觉相反，第一次实现时很容易写反。

电影：

```text
UPMIX_CINEMA: E8 04 <onOff>
UPMIX_SERIES: E8 0A <itemId>   (Cinema = 1, None = 0)
```

App 优先走 `UPMIX_CINEMA`，固件不支持时回退到 `UPMIX_SERIES`。

标准模式的实现是：**把 BGM 和 Cinema 都关掉，不写 EQ**。所以当前 EQ 预设仍然生效。这一点在 UI 里要说明，否则用户会以为"标准模式"把 EQ 也重置了。

状态读回：

```text
BGM:          E7 09 <onOff> <roomSize>
UPMIX_CINEMA: E7 04 <onOff>
UPMIX_SERIES: E7 0A <itemId>
```

房间映射来自 APK 里的 `RoomSize`：`SMALL -> BGM_Setting_R1`、`MIDDLE -> R2`、`LARGE -> R3`，UI 标注为 My Room / Living Room / Cafe。协议文档里对房间映射的实机验证仍标注为待补，这一点保持诚实，不把"代码里写了"当成"设备上验证了"。

### 6.4 DSEE：只能设 Auto/Off，效果要单独读

DSEE 是另一个"设置"和"效果"分离的功能。

通用状态命令：

```text
COMMON_GET_STATUS 0x12 / RET_STATUS 0x13 / NTFY_STATUS 0x15
```

查询类型：

```text
AUDIO_CODEC       2
UPSCALING_EFFECT  3
```

读当前编解码器：

```text
12 02  -> 13 02 <codec>
```

codec 值：

| 值 | 编码 |
|----|------|
| 0 | unsettled |
| 1 | SBC |
| 2 | AAC |
| 3 | LDAC |
| 32 | aptX |
| 33 | aptX HD |
| 48 | LC3 |
| 255 | other |

读 DSEE 效果：

```text
12 03  -> 13 03 <type> <status>
```

DSEE 类型：

```text
0 = DSEE HX
1 = DSEE
2 = DSEE HX AI (DSEE Extreme)
3 = DSEE Ultimate
```

状态：

```text
0 = off
1 = valid (active)
2 = invalid (enabled but not applied)
```

设置本身走音频参数：

```text
AUDIO_GET_CAPABILITY 0xE0 01  -> E1 01 <UpscalingType>
AUDIO_GET_STATUS     0xE2 01  -> E3 01 <EnableDisable>
AUDIO_GET_PARAM      0xE6 01  -> E7 01 <value>
AUDIO_SET_PARAM      0xE8 01 <value>
```

`EnableDisable` 是 `0 = enable`、`1 = disable`；设置值是 `0 = off`、`1 = auto`。**协议没有硬 "on"**，只能设 Auto 或 Off。

所以 UI 要区分两件事：

- 设置是不是 Auto。
- 当前效果是不是真的生效。

实机验证（AAC 链路，DSEE 运行中）：

```text
12 02        -> 13 02 02          codec = AAC
12 03        -> 13 03 02 01       DSEE = DSEE_HX_AI, VALID
E0 01        -> E1 01 02          capability = DSEE_HX_AI
E6 01        -> E7 01 01          setting = Auto
E2 01        -> E3 01 00          enabled = Enable
E8 01 00     -> E7 01 00          Off 写入并读回
E8 01 01     -> E7 01 01          Auto 写入并读回，效果重新 VALID
```

App 里用"运行中"表示 `status = valid`，用"已开启，当前未生效"表示设置为 Auto 但 `status = invalid`。不把"Auto"直接显示成"开"，是对协议最基本的尊重。

### 6.5 多点连接与自动关机

多点连接不是独立命令，而是通用设置里的一个 Boolean：

```text
GS_GET_CAPABILITY 0xD0 / RET_CAPABILITY 0xD1
GS_GET_STATUS     0xD2 / RET_STATUS     0xD3
GS_GET_PARAM      0xD6 / RET_PARAM      0xD7
GS_SET_PARAM      0xD8 / NTFY_PARAM     0xD9
```

XM6 上的映射：

```text
D1 = SIDETONE_SETTING       BooleanType
D2 = MULTIPOINT_SETTING     BooleanType
D3 = TOUCH_PANEL_SETTING    BooleanType
D4 = 不作为 capability 上报
```

状态读回：

```text
D7 D2 00 00   -> multipoint On
```

写入：

```text
D8 D2 00 00   (On)  -> 读回 On，验证通过
D8 D2 00 01   (Off) -> 返回 D9 D2 00 00，读回仍然 On
```

在 LDAC 可用 / 两台设备已连接的状态下，关闭多点连接会被拒绝。App 的处理是：**把写入结果和读回结果分开报告，不把"写了"当成"成功了"**。

自动关机走佩戴检测：

```text
POWER_GET_CAPABILITY 0x20, WEARING 0x05 -> 0x21
POWER_GET_PARAM      0x26, WEARING 0x05 -> 0x27
POWER_SET_PARAM      0x28, WEARING 0x05, first, second
```

XM6 的 UI 只暴露两个状态：

```text
type 5 capability: 21 05 02 10 11
                   WhenRemovedFromEars (0x10), Disable (0x11)

state:             27 05 <first> <second>
```

读回例子：

```text
27 05 10 00 = 取下耳机后
27 05 11 00 = 关闭
```

两个写入都验证过：

```text
first = 0x10 (removed) -> 读回一致
first = 0x11 (Disable) -> 读回一致
```

第二个字节是协议里的占位/上次时间，UI 不暴露，只显示第一个字节对应的两个状态。APK 里还有基于时间的 `AUTO_POWER_OFF 0x04`，但 XM6 的界面没有这个选项，所以不写。

## 第七关：Classic RFCOMM 此路不通

APK 里其实有两套 Tandem 传输：BLE 和 Classic SPP。

Classic 的 UUID：

```text
table1: 96CC203E-5068-46AD-B32D-E316F5E069BA
table2: 956C7B26-D49A-4BA8-B03F-B17D393CB6E2
```

Windows 上的结果：

```text
table1 96CC203E...: 不暴露
table2 956C7B26...: 能连接，但 support-function 请求后连接关闭，无响应
```

而且 table2 本身不包含 NCASM 和 EQ/EBB 命令，即使握手成功也覆盖不了核心功能。table1 才是完整的 v2/table1 命令集，但它在当前 Windows SDP 视图里根本不出现。

禁用 Alternative A2DP Driver 后重测，结论不变：

```text
table1: 仍然不暴露
table2: 仍然连接，仍然没有握手响应
```

所以 Classic 路径暂时封存，LE Tandem 是唯一可行方向。这个"死路"也值得记录，避免以后重复投入。

## 第八关：把协议变成应用

协议跑通之后，才是应用层的工作。最终做的是一个 **WinUI 3** 桌面应用，.NET 10，Windows App SDK 1.8，自包含、x64，提供免安装便携版和安装版。

### 页面结构

- **概览**：型号、固件、电量、连接状态、当前编解码器、DSEE 效果。
- **环境声音控制**：降噪 / 环境声 / 关闭，环境声等级，自动环境声与灵敏度，关注语音。
- **均衡器**：预设、10 段滑块，应用后读回。
- **聆听模式**：标准、背景音乐（我的房间 / 客厅 / 咖啡馆）、电影，外加独立的 DSEE 开关。
- **多点连接**：开关，应用后读回。
- **自动关机**：取下耳机后 / 关闭。
- **情景**：把环境声音、EQ、聆听模式组合保存，一键应用。
- **设置**：开机自启、启动最小化、窗口记忆、主题与背景、中文/English、托盘行为、自动刷新与重连、目标设备。
- **关于**：功能说明、本地化范围、GitHub 链接。

### 情景：三步写入，逐步读回

一个情景最多保存三组状态：

1. 环境声音：模式、等级、自动环境声、灵敏度、关注语音。
2. EQ：预设，Custom 时还有 10 段 band。
3. 聆听模式：BGM/Cinema/标准，以及房间距离。

应用时按固定顺序写入：**环境声音 → EQ → 聆听模式**。每一步都独立读回、独立报告；某一步失败不会中止后面的步骤，也不做整体回滚。

如果情景目标是 NC，还要先写 ASM 参数，再切 NC——原因前面说过，耳机在 ASM→NC 时会保留上一次的 ASM 值。

### 连接生命周期

这是桌面端和手机 App 共存的关键设计：

- 主窗口显示时，保持一个 Tandem 会话，复用连接、GATT 发现和握手。热写入大约 0.3–1 秒，而不是每次重新连几秒。
- 从托盘打开窗口时，后台立即预热连接；预热期间的操作会等待，不会开第二个会话。
- 隐藏到托盘时**释放连接**，把 Tandem 让给手机上的官方 App。
- 隐藏状态下的自动刷新使用"连接一次、刷新、释放"的一次性模式。
- 链路断开（耳机断电、蓝牙开关、另一台主机占用）后，下一次操作自动重连。

这个设计不追求"永远占着耳机"，而是明确取舍：窗口开着时体验优先，窗口关掉后把控制权还给手机。

### 设置与本地化

设置保存在：

```text
%LOCALAPPDATA%\Xm6Control\settings.json
```

写入是原子的，未知或缺失字段回退到默认值，文件损坏时保留为 `settings.json.corrupt`，不会直接覆盖。

本地化没有用 `.resw`，而是把字符串放在 `Localization.cs` 里。原因很实际：这是一个未打包、自包含的 WinUI 3 应用，运行时切换语言用集中式字符串表更可控。XAML 用 `Loc` 附加属性，动态字符串调用 `Localization.Text` / `Format`，切换语言不需要重启。

### 托盘与打包

托盘菜单提供概览、环境声音、均衡器、聆听模式、退出；提示里显示设备、当前模式和电量。

发布时做了两件事：

- 移除应用不会加载的 Windows App SDK AI/ML 和 Widgets 组件。
- 只保留中英文语言资源。

结果：解压后约 168 MB，压缩后约 67 MB。安装包用 Inno Setup 6 生成，安装到 `C:\Program Files\Sound Connect for Windows`，卸载时保留 `%LOCALAPPDATA%\Xm6Control` 下的设置和情景。

## 经验总结

### 1. HCI 是理想，反编译是可行的备选

有 HCI 抓包当然最好，它提供的是"设备实际说了什么"。没有的话，反编译能告诉你"App 期望什么"，但所有结论仍要靠实机读回验证。两者不是替代关系，是证据强度不同。

### 2. 先确认服务是否存在，再怀疑协议

握手失败时，很容易一头扎进帧格式。但这次真正的问题是 Windows 根本没暴露 Tandem 服务。先枚举、先确认服务在不在，再谈协议。

### 3. 主机侧也会影响 BLE 服务可见性

第三方 A2DP 驱动能让 `5b833e20` 消失，这个事实说明"耳机不支持"和"Windows 看不到"是两回事。遇到服务缺失，先排除主机侧变量。

### 4. 帧格式的四个细节，缺一不可

字段顺序、ACK 序号、发送序号、写模式。任何一处错，表现都是"连上了但没反应"，而且没有明确报错。这种问题只能靠对照反编译代码和逐帧日志定位。

### 5. 写入成功不等于生效

EQ 的 `0x58` 没有直接响应，多点连接的 Off 会被拒绝，ASM→NC 会保留旧参数。**唯一可信的成功标准是读回一致。**

### 6. 能力和状态要分开看

NC/ASM 能力是 type 21，状态是 type 25；DSEE 设置是 Auto/Off，效果是 valid/invalid。把能力查询当成状态查询，或者把"设置成功"当成"效果生效"，都会做错 UI。

### 7. 未知就保持未知

`0x03003032` 的语义没对上，就记录为未知，不参与功能判断。不猜状态变更命令，不因为"看起来像"就发写操作。这是逆向设备协议的安全底线。

### 8. 本地互操作要守住边界

不碰固件，不绕过签名校验，不复制 Sony 的代码、资源、图标。协议事实可以独立实现，产品边界必须清楚。

## 相关链接

- GitHub：[Sound-Connect-for-Windows](https://github.com/ThomasOffice/Sound-Connect-for-Windows)
- 最新版本：1.0.3（安装版 / 便携版）

## 免责声明

本项目是个人用途的互操作性实现，不是 Sony 官方产品。协议实现基于本机设备行为与公开的 Tandem 控制消息结构，未包含 Sony 的反编译源码、资源或固件。请勿用于绕过 DRM、固件签名校验或商业分发；设备功能会受耳机固件、连接状态和 Windows 蓝牙栈影响。

---

*写于 2026 年 11 月。耳机是自己的，协议是一帧一帧问出来的，代码是独立写的。*
