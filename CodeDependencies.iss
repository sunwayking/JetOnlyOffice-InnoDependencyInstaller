#ifndef Dependency_DownloadRetryCount
  #define Dependency_DownloadRetryCount 3
#endif
#ifndef Dependency_InstallBusyRetryCount
  #define Dependency_InstallBusyRetryCount 30
#endif

[Code]
// https://github.com/DomGries/InnoDependencyInstaller

// types and variables
type
  TDependency_Entry = record
    Filename: String;
    Parameters: String;
    Title: String;
    URL: String;
    Checksum: String;
    ForceSuccess: Boolean;
    RestartAfter: Boolean;
    Components: String;
    SkipInstall: Boolean;
  end;

var
  Dependency_List: array of TDependency_Entry;
  Dependency_NeedToRestart, Dependency_ForceX86, Dependency_ForceX64: Boolean;
  Dependency_Components: String;
  Dependency_DownloadPage: TDownloadWizardPage;

function Dependency_IsEntryActive(const Entry: TDependency_Entry): Boolean;
begin
  Result := (Entry.Components = '') or WizardIsComponentSelected(Entry.Components);
end;

// a file name is downloaded to and run from {tmp}, a full path is run where it is
function Dependency_FilePath(const Filename: String): String;
begin
  if PathIsRooted(Filename) then begin
    Result := Filename;
  end else begin
    Result := ExpandConstant('{tmp}{\}') + Filename;
  end;
end;

procedure Dependency_Add(const Filename, Parameters, Title, URL, Checksum: String; const ForceSuccess, RestartAfter: Boolean);
var
  Dependency: TDependency_Entry;
  DependencyCount: Integer;
begin
  Dependency.Filename := Filename;
  Dependency.Parameters := Parameters;
  Dependency.Title := Title;

  if FileExists(Dependency_FilePath(Filename)) then begin
    Dependency.URL := '';
    Log('Dependency queued (already present): ' + Title);
  end else begin
    Dependency.URL := URL;
    Log('Dependency queued for download: ' + Title);
  end;

  Dependency.Checksum := Checksum;
  Dependency.ForceSuccess := ForceSuccess;
  Dependency.RestartAfter := RestartAfter;
  Dependency.Components := Dependency_Components;
  Dependency.SkipInstall := False;

  DependencyCount := GetArrayLength(Dependency_List);
  SetArrayLength(Dependency_List, DependencyCount + 1);
  Dependency_List[DependencyCount] := Dependency;
end;

procedure Dependency_AddIfMissing(const Missing: Boolean; const Filename, Parameters, Title, URL, Checksum: String; const ForceSuccess, RestartAfter: Boolean);
begin
  if Missing then begin
    Dependency_Add(Filename, Parameters, Title, URL, Checksum, ForceSuccess, RestartAfter);
  end else begin
    Log('Dependency already installed: ' + Title);
  end;
end;

<event('InitializeWizard')>
procedure Dependency_InitializeWizard;
begin
  Dependency_DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

<event('PrepareToInstall')>
function Dependency_PrepareToInstall(var NeedsRestart: Boolean): String;
var
  DependencyCount, DependencyIndex, ActiveCount, ActiveIndex, ResultCode, ParameterIndex, Attempt: Integer;
  Parameter, TempValue: String;
  Retry: Boolean;
