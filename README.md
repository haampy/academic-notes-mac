# Purrk

Mac 上的中英学术语音笔记。打开应用、允许麦克风访问后，悬浮窗会显示原语言字幕。点击「结束」将已定稿文字保存到本机。连接飞书后，还会在自己的云盘创建一篇带时间戳的文档。音频在内存中处理。

## 下载安装

适用于配备 Apple 芯片（M 系列）、运行 macOS 15 或更高版本的 Mac。

1. [下载 Purrk 1.0 安装包（DMG）](https://github.com/haampy/academic-notes-mac/releases/download/v1.0/Purrk-1.0-arm64.dmg)，双击打开，将 Purrk 拖入「应用程序」。
2. 从「应用程序」打开 Purrk，允许访问麦克风。首次启动会联网下载默认的本地模型（约 2.2 GB）。Python 和转写依赖已随应用打包。
3. 对着麦克风说一句话，等字幕出现后点「结束」，再点「本地笔记」查看文字。

需要同步至飞书时，先按官方指南安装并配置 `lark-cli`，再运行 `lark-cli auth login --domain docs --domain drive`，授权写入自己的云盘。[飞书 CLI 安装指南](https://github.com/larksuite/cli/blob/main/README.zh.md)

1.0 版尚未经 Apple 公证。如果 macOS 提示无法验证开发者，请先确认文件来自本仓库的发布页，再到「系统设置 → 隐私与安全性」为 Purrk 选择「仍要打开」。[Apple 官方说明](https://support.apple.com/zh-cn/102445)

## 使用

- 录音或暂停时，点击顶部工具栏中的标题即可改名。按回车、移开焦点或结束记录时保存。本地文件名包含标题和会话标识，飞书文档采用填写的标题。
- 顶部的图钉可随时切换字幕窗口置顶。首次打开时默认置顶，之后会记住上次的选择。
- 「暂停」会提交当前句，「继续」接着记到同一篇。「标重点」（⌘B）会在当前时间插入 ★。
- 在齿轮设置中选择转写引擎。首次用某个本地模型开始或继续记录时，应用会下载该模型。下载完成后，可离线转写。
- 选择「云端 API · 阿里云百炼」时，选对应地域，填入该地域的 API Key 并点「保存」。密钥存入 macOS 钥匙串。Workspace ID 可用于连接业务空间专属域名。云端模式会将麦克风音频发给百炼的实时转写服务，按账户用量计费。[百炼模型说明](https://help.aliyun.com/zh/model-studio/qwen-audio-3-1-asr-flash-streaming)
- 引擎和课题术语在下次开始或继续记录时生效。术语可填英文缩写、人名等，用逗号分隔。飞书文件夹 token 可留空，默认保存到个人云盘。
- 点「打开最近的飞书笔记」查看最近上传的笔记。同步失败时会出现「重试同步」，网络恢复或下次启动时也会自动补传。本地文字可在「本地笔记」中查看。
- 应用采集系统默认麦克风。字幕中的中文统一转成简体，英文保留原语言。本地笔记与飞书使用同一份定稿。

## 本地转写引擎

| 模型 | 约下载量 | 适用场景 |
| --- | ---: | --- |
| Qwen3-ASR 1.7B | 2.2 GB | 默认选项，适合中英学术笔记，支持课题术语和临时字幕。 |
| Qwen3-ASR 0.6B | 840 MB | 轻量选项，适合希望减小下载量及内存占用时使用。 |
| FireRedASR2-AED | 4.57 GB | 适合普通话、方言和中英混说。每句定稿后显示，输出通常没有标点，英文为小写。此引擎不使用课题术语。 |
| Confucius4-R2T2 8 位 | 2.48 GB | 适合边听边看中英字幕，随讲话逐步显示已确认的文字。可填写课题术语提示人名与缩写。 |

FireRed 使用社区转换的 MLX 权重，原始模型采用 Apache 2.0 许可。[FireRed 官方模型说明](https://huggingface.co/FireRedTeam/FireRedASR2-AED) · [MLX 权重](https://huggingface.co/mlx-community/FireRedASR2-AED-mlx/tree/f3212eacfa49b851130b97c63653c8e06ee09bdb)

Confucius4-R2T2 来自网易有道，应用使用 MLX 社区的 8 位量化版。使用该模型即接受《网易有道模型使用许可协议》。按照中文协议第 2.2 条，您或关联方的产品或服务上个自然月月活用户超过 1 亿，或您或关联方上个自然年收入超过人民币 1 亿元，须向网易有道另行取得商业许可。[中文许可原文](https://github.com/netease-youdao/Confucius4-R2T2/blob/master/MODEL_LICENSE_zh) · [量化权重与声明](https://huggingface.co/mlx-community/Confucius4-R2T2-8bit)

## 从源码运行

在 Apple 芯片 Mac 上安装 Xcode 命令行工具和 [uv](https://docs.astral.sh/uv/getting-started/installation/)，然后在终端运行以下命令。

```sh
git clone https://github.com/haampy/academic-notes-mac.git
cd academic-notes-mac
./build.sh
```

打开构建结束时显示的 `Purrk.app`，默认位于 `build/`。如果已选好安装目录，可用 `git config --local purrk.installDir "/安装目录"` 设置一次，以后构建会直接更新该处的应用。

构建会把 Python 运行时装在用户的 Application Support/AcademicNotes 下。本地转写使用 MLX，暂停或结束后释放模型内存。

要制作包含 Python 和转写依赖的安装包，运行 `./build.sh --dmg`。发布时再运行 `python3 bundle-sources.py`，把生成的第三方源码附件与 DMG 一起上传。两个文件均位于 `build/`。

## 一起开发

遇到问题或想提新功能，可以开一个 [Issue](https://github.com/haampy/academic-notes-mac/issues)。报告问题时，请写明 macOS 版本、所选引擎、复现步骤，以及实际看到的结果。

想提交改动时，先 Fork 仓库，在自己的分支上完成一项改动，按上面的步骤构建并试用，然后向本仓库的 `main` 提交 Pull Request。请写明改了什么、怎么验证；有关联的 Issue，可以一并附上。维护者会审阅、讨论并决定是否合并。

项目原创代码采用 [MIT 许可证](LICENSE)。第三方依赖与模型各自适用原许可证。
