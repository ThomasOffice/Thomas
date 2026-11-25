+++
title = '验证码中继 v2.0：从短信到邮箱，从 Tkinter 到双端 Fluent Glass'
date = '2026-11-25T12:00:00+08:00'
draft = false
author = 'Thomas'
categories = ['技术']
tags = ['验证码', '蓝牙', 'IMAP', '邮箱验证码', 'Jetpack Compose', 'WebView2', 'Fluent Glass', '排错']
description = '验证码中继工具的 v1.1 / v2.0 迭代记录：IMAP 邮箱验证码、UID 与序号的坑、严格模式、双端 Fluent Glass UI、WebView2 运行时与高 DPI 图标适配。'
keywords = ['验证码中继', 'IMAP', '邮箱验证码', 'Jetpack Compose', 'WebView2', 'Fluent Glass', '蓝牙', 'SmsRelay']
toc = true
autoCollapseToc = true
comment = true
+++

> v1.0 解决了"手机短信验证码 → 蓝牙 → PC 剪贴板"的链路，也踩完了 Android 后台限制、COM 端口、SDP 等坑。本文是续篇：v1.1 加入 IMAP 邮箱验证码，v2.0 把 PC 和 Android 两端重构为统一的 Fluent Glass UI，并记录这一轮新增的坑。

## 回顾 v1.0：那条已经跑通的链路

v1.0 的最终架构并不复杂：

```text
Android 手机                              PC (Windows)
┌─────────────────────┐  蓝牙 RFCOMM  ┌──────────────────────┐
│ SmsPoller 轮询短信库  │ ────────────> │ Winsock2 直连监听     │
│ CodeExtractor 正则    │  JSON 行      │ 端口 5 (无 SDP)       │
│ BtClient 反射直连端口5│              │ CodeHandler 校验+剪贴板│
│ KeepAliveService 保活 │              │ TrayApp 托盘+UI       │
└─────────────────────┘              └──────────────────────┘
```

- **短信**：每 2 秒轮询 `content://sms/inbox`，用 `_id` 增量检测，绕开国产 ROM 对后台广播的冻结。
- **蓝牙**：PC 端 Winsock2 `bind + listen` 固定 RFCOMM 端口 5；Android 端反射调用 `createRfcommSocket(5)` 直连，绕过 COM 端口和 SDP。
- **PC 端**：token 校验、去重、写剪贴板、Windows 通知、系统托盘。

v1.0 踩过的 8 个坑——广播权限、华为后台冻结、UI 线程崩溃、`BLUETOOTH_SCAN`、COM 端口幽灵化、Winsock2 直连、SDP 注册失败、反射直连端口——都记录在上一篇文章里：

[《蓝牙验证码中继工具：从踩坑到上线的完整排错纪实》]({{< ref "/posts/2026-08-12.md" >}})

本文不再重复那 8 个坑，只讲 v1.0 之后发生的事。

## 版本演进

| 版本 | 时间 | 主要内容 |
|------|------|----------|
| v1.0 | 2026-08 | 短信 + 蓝牙 + 托盘，跑通主链路 |
| v1.1 | 2026-08-15 | IMAP 邮箱验证码，和短信共用处理管道 |
| v2.0 | 2026-11-15 | 双端 Fluent Glass UI，开机自启，设置抽屉 |

从功能上看，v1.1 是"加一个来源"，v2.0 是"换一层皮"。但实际做下来，两者都不是简单的增量：邮箱有 IMAP 自己的坑，UI 重构则把 PC 和 Android 的技术栈都换了一遍。

## v1.1：把邮箱也接进来

很多网站的验证码发到邮箱，尤其是登录、改密码、开发者平台。短信链路跑通之后，每次还要打开邮箱、找邮件、复制数字，体验很割裂。

目标很明确：**邮箱验证码也走同一条处理管道**，不复制一套去重、剪贴板、通知逻辑。

### 一条管道，两个入口

最终的数据流是：

```text
邮箱 ──IMAP 轮询──> EmailPoller ──提取──┐
                                       ├─> CodeHandler.process_code()
手机短信 ──蓝牙──> BtServer ──token──提取─┘
                                              │
                                    去重 → 剪贴板 → 记录 → 通知
```

核心是 `CodeHandler.process_code(code, sender)`：

