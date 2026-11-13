#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#ifndef SourceDir
  #error SourceDir must point to the packaged Windows client directory.
#endif

#ifndef OutputDir
  #error OutputDir must point to the release output directory.
#endif

[Setup]
AppId={{A05E443A-A832-4891-A46E-27A8372E122A}
AppName=Meeting Client
AppVersion={#AppVersion}
AppPublisher=Meeting Client
DefaultDirName={autopf}\Meeting Client
DefaultGroupName=Meeting Client
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=MeetingClient-Setup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
UninstallDisplayIcon={app}\MeetingClient.exe
CloseApplications=force
RestartApplications=no

[Languages]
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\MeetingClient.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\livekit.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\livekit_ffi.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\Licenses\*"; DestDir: "{app}\Licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\Meeting Client"; Filename: "{app}\MeetingClient.exe"
Name: "{autodesktop}\Meeting Client"; Filename: "{app}\MeetingClient.exe"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装 Microsoft Visual C++ 运行库..."; Flags: runhidden waituntilterminated
Filename: "{app}\MeetingClient.exe"; Description: "启动 Meeting Client"; Flags: nowait postinstall skipifsilent
