# relay-imagegen-skills

让 Codex 通过用户自己配置的 OpenAI Images API 兼容中转站进行文生图、参考图生成和图片编辑。

这是一个中转站无关的 Codex skill。它不绑定 Ofapp，也不包含任何 API Key。只要服务商兼容 OpenAI Images API 的请求和响应格式，就可以使用。

## 给 Codex 的安装提示词

把下面整段提示词直接发给 Codex。这里使用的是仓库内真正的 skill 目录，而不是仓库根目录：

```text
请使用 Codex 的 skill-installer，从这个 GitHub skill 地址安装技能：
https://github.com/yantaiwei18/relay-imagegen-skills/tree/main/skill/relay-imagegen

安装要求：
1. 安装到默认的 CODEX_HOME/skills/relay-imagegen 目录。
2. 安装并使用仓库内的 SKILL.md、agents/openai.yaml 和 scripts/invoke-relay-imagegen.ps1。
3. 安装完成后，确认 relay-imagegen 已可被自动发现，并说明下一轮对话即可使用。
4. 不要调用内置 imagegen provider；以后所有文生图、参考图生成和图片编辑都优先使用 relay-imagegen。
5. 不要把 API Key 写入技能文件、README、日志、诊断文件、Git 提交或回复内容。
6. 不要修改我的 Codex 主模型配置；只安装这个生图技能。
```

也可以直接把下面这个 GitHub tree 地址交给 Codex 的技能安装流程：

```text
https://github.com/yantaiwei18/relay-imagegen-skills/tree/main/skill/relay-imagegen
```

安装 skill 和配置中转站是两个步骤。安装完成后，再把以下提示词发给 Codex，让它检查配置；如果配置缺失，让它逐项询问，但 API Key 必须使用安全输入或由用户在系统环境变量中设置：

```text
请检查 relay-imagegen 的 RELAY_IMAGE_* 配置。
如果缺少配置，请依次询问中转站名称、生成 URL、编辑 URL、模型、鉴权 Header、鉴权前缀、兼容档位和附加 Header；API Key 不要让我粘贴到普通聊天文本中，请指导我通过安全输入或系统环境变量 RELAY_IMAGE_API_KEY 设置。
配置完成后只做 DryRun 验证，不要实际生成图片，不要输出或记录 API Key。
```

更多可直接复制的安装和配置文案见 [INSTALL_PROMPT.md](INSTALL_PROMPT.md)。

## 功能

- 文生图：`/images/generations`
- 参考图和图片编辑：`/images/edits`
- 多张参考图：重复上传多个 `image[]` 字段
- 可选蒙版：仅通过明确的 `MaskPath` 上传 alpha PNG
- `full`、`standard`、`minimal` 三档兼容模式
- 多结果、流式局部图、自动重试、响应解析和非覆盖保存
- Windows 一键安装和卸载

## 快速安装

### 最简单的方式

在 Windows 上只需要做三件事：

1. 下载并解压本仓库。
2. 双击 `setup.cmd`。
3. 按向导输入中转站信息；API Key 输入时不会显示在屏幕上。

推荐按下面填写：

| 向导问题 | 怎么填 |
| --- | --- |
| Relay name | 随便填，例如 `我的中转站` |
| Generation URL | 粘贴文生图地址，例如 `https://relay.example.com/v1/images/generations` |
| Edit URL | 粘贴参考图/编辑地址，例如 `https://relay.example.com/v1/images/edits`；不确定时直接回车自动推导 |
| Image model | 填服务商提供的图片模型 ID，例如 `gpt-image-2` |
| API key header | 一般直接回车，使用 `Authorization` |
| API key prefix | 一般直接回车，使用 `Bearer` |
| Compatibility profile | 一般直接回车，使用 `full` |
| Relay image API key | 粘贴 Key，输入时不会回显 |

安装器会自动把配置保存到当前 Windows 用户的 `RELAY_IMAGE_*` 环境变量，并运行 DryRun 自检。完成后完全退出并重新打开 Codex。

### 方式一：交互式安装

1. 安装并启动过一次 Windows 版 Codex。
2. 下载本仓库并解压。
3. 双击 `install.cmd`。
4. 按提示填写中转站名称、生成 URL、编辑 URL、模型、鉴权方式、兼容档位和 API Key。
5. 完全退出并重新打开 Codex。

安装程序会：

- 将 `skill/relay-imagegen` 安装到 `%USERPROFILE%\\.codex\\skills\\relay-imagegen`；
- 写入 `RELAY_IMAGE_*` 用户环境变量；
- 在 `%USERPROFILE%\\.codex\\AGENTS.md` 中加入受管理的全局生图规则；
- 自动执行一次不计生图的本地 DryRun 自检。

### 方式二：PowerShell 自动安装

在仓库根目录运行。省略 `-ApiKey`，安装器会从已有环境变量读取，或以安全输入方式询问，不要把 Key 写进命令历史。

```powershell
.\\install.ps1 `
  -ProviderName "My Relay" `
  -GenerationsUrl "https://relay.example.com/v1/images/generations" `
  -EditsUrl "https://relay.example.com/v1/images/edits" `
  -Model "gpt-image-2" `
  -AuthHeader "Authorization" `
  -AuthScheme "Bearer" `
  -CompatibilityProfile "full"
