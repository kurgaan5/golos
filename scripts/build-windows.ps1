param([ValidateSet('x64','arm64')][string]$Arch='x64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$build=Join-Path $root ".build/windows-$Arch"
$source=Join-Path $root '.build/whisper.cpp-1.8.2'
New-Item -ItemType Directory -Force "$root/.build", "$root/dist" | Out-Null
if (!(Test-Path $source)) {
  curl.exe --fail --location --retry 3 https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.2.tar.gz -o "$root/.build/whisper.tar.gz"
  if ($LASTEXITCODE) { throw 'Whisper download failed' }
  tar -xzf "$root/.build/whisper.tar.gz" -C "$root/.build"
  if ($LASTEXITCODE) { throw 'Whisper extraction failed' }
}
$platform=if ($Arch -eq 'x64') {'x64'} else {'ARM64'}
$toolset=if ($Arch -eq 'arm64') {@('-T','ClangCL')} else {@()}
cmake -S "$root/native" -B $build -A $platform @toolset "-DWHISPER_SOURCE=$source"
if ($LASTEXITCODE) { throw 'Native configuration failed' }
cmake --build $build --config Release --parallel 4
if ($LASTEXITCODE) { throw 'Native compilation failed' }
$package=Join-Path $root "dist/Golos-1.7-Windows-$Arch"
dotnet publish "$root/windows/Golos.Windows/Golos.Windows.csproj" -c Release -r "win-$Arch" --self-contained true -p:PublishSingleFile=false -o $package
if ($LASTEXITCODE) { throw 'Managed publish failed' }
$nativeLibraries=Get-ChildItem $build -Filter '*.dll' -Recurse
if (!$nativeLibraries -or !($nativeLibraries.Name -contains 'golos_native.dll')) { throw 'Native DLLs missing' }
$nativeLibraries | ForEach-Object { Copy-Item $_.FullName $package -Force }
Copy-Item "$root/ThirdPartyNotices.txt", "$root/WINDOWS.txt" $package
Copy-Item "$root/licenses" $package -Recurse -Force
python "$PSScriptRoot/fetch-models.py" "$package/Resources"
if ($LASTEXITCODE) { throw 'Model verification failed' }
$tests=Join-Path $root ".build/tests-$Arch"
dotnet publish "$root/windows/Golos.Tests/Golos.Tests.csproj" -c Release -r "win-$Arch" --self-contained true -o $tests
if ($LASTEXITCODE) { throw 'Test compilation failed' }
$nativeLibraries | ForEach-Object { Copy-Item $_.FullName $tests -Force }
& "$tests/Golos.Tests.exe" "$package/Resources/ggml-large-v3-turbo-q5_0.bin" "$root/tests/fixtures"
if ($LASTEXITCODE) { throw 'Recognition tests failed' }
$preview=Start-Process "$package/Golos.exe" -ArgumentList @('--render-ui',"`"$root/dist/Windows-$Arch.png`"") -PassThru -Wait
if ($preview.ExitCode -ne 0) { throw 'UI smoke test failed' }
Compress-Archive -Path $package -DestinationPath "$package.zip" -Force
Get-FileHash "$package.zip" -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  Golos-1.7-Windows-$Arch.zip" } | Set-Content "$package.zip.sha256"
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
$setupFile=Join-Path $root "dist/Golos-1.7-Windows-$Arch-Setup.exe"
# Verify that a clean per-user installation contains the complete offline app.
$smokeDir=Join-Path $root ".build/installed-$Arch"
$install=Start-Process $setupFile -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"`"/DIR=$smokeDir`"") -PassThru -Wait
if ($install.ExitCode -ne 0) { throw 'Installer smoke test failed' }
foreach ($file in @('Golos.exe','golos_native.dll','Resources/ggml-large-v3-turbo-q5_0.bin','Resources/ggml-silero-v5.1.2.bin')) {
  if (!(Test-Path (Join-Path $smokeDir $file))) { throw "Installed file missing: $file" }
}
$installedPreview=Start-Process "$smokeDir/Golos.exe" -ArgumentList @('--render-ui',"`"$root/dist/Windows-$Arch.png`"") -PassThru -Wait
if ($installedPreview.ExitCode -ne 0) { throw 'Installed application smoke test failed' }
Get-FileHash $setupFile -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $([IO.Path]::GetFileName($setupFile))" } | Set-Content "$setupFile.sha256"
