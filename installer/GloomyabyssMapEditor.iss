#define AppName "Gloomyabyss Map Editor"
#define AppExe "gloomyabyss_map_editor.exe"
#define AppPublisher "JO-Beacon"
#define AppUrl "https://github.com/JO-Beacon/Gloomyabyss-MapEditor"

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "dist"
#endif
#ifndef IconSource
  #define IconSource "windows\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{7B1F5C52-9D2A-4E83-9C31-2A6E4B8D5F10}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={autopf}\GloomyabyssMapEditor
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=GloomyabyssMapEditor-v{#AppVersion}-windows-x64-setup
SetupIconFile={#IconSource}
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#ifdef ChineseMessagesFile
Name: "chinesesimplified"; MessagesFile: "{#ChineseMessagesFile}"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
