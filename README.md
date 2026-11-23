# Purrk

Purrk 把麦克风里的中英文讲话转成实时字幕和带时间戳的文字笔记。默认在 Mac 上转写，只保存文字。

## 安装与使用

1. 在 Apple 芯片 Mac（macOS 15 或更高版本）上打开 DMG，将 Purrk 拖入「应用程序」。[下载 Purrk 1.1](https://github.com/haampy/academic-notes-mac/releases/download/v1.1/Purrk-1.1-arm64.dmg)
2. 打开 Purrk，允许访问麦克风。首次启动会下载默认模型（约 2.2 GB），之后可离线使用。
3. 说话时可以按 ⌘B 标重点，点「暂停」可稍后继续。点右下角的方块结束记录，再从「更多操作 → 打开笔记文件夹」查看文字。

笔记按天编号，点标题可改名。点窗口左下角的设备名可切换麦克风，在「设置 → 显示」中可调字号。

安装包未经 Apple 公证。如果系统提示无法验证开发者，请确认安装包来自本仓库，再到「系统设置 → 隐私与安全性」点「仍要打开」。[Apple 说明](https://support.apple.com/zh-cn/102445)

## 转写与同步

- 在「设置」中可更换**本地模型**。默认是 Qwen3-ASR 1.7B，轻量版 0.6B 约 840 MB。FireRedASR2-AED 适合普通话和方言，Confucius4-R2T2 可边说边出字幕。切换引擎后，暂停再继续即可生效。
- 使用**云端转写**时，选「阿里云百炼」和服务地域，填入对应的 API Key 并保存。音频会发送到百炼，按账号用量计费。密钥保存在 macOS 钥匙串。
- 要**同步到飞书**，先安装并配置飞书 CLI，再运行 `lark-cli auth login --domain docs --domain drive`。记录结束后，笔记会自动存入个人云盘的「Purrk」文件夹。要换位置，可在设置中填写文件夹 token。[飞书 CLI 安装指南](https://github.com/larksuite/cli/blob/main/README.zh.md)

## 从源码构建

构建前请安装 Xcode 命令行工具和 [uv](https://docs.astral.sh/uv/getting-started/installation/)。

```sh
git clone https://github.com/haampy/academic-notes-mac.git
cd academic-notes-mac
./build.sh
```

构建产物默认为 `build/Purrk.app`，也可用 `git config --local purrk.installDir "/安装目录"` 指定位置。发布时运行 `./build.sh --dmg` 和 `python3 bundle-sources.py`，将 `build/` 下的 DMG 和第三方源码包一起上传。

反馈问题时请附上 macOS 版本、引擎和复现步骤。[提交 Issue](https://github.com/haampy/academic-notes-mac/issues)

项目代码采用 [MIT 许可证](LICENSE)。第三方依赖和模型遵循各自许可。使用 Confucius4-R2T2 即接受网易有道模型许可，商业使用限制见第 2.2 条。[模型许可](https://github.com/netease-youdao/Confucius4-R2T2/blob/master/MODEL_LICENSE_zh)