```

如果必须自动化部署，可以显式传入 `-ApiKey`，但请避免在共享终端、脚本仓库或 CI 日志中使用明文 Key。

## 中转站配置

### URL

`-GenerationsUrl` 和 `-EditsUrl` 接受以下形式：

```text
https://relay.example.com
https://relay.example.com/v1
https://relay.example.com/v1/images/generations
https://relay.example.com/api/image/create
```

根地址会自动补成标准生成端点，`/v1` 会自动补上 `/images/generations`。标准生成端点会自动推导编辑端点；非标准路由请手动填写 `-EditsUrl`。输入 `none` 可以禁用参考图和编辑。

### 鉴权

标准 OpenAI 兼容中转站：

```powershell
-AuthHeader "Authorization" -AuthScheme "Bearer"
```

使用 `x-api-key: KEY`：

```powershell
-AuthHeader "x-api-key" -AuthScheme "none"
```

需要固定附加请求头时：

```powershell
-ExtraHeadersJson '{"X-Client":"Codex","X-Region":"cn"}'
```

### 兼容档位

- `full`：发送尺寸、质量、格式、压缩、数量、流式和局部图参数。
- `standard`：发送常见标准参数，不发送流式和压缩扩展。
- `minimal`：只发送模型和提示词，编辑时再加图片和蒙版。适合参数兼容性较弱的中转站。

如果中转站返回“不支持某字段”，先改用 `standard`，仍失败再改用 `minimal`。

## 环境变量

安装器会在当前 Windows 用户范围配置以下变量：

| 变量 | 用途 |
| --- | --- |
| `RELAY_IMAGE_PROVIDER_NAME` | 中转站显示名称 |
| `RELAY_IMAGE_GENERATIONS_URL` | 文生图端点 |
| `RELAY_IMAGE_EDITS_URL` | 参考图/编辑端点 |
| `RELAY_IMAGE_MODEL` | 图片模型 ID |
| `RELAY_IMAGE_API_KEY` | API Key |
| `RELAY_IMAGE_AUTH_HEADER` | 鉴权 Header，默认 `Authorization` |
| `RELAY_IMAGE_AUTH_SCHEME` | 鉴权前缀，默认 `Bearer`，无前缀使用 `none` |
| `RELAY_IMAGE_EXTRA_HEADERS_JSON` | 附加 Header JSON 对象 |
| `RELAY_IMAGE_COMPATIBILITY_PROFILE` | `full`、`standard` 或 `minimal` |

不要把 `RELAY_IMAGE_API_KEY` 写入仓库文件。修改用户环境变量后，需要重启 Codex 才能让新会话读取到配置。

## 直接调用脚本

安装后，脚本位于 `%USERPROFILE%\\.codex\\skills\\relay-imagegen\\scripts\\invoke-relay-imagegen.ps1`。

### 文生图

```powershell
$params = @{
  Prompt = "A realistic spring lakeside fashion portrait, soft golden-hour backlight"
  OutputPath = "C:\\temp\\portrait.jpg"
  Quality = "medium"
}

$script = Join-Path $HOME ".codex\\skills\\relay-imagegen\\scripts\\invoke-relay-imagegen.ps1"
& $script @params
```

### 多张参考图

必须在当前 PowerShell 进程中直接调用脚本，并把路径作为数组传给 `ReferenceImagePath`：

```powershell
$params = @{
  Prompt = "Combine the subject from image 1 with the clothing style from image 2"
  ReferenceImagePath = @(
    "C:\\temp\\subject.png"
    "C:\\temp\\style.jpg"
  )
  OutputPath = "C:\\temp\\combined.jpg"
  Quality = "medium"
}

$script = Join-Path $HOME ".codex\\skills\\relay-imagegen\\scripts\\invoke-relay-imagegen.ps1"
& $script @params
```

脚本会把每张普通参考图上传为独立的 `image[]` 字段：

```text
image[]=@subject.png
image[]=@style.jpg
```

不要把第二张参考图传给 `MaskPath`。`MaskPath` 只用于用户明确提供的、带 alpha 通道且与第一张 PNG 参考图尺寸一致的蒙版。

## 验证配置

DryRun 只解析配置和请求，不会访问生图接口，也不会产生费用：

```powershell
$script = Join-Path $HOME ".codex\\skills\\relay-imagegen\\scripts\\invoke-relay-imagegen.ps1"
& $script -Prompt "configuration check" -DryRun
```

你应看到 `credential_configured: true`，并能看到解析后的端点、模型和兼容档位。输出中不会打印 API Key。

## 卸载

删除 skill 和全局生图规则：

```powershell
.\\uninstall.ps1
```

同时删除 `RELAY_IMAGE_*` 用户环境变量：

```powershell
.\\uninstall.ps1 -RemoveCredentials
```

卸载脚本只删除它自己管理的 Codex skill、标记区块和变量，不会删除其他 Codex 配置。

## 安全说明

- 本仓库不包含 API Key。
- API Key 只从 `RELAY_IMAGE_API_KEY` 或安装时的安全输入读取。
- 脚本不会把鉴权值写入诊断文件、生成文件或普通 DryRun 输出。
- 请不要提交 `.env`、本地配置、日志、输出图片或带 Key 的命令历史。
- 本项目仅适用于你有权使用的中转站和图片内容。

## 限制

“通用”指 OpenAI Images API 兼容中转站。若服务商使用完全不同的字段、上传格式或响应结构，需要增加专用适配器。

## 目录结构

```text
relay-imagegen-skills/
├─ install.cmd
├─ setup.cmd
├─ install.ps1
├─ uninstall.ps1
├─ manifest.json
├─ INSTALL_PROMPT.md
└─ skill/
   └─ relay-imagegen/
      ├─ SKILL.md
      ├─ agents/openai.yaml
      └─ scripts/invoke-relay-imagegen.ps1
```
