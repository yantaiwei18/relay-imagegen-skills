# Codex 安装提示词

本文档用于把本仓库直接交给 Codex。推荐使用 skill-installer 安装仓库内的 `skill/relay-imagegen`，不要把仓库根目录误当成 skill 目录。

## 一键安装提示词

复制下面整段文字发送给 Codex：

```text
请使用 Codex 的 skill-installer，从这个 GitHub skill 地址安装技能：
https://github.com/yantaiwei18/relay-imagegen-skills/tree/main/skill/relay-imagegen

请遵守以下安装规范：
1. 安装目标是默认的 CODEX_HOME/skills/relay-imagegen。
2. 安装仓库内的 SKILL.md、agents/openai.yaml 和 scripts/invoke-relay-imagegen.ps1。
3. 不要只阅读 README，也不要安装仓库里的 Windows 打包目录作为 skill。
4. 安装完成后确认技能名称为 relay-imagegen，并说明下一轮对话即可使用。
5. 以后所有 raster image 的生成、编辑、参考图和蒙版任务，优先使用 relay-imagegen，不使用内置 imagegen provider。
6. 不要修改 Codex 主模型、其他 skill 或无关配置。
7. 不要把 API Key 写入任何文件、日志、诊断结果、Git 提交或聊天回复。
```

## 配置提示词

skill 安装成功后，复制下面整段文字发送给 Codex：

```text
请配置并验证 relay-imagegen 的中转站环境变量。

请先读取现有的 RELAY_IMAGE_* 环境变量；已有值不要覆盖。缺少时依次询问：
- 中转站名称
- 文生图 URL（RELAY_IMAGE_GENERATIONS_URL）
- 参考图/编辑 URL（RELAY_IMAGE_EDITS_URL）
- 图片模型 ID（RELAY_IMAGE_MODEL）
- 鉴权 Header（默认 Authorization）
- 鉴权前缀（默认 Bearer；无前缀使用 none）
- 兼容档位（full、standard 或 minimal）
- 可选附加 Header JSON

API Key 不要让我粘贴到普通聊天文本中，也不要在回复中显示。请指导我把它设置为 RELAY_IMAGE_API_KEY，或使用安全的密码输入读取。

配置完成后只运行 invoke-relay-imagegen.ps1 的 DryRun，不要实际调用生图接口，不要产生图片费用。DryRun 只能报告端点、模型、鉴权 Header 名称、兼容档位和 credential_configured 状态，不能报告 Key 内容。
```

## Windows 便携安装提示词

如果用户希望同时安装全局规则、写入用户环境变量并使用交互式安装器，发送：

```text
请从以下 GitHub 仓库获取 Windows 便携安装包：
https://github.com/yantaiwei18/relay-imagegen-skills

请在用户明确确认后运行仓库根目录的 install.ps1。安装时使用交互式安全输入配置 API Key，不要把 -ApiKey 明文写入命令、脚本或日志。保留其他 Codex 配置，只添加 relay-imagegen 的受管理规则。安装后重启 Codex，并用 DryRun 验证，不要实际生成图片。
```

## 使用规范

- 文生图：不传 `ReferenceImagePath`，使用 `RELAY_IMAGE_GENERATIONS_URL`。
- 参考图或编辑：所有普通图片都放入 `ReferenceImagePath` 数组，使用 `RELAY_IMAGE_EDITS_URL`。
- 多张参考图必须上传为多个 `image[]` 字段。
- 第二张参考图绝不能传给 `MaskPath`。
- `MaskPath` 只用于用户明确提供的 alpha PNG，并且必须与第一张参考图尺寸一致。
- 不要用 `powershell.exe -File` 包装多参考图调用；在当前 PowerShell 进程中直接用 splatting 调用脚本。
- 输出默认非覆盖保存；只有用户明确要求时才使用 `Overwrite`。
- 生成完成后检查输出文件，并向用户报告路径和最终提示词，但不报告鉴权值。

## 安全边界

API Key 只能通过 `RELAY_IMAGE_API_KEY` 或安全输入提供。任何提示词、README、技能文件、诊断文件、生成文件和 Git 历史都不得包含真实 Key。