begin
  DependencyCount := GetArrayLength(Dependency_List);

  if DependencyCount > 0 then begin
    Dependency_DownloadPage.Show;
    try
      for DependencyIndex := 0 to DependencyCount - 1 do begin
        if not Dependency_IsEntryActive(Dependency_List[DependencyIndex]) then begin
          continue;
        end;
        if Dependency_List[DependencyIndex].URL <> '' then begin
          Dependency_DownloadPage.Clear;
          Dependency_DownloadPage.Add(Dependency_List[DependencyIndex].URL, Dependency_List[DependencyIndex].Filename, Dependency_List[DependencyIndex].Checksum);
          Dependency_DownloadPage.SetText(Dependency_List[DependencyIndex].Title, '');

          Attempt := 0;
          Retry := True;
          while Retry do begin
            Retry := False;
            try
              Dependency_DownloadPage.Download;
            except
              if Dependency_DownloadPage.AbortedByUser then begin
                Log('Download aborted by user: ' + Dependency_List[DependencyIndex].Title);
                Result := Dependency_List[DependencyIndex].Title;
              end else begin
                Log('Download failed: ' + Dependency_List[DependencyIndex].Title + ': ' + GetExceptionMessage);
                Attempt := Attempt + 1;
                // a transient network error must not fail an unattended setup on the first try
                if Attempt <= {#Dependency_DownloadRetryCount} then begin
                  Log('Retrying download (attempt ' + IntToStr(Attempt) + ' of ' + IntToStr({#Dependency_DownloadRetryCount}) + '): ' + Dependency_List[DependencyIndex].Title);
                  Sleep(Attempt * 2000);
                  Retry := True;
                end else begin
                  case SuppressibleMsgBox(AddPeriod(GetExceptionMessage), mbError, MB_ABORTRETRYIGNORE, IDABORT) of
                    IDABORT: begin
                      Result := Dependency_List[DependencyIndex].Title;
                    end;
                    IDRETRY: begin
                      Attempt := 0;
                      Retry := True;
                    end;
                    IDIGNORE: begin
                      Dependency_List[DependencyIndex].SkipInstall := True;
                      Log('Dependency skipped after failed download: ' + Dependency_List[DependencyIndex].Title);
                    end;
                  end;
                end;
              end;
            end;
          end;
          if Result <> '' then begin
            break;
          end;
        end;
      end;

      if Result = '' then begin
        ActiveCount := 0;
        for DependencyIndex := 0 to DependencyCount - 1 do begin
          if Dependency_IsEntryActive(Dependency_List[DependencyIndex]) and not Dependency_List[DependencyIndex].SkipInstall then begin
            ActiveCount := ActiveCount + 1;
          end;
        end;

        ActiveIndex := 0;
        for DependencyIndex := 0 to DependencyCount - 1 do begin
          if not Dependency_IsEntryActive(Dependency_List[DependencyIndex]) then begin
            Log('Dependency skipped (component not selected): ' + Dependency_List[DependencyIndex].Title);
            continue;
          end;
          if Dependency_List[DependencyIndex].SkipInstall then begin
            continue;
          end;
          ActiveIndex := ActiveIndex + 1;
          Dependency_DownloadPage.SetText(Dependency_List[DependencyIndex].Title, '');
          Dependency_DownloadPage.SetProgress(ActiveIndex, ActiveCount + 1);

          Attempt := 0;
          while True do begin
            ResultCode := 0;
#ifdef Dependency_CustomExecute
            if {#Dependency_CustomExecute}(Dependency_FilePath(Dependency_List[DependencyIndex].Filename), Dependency_List[DependencyIndex].Parameters, ResultCode) then begin
#else
            if ShellExec('', Dependency_FilePath(Dependency_List[DependencyIndex].Filename), Dependency_List[DependencyIndex].Parameters, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then begin
#endif
              Log('Dependency exit code ' + IntToStr(ResultCode) + ': ' + Dependency_List[DependencyIndex].Title);
              if (ResultCode = 0) or Dependency_List[DependencyIndex].ForceSuccess then begin // ERROR_SUCCESS (0)
                if Dependency_List[DependencyIndex].RestartAfter then begin
                  if ActiveIndex = ActiveCount then begin
                    Dependency_NeedToRestart := True;
                  end else begin
                    NeedsRestart := True;
                    Result := Dependency_List[DependencyIndex].Title;
                  end;
                end;
                break;
              end else if ResultCode = 1641 then begin // ERROR_SUCCESS_REBOOT_INITIATED (1641)
                NeedsRestart := True;
                Result := Dependency_List[DependencyIndex].Title;
                break;
              end else if ResultCode = 3010 then begin // ERROR_SUCCESS_REBOOT_REQUIRED (3010)
                Dependency_NeedToRestart := True;
                break;
              end else if ResultCode = 1638 then begin // ERROR_PRODUCT_VERSION (1638)
                break;
              end else if ResultCode = 1618 then begin // ERROR_INSTALL_ALREADY_RUNNING (1618)
                Attempt := Attempt + 1;
                // another installer (often Windows Update) holds the install mutex, so wait instead of failing
                if Attempt <= {#Dependency_InstallBusyRetryCount} then begin
                  Log('Another installation is in progress, waiting (attempt ' + IntToStr(Attempt) + ' of ' + IntToStr({#Dependency_InstallBusyRetryCount}) + '): ' + Dependency_List[DependencyIndex].Title);
                  Sleep(10000);
                  continue;
                end;
              end;
            end;

            case SuppressibleMsgBox(FmtMessage(SetupMessage(msgErrorFunctionFailed), [Dependency_List[DependencyIndex].Title, IntToStr(ResultCode)]), mbError, MB_ABORTRETRYIGNORE, IDABORT) of
              IDABORT: begin
                Result := Dependency_List[DependencyIndex].Title;
                break;
              end;
              IDIGNORE: begin
                break;
              end;
            end;
          end;

          if Result <> '' then begin
            break;
          end;
        end;

      end;
    finally
      Dependency_DownloadPage.Hide;
    end;

    if NeedsRestart then begin
      Log('Dependency requires restart: registering RunOnce to resume setup');
      TempValue := '"' + ExpandConstant('{srcexe}') + '" /restart=1 /LANG="' + ExpandConstant('{language}') + '" /DIR="' + RemoveBackslashUnlessRoot(WizardDirValue) + '" /GROUP="' + RemoveBackslashUnlessRoot(WizardGroupValue) + '" /TYPE="' + WizardSetupType(False) + '" /COMPONENTS="' + WizardSelectedComponents(False) + '" /TASKS="' + WizardSelectedTasks(False) + '"';
      for ParameterIndex := 1 to ParamCount do begin
        Parameter := Uppercase(ParamStr(ParameterIndex));
        if (Parameter = '/SP-') or (Parameter = '/SILENT') or (Parameter = '/VERYSILENT') or (Parameter = '/SUPPRESSMSGBOXES') or (Parameter = '/NOCANCEL') or (Parameter = '/NORESTART') or (Parameter = '/ALLUSERS') or (Parameter = '/CURRENTUSER') then begin
          TempValue := TempValue + ' ' + Parameter;
        end;
      end;
      if WizardNoIcons then begin
        TempValue := TempValue + ' /NOICONS';
      end;
      RegWriteStringValue(HKA, 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '{#SetupSetting("AppName")}', TempValue);
    end;
  end;
end;

#ifndef Dependency_NoUpdateReadyMemo
<event('UpdateReadyMemo')>
#endif
function Dependency_UpdateReadyMemo(const Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  DependencyIndex: Integer;
  DependencyMemo: String;
begin
  Result := '';
  if MemoUserInfoInfo <> '' then begin
    Result := Result + MemoUserInfoInfo + Newline + NewLine;
  end;
  if MemoDirInfo <> '' then begin
    Result := Result + MemoDirInfo + Newline + NewLine;
  end;
  if MemoTypeInfo <> '' then begin
    Result := Result + MemoTypeInfo + Newline + NewLine;
  end;
  if MemoComponentsInfo <> '' then begin
    Result := Result + MemoComponentsInfo + Newline + NewLine;
  end;
  if MemoGroupInfo <> '' then begin
    Result := Result + MemoGroupInfo + Newline + NewLine;
  end;
  if MemoTasksInfo <> '' then begin
    Result := Result + MemoTasksInfo;
  end;

  DependencyMemo := '';
  for DependencyIndex := 0 to GetArrayLength(Dependency_List) - 1 do begin
    if Dependency_IsEntryActive(Dependency_List[DependencyIndex]) then begin
      DependencyMemo := DependencyMemo + #13#10 + '%1' + Dependency_List[DependencyIndex].Title;
    end;
  end;

  if DependencyMemo <> '' then begin
    if MemoTasksInfo = '' then begin
      Result := Result + SetupMessage(msgReadyMemoTasks);
    end;
    Result := Result + FmtMessage(DependencyMemo, [Space]);
  end;
end;

<event('NeedRestart')>
function Dependency_NeedRestart: Boolean;
begin
  Result := Dependency_NeedToRestart;
end;

function Dependency_IsArm64: Boolean;
begin
  Result := not Dependency_ForceX86 and not Dependency_ForceX64 and IsArm64;
end;

function Dependency_IsX64: Boolean;
begin
  Result := not Dependency_IsArm64 and not Dependency_ForceX86 and (Is64BitInstallMode or (Dependency_ForceX64 and IsX64Compatible));
end;

function Dependency_String(const x86, x64, arm64: String): String;
begin
  if Dependency_IsArm64 then begin
    Result := arm64;
  end else if Dependency_IsX64 then begin
    Result := x64;
  end else begin
    Result := x86;
  end;
end;

function Dependency_StringX64(const x86, x64: String): String;
begin
  Result := Dependency_String(x86, x64, x64);
end;

function Dependency_ArchSuffix: String;
begin
  Result := Dependency_String('', '_x64', '_arm64');
end;

function Dependency_ArchTitle: String;
begin
  Result := Dependency_String(' (x86)', ' (x64)', ' (arm64)');
end;

function Dependency_ArchHKLM: Integer;
begin
  if Dependency_IsArm64 or Dependency_IsX64 then begin
    Result := HKLM64;
  end else begin
    Result := HKLM32;
  end;
end;

function Dependency_PassiveOrQuiet(const Passive, Quiet: String): String;
begin
  if WizardSilent then begin
    Result := Quiet;
  end else begin
    Result := Passive;
  end;
end;

function Dependency_IsMsiProductInstalled(const UpgradeCode: String; const PackedMinVersion: Int64): Boolean;
begin
  try
    Result := IsMsiProductInstalled(UpgradeCode, PackedMinVersion);
  except
    Log('Failed to query MSI product ' + UpgradeCode + ': ' + GetExceptionMessage);
    Result := False;
  end;
end;

var
  Dependency_NetCoreRuntimesArch: String;
  Dependency_NetCoreRuntimes: TArrayOfString;

procedure Dependency_ListNetCoreRuntimes;
var
  Arch, Path: String;
  ResultCode: Integer;
  Output: TExecOutput;
begin
  Arch := Dependency_String('x86', 'x64', 'arm64');
  if Dependency_NetCoreRuntimesArch = Arch then begin
    exit;
  end;
  Dependency_NetCoreRuntimesArch := Arch;
  SetArrayLength(Dependency_NetCoreRuntimes, 0);

  // never keep a relative location: it would run whatever dotnet.exe sits in the current directory
  if not (RegQueryStringValue(HKLM32, 'SOFTWARE\dotnet\Setup\InstalledVersions\' + Arch, 'InstallLocation', Path)
    and PathIsRooted(Path) and FileExists(AddBackslash(Path) + 'dotnet.exe')) then begin
    Path := ExpandConstant(Dependency_StringX64('{commonpf32}', '{commonpf64}')) + '\dotnet';
  end;
  Path := AddBackslash(Path);

  if FileExists(Path + 'dotnet.exe') and ExecAndCaptureOutput(Path + 'dotnet.exe', '--list-runtimes', '', SW_HIDE, ewWaitUntilTerminated, ResultCode, Output) and (ResultCode = 0) then begin
    Dependency_NetCoreRuntimes := Output.StdOut;
  end;
end;

function Dependency_IsNetCoreInstalled(Runtime: String; Major, Minor, Revision: Word): Boolean;
var
  LineIndex: Integer;
  LineParts: TArrayOfString;
  PackedVersion: Int64;
  LineMajor, LineMinor, LineRevision, LineBuild: Word;
begin
  Dependency_ListNetCoreRuntimes;

  for LineIndex := 0 to Length(Dependency_NetCoreRuntimes) - 1 do begin
    LineParts := StringSplit(Trim(Dependency_NetCoreRuntimes[LineIndex]), [' '], stExcludeEmpty);

    if (Length(LineParts) > 1) and SameText(LineParts[0], Runtime) and StrToVersion(LineParts[1], PackedVersion) then begin
      UnpackVersionComponents(PackedVersion, LineMajor, LineMinor, LineRevision, LineBuild);

      if (LineMajor = Major) and (LineMinor = Minor) and (LineRevision >= Revision) then begin
        Result := True;
        exit;
      end;
    end;
  end;
  Result := False;
end;

procedure Dependency_AddDotNet35;
begin
  // https://learn.microsoft.com/en-us/dotnet/framework/install/dotnet-35-windows
  Dependency_AddIfMissing(not IsDotNetInstalled(net35, 1),
    GetSysNativeDir + '\dism.exe',
    '/online /enable-feature /featurename:NetFx3 /all /quiet /norestart',
    '.NET Framework 3.5 Service Pack 1',
    '',
    '',
    False, False);
end;

procedure Dependency_AddDotNet40;
begin
  // https://dotnet.microsoft.com/download/dotnet-framework/net40
  Dependency_AddIfMissing(not IsDotNetInstalled(net4full, 0),
    'dotNetFx40_Full_setup.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/q') + ' /norestart',
    '.NET Framework 4.0',
    'https://download.microsoft.com/download/1/B/E/1BE39E79-7E39-46A3-96FF-047F95396215/dotNetFx40_Full_setup.exe',
    'fa1afff978325f8818ce3a559d67a58297d9154674de7fd8eb03656d93104425',
    False, False);
end;

procedure Dependency_AddDotNet45;
begin
  // https://dotnet.microsoft.com/download/dotnet-framework/net452
  Dependency_AddIfMissing(not IsDotNetInstalled(net452, 0),
    'dotnetfx45.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/q') + ' /norestart',
    '.NET Framework 4.5.2',
    'https://download.microsoft.com/download/9/A/7/9A78F13F-FD62-4F6D-AB6B-1803508A9F56/51209.34209.03/web/NDP452-KB2901954-Web.exe',
    'bd173d14a371e6786c4ae90be1f2c560458d672ba4cbeb3cf55bebfef2e2778a',
    False, False);
end;

procedure Dependency_AddDotNet46;
begin
  // https://dotnet.microsoft.com/download/dotnet-framework/net462
  Dependency_AddIfMissing(not IsDotNetInstalled(net462, 0),
    'dotnetfx46.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/q') + ' /norestart',
    '.NET Framework 4.6.2',
    'https://download.visualstudio.microsoft.com/download/pr/8e396c75-4d0d-41d3-aea8-848babc2736a/570f7c7e1975df353a4652ae70b3e0ac/ndp462-kb3151802-web.exe',
    '67242c8fe953d454edb4171023343f33740e3d16e8469a4b0c11bd42eb85f3fa',
    False, False);
end;

procedure Dependency_AddDotNet47;
begin
  // https://dotnet.microsoft.com/download/dotnet-framework/net472
  Dependency_AddIfMissing(not IsDotNetInstalled(net472, 0),
    'dotnetfx47.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/q') + ' /norestart',
    '.NET Framework 4.7.2',
    'https://download.visualstudio.microsoft.com/download/pr/1f5af042-d0e4-4002-9c59-9ba66bcf15f6/124d2afe5c8f67dfa910da5f9e3db9c1/ndp472-kb4054531-web.exe',
    '151b1c11f625e7122d517b6a1778841df8ff168d931c41730f59b9e4b8bcbe36',
    False, False);
end;

procedure Dependency_AddDotNet48;
begin
  // https://dotnet.microsoft.com/download/dotnet-framework/net48
  Dependency_AddIfMissing(not IsDotNetInstalled(net48, 0),
    'dotnetfx48.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/q') + ' /norestart',
    '.NET Framework 4.8',
    'https://download.visualstudio.microsoft.com/download/pr/2d6bb6b2-226a-4baa-bdec-798822606ff1/9b7b8746971ed51a1770ae4293618187/ndp48-web.exe',
    '0bba3094588c4bfec301939985222a20b340bf03431563dec8b2b4478b06fffa',
    False, False);
end;

procedure Dependency_AddDotNet481;
begin
  // https://dotnet.microsoft.com/download/dotnet-framework/net481
  Dependency_AddIfMissing(not IsDotNetInstalled(net481, 0),
    'dotnetfx481.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/q') + ' /norestart',
    '.NET Framework 4.8.1',
    'https://download.microsoft.com/download/4/b/2/cd00d4ed-ebdd-49ee-8a33-eabc3d1030e3/NDP481-Web.exe',
    '05e9ada305fd0013a6844e7657f06ed330887093e3df59c11cb528b86efa3fbf',
    False, False);
end;

procedure Dependency_AddDotNetRuntime(const Runtime, Prefix, Title: String; Major, Minor, Revision: Word; const URL, Checksum: String);
begin
  // https://dotnet.microsoft.com/download/dotnet
  Dependency_AddIfMissing(not Dependency_IsNetCoreInstalled(Runtime, Major, Minor, Revision),
    Prefix + Dependency_ArchSuffix + '.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/quiet') + ' /norestart',
    Title + ' ' + IntToStr(Major) + '.' + IntToStr(Minor) + '.' + IntToStr(Revision) + Dependency_ArchTitle,
    URL,
    Checksum,
    False, False);
end;

procedure Dependency_AddNetCore31; begin Dependency_AddDotNetRuntime('Microsoft.NETCore.App', 'netcore31', '.NET Core Runtime', 3, 1, 32, Dependency_StringX64('https://builds.dotnet.microsoft.com/dotnet/Runtime/3.1.32/dotnet-runtime-3.1.32-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/Runtime/3.1.32/dotnet-runtime-3.1.32-win-x64.exe'), Dependency_StringX64('bc735b1a969cd03cbf1d0a70d5f16402e1030f309e5e58ca072307a30f0df164', '4393d2cdacecc096e964ea9761dfd5c336fb002b1b3ae0808e7d2d445e2dea89')); end;
procedure Dependency_AddNetCore31Asp; begin Dependency_AddDotNetRuntime('Microsoft.AspNetCore.App', 'netcore31asp', 'ASP.NET Core Runtime', 3, 1, 32, Dependency_StringX64('https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/3.1.32/aspnetcore-runtime-3.1.32-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/3.1.32/aspnetcore-runtime-3.1.32-win-x64.exe'), Dependency_StringX64('d3ebd94c684eb1ddb410a649d0a3185da05a7b21ef1d378d2e4a7ee21bfd27d2', '03035faabb028399f3fbe41fe565aec4204deb9373fa65fe7efc769066ba0502')); end;
procedure Dependency_AddNetCore31Desktop; begin Dependency_AddDotNetRuntime('Microsoft.WindowsDesktop.App', 'netcore31desktop', '.NET Desktop Runtime', 3, 1, 32, Dependency_StringX64('https://download.visualstudio.microsoft.com/download/pr/3f353d2c-0431-48c5-bdf6-fbbe8f901bb5/542a4af07c1df5136a98a1c2df6f3d62/windowsdesktop-runtime-3.1.32-win-x86.exe', 'https://download.visualstudio.microsoft.com/download/pr/b92958c6-ae36-4efa-aafe-569fced953a5/1654639ef3b20eb576174c1cc200f33a/windowsdesktop-runtime-3.1.32-win-x64.exe'), Dependency_StringX64('765436d4aa3de87af8b390d1cd16fce94c5f72dd04173adbb49c940b98b47704', '22f4050ae4b6cdfd109f229f7f7a56f3b3afde00f592babfe890177c76ad8e40')); end;
procedure Dependency_AddDotNet50; begin Dependency_AddDotNetRuntime('Microsoft.NETCore.App', 'dotnet50', '.NET Runtime', 5, 0, 17, Dependency_String('https://builds.dotnet.microsoft.com/dotnet/Runtime/5.0.17/dotnet-runtime-5.0.17-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/Runtime/5.0.17/dotnet-runtime-5.0.17-win-x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/Runtime/5.0.17/dotnet-runtime-5.0.17-win-arm64.exe'), Dependency_String('40a978da46efa7e66de2c40d952778118b2207ba2344f6d59032d114cbdb40da', '8387e162223ac2adc4d0f24765a886052b8c514bb4eb3d7cc9333c747cd9a03b', '2d1a5d53717e92d6def6415c81acea3d1fbd729ec3d06f3b4312d57ee5906b65')); end;
procedure Dependency_AddDotNet50Asp; begin Dependency_AddDotNetRuntime('Microsoft.AspNetCore.App', 'dotnet50asp', 'ASP.NET Core Runtime', 5, 0, 17, Dependency_StringX64('https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/5.0.17/aspnetcore-runtime-5.0.17-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/5.0.17/aspnetcore-runtime-5.0.17-win-x64.exe'), Dependency_StringX64('0d2d451bbe54f652905530a2c635be974b439cef7aefa7eced314780ae1a2a67', '5e4c82c13b406f0542793ea3cb2d510fd97fa186bfe5017c1c3ca1e942bb9ae8')); end;
procedure Dependency_AddDotNet50Desktop; begin Dependency_AddDotNetRuntime('Microsoft.WindowsDesktop.App', 'dotnet50desktop', '.NET Desktop Runtime', 5, 0, 17, Dependency_String('https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/5.0.17/windowsdesktop-runtime-5.0.17-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/5.0.17/windowsdesktop-runtime-5.0.17-win-x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/5.0.17/windowsdesktop-runtime-5.0.17-win-arm64.exe'), Dependency_String('63fef76824c51df09ed6fc5b031796fad64435db0e72f1735021b55760360c98', '925cc68a346cf5692fc1b52f498db32edd278ade3f4331539b7914e23f3af417', '2de98cf23ac87178e703d608697ec2697d09a0715dc89967e89ffb1de8dbb532')); end;
procedure Dependency_AddDotNet60; begin Dependency_AddDotNetRuntime('Microsoft.NETCore.App', 'dotnet60', '.NET Runtime', 6, 0, 36, Dependency_String('https://builds.dotnet.microsoft.com/dotnet/Runtime/6.0.36/dotnet-runtime-6.0.36-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/Runtime/6.0.36/dotnet-runtime-6.0.36-win-x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/Runtime/6.0.36/dotnet-runtime-6.0.36-win-arm64.exe'), Dependency_String('3b3cb4636251a582158f4b6b340f20b3861e6793eb9a3e64bda29cbf32da3604', '6bdad7bc4c41fe93d4ae7b0312b1d017cfe369d28e7e2e421f5b675f9feefe84', 'e34775ff8723bf4e6d397473e302e246a18692e6ea3b3906eff3cb5a6f8c8f3b')); end;
procedure Dependency_AddDotNet60Asp; begin Dependency_AddDotNetRuntime('Microsoft.AspNetCore.App', 'dotnet60asp', 'ASP.NET Core Runtime', 6, 0, 36, Dependency_StringX64('https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/6.0.36/aspnetcore-runtime-6.0.36-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/6.0.36/aspnetcore-runtime-6.0.36-win-x64.exe'), Dependency_StringX64('af72a5b08fb14e95c1d05d2542d3de79d50e31e06cac181b2a1df3f87bc1f515', '06dbd26509079497c363b28060874d75d19c3797b83020f3c53f37faa755a61d')); end;
procedure Dependency_AddDotNet60Desktop; begin Dependency_AddDotNetRuntime('Microsoft.WindowsDesktop.App', 'dotnet60desktop', '.NET Desktop Runtime', 6, 0, 36, Dependency_String('https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/6.0.36/windowsdesktop-runtime-6.0.36-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/6.0.36/windowsdesktop-runtime-6.0.36-win-x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/6.0.36/windowsdesktop-runtime-6.0.36-win-arm64.exe'), Dependency_String('4e77bd970df0a06528ee88d33e4a8c9fb85beedbdd7219b017083acf0c3aa39e', '0d20debb26fc8b2bc84f25fbd9d4596a6364af8517ebf012e8b871127b798941', '8bb01362d7525a42cc4f27e1b863242d8136c3f491bdf00efca627658735a118')); end;
procedure Dependency_AddDotNet70; begin Dependency_AddDotNetRuntime('Microsoft.NETCore.App', 'dotnet70', '.NET Runtime', 7, 0, 20, Dependency_String('https://builds.dotnet.microsoft.com/dotnet/Runtime/7.0.20/dotnet-runtime-7.0.20-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/Runtime/7.0.20/dotnet-runtime-7.0.20-win-x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/Runtime/7.0.20/dotnet-runtime-7.0.20-win-arm64.exe'), Dependency_String('9bf79c94ab014b555167e61f3ce653fdf54c70bda6d6c74ab9f6f44652947a89', '10f48feee0f7fb4c2ed61ecef5e58699743afc9531f8a293680a99fc2d0a78a5', '04b97503bc1ca8b1fc0277e406a4875b003137b814ca20b5cb1778ccbc095cc6')); end;
procedure Dependency_AddDotNet70Asp; begin Dependency_AddDotNetRuntime('Microsoft.AspNetCore.App', 'dotnet70asp', 'ASP.NET Core Runtime', 7, 0, 20, Dependency_String('https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/7.0.20/aspnetcore-runtime-7.0.20-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/7.0.20/aspnetcore-runtime-7.0.20-win-x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/7.0.20/aspnetcore-runtime-7.0.20-win-x64.exe'), Dependency_String('c4fa407e4e8324edd900b6a39ab7964a45b77bd5a22d4cdba945f1a17c595ab8', 'ab9a6bfed06369dbe22328f54c69ce0660629ea6fc31bc554ed8b585edb16a67', 'ab9a6bfed06369dbe22328f54c69ce0660629ea6fc31bc554ed8b585edb16a67')); end;
procedure Dependency_AddDotNet70Desktop; begin Dependency_AddDotNetRuntime('Microsoft.WindowsDesktop.App', 'dotnet70desktop', '.NET Desktop Runtime', 7, 0, 20, Dependency_String('https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/7.0.20/windowsdesktop-runtime-7.0.20-win-x86.exe', 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/7.0.20/windowsdesktop-runtime-7.0.20-win-x64.exe', 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/7.0.20/windowsdesktop-runtime-7.0.20-win-arm64.exe'), Dependency_String('58d32d9857bda5da99afc217669aedacdffb20aed61f15315718eeb3a455b273', '57e7c16e7226c9a29dbc3faedd9e5876cec494c7660528052f52160521e7b714', '93df5c5d93d3dec06b49b555909a751122edbb3f121d52577578cb9b24ffe4f2')); end;
procedure Dependency_AddDotNet80; begin Dependency_AddDotNetRuntime('Microsoft.NETCore.App', 'dotnet80', '.NET Runtime', 8, 0, 32, Dependency_String('https://download.microsoft.com/download/5ab91d2a-50f7-4cc1-a769-534f6d3d45d9/5e410ceb-8e68-441d-aa2c-3e79200231ae/dotnet-runtime-8.0.32-win-x86.exe', 'https://download.microsoft.com/download/5ab91d2a-50f7-4cc1-a769-534f6d3d45d9/1943d4b5-db8e-465e-bd87-1c356f523e33/dotnet-runtime-8.0.32-win-x64.exe', 'https://download.microsoft.com/download/5ab91d2a-50f7-4cc1-a769-534f6d3d45d9/b91c00fe-3d3f-4cc3-b7e8-a3594f537609/dotnet-runtime-8.0.32-win-arm64.exe'), Dependency_String('37d724738809dc67150d47618f6b96e0d9c7b9e9361d776aacdbc5ea221e59c8', '4fbc22376fa60c8255946920fe0d1b93ee526b6956f8b9c9ce6743cf67e08b43', '9db96aac4db51823427ba0c97770fa3df88d963ce3c01f6ce4ee89295be2d99d')); end;
procedure Dependency_AddDotNet80Asp; begin Dependency_AddDotNetRuntime('Microsoft.AspNetCore.App', 'dotnet80asp', 'ASP.NET Core Runtime', 8, 0, 32, Dependency_String('https://download.microsoft.com/download/8eb9078a-5c3b-4f67-9d1d-96b5119b4e86/f9285162-e47e-4a34-aefa-018b9b9cb22f/aspnetcore-runtime-8.0.32-win-x86.exe', 'https://download.microsoft.com/download/8eb9078a-5c3b-4f67-9d1d-96b5119b4e86/2b0218c7-732f-4af3-a96b-1da7e3c77c3e/aspnetcore-runtime-8.0.32-win-x64.exe', 'https://download.microsoft.com/download/8eb9078a-5c3b-4f67-9d1d-96b5119b4e86/f9abeefe-510d-400a-aaa8-791ac8758126/aspnetcore-runtime-8.0.32-win-arm64.exe'), Dependency_String('2f70d5df0f018b133d04f56fa8dce3730e19efacb255c5e67e3fc8b000b75821', '72bd8f5598225c19280bee576ad2318090086ced5fd6c0cb9cf19408e9359ea6', 'e282128f4c23bb4d38aa2a67a5c16e915dd8d209f7e2e7ae377e99b4efbf35a9')); end;
procedure Dependency_AddDotNet80Desktop; begin Dependency_AddDotNetRuntime('Microsoft.WindowsDesktop.App', 'dotnet80desktop', '.NET Desktop Runtime', 8, 0, 32, Dependency_String('https://download.microsoft.com/download/0df67e77-450a-4e2f-be68-183677bb1091/4f71bf69-6ea3-4e56-bc72-96edaf240b61/windowsdesktop-runtime-8.0.32-win-x86.exe', 'https://download.microsoft.com/download/0df67e77-450a-4e2f-be68-183677bb1091/7e0f8cc8-bd11-462c-bd35-75b00dd2ce6e/windowsdesktop-runtime-8.0.32-win-x64.exe', 'https://download.microsoft.com/download/0df67e77-450a-4e2f-be68-183677bb1091/f57ab0cd-3892-440a-90bc-a150c077d7a2/windowsdesktop-runtime-8.0.32-win-arm64.exe'), Dependency_String('6402fc8054d310b7660357c82488948aa89b1d7049c106ead4e9a1d1707a8f33', '0f45815f9f032095910af092405c9c6d3844b7fe57252f854d65ed9379b45598', 'd2fffb301213ec3ac50820d566ba9d1849b4cc06ce007b8823d2f67f4cf4b1f5')); end;
procedure Dependency_AddDotNet90; begin Dependency_AddDotNetRuntime('Microsoft.NETCore.App', 'dotnet90', '.NET Runtime', 9, 0, 21, Dependency_String('https://download.microsoft.com/download/1a1ef5e5-9135-40b5-ad2d-e3539e3b2e4a/7e235487-fd54-4d9a-b6d2-5be6055a4b6a/dotnet-runtime-9.0.21-win-x86.exe', 'https://download.microsoft.com/download/1a1ef5e5-9135-40b5-ad2d-e3539e3b2e4a/8f924914-2d37-4c04-bf83-e69c899a3f74/dotnet-runtime-9.0.21-win-x64.exe', 'https://download.microsoft.com/download/1a1ef5e5-9135-40b5-ad2d-e3539e3b2e4a/4473c7b0-7b14-4fb3-b742-ab0ed22f506c/dotnet-runtime-9.0.21-win-arm64.exe'), Dependency_String('0948ddabd852501acbf1adc4eeee1b29d86a3f394da979d01607be737ea905a9', 'ede6cd47acdf42d95289d5a5d2fee42fb5abd7c69a0f97b74c791a3ce000c8e5', '63b6dfd2d7246c9f358432bec2e4cdef0d9ede34667a41172f7fb127ee1de9dd')); end;
procedure Dependency_AddDotNet90Asp; begin Dependency_AddDotNetRuntime('Microsoft.AspNetCore.App', 'dotnet90asp', 'ASP.NET Core Runtime', 9, 0, 21, Dependency_String('https://download.microsoft.com/download/ccfd83e9-3d55-4cce-913d-7849561aafda/c1d63ec4-c2ee-4280-8c25-548ee1748927/aspnetcore-runtime-9.0.21-win-x86.exe', 'https://download.microsoft.com/download/ccfd83e9-3d55-4cce-913d-7849561aafda/407958c9-c73a-4f03-a8ab-ca5978273118/aspnetcore-runtime-9.0.21-win-x64.exe', 'https://download.microsoft.com/download/ccfd83e9-3d55-4cce-913d-7849561aafda/02ef0808-675e-4d63-b0cc-e2211e6126a5/aspnetcore-runtime-9.0.21-win-arm64.exe'), Dependency_String('cb330f3abebf8e04dcac49ad2f5beff0be082ccaeaa273e271135fd80df4889b', 'abb4c05c976b6d5828e9301a5a9bd3961158eb4635e4d716b19a5d01d7d9a157', 'a92f3fd17fb21f1de91f8936b5627f8689675c0c7559b82b1a5d4f2960d6458c')); end;
procedure Dependency_AddDotNet90Desktop; begin Dependency_AddDotNetRuntime('Microsoft.WindowsDesktop.App', 'dotnet90desktop', '.NET Desktop Runtime', 9, 0, 21, Dependency_String('https://download.microsoft.com/download/a215e6a7-bb18-4d7a-8b72-c06fa5a94985/8c189493-08a2-4cb6-96e8-58eb2478ea3e/windowsdesktop-runtime-9.0.21-win-x86.exe', 'https://download.microsoft.com/download/a215e6a7-bb18-4d7a-8b72-c06fa5a94985/bc9a2df8-c4c9-4ffb-870b-bf83a00596b0/windowsdesktop-runtime-9.0.21-win-x64.exe', 'https://download.microsoft.com/download/a215e6a7-bb18-4d7a-8b72-c06fa5a94985/df2522a3-2a81-425a-8c25-5dca71ddf5ab/windowsdesktop-runtime-9.0.21-win-arm64.exe'), Dependency_String('ce85c2feeb765de38b2bf921742ca150dc022f988120c53229ba1ebcc10a56f5', '3e84553cab2edbcb2d5b907d302b1f38d265994522057be65eb9b0361cc19d56', 'ed63b8cb723f1b0d872b31fc318aa2cc89ee9797e8772c28c2990bcdda849389')); end;
procedure Dependency_AddDotNet100; begin Dependency_AddDotNetRuntime('Microsoft.NETCore.App', 'dotnet100', '.NET Runtime', 10, 0, 13, Dependency_String('https://download.microsoft.com/download/d264d1e0-b40b-4519-8bc6-ffadfcd9cec5/6c16227d-baf9-4d62-9edf-c394edaaf230/dotnet-runtime-10.0.13-win-x86.exe', 'https://download.microsoft.com/download/d264d1e0-b40b-4519-8bc6-ffadfcd9cec5/4c73de89-4de7-4aa5-8707-c5401c7ead4c/dotnet-runtime-10.0.13-win-x64.exe', 'https://download.microsoft.com/download/d264d1e0-b40b-4519-8bc6-ffadfcd9cec5/bde2f67a-4c27-4d78-bf98-42d36c306dbe/dotnet-runtime-10.0.13-win-arm64.exe'), Dependency_String('063e57e5fc4e56bc18b4e4be316aa5e7f0c5e2c96f2355e34fcc8af3464d8959', '15c6e0af2bfdead22d2a44c5ffae579ddf45ca465c38722a0490e77221fdb81d', '386c351052f816cdb0707fb95d03c5bebc946e754696839d72e46e4e7b434bbc')); end;
procedure Dependency_AddDotNet100Asp; begin Dependency_AddDotNetRuntime('Microsoft.AspNetCore.App', 'dotnet100asp', 'ASP.NET Core Runtime', 10, 0, 13, Dependency_String('https://download.microsoft.com/download/128b6fc0-0c19-4052-834e-46c3e9b30523/ac8ec834-be3d-4a88-a1e2-c1594a3f85a3/aspnetcore-runtime-10.0.13-win-x86.exe', 'https://download.microsoft.com/download/128b6fc0-0c19-4052-834e-46c3e9b30523/4266b8e4-0851-4fd4-83df-409374afe356/aspnetcore-runtime-10.0.13-win-x64.exe', 'https://download.microsoft.com/download/128b6fc0-0c19-4052-834e-46c3e9b30523/6aed0900-e3dd-4006-8439-7b73b0a4c594/aspnetcore-runtime-10.0.13-win-arm64.exe'), Dependency_String('61361b260e378765c5877bb8dc22eb8735e0d91ec562c85407b3e944b011d2f3', '1c349d16bebabe5a77f1b7d116f87502518a35b6f1d9541829889ca468830ffc', 'c943688e21302a28b8dbe317258698b69125456936b191b86b18d0b259aab1a2')); end;
procedure Dependency_AddDotNet100Desktop; begin Dependency_AddDotNetRuntime('Microsoft.WindowsDesktop.App', 'dotnet100desktop', '.NET Desktop Runtime', 10, 0, 13, Dependency_String('https://download.microsoft.com/download/482a626a-5c5f-417a-aeda-190e094e669c/f66055da-be73-4605-932f-cae3601d0f5b/windowsdesktop-runtime-10.0.13-win-x86.exe', 'https://download.microsoft.com/download/482a626a-5c5f-417a-aeda-190e094e669c/655563a9-1dbf-49b8-b72e-c6a0587c1dd7/windowsdesktop-runtime-10.0.13-win-x64.exe', 'https://download.microsoft.com/download/482a626a-5c5f-417a-aeda-190e094e669c/834989c0-0a69-470b-9d3b-572a17389d4a/windowsdesktop-runtime-10.0.13-win-arm64.exe'), Dependency_String('f241cf11d6c0151a0b0eee3f02da4d6a6ef9e21e7d54349056e2d65e6ffb0d73', 'f5f0268b3d89ec3b9eb952b620330360b35c63593ead45816aeb26e934a4b7b6', '68d651af6e5f184d121b84201df93638ed19e71628b50ae0a4f076131d6013be')); end;

procedure Dependency_AddDotNetHosting(const Major, Patch: Integer; const URL, Checksum: String);
begin
  // https://dotnet.microsoft.com/download/dotnet
  Dependency_AddIfMissing(not Dependency_IsNetCoreInstalled('Microsoft.AspNetCore.App', Major, 0, Patch) or not FileExists(ExpandConstant(Dependency_StringX64('{commonpf32}', '{commonpf64}')) + '\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'),
    'dotnet' + IntToStr(Major) + '0hosting.exe',
    '/lcid ' + IntToStr(GetUILanguage) + ' ' + Dependency_PassiveOrQuiet('/passive', '/quiet') + ' /norestart',
    'ASP.NET Core ' + IntToStr(Major) + '.0 Hosting Bundle',
    URL,
    Checksum,
    False, False);
end;

procedure Dependency_AddDotNet80Hosting; begin Dependency_AddDotNetHosting(8, 32, 'https://download.microsoft.com/download/cea3cccf-458f-4807-8e34-d4b1008f5bcf/8b6dc239-1fe4-479f-ada9-1e1e735112aa/dotnet-hosting-8.0.32-win.exe', '3dfd552d4c1f776ee4e971b8794ac09e2fd39a493399fc5ab777f14745f863dc'); end;
procedure Dependency_AddDotNet90Hosting; begin Dependency_AddDotNetHosting(9, 21, 'https://download.microsoft.com/download/1d87ef22-2f37-4191-af91-d2b8aaa50ed8/911e7a1c-5925-441f-a4d3-a98bbf487d39/dotnet-hosting-9.0.21-win.exe', '5a246e17fa090bb16883f21c43eecc5f4d18ac049f5611da86cc79e4246e8edb'); end;
procedure Dependency_AddDotNet100Hosting; begin Dependency_AddDotNetHosting(10, 13, 'https://download.microsoft.com/download/1fd4444a-d31d-4479-8781-ad2c5a66f9d4/842ff5c2-d2e7-41b1-afcd-6dbb11c6bfb3/dotnet-hosting-10.0.13-win.exe', '6cd3b2e13583bcd46be09f932159a4c2c840d685d451e33e7000f6337cde6c06'); end;

procedure Dependency_AddVCMsi(const Year, Title, UpgradeCode: String; Major, Minor, Build, Revision: Word; const Parameters, URL, Checksum: String);
begin
  Dependency_AddIfMissing(not Dependency_IsMsiProductInstalled(UpgradeCode, PackVersionComponents(Major, Minor, Build, Revision)), 'vcredist' + Year + Dependency_ArchSuffix + '.exe', Parameters, Title + Dependency_ArchTitle, URL, Checksum, False, False);
end;

procedure Dependency_AddVC2005; begin Dependency_AddVCMsi('2005', 'Visual C++ 2005 Service Pack 1 Redistributable', Dependency_StringX64('{86C9D5AA-F00C-4921-B3F2-C60AF92E2844}', '{A8D19029-8E5C-4E22-8011-48070F9E796E}'), 8, 0, 61000, 0, '/q', Dependency_StringX64('https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE', 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE'), Dependency_StringX64('8648c5fc29c44b9112fe52f9a33f80e7fc42d10f3b5b42b2121542a13e44adfd', '4487570bd86e2e1aac29db2a1d0a91eb63361fcaac570808eb327cd4e0e2240d')); end;
procedure Dependency_AddVC2008; begin Dependency_AddVCMsi('2008', 'Visual C++ 2008 Service Pack 1 Redistributable', Dependency_StringX64('{DE2C306F-A067-38EF-B86C-03DE4B0312F9}', '{FDA45DDF-8E17-336F-A3ED-356B7B7C688A}'), 9, 0, 30729, 6161, '/q', Dependency_StringX64('https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe', 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe'), Dependency_StringX64('8742bcbf24ef328a72d2a27b693cc7071e38d3bb4b9b44dec42aa3d2c8d61d92', 'c5e273a4a16ab4d5471e91c7477719a2f45ddadb76c7f98a38fa5074a6838654')); end;
procedure Dependency_AddVC2010; begin Dependency_AddVCMsi('2010', 'Visual C++ 2010 Service Pack 1 Redistributable', Dependency_StringX64('{1F4F1D2A-D9DA-32CF-9909-48485DA06DD5}', '{5B75F761-BAC8-33BC-A381-464DDDD813A3}'), 10, 0, 40219, 0, Dependency_PassiveOrQuiet('/passive', '/q') + ' /norestart', Dependency_StringX64('https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe', 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'), Dependency_StringX64('99dce3c841cc6028560830f7866c9ce2928c98cf3256892ef8e6cf755147b0d8', 'f3b7a76d84d23f91957aa18456a14b4e90609e4ce8194c5653384ed38dada6f3')); end;
procedure Dependency_AddVC2012; begin Dependency_AddVCMsi('2012', 'Visual C++ 2012 Update 4 Redistributable', Dependency_StringX64('{4121ED58-4BD9-3E7B-A8B5-9F8BAAE045B7}', '{EFA6AFA1-738E-3E00-8101-FD03B86B29D1}'), 11, 0, 61030, 0, Dependency_PassiveOrQuiet('/passive', '/quiet') + ' /norestart', Dependency_StringX64('https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe', 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'), Dependency_StringX64('b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386', '681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064')); end;
procedure Dependency_AddVC2013; begin Dependency_AddVCMsi('2013', 'Visual C++ 2013 Update 5 Redistributable', Dependency_StringX64('{B59F5BF1-67C8-3802-8E59-2CE551A39FC5}', '{20400CF0-DE7C-327E-9AE4-F0F38D9085F8}'), 12, 0, 40664, 0, Dependency_PassiveOrQuiet('/passive', '/quiet') + ' /norestart', Dependency_StringX64('https://download.visualstudio.microsoft.com/download/pr/10912113/5da66ddebb0ad32ebd4b922fd82e8e25/vcredist_x86.exe', 'https://download.visualstudio.microsoft.com/download/pr/10912041/cee5d6bca2ddbcd039da727bf4acb48a/vcredist_x64.exe'), Dependency_StringX64('53b605d1100ab0a88b867447bbf9274b5938125024ba01f5105a9e178a3dcdbd', 'a4bba7701e355ae29c403431f871a537897c363e215cafe706615e270984f17c')); end;

procedure Dependency_AddVC14;
var
  Version: String;
  PackedVersion: Int64;
begin
  // https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist
  if RegQueryStringValue(Dependency_ArchHKLM, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\' + Dependency_String('x86', 'x64', 'arm64'), 'Version', Version) and (Copy(Version, 1, 1) = 'v') then begin
    Delete(Version, 1, 1);
  end;
  Dependency_AddIfMissing(not StrToVersion(Version, PackedVersion) or (ComparePackedVersion(PackedVersion, PackVersionComponents(14, 51, 36247, 0)) < 0),
    'vcredist14' + Dependency_ArchSuffix + '.exe',
    Dependency_PassiveOrQuiet('/passive', '/quiet') + ' /norestart',
    'Visual C++ v14 Redistributable' + Dependency_ArchTitle,
    Dependency_String('https://download.visualstudio.microsoft.com/download/pr/ddfd326a-05c1-4646-9cf7-9fbc5206a9e8/F0BAB33A302B3CDB2E11113760D016F54FD3D2632C65BA7834FAC4F0ABD7F1A3/VC_redist.x86.exe', 'https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe', 'https://download.visualstudio.microsoft.com/download/pr/ddfd326a-05c1-4646-9cf7-9fbc5206a9e8/B70EF586669A620A0A30A1156969C05C6A3831DC8F8BC992DA75779D2A92F944/VC_redist.arm64.exe'),
    Dependency_String('f0bab33a302b3cdb2e11113760d016f54fd3d2632c65ba7834fac4f0abd7f1a3', '843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c', 'b70ef586669a620a0a30a1156969c05c6a3831dc8f8bc992da75779d2a92f944'),
    False, False);
end;

procedure Dependency_AddVC2015To2019; begin Dependency_AddVC14; end;
procedure Dependency_AddVC2015To2022; begin Dependency_AddVC14; end;

procedure Dependency_AddDirectX;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/DirectX/9.29.1974.0
  Dependency_Add('dxwebsetup.exe',
    '/q',
    'DirectX Runtime',
    'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe',
    '2cf71d098c608c56e07f4655855a886c3102553f648df88458df616b26fd612f',
    True, False);
end;

procedure Dependency_AddSqlExpress(const Year, Instance, Title: String; Major, Minor, Build, Revision: Word; const URL, Checksum: String);
var
  Version: String;
  PackedVersion: Int64;
begin
  Dependency_AddIfMissing(not RegQueryStringValue(Dependency_ArchHKLM, 'SOFTWARE\Microsoft\Microsoft SQL Server\' + Instance + '\MSSQLServer\CurrentVersion', 'CurrentVersion', Version) or not StrToVersion(Version, PackedVersion) or (ComparePackedVersion(PackedVersion, PackVersionComponents(Major, Minor, Build, Revision)) < 0), 'sql' + Year + 'express' + Dependency_ArchSuffix + '.exe', Dependency_PassiveOrQuiet('/QS', '/Q') + ' /IACCEPTSQLSERVERLICENSETERMS /ACTION=INSTALL /FEATURES=SQL /INSTANCENAME=MSSQLSERVER', Title, URL, Checksum, False, False);
end;

procedure Dependency_AddSql2008Express; begin Dependency_AddSqlExpress('2008', 'MSSQL10_50.MSSQLSERVER', 'SQL Server 2008 R2 Service Pack 2 Express', 10, 50, 4000, 0, Dependency_StringX64('https://download.microsoft.com/download/0/4/B/04BE03CD-EAF3-4797-9D8D-2E08E316C998/SQLEXPR32_x86_ENU.exe', 'https://download.microsoft.com/download/0/4/B/04BE03CD-EAF3-4797-9D8D-2E08E316C998/SQLEXPR_x64_ENU.exe'), Dependency_StringX64('8096bea8ed1559cb39a2b42c0c680d1251e8ddbab6d09be1e0a4263623183086', '4372dec5a5f4b2e48c60da7b09b5368214fddbc8cd0c4a0be5af2d74522b67f8')); end;
procedure Dependency_AddSql2012Express; begin Dependency_AddSqlExpress('2012', 'MSSQL11.MSSQLSERVER', 'SQL Server 2012 Service Pack 4 Express', 11, 0, 7001, 0, Dependency_StringX64('https://download.microsoft.com/download/B/D/E/BDE8FAD6-33E5-44F6-B714-348F73E602B6/SQLEXPR32_x86_ENU.exe', 'https://download.microsoft.com/download/B/D/E/BDE8FAD6-33E5-44F6-B714-348F73E602B6/SQLEXPR_x64_ENU.exe'), Dependency_StringX64('c380d4f4aa61a150885dda6f39ce135c0960c5ce4f04d5c96a5357e9417bc474', 'bae6000b3ecef827fb4371a7aaccf0278de8cb84da1a510d56e3588b20230582')); end;
procedure Dependency_AddSql2014Express; begin Dependency_AddSqlExpress('2014', 'MSSQL12.MSSQLSERVER', 'SQL Server 2014 Service Pack 3 Express', 12, 0, 6024, 0, Dependency_StringX64('https://download.microsoft.com/download/3/9/F/39F968FA-DEBB-4960-8F9E-0E7BB3035959/SQLEXPR32_x86_ENU.exe', 'https://download.microsoft.com/download/3/9/F/39F968FA-DEBB-4960-8F9E-0E7BB3035959/SQLEXPR_x64_ENU.exe'), Dependency_StringX64('5771644bc02221268c5e14fdea7068c6311e8bff4182b2d359b4d8d4b22bec3d', 'e8d8330e3e7d6f9242e658315b99aace4aabb71ed14f3ec465e4450d66d255b6')); end;
procedure Dependency_AddSql2016Express; begin Dependency_AddSqlExpress('2016', 'MSSQL13.MSSQLSERVER', 'SQL Server 2016 Service Pack 3 Express', 13, 0, 6404, 1, Dependency_StringX64('https://download.microsoft.com/download/f/a/8/fa83d147-63d1-449c-b22d-5fef9bd5bb46/SQLServer2016-SSEI-Expr.exe', 'https://download.microsoft.com/download/f/a/8/fa83d147-63d1-449c-b22d-5fef9bd5bb46/SQLServer2016-SSEI-Expr.exe'), Dependency_StringX64('25692917049a856b9ccea2c1242f42a1a585d3ad94f1f449e93be183f17c397a', '25692917049a856b9ccea2c1242f42a1a585d3ad94f1f449e93be183f17c397a')); end;
procedure Dependency_AddSql2017Express; begin Dependency_AddSqlExpress('2017', 'MSSQL14.MSSQLSERVER', 'SQL Server 2017 Express', 14, 0, 1000, 169, Dependency_StringX64('https://download.microsoft.com/download/5/E/9/5E9B18CC-8FD5-467E-B5BF-BADE39C51F73/SQLServer2017-SSEI-Expr.exe', 'https://download.microsoft.com/download/5/E/9/5E9B18CC-8FD5-467E-B5BF-BADE39C51F73/SQLServer2017-SSEI-Expr.exe'), Dependency_StringX64('d8a5cd8f4380be195af82d0ddc21316713ab2b41ff6c48d86f87c5778de18411', 'd8a5cd8f4380be195af82d0ddc21316713ab2b41ff6c48d86f87c5778de18411')); end;
procedure Dependency_AddSql2019Express; begin Dependency_AddSqlExpress('2019', 'MSSQL15.MSSQLSERVER', 'SQL Server 2019 Express', 15, 2204, 5490, 2, Dependency_StringX64('https://download.microsoft.com/download/7/f/8/7f8a9c43-8c8a-4f7c-9f92-83c18d96b681/SQL2019-SSEI-Expr.exe', 'https://download.microsoft.com/download/7/f/8/7f8a9c43-8c8a-4f7c-9f92-83c18d96b681/SQL2019-SSEI-Expr.exe'), Dependency_StringX64('1333bac5283998a18f761816f0fd09028e50e89d7085f39338b57a01549e5015', '1333bac5283998a18f761816f0fd09028e50e89d7085f39338b57a01549e5015')); end;
procedure Dependency_AddSql2022Express; begin Dependency_AddSqlExpress('2022', 'MSSQL16.MSSQLSERVER', 'SQL Server 2022 Express', 16, 0, 1000, 6, Dependency_StringX64('https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe', 'https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe'), Dependency_StringX64('36e0ec2ac3dd60f496c99ce44722c629209ea7302a2ce9cbfd1e42a73510d7b6', '36e0ec2ac3dd60f496c99ce44722c629209ea7302a2ce9cbfd1e42a73510d7b6')); end;
procedure Dependency_AddSql2025Express; begin Dependency_AddSqlExpress('2025', 'MSSQL17.MSSQLSERVER', 'SQL Server 2025 Express', 17, 0, 1000, 7, Dependency_StringX64('https://download.microsoft.com/download/7ab8f535-7eb8-4b16-82eb-eca0fa2d38f3/SQL2025-SSEI-Expr.exe', 'https://download.microsoft.com/download/7ab8f535-7eb8-4b16-82eb-eca0fa2d38f3/SQL2025-SSEI-Expr.exe'), Dependency_StringX64('1c677a33b318481c3217128835f8405cf0026621dcd04b13eb6cb0982e823f27', '1c677a33b318481c3217128835f8405cf0026621dcd04b13eb6cb0982e823f27')); end;

procedure Dependency_AddSqlOleDb19;
begin
  // https://learn.microsoft.com/en-us/sql/connect/oledb/download-oledb-driver-for-sql-server
  Dependency_AddIfMissing(not RegValueExists(Dependency_ArchHKLM, 'SOFTWARE\Microsoft\MSOLEDBSQL19', 'InstalledVersion'),
    'msoledbsql' + Dependency_ArchSuffix + '.msi',
    '/qn /norestart IACCEPTMSOLEDBSQLLICENSETERMS=YES',
    'Microsoft OLE DB Driver 19 for SQL Server' + Dependency_ArchTitle,
    Dependency_StringX64('https://download.microsoft.com/download/0a09a9e0-e364-4d01-b102-04ddfcf38a7e/x86/1033/msoledbsql.msi', 'https://download.microsoft.com/download/7bf55274-18ac-4b26-9783-45453a1ab64f/amd64/1033/msoledbsql.msi'),
    Dependency_StringX64('b86f1ee532e6ea543721747eb03b32e5eff6c292458de3d90391b97908c8e13c', '409adfd93165dd3622b2d7cd0b9c4d96a27b04f9f3fb5599d99acbe90ade0638'),
    False, False);
end;

procedure Dependency_AddSqlOdbc18;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/msodbcsql/18/18.7.1.1
  Dependency_AddIfMissing(not RegKeyExists(Dependency_ArchHKLM, 'SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server'),
    'msodbcsql' + Dependency_ArchSuffix + '.msi',
    '/qn /norestart IACCEPTMSODBCSQLLICENSETERMS=YES',
    'Microsoft ODBC Driver 18 for SQL Server' + Dependency_ArchTitle,
    Dependency_String('https://download.microsoft.com/download/ca8ce451-a4b4-42c0-ba73-f66642c4bfae/x86/1033/msodbcsql.msi', 'https://download.microsoft.com/download/d624e1c6-293b-4d6f-91b8-6e515a5d6a77/amd64/1033/msodbcsql.msi', 'https://download.microsoft.com/download/92f6c111-1489-4538-8d7e-b35218b0675b/arm64/1033/msodbcsql.msi'),
    Dependency_String('b2cc946db432ac6d84064b8c55024e7157495a5d1f14f7402b291c2efb567ced', '21ef69e4b942f18aced55fa7c3a8d7263004e113a96690bac7509645e1b1a310', 'fc61b5a9c52b4bb62e0c735f275e7579ede0a62e0e4b60811ef4a63ea55ac52b'),
    False, False);
end;

procedure Dependency_AddWebView2;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/EdgeWebView2Runtime/155.0.4283.62
  Dependency_AddIfMissing(not (RegValueExists(HKLM32, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv')
    or RegValueExists(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv')),
    'MicrosoftEdgeWebView2RuntimeInstaller' + Dependency_ArchSuffix + '.exe',
    '/silent /install',
    'WebView2 Runtime',
    Dependency_String('https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/f9392307-9373-4315-9425-2d1577ac9f02/MicrosoftEdgeWebView2RuntimeInstallerX86.exe', 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/35871e19-d11b-432d-9d1e-7be0ff286540/MicrosoftEdgeWebView2RuntimeInstallerX64.exe', 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/a8eefc09-1989-4d69-b834-689bb46de37d/MicrosoftEdgeWebView2RuntimeInstallerARM64.exe'),
    Dependency_String('f86d167ab894dc3b7582d91ac57a350178cae0af589220a236518f267969de71', '0625fb5c1e75be58a164e14f95aa58a3e5badb859b3d17c952385f3e4a9ff3e8', '216324c5433da0e82f83c379a171c847eca53f655053d5699e5fef6f5b951d8d'),
    False, False);
end;

procedure Dependency_AddAccessDatabaseEngine2016;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/AccessDatabaseEngine2016/16.0.5044.1000
  Dependency_AddIfMissing(not RegKeyExists(Dependency_ArchHKLM, 'SOFTWARE\Microsoft\Office\16.0\Access Connectivity Engine\Engines\ACE'),
    'AccessDatabaseEngine2016' + Dependency_ArchSuffix + '.exe',
    '/quiet',
    'Microsoft Access Database Engine 2016' + Dependency_ArchTitle,
    Dependency_StringX64('https://download.microsoft.com/download/3/5/C/35C84C36-661A-44E6-9324-8786B8DBE231/accessdatabaseengine.exe', 'https://download.microsoft.com/download/3/5/C/35C84C36-661A-44E6-9324-8786B8DBE231/accessdatabaseengine_X64.exe'),
    Dependency_StringX64('adc0504656f390d225530ac09f1fc2113295c4f9baeffea1e983fecf4ac960f0', '04e96c9f1a1f7d251a88aececf1dc10ff65950392787427c00814a43308003de'),
    False, False);
end;

procedure Dependency_AddVSTORuntime;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/VSTOR/10.0.60917
  Dependency_AddIfMissing(not RegKeyExists(HKLM32, 'SOFTWARE\Microsoft\VSTO Runtime Setup\v4R'),
    'vstor_redist.exe',
    '/q /norestart',
    'Visual Studio 2010 Tools for Office Runtime',
    'https://download.microsoft.com/download/5/d/2/5d24f8f8-efbb-4b63-aa33-3785e3104713/vstor_redist.exe',
    'cfe1a40bbe4a50022db2164abdb0154984e2cecb761a23cdc81cb5754f6e0a18',
    False, False);
end;

var
  Dependency_WinAppRuntimePackages: TArrayOfString;
  Dependency_WinAppRuntimePackagesListed: Boolean;

function Dependency_HasWinAppRuntimePackage(const PackageName, Architecture: String; const PrefixMatch: Boolean): Boolean;
var
  LineIndex: Integer;
  PackageFields: TArrayOfString;
begin
  for LineIndex := 0 to Length(Dependency_WinAppRuntimePackages) - 1 do begin
    PackageFields := StringSplit(Trim(Dependency_WinAppRuntimePackages[LineIndex]), ['|'], stExcludeEmpty);
    if (Length(PackageFields) = 2)
      and ((not PrefixMatch and SameText(PackageFields[0], PackageName))
        or (PrefixMatch and SameText(Copy(PackageFields[0], 1, Length(PackageName)), PackageName)))
      and SameText(PackageFields[1], Architecture) then begin
      Result := True;
      exit;
    end;
  end;
  Result := False;
end;

// a usable runtime needs all four package types registered for the current user
function Dependency_IsWinAppRuntimeInstalled(const Channel: String): Boolean;
var
  PackageArchitecture, SystemArchitecture: String;
  ResultCode: Integer;
  Output: TExecOutput;
begin
  if not Dependency_WinAppRuntimePackagesListed then begin
    Dependency_WinAppRuntimePackagesListed := True;
    if ExecAndCaptureOutput(GetSysNativeDir + '\WindowsPowerShell\v1.0\powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -Command "$pattern = ''^(Microsoft\.WindowsAppRuntime\.|MicrosoftCorporationII\.WinAppRuntime\.|Microsoft\.WinAppRuntime\.DDLM\.)''; Get-AppxPackage | Where-Object { $_.Name -match $pattern } | ForEach-Object { ''{0}|{1}'' -f $_.Name, $_.Architecture }"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode, Output) and (ResultCode = 0) then begin
      Dependency_WinAppRuntimePackages := Output.StdOut;
    end;
  end;

  PackageArchitecture := Dependency_String('X86', 'X64', 'Arm64');
  if IsArm64 then begin
    SystemArchitecture := 'Arm64';
  end else if IsX64Compatible then begin
    SystemArchitecture := 'X64';
  end else begin
    SystemArchitecture := 'X86';
  end;

  Result :=
    Dependency_HasWinAppRuntimePackage('Microsoft.WindowsAppRuntime.' + Channel, PackageArchitecture, False)
    and Dependency_HasWinAppRuntimePackage('MicrosoftCorporationII.WinAppRuntime.Main.' + Channel, SystemArchitecture, False)
    and Dependency_HasWinAppRuntimePackage('MicrosoftCorporationII.WinAppRuntime.Singleton', SystemArchitecture, False)
    and Dependency_HasWinAppRuntimePackage('Microsoft.WinAppRuntime.DDLM.', PackageArchitecture, True);
end;

procedure Dependency_AddWinAppRuntime16;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/WindowsAppRuntime/1/6/1.6.9
  Dependency_AddIfMissing(not Dependency_IsWinAppRuntimeInstalled('1.6'),
    'windowsappruntime16' + Dependency_ArchSuffix + '.exe',
    '--quiet',
    'Windows App Runtime 1.6' + Dependency_ArchTitle,
    Dependency_String('https://aka.ms/windowsappsdk/1.6/1.6.250602001/windowsappruntimeinstall-x86.exe', 'https://aka.ms/windowsappsdk/1.6/1.6.250602001/windowsappruntimeinstall-x64.exe', 'https://aka.ms/windowsappsdk/1.6/1.6.250602001/windowsappruntimeinstall-arm64.exe'),
    Dependency_String('6219474e62cdc52509df78c31943e61cb896e10517602dd7d55b9b8a9a0b79c7', 'c7cd988425b76ea087e2e1d7b096b585f853e20bb826b8f38d45a5175410a877', '69b8ab5fcff480cc8324c36f9e38140907a6aaa02a4065716c7a2ba74ff177ae'),
    False, False);
end;

procedure Dependency_AddWinAppRuntime17;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/WindowsAppRuntime/1/7/1.7.9
  Dependency_AddIfMissing(not Dependency_IsWinAppRuntimeInstalled('1.7'),
    'windowsappruntime17' + Dependency_ArchSuffix + '.exe',
    '--quiet',
    'Windows App Runtime 1.7' + Dependency_ArchTitle,
    Dependency_String('https://aka.ms/windowsappsdk/1.7/1.7.260224002/windowsappruntimeinstall-x86.exe', 'https://aka.ms/windowsappsdk/1.7/1.7.260224002/windowsappruntimeinstall-x64.exe', 'https://aka.ms/windowsappsdk/1.7/1.7.260224002/windowsappruntimeinstall-arm64.exe'),
    Dependency_String('470b6fe2db339b90b845c90c3368f39b38b15e1a4d3dc7aebea5fa12f1483169', '8de73b13a010c6aeb84040e5587a46d21b36decce0ccd582c346536cad63ae73', '993f54077e747d3f9026745ec860cbe57ec545bcc9054c76746a3acbe99bf8ab'),
    False, False);
end;

procedure Dependency_AddWinAppRuntime18;
begin
  // https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/WindowsAppRuntime/1/8/1.8.10
  Dependency_AddIfMissing(not Dependency_IsWinAppRuntimeInstalled('1.8'),
    'windowsappruntime18' + Dependency_ArchSuffix + '.exe',
    '--quiet',
    'Windows App Runtime 1.8' + Dependency_ArchTitle,
    Dependency_String('https://aka.ms/windowsappsdk/1.8/1.8.260710003/windowsappruntimeinstall-x86.exe', 'https://aka.ms/windowsappsdk/1.8/1.8.260710003/windowsappruntimeinstall-x64.exe', 'https://aka.ms/windowsappsdk/1.8/1.8.260710003/windowsappruntimeinstall-arm64.exe'),
    Dependency_String('1d478178455f1da703d5f100489507c8e2853bfb6157635dcebb8d2de5acc8ab', 'b8cda840267ab72797f654f801f9a064ab6d9e508cedee3df79f772f104db6d6', '4c019a3f903dbd3b0cbb02201f852c3142d4c22415d7ef8c74cce76fef789657'),
    False, False);
end;

procedure Dependency_AddWinAppRuntime2;
begin
  // https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads
  Dependency_AddIfMissing(not Dependency_IsWinAppRuntimeInstalled('2'),
    'windowsappruntime2' + Dependency_ArchSuffix + '.exe',
    '--quiet',
    'Windows App Runtime 2' + Dependency_ArchTitle,
    Dependency_String('https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x86.exe', 'https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x64.exe', 'https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-arm64.exe'),
    Dependency_String('76dbd7c272cee0bf18f0b7228255b353d669cd55dc530209c45646f47acb89d4', '931a421e8dc3e6e67724806cb67fecdbb88dfe323f0170842eb4a4b4b149f1e2', 'd5e4d34547eb4e31c64bf1532415b3019c0d92b750e72eb18d3d95bd00feacbb'),
    False, False);
end;

var
  Dependency_JavaMajor: Integer;
  Dependency_JavaMajorDetected: Boolean;

function Dependency_GetJavaMajor: Integer;
var
  JavaExe, Line: String;
  ResultCode, LineIndex, QuotePos: Integer;
  Output: TExecOutput;
  Parts: TArrayOfString;
begin
  if not Dependency_JavaMajorDetected then begin
    Dependency_JavaMajorDetected := True;
    Dependency_JavaMajor := 0;

    // detect whichever java.exe an app would actually use: JAVA_HOME, else PATH
    JavaExe := RemoveQuotes(GetEnv('JAVA_HOME'));
    if (JavaExe <> '') and PathIsRooted(JavaExe) and FileExists(AddBackslash(JavaExe) + 'bin\java.exe') then begin
      JavaExe := AddBackslash(JavaExe) + 'bin\java.exe';
    end else begin
      JavaExe := FileSearch('java.exe', GetEnv('PATH'));
    end;

    // `java -version` prints to stderr
    if (JavaExe <> '') and ExecAndCaptureOutput(JavaExe, '-version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode, Output) and (ResultCode = 0) then begin
      for LineIndex := 0 to Length(Output.StdErr) - 1 do begin
        Line := Output.StdErr[LineIndex];
        QuotePos := Pos('version "', Line);
        if QuotePos > 0 then begin
          Parts := StringSplit(Copy(Line, QuotePos + 9, Length(Line)), ['.'], stExcludeEmpty);
          if Length(Parts) > 0 then begin
            Dependency_JavaMajor := StrToIntDef(Parts[0], 0);
            if (Dependency_JavaMajor = 1) and (Length(Parts) > 1) then begin
              Dependency_JavaMajor := StrToIntDef(Parts[1], 0); // legacy "1.8.0_x" -> 8
            end;
          end;
          break;
        end;
      end;
    end;
  end;

  Result := Dependency_JavaMajor;
end;

procedure Dependency_AddJava(const Major: Integer; const URL, Checksum: String);
begin
  // https://learn.microsoft.com/en-us/java/openjdk/download
  if URL = '' then begin
    Log('Dependency not available for this architecture: OpenJDK ' + IntToStr(Major) + Dependency_ArchTitle);
    exit;
  end;

  Dependency_AddIfMissing(Dependency_GetJavaMajor < Major,
    'openjdk-' + IntToStr(Major) + Dependency_ArchSuffix + '.msi',
    '/quiet /norestart ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome',
    'OpenJDK ' + IntToStr(Major) + Dependency_ArchTitle,
    URL,
    Checksum,
    False, False);
end;

// Java 8 has no Microsoft build (and is still shipped 32-bit), so it comes from Eclipse Temurin
procedure Dependency_AddJava8; begin Dependency_AddJava(8, Dependency_StringX64('https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u472-b08/OpenJDK8U-jdk_x86-32_windows_hotspot_8u472b08.msi', 'https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u492-b09/OpenJDK8U-jdk_x64_windows_hotspot_8u492b09.msi'), Dependency_StringX64('daff0b3a7892ec99635f54554070ede99c175c157f683bc99c6d9008e81dfe4f', 'e931546f0557e0735472e99c5f0a62d34854ab8a2fee9709bfcbc7ea6dcc5172')); end;
procedure Dependency_AddJava11; begin Dependency_AddJava(11, Dependency_String('', 'https://aka.ms/download-jdk/microsoft-jdk-11.0.32-windows-x64.msi', 'https://aka.ms/download-jdk/microsoft-jdk-11.0.32-windows-aarch64.msi'), Dependency_String('', 'e3e83188a65a7a27c1055e9cf522cb74f66517934dc04289d57cc4e9d8ab3564', 'b8788d0ea84fc413bc1c60a2b79f725131f42a2d3e501d413c7988a59212f097')); end;
procedure Dependency_AddJava17; begin Dependency_AddJava(17, Dependency_String('', 'https://aka.ms/download-jdk/microsoft-jdk-17.0.20-windows-x64.msi', 'https://aka.ms/download-jdk/microsoft-jdk-17.0.20-windows-aarch64.msi'), Dependency_String('', '96115e7ba251f476544e38f4b214562b57b609618d64533dff1104bb74d328fc', '9234135a0c03ad05f3c14c20ad1fc9e54fe99b5791e8be281d35fac422d30f2e')); end;
procedure Dependency_AddJava21; begin Dependency_AddJava(21, Dependency_String('', 'https://aka.ms/download-jdk/microsoft-jdk-21.0.12-windows-x64.msi', 'https://aka.ms/download-jdk/microsoft-jdk-21.0.12-windows-aarch64.msi'), Dependency_String('', '96ee22a4863c1b6f92ff3c8af0f8dab4a7dffc210440b1641950d9001d0e23ed', '00b5888d71cbd1e5762e4266ba56046869be1f78d1b5d36485c9a3d94f5c4a55')); end;
procedure Dependency_AddJava25; begin Dependency_AddJava(25, Dependency_String('', 'https://aka.ms/download-jdk/microsoft-jdk-25.0.4-windows-x64.msi', 'https://aka.ms/download-jdk/microsoft-jdk-25.0.4-windows-aarch64.msi'), Dependency_String('', 'aa2910c6586412513f1a84ecbef0dc8ac22ea10e08b4c6d37a80cfca9f837941', '599f3d5020b08029845a65e9c0feb9166be1fa9634bfd085b9962f832a4e622e')); end;

function Dependency_IsPythonInstalled(const Tag: String): Boolean;
begin
  Result := RegKeyExists(Dependency_ArchHKLM, 'Software\Python\PythonCore\' + Tag + '\InstallPath') or RegKeyExists(HKCU, 'Software\Python\PythonCore\' + Tag + '\InstallPath');
end;

procedure Dependency_AddPython(const Minor, URL, Checksum: String);
begin
  // https://www.python.org/downloads/windows/
  Dependency_AddIfMissing(not Dependency_IsPythonInstalled(Minor + Dependency_String('-32', '', '-arm64')),
    'python' + Minor + Dependency_ArchSuffix + '.exe',
    Dependency_PassiveOrQuiet('/passive', '/quiet') + ' InstallAllUsers=1 PrependPath=1',
    'Python ' + Minor + Dependency_ArchTitle,
    URL,
    Checksum,
    False, False);
end;

procedure Dependency_AddPython313; begin Dependency_AddPython('3.13', Dependency_String('https://www.python.org/ftp/python/3.13.15/python-3.13.15.exe', 'https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe', 'https://www.python.org/ftp/python/3.13.15/python-3.13.15-arm64.exe'), Dependency_String('741c07276eb2d57e7ee012d643f021c58cb38d11c5389be46c15d41d1a10b447', 'edec09c4853aeae9ac36efb8c9f95b6b8e2fee65eee56d9767a8b7c69c574403', 'c252c676087c49e6b94e95a273536b78921c28a5fc9f86d15d25392328247249')); end;
procedure Dependency_AddPython314; begin Dependency_AddPython('3.14', Dependency_String('https://www.python.org/ftp/python/3.14.7/python-3.14.7.exe', 'https://www.python.org/ftp/python/3.14.7/python-3.14.7-amd64.exe', 'https://www.python.org/ftp/python/3.14.7/python-3.14.7-arm64.exe'), Dependency_String('097fc03d4ac2de66ee1d73a0c5d2d323b5c0f14923f7207686ce93149a80f0a6', '9d9eb2709ef81bf5cd30db3c2096bdbc4ea10087c22e62f27d356b36f6ae9649', '9a3fe120cc81bc2cb099550f794d8356811f96a86c7f438519243c3485db928d')); end;

procedure Dependency_AddPowerShell7;
begin
  // https://github.com/PowerShell/PowerShell/releases
  Dependency_AddIfMissing(not FileExists(ExpandConstant(Dependency_StringX64('{commonpf32}', '{commonpf64}')) + '\PowerShell\7\pwsh.exe'),
    'powershell7' + Dependency_ArchSuffix + '.msi',
    Dependency_PassiveOrQuiet('/passive', '/quiet') + ' /norestart',
    'PowerShell 7' + Dependency_ArchTitle,
    Dependency_String('https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7-win-x86.msi', 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7-win-x64.msi', 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7-win-arm64.msi'),
    Dependency_String('e0a5296fe368b2dc1b4fef1217979a32cfed8a26f3586fb09fcee9a72873691b', 'ec575cef9ec56fcd905de0d5eeac9cb7f81a0a65abb87bb5cd0e87fdfe2b8cc0', 'ddb2f3613a0ad27817b90601a0827f7347e81dfa5bce18d4be8009b8cb0e0a31'),
    False, False);
end;