```python
def process_code(self, code: str, sender: str) -> bool:
    now = time.time()
    if code == self._last_code and (now - self._last_ts) < self.dedup_seconds:
        return False

    pyperclip.copy(code)
    self._last_code = code
    self._last_ts = now
    self.record.add(code, sender)

    if self.on_code:
        self.on_code(code, sender)
    if self.notify:
        toast("验证码已接收", f"{code}\n来自: {sender}", duration="short")
    return True
```

短信和邮箱都只负责"拿到 code 和 sender"，剩下的事情完全一致。这个拆分看起来朴素，但它是后续加功能的前提：v2.0 的 UI 推送、历史时间线、邮箱状态，都挂在这条管道上。

### 配置长什么样

邮箱配置存在 `%APPDATA%\SmsRelay\config.yaml`：

```yaml
email:
  enabled: false
  imap_host: "imap.qq.com"
  imap_port: 993
  username: ""
  password: ""            # QQ 授权码（非登录密码）
  poll_interval: 30       # 轮询间隔（秒）
  since_days: 1           # 只处理最近 N 天的邮件
  mark_seen: true         # 处理后是否标记为已读
  strict: true            # 严格模式：只处理含验证码关键词的邮件
```

内置了 QQ、网易 163、网易 126、Gmail、Outlook 的 IMAP 预设，选预设会自动填服务器和端口。QQ 邮箱需要先在网页端开启 IMAP/SMTP，再生成**授权码**；登录密码在这里是没用的。

### IMAP 轮询的三个细节

#### 1. 连接与超时

```python
conn = imaplib.IMAP4_SSL(host, port, timeout=15)
conn.login(username, password)
conn.sock.settimeout(20)
```

连接超时和 socket 超时都要设。IMAP 服务器偶尔会卡住，如果不设超时，轮询线程会一直挂在那里，后面的邮件全部不处理。出错时关闭连接，下一轮重连。

#### 2. 只取正文，不轻易标记已读

```python
conn.uid("fetch", uid, "(BODY.PEEK[])")
```

用 `BODY.PEEK[]` 而不是 `BODY[]`，避免"拉取"这个动作本身把邮件标成已读。是否标记已读由 `mark_seen` 配置决定，单独调用 `STORE +FLAGS (\Seen)`。

#### 3. MIME 解码与 HTML 兜底

邮件的主题和发件人经常是 MIME 编码的：

```python
parts = decode_header(value)
```

正文优先取 `text/plain`；只有 HTML 时，简单去标签并压缩空白：

```python
body = re.sub(r"<[^>]+>", " ", html)
body = re.sub(r"\s+", " ", body)
```

这套逻辑不追求完整的 HTML 渲染，只要求把验证码周围的文字还原出来。

## 第九坑：IMAP 的 `search()` 返回的是序号，不是 UID

这是 v1.1 最隐蔽的一个 bug。

### 现象

邮箱配置正确，"测试连接"也成功，但新邮件永远收不到。日志里有时是"搜索无结果"，有时是 fetch 返回空，没有任何异常。

### 错误代码

最初是这样写的：

```python
status, data = conn.search(None, "SINCE", date)
for num in data[0].split():
    st, msg_data = conn.uid("fetch", num, "(BODY.PEEK[])")
```

看起来没问题：搜索、遍历、按 UID 取邮件。但实际上：

- `conn.search()` 返回的是 **sequence number**（当前会话内的邮件序号，1..N）。
- `conn.uid("fetch", ...)` 期望的是 **UID**（邮件在邮箱里的持久唯一编号）。

两者是两套编号。把序号当 UID 传进去，服务器不会报错，只会返回一个空结果——因为"UID 等于这个序号"的邮件很可能不存在。

### 修复

搜索也必须用 UID 版本：

```python
status, data = conn.uid("search", None, "SINCE", date)
if status != "OK" or not data or not data[0]:
    return []
uids = data[0].split()
for uid in uids:
    st, msg_data = conn.uid("fetch", uid, "(BODY.PEEK[])")
```

### 经验

> IMAP 里只要用了 `uid()`，搜索就必须用 `uid("search")`。`search()` 和 `uid("search")` 的返回值是两套编号，混用不会报错，只会静默返回空。**"没有异常"不等于"逻辑正确"。**

