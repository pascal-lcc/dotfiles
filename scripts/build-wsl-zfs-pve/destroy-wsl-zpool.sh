#!/usr/bin/env bash
#
# destroy-wsl-zpool-v6.sh — V6.6.9 Page83-first mapping; optional VHDX deletion
#
# Discovery and safety checks are read-only. The explicit menu action can
# execute zpool destroy only after two safety checks and a yes/no confirmation.
# - After verified destroy, detach only the mapped VHDX and safely edit /etc/wsl.conf
# - VHDX deletion is optional and requires successful cleanup plus a fresh Page83 match.
#
# Windows Hyper-V event query can optionally request UAC elevation.

set -u

DISTRO="pve"
PS_EXE="/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe"
COMPUTE_LOG="Microsoft-Windows-Hyper-V-Compute-Operational"

section() {
    printf '\n'
    printf '%s\n' '============================================================'
    printf ' %s\n' "$1"
    printf '%s\n' '============================================================'
}

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

# Convert PowerShell source into Windows PowerShell -EncodedCommand format.
ps_encode() {
    iconv -f UTF-8 -t UTF-16LE | base64 -w 0
}

# Latest Hyper-V attachment information.
declare -A HV_ATTACHMENT_CONTROLLER=()
declare -A HV_ATTACHMENT_STATE=()
declare -A HV_ATTACHMENT_PATH=()

# Query Hyper-V Compute events through an elevated PowerShell process.
query_windows_events() {
    local answer

    section "Windows: Hyper-V Compute events"

    info "需要管理員權限讀取 Hyper-V Compute Operational event log。"
    info "查詢工具：wevtutil.exe"
    info "Event ID: 2007"
    info "Query: VHDX attachment history"

    printf '\n'
    read -r -p "是否透過 UAC 以管理員權限查詢？ [y/N] " answer || answer=""

    case "$answer" in
    y | Y | yes | YES)
        if query_windows_events_elevated; then
            return 0
        fi
        warn "未能取得管理員權限或 Hyper-V 事件讀取失敗。"
        warn "無法驗證 VHDX 與 Linux SCSI Page 83 的對應關係。"
        warn "因此本次禁止執行 ZFS Destroy，也禁止刪除任何 VHDX。"
        return 1
        ;;
    *)
        warn "未取得管理員權限（已選擇略過或直接按 Enter）。"
        warn "無法讀取 Hyper-V attachment events，因此無法驗證 VHDX ↔ SCSI Page 83 身分。"
        warn "因此本次禁止執行 ZFS Destroy，也禁止刪除任何 VHDX。"
        return 1
        ;;
    esac
}

