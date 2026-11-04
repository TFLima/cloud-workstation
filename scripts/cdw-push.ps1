<#
.SYNOPSIS
    Copia arquivos ou pastas do Windows para ~/work na VM, seja qual for o IP atual.

.DESCRIPTION
    O IP da VM muda a cada "make up". Este script pergunta ao WSL o IP atual
    (scripts/vm-info.sh, que le o estado OpenTofu), atualiza o bloco "Host cdw"
    do seu ~/.ssh/config (o mesmo que o VS Code Remote - SSH usa) e copia os
    arquivos com scp para /home/<usuario>/work na VM (ou uma subpasta).

    Chave de host: cada VM ganha um known_hosts proprio
    (~/.ssh/known_hosts.cdw.<id-da-VM>), preenchido com as chaves que o WSL ja
    conhece daquela VM. Se o WSL ainda nao conhecer nenhuma, a primeira conexao
    aceita a chave (StrictHostKeyChecking accept-new) e a fixa para essa VM.
    Uma chave diferente para a mesma VM continua sendo recusada pelo ssh; o
    script nunca desliga a verificacao.

    Arquivo em ASCII de proposito: o Windows PowerShell 5.1 le .ps1 sem BOM
    como ANSI e estragaria acentos.

.PARAMETER Path
    Arquivos ou pastas locais (aceita curingas, ex.: *.csv).

.PARAMETER Dest
    Subpasta dentro de ~/work na VM (ex.: projetos/site). Criada se faltar.

.PARAMETER ConfigOnly
    So atualiza o bloco "Host cdw" do ~/.ssh/config (util depois de um make up,
    antes de abrir o VS Code), sem copiar nada.

.EXAMPLE
    cdw-push .\relatorio.pdf

.EXAMPLE
    cdw-push .\meu-projeto .\notas.txt -Dest projetos

.EXAMPLE
    cdw-push -ConfigOnly
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,
    [string]$Dest = '',
    [switch]$ConfigOnly,
    [string]$HostAlias = 'cdw',
    [string]$Distro = $env:CDW_WSL_DISTRO,
    [string]$RepoPath = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Write-Cdw([string]$Message) { Write-Host "[cdw] $Message" }
function Stop-Cdw([string]$Message) {
    Write-Host "[cdw] ERRO: $Message" -ForegroundColor Red
    exit 1
}

# UTF-8 sem BOM: o OpenSSH nao entende um config que comece com BOM.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-CdwVmInfo {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Stop-Cdw 'wsl.exe nao encontrado; o estado da VM fica no WSL (veja docs/operations.md).'
    }
    $wslArgs = @()
    if ($Distro) { $wslArgs += @('-d', $Distro) }
    # "bash -l" carrega o PATH do seu usuario no WSL (onde esta o tofu).
    $wslArgs += @('--cd', $RepoPath, '-e', 'bash', '-l', 'scripts/vm-info.sh')
    $lines = @(& wsl.exe @wslArgs)
    if ($LASTEXITCODE -ne 0) {
        Stop-Cdw "nao consegui ler a VM pelo WSL (codigo $LASTEXITCODE). Teste no WSL: cd <repo> && bash scripts/vm-info.sh"
    }
    $info = @{ server_id = ''; ipv4 = ''; username = ''; hostkey = @() }
    foreach ($line in $lines) {
        if ("$line" -match '^(server_id|ipv4|username|hostkey)=(.*)$') {
            if ($Matches[1] -eq 'hostkey') { $info.hostkey += $Matches[2].Trim() }
            else { $info[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    if ($info.server_id -notmatch '^[0-9]+$') { Stop-Cdw 'id da VM ausente ou invalido na resposta do WSL.' }
    if ($info.ipv4 -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$') { Stop-Cdw 'IPv4 ausente ou invalido na resposta do WSL.' }
    if ($info.username -notmatch '^[a-z][a-z0-9_-]{1,30}$') { Stop-Cdw 'usuario ausente ou invalido na resposta do WSL.' }
    return $info
}

# Grava as chaves de host que o WSL ja conhece desta VM, se o known_hosts
# proprio dela ainda nao existir no Windows. Nunca apaga nem troca chaves.
function Initialize-CdwKnownHosts($Info, [string]$File) {
    if (Test-Path -LiteralPath $File) { return }
    if ($Info.hostkey.Count -gt 0) {
        [System.IO.File]::WriteAllText($File, (($Info.hostkey -join "`n") + "`n"), $Utf8NoBom)
        Write-Cdw "chaves de host da VM $($Info.server_id) copiadas do WSL para $File"
    }
    else {
        Write-Cdw "AVISO: o WSL ainda nao conhece a chave de host desta VM; a primeira conexao vai aceita-la e fixa-la em $File."
    }
}

# Atualiza (ou cria) o bloco "Host <alias>" mantendo as demais linhas dele
# (IdentityFile, LocalForward etc.). Retorna o HostName anterior.
function Update-CdwSshConfig([string]$ConfigFile, [string]$Alias, $Settings) {
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $ConfigFile) {
        foreach ($l in [System.IO.File]::ReadAllLines($ConfigFile)) { $lines.Add($l) }
    }
    $hostRe = '^\s*Host\s+' + [regex]::Escape($Alias) + '\s*$'
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $hostRe) { $start = $i; break }
    }
    $previous = ''
    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
        $lines.Add("Host $Alias")
        foreach ($k in $Settings.Keys) { $lines.Add("    $k $($Settings[$k])") }
        $lines.Add('    IdentityFile ~/.ssh/id_ed25519')
        $lines.Add('    IdentitiesOnly yes')
        $lines.Add('    ServerAliveInterval 30')
        Write-Cdw "bloco 'Host $Alias' criado em $ConfigFile"
    }
    else {
        $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*(Host|Match)\s') { $end = $i; break }
        }
        foreach ($k in $Settings.Keys) {
            $keyRe = '^(\s*)' + $k + '(\s+|\s*=\s*)(.*)$'
            $found = $false
            for ($i = $start + 1; $i -lt $end; $i++) {
                if ($lines[$i] -match $keyRe) {
                    if ($k -eq 'HostName') { $previous = $Matches[3].Trim() }
                    $lines[$i] = "$($Matches[1])$k $($Settings[$k])"
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                $lines.Insert($start + 1, "    $k $($Settings[$k])")
                $end++
            }
        }
    }
    $text = ($lines -join "`n") + "`n"
    $old = ''
    if (Test-Path -LiteralPath $ConfigFile) { $old = [System.IO.File]::ReadAllText($ConfigFile) }
    if ($text -ne $old) {
        if ($old -ne '') { Copy-Item -LiteralPath $ConfigFile -Destination "$ConfigFile.bak-cdw" -Force }
        [System.IO.File]::WriteAllText($ConfigFile, $text, $Utf8NoBom)
    }
    return $previous
}

