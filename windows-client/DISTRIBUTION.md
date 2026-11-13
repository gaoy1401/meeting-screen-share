# Windows 客户端交付说明

## 在 Windows 构建机上生成成品

构建机需要 Windows 10/11 x64、Visual Studio 2022 的“使用 C++ 的桌面开发”
组件、CMake 3.20 或更高版本，并且首次构建可以访问 GitHub。

缺少构建工具时，可先在管理员 PowerShell 中安装：

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
winget install --id Kitware.CMake --exact --source winget
```

安装完成后重新打开 PowerShell。构建脚本会优先使用 PATH 中的 CMake，也会
自动查找 Visual Studio 随附的 CMake。

在 PowerShell 中运行：

```powershell
cd windows-client
.\scripts\build-release.ps1 -InstallInnoSetup
```

脚本会构建和测试客户端、下载并验证微软官方 VC++ x64 运行库、安装或调用
Inno Setup，并在 `dist` 中生成：

```text
MeetingClient-Windows-x64.zip
MeetingClient-Setup-0.1.0-x64.exe
SHA256SUMS.txt
```

如果 Inno Setup 已安装，可以省略 `-InstallInnoSetup`。指定版本号：

```powershell
.\scripts\build-release.ps1 -Version 0.2.0
```

## 发给其他人

把安装包和 `SHA256SUMS.txt` 传给对方即可。对方使用 Windows 10/11 x64，
双击安装包完成安装后，从桌面或开始菜单启动 Meeting Client，不需要安装
Visual Studio、CMake 或 LiveKit SDK。

免安装用户也可以解压 `MeetingClient-Windows-x64.zip`，保持 EXE 和两个
LiveKit DLL 在同一目录；如果系统缺少运行库，先运行包内的
`vc_redist.x64.exe`，再双击 `MeetingClient.exe`。

默认服务器为 `127.0.0.1:9000`。连接其他电脑上的服务端时，改为你自己的
服务端地址。所有参与者填写同一房间号（例如 `demo`）。本项目不提供公共默认服务器。

## SmartScreen 与代码签名

没有代码签名证书也能生成和使用安装包，但通过互联网公开下载时 Windows
SmartScreen 可能提示“未知发布者”。正式对外分发时，应使用受信任的代码
签名证书，或者使用 Microsoft Store 的 MSIX 分发。

如果签名证书已导入 Windows 证书存储，并且 Windows SDK 的
`signtool.exe` 可用，可在构建前设置证书指纹：

```powershell
$env:MEETING_SIGN_CERT_SHA1 = "证书的 SHA-1 指纹"
.\scripts\build-release.ps1 -InstallInnoSetup
```

脚本会先签名 `MeetingClient.exe`，再签名最终安装包，并验证签名状态。
签名证书私钥和密码不要放入项目或传输包。

## 校验传输文件

对方可运行：

```powershell
Get-FileHash .\MeetingClient-Setup-0.1.0-x64.exe -Algorithm SHA256
```

输出值应和 `SHA256SUMS.txt` 中对应文件的值完全一致。