# Run wevtutil in an elevated child PowerShell.
# The child writes XML, stderr and exit code to separate files.
query_windows_events_elevated() {
    local encoded=""
    local output
    local rc

    info "準備呼叫 Windows RunAs..."

    encoded=$(
        cat <<'PS' | ps_encode
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    $prefix = Join-Path $env:TEMP (
        'wsl-zpool-' + [guid]::NewGuid().ToString()
    )

    $outFile   = "$prefix.xml"
    $errFile   = "$prefix.err"
    $exitFile  = "$prefix.exit"
    $debugFile = "$prefix.debug"
    $childFile = "$prefix.child.ps1"

    $childScript = @'
param(
    [string]$OutFile,
    [string]$ErrFile,
    [string]$ExitFile,
    [string]$DebugFile
)

$ErrorActionPreference = 'Stop'

try {
    [IO.File]::WriteAllText(
        $DebugFile,
        "CHILD_STARTED`r`n"
    )

    [IO.File]::AppendAllText(
        $DebugFile,
        "IDENTITY: $(& whoami.exe)`r`n"
    )

    $channel = 'Microsoft-Windows-Hyper-V-Compute-Operational'
    $query = '*[System[(EventID=2007)]]'
    $wevtutil = "$env:SystemRoot\System32\wevtutil.exe"

    [IO.File]::AppendAllText(
        $DebugFile,
        "BEFORE_WEVTUTIL`r`n"
    )

    & $wevtutil qe $channel "/q:$query" /rd:true /c:500 /f:xml `
        1> $OutFile `
        2> $ErrFile

    $rc = $LASTEXITCODE

    [IO.File]::AppendAllText(
        $DebugFile,
        "WEVTUTIL_EXIT: $rc`r`n"
    )

    [IO.File]::WriteAllText(
        $ExitFile,
        [string]$rc,
        [Text.Encoding]::ASCII
    )

    [IO.File]::AppendAllText(
        $DebugFile,
        "EXITFILE_WRITTEN`r`n"
    )

    exit $rc
}
catch {
    try {
        [IO.File]::AppendAllText(
            $DebugFile,
            "CHILD_EXCEPTION: $($_.Exception.ToString())`r`n"
        )
    }
    catch {
        # Debug logging failure must not hide the original error.
    }

    exit 90
}
'@

    [IO.File]::WriteAllText(
        $childFile,
        $childScript,
        [Text.Encoding]::Unicode
    )

    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        "`"$childFile`""
        '-OutFile'
        "`"$outFile`""
        '-ErrFile'
        "`"$errFile`""
        '-ExitFile'
        "`"$exitFile`""
        '-DebugFile'
        "`"$debugFile`""
    ) -join ' '

    $process = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs `
        -Wait `
        -PassThru `
        -ArgumentList $argumentList

    Write-Output "Elevated child exit code: $($process.ExitCode)"

    Write-Output '=== Elevated wevtutil result ==='

    if (Test-Path -LiteralPath $exitFile) {
        $queryExit = [int](Get-Content -LiteralPath $exitFile -Raw)
        Write-Output "wevtutil exit code: $queryExit"
    }
    else {
        Write-Output '[ERROR] Elevated process did not write exit code.'
        Write-Output "PowerShell process exit code: $($process.ExitCode)"
        $queryExit = 1
    }

if (Test-Path -LiteralPath $outFile) {

    try {
        $rawXml = Get-Content -LiteralPath $outFile -Raw

        # Remove XML declaration if present.
        $rawXml = $rawXml -replace '^\s*<\?xml[^>]*\?>', ''

        # Wrap multiple Event elements in one root element.
        [xml]$doc = "<Events>$rawXml</Events>"

        $parsedEvents = @()

        foreach ($event in $doc.SelectNodes(
            "/*[local-name()='Events']/*[local-name()='Event']"
        )) {
            $system = $event.SelectSingleNode(
                "./*[local-name()='System']"
            )

            if (-not $system) {
                continue
            }

            $timeNode = $system.SelectSingleNode(
                "./*[local-name()='TimeCreated']"
            )

            $recordNode = $system.SelectSingleNode(
                "./*[local-name()='EventRecordID']"
            )
$userData = $event.SelectSingleNode(
    ".//*[local-name()='VmlEventLog']"
)

if (-not $userData) {
    continue
}

$paramNode = $userData.SelectSingleNode(
    "./*[local-name()='Parameter0']"
)

$resultNode = $userData.SelectSingleNode(
    "./*[local-name()='Result']"
)

if (-not $paramNode) {
    continue
}

$data = $paramNode.InnerText | ConvertFrom-Json
$resourcePath = [string]$data.ResourcePath

if ($resourcePath -notmatch '^VirtualMachine/Devices/Scsi/(\d+)/Attachments/(\d+)$') {
    continue
}

$controller = $Matches[1]
$attachment = $Matches[2]

$timeLocal = $null

if ($timeNode) {
    $timeLocal = [DateTimeOffset]::Parse(
        $timeNode.GetAttribute('SystemTime')
    ).ToLocalTime()
}

$recordID = ''

if ($recordNode) {
    $recordID = [string]$recordNode.InnerText
}

$result = ''

if ($resultNode) {
    $result = [string]$resultNode.InnerText
}

$parsedEvents += [pscustomobject]@{
    TimeCreated = $timeLocal
    RecordID    = $recordID
    RequestType = [string]$data.RequestType
    Attachment  = $attachment
    Result      = $result
    Path        = [string]$data.Settings.Path
    Controller = $controller
}
        }

                # ------------------------------------------------------------
        # Emit latest Hyper-V attachment state for Bash
        # ------------------------------------------------------------


        $latestByAttachment = @(
            $parsedEvents |
                Group-Object -Property {
                    "$($_.Controller)|$($_.Attachment)"
                } |
                ForEach-Object {
                    $_.Group |
                        Sort-Object {
                            [long]$_.RecordID
                        } -Descending |
                        Select-Object -First 1
                }
        )

        foreach ($event in $latestByAttachment) {
            $controller = [string]$event.Controller
            $attachment = [string]$event.Attachment
            $requestType = ([string]$event.RequestType).ToUpperInvariant()
            $result = ([string]$event.Result).Trim()

            if ($result -ne '0x00000000') {
                $state = 'UNKNOWN'
            }
            elseif ($requestType -eq 'ADD') {
                $state = 'ADD'
            }
            elseif ($requestType -eq 'REMOVE') {
                $state = 'REMOVE'
            }
            else {
                $state = 'UNKNOWN'
            }

            $path = [string]$event.Path
            $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($path)
            $pathBase64 = [Convert]::ToBase64String($pathBytes)

            Write-Output "@@ATTACHMENT|$controller|$attachment|$state|$pathBase64"
        }

        if ($parsedEvents.Count -eq 0) {
            Write-Output '[INFO] No SCSI attachment events found.'
        }
    }
    catch {
        Write-Output "[XML_PARSE_ERROR] $($_.Exception.Message)"
        Write-Output '[INFO] Raw XML is preserved at:'
        Write-Output $outFile
    }
}

if (Test-Path -LiteralPath $errFile) {
    $err = Get-Content -LiteralPath $errFile -Raw

    if (-not [string]::IsNullOrWhiteSpace($err)) {
        Write-Output '=== wevtutil stderr ==='
        Write-Output $err
    }
}

    exit $queryExit
}
catch {
    Write-Output "[UAC_ERROR] $($_.Exception.Message)"
    exit 6
}
PS
    )

    output=$("$PS_EXE" -NoProfile -EncodedCommand "$encoded" 2>&1)
    rc=$?

    printf '%s\n' "$output" | sed '/^@@ATTACHMENT|/d'

    if [[ "$rc" -ne 0 ]]; then
        warn "管理員查詢失敗，PowerShell exit code: $rc"
        return "$rc"
    fi

    # ------------------------------------------------------------
    # Parse machine-readable Hyper-V attachment records
    # ------------------------------------------------------------

    HV_ATTACHMENT_CONTROLLER=()
    HV_ATTACHMENT_STATE=()
    HV_ATTACHMENT_PATH=()

    while IFS='|' read -r marker controller attachment state path_b64; do
        [[ "$marker" == "@@ATTACHMENT" ]] || continue
        [[ "$controller" =~ ^[0-9]+$ ]] || continue
        [[ "$attachment" =~ ^[0-9]+$ ]] || continue

        local decoded_path=""
        local attachment_key="${controller}:${attachment}"

        # Remove Windows CRLF carriage return.
        controller="${controller//$'\r'/}"
        attachment="${attachment//$'\r'/}"
        state="${state//$'\r'/}"
        path_b64="${path_b64//$'\r'/}"

        attachment_key="${controller}:${attachment}"

        if [[ -n "$path_b64" ]]; then
            if ! decoded_path=$(printf '%s' "$path_b64" | base64 -d 2>/dev/null); then
                warn "Controller $controller Attachment $attachment 路徑 Base64 解碼失敗。"
                continue
            fi
        fi

        HV_ATTACHMENT_CONTROLLER["$attachment_key"]="$controller"
        HV_ATTACHMENT_STATE["$attachment_key"]="$state"
        HV_ATTACHMENT_PATH["$attachment_key"]="$decoded_path"

    done <<<"$output"

    # ------------------------------------------------------------
    # Display parsed attachment records
    # ------------------------------------------------------------

    section "Bash: Parsed Hyper-V attachments"

    if [[ ${#HV_ATTACHMENT_STATE[@]} -eq 0 ]]; then
        warn "沒有取得任何有效的 Attachment 資料。"
    else
        printf '%-12s %-12s %-12s %s\n' \
            "CONTROLLER" "ATTACHMENT" "STATE" "VHDX PATH"

        for attachment_key in "${!HV_ATTACHMENT_STATE[@]}"; do
            printf '%-12s %-12s %-12s %s\n' \
                "${HV_ATTACHMENT_CONTROLLER[$attachment_key]}" \
                "${attachment_key#*:}" \
                "${HV_ATTACHMENT_STATE[$attachment_key]}" \
                "${HV_ATTACHMENT_PATH[$attachment_key]}"
        done
    fi

    return 0
}

# ------------------------------------------------------------
# Read VHDX Metadata Page 83 Data
# ------------------------------------------------------------

read_vhdx_page83() {

    local vhdx_path="$1"
    local path_b64
    local encoded
    local output
    local rc

    path_b64="$(printf '%s' "$vhdx_path" | base64 -w 0)"

    # Build PowerShell script without Bash variable expansion.
    ps_script=$(
        cat <<'PS'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$pathB64 = "__PATH_B64__"

try {

    $path = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($pathB64)
    )

    $fs = [IO.File]::Open(
        $path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )

    try {

        $reader = New-Object System.IO.BinaryReader($fs)

        function Read-BytesAt([long]$offset, [int]$count) {
            $fs.Position = $offset
            return $reader.ReadBytes($count)
        }

        function Read-UInt32At([long]$offset) {
            $fs.Position = $offset
            return $reader.ReadUInt32()
        }

        function Read-UInt16At([long]$offset) {
            $fs.Position = $offset
            return $reader.ReadUInt16()
        }

        function Guid-At([long]$offset) {
            $bytes = Read-BytesAt $offset 16
            return [System.Guid]([byte[]]$bytes)
        }

        # ----------------------------------------------------
        # Locate Metadata Region through Region Table
        # ----------------------------------------------------

        $regionOffsets = @(196608, 262144)
        $metadataOffset = 0
        $metadataLength = 0

        foreach ($regionOffset in $regionOffsets) {

            $signature = [Text.Encoding]::ASCII.GetString(
                (Read-BytesAt $regionOffset 4)
            )

            if ($signature -ne "regi") {
                continue
            }

            $entryCount = Read-UInt32At ($regionOffset + 8)

            if ($entryCount -gt 2047) {
                continue
            }

            for ($i = 0; $i -lt $entryCount; $i++) {

                $entryOffset = $regionOffset + 16 + ($i * 32)

                $regionGuid = Guid-At $entryOffset

                $regionFileOffset = [BitConverter]::ToUInt64(
                    (Read-BytesAt ($entryOffset + 16) 8), 0
                )

                $regionFileLength = Read-UInt32At ($entryOffset + 24)

                if ($regionGuid.ToString() -ieq "8b7ca206-4790-4b9a-b8fe-575f050f886e") {

                    $metadataOffset = [long]$regionFileOffset
                    $metadataLength = [long]$regionFileLength
                }
            }
        }

        if ($metadataOffset -eq 0 -or $metadataLength -lt 32) {
            throw "Metadata Region not found."
        }

        # ----------------------------------------------------
        # Validate Metadata Table
        # ----------------------------------------------------

        $metadataSignature = [Text.Encoding]::ASCII.GetString(
            (Read-BytesAt $metadataOffset 8)
        )

        if ($metadataSignature -ne "metadata") {
            throw "Invalid Metadata Table signature."
        }

        $itemCount = Read-UInt16At ($metadataOffset + 10)

        if ($itemCount -gt 2047) {
            throw "Invalid Metadata item count."
        }

        $page83Guid = "beca12ab-b2e6-4523-93ef-c309e000c746"
        $page83Found = $false
        $page83Hex = ""

        for ($i = 0; $i -lt $itemCount; $i++) {

            $itemOffset = $metadataOffset + 32 + ($i * 32)

            $itemGuid = Guid-At $itemOffset

            $valueOffset = Read-UInt32At ($itemOffset + 16)
            $valueLength = Read-UInt32At ($itemOffset + 20)

            if ($itemGuid.ToString() -ine $page83Guid) {
                continue
            }

            if ($valueLength -ne 16) {
                throw "Invalid Page 83 Data length."
            }

            if (($valueOffset + $valueLength) -gt $metadataLength) {
                throw "Page 83 Data exceeds Metadata Region."
            }

            $absoluteOffset = $metadataOffset + [long]$valueOffset

            $bytes = Read-BytesAt $absoluteOffset 16

            if ($bytes.Length -ne 16) {
                throw "Unable to read Page 83 Data."
            }

            $page83Hex = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()

            $page83Found = $true
            break
        }

        if (-not $page83Found) {
            throw "Page 83 Data not found."
        }

        Write-Output "@@VHDX|OK|$page83Hex"

    }
    finally {
        $fs.Dispose()
    }
}
catch {
    Write-Output "@@VHDX|ERROR|$($_.Exception.Message)"
    exit 1
}
PS
    )

    # Inject the Base64 path after the quoted heredoc is complete.
    ps_script=${ps_script//__PATH_B64__/$path_b64}

    # Encode PowerShell source as UTF-16LE Base64.
    encoded=$(printf '%s' "$ps_script" | ps_encode)

    output=$("$PS_EXE" -NoProfile -EncodedCommand "$encoded" 2>&1)
    rc=$?

    printf '%s\n' "$output"

    if [[ "$rc" -ne 0 ]]; then
        warn "VHDX Metadata 解析失敗：$vhdx_path"
        return "$rc"
    fi

    return 0
}

# ------------------------------------------------------------
# Resolve a Linux SCSI device to exactly one active Hyper-V VHDX by Page 83.
# Hyper-V Attachment numbers are NOT assumed to equal Linux SCSI LUNs.
# Returns 0 for one unique VHDX path, 1 for no match, 2 for ambiguity.
# ------------------------------------------------------------
PAGE83_MATCH_PATH=""
PAGE83_MATCH_KEY=""
PAGE83_MATCH_PATH_COUNT=0
PAGE83_MATCH_KEY_COUNT=0

find_vhdx_by_page83() {
    local linux_t10="$1" key path page
    local -A matched_paths=()
    PAGE83_MATCH_PATH=""
    PAGE83_MATCH_KEY=""
    PAGE83_MATCH_PATH_COUNT=0
    PAGE83_MATCH_KEY_COUNT=0

    [[ -n "$linux_t10" ]] || return 1

    for key in "${!HV_ATTACHMENT_STATE[@]}"; do
        [[ "${HV_ATTACHMENT_STATE[$key]-}" == "ADD" ]] || continue
        path="${HV_ATTACHMENT_PATH[$key]-}"
        [[ -n "$path" ]] || continue
        page="${VHDX_PAGE83[$path]-}"
        [[ -n "$page" && "$page" == "$linux_t10" ]] || continue

        PAGE83_MATCH_KEY_COUNT=$((PAGE83_MATCH_KEY_COUNT + 1))
        [[ -n "$PAGE83_MATCH_KEY" ]] || PAGE83_MATCH_KEY="$key"
        matched_paths["$path"]=1
    done

    PAGE83_MATCH_PATH_COUNT="${#matched_paths[@]}"
    if ((PAGE83_MATCH_PATH_COUNT == 1)); then
        for path in "${!matched_paths[@]}"; do
            PAGE83_MATCH_PATH="$path"
        done
        return 0
    fi
    if ((PAGE83_MATCH_PATH_COUNT > 1)); then
        return 2
    fi
    return 1
}

if [[ "${1-}" != "--self-test" && "${1-}" != "--test-config-cleanup" ]]; then

section "Environment"

info "WSL distro: $DISTRO"
info "Linux kernel: $(uname -r)"
info "Current user: $(id -un)"
info "Date: $(date --iso-8601=seconds)"

section "Linux SCSI devices"

printf '%-8s %-8s %-8s %-12s %-38s %-20s\n' \
    "DEVICE" "HOST" "LUN" "SIZE" "WWID" "MODEL"

for sysdev in /sys/block/sd*; do
    [[ -e "$sysdev/device" ]] || continue

    dev="${sysdev##*/}"
    device_path="$(readlink -f "$sysdev/device" 2>/dev/null || true)"
    scsi_address="${device_path##*/}"

    host="unknown"
    lun="unknown"

    if [[ "$scsi_address" =~ ^([0-9]+):[0-9]+:[0-9]+:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        lun="${BASH_REMATCH[2]}"
    fi

    wwid="$(cat "$sysdev/device/wwid" 2>/dev/null || echo unknown)"
    model="$(cat "$sysdev/device/model" 2>/dev/null | xargs || echo unknown)"
    size="$(lsblk -dn -o SIZE "/dev/$dev" 2>/dev/null | xargs || echo unknown)"

    printf '%-8s %-8s %-8s %-12s %-38s %-20s\n' \
        "/dev/$dev" "$host" "$lun" "$size" "$wwid" "$model"
done

section "Windows VHDX attachment information"

query_windows_events || true

# Read Page 83 from every unique active Hyper-V ADD VHDX path.
# Hyper-V attachment history is the inventory; wsl.conf is not authoritative.
declare -A VHDX_PAGE83=()
declare -A VHDX_PAGE83_STATUS=()
declare -A scanned_vhdx_paths=()

section "Windows VHDX Metadata Page 83"

for attachment_key in "${!HV_ATTACHMENT_STATE[@]}"; do
    [[ "${HV_ATTACHMENT_STATE[$attachment_key]}" == "ADD" ]] || continue
    vhdx_path="${HV_ATTACHMENT_PATH[$attachment_key]-}"
    [[ -n "$vhdx_path" ]] || continue
    [[ -z "${scanned_vhdx_paths[$vhdx_path]+x}" ]] || continue
    scanned_vhdx_paths["$vhdx_path"]=1

    printf '\n'
    info "Reading VHDX Page 83: $vhdx_path"
    vhdx_output="$(read_vhdx_page83 "$vhdx_path" 2>&1)"
    vhdx_rc=$?
    page83_record="$(printf '%s\n' "$vhdx_output" | tr -d '\r' | grep '^@@VHDX|' | tail -n 1 || true)"

    if [[ "$page83_record" =~ ^@@VHDX\|OK\|([[:xdigit:]]{32})$ ]]; then
        VHDX_PAGE83["$vhdx_path"]="${BASH_REMATCH[1],,}"
        VHDX_PAGE83_STATUS["$vhdx_path"]="OK"
        info "Page 83: ${VHDX_PAGE83[$vhdx_path]}"
    else
        VHDX_PAGE83["$vhdx_path"]=""
        VHDX_PAGE83_STATUS["$vhdx_path"]="ERROR"
        warn "無法讀取此 VHDX 的 Page 83。"
        printf '%s\n' "$vhdx_output" | grep -v '^@@VHDX|' || true
        [[ -n "$page83_record" ]] && warn "$page83_record"
        [[ "$vhdx_rc" -eq 0 ]] || warn "PowerShell exit code: $vhdx_rc"
    fi
done

if ((${#scanned_vhdx_paths[@]} == 0)); then
    info "沒有可供讀取的 Hyper-V ADD VHDX 路徑。"
fi


section "ZFS pools"

ZPOOL_NAMES=()
declare -A POOL_STATUS=()
declare -A POOL_VDEV_COUNT=()
declare -A POOL_MAPPED_COUNT=()
declare -A POOL_VERIFIED_COUNT=()
declare -A POOL_VHDX_PATH=()
declare -A POOL_HEALTH=()
declare -A POOL_GUID=()
declare -A POOL_VDEV_PATHS=()
declare -A POOL_VDEV_PHYS_PATH=()
declare -A POOL_VDEV_PARENT=()
declare -A POOL_HV_ATTACHMENT_KEY=()

# ------------------------------------------------------------
# Build Linux SCSI device lookup
# ------------------------------------------------------------

declare -A SCSI_HOST=()
declare -A SCSI_LUN=()
declare -A SCSI_WWID=()
declare -A SCSI_VMBUS_GUID=()

# SCSI VPD Page 0x83
declare -A SCSI_VPD83_T10=()
declare -A SCSI_VPD83_NAA=()
declare -A SCSI_VPD83_STATUS=()
declare -A SCSI_VPD83_RAW_SHA=()

for sysdev in /sys/block/sd*; do
    [[ -e "$sysdev/device" ]] || continue

    dev="${sysdev##*/}"
    device_path="$(readlink -f "$sysdev/device" 2>/dev/null || true)"
    scsi_address="${device_path##*/}"

    [[ "$scsi_address" =~ ^([0-9]+):[0-9]+:[0-9]+:([0-9]+)$ ]] || continue

    host="${BASH_REMATCH[1]}"
    lun="${BASH_REMATCH[2]}"
    wwid="$(cat "$sysdev/device/wwid" 2>/dev/null || true)"

    vmbus_guid=""
    if [[ "$device_path" =~ VMBUS:00/([[:xdigit:]-]+)/host ]]; then
        vmbus_guid="${BASH_REMATCH[1],,}"
    fi

    SCSI_HOST["$dev"]="$host"
    SCSI_LUN["$dev"]="$lun"
    SCSI_WWID["$dev"]="${wwid#naa.}"
    SCSI_VMBUS_GUID["$dev"]="$vmbus_guid"

    # ----------------------------------------------------------
    # Read SCSI VPD Page 0x83
    # ----------------------------------------------------------

    vpd_file="$sysdev/device/vpd_pg83"

    vpd_hex=""
    t10_id=""
    naa_id=""
    vpd_status="MISSING"

    if [[ -r "$vpd_file" ]]; then

        if vpd_hex="$(
            od -An -v -tx1 "$vpd_file" 2>/dev/null |
                tr -d '[:space:]'
        )" && [[ -n "$vpd_hex" ]]; then

            vpd_hex="${vpd_hex,,}"

            if [[ "$vpd_hex" =~ ^0083([0-9a-f]{4}) ]]; then

                page_len=$((16#${BASH_REMATCH[1]}))
                total_bytes=$((4 + page_len))
                total_hex_len=$((total_bytes * 2))

                if ((${#vpd_hex} >= total_hex_len)); then

                    offset=8
                    valid=1

                    while ((offset / 2 + 4 <= total_bytes)); do

                        desc_byte1=$((16#${vpd_hex:$((offset + 2)):2}))
                        desc_len=$((16#${vpd_hex:$((offset + 6)):2}))

                        desc_type=$((desc_byte1 & 15))
                        desc_assoc=$(((desc_byte1 >> 4) & 3))

                        desc_total_chars=$(((4 + desc_len) * 2))

                        if ((offset + desc_total_chars > total_hex_len)); then
                            valid=0
                            break
                        fi

                        # T10 Vendor ID descriptor:
                        # Association = Logical Unit
                        # Length = 24
                        # Vendor ID = MSFT
                        if ((desc_assoc == 0 && \
                            desc_type == 1 && \
                            desc_len == 24)); then

                            vendor_hex="${vpd_hex:$((offset + 8)):16}"

                            if [[ "$vendor_hex" == "4d53465420202020" ]]; then
                                t10_id="${vpd_hex:$((offset + 24)):32}"
                            fi

                        # NAA descriptor:
                        # Association = Logical Unit
                        # Designator type = 3
                        # Length = 16
                        elif ((desc_assoc == 0 && \
                            desc_type == 3 && \
                            desc_len == 16)); then

                            naa_id="${vpd_hex:$((offset + 8)):32}"
                        fi

                        offset=$((offset + desc_total_chars))
                    done

                    if ((valid == 1)); then
                        if [[ -n "$t10_id" || -n "$naa_id" ]]; then
                            vpd_status="OK"
                        else
                            vpd_status="NO_MATCHING_DESIGNATOR"
                        fi
                    else
                        vpd_status="INVALID_DESCRIPTOR"
                    fi

                else
                    vpd_status="TRUNCATED"
                fi

            else
                vpd_status="INVALID_HEADER"
            fi
        else
            vpd_status="READ_ERROR"
        fi
    fi

    SCSI_VPD83_T10["$dev"]="$t10_id"
    SCSI_VPD83_NAA["$dev"]="$naa_id"
    SCSI_VPD83_STATUS["$dev"]="$vpd_status"
    SCSI_VPD83_RAW_SHA["$dev"]="$(sha256sum "$vpd_file" 2>/dev/null | awk '{print $1}')"

done

# ------------------------------------------------------------
# Display Linux SCSI VPD Page 0x83
# ------------------------------------------------------------

section "Linux SCSI VPD Page 0x83"

printf '%-8s %-22s %-38s %-12s\n' \
    "DEVICE" "STATUS" "T10 PAGE83 DATA" "NAA"

for dev in "${!SCSI_HOST[@]}"; do

    printf '%-8s %-22s %-38s %-12s\n' \
        "/dev/$dev" \
        "${SCSI_VPD83_STATUS[$dev]-UNKNOWN}" \
        "${SCSI_VPD83_T10[$dev]:-unknown}" \
        "${SCSI_VPD83_NAA[$dev]:-unknown}"

done

# ------------------------------------------------------------
# Scan all ZFS pools
# ------------------------------------------------------------

if ! command -v zpool >/dev/null 2>&1; then
    warn "找不到 zpool command。"
else
    info "Scanning all ZFS pools..."

    if mapfile -t ZPOOL_NAMES < <(zpool list -H -o name 2>/dev/null); then
        :
    else
        warn "無法取得 ZFS pool 清單。"
    fi

    if [[ ${#ZPOOL_NAMES[@]} -eq 0 ]]; then
        warn "目前沒有找到任何 ZFS pool。"
    else
        printf '\n'
        printf '%-5s %-20s\n' "NO." "POOL"

        for i in "${!ZPOOL_NAMES[@]}"; do
            printf '%-5s %-20s\n' "$((i + 1))" "${ZPOOL_NAMES[$i]}"
        done

        section "ZFS pool → VHDX mapping"

        for pool in "${ZPOOL_NAMES[@]}"; do
            echo
            info "Analyzing pool: $pool"

            # Pool-level mapping aggregation.
            pool_vdev_count=0
            pool_mapped_count=0
            pool_verified_count=0
            pool_status="CANDIDATE"
            pool_vdev_paths=""
            declare -A pool_vhdx_paths=()
            declare -A pool_hv_attachment_keys=()

            zdb_output="$(sudo zdb -C "$pool" 2>&1)"
            zdb_rc=$?

            if [[ "$zdb_rc" -ne 0 ]]; then
                warn "無法讀取 $pool 的 ZFS configuration。"
                POOL_STATUS["$pool"]="UNKNOWN"
                POOL_VDEV_COUNT["$pool"]=0
                POOL_MAPPED_COUNT["$pool"]=0
                POOL_VERIFIED_COUNT["$pool"]=0
                POOL_VHDX_PATH["$pool"]=""
                POOL_HEALTH["$pool"]="UNKNOWN"
                POOL_GUID["$pool"]=""
                POOL_VDEV_PATHS["$pool"]=""
                POOL_HV_ATTACHMENT_KEY["$pool"]=""
                continue
            fi

            pool_guid="$(printf '%s\n' "$zdb_output" | sed -n 's/^[[:space:]]*pool_guid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"

            while IFS= read -r line; do
                [[ "$line" =~ ^[[:space:]]*path:[[:space:]]*\'([^\'\"]+)\' ]] || continue
                vdev_path="${BASH_REMATCH[1]}"
                pool_vdev_paths+="${vdev_path}"$'\n'

                ((pool_vdev_count += 1))

                if [[ ! "$vdev_path" =~ ^/dev/ ]]; then
                    warn "$pool: 不支援的 vdev 路徑: $vdev_path"
                    pool_status="UNKNOWN"
                    continue
                fi

                vdev_name="${vdev_path##*/}"
                parent_name="$(lsblk -ndo PKNAME "$vdev_path" 2>/dev/null | head -n 1)"

                if [[ -z "$parent_name" ]]; then
                    warn "$pool: 無法辨識 vdev parent: $vdev_path"
                    pool_status="UNKNOWN"
                    continue
                fi

                # Extract metadata only from the current vdev stanza.
                vdev_block="$(
                    awk \
                        -v target="$vdev_path" \
                        -v quote="'" '
                        function indent(s, t) {
                            t = s
                            sub(/[^ ].*$/, "", t)
                            return length(t)
                        }

                        {
                            current_indent = indent($0)

                            # Leave the current vdev when reaching
                            # its parent-level boundary.
                            if (active &&
                                current_indent <= base_indent - 4 &&
                                $0 ~ /[^[:space:]]/) {
                                exit
                            }

                            if (!active && index($0, "path:")) {
                                value = $0
                                sub(/^.*path:[[:space:]]*/, "", value)
                                sub(/[[:space:]]*$/, "", value)

                                if (substr(value, 1, 1) == quote) {
                                    sub("^" quote, "", value)
                                    sub(quote ".*$", "", value)

                                    if (value == target) {
                                        active = 1
                                        base_indent = current_indent
                                    }
                                }
                            }

                            if (active) {
                                print
                            }
                        }
                    ' <<<"$zdb_output"
                )"

                devid=""
                phys_path=""

                while IFS= read -r detail; do
                    if [[ "$detail" =~ devid:[[:space:]]*\'([^\'\"]+)\' ]]; then
                        devid="${BASH_REMATCH[1]}"
                    elif [[ "$detail" =~ phys_path:[[:space:]]*\'([^\'\"]+)\' ]]; then
                        phys_path="${BASH_REMATCH[1]}"
                    fi
                done <<<"$vdev_block"

                # Preserve the exact ZFS phys_path and Linux parent identity
                # from discovery so the destroy gate can revalidate both.
                POOL_VDEV_PHYS_PATH["$pool|$vdev_path"]="$phys_path"
                POOL_VDEV_PARENT["$pool|$vdev_path"]="$parent_name"

                devid_wwid=""

                if [[ "$devid" =~ ^scsi-3([[:xdigit:]]+)(-part[0-9]+)?$ ]]; then
                    devid_wwid="${BASH_REMATCH[1],,}"
                fi

                linux_wwid="${SCSI_WWID[$parent_name]-}"
                linux_host="${SCSI_HOST[$parent_name]-}"
                linux_lun="${SCSI_LUN[$parent_name]-}"
                linux_guid="${SCSI_VMBUS_GUID[$parent_name]-}"

                printf '  ZFS vdev       : %s\n' "$vdev_path"
                printf '  Parent device  : /dev/%s\n' "$parent_name"
                printf '  ZFS devid      : %s\n' "${devid:-unknown}"
                printf '  ZFS phys_path  : %s\n' "${phys_path:-unknown}"
                printf '  Linux WWID     : %s\n' "${linux_wwid:-unknown}"
                printf '  Linux VMBUS    : %s\n' "${linux_guid:-unknown}"
                printf '  Linux LUN      : %s\n' "${linux_lun:-unknown}"
                printf '  Linux SCSI Host: %s\n' "${linux_host:-unknown}"

                if [[ -z "$devid_wwid" || -z "$linux_wwid" ||
                    "$devid_wwid" != "$linux_wwid" ]]; then
                    warn "$pool: ZFS devid 與 Linux WWID 不一致。"
                    pool_status="UNKNOWN"
                    continue
                fi

                # Normalize GUID: Linux uses hyphens, ZFS phys_path does not.
                linux_guid_compact="${linux_guid//-/}"
                phys_path_lower="${phys_path,,}"

                phys_guid=""
                phys_lun=""

                if [[ "$phys_path_lower" =~ vmbus-[[:xdigit:]]+-lun-([0-9]+)$ ]]; then
                    phys_lun="${BASH_REMATCH[1]}"
                fi

                if [[ "$phys_path_lower" =~ vmbus-([[:xdigit:]]+)-lun-[0-9]+$ ]]; then
                    phys_guid="${BASH_REMATCH[1]}"
                fi

                if [[ -z "$linux_lun" || -z "$linux_guid_compact" ||
                    "$phys_guid" != "$linux_guid_compact" ||
                    "$phys_lun" != "$linux_lun" ]]; then
                    warn "$pool: ZFS phys_path 與 Linux VMBUS/LUN 不一致。"
                    pool_status="UNKNOWN"
                    continue
                fi

                info "$pool: VMBUS GUID and LUN matched."

                # Resolve by the actual SCSI Page 83 identity across every
                # active Hyper-V ADD path. Controller/Attachment numbers are
                # historical metadata and are not assumed to equal Host/LUN.
                linux_t10="${SCSI_VPD83_T10[$parent_name]-}"
                matched_attachment=""
                matched_attachment_key=""
                vhdx_path=""

                if find_vhdx_by_page83 "$linux_t10"; then
                    vhdx_path="$PAGE83_MATCH_PATH"
                    matched_attachment_key="$PAGE83_MATCH_KEY"
                    matched_attachment="${matched_attachment_key#*:}"
                    [[ -n "$matched_attachment_key" ]] && \
                        pool_hv_attachment_keys["$matched_attachment_key"]=1
                    ((pool_verified_count += 1))
                    info "$pool: VHDX Page 83 exactly matches Linux T10 Page 83."
                else
                    mapping_rc=$?
                    if [[ "$mapping_rc" -eq 2 ]]; then
                        warn "$pool: 多個不同 VHDX 的 Page 83 同時匹配此 SCSI 裝置；映射不唯一。"
                    else
                        warn "$pool: 所有 Hyper-V ADD VHDX 中都找不到相符的 Page 83。"
                    fi
                    pool_status="UNKNOWN"
                    continue
                fi

                printf '  Hyper-V attachment key: %s (supplemental)\n' \
                    "${matched_attachment_key:-MULTIPLE/UNKNOWN}"
                printf '  VHDX path             : %s\n' "$vhdx_path"
                info "$pool: VHDX mapping verified by Page 83 identity."

                ((pool_mapped_count += 1))
                pool_vhdx_paths["$vhdx_path"]=1

            done <<<"$zdb_output"
            # Finalize pool-level mapping status.
            if ((pool_vdev_count == 0)); then
                pool_status="UNKNOWN"
                warn "$pool: 找不到任何可辨識的 vdev path。"

            elif [[ "$pool_status" == "UNKNOWN" ]]; then
                :
            elif ((pool_mapped_count != pool_vdev_count)); then
                pool_status="UNKNOWN"
            elif ((${#pool_vhdx_paths[@]} > 1)); then
                pool_status="AMBIGUOUS"
            elif ((pool_verified_count == pool_vdev_count)); then
                pool_status="VERIFIED"
            elif ((${#pool_vhdx_paths[@]} == 1)); then
                pool_status="CANDIDATE"
            else
                pool_status="UNKNOWN"
            fi

            pool_path_summary=""
            if ((${#pool_vhdx_paths[@]} == 1)); then
                for vhdx_path in "${!pool_vhdx_paths[@]}"; do
                    pool_path_summary="$vhdx_path"
                done
            fi

            POOL_STATUS["$pool"]="$pool_status"
            POOL_VDEV_COUNT["$pool"]="$pool_vdev_count"
            POOL_MAPPED_COUNT["$pool"]="$pool_mapped_count"
            POOL_VERIFIED_COUNT["$pool"]="$pool_verified_count"
            POOL_VHDX_PATH["$pool"]="$pool_path_summary"
            POOL_GUID["$pool"]="$pool_guid"
            POOL_VDEV_PATHS["$pool"]="$pool_vdev_paths"
            POOL_HV_ATTACHMENT_KEY["$pool"]=""
            if ((${#pool_hv_attachment_keys[@]} == 1)); then
                for attachment_key in "${!pool_hv_attachment_keys[@]}"; do
                    POOL_HV_ATTACHMENT_KEY["$pool"]="$attachment_key"
                done
            fi
            POOL_HEALTH["$pool"]="$(zpool list -H -o health "$pool" 2>/dev/null | head -n 1)"
            [[ -n "${POOL_HEALTH[$pool]}" ]] || POOL_HEALTH["$pool"]="UNKNOWN"

            echo
            info "Pool mapping summary: $pool"
            printf '  Vdev count      : %s\n' "$pool_vdev_count"
            printf '  Mapped count    : %s\n' "$pool_mapped_count"
            printf '  Page83 verified : %s\n' "$pool_verified_count"
            printf '  Mapping status  : %s\n' "$pool_status"

            if ((${#pool_vhdx_paths[@]} == 1)); then
                for vhdx_path in "${!pool_vhdx_paths[@]}"; do
                    printf '  VHDX path      : %s\n' "$vhdx_path"
                done
            elif ((${#pool_vhdx_paths[@]} > 1)); then
                warn "$pool: vdev 對應到多個不同的 VHDX。"
                for vhdx_path in "${!pool_vhdx_paths[@]}"; do
                    printf '    - %s\n' "$vhdx_path"
                done
            fi
        done
    fi
fi

fi # end normal discovery; --self-test skips all host discovery

show_wsl_conf_preview() {
    local selected_vhdx="${1-}"
    local mode="${2-}"
    local conf="${WSL_CONF_TEST_FILE:-/etc/wsl.conf}"

    section "/etc/wsl.conf: strict mount-argument and shell-chain safety"
    info "/etc/wsl.conf is supplemental metadata only; it is not the VHDX inventory or mapping source."
    if [[ "$mode" == "--apply" ]]; then
        info "將只移除安全解析確認的目標 --vhd 命令；其他設定保持不變。"
    else
        info "目前為唯讀預覽；不會修改設定檔。"
    fi

    if [[ -z "$selected_vhdx" ]]; then
        warn "沒有唯一的目標 VHDX，無法安全比對 boot command。"
        return 0
    fi

    if [[ ! -f "$conf" ]]; then
        warn "$conf 不存在；沒有可預覽的 boot command。"
        return 0
    fi

    local perl_program
    perl_program=$(cat <<'PERL'
use strict;
use warnings;

my ($file, $target_vhdx) = @ARGV;

open my $fh, '<', $file or die "Cannot open $file: $!";
local $/;
my $content = <$fh>;
close $fh;

# Extract only the [boot] section. Other sections remain out of scope.
my $boot = '';
my $boot_start = -1;
if ($content =~ /^\[boot\][ \t]*\r?\n(.*?)(?=^\[|\z)/ms) {
    $boot = $1;
    $boot_start = $-[1];
} else {
    print "[INFO] [boot] section not found; no boot command to remove.\n";
    exit 0;
}

# Read the boot command value and remove shell line continuations.
if ($boot !~ /^\s*command\s*=\s*(["\x27]?)(.*?)\1\s*$/sm) {
    print "[INFO] [boot] command not found; no boot command to remove.\n";
    exit 0;
}

my $raw_command = $2;
my $command_start = $-[2];
my $command_end = $+[2];
my $command = $raw_command;
$command =~ s/\\\r?\n/ /g;

print "=== Original command content ===\n$command\n";

# Split shell command chains only outside quotes. Keep the original operator
# so the preview does not silently turn '&&' into another shell operation.
my (@commands, @operators);
my ($current, $quote) = ('', '');
my $parse_safe = 1;
my @parse_reasons;
for (my $i = 0; $i < length($command); ) {
    my $ch = substr($command, $i, 1);

    if ($ch eq '\\' && $quote ne "'") {
        if ($i + 1 >= length($command)) {
            $parse_safe = 0;
            push @parse_reasons, 'Trailing escape character';
            $current .= $ch;
            $i++;
            next;
        }
        my $next = substr($command, $i + 1, 1);
        $current .= $ch . $next;
        $i += 2;
        next;
    }

    if ($ch eq '"' || $ch eq "'") {
        if ($quote eq '') {
            $quote = $ch;
        } elsif ($quote eq $ch) {
            $quote = '';
        }
        $current .= $ch;
        $i++;
        next;
    }

    if ($quote eq '') {
        my $two = substr($command, $i, 2);
        if ($two eq '&&' || $two eq '||') {
            $current =~ s/^\s+|\s+$//g;
            if (!length $current) {
                $parse_safe = 0;
                push @parse_reasons, 'Empty command before chain operator';
            }
            push @commands, $current;
            push @operators, $two;
            $current = '';
            $i += 2;
            next;
        }
        if ($ch eq ';') {
            $current =~ s/^\s+|\s+$//g;
            if (!length $current) {
                $parse_safe = 0;
                push @parse_reasons, 'Empty command before semicolon';
            }
            push @commands, $current;
            push @operators, ';';
            $current = '';
            $i++;
            next;
        }
        # These shell constructs are outside the deliberately small grammar
        # supported by this preview parser. Detect, then refuse reconstruction.
        if ($ch eq '|' || $ch eq '(' || $ch eq ')' || $ch eq '<' || $ch eq '>' || $ch eq '&') {
            $parse_safe = 0;
            push @parse_reasons, "Unsupported shell syntax: $ch";
        }
    }

    $current .= $ch;
    $i++;
}
if ($quote ne '') {
    $parse_safe = 0;
    push @parse_reasons, 'Unclosed quote';
}
# Command substitution remains active inside double quotes in POSIX shells;
# do not claim that a simple quote-aware split can safely preserve it.
if ($command =~ /`|\$\(/) {
    $parse_safe = 0;
    push @parse_reasons, 'Command substitution detected';
}
$current =~ s/^\s+|\s+$//g;
if (length $current) {
    push @commands, $current;
} elsif (@operators) {
    $parse_safe = 0;
    push @parse_reasons, 'Trailing shell chain operator';
}

print "\n=== Parsed commands ===\n";
for my $i (0 .. $#commands) {
    print "\nCommand " . ($i + 1) . ":\n$commands[$i]\n";
}

# Normalize Windows paths for case-insensitive exact-path comparison.
sub normalize_path {
    my ($value) = @_;
    $value = lc($value // '');
    $value =~ s/^\\\\\?\\//;
    $value =~ tr{\\}{/};
    $value =~ s{/+}{/}g;
    $value =~ s{/$}{} unless $value =~ m{^[a-z]:/$};
    return $value;
}

# Extract the argument immediately following --vhd. Do not match a path that
# merely appears elsewhere in the command. Quoted and unquoted arguments are
# supported; --vhd=PATH is intentionally not accepted by this conservative parser.
sub vhd_argument {
    my ($cmd) = @_;
    if ($cmd =~ /(?:^|\s)--vhd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))/i) {
        return defined $1 ? $1 : defined $2 ? $2 : $3;
    }
    return undef;
}

my $target_norm = normalize_path($target_vhdx);
my (@remove, @keep, @remove_indices);
my $match_count = 0;

for my $idx (0 .. $#commands) {
    my $cmd = $commands[$idx];
    my $candidate = $cmd;

    # Accept either a direct WSL invocation, or the known PowerShell wrapper
    # form where -Command contains exactly one WSL invocation. A compound
    # PowerShell script must never be removed as though it were only a mount.
    if ($cmd =~ /^\s*[^\s]*powershell(?:\.exe)?\s+.*?\-Command\s+"(wsl(?:\.exe)?\s+[^"`]*)"\s*$/i) {
        $candidate = $1;
    } elsif ($cmd =~ /powershell(?:\.exe)?/i) {
        $candidate = '';
    }

    my $has_wsl = ($candidate =~ /^\s*wsl(?:\.exe)?(?=$|\s)/i) ? 1 : 0;
    my $has_mount = ($candidate =~ /(?:^|\s)--mount(?:\s|$)/i) ? 1 : 0;
    my $arg = vhd_argument($candidate);
    my $arg_norm = defined $arg ? normalize_path($arg) : '';

    if ($has_wsl && $has_mount && length($target_norm) &&
        length($arg_norm) && $arg_norm eq $target_norm) {
        push @remove, $cmd;
        push @remove_indices, $idx;
        $match_count++;
    } else {
        push @keep, $cmd;
    }
}

print "\n=== Planned removal (preview only) ===\n";
if (@remove) {
    for my $i (0 .. $#remove) {
        print "Remove command " . ($i + 1) . ":\n$remove[$i]\n";
    }
} else {
    print "[NONE] No exact '--vhd <target-path>' mount command matched the selected VHDX.\n";
}

print "\n=== Commands to preserve ===\n";
if (@keep) {
    my %removed_index = map { $_ => 1 } @remove_indices;
    my $n = 0;
    for my $idx (0 .. $#commands) {
        next if $removed_index{$idx};
        print "Keep command " . (++$n) . ":\n$commands[$idx]\n";
    }
} else {
    print "[EMPTY] No other boot commands remain.\n";
}

print "\n=== Rebuilt command preview ===\n";
my $rebuild_safe = $parse_safe ? 1 : 0;
if (@remove && $rebuild_safe) {
    # Removing only a trailing suffix leaves the surviving command chain and
    # its original operators unchanged. Removing a leading/middle command can
    # alter && / || control flow, so refuse to synthesize a replacement.
    my $first_removed = $remove_indices[0];
    for my $idx ($first_removed .. $#commands) {
        my $is_removed = 0;
        for my $removed_idx (@remove_indices) {
            if ($idx == $removed_idx) { $is_removed = 1; last; }
        }
        if (!$is_removed) { $rebuild_safe = 0; last; }
    }
}

if (!@remove) {
    print "[UNCHANGED] No matching command; original command remains unchanged.\n";
} elsif (!$rebuild_safe) {
    if (!$parse_safe) {
        print "[BLOCKED] Command syntax is outside the supported conservative parser grammar.\n";
        for my $reason (@parse_reasons) {
            print "[BLOCKED] $reason\n";
        }
    } else {
        print "[BLOCKED] Matching command is not a trailing command-chain suffix.\n";
        print "[BLOCKED] Automatic rebuild refused to avoid changing shell operator semantics.\n";
    }
    print "[BLOCKED] Manual review is required before any future configuration edit.\n";
} elsif (@keep) {
    # Since only a trailing suffix is removed, all retained operators are the
    # original operators between the retained adjacent commands.
    for my $i (0 .. $#keep) {
        print $keep[$i];
        print " " . $operators[$i] . " \\
    " if $i < $#keep;
    }
    print "\n";
} else {
    print "[EMPTY] All boot commands matched the selected VHDX; command value would be removed.\n";
}

print "\n=== Summary ===\n";
print "Matched mount commands : $match_count\n";
print "Commands preserved     : " . scalar(@keep) . "\n";
print "Commands removed       : " . scalar(@remove) . "\n";
print "Parser safety          : " . ($parse_safe ? 'SUPPORTED' : 'BLOCKED') . "\n";

if ($match_count > 0) {
    require POSIX;
    my $stamp = POSIX::strftime("%Y%m%d-%H%M%S", localtime);
    my $backup = "$file.bak.$stamp";
    print "\n=== Backup / recovery plan (not executed) ===\n";
    print "Planned backup path : $backup\n";
    print "Planned restore     : sudo cp -a '$backup' '$file'\n";
    print "Write strategy      : create temporary file, validate, then atomic replace\n";
} else {
    print "\n=== Backup / recovery plan ===\n";
    print "[NONE] No matching command; no configuration edit or backup is planned.\n";
}

if (($ENV{WSL_CONF_APPLY} // '0') eq '1') {
    if (!@remove) {
        print "[UNCHANGED] No exact target mount command; /etc/wsl.conf was not modified.\n";
        exit 0;
    }
    if (!$rebuild_safe) {
        print "[BLOCKED] Unsafe command structure; /etc/wsl.conf was not modified.\n";
        exit 3;
    }

    my $rebuilt = '';
    for my $i (0 .. $#keep) {
        $rebuilt .= $keep[$i];
        $rebuilt .= " " . $operators[$i] . " \\
    " if $i < $#keep;
    }

    my $new_content = $content;
    substr($new_content, $boot_start + $command_start,
           $command_end - $command_start) = $rebuilt;

    require File::Basename;
    require File::Copy;
    require File::Temp;
    require POSIX;
    my @st = stat($file);
    die "Cannot stat $file: $!" unless @st;
    my $stamp = POSIX::strftime("%Y%m%d-%H%M%S", localtime);
    my $backup = "$file.bak.$stamp.$$";
    File::Copy::copy($file, $backup) or die "Backup failed ($backup): $!";
    chmod($st[2] & 07777, $backup) or die "Cannot preserve backup mode: $!";
    chown($st[4], $st[5], $backup) or die "Cannot preserve backup owner: $!";

    my $dir = File::Basename::dirname($file);
    my ($tmpfh, $tmpfile) = File::Temp::tempfile('.wsl.conf.tmp.XXXXXX', DIR => $dir, UNLINK => 0);
    binmode($tmpfh);
    print {$tmpfh} $new_content or die "Cannot write temporary config: $!";
    close($tmpfh) or die "Cannot close temporary config: $!";
    chmod($st[2] & 07777, $tmpfile) or die "Cannot preserve temp mode: $!";
    chown($st[4], $st[5], $tmpfile) or die "Cannot preserve temp owner: $!";
    rename($tmpfile, $file) or do { unlink($tmpfile); die "Atomic replace failed: $!"; };

    print "[PASS] /etc/wsl.conf updated atomically.\n";
    print "[INFO] Backup: $backup\n";
    print "[INFO] Removed exact target --vhd command(s): $match_count\n";
    print "[INFO] Preserved other boot command(s): " . scalar(@keep) . "\n";
} else {
    print "[INFO] This is a read-only preview; /etc/wsl.conf was not changed.\n";
}
PERL
)
    local apply_env=0
    [[ "$mode" == "--apply" ]] && apply_env=1
    if ((apply_env)) && [[ "$conf" == "/etc/wsl.conf" ]]; then
        printf '%s\n' "$perl_program" | sudo env WSL_CONF_APPLY=1 perl -0777 - "$conf" "$selected_vhdx"
    else
        printf '%s\n' "$perl_program" | env WSL_CONF_APPLY="$apply_env" perl -0777 - "$conf" "$selected_vhdx"
    fi
}

# ------------------------------------------------------------
# Parser self-tests. Uses temporary config files only; never reads or writes
# the real /etc/wsl.conf and never performs host discovery.
# ------------------------------------------------------------
run_parser_self_tests() {
    local tmpdir target output failures=0 total=0
    target='D:/Wsl/disk/wsl-pve.vhdx'
    tmpdir="$(mktemp -d)" || {
        printf '[FAIL] Unable to create temporary test directory.\n' >&2
        return 1
    }
    trap 'rm -rf "$tmpdir"' RETURN

    run_case() {
        local name="$1" command="$2" expected="$3" detail="$4"
        local config="$tmpdir/case-$((total + 1)).conf"
        total=$((total + 1))
        printf '[boot]\ncommand = %s\n' "$command" > "$config"
        output="$(WSL_CONF_TEST_FILE="$config" show_wsl_conf_preview "$target" 2>&1)"
        if printf '%s\n' "$output" | grep -Fq -- "$expected" &&
           { [[ -z "$detail" ]] || printf '%s\n' "$output" | grep -Fq -- "$detail"; }; then
            printf '[PASS] %s\n' "$name"
        else
            printf '[FAIL] %s\n' "$name"
            printf '       Expected: %s\n' "$expected"
            [[ -z "$detail" ]] || printf '       Also expected: %s\n' "$detail"
            printf '%s\n' "$output" | sed 's/^/       /'
            failures=$((failures + 1))
        fi
    }

    section "V6 parser self-test (temporary files only)"
    info "Real /etc/wsl.conf will not be read or modified."
    info "Windows, SCSI and ZFS discovery are skipped."

    run_case \
        'A: target mount command in the middle must be BLOCKED' \
        '/usr/local/bin/fix-pve-hosts.sh && powershell.exe -Command "wsl -d pve --mount --vhd D:/Wsl/disk/wsl-pve.vhdx --bare" && /usr/local/bin/another-script.sh' \
        '[BLOCKED] Matching command is not a trailing command-chain suffix.' \
        'Parser safety          : SUPPORTED'

    run_case \
        'B: mixed &&, || and ; chain must be BLOCKED' \
        'command-A && powershell.exe -Command "wsl -d pve --mount --vhd D:/Wsl/disk/wsl-pve.vhdx --bare" || command-B; command-C' \
        '[BLOCKED] Matching command is not a trailing command-chain suffix.' \
        'Parser safety          : SUPPORTED'

    run_case \
        'C: compound PowerShell command must NOT be removed' \
        'powershell.exe -Command "Write-Output '\''before'\''; wsl -d pve --mount --vhd D:/Wsl/disk/wsl-pve.vhdx --bare"' \
        'Matched mount commands : 0' \
        '[NONE] No exact '\''--vhd <target-path>'\'' mount command matched'

    run_case \
        'D: target path outside the --vhd argument must NOT match' \
        'powershell.exe -Command "Write-Output D:/Wsl/disk/wsl-pve.vhdx; wsl -d pve --mount --vhd D:/Wsl/disk/other.vhdx --bare"' \
        'Matched mount commands : 0' \
        '[NONE] No exact '\''--vhd <target-path>'\'' mount command matched'

    # Apply-mode tests use temporary files only.
    local apply_conf apply_before apply_output apply_rc
    apply_conf="$tmpdir/apply-safe.conf"
    cat > "$apply_conf" <<'CONF'
[boot]
command = /usr/local/bin/fix-pve-hosts.sh && powershell.exe -Command "wsl -d pve --mount --vhd D:/Wsl/disk/wsl-pve.vhdx --bare"

[network]
hostAddressLoopback = true
CONF
    total=$((total + 1))
    apply_rc=0
    apply_output="$(WSL_CONF_TEST_FILE="$apply_conf" show_wsl_conf_preview "$target" --apply 2>&1)" || apply_rc=$?
    if [[ "$apply_rc" -eq 0 ]] &&
       grep -Fq '/usr/local/bin/fix-pve-hosts.sh' "$apply_conf" &&
       ! grep -Fqi -- '--vhd D:/Wsl/disk/wsl-pve.vhdx' "$apply_conf" &&
       grep -Fq 'hostAddressLoopback = true' "$apply_conf" &&
       printf '%s\n' "$apply_output" | grep -Fq '[PASS] /etc/wsl.conf updated atomically.' &&
       compgen -G "$apply_conf.bak.*" >/dev/null; then
        printf '[PASS] E: apply removes only the exact trailing target command and preserves other settings\n'
    else
        printf '[FAIL] E: safe apply/preserve test (rc=%s)\n' "$apply_rc"
        printf '%s\n' "$apply_output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    apply_conf="$tmpdir/apply-blocked.conf"
    cat > "$apply_conf" <<'CONF'
[boot]
command = /usr/local/bin/fix-pve-hosts.sh && powershell.exe -Command "wsl -d pve --mount --vhd D:/Wsl/disk/wsl-pve.vhdx --bare" && /usr/local/bin/after.sh
CONF
    apply_before="$(cat "$apply_conf")"
    total=$((total + 1))
    apply_rc=0
    apply_output="$(WSL_CONF_TEST_FILE="$apply_conf" show_wsl_conf_preview "$target" --apply 2>&1)" || apply_rc=$?
    if [[ "$apply_rc" -eq 3 && "$(cat "$apply_conf")" == "$apply_before" ]]; then
        printf '[PASS] F: unsafe middle command is blocked and config remains unchanged\n'
    else
        printf '[FAIL] F: blocked apply did not preserve config (rc=%s)\n' "$apply_rc"
        printf '%s\n' "$apply_output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    # Exercise the new standalone round-trip entry against a temporary file.
    # sudo/read are stubbed here; the real /etc/wsl.conf is never touched.
    local roundtrip_conf roundtrip_before roundtrip_output roundtrip_rc=0
    roundtrip_conf="$tmpdir/live-roundtrip.conf"
    cat > "$roundtrip_conf" <<'CONF'
[boot]
systemd=true
command = "/usr/local/bin/fix-pve-hosts.sh && \
/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "wsl -d pve --mount --vhd D:/Wsl/disk/wsl-pve.vhdx --bare""

[network]
generateResolvConf=false
CONF
    cp -a "$roundtrip_conf" "$roundtrip_conf.original"
    total=$((total + 1))
    roundtrip_output="$(
        CONFIG_TEST_FILE="$roundtrip_conf"
        CONFIG_TEST_BACKUP=""
        CONFIG_TEST_ACTIVE=0
        sudo() { if [[ "${1-}" == "-v" ]]; then return 0; else command "$@"; fi; }
        read() { local var="${@: -1}"; printf -v "$var" '%s' 'TEST CONFIG CLEANUP'; return 0; }
        run_config_cleanup_live_test 'D:\Wsl\disk\wsl-pve.vhdx'
    )" || roundtrip_rc=$?
    if [[ "$roundtrip_rc" -eq 0 ]] &&
       cmp -s "$roundtrip_conf.original" "$roundtrip_conf" &&
       printf '%s\n' "$roundtrip_output" | grep -Fq '[PASS] Original /etc/wsl.conf restored byte-for-byte.' &&
       printf '%s\n' "$roundtrip_output" | grep -Fq '[PASS] 設定檔 round-trip 測試完成'; then
        printf '[PASS] G: standalone config apply/verify/restore round-trip uses a temporary file only\n'
    else
        printf '[FAIL] G: standalone config round-trip (rc=%s)\n' "$roundtrip_rc"
        printf '%s\n' "$roundtrip_output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    printf '\nSelf-test summary: %d total, %d failed\n' "$total" "$failures"
    if ((failures == 0)); then
        printf '[PASS] All parser self-tests passed.\n'
        return 0
    fi
    printf '[FAIL] Parser self-tests need attention.\n'
    return 1
}

# ------------------------------------------------------------
# Interactive, read-only pool selection.
# ------------------------------------------------------------

zpool_pool_exists() {
    local wanted="$1" names rc
    names="$(zpool list -H -o name 2>/dev/null)" || return 2
    printf '%s\n' "$names" | awk -v p="$wanted" '$0 == p { found=1 } END { exit !found }'
}

refresh_known_pool_names() {
    local names rc pool
    local -a live_names=() refreshed=()
    names="$(zpool list -H -o name 2>/dev/null)" || {
        warn "無法重新查詢 ZFS pool 清單；暫時保留既有清單。"
        return 1
    }
    while IFS= read -r pool; do
        [[ -n "$pool" ]] && live_names+=("$pool")
    done <<< "$names"
    for pool in "${ZPOOL_NAMES[@]}"; do
        if printf '%s\n' "${live_names[@]}" | awk -v p="$pool" '$0 == p { found=1 } END { exit !found }'; then
            refreshed+=("$pool")
        else
            info "Pool '$pool' 已不存在，從目前選單移除。"
        fi
    done
    ZPOOL_NAMES=("${refreshed[@]}")
}

show_pool_details() {
    local pool="$1"
    local path="${POOL_VHDX_PATH[$pool]-}"

    section "Selected ZFS pool: $pool"
    printf '  Health          : %s\n' "${POOL_HEALTH[$pool]-UNKNOWN}"
    printf '  Vdev count      : %s\n' "${POOL_VDEV_COUNT[$pool]-0}"
    printf '  Mapped vdevs    : %s\n' "${POOL_MAPPED_COUNT[$pool]-0}"
    printf '  Page83 verified : %s\n' "${POOL_VERIFIED_COUNT[$pool]-0}"
    printf '  Mapping status  : %s\n' "${POOL_STATUS[$pool]-UNKNOWN}"

    if [[ -n "$path" ]]; then
        printf '  VHDX path       : %s\n' "$path"
        printf '  VHDX Page83     : %s\n' "${VHDX_PAGE83[$path]-unavailable}"
    else
        printf '  VHDX path       : (no unique mapping)\n'
    fi
    info "目前僅顯示辨識結果；不會執行卸載或銷毀操作。"
}

show_pool_storage_snapshot() {
    local pool="$1" pool_rc=0 status_rc=0

    # Never trust the discovery-time snapshot for a detail query.
    zpool_pool_exists "$pool" || pool_rc=$?
    case "$pool_rc" in
        0) ;;
        1)
            warn "Pool '$pool' 已不存在；略過 zpool status 與 zdb 查詢。"
            return 1
            ;;
        *)
            warn "無法確認 Pool '$pool' 是否存在；略過 zpool status 與 zdb 查詢。"
            return 1
            ;;
    esac

    section "ZFS status -P: $pool"
    if zpool status -P "$pool" 2>&1; then
        status_rc=0
    else
        status_rc=$?
    fi

    if ((status_rc != 0)); then
        # The pool may have disappeared between the existence check and
        # zpool status. Recheck and, importantly, never run zdb on a stale pool.
        pool_rc=0
        zpool_pool_exists "$pool" || pool_rc=$?
        case "$pool_rc" in
            1)
                warn "Pool '$pool' 已不存在（可能剛完成 Destroy）；略過 zdb 查詢。"
                ;;
            0)
                warn "Pool '$pool' 仍列於 zpool list，但 zpool status 讀取失敗；略過 zdb 查詢。"
                ;;
            *)
                warn "無法重新確認 Pool '$pool' 狀態；略過 zdb 查詢。"
                ;;
        esac
        return 1
    fi

    section "ZFS configuration (zdb -C): $pool"
    if ! sudo zdb -C "$pool" 2>&1; then
        warn "無法讀取 $pool 的 zdb configuration。"
        return 1
    fi
    return 0
}

run_pool_detail_mock_tests() {
    local output rc
    local calls=0 zdb_called=0
    local total=0 failures=0

    section "Pool detail stale-state mock tests (no real ZFS operations)"

    # Case 1: pool is already absent when the detail action starts.
    total=$((total + 1))
    rc=0
    output="$(
        {
        zpool() {
            if [[ "$*" == "list -H -o name" ]]; then return 0; fi
            printf 'UNEXPECTED_ZPOOL_CALL=%s\n' "$*"
            return 1
        }
        sudo() { printf 'UNEXPECTED_ZDB_CALL\n'; return 1; }
        show_pool_storage_snapshot mockpool
        } 2>&1
    )" || rc=$?
    rc=${rc:-0}
    if [[ "$rc" -ne 0 ]] &&
       printf '%s\n' "$output" | grep -Fq "Pool 'mockpool' 已不存在" &&
       ! printf '%s\n' "$output" | grep -Fq 'ZFS status -P:' &&
       ! printf '%s\n' "$output" | grep -Fq 'UNEXPECTED_ZDB_CALL'; then
        printf '[PASS] A: already-destroyed pool is rejected before status/zdb queries\n'
    else
        printf '[FAIL] A: stale pool was not safely rejected (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    # Case 2: pool is listed but status fails; never fall through to zdb.
    total=$((total + 1))
    rc=0
    output="$(
        {
        zpool() {
            case "$*" in
                'list -H -o name') printf 'mockpool\n'; return 0 ;;
                'status -P mockpool') return 1 ;;
                *) return 1 ;;
            esac
        }
        sudo() { printf 'UNEXPECTED_ZDB_CALL\n'; return 1; }
        show_pool_storage_snapshot mockpool
        } 2>&1
    )" || rc=$?
    if [[ "$rc" -ne 0 ]] &&
       printf '%s\n' "$output" | grep -Fq "Pool 'mockpool' 仍列於 zpool list" &&
       ! printf '%s\n' "$output" | grep -Fq 'UNEXPECTED_ZDB_CALL'; then
        printf '[PASS] B: zpool status failure prevents zdb invocation\n'
    else
        printf '[FAIL] B: status failure incorrectly continued or was misclassified (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    printf '\nPool detail mock summary: %d total, %d failed\n' "$total" "$failures"
    ((failures == 0))
}

preview_selected_pool() {
    local pool="$1"
    local path="${POOL_VHDX_PATH[$pool]-}"

    section "Read-only destroy preview: $pool"
    printf 'Pool              : %s\n' "$pool"
    printf 'Health            : %s\n' "${POOL_HEALTH[$pool]-UNKNOWN}"
    printf 'Vdev count        : %s\n' "${POOL_VDEV_COUNT[$pool]-0}"
    printf 'Mapped vdevs      : %s\n' "${POOL_MAPPED_COUNT[$pool]-0}"
    printf 'Page83 verified   : %s\n' "${POOL_VERIFIED_COUNT[$pool]-0}"
    printf 'Mapping status    : %s\n' "${POOL_STATUS[$pool]-UNKNOWN}"
    printf 'VHDX path         : %s\n' "${path:-unknown}"

    if [[ "${POOL_STATUS[$pool]-UNKNOWN}" != "VERIFIED" ]]; then
        warn "此 pool 的 VHDX 身分尚未達到 VERIFIED。"
        warn "請勿將此結果視為可執行的 Destroy 目標。"
    else
        info "Page 83 已完成 VHDX ↔ Linux SCSI 身分比對。"
        info "這裡只顯示唯讀預覽；本預覽不會執行任何破壞性操作。"
        printf '\n預計操作對象（僅預覽）：\n'
        printf '  ZFS pool : %s\n' "$pool"
        printf '  VHDX     : %s\n' "$path"
    fi

    # Include the current vdev tree and full ZFS configuration in the preview.
    # Both commands are inspection-only; neither destroys nor unmounts anything.
    show_pool_storage_snapshot "$pool"

    # wsl.conf is displayed only as supplemental context. A target VHDX may
    # legitimately be absent from its boot command.
    show_wsl_conf_preview "$path"
}

# ------------------------------------------------------------
# Classify Hyper-V event evidence for the expected VHDX.
# Return codes: 0 = matching ADD found; 1 = explicit REMOVE only;
#               2 = unavailable/inconclusive (never a safety blocker).
# Event IDs are historical evidence, not authoritative live mount state.
# ------------------------------------------------------------
classify_hv_attachment_evidence() {
    local expected_path="$1" query_rc="$2"
    local expected_normalized key state path normalized
    local matching_add="" matching_remove=""

    ((query_rc == 0)) || return 2
    [[ -n "$expected_path" ]] || return 2

    expected_normalized="$(printf '%s' "$expected_path" | sed 's#\\#/#g' | sed -E 's#^//\?/##' | tr '[:upper:]' '[:lower:]')"

    for key in "${!HV_ATTACHMENT_STATE[@]}"; do
        state="${HV_ATTACHMENT_STATE[$key]-}"
        path="${HV_ATTACHMENT_PATH[$key]-}"
        [[ -n "$path" ]] || continue
        normalized="$(printf '%s' "$path" | sed 's#\\#/#g' | sed -E 's#^//\?/##' | tr '[:upper:]' '[:lower:]')"
        [[ "$normalized" == "$expected_normalized" ]] || continue

        case "${state^^}" in
            ADD) matching_add="$key" ;;
            REMOVE) matching_remove="$key" ;;
        esac
    done

    if [[ -n "$matching_add" ]]; then
        printf '%s\n' "$matching_add"
        return 0
    fi
    if [[ -n "$matching_remove" ]]; then
        printf '%s\n' "$matching_remove"
        return 1
    fi
    return 2
}

# ------------------------------------------------------------
# Compare the live SCSI identity with the startup snapshot.
# /dev/sdX is expected to remain stable during one script run.
# A new WSL start creates a fresh snapshot; no device re-mapping is attempted
# during an active run. The sysfs root is injectable for isolated tests.
# ------------------------------------------------------------
verify_live_scsi_snapshot() {
    local expected_parent="$1" current_parent="$2"
    local expected_wwid="$3" expected_lun="$4" expected_guid="$5"
    local expected_vpd_sha="$6" sysfs_root="${7:-/sys}"
    local sysdev device_path scsi_address live_lun live_guid live_wwid live_sha

    if [[ -z "$expected_parent" || -z "$current_parent" ||
          "$current_parent" != "$expected_parent" ]]; then
        printf '[BLOCKED] SCSI parent device name changed or unavailable (expected=%s current=%s).\n' \
            "${expected_parent:-UNKNOWN}" "${current_parent:-UNKNOWN}" >&2
        return 1
    fi

    sysdev="$sysfs_root/block/$current_parent"
    if [[ ! -e "$sysdev/device" ]]; then
        printf '[BLOCKED] %s sysfs device link is missing.\n' "$current_parent" >&2
        return 1
    fi

    device_path="$(readlink -f "$sysdev/device" 2>/dev/null || true)"
    scsi_address="${device_path##*/}"
    live_lun=""
    live_guid=""
    live_wwid=""
    live_sha=""

    if [[ "$scsi_address" =~ ^[0-9]+:[0-9]+:[0-9]+:([0-9]+)$ ]]; then
        live_lun="${BASH_REMATCH[1]}"
    fi
    if [[ "$device_path" =~ VMBUS:00/([[:xdigit:]-]+)/host ]]; then
        live_guid="${BASH_REMATCH[1],,}"
    fi

    live_wwid="$(cat "$sysdev/device/wwid" 2>/dev/null || true)"
    live_wwid="${live_wwid#naa.}"
    live_wwid="${live_wwid,,}"

    if [[ -r "$sysdev/device/vpd_pg83" ]]; then
        live_sha="$(sha256sum "$sysdev/device/vpd_pg83" 2>/dev/null | awk '{print $1}')"
    fi

    if [[ -z "$device_path" || -z "$live_lun" || -z "$live_guid" ||
          -z "$live_wwid" || -z "$live_sha" ||
          "$live_lun" != "$expected_lun" ||
          "${live_guid//-/}" != "${expected_guid//-/}" ||
          "$live_wwid" != "${expected_wwid,,}" ||
          "$live_sha" != "$expected_vpd_sha" ]]; then
        printf '[BLOCKED] %s live SCSI identity differs from the startup snapshot (name/WWID/LUN/VMBUS/Page83).\n' \
            "$current_parent" >&2
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Read-only pre-destroy safety gate. No destructive operations here.
# ------------------------------------------------------------
pre_destroy_safety_check() {
    local pool="$1" blockers=0
    local names health status_output status_rc zdb_output zdb_rc fresh_guid
    local fresh_paths="" path parent vpd_file fresh_sha
    local vhdx_path page_output page_record fresh_page83
    local expected_paths actual_paths current_count
    local expected_phys fresh_phys phys_guid phys_lun linux_guid linux_lun vdev_parent
    local expected_attachment expected_hv_path
    local hv_query_rc hv_evidence_rc hv_match_key
    local saved_key
    local local_sysdev live_device_path live_scsi_address live_guid live_lun live_wwid current_parent
    local -A saved_hv_controller=() saved_hv_state=() saved_hv_path=()

    section "Pre-destroy safety check (READ ONLY): $pool"
    info "重新讀取目前 Pool 狀態、ZFS 組態及磁碟識別資料。"
    info "本檢查不會執行 destroy、export、offline、unmount 或設定檔修改。"

    if ! command -v zpool >/dev/null 2>&1; then
        warn "找不到 zpool；安全檢查中止。"
        return 1
    fi
    names="$(zpool list -H -o name 2>/dev/null)" || {
        warn "無法重新取得 ZFS pool 清單。"
        return 1
    }
    if [[ "$(printf '%s\n' "$names" | awk -v p="$pool" '$0 == p {n++} END {print n+0}')" -ne 1 ]]; then
        warn "Pool 不存在或名稱不唯一：$pool"
        return 1
    fi

    health="$(zpool list -H -o health "$pool" 2>/dev/null | head -n 1)"
    printf 'Current pool health : %s\n' "${health:-UNKNOWN}"
    if [[ "$health" != "ONLINE" ]]; then
        warn "Pool health 不是 ONLINE。"
        blockers=$((blockers + 1))
    fi

    status_output="$(zpool status -P "$pool" 2>&1)"
    status_rc=$?
    if ((status_rc != 0)); then
        warn "重新讀取 zpool status 失敗。"
        blockers=$((blockers + 1))
    else
        printf '%s\n' "$status_output" | grep -E '^[[:space:]]*(pool:|state:|scan:|errors:)' || true
        if ! printf '%s\n' "$status_output" | grep -Eq '^[[:space:]]*state:[[:space:]]+ONLINE[[:space:]]*$'; then
            warn "zpool status 未回報 state: ONLINE。"
            blockers=$((blockers + 1))
        fi
        if printf '%s\n' "$status_output" | grep -Eiq 'scan:.*(in progress|resilvering)'; then
            warn "Pool 正在 scrub/resilver。"
            blockers=$((blockers + 1))
        fi
        if printf '%s\n' "$status_output" | grep -Eiq 'errors:.*(Permanent errors|errors found)'; then
            warn "zpool status 回報資料錯誤。"
            blockers=$((blockers + 1))
        fi
    fi

    zdb_output="$(sudo zdb -C "$pool" 2>&1)"
    zdb_rc=$?
    if ((zdb_rc != 0)); then
        warn "重新讀取 zdb -C 失敗。"
        blockers=$((blockers + 1))
    else
        fresh_guid="$(printf '%s\n' "$zdb_output" | sed -n 's/^[[:space:]]*pool_guid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
        printf 'Original pool GUID : %s\n' "${POOL_GUID[$pool]-unknown}"
        printf 'Current pool GUID  : %s\n' "${fresh_guid:-unknown}"
        if [[ -z "$fresh_guid" || "$fresh_guid" != "${POOL_GUID[$pool]-}" ]]; then
            warn "Pool GUID 與初始探索結果不同，或無法取得。"
            blockers=$((blockers + 1))
        fi
        while IFS= read -r line; do
            path="$(sed -n "s/^[[:space:]]*path:[[:space:]]*'\\([^']*\\)'.*/\\1/p" <<< "$line")"
            [[ -n "$path" ]] || continue
            fresh_paths+="${path}"$'\n'
        done <<< "$zdb_output"
        expected_paths="$(printf '%s' "${POOL_VDEV_PATHS[$pool]-}" | sed '/^$/d' | sort)"
        actual_paths="$(printf '%s' "$fresh_paths" | sed '/^$/d' | sort)"
        current_count="$(printf '%s\n' "$actual_paths" | sed '/^$/d' | wc -l | xargs)"
        printf 'Original vdev count: %s\n' "${POOL_VDEV_COUNT[$pool]-0}"
        printf 'Current vdev count : %s\n' "${current_count:-0}"
        if [[ -z "$actual_paths" || "$actual_paths" != "$expected_paths" ]]; then
            warn "目前 vdev 路徑清單與初始探索結果不同。"
            blockers=$((blockers + 1))
        fi

        # Revalidate the ZFS phys_path identity for every original vdev.
        # A matching /dev path alone is insufficient: VMBUS GUID and LUN
        # must still agree with the identity captured during discovery.
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            expected_phys="${POOL_VDEV_PHYS_PATH[$pool|$path]-}"
            vdev_parent="${POOL_VDEV_PARENT[$pool|$path]-}"
            if [[ -z "$expected_phys" || -z "$vdev_parent" ]]; then
                warn "$path：初始探索未保存 phys_path/parent identity。"
                blockers=$((blockers + 1))
                continue
            fi
            fresh_phys="$(printf '%s\n' "$zdb_output" | awk -v target="$path" '
                BEGIN { active=0; base=-1 }
                function indent(s, t) { t=s; sub(/[^ ].*$/, "", t); return length(t) }
                {
                    n=indent($0)
                    if (active && n <= base-4 && $0 ~ /[^[:space:]]/) exit
                    if (!active && $0 ~ /path:[[:space:]]*\047/) {
                        v=$0; sub(/^.*path:[[:space:]]*\047/, "", v); sub(/\047.*$/, "", v)
                        if (v == target) { active=1; base=n }
                    }
                    if (active && $0 ~ /phys_path:[[:space:]]*\047/) {
                        v=$0; sub(/^.*phys_path:[[:space:]]*\047/, "", v); sub(/\047.*$/, "", v); print v; exit
                    }
                }')"
            if [[ -z "$fresh_phys" || "$fresh_phys" != "$expected_phys" ]]; then
                warn "$path：目前 ZFS phys_path 與初始探索結果不同或缺失。"
                blockers=$((blockers + 1))
                continue
            fi
            phys_guid=""
            phys_lun=""
            if [[ "${fresh_phys,,}" =~ vmbus-([[:xdigit:]]+)-lun-([0-9]+)$ ]]; then
                phys_guid="${BASH_REMATCH[1]}"
                phys_lun="${BASH_REMATCH[2]}"
            fi

            # During one script run, the device node must remain the same as
            # the startup snapshot. WSL shutdown/start happens before a new
            # run, so a fresh run simply captures the new device name.
            current_parent="$(lsblk -ndo PKNAME "$path" 2>/dev/null | head -n 1)"
            if [[ -z "$phys_guid" || -z "$phys_lun" ]]; then
                warn "$path：ZFS phys_path 缺少有效 VMBUS GUID/LUN。"
                blockers=$((blockers + 1))
            else
                linux_guid="${SCSI_VMBUS_GUID[$vdev_parent]-}"
                linux_guid="${linux_guid//-/}"
                if [[ "$phys_guid" != "$linux_guid" ||
                      "$phys_lun" != "${SCSI_LUN[$vdev_parent]-}" ]]; then
                    warn "$path：ZFS phys_path 與啟動時記錄的 VMBUS GUID/LUN 不一致。"
                    blockers=$((blockers + 1))
                elif ! verify_live_scsi_snapshot \
                        "$vdev_parent" "$current_parent" \
                        "${SCSI_WWID[$vdev_parent]-}" \
                        "${SCSI_LUN[$vdev_parent]-}" \
                        "${SCSI_VMBUS_GUID[$vdev_parent]-}" \
                        "${SCSI_VPD83_RAW_SHA[$vdev_parent]-}"; then
                    warn "$path：裝置名稱或即時 SCSI 身分與程式啟動時快照不一致。"
                    blockers=$((blockers + 1))
                else
                    info "$path：裝置名稱、WWID、LUN、VMBUS GUID、Page 83 均與啟動時快照一致。"
                fi
            fi
        done <<< "${POOL_VDEV_PATHS[$pool]-}"
    fi

    if [[ "${POOL_STATUS[$pool]-UNKNOWN}" != "VERIFIED" ||
          "${POOL_VDEV_COUNT[$pool]-0}" -le 0 ||
          "${POOL_MAPPED_COUNT[$pool]-0}" != "${POOL_VDEV_COUNT[$pool]-0}" ||
          "${POOL_VERIFIED_COUNT[$pool]-0}" != "${POOL_VDEV_COUNT[$pool]-0}" ||
          -z "${POOL_VHDX_PATH[$pool]-}" ]]; then
        warn "初始探索並未達到完整 VERIFIED 條件。"
        blockers=$((blockers + 1))
    fi

    # Hyper-V Event 2007 is historical evidence, not a live attachment API.
    # Re-query it for diagnostics, but do not block merely because the query
    # is unavailable or the expected path is absent from the event window.
    # A matching ADD may use a different controller/attachment key after WSL
    # shutdown/restart, so match by normalized VHDX path rather than old key.
    expected_attachment="${POOL_HV_ATTACHMENT_KEY[$pool]-}"
    expected_hv_path="${POOL_VHDX_PATH[$pool]-}"
    printf '\nHyper-V Attachment event evidence (supplemental)\n'
    printf 'Original attachment key : %s\n' "${expected_attachment:-UNKNOWN}"
    printf 'Expected VHDX path      : %s\n' "${expected_hv_path:-UNKNOWN}"

    for saved_key in "${!HV_ATTACHMENT_CONTROLLER[@]}"; do
        saved_hv_controller["$saved_key"]="${HV_ATTACHMENT_CONTROLLER[$saved_key]}"
        saved_hv_state["$saved_key"]="${HV_ATTACHMENT_STATE[$saved_key]-}"
        saved_hv_path["$saved_key"]="${HV_ATTACHMENT_PATH[$saved_key]-}"
    done

    if [[ -z "$expected_hv_path" ]]; then
        warn "沒有初始 VHDX 路徑；Page83 無法建立目標，安全檢查阻擋。"
        blockers=$((blockers + 1))
    else
        if query_windows_events; then
            hv_query_rc=0
        else
            hv_query_rc=$?
        fi

        if hv_match_key="$(classify_hv_attachment_evidence "$expected_hv_path" "$hv_query_rc")"; then
            info "Hyper-V event 找到目標 VHDX 的 ADD：Attachment $hv_match_key。"
            info "Attachment 編號可因 WSL shutdown/restart 改變；以 VHDX 路徑作輔助比對。"
        else
            hv_evidence_rc=$?
            case "$hv_evidence_rc" in
                1)
                    warn "Hyper-V event 對目標 VHDX 只找到 REMOVE，未找到對應 ADD。"
                    warn "事件紀錄顯示可能已卸載；此項明確衝突，安全檢查阻擋。"
                    blockers=$((blockers + 1))
                    ;;
                *)
                    warn "Hyper-V event 查詢失敗或沒有足夠紀錄；此項僅標示 UNKNOWN，不單獨阻擋。"
                    ;;
            esac
        fi
    fi

    # Restore original discovery data for subsequent menu/detail operations.
    HV_ATTACHMENT_CONTROLLER=()
    HV_ATTACHMENT_STATE=()
    HV_ATTACHMENT_PATH=()
    for saved_key in "${!saved_hv_controller[@]}"; do
        HV_ATTACHMENT_CONTROLLER["$saved_key"]="${saved_hv_controller[$saved_key]}"
        HV_ATTACHMENT_STATE["$saved_key"]="${saved_hv_state[$saved_key]}"
        HV_ATTACHMENT_PATH["$saved_key"]="${saved_hv_path[$saved_key]}"
    done

    vhdx_path="${POOL_VHDX_PATH[$pool]-}"
    if [[ -n "$vhdx_path" ]]; then
        page_output="$(read_vhdx_page83 "$vhdx_path" 2>&1)"
        page_record="$(printf '%s\n' "$page_output" | tr -d '\r' | grep '^@@VHDX|' | tail -n 1 || true)"
        if [[ "$page_record" =~ ^@@VHDX\\|OK\\|([[:xdigit:]]{32})$ ]]; then
            fresh_page83="${BASH_REMATCH[1],,}"
            printf 'Fresh VHDX Page83  : %s\n' "$fresh_page83"
        else
            warn "無法重新讀取目標 VHDX Page 83。"
            blockers=$((blockers + 1))
            fresh_page83=""
        fi
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            parent="$(lsblk -ndo PKNAME "$path" 2>/dev/null | head -n 1)"
            if [[ -z "$parent" ]]; then
                warn "無法重新辨識 vdev parent：$path"
                blockers=$((blockers + 1))
                continue
            fi
            # Re-read the current sysfs VPD Page 0x83 bytes, not merely the
            # discovery-time parsed value. The raw digest anchors the exact
            # descriptor bytes; the T10 value below is the discovery-time
            # interpretation of those same bytes.
            vpd_file="/sys/block/$parent/device/vpd_pg83"
            if [[ ! -r "$vpd_file" ]]; then
                warn "Linux $parent 的即時 VPD Page 83 不可讀。"
                blockers=$((blockers + 1))
                continue
            fi
            fresh_sha="$(sha256sum "$vpd_file" 2>/dev/null | awk '{print $1}')"
            if [[ -z "$fresh_sha" || "$fresh_sha" != "${SCSI_VPD83_RAW_SHA[$parent]-}" ]]; then
                warn "Linux $parent 的 VPD Page 83 無法讀取或內容已變更。"
                blockers=$((blockers + 1))
                continue
            fi
            if [[ -z "$fresh_page83" || "$fresh_page83" != "${SCSI_VPD83_T10[$parent]-}" ]]; then
                warn "VHDX Page 83 與 Linux $parent T10 Page 83 不一致。"
                blockers=$((blockers + 1))
            else
                info "$path：Linux VPD 原始資料未變，且 T10 Page 83 與 VHDX 相符。"
            fi
        done <<< "${POOL_VDEV_PATHS[$pool]-}"
    fi

    printf '\n'
    if ((blockers == 0)); then
        printf '[PASS] Read-only pre-destroy safety checks passed.\n'
        info "這只代表本次唯讀檢查通過，不代表已授權或已執行 Destroy。"
        return 0
    fi
    printf '[BLOCKED] %d safety condition(s) failed.\n' "$blockers"
    info "禁止進入後續 Destroy 階段；請先調查上述項目。"
    return 1
}


# ------------------------------------------------------------
# Post-destroy cleanup: detach only the verified VHDX, then update boot config.
# A non-zero result is always reported as partial completion.
# ------------------------------------------------------------
run_wsl_unmount_elevated() {
    local vhdx_path="$1" path_b64 encoded rc
    if [[ ! -x "$PS_EXE" ]]; then
        warn "找不到 PowerShell，無法透過 UAC 重試卸載。"
        return 1
    fi
    path_b64="$(printf '%s' "$vhdx_path" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0)" || return 1
    encoded="$(cat <<PS | ps_encode
\$ErrorActionPreference = 'Stop'
\$path = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$path_b64'))
try {
    \$wsl = Join-Path \$env:WINDIR 'System32\wsl.exe'
    \$arguments = '--unmount "' + \$path + '"'
    \$process = Start-Process -FilePath \$wsl -ArgumentList \$arguments -Verb RunAs -Wait -PassThru
    Write-Output "WSL_UNMOUNT_EXIT=\$(\$process.ExitCode)"
    exit [int]\$process.ExitCode
} catch {
    Write-Error \$_
    exit 125
}
PS
)" || return 1
    # Do not capture Windows PowerShell stdout in a Bash variable: Windows
    # interop output may contain NUL bytes. Keep stderr visible and trust the
    # process exit code for success/failure.
    if "$PS_EXE" -NoProfile -EncodedCommand "$encoded" >/dev/null; then
        rc=0
    else
        rc=$?
    fi
    return "$rc"
}

detach_vhdx_from_wsl() {
    local vhdx_path="$1" rc
    local wsl_exe="${WSL_EXE:-/mnt/c/Windows/System32/wsl.exe}"

    section "Detach target VHDX from WSL"
    if [[ -z "$vhdx_path" ]]; then
        warn "目標 VHDX 路徑為空；拒絕呼叫 wsl --unmount。"
        return 1
    fi
    case "$vhdx_path" in
        [A-Za-z]:\\*|\\\\?\\[A-Za-z]:\\*) ;;
        *)
            warn "VHDX 路徑不是可辨識的 Windows 絕對路徑；拒絕卸載。"
            return 1
            ;;
    esac
    if [[ ! -x "$wsl_exe" ]]; then
        warn "找不到可執行的 wsl.exe：$wsl_exe"
        return 1
    fi

    info "只對指定 VHDX 執行 wsl.exe --unmount；不會省略 DiskPath。"
    # wsl.exe may emit NUL-containing Windows interop output. Its stdout is
    # not needed; leave stderr visible and capture only the real exit status.
    if "$wsl_exe" --unmount "$vhdx_path" >/dev/null; then
        rc=0
    else
        rc=$?
    fi
    if ((rc != 0)); then
        warn "一般權限的 wsl.exe --unmount 回傳非零（$rc）。"
        local elevate_answer=""
        read -r -p "是否透過 UAC 以管理員權限重試指定 VHDX 卸載？ [y/N] " elevate_answer || elevate_answer=""
        case "$elevate_answer" in
            y|Y|yes|YES)
                if run_wsl_unmount_elevated "$vhdx_path"; then
                    rc=0
                else
                    warn "UAC 卸載重試失敗或遭取消。"
                    return 1
                fi
                ;;
            *)
                warn "未進行 UAC 重試；VHDX detach 尚未確認。"
                return 1
                ;;
        esac
    fi
    printf '[PASS] 指定 VHDX 的 WSL unmount 命令已成功返回。\n'
    return 0
}

update_wsl_conf_for_vhdx() {
    local vhdx_path="$1" rc
    section "Update /etc/wsl.conf boot command"
    if [[ -z "$vhdx_path" ]]; then
        warn "沒有唯一的目標 VHDX；不修改 /etc/wsl.conf。"
        return 1
    fi
    show_wsl_conf_preview "$vhdx_path" --apply
    rc=$?
    if ((rc != 0)); then
        warn "/etc/wsl.conf 未能安全更新（rc=$rc）；保留原檔，需人工檢查。"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# Standalone live config round-trip test.
# Temporarily applies the real parser to /etc/wsl.conf, verifies the exact
# target mount command is gone and the required fix script remains, then
# restores the byte-for-byte backup. This path NEVER calls ZFS or wsl.exe.
# ------------------------------------------------------------
CONFIG_TEST_FILE="/etc/wsl.conf"
CONFIG_TEST_BACKUP=""
CONFIG_TEST_ACTIVE=0

restore_config_test_backup() {
    [[ "${CONFIG_TEST_ACTIVE:-0}" == "1" ]] || return 0

    section "Restore /etc/wsl.conf after isolated test"
    if sudo cp -a -- "$CONFIG_TEST_BACKUP" "$CONFIG_TEST_FILE" &&
       cmp -s -- "$CONFIG_TEST_BACKUP" "$CONFIG_TEST_FILE"; then
        CONFIG_TEST_ACTIVE=0
        printf '[PASS] Original /etc/wsl.conf restored byte-for-byte.\n'
        printf '[INFO] Safety backup retained at: %s\n' "$CONFIG_TEST_BACKUP"
        return 0
    fi

    warn "還原驗證失敗！原始備份仍保留於：$CONFIG_TEST_BACKUP"
    warn "請立即手動執行：sudo cp -a '$CONFIG_TEST_BACKUP' '$CONFIG_TEST_FILE'"
    return 1
}

run_config_cleanup_live_test() {
    local target_vhdx="$1"
    local preflight_output="" apply_output="" verify_output=""
    local rc=0 matched=0 backup_stamp=""

    section "Standalone /etc/wsl.conf cleanup round-trip test"
    info "此測試會短暫修改真實 /etc/wsl.conf，隨後立即從備份還原。"
    info "不會呼叫 zpool、wsl.exe、wsl --unmount，也不會接觸 VHDX。"

    if [[ ! -f "$CONFIG_TEST_FILE" ]]; then
        warn "$CONFIG_TEST_FILE 不存在；停止測試。"
        return 1
    fi
    if [[ -z "$target_vhdx" ]]; then
        warn "必須明確提供目標 VHDX Windows 絕對路徑。"
        return 1
    fi
    case "$target_vhdx" in
        [A-Za-z]:\\*|\\\\?\\[A-Za-z]:\\*) ;;
        *)
            warn "目標不是可辨識的 Windows 絕對路徑；拒絕測試。"
            return 1
            ;;
    esac

    if ! sudo -v; then
        warn "無法取得 sudo 權限；沒有修改設定檔。"
        return 1
    fi

    preflight_output="$(WSL_CONF_TEST_FILE="$CONFIG_TEST_FILE" show_wsl_conf_preview "$target_vhdx" 2>&1)" || rc=$?
    printf '%s\n' "$preflight_output"
    if ((rc != 0)) ||
       ! printf '%s\n' "$preflight_output" | grep -Eq 'Matched mount commands[[:space:]]*:[[:space:]]*[1-9][0-9]*' ||
       ! printf '%s\n' "$preflight_output" | grep -Fq 'Parser safety          : SUPPORTED' ||
       printf '%s\n' "$preflight_output" | grep -Fq '[BLOCKED]' ||
       ! printf '%s\n' "$preflight_output" | grep -Fq '/usr/local/bin/fix-pve-hosts.sh'; then
        warn "預檢未能證明目標命令可安全移除且 fix-pve-hosts.sh 可保留；不會修改設定檔。"
        return 1
    fi

    printf '\n'
    printf '即將暫時套用清理，再自動還原原始檔案。\n'
    printf '請輸入 TEST CONFIG CLEANUP 繼續：'
    local confirmation=""
    read -r confirmation || confirmation=""
    if [[ "$confirmation" != "TEST CONFIG CLEANUP" ]]; then
        info "未確認；沒有修改設定檔。"
        return 1
    fi

    backup_stamp="$(date +%Y%m%d-%H%M%S)"
    CONFIG_TEST_BACKUP="$CONFIG_TEST_FILE.v6-test-backup.$backup_stamp.$$"
    if ! sudo cp -a -- "$CONFIG_TEST_FILE" "$CONFIG_TEST_BACKUP"; then
        warn "建立安全備份失敗；沒有修改設定檔。"
        CONFIG_TEST_BACKUP=""
        return 1
    fi
    CONFIG_TEST_ACTIVE=1
    trap 'restore_config_test_backup' EXIT
    trap 'restore_config_test_backup; exit 130' INT
    trap 'restore_config_test_backup; exit 143' TERM
    trap 'restore_config_test_backup; exit 129' HUP
    info "安全備份已建立：$CONFIG_TEST_BACKUP"

    rc=0
    apply_output="$(WSL_CONF_TEST_FILE="$CONFIG_TEST_FILE" show_wsl_conf_preview "$target_vhdx" --apply 2>&1)" || rc=$?
    printf '%s\n' "$apply_output"
    if ((rc != 0)) ||
       ! printf '%s\n' "$apply_output" | grep -Fq '[PASS] /etc/wsl.conf updated atomically.' ||
       ! grep -Fq '/usr/local/bin/fix-pve-hosts.sh' "$CONFIG_TEST_FILE"; then
        warn "套用或內容驗證失敗；立即還原原始設定檔。"
        restore_config_test_backup || return 2
        trap - EXIT INT TERM HUP
        return 1
    fi

    verify_output="$(WSL_CONF_TEST_FILE="$CONFIG_TEST_FILE" show_wsl_conf_preview "$target_vhdx" 2>&1)" || rc=$?
    printf '%s\n' "$verify_output"
    if ((rc != 0)) ||
       ! printf '%s\n' "$verify_output" | grep -Fq 'Matched mount commands : 0' ||
       ! grep -Fq '/usr/local/bin/fix-pve-hosts.sh' "$CONFIG_TEST_FILE"; then
        warn "修改後的唯讀複查未通過；立即還原原始設定檔。"
        restore_config_test_backup || return 2
        trap - EXIT INT TERM HUP
        return 1
    fi

    printf '[PASS] 實際設定檔已移除目標 mount command，並保留 fix-pve-hosts.sh。\n'
    if ! restore_config_test_backup; then
        return 2
    fi
    trap - EXIT INT TERM HUP
    printf '[PASS] 設定檔 round-trip 測試完成；原始內容已完整還原。\n'
    return 0
}

delete_vhdx_file() {
    local vhdx_path="$1" expected_page83="$2"
    local page_output="" page_record="" fresh_page83=""
    local path_b64="" encoded="" rc=0

    section "Delete verified VHDX file"

    if [[ -z "$vhdx_path" || -z "$expected_page83" ]]; then
        warn "VHDX 路徑或原始 Page83 身分缺失；拒絕刪除。"
        return 1
    fi
    if [[ ! -x "$PS_EXE" ]]; then
        warn "找不到 PowerShell；無法安全刪除 VHDX。"
        return 1
    fi

    # Re-read the VHDX metadata immediately before deletion. This is a
    # direct file parse; it does not use Get-VHD or infer identity by path.
    page_output="$(read_vhdx_page83 "$vhdx_path" 2>&1)" || rc=$?
    page_record="$(printf '%s\n' "$page_output" | tr -d '\r' | grep '^@@VHDX|' | tail -n 1 || true)"
    if ((rc != 0)) || [[ ! "$page_record" =~ ^@@VHDX\|OK\|([[:xdigit:]]{32})$ ]]; then
        warn "刪除前無法重新讀取 VHDX Page83；拒絕刪除。"
        printf '%s\n' "$page_output" | grep -v '^@@VHDX|' || true
        return 1
    fi
    fresh_page83="${BASH_REMATCH[1],,}"
    if [[ "$fresh_page83" != "${expected_page83,,}" ]]; then
        warn "刪除前 VHDX Page83 與 Destroy 前記錄不一致；拒絕刪除。"
        warn "Expected: ${expected_page83,,}"
        warn "Current : $fresh_page83"
        return 1
    fi

    path_b64="$(printf '%s' "$vhdx_path" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0)" || return 1
    encoded="$(cat <<PS | ps_encode
\$ErrorActionPreference = 'Stop'
try {
    \$path = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$path_b64'))
    if (-not [IO.File]::Exists(\$path)) {
        throw "Target VHDX file does not exist or is not a regular file."
    }
    [IO.File]::Delete(\$path)
    if ([IO.File]::Exists(\$path)) {
        throw "VHDX still exists after deletion."
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine(\$_.Exception.Message)
    exit 1
}
PS
)" || return 1

    # Do not capture Windows PowerShell stdout in Bash; preserve stderr and
    # use the process exit code as the deletion result.
    if "$PS_EXE" -NoProfile -EncodedCommand "$encoded" >/dev/null; then
        printf '[PASS] VHDX Page83 身分再次確認，且指定 VHDX 檔案已刪除。\n'
        return 0
    else
        rc=$?
        warn "VHDX 刪除失敗（PowerShell exit code: $rc）。"
        return 1
    fi
}

post_destroy_cleanup() {
    local vhdx_path="$1" delete_vhdx="${2:-0}" expected_page83="${3:-}"
    local detach_rc=0 config_rc=0 delete_rc=0

    section "Post-destroy cleanup"
    detach_vhdx_from_wsl "$vhdx_path" || detach_rc=$?

    # Config cleanup is independent: even if detach fails, removing the exact
    # boot-time mount command prevents that command from reattaching next boot.
    update_wsl_conf_for_vhdx "$vhdx_path" || config_rc=$?

    if ((detach_rc == 0 && config_rc == 0)); then
        if [[ "$delete_vhdx" == "1" ]]; then
            delete_vhdx_file "$vhdx_path" "$expected_page83" || delete_rc=$?
            if ((delete_rc == 0)); then
                printf '\n[PASS] ZFS destroy、指定 VHDX detach、boot command cleanup 與 VHDX 刪除均完成。\n'
                return 0
            fi
            printf '\n[PARTIAL] ZFS pool 已銷毀，detach 與 boot command cleanup 已完成，但 VHDX 未能刪除。\n'
            warn "VHDX 檔案仍應保留；請依錯誤訊息人工檢查。不要重複執行 zpool destroy。"
            return 2
        fi

        printf '\n[PASS] ZFS destroy、指定 VHDX detach 與 boot command cleanup 均完成。\n'
        printf '[INFO] VHDX 檔案依照選擇保留：%s\n' "$vhdx_path"
        return 0
    fi

    printf '\n[PARTIAL] ZFS pool 已銷毀，但後續清理未全部完成。\n'
    ((detach_rc == 0)) || printf '[PENDING] VHDX 尚未確認 detach；因此不會刪除 VHDX。\n'
    ((config_rc == 0)) || printf '[PENDING] /etc/wsl.conf 尚未安全更新；因此不會刪除 VHDX。\n'
    warn "請依上述狀態人工處理；不要重複執行 zpool destroy。"
    return 2
}

# ------------------------------------------------------------
# Explicit ZFS destroy stage followed by narrowly scoped post-destroy cleanup.
# ------------------------------------------------------------
execute_pool_destroy() {
    local pool="$1"
    local delete_vhdx="${2:-0}"
    local vhdx_path="${POOL_VHDX_PATH[$pool]-}"
    local confirmation=""
    local destroy_output=""
    local expected_page83=""
    local destroy_rc=0
    local current_names=""
    local list_rc=0

    section "DESTRUCTIVE OPERATION: zpool destroy $pool"

    if [[ "$delete_vhdx" != "0" && "$delete_vhdx" != "1" ]]; then
        warn "內部 Destroy 模式無效；拒絕執行。"
        return 1
    fi
    if [[ "${POOL_STATUS[$pool]-UNKNOWN}" != "VERIFIED" ||
          -z "$vhdx_path" ||
          "${POOL_VDEV_COUNT[$pool]-0}" -le 0 ||
          "${POOL_VERIFIED_COUNT[$pool]-0}" != "${POOL_VDEV_COUNT[$pool]-0}" ]]; then
        warn "Pool 未達完整 VERIFIED 條件，拒絕執行 Destroy。"
        return 1
    fi

    # Bash associative arrays reject an empty subscript. Resolve Page 83 only
    # after the verified mapping guard has established a non-empty VHDX path.
    expected_page83="${VHDX_PAGE83[$vhdx_path]-}"
    if [[ -z "$expected_page83" ]]; then
        warn "找不到指定 VHDX 的 Page 83 身分資料，拒絕執行 Destroy。"
        return 1
    fi

    printf 'Pool name       : %s\n' "$pool"
    printf 'Pool GUID       : %s\n' "${POOL_GUID[$pool]-UNKNOWN}"
    printf 'Vdev count      : %s\n' "${POOL_VDEV_COUNT[$pool]-0}"
    printf 'VHDX path       : %s\n' "$vhdx_path"
    printf 'VHDX Page83     : %s\n' "${VHDX_PAGE83[$vhdx_path]-UNKNOWN}"
    printf '\n'
    warn "此操作會永久銷毀 ZFS pool '$pool' 及其資料。"
    if [[ "$delete_vhdx" == "1" ]]; then
        warn "本次選擇：Destroy Pool，並在清理成功及 Page83 再次吻合後刪除 VHDX。"
        warn "將刪除的 VHDX：$vhdx_path"
    else
        info "本次選擇：Destroy Pool，但保留 VHDX 檔案。"
    fi
    info "Destroy 成功後會卸載指定 VHDX，並清理對應的 wsl.conf boot command。"

    info "第一輪：執行唯讀 Destroy 前安全檢查。"
    if ! pre_destroy_safety_check "$pool"; then
        warn "安全檢查未通過，Destroy 已取消。"
        return 1
    fi

    printf '\n'
    if [[ "$delete_vhdx" == "1" ]]; then
        read -r -p "確定要銷毀 Pool '$pool' 並刪除上述 VHDX？ [y/N] " confirmation || confirmation=""
    else
        read -r -p "確定要銷毀 Pool '$pool'（保留 VHDX）？ [y/N] " confirmation || confirmation=""
    fi
    case "$confirmation" in
        y|Y|yes|YES) ;;
        *)
            info "使用者取消；未執行任何破壞性操作。"
            return 1
            ;;
    esac

    # Revalidate after yes/no confirmation, immediately before the destructive command.
    info "第二輪：確認後再次執行完整唯讀安全檢查。"
    if ! pre_destroy_safety_check "$pool"; then
        warn "第二輪安全檢查未通過，Destroy 已取消。"
        return 1
    fi

    printf '\n'
    warn "最後確認：即將執行 sudo zpool destroy '$pool'。"
    destroy_output="$(sudo zpool destroy "$pool" 2>&1)"
    destroy_rc=$?
    if [[ -n "$destroy_output" ]]; then
        printf '%s\n' "$destroy_output"
    fi

    # Verify actual pool presence independently of the command exit status.
    current_names="$(zpool list -H -o name 2>&1)"
    list_rc=$?
    if ((list_rc != 0)); then
        printf '[PARTIAL] zpool destroy exit code: %s\n' "$destroy_rc"
        warn "無法重新查詢 ZFS pool 清單，不能確認銷毀結果。"
        warn "請勿重複執行 Destroy；先人工確認 zpool list。"
        return 2
    fi

    if printf '%s\n' "$current_names" | awk -v p="$pool" '$0 == p {found=1} END {exit !found}'; then
        if ((destroy_rc == 0)); then
            warn "zpool destroy 回報成功，但 Pool 仍存在。"
        else
            warn "zpool destroy 失敗，且 Pool 仍存在。"
        fi
        return 1
    fi

    if ((destroy_rc != 0)); then
        warn "zpool destroy 回報非零，但 Pool 已不在清單中；結果需人工確認。"
        printf '[PARTIAL] Pool absence observed; command exit code was %s.\n' "$destroy_rc"
        return 2
    fi

    printf '\n'
    printf '[PASS] ZFS pool 已銷毀，且 zpool list 已確認該 Pool 不存在。\n'
    post_destroy_cleanup "$vhdx_path" "$delete_vhdx" "$expected_page83"
    return $?
}

# ------------------------------------------------------------
# SCSI snapshot comparison tests. Temporary sysfs fixtures only.
# ------------------------------------------------------------
run_scsi_identity_mock_tests() {
    local tmpdir failures=0 total=0 guid="fd1d2cbd-ce7c-535c-966b-eb5f811c95f0"
    local devpath sysdev expected_sha rc
    tmpdir="$(mktemp -d)" || return 1
    devpath="$tmpdir/devices/VMBUS:00/$guid/host0/target0:0:3/0:0:0:3"
    sysdev="$tmpdir/sys/block/sdc"
    mkdir -p "$devpath" "$sysdev"
    printf '%s\n' '60022480d90287df2be40bbc235e8674' > "$devpath/wwid"
    printf '%s\n' 'mock-vpd-page-83-original' > "$devpath/vpd_pg83"
    ln -s "$devpath" "$sysdev/device"
    expected_sha="$(sha256sum "$devpath/vpd_pg83" | awk '{print $1}')"

    section "Live SCSI identity snapshot comparison tests"

    total=$((total + 1))
    if verify_live_scsi_snapshot sdc sdc 60022480d90287df2be40bbc235e8674 3 "$guid" "$expected_sha" "$tmpdir/sys" 2>/dev/null; then
        printf '[PASS] P: unchanged device name and SCSI identity are accepted\n'
    else
        printf '[FAIL] P: unchanged identity was rejected\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    verify_live_scsi_snapshot sdc sdd 60022480d90287df2be40bbc235e8674 3 "$guid" "$expected_sha" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] Q: changed /dev device name is blocked\n'
    else
        printf '[FAIL] Q: changed device name was accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    printf '%s\n' '60022480ffffffffffffffffffffffff' > "$devpath/wwid"
    rc=0
    verify_live_scsi_snapshot sdc sdc 60022480d90287df2be40bbc235e8674 3 "$guid" "$expected_sha" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] R: changed WWID is blocked\n'
    else
        printf '[FAIL] R: changed WWID was accepted\n'
        failures=$((failures + 1))
    fi
    printf '%s\n' '60022480d90287df2be40bbc235e8674' > "$devpath/wwid"

    total=$((total + 1))
    rc=0
    verify_live_scsi_snapshot sdc sdc 60022480d90287df2be40bbc235e8674 2 "$guid" "$expected_sha" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] S: changed LUN is blocked\n'
    else
        printf '[FAIL] S: changed LUN was accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    verify_live_scsi_snapshot sdc sdc 60022480d90287df2be40bbc235e8674 3 "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "$expected_sha" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] T: changed VMBUS GUID is blocked\n'
    else
        printf '[FAIL] T: changed VMBUS GUID was accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    printf '%s\n' 'mock-vpd-page-83-changed' > "$devpath/vpd_pg83"
    rc=0
    verify_live_scsi_snapshot sdc sdc 60022480d90287df2be40bbc235e8674 3 "$guid" "$expected_sha" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] U: changed Page 83 bytes are blocked\n'
    else
        printf '[FAIL] U: changed Page 83 bytes were accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rm -f "$sysdev/device"
    rc=0
    verify_live_scsi_snapshot sdc sdc 60022480d90287df2be40bbc235e8674 3 "$guid" "$expected_sha" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] V: missing sysfs device is blocked\n'
    else
        printf '[FAIL] V: missing sysfs device was accepted\n'
        failures=$((failures + 1))
    fi

    rm -rf "$tmpdir"
    printf '\nSCSI identity mock summary: %d total, %d failed\n' "$total" "$failures"
    ((failures == 0))
}

# ------------------------------------------------------------
# Multi-vdev identity tests.
# These exercise the same per-vdev snapshot verifier used by the
# pre-destroy loop, using only temporary sysfs fixtures. No ZFS pool,
# block device, WSL mount, VHDX or /etc/wsl.conf is touched.
# ------------------------------------------------------------
run_multi_vdev_mock_tests() {
    local tmpdir failures=0 total=0 guid_a="fd1d2cbd-ce7c-535c-966b-eb5f811c95f0"
    local guid_b="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local guid_c="11111111-2222-3333-4444-555555555555"
    local devpath name parent expected_sha rc
    local -a parents=(sdc sdd sde)
    local -A wwids=() luns=() guids=() shas=()

    tmpdir="$(mktemp -d)" || return 1

    make_fixture() {
        local parent="$1" guid="$2" lun="$3" wwid="$4" page="$5"
        local d="$tmpdir/devices/VMBUS:00/$guid/host0/target0:0:$lun/0:0:0:$lun"
        local b="$tmpdir/sys/block/$parent"
        mkdir -p "$d" "$b"
        printf '%s\n' "$wwid" > "$d/wwid"
        printf '%s\n' "$page" > "$d/vpd_pg83"
        ln -s "$d" "$b/device"
        wwids[$parent]="$wwid"
        luns[$parent]="$lun"
        guids[$parent]="$guid"
        shas[$parent]="$(sha256sum "$d/vpd_pg83" | awk '{print $1}')"
    }

    multi_check() {
        local count="$1" changed_name="${2-}"
        local p current result=0
        for p in "${parents[@]:0:count}"; do
            current="$p"
            [[ "$p" == "$changed_name" ]] && current="sdz"
            if ! verify_live_scsi_snapshot "$p" "$current" \
                "${wwids[$p]}" "${luns[$p]}" "${guids[$p]}" \
                "${shas[$p]}" "$tmpdir/sys" 2>/dev/null; then
                result=1
            fi
        done
        return "$result"
    }

    make_fixture sdc "$guid_a" 3 60022480d90287df2be40bbc235e8674 'page83-A'
    make_fixture sdd "$guid_b" 4 60022480aaaaaaaaaaaaaaaaaaaaaaaa 'page83-B'
    make_fixture sde "$guid_c" 5 60022480111111111111111111111111 'page83-C'

    section "Multi-vdev SCSI identity mock tests"

    total=$((total + 1))
    if multi_check 2; then
        printf '[PASS] W: two vdevs with matching identities are accepted\n'
    else
        printf '[FAIL] W: valid two-vdev set was rejected\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    if multi_check 3; then
        printf '[PASS] X: three vdevs with matching identities are accepted\n'
    else
        printf '[FAIL] X: valid three-vdev set was rejected\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    printf '%s\n' '60022480ffffffffffffffffffffffff' > "$tmpdir/devices/VMBUS:00/$guid_b/host0/target0:0:4/0:0:0:4/wwid"
    rc=0; multi_check 3 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] Y: one vdev WWID mismatch blocks the entire set\n'
    else
        printf '[FAIL] Y: one vdev WWID mismatch was accepted\n'
        failures=$((failures + 1))
    fi
    printf '%s\n' '60022480aaaaaaaaaaaaaaaaaaaaaaaa' > "$tmpdir/devices/VMBUS:00/$guid_b/host0/target0:0:4/0:0:0:4/wwid"

    total=$((total + 1))
    rc=0; verify_live_scsi_snapshot sdd sdd "${wwids[sdd]}" 9 "$guid_b" "${shas[sdd]}" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] Z: one vdev LUN mismatch is blocked\n'
    else
        printf '[FAIL] Z: one vdev LUN mismatch was accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0; verify_live_scsi_snapshot sde sde "${wwids[sde]}" 5 "$guid_b" "${shas[sde]}" "$tmpdir/sys" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] AA: one vdev VMBUS GUID mismatch is blocked\n'
    else
        printf '[FAIL] AA: one vdev VMBUS GUID mismatch was accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    printf '%s\n' 'page83-C-modified' > "$tmpdir/devices/VMBUS:00/$guid_c/host0/target0:0:5/0:0:0:5/vpd_pg83"
    rc=0; multi_check 3 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] AB: one vdev Page 83 mismatch blocks the entire set\n'
    else
        printf '[FAIL] AB: one vdev Page 83 mismatch was accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0; multi_check 3 sdd || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] AC: one vdev device-name change blocks the entire set\n'
    else
        printf '[FAIL] AC: one vdev device-name change was accepted\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rm -f "$tmpdir/sys/block/sdd/device"
    rc=0; multi_check 3 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '[PASS] AD: one missing vdev sysfs identity blocks the entire set\n'
    else
        printf '[FAIL] AD: one missing vdev identity was accepted\n'
        failures=$((failures + 1))
    fi

    rm -rf "$tmpdir"
    printf '\nMulti-vdev mock summary: %d total, %d failed\n' "$total" "$failures"
    ((failures == 0))
}

# ------------------------------------------------------------
# Page 83-first VHDX mapping tests. Attachment/LUN numbers deliberately differ.
# ------------------------------------------------------------
run_page83_mapping_mock_tests() {
    local failures=0 total=0 rc
    local -A HV_ATTACHMENT_CONTROLLER=() HV_ATTACHMENT_STATE=() HV_ATTACHMENT_PATH=()
    local -A VHDX_PAGE83=()

    section "Page 83-first VHDX mapping mock tests"
    HV_ATTACHMENT_STATE['9:8']='ADD'
    HV_ATTACHMENT_CONTROLLER['9:8']='9'
    HV_ATTACHMENT_PATH['9:8']='D:\\Mock\\disk-a.vhdx'
    VHDX_PAGE83['D:\\Mock\\disk-a.vhdx']='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

    total=$((total + 1))
    if find_vhdx_by_page83 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' &&
       [[ "$PAGE83_MATCH_PATH" == 'D:\\Mock\\disk-a.vhdx' ]]; then
        printf '[PASS] AE: Page 83 finds the VHDX even when Attachment 8 differs from Linux LUN 3\n'
    else
        printf '[FAIL] AE: Page 83-first matching failed when Attachment and LUN differ\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    find_vhdx_by_page83 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        printf '[PASS] AF: missing Page 83 match is rejected\n'
    else
        printf '[FAIL] AF: missing Page 83 match was not rejected (rc=%s)\n' "$rc"
        failures=$((failures + 1))
    fi

    HV_ATTACHMENT_STATE['2:6']='ADD'
    HV_ATTACHMENT_CONTROLLER['2:6']='2'
    HV_ATTACHMENT_PATH['2:6']='D:\\Mock\\disk-b.vhdx'
    VHDX_PAGE83['D:\\Mock\\disk-b.vhdx']='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

    total=$((total + 1))
    rc=0
    find_vhdx_by_page83 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        printf '[PASS] AG: duplicate Page 83 matches on different VHDX paths are ambiguous and blocked\n'
    else
        printf '[FAIL] AG: duplicate VHDX Page 83 matches were not blocked (rc=%s)\n' "$rc"
        failures=$((failures + 1))
    fi

    printf '\nPage 83 mapping mock summary: %d total, %d failed\n' "$total" "$failures"
    ((failures == 0))
}

# ------------------------------------------------------------
# Destroy workflow simulation tests.
# All external effects are replaced by shell functions; no real zpool,
# sudo, device, VHDX, WSL or configuration file is touched.
# ------------------------------------------------------------
run_destroy_mock_tests() {
    local tmpdir failures=0 total=0
    tmpdir="$(mktemp -d)" || return 1

    run_destroy_case() {
        local name="$1" safety_rc="$2" confirmation="$3"
        local destroy_rc="$4" list_mode="$5" expected_rc="$6" expect_destroy="$7"
        local marker="$tmpdir/destroy-called-$((total + 1))"
        local output actual_rc=0
        total=$((total + 1))
        output="$(
            declare -A POOL_STATUS=() POOL_VHDX_PATH=() POOL_GUID=()
            declare -A POOL_VDEV_COUNT=() POOL_VERIFIED_COUNT=() VHDX_PAGE83=()
            POOL_STATUS[mockpool]=VERIFIED
            POOL_VHDX_PATH[mockpool]="/mock/mock.vhdx"
            POOL_GUID[mockpool]="12345"
            POOL_VDEV_COUNT[mockpool]=1
            POOL_VERIFIED_COUNT[mockpool]=1
            VHDX_PAGE83["/mock/mock.vhdx"]="0123456789abcdef0123456789abcdef"
            MOCK_SAFETY_RC="$safety_rc"
            MOCK_CONFIRM="$confirmation"
            MOCK_DESTROY_RC="$destroy_rc"
            MOCK_LIST_MODE="$list_mode"
            MOCK_DESTROY_MARKER="$marker"

            pre_destroy_safety_check() { return "$MOCK_SAFETY_RC"; }
            post_destroy_cleanup() { printf '[MOCK] post-destroy cleanup\n'; return 2; }
            read() { confirmation="$MOCK_CONFIRM"; return 0; }
            sudo() { : > "$MOCK_DESTROY_MARKER"; return "$MOCK_DESTROY_RC"; }
            zpool() {
                if [[ "$MOCK_LIST_MODE" == "error" ]]; then
                    printf 'mock zpool list error\n' >&2
                    return 1
                fi
                if [[ "$MOCK_LIST_MODE" == "present" ]]; then
                    printf 'mockpool\n'
                fi
                return 0
            }
            execute_pool_destroy mockpool
        )" || actual_rc=$?

        if [[ "$actual_rc" -ne "$expected_rc" ]]; then
            printf '[FAIL] %s (expected rc=%s, got rc=%s)\n' "$name" "$expected_rc" "$actual_rc"
            printf '%s\n' "$output" | sed 's/^/       /'
            failures=$((failures + 1))
        elif [[ "$expect_destroy" == "yes" && ! -f "$marker" ]]; then
            printf '[FAIL] %s (expected mock destroy call, but none occurred)\n' "$name"
            failures=$((failures + 1))
        elif [[ "$expect_destroy" == "no" && -f "$marker" ]]; then
            printf '[FAIL] %s (mock destroy was unexpectedly called)\n' "$name"
            failures=$((failures + 1))
        else
            printf '[PASS] %s\n' "$name"
        fi
    }

    section "Destroy workflow mock self-test (no real ZFS operations)"
    run_destroy_case 'E: safety check failure blocks destroy' 1 'y' 0 absent 1 no
    run_destroy_case 'F: user declines yes/no confirmation' 0 'n' 0 absent 1 no
    run_destroy_case 'G: destroy success + pool absent enters post-destroy cleanup'  0 'y' 0 absent 2 yes
    run_destroy_case 'H: destroy failure + pool still present reports failure' 0 'y' 1 present 1 yes
    run_destroy_case 'I: nonzero destroy + pool absent reports partial' 0 'y' 1 absent 2 yes
    run_destroy_case 'J: post-destroy list failure reports partial' 0 'y' 0 error 2 yes

    # Empty/unresolved VHDX mapping must fail closed without indexing an
    # associative array with an empty key (Bash: "bad array subscript").
    local empty_path_output empty_path_rc=0 empty_path_marker="$tmpdir/destroy-called-empty-path"
    total=$((total + 1))
    empty_path_output="$(
        declare -A POOL_STATUS=() POOL_VHDX_PATH=() POOL_GUID=()
        declare -A POOL_VDEV_COUNT=() POOL_VERIFIED_COUNT=() VHDX_PAGE83=()
        POOL_STATUS[mockpool]=VERIFIED
        POOL_VHDX_PATH[mockpool]=""
        POOL_GUID[mockpool]="12345"
        POOL_VDEV_COUNT[mockpool]=1
        POOL_VERIFIED_COUNT[mockpool]=1
        MOCK_DESTROY_MARKER="$empty_path_marker"
        pre_destroy_safety_check() { return 0; }
        sudo() { : > "$MOCK_DESTROY_MARKER"; return 0; }
        execute_pool_destroy mockpool 2>&1
    )" || empty_path_rc=$?
    if [[ "$empty_path_rc" -eq 1 && ! -f "$empty_path_marker" &&
          "$empty_path_output" != *"bad array subscript"* ]]; then
        printf '[PASS] P: missing VHDX mapping is rejected cleanly without an empty associative-array subscript\n'
    else
        printf '[FAIL] P: missing VHDX mapping did not fail closed cleanly (rc=%s)\n' "$empty_path_rc"
        printf '%s\n' "$empty_path_output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    # Explicitly prove that a successful first safety pass followed by a
    # failed second pass (after yes/no confirmation) never reaches sudo destroy.
    local second_marker="$tmpdir/destroy-called-second-check"
    local second_output second_rc=0
    total=$((total + 1))
    second_output="$(
        declare -A POOL_STATUS=() POOL_VHDX_PATH=() POOL_GUID=()
        declare -A POOL_VDEV_COUNT=() POOL_VERIFIED_COUNT=() VHDX_PAGE83=()
        POOL_STATUS[mockpool]=VERIFIED
        POOL_VHDX_PATH[mockpool]="/mock/mock.vhdx"
        POOL_GUID[mockpool]="12345"
        POOL_VDEV_COUNT[mockpool]=1
        POOL_VERIFIED_COUNT[mockpool]=1
        VHDX_PAGE83["/mock/mock.vhdx"]="0123456789abcdef0123456789abcdef"
        MOCK_SAFETY_CALLS=0
        MOCK_DESTROY_MARKER="$second_marker"
        pre_destroy_safety_check() {
            MOCK_SAFETY_CALLS=$((MOCK_SAFETY_CALLS + 1))
            [[ "$MOCK_SAFETY_CALLS" -eq 1 ]]
        }
        post_destroy_cleanup() { return 0; }
        read() { confirmation='y'; return 0; }
        sudo() { : > "$MOCK_DESTROY_MARKER"; return 0; }
        zpool() { printf 'mockpool\n'; return 0; }
        execute_pool_destroy mockpool
    )" || second_rc=$?
    if [[ "$second_rc" -eq 1 && ! -f "$second_marker" ]]; then
        printf '[PASS] O: first safety check passes but second fails; destroy is never called\n'
    else
        printf '[FAIL] O: second-check failure did not safely block destroy (rc=%s marker=%s)\n' \
            "$second_rc" "$( [[ -f "$second_marker" ]] && printf present || printf absent )"
        printf '%s\n' "$second_output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    section "Hyper-V event evidence policy tests"
    local hv_test_rc
    HV_ATTACHMENT_CONTROLLER=(); HV_ATTACHMENT_STATE=(); HV_ATTACHMENT_PATH=()
    total=$((total + 1))
    hv_test_rc=0
    classify_hv_attachment_evidence 'D:\Wsl\disk\wsl-pve.vhdx' 1 >/dev/null || hv_test_rc=$?
    if [[ "$hv_test_rc" -eq 2 ]]; then
        printf '[PASS] K: Hyper-V query failure is inconclusive, not a blocker\n'
    else
        printf '[FAIL] K: Hyper-V query failure classification (got %s)\n' "$hv_test_rc"
        failures=$((failures + 1))
    fi
    total=$((total + 1))
    HV_ATTACHMENT_STATE['0:9']='ADD'
    HV_ATTACHMENT_PATH['0:9']='\\?\D:\Wsl\disk\wsl-pve.vhdx'
    hv_test_rc=0
    hv_match_key="$(classify_hv_attachment_evidence 'D:\Wsl\disk\wsl-pve.vhdx' 0)" || hv_test_rc=$?
    if [[ "$hv_test_rc" -eq 0 && "$hv_match_key" == '0:9' ]]; then
        printf '[PASS] L: matching ADD on a new attachment key is accepted\n'
    else
        printf '[FAIL] L: new attachment key classification (rc=%s key=%s)\n' "$hv_test_rc" "$hv_match_key"
        failures=$((failures + 1))
    fi
    HV_ATTACHMENT_STATE=(); HV_ATTACHMENT_PATH=()
    total=$((total + 1))
    HV_ATTACHMENT_STATE['0:9']='REMOVE'
    HV_ATTACHMENT_PATH['0:9']='D:\Wsl\disk\wsl-pve.vhdx'
    hv_test_rc=0
    classify_hv_attachment_evidence 'D:\Wsl\disk\wsl-pve.vhdx' 0 >/dev/null || hv_test_rc=$?
    if [[ "$hv_test_rc" -eq 1 ]]; then
        printf '[PASS] M: explicit target REMOVE without ADD is blocked\n'
    else
        printf '[FAIL] M: explicit REMOVE classification (got %s)\n' "$hv_test_rc"
        failures=$((failures + 1))
    fi
    HV_ATTACHMENT_STATE=(); HV_ATTACHMENT_PATH=()
    total=$((total + 1))
    HV_ATTACHMENT_STATE['0:3']='ADD'
    HV_ATTACHMENT_PATH['0:3']='D:\Wsl\disk\another.vhdx'
    hv_test_rc=0
    classify_hv_attachment_evidence 'D:\Wsl\disk\wsl-pve.vhdx' 0 >/dev/null || hv_test_rc=$?
    if [[ "$hv_test_rc" -eq 2 ]]; then
        printf '[PASS] N: no matching event is inconclusive, not a blocker\n'
    else
        printf '[FAIL] N: missing target event classification (got %s)\n' "$hv_test_rc"
        failures=$((failures + 1))
    fi
    HV_ATTACHMENT_CONTROLLER=(); HV_ATTACHMENT_STATE=(); HV_ATTACHMENT_PATH=()

    rm -rf "$tmpdir"
    printf '\nDestroy mock summary: %d total, %d failed\n' "$total" "$failures"
    if ((failures == 0)); then
        printf '[PASS] All destroy workflow mock tests passed.\n'
        return 0
    fi
    printf '[FAIL] Destroy workflow mock tests need attention.\n'
    return 1
}

run_cleanup_mock_tests() {
    local tmpdir failures=0 total=0 fake_wsl call_log output rc
    tmpdir="$(mktemp -d)" || return 1
    fake_wsl="$tmpdir/wsl.exe"
    call_log="$tmpdir/wsl-call.log"
    cat > "$fake_wsl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$WSL_CALL_LOG"
exit "${MOCK_WSL_RC:-0}"
MOCK
    chmod +x "$fake_wsl"

    section "Post-destroy cleanup mock tests (temporary files only)"
    total=$((total + 1))
    rm -f "$call_log"
    rc=0
    output="$(WSL_EXE="$fake_wsl" WSL_CALL_LOG="$call_log" detach_vhdx_from_wsl 'D:\Wsl\disk\mock.vhdx' 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 && -f "$call_log" ]] &&
       [[ "$(sed -n '1p' "$call_log")" == '--unmount' ]] &&
       [[ "$(sed -n '2p' "$call_log")" == 'D:\Wsl\disk\mock.vhdx' ]]; then
        printf '[PASS] G: detach passes only --unmount and exact target VHDX path\n'
    else
        printf '[FAIL] G: detach argument verification (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rm -f "$call_log"
    rc=0
    output="$(WSL_EXE="$fake_wsl" WSL_CALL_LOG="$call_log" detach_vhdx_from_wsl '/tmp/not-a-windows-path.vhdx' 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 && ! -e "$call_log" ]]; then
        printf '[PASS] H: invalid target path is rejected before wsl.exe is called\n'
    else
        printf '[FAIL] H: invalid path was not rejected\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rm -f "$call_log"
    rc=0
    output="$(read() { return 1; }; WSL_EXE="$fake_wsl" WSL_CALL_LOG="$call_log" MOCK_WSL_RC=5 detach_vhdx_from_wsl 'D:\Wsl\disk\mock.vhdx' 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 && -f "$call_log" ]]; then
        printf '[PASS] I: non-zero wsl.exe result is reported as detach failure\n'
    else
        printf '[FAIL] I: detach failure was not propagated\n'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    output="$(
        detach_vhdx_from_wsl() { printf 'MOCK_DETACH_FAIL\n'; return 1; }
        update_wsl_conf_for_vhdx() { printf 'MOCK_CONFIG_ATTEMPTED\n'; return 0; }
        post_destroy_cleanup 'D:\Wsl\disk\mock.vhdx'
    )" || rc=$?
    if [[ "$rc" -eq 2 ]] &&
       printf '%s\n' "$output" | grep -Fq 'MOCK_DETACH_FAIL' &&
       printf '%s\n' "$output" | grep -Fq 'MOCK_CONFIG_ATTEMPTED' &&
       printf '%s\n' "$output" | grep -Fq '[PARTIAL]'; then
        printf '[PASS] J: config cleanup is still attempted if detach fails; result is PARTIAL\n'
    else
        printf '[FAIL] J: detach failure sequencing (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    output="$(
        detach_vhdx_from_wsl() { printf 'MOCK_DETACH_OK\n'; return 0; }
        update_wsl_conf_for_vhdx() { printf 'MOCK_CONFIG_OK\n'; return 0; }
        post_destroy_cleanup 'D:\Wsl\disk\mock.vhdx'
    )" || rc=$?
    if [[ "$rc" -eq 0 ]] &&
       printf '%s\n' "$output" | grep -Fq 'MOCK_DETACH_OK' &&
       printf '%s\n' "$output" | grep -Fq 'MOCK_CONFIG_OK' &&
       printf '%s\n' "$output" | grep -Fq '[PASS]'; then
        printf '[PASS] K: both cleanup stages succeeding reports full completion\n'
    else
        printf '[FAIL] K: full cleanup success result (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    output="$(
        detach_vhdx_from_wsl() { return 1; }
        update_wsl_conf_for_vhdx() { return 0; }
        delete_vhdx_file() { printf 'MOCK_DELETE_SHOULD_NOT_RUN\n'; return 0; }
        post_destroy_cleanup 'D:\Wsl\disk\mock.vhdx' 1 '0123456789abcdef0123456789abcdef'
    )" || rc=$?
    if [[ "$rc" -eq 2 ]] && ! printf '%s\n' "$output" | grep -Fq 'MOCK_DELETE_SHOULD_NOT_RUN'; then
        printf '[PASS] M: requested VHDX deletion is blocked when detach fails\n'
    else
        printf '[FAIL] M: VHDX deletion was not safely gated (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    output="$(
        detach_vhdx_from_wsl() { return 0; }
        update_wsl_conf_for_vhdx() { return 0; }
        delete_vhdx_file() {
            printf 'MOCK_DELETE path=%s page83=%s\n' "$1" "$2"
            return 0
        }
        post_destroy_cleanup 'D:\Wsl\disk\mock.vhdx' 1 '0123456789abcdef0123456789abcdef'
    )" || rc=$?
    if [[ "$rc" -eq 0 ]] &&
       printf '%s\n' "$output" | grep -Fq 'MOCK_DELETE path=D:\Wsl\disk\mock.vhdx page83=0123456789abcdef0123456789abcdef' &&
       printf '%s\n' "$output" | grep -Fq 'VHDX 刪除均完成'; then
        printf '[PASS] N: VHDX deletion runs only after both cleanup stages succeed\n'
    else
        printf '[FAIL] N: VHDX delete success path (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    output="$(
        detach_vhdx_from_wsl() { return 0; }
        update_wsl_conf_for_vhdx() { return 0; }
        delete_vhdx_file() { return 1; }
        post_destroy_cleanup 'D:\Wsl\disk\mock.vhdx' 1 '0123456789abcdef0123456789abcdef'
    )" || rc=$?
    if [[ "$rc" -eq 2 ]] && printf '%s\n' "$output" | grep -Fq '[PARTIAL]'; then
        printf '[PASS] O: VHDX deletion failure is reported as PARTIAL\n'
    else
        printf '[FAIL] O: VHDX deletion failure classification (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    total=$((total + 1))
    rc=0
    output="$(
        read() { local var="${@: -1}"; printf -v "$var" '%s' y; return 0; }
        run_wsl_unmount_elevated() { printf 'MOCK_ELEVATED_PATH=%s\n' "$1"; return 0; }
        WSL_EXE="$fake_wsl" WSL_CALL_LOG="$call_log" MOCK_WSL_RC=5 detach_vhdx_from_wsl 'D:\Wsl\disk\mock.vhdx'
    )" || rc=$?
    if [[ "$rc" -eq 0 ]] &&
       printf '%s\n' "$output" | grep -Fq 'MOCK_ELEVATED_PATH=D:\Wsl\disk\mock.vhdx'; then
        printf '[PASS] L: failed normal detach can retry through the UAC elevation path\n'
    else
        printf '[FAIL] L: UAC retry path (rc=%s)\n' "$rc"
        printf '%s\n' "$output" | sed 's/^/       /'
        failures=$((failures + 1))
    fi

    rm -rf "$tmpdir"
    printf '\nCleanup mock summary: %d total, %d failed\n' "$total" "$failures"
    ((failures == 0))
}

pool_menu() {
    local choice action pool selected_pool pool_rc

    while :; do
        refresh_known_pool_names || true
        if ((${#ZPOOL_NAMES[@]} == 0)); then
            warn "目前沒有可供選擇的 ZFS pool。"
            break
        fi

        printf '%-5s %-20s %-12s %-12s %-12s\n' \
            "NO." "POOL" "HEALTH" "VDEVS" "MAPPING"
        for i in "${!ZPOOL_NAMES[@]}"; do
            pool="${ZPOOL_NAMES[$i]}"
            printf '%-5s %-20s %-12s %-12s %-12s\n' \
                "$((i + 1))" "$pool" \
                "${POOL_HEALTH[$pool]-UNKNOWN}" \
                "${POOL_VDEV_COUNT[$pool]-0}" \
                "${POOL_STATUS[$pool]-UNKNOWN}"
        done

        printf '0     Exit\n\n'
        if ! read -r -p "請選擇要檢視／預覽的 pool [0-${#ZPOOL_NAMES[@]}]: " choice; then
            break
        fi
        [[ "$choice" == "0" ]] && break

        if [[ ! "$choice" =~ ^[0-9]+$ ]] ||
            ((choice < 1 || choice > ${#ZPOOL_NAMES[@]})); then
            warn "請輸入有效的選項。"
            continue
        fi

        selected_pool="${ZPOOL_NAMES[$((choice - 1))]}"
        while :; do
            pool_rc=0
            zpool_pool_exists "$selected_pool" || pool_rc=$?
            case "$pool_rc" in
                0) ;;
                1)
                    warn "Pool '$selected_pool' 已不存在；返回並更新 Pool 清單。"
                    break
                    ;;
                *)
                    warn "無法確認 Pool '$selected_pool' 是否存在；為避免使用過期資訊，返回 Pool 清單。"
                    break
                    ;;
            esac
            show_pool_details "$selected_pool"
            printf '\n1) 顯示 pool 詳細資訊\n'
            printf '2) 唯讀 destroy 操作預覽\n'
            printf '3) Destroy 前安全檢查（唯讀）\n'
            printf '4) Destroy ZFS Pool（保留 VHDX）\n'
            printf '5) Destroy ZFS Pool + 刪除 VHDX\n'
            printf '0) 返回 pool 清單\n'
            if ! read -r -p "請選擇 [0-5]: " action; then
                break
            fi

            case "$action" in
                1)
                    if ! show_pool_storage_snapshot "$selected_pool"; then
                        refresh_known_pool_names || true
                        break
                    fi
                    ;;
                2)
                    preview_selected_pool "$selected_pool"
                    ;;
                3)
                    pre_destroy_safety_check "$selected_pool" || true
                    ;;
                4)
                    execute_pool_destroy "$selected_pool" 0 || true
                    ;;
                5)
                    execute_pool_destroy "$selected_pool" 1 || true
                    ;;
                0)
                    break
                    ;;
                *)
                    warn "無效選項。"
                    ;;
            esac
        done
    done
}