# --- Validacao da entrada (antes de qualquer acesso ao WSL ou a VM) ---
if (-not $ConfigOnly -and (-not $Path -or $Path.Count -eq 0)) {
    Write-Host 'Uso: cdw-push <arquivo-ou-pasta> [...] [-Dest subpasta]   |   cdw-push -ConfigOnly'
    exit 2
}

$Dest = $Dest.Replace('\', '/').TrimEnd('/')
if ($Dest -ne '') {
    $badSegment = @($Dest.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0
    if ($Dest -notmatch '^[A-Za-z0-9._/-]+$' -or $Dest.StartsWith('/') -or $Dest.StartsWith('-') -or $badSegment) {
        Stop-Cdw "subpasta invalida: '$Dest' (use um caminho relativo a ~/work, sem '..' nem espacos)"
    }
}

$sources = @()
if (-not $ConfigOnly) {
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p) {
            $sources += @(Resolve-Path -LiteralPath $p -Relative)
        }
        else {
            $found = @(Resolve-Path -Path $p -Relative -ErrorAction SilentlyContinue)
            if ($found.Count -eq 0) { Stop-Cdw "nao encontrado: $p" }
            $sources += $found
        }
    }
}

foreach ($tool in @('ssh', 'scp')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Stop-Cdw "$tool nao encontrado; instale o 'Cliente OpenSSH' do Windows (Configuracoes > Apps > Recursos opcionais)."
    }
}

# --- IP atual e ~/.ssh/config ---
$info = Get-CdwVmInfo
$sshDir = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
$knownHostsName = "known_hosts.cdw.$($info.server_id)"
Initialize-CdwKnownHosts $info (Join-Path $sshDir $knownHostsName)

$settings = [ordered]@{
    HostName              = $info.ipv4
    User                  = $info.username
    UserKnownHostsFile    = "~/.ssh/$knownHostsName"
    StrictHostKeyChecking = 'accept-new'
}
$configFile = Join-Path $sshDir 'config'
$previous = Update-CdwSshConfig $configFile $HostAlias $settings
if ($previous -and $previous -ne $info.ipv4) {
    Write-Cdw "Host $HostAlias atualizado: $previous -> $($info.ipv4) (VM $($info.server_id))"
}
else {
    Write-Cdw "Host $HostAlias -> $($info.ipv4) (VM $($info.server_id))"
}
if ($ConfigOnly) { exit 0 }

# --- Copia ---
$remote = "/home/$($info.username)/work"
if ($Dest) { $remote = "$remote/$Dest" }
& ssh $HostAlias "mkdir -p -- '$remote'"
if ($LASTEXITCODE -ne 0) { Stop-Cdw "nao consegui criar $remote na VM (ssh saiu com $LASTEXITCODE)." }
& scp -r @sources "$($HostAlias):$remote/"
if ($LASTEXITCODE -ne 0) { Stop-Cdw "a copia falhou (scp saiu com $LASTEXITCODE)." }
Write-Cdw "copiado para $($HostAlias):$remote/"