## 第十坑：营销邮件里的 6 位数字不是验证码

### 现象

启用邮箱后，剪贴板开始出现奇怪的东西：订单号、优惠券码、快递单号、活动编号。它们都是 4–8 位数字，完美命中兜底规则。

### 原因

短信是一个"窄管道"：能发短信给你的，大多是银行、运营商、网站验证码。兜底规则"任意 4–8 位数字"问题不大。

邮箱是一个"宽管道"：营销邮件、账单、发票、社交通知全在里面。同一套正则无差别套用，误报是必然的。

### 修复：严格模式

默认开启 `strict: true`。严格模式下，只使用**正则本身包含验证码关键词**的规则：

```python
EMAIL_CODE_KEYWORDS = (
    "验证码", "动态码", "校验码", "认证码", "安全码", "授权码",
    "verification", "otp", "passcode", "security code",
)

def _is_keyword_rule(pattern: str) -> bool:
    lower = pattern.lower()
    return any(k.lower() in lower for k in EMAIL_CODE_KEYWORDS)
```

然后先主题、后正文：

```python
code = extract_code(subject, rules) or extract_code(body, rules)
```

这样，"任意 4–8 位数字"的兜底规则不会参与邮箱提取，只有"验证码/verification code/OTP"这类规则才会命中。

### 经验

> 短信和邮件的信噪比完全不同。**同一套提取规则不能无差别复用。** 严格模式应该是默认值，而不是一个需要用户自己去发现的选项。

## v1.1 的其他工程细节

- **FETCH 响应结构不统一**：不同 IMAP 服务器返回的 `msg_data` 结构有差异，不能假设固定位置。用一个稳健的提取函数，遍历所有元素找 `bytes`。
- **进程内去重**：`processed_uids` 集合记录本次进程处理过的 UID，避免同一封邮件在多次轮询中重复处理。
- **配置热更新**：设置抽屉保存后调用 `EmailPoller.apply_config()`，不需要重启；关闭邮箱时主动断开连接。
- **测试连接**：单独建立一次 `IMAP4_SSL` 登录/登出，不污染轮询线程的状态。
- **安全**：授权码以明文存在本机 `config.yaml`，建议使用独立授权码，并随时在邮箱网页端撤销重置。

## v2.0：为什么要重做 UI

v1.x 的 PC 端是 CustomTkinter，Android 端是传统 XML 布局。功能没问题，但两边看起来像两个不同的产品：

- 颜色、圆角、字体、间距各写各的。
- 深色模式和浅色模式的对比度要分别调。
- 设置项越加越多，旧界面开始放不下。

v2.0 的目标不是"换个好看的颜色"，而是**建立一套双端共用的设计语言**：

- 炭黑底 / 暖白底两套主题，支持深色、浅色、跟随系统。
- 翡翠渐变作为主强调色。
- UI 字体 Inter，验证码和时间戳用 JetBrains Mono。
- Lucide 风格的线性图标。
- 主界面固定为三块：hero 验证码卡片、最近接收时间线、连接状态球。
- 设置收进抽屉，不再挤在主界面。

### PC 端：pywebview + WebView2

PC 端从 CustomTkinter 换成了 **pywebview + WebView2**：窗口是原生的，内容是 HTML/CSS/JS。这样毛玻璃、渐变、动画、字体都能用 Web 技术实现，同时保留 Python 的后端逻辑。

通信是双向的：

```text
JS → Python：window.pywebview.api.copy() / gen_token() / save_email() ...
Python → JS：window.evaluate_js("window.__setState({...})")
```

线程模型要特别注意：

- 主线程运行 `webview.start()`，WebView2 需要 STA 消息循环。
- 蓝牙、邮箱后端线程不变。
- `js_api` 在独立线程执行，可以阻塞。
- Python → JS 的推送用 1 秒刷新线程 + 新验证码事件回调，`evaluate_js` 加锁，避免并发写。

后端逻辑（蓝牙监听、邮箱轮询、剪贴板管道）完全没动，只换了窗口和交互层。这是 v1.1 管道化带来的好处。

### Android 端：Jetpack Compose

Android 端用 Compose 重写，和 PC 共用同一套视觉语言：