if [[ "${1-}" == "--self-test" ]]; then
    test_rc=0
    run_parser_self_tests || test_rc=1
    run_scsi_identity_mock_tests || test_rc=1
    run_multi_vdev_mock_tests || test_rc=1
    run_page83_mapping_mock_tests || test_rc=1
    run_destroy_mock_tests || test_rc=1
    run_cleanup_mock_tests || test_rc=1
    run_pool_detail_mock_tests || test_rc=1
    exit "$test_rc"
fi

if [[ "${1-}" == "--test-config-cleanup" ]]; then
    if [[ "$#" -ne 2 ]]; then
        printf 'Usage: %s --test-config-cleanup <Windows-VHDX-path>\n' "$0" >&2
        printf "Example: %s --test-config-cleanup 'D:\\Wsl\\disk\\wsl-pve.vhdx'\n" "$0" >&2
        exit 2
    fi
    run_config_cleanup_live_test "$2"
    exit "$?"
fi

pool_menu

section "Discovery summary"
info "v6.6.10 使用 Page 83 在 Hyper-V ADD VHDX 中尋找唯一身分匹配，不假設 Attachment 編號等於 Linux LUN。"
info "支援雙重安全檢查、逐一 vdev 的 WWID/LUN/VMBUS/Page83 快照比對、Destroy 後指定 VHDX detach 及 wsl.conf 安全清理。"
info "若未在選單明確選擇 4（保留 VHDX）或 5（刪除 VHDX）並通過 yes/no 確認，本次不會執行 zpool destroy。"
info "Destroy 成功後會卸載指定 VHDX，並安全清理對應的 /etc/wsl.conf boot command；失敗時回報 PARTIAL。"
info "只有選擇 5 且卸載、設定清理及刪除前 Page83 身分複核全部成功，才會刪除 VHDX。"



