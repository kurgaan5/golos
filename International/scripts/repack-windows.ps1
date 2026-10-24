param([ValidateSet('x64','arm64')][string]$Arch='x64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$baseline='276d5806787f171783977def6c4956c76c908a9b'
git -C $root/.. diff --exit-code $baseline HEAD -- International/native International/windows/Golos.Core
if ($LASTEXITCODE) { throw 'Native/core changes require the full build workflow' }
$input=Join-Path $root '.build/baseline'
$archive=Get-ChildItem $input -Filter "DictaNest-1.8.0-beta.1-Windows-$Arch.zip" | Select-Object -First 1
if (!$archive) { throw 'Verified baseline ZIP is missing' }
New-Item -ItemType Directory -Force "$root/dist" | Out-Null
Expand-Archive $archive.FullName "$root/dist" -Force
$package=Join-Path $root "dist/DictaNest-1.8.0-beta.1-Windows-$Arch"
$nativeBefore=Get-ChildItem $package -Filter '*.dll' | Where-Object {$_.Name -match '^(golos_native|whisper|ggml)'} | Get-FileHash -Algorithm SHA256
if (!$nativeBefore) { throw 'Baseline native libraries missing' }
dotnet publish "$root/windows/Golos.Windows/Golos.Windows.csproj" -c Release -r "win-$Arch" --self-contained true -p:PublishSingleFile=false -o $package
if ($LASTEXITCODE) { throw 'Managed compilation failed' }
foreach ($item in $nativeBefore) { if ((Get-FileHash $item.Path -Algorithm SHA256).Hash -ne $item.Hash) { throw 'Native library changed during UI repack' } }
python "$PSScriptRoot/fetch-models.py" "$package/Resources"
if ($LASTEXITCODE) { throw 'Model verification failed' }
dotnet run --project "$root/windows/Golos.Tests" -c Release
if ($LASTEXITCODE) { throw 'Portable regressions failed' }
$preview=Start-Process "$package/DictaNest.exe" -ArgumentList @('--render-ui',"`"$root/dist/Windows-$Arch.png`"") -PassThru -Wait
if ($preview.ExitCode) { throw 'UI render failed' }
Compress-Archive -Path $package -DestinationPath "$package.zip" -Force
Get-FileHash "$package.zip" -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  DictaNest-1.8.0-beta.1-Windows-$Arch.zip" } | Set-Content "$package.zip.sha256"
$compiler=Get-ChildItem "${env:ProgramFiles(x86)}/Inno Setup */ISCC.exe", "$env:ProgramFiles/Inno Setup */ISCC.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (!$compiler) {
  $installer=Join-Path $root '.build/innosetup.exe'
  curl.exe --fail --location --retry 3 https://files.jrsoftware.org/is/6/innosetup-6.4.3.exe -o $installer
  if ($LASTEXITCODE) { throw 'Inno Setup download failed' }
  $signature=Get-AuthenticodeSignature $installer
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Jordan Russell') { throw 'Inno Setup publisher verification failed' }
  $inno=Join-Path $root '.build/InnoSetup'
  $setup=Start-Process $installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/CURRENTUSER',"`"/DIR=$inno`"") -PassThru -Wait
  if ($setup.ExitCode -ne 0) { throw 'Inno Setup installation failed' }
  $compiler=Join-Path $inno 'ISCC.exe'
}
& $compiler "/DPackageDir=$package" "/DOutputDir=$root/dist" "/DTargetArch=$Arch" "$PSScriptRoot/windows-installer.iss"
if ($LASTEXITCODE) { throw 'Installer compilation failed' }
$setupFile=Join-Path $root "dist/DictaNest-1.8.0-beta.1-Windows-$Arch-Setup.exe"
# Verify that a clean per-user installation contains the complete offline app.
$smokeDir=Join-Path $root ".build/installed-$Arch"
$install=Start-Process $setupFile -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"`"/DIR=$smokeDir`"") -PassThru -Wait
if ($install.ExitCode -ne 0) { throw 'Installer smoke test failed' }
foreach ($file in @('DictaNest.exe','golos_native.dll','Resources/ggml-large-v3-turbo-q5_0.bin','Resources/ggml-silero-v5.1.2.bin')) {
  if (!(Test-Path (Join-Path $smokeDir $file))) { throw "Installed file missing: $file" }
}
$installedPreview=Start-Process "$smokeDir/DictaNest.exe" -ArgumentList @('--render-ui',"`"$root/dist/Windows-$Arch.png`"") -PassThru -Wait
if ($installedPreview.ExitCode -ne 0) { throw 'Installed application smoke test failed' }
Get-FileHash $setupFile -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $([IO.Path]::GetFileName($setupFile))" } | Set-Content "$setupFile.sha256"