- `GlassTheme`：颜色、字体、形状令牌。
- `GlassComponents`：玻璃卡片、渐变按钮、状态球、开关。
- `GlassDashboard`：hero 验证码 + 时间线 + 状态球。
- `GlassSettingsSheet`：设备、Token、外观、日志。
- `GlassIcons`：Lucide 风格矢量图标。
- `MainViewModel` + `RelayLog`：UI 状态和全局日志总线（StateFlow）。

同时补了几件移动端必须做的事：

- **开机自启**：`BootReceiver` 接收 `BOOT_COMPLETED`，只有已配置设备/token 且用户开启自启时才启动前台服务。
- **前台服务保活**：`KeepAliveService` 常驻通知，轮询短信库。
- **通知图标**：单独做单色 `ic_stat_relay`，避免通知栏显示成白色方块。
- **edge-to-edge / 灵动岛适配**：用 WindowInsets 处理状态栏、导航栏和挖孔区域，内容不被遮挡。

### 共享图标

两端共用 `assets/icon.svg` 作为矢量源：

- Windows 生成多尺寸 `.ico`，托盘用 `.png`。
- Android 生成各 DPI 的 mipmap PNG 和单色通知图标。

这样图标改一次，两端都能重新导出，不会再出现"PC 是新图标、手机是旧图标"的情况。

## v2.0 的新坑

### 第十一坑：WebView2 不是"系统自带"

pywebview 依赖 Edge WebView2 Runtime。Windows 11 通常自带，所以开发机上一切正常；但 Windows 10 不一定有，用户双击 exe 可能只看到一个空白窗口。

正确处理方式：

- 启动时检测 WebView2 运行时是否可用。
- 缺失时给出明确提示，引导安装 Evergreen Runtime，而不是让用户对着空白窗口猜。
- 打包时把 `web/` 目录、字体、图标一起收进 exe，避免路径缺失。

PyInstaller 这一层也有坑：

```powershell
pyinstaller --noconfirm --windowed --onefile `
    --collect-all webview `
    --add-data "web;web" `
    --add-data "config.yaml;." `
    --hidden-import "webview_app" `
    server.py
```

`--collect-all webview` 不能少，否则 pywebview 的运行时文件不会被收进去。

### 第十二坑：高 DPI 下的图标模糊

旧的 PNG 图标在 100% 缩放下没问题，但 125%、150% 缩放时明显发糊。原因是只有一个尺寸，Windows 只能拉伸。

修复方式：

- 用矢量源 `icon.svg` 生成多尺寸 `.ico`（16/24/32/48/64/128/256）。
- Android 用各 DPI 的 mipmap PNG + 单色通知图标。
- Windows 图标缓存可能仍然显示旧图标，需要清理缓存或重启 explorer。

这件事看起来小，但托盘图标是常驻的，模糊会一直被看到。

### 第十三坑：Compose 的 edge-to-edge 不是"全屏就完事"

v2.0 启用了 edge-to-edge（`enableEdgeToEdge()`），内容会画到状态栏和导航栏后面。如果不处理 insets，hero 卡片会被状态栏压住，底部按钮会被导航条挡住。

做法：

- 用 `WindowInsets.systemBars` / `displayCutout` 计算 padding。
- 背景可以全屏，交互内容必须避让。
- 在带灵动岛/挖孔的机器上实机测试，不只看模拟器。

### 其他改进

- **Token 生成**：UI 内一键生成 24 位随机 Token，自动保存并复制到剪贴板。
- **邮箱设置抽屉**：预设选择、测试连接、保存后热更新，不用改配置文件。
- **验证码保护智能提示**：只有"正文含验证码关键词、但提取不到数字"时才提示；出现星号时给出更明确的保护提示，没有星号时提示"可能被拦截"。用户关闭保护后能正常提取，就不再反复打扰。提示里会按品牌给出对应的设置路径。
- **关闭行为**：关闭到托盘或直接退出，可选；支持启动到托盘。
- **日志**：Android 用 `RelayLog` 全局日志总线；PC 日志在 `%APPDATA%\SmsRelay\logs\server.log`。

## 更新后的架构

```text
┌──────────────────────────── Android ────────────────────────────┐
│ Compose UI (GlassDashboard / GlassSettingsSheet)                │
│   ├─ MainViewModel + RelayLog                                   │
│   ├─ SmsPoller ──> CodeProtector + SmsProcessor（含提取）        │
│   ├─ BtClient（反射直连 RFCOMM 端口 5）                          │
│   └─ KeepAliveService / BootReceiver                            │
└───────────────────────────────┬─────────────────────────────────┘
                                │ 蓝牙 RFCOMM / JSON 行
