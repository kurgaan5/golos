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
cmake -S "$root/native" -B $build -A $platform "-DWHISPER_SOURCE=$source"
if ($LASTEXITCODE) { throw 'Native configuration failed' }
cmake --build $build --config Release --parallel 4
if ($LASTEXITCODE) { throw 'Native compilation failed' }
$package=Join-Path $root "dist/Golos-1.7-Windows-$Arch"
dotnet publish "$root/windows/Golos.Windows/Golos.Windows.csproj" -c Release -r "win-$Arch" --self-contained true -p:PublishSingleFile=false -o $package
if ($LASTEXITCODE) { throw 'Managed publish failed' }
Copy-Item "$build/Release/golos_native.dll" $package
Copy-Item "$root/ThirdPartyNotices.txt", "$root/WINDOWS.txt" $package
Copy-Item "$root/licenses" $package -Recurse -Force
python "$PSScriptRoot/fetch-models.py" "$package/Resources"
if ($LASTEXITCODE) { throw 'Model verification failed' }
$tests=Join-Path $root ".build/tests-$Arch"
dotnet publish "$root/windows/Golos.Tests/Golos.Tests.csproj" -c Release -r "win-$Arch" --self-contained true -o $tests
if ($LASTEXITCODE) { throw 'Test compilation failed' }
Copy-Item "$build/Release/golos_native.dll" $tests
& "$tests/Golos.Tests.exe" "$package/Resources/ggml-large-v3-turbo-q5_0.bin" "$root/tests/fixtures"
if ($LASTEXITCODE) { throw 'Recognition tests failed' }
$preview=Start-Process "$package/Golos.exe" -ArgumentList @('--render-ui',"`"$root/dist/Windows-$Arch.png`"") -PassThru -Wait
if ($preview.ExitCode -ne 0) { throw 'UI smoke test failed' }
Compress-Archive -Path $package -DestinationPath "$package.zip" -Force
Get-FileHash "$package.zip" -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  Golos-1.7-Windows-$Arch.zip" } | Set-Content "$package.zip.sha256"