┌───────────────────────────────▼─────────────────────────────────┐
│ PC (Windows)                                                    │
│   WebView2 UI (HTML/CSS/JS) <──pywebview──> Api                 │
│   ├─ BtServer（Winsock2 直连监听端口 5）                         │
│   ├─ EmailPoller（IMAP 轮询）                                    │
│   ├─ CodeHandler.process_code()                                 │
│   │    去重 → 剪贴板 → 记录 → 通知 → UI 推送                     │
│   └─ 系统托盘 / 开机自启 / 配置管理                              │
└─────────────────────────────────────────────────────────────────┘
```

两条来源、一条管道、两个前端。结构比 v1.0 复杂，但职责边界更清楚了。

## 技术栈

| 模块 | 技术 |
|------|------|
| Android | Kotlin 2.0 + Jetpack Compose + Gradle 8.11.1 + AGP 8.7.3 + compileSdk 35 |
| Android 蓝牙 | 反射调用 `createRfcommSocket(port)` 直连 |
| Android 短信 | `SmsPoller` 轮询 `content://sms/inbox` |
| PC | Python 3.13 + pywebview + WebView2 + pystray + pyperclip + win11toast |
| PC 蓝牙 | Winsock2 RFCOMM 直连（绕过 COM 端口和 SDP） |
| 邮箱 | Python `imaplib` IMAP4_SSL 轮询 |
| 通信协议 | JSON over RFCOMM，`\n` 分行 |
| 打包 | PyInstaller（PC）/ Gradle（Android） |

## 经验总结

### 1. 管道化是加功能的前提

短信和邮箱共用 `process_code()`，新增来源只需要负责"拿到 code 和 sender"，不用复制去重、剪贴板、通知逻辑。**先把共同路径抽出来，再加第二个入口。**

### 2. IMAP 的 UID 和 sequence 不能混

`search()` 返回序号，`uid("search")` 返回 UID。混用不会报错，只会静默返回空。这是 IMAP 最典型的"看起来对、实际全错"。

### 3. 宽管道要严格模式

短信的正则可以宽松，邮件不行。严格模式只跑含验证码关键词的规则，主题优先、正文兜底。**默认值应该是安全的，而不是最宽松的。**

### 4. 双端 UI 用设计令牌，不要各自发挥

颜色、字体、圆角、间距集中定义，PC 和 Android 都从同一套令牌取值。否则两个端会越走越远，最后变成两个产品。

### 5. WebView2 是运行时依赖

它不是 Python 包，也不是 exe 里自带的东西。Windows 10 用户可能没有，必须在启动时检测并给出可操作的提示。

### 6. 图标要矢量化、多尺寸

一个 PNG 打天下，在高 DPI 下一定糊。矢量源 + 多尺寸导出 + 通知单色图标，是桌面和移动端都要做的基础工作。

### 7. 自启和保活要适配国产 ROM

Android 的 `BOOT_COMPLETED` 可能被华为/荣耀/小米拦截，需要在系统"自启动管理"里手动允许。代码层面只能做到"申请"，不能保证"一定启动"。

### 8. 日志和读回是排错的基础

PC 端有 `server.log`，Android 端有 `RelayLog`，蓝牙写入有读回校验。链路越长，越要在每一环留下证据。**没有日志的排错，只能靠猜。**

## 相关链接

- v1.0 排错纪实：[《蓝牙验证码中继工具：从踩坑到上线的完整排错纪实》]({{< ref "/posts/2026-08-12.md" >}})
- GitHub：[ThomasOffice/SmsCodeRelay](https://github.com/ThomasOffice/SmsCodeRelay)
- 下载：`SmsRelay.exe`（PC，免安装）、`app-release.apk`（Android）
- PC 配置：`%APPDATA%\SmsRelay\config.yaml`
- PC 日志：`%APPDATA%\SmsRelay\logs\server.log`

---

*写于 2026 年 11 月。v1.0 让验证码"能过来"，v2.0 让它"来得舒服一点"。*
