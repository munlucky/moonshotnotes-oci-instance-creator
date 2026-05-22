param(
    [string]$EnvFile = "",
    [switch]$ValidateOnly,
    [switch]$Once
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $homeEnv = Join-Path $HOME ".oci-instance-creator.env"
    $repoEnv = Join-Path $repoRoot ".oci-instance-creator.env"
    if (Test-Path -LiteralPath $homeEnv) {
        $EnvFile = $homeEnv
    } else {
        $EnvFile = $repoEnv
    }
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "Env file not found: $EnvFile"
}

$config = @{}
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)\s*$') {
        $name = $matches[1]
        $value = $matches[2].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $value = $value.Replace('$PWD', $repoRoot).Replace('$HOME', $HOME)
        $config[$name] = $value
    }
}

function Get-ConfigValue {
    param(
        [string]$Name,
        [string]$Default = ""
    )
    if ($config.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($config[$Name])) {
        return $config[$Name]
    }
    return $Default
}

function Require-ConfigValue {
    param(
        [string]$Name,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match 'replace-me|xxxxx') {
        throw "Missing required config: $Name"
    }
}

$oci = Get-ConfigValue "OCI_CLI_BIN" (Join-Path $repoRoot ".venv\Scripts\oci.exe")
$ociConfig = Get-ConfigValue "OCI_CONFIG_FILE" (Join-Path $HOME ".oci\config")
$ociProfile = Get-ConfigValue "OCI_PROFILE" "DEFAULT"
$ociConnectionTimeoutSeconds = [int](Get-ConfigValue "OCI_CONNECTION_TIMEOUT_SECONDS" "120")
$ociReadTimeoutSeconds = [int](Get-ConfigValue "OCI_READ_TIMEOUT_SECONDS" "240")
$logFile = Get-ConfigValue "LOG_FILE" (Join-Path $HOME "oci-instance.log")
$successFlag = Get-ConfigValue "SUCCESS_FLAG" (Join-Path $HOME ".oci-instance-created")
$intervalSeconds = [int](Get-ConfigValue "INTERVAL_SECONDS" "60")
$rateLimitBackoffSeconds = [int](Get-ConfigValue "RATE_LIMIT_BACKOFF_SECONDS" "180")
$jitterSeconds = [int](Get-ConfigValue "JITTER_SECONDS" "10")
$throttleStateFile = Get-ConfigValue "THROTTLE_STATE_FILE" (Join-Path $HOME ".oci-instance-throttle.json")
$minIntervalSeconds = [int](Get-ConfigValue "MIN_INTERVAL_SECONDS" $intervalSeconds.ToString())
$maxIntervalSeconds = [int](Get-ConfigValue "MAX_INTERVAL_SECONDS" "360")
$rateLimitMultiplier = [double](Get-ConfigValue "RATE_LIMIT_MULTIPLIER" "1.15")
$decayAfterNon429 = [int](Get-ConfigValue "DECAY_AFTER_NON_429" "3")
$decaySeconds = [int](Get-ConfigValue "DECAY_SECONDS" "15")
$maxAttempts = [int](Get-ConfigValue "MAX_ATTEMPTS" "0")
$existingCheckEveryAttempts = [int](Get-ConfigValue "EXISTING_CHECK_EVERY_ATTEMPTS" "20")
$defaultRegion = Get-ConfigValue "DEFAULT_REGION" ""
$regionRotationRaw = Get-ConfigValue "REGION_ROTATION" ""
$regionRotation = @()
if (-not [string]::IsNullOrWhiteSpace($regionRotationRaw)) {
    $regionRotation = @($regionRotationRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$compartmentId = Get-ConfigValue "COMPARTMENT_ID"
$availabilityDomain = Get-ConfigValue "AVAILABILITY_DOMAIN"
$subnetId = Get-ConfigValue "SUBNET_ID"
$imageId = Get-ConfigValue "IMAGE_ID"
$instanceName = Get-ConfigValue "INSTANCE_NAME" "oci-free-tier-a1"
$instanceNamePrefix = Get-ConfigValue "INSTANCE_NAME_PREFIX" $instanceName
$targetInstanceCount = [int](Get-ConfigValue "TARGET_INSTANCE_COUNT" "1")
$sshPublicKey = Get-ConfigValue "SSH_PUBLIC_KEY"
$sshKeyFile = Get-ConfigValue "SSH_KEY_FILE" (Join-Path $HOME ".ssh\oci_key.pub")

$shape = Get-ConfigValue "OCI_SHAPE" "VM.Standard.A1.Flex"
$ocpus = Get-ConfigValue "OCPUS" "4"
$memoryGb = Get-ConfigValue "MEMORY_GB" "24"
$bootVolumeGb = Get-ConfigValue "BOOT_VOLUME_GB" "100"
$assignPublicIp = Get-ConfigValue "ASSIGN_PUBLIC_IP" "true"
$upgradeAfterCreate = (Get-ConfigValue "UPGRADE_AFTER_CREATE" "false") -match '^(1|true|yes)$'
$upgradeStepsRaw = Get-ConfigValue "UPGRADE_STEPS" ""
$upgradeOcpus = Get-ConfigValue "UPGRADE_OCPUS" $ocpus
$upgradeMemoryGb = Get-ConfigValue "UPGRADE_MEMORY_GB" $memoryGb
$upgradeSteps = @()

if ($upgradeAfterCreate) {
    if (-not [string]::IsNullOrWhiteSpace($upgradeStepsRaw)) {
        foreach ($step in ($upgradeStepsRaw -split ",")) {
            $trimmedStep = $step.Trim()
            if ($trimmedStep -match '^([0-9]+(?:\.[0-9]+)?)\s*[:/]\s*([0-9]+(?:\.[0-9]+)?)$') {
                $upgradeSteps += [pscustomobject]@{
                    Ocpus = [double]$matches[1]
                    MemoryGb = [double]$matches[2]
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($trimmedStep)) {
                throw "Invalid UPGRADE_STEPS item: $trimmedStep. Use format like 2:12,4:24"
            }
        }
    } else {
        $upgradeSteps += [pscustomobject]@{
            Ocpus = [double]$upgradeOcpus
            MemoryGb = [double]$upgradeMemoryGb
        }
    }
}

if ($targetInstanceCount -lt 1) {
    throw "TARGET_INSTANCE_COUNT must be at least 1"
}

if ($upgradeAfterCreate -and $targetInstanceCount -ne 1) {
    throw "UPGRADE_AFTER_CREATE requires TARGET_INSTANCE_COUNT=1"
}

if ($upgradeAfterCreate -and $upgradeSteps.Count -lt 1) {
    throw "UPGRADE_AFTER_CREATE requires at least one upgrade target"
}

if ($existingCheckEveryAttempts -lt 1) {
    throw "EXISTING_CHECK_EVERY_ATTEMPTS must be at least 1"
}

Require-ConfigValue "OCI_CLI_BIN" $oci
Require-ConfigValue "OCI_CONFIG_FILE" $ociConfig
Require-ConfigValue "COMPARTMENT_ID" $compartmentId
Require-ConfigValue "AVAILABILITY_DOMAIN" $availabilityDomain
Require-ConfigValue "SUBNET_ID" $subnetId
Require-ConfigValue "IMAGE_ID" $imageId

if (-not (Test-Path -LiteralPath $oci)) {
    throw "OCI CLI not found: $oci"
}
if (-not (Test-Path -LiteralPath $ociConfig)) {
    throw "OCI config file not found: $ociConfig"
}

$env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = Get-ConfigValue "OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING" "True"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
    Add-LogContent "${timestamp}: $Message"
}

function Add-LogContent {
    param([string]$Value)

    $directory = Split-Path -Parent $logFile
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
                try {
                    $writer.WriteLine($Value)
                } finally {
                    $writer.Dispose()
                }
            } finally {
                if ($stream) {
                    $stream.Dispose()
                }
            }
            return
        } catch {
            if ($attempt -eq 5) {
                Write-Warning "Log write failed: $($_.Exception.Message)"
                return
            }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

function Get-RegionConfigKey {
    param(
        [string]$Region,
        [string]$Suffix
    )

    $regionKey = $Region.ToUpperInvariant().Replace("-", "_")
    return "REGION_${regionKey}_${Suffix}"
}

function Get-RegionConfigValue {
    param(
        [string]$Region,
        [string]$Suffix,
        [string]$GlobalValue = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Region)) {
        $key = Get-RegionConfigKey -Region $Region -Suffix $Suffix
        $value = Get-ConfigValue $key ""
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    if ([string]::IsNullOrWhiteSpace($Region) -or [string]::IsNullOrWhiteSpace($defaultRegion) -or $Region -eq $defaultRegion) {
        return $GlobalValue
    }

    return ""
}

function Invoke-OciCommand {
    param(
        [string]$Region,
        [array]$Arguments
    )

    $args = @(
        "--config-file", $ociConfig,
        "--profile", $ociProfile,
        "--connection-timeout", $ociConnectionTimeoutSeconds.ToString(),
        "--read-timeout", $ociReadTimeoutSeconds.ToString()
    )
    if (-not [string]::IsNullOrWhiteSpace($Region)) {
        $args += @("--region", $Region)
    }
    $args += $Arguments

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $result = & $oci @args 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $result
        Text = ($result | Out-String)
    }
}

function Resolve-RegionTarget {
    param([string]$Region)

    $regionLabel = if ([string]::IsNullOrWhiteSpace($Region)) { "default" } else { $Region }
    $resolvedAd = Get-RegionConfigValue -Region $Region -Suffix "AVAILABILITY_DOMAIN" -GlobalValue $availabilityDomain
    $resolvedSubnet = Get-RegionConfigValue -Region $Region -Suffix "SUBNET_ID" -GlobalValue $subnetId
    $resolvedImage = Get-RegionConfigValue -Region $Region -Suffix "IMAGE_ID" -GlobalValue $imageId
    $resolvedSubnetName = Get-RegionConfigValue -Region $Region -Suffix "SUBNET_NAME" -GlobalValue (Get-ConfigValue "SUBNET_NAME" "")

    if ([string]::IsNullOrWhiteSpace($resolvedAd)) {
        $adResult = Invoke-OciCommand -Region $Region -Arguments @(
            "iam", "availability-domain", "list",
            "--compartment-id", $compartmentId,
            "--query", "data[0].name",
            "--raw-output"
        )
        if ($adResult.ExitCode -ne 0) {
            Write-Log "Region skipped: region=$regionLabel reason=availability-domain lookup failed output=$($adResult.Text.Trim())"
            return $null
        }
        $resolvedAd = $adResult.Text.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($resolvedSubnet) -and -not [string]::IsNullOrWhiteSpace($resolvedSubnetName)) {
        $subnetResult = Invoke-OciCommand -Region $Region -Arguments @(
            "network", "subnet", "list",
            "--compartment-id", $compartmentId,
            "--display-name", $resolvedSubnetName,
            "--all",
            "--query", "data[0].id",
            "--raw-output"
        )
        if ($subnetResult.ExitCode -eq 0) {
            $resolvedSubnet = $subnetResult.Text.Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedImage)) {
        $imageResult = Invoke-OciCommand -Region $Region -Arguments @(
            "compute", "image", "list",
            "--compartment-id", $compartmentId,
            "--operating-system", (Get-ConfigValue "IMAGE_OPERATING_SYSTEM" "Canonical Ubuntu"),
            "--operating-system-version", (Get-ConfigValue "IMAGE_OPERATING_SYSTEM_VERSION" "24.04 Minimal aarch64"),
            "--shape", $shape,
            "--sort-by", "TIMECREATED",
            "--sort-order", "DESC",
            "--all",
            "--query", "data[0].id",
            "--raw-output"
        )
        if ($imageResult.ExitCode -ne 0) {
            Write-Log "Region skipped: region=$regionLabel reason=image lookup failed output=$($imageResult.Text.Trim())"
            return $null
        }
        $resolvedImage = $imageResult.Text.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($resolvedSubnet) -or $resolvedSubnet -eq "null") {
        Write-Log "Region skipped: region=$regionLabel reason=subnet not configured"
        return $null
    }

    return [pscustomobject]@{
        Region = $Region
        Label = $regionLabel
        AvailabilityDomain = $resolvedAd
        SubnetId = $resolvedSubnet
        ImageId = $resolvedImage
    }
}

function Get-RegionCandidates {
    if ($regionRotation.Count -gt 0) {
        return @($regionRotation)
    }

    return @("")
}

function Get-ResolvedRegionTargets {
    $targets = @()
    foreach ($region in (Get-RegionCandidates)) {
        $target = Resolve-RegionTarget -Region $region
        if ($null -ne $target) {
            $targets += $target
        }
    }
    return $targets
}

function Get-CreateRegionTarget {
    $candidates = @(Get-RegionCandidates)
    if ($candidates.Count -eq 0) {
        return $null
    }

    for ($offset = 0; $offset -lt $candidates.Count; $offset++) {
        $index = (($script:attempt - 1 + $offset) % $candidates.Count)
        $target = Resolve-RegionTarget -Region $candidates[$index]
        if ($null -ne $target) {
            return $target
        }
    }

    return $null
}

function Read-ThrottleState {
    if (Test-Path -LiteralPath $throttleStateFile) {
        try {
            $state = Get-Content -LiteralPath $throttleStateFile -Raw | ConvertFrom-Json
            $current = [int]$state.CurrentIntervalSeconds
            $current = [Math]::Max($minIntervalSeconds, [Math]::Min($current, $maxIntervalSeconds))
            return [pscustomobject]@{
                CurrentIntervalSeconds = $current
                ConsecutiveNon429 = [int]$state.ConsecutiveNon429
            }
        } catch {
            Write-Log "Throttle state unreadable. Resetting: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        CurrentIntervalSeconds = $intervalSeconds
        ConsecutiveNon429 = 0
    }
}

function Write-ThrottleState {
    param([object]$State)

    $parent = Split-Path -Parent $throttleStateFile
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $State | ConvertTo-Json | Set-Content -LiteralPath $throttleStateFile -Encoding ascii
}

function Get-AdaptiveSleepSeconds {
    param(
        [int]$ResultCode,
        [object]$State
    )

    $current = [int]$State.CurrentIntervalSeconds
    $non429 = [int]$State.ConsecutiveNon429

    if ($ResultCode -eq 2) {
        $current = [Math]::Max($rateLimitBackoffSeconds, [Math]::Ceiling($current * $rateLimitMultiplier))
        $current = [Math]::Min($current, $maxIntervalSeconds)
        $non429 = 0
        Write-Log "429 detected. Increasing interval to $current seconds."
    } elseif ($ResultCode -eq 1) {
        $non429++
        if ($decayAfterNon429 -gt 0 -and $non429 -ge $decayAfterNon429) {
            $current = [Math]::Max($minIntervalSeconds, $current - $decaySeconds)
            $non429 = 0
            Write-Log "No 429 for $decayAfterNon429 attempts. Decreasing interval to $current seconds."
        }
    }

    $State.CurrentIntervalSeconds = $current
    $State.ConsecutiveNon429 = $non429
    Write-ThrottleState $State

    $sleepSeconds = $current
    if ($jitterSeconds -gt 0) {
        $sleepSeconds += Get-Random -Minimum 0 -Maximum ($jitterSeconds + 1)
    }

    return $sleepSeconds
}

function Should-CheckExistingInstances {
    if ($ValidateOnly) {
        return $true
    }

    if ($script:attempt -le 1) {
        return $true
    }

    return ((($script:attempt - 1) % $existingCheckEveryAttempts) -eq 0)
}

function Get-TargetInstanceName {
    param([array]$ExistingInstances)

    if ($targetInstanceCount -eq 1) {
        return $instanceName
    }

    $existingNames = @{}
    foreach ($instance in $ExistingInstances) {
        $existingNames[[string]$instance.'display-name'] = $true
    }

    for ($index = 1; $index -le $targetInstanceCount; $index++) {
        $candidate = "$instanceNamePrefix-$index"
        if (-not $existingNames.ContainsKey($candidate)) {
            return $candidate
        }
    }

    return "$instanceNamePrefix-$((Get-Date).ToString('yyyyMMddHHmmss'))"
}

function Get-TargetInstancesForRegion {
    param([object]$RegionTarget)

    $result = Invoke-OciCommand -Region $RegionTarget.Region -Arguments @(
        "compute", "instance", "list",
        "--compartment-id", $compartmentId,
        "--all",
        "--output", "json"
    )

    if ($result.ExitCode -ne 0) {
        Write-Log "Region skipped: region=$($RegionTarget.Label) reason=instance list failed output=$($result.Text.Trim())"
        return @()
    }

    $resultText = $result.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($resultText)) {
        return @()
    }

    $parsed = $resultText | ConvertFrom-Json
    $instances = @()
    if ($null -ne $parsed.data) {
        $instances = @($parsed.data)
    } else {
        $instances = @($parsed)
    }

    $matchingInstances = @(
        $instances | Where-Object {
            $name = [string]$_.'display-name'
            $state = [string]$_.'lifecycle-state'
            ($name -eq $instanceNamePrefix -or $name.StartsWith("$instanceNamePrefix-")) -and
                $state -notin @("TERMINATED", "TERMINATING")
        }
    )

    foreach ($instance in $matchingInstances) {
        $instance | Add-Member -NotePropertyName "__region" -NotePropertyValue $RegionTarget.Region -Force
        $instance | Add-Member -NotePropertyName "__regionLabel" -NotePropertyValue $RegionTarget.Label -Force
    }

    return $matchingInstances
}

function Get-TargetInstances {
    $instances = @()
    foreach ($target in (Get-ResolvedRegionTargets)) {
        $instances += @(Get-TargetInstancesForRegion -RegionTarget $target)
    }
    return $instances
}

function Get-ShapeConfigValue {
    param(
        [object]$Instance,
        [string]$Name
    )

    if ($null -eq $Instance -or $null -eq $Instance.'shape-config') {
        return 0
    }

    $shapeConfig = $Instance.'shape-config'
    $property = $shapeConfig.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return 0
    }

    return [double]$property.Value
}

function Test-InstanceUpgraded {
    param([object]$Instance)

    if (-not $upgradeAfterCreate) {
        return $true
    }

    $currentOcpus = Get-ShapeConfigValue -Instance $Instance -Name "ocpus"
    $currentMemoryGb = Get-ShapeConfigValue -Instance $Instance -Name "memory-in-gbs"
    $finalStep = $upgradeSteps[$upgradeSteps.Count - 1]
    return ($currentOcpus -ge [double]$finalStep.Ocpus -and $currentMemoryGb -ge [double]$finalStep.MemoryGb)
}

function Get-NextUpgradeStep {
    param([object]$Instance)

    $currentOcpus = Get-ShapeConfigValue -Instance $Instance -Name "ocpus"
    $currentMemoryGb = Get-ShapeConfigValue -Instance $Instance -Name "memory-in-gbs"

    foreach ($step in $upgradeSteps) {
        if ($currentOcpus -lt [double]$step.Ocpus -or $currentMemoryGb -lt [double]$step.MemoryGb) {
            return $step
        }
    }

    return $null
}

function Get-PrimaryTargetInstance {
    param([array]$ExistingInstances)

    $exact = @($ExistingInstances | Where-Object { [string]$_.'display-name' -eq $instanceName })
    if ($exact.Count -gt 0) {
        return $exact[0]
    }

    if ($ExistingInstances.Count -gt 0) {
        return @($ExistingInstances | Sort-Object 'time-created')[0]
    }

    return $null
}

function Test-TargetReached {
    param(
        [array]$ExistingInstances = $null,
        [switch]$WriteSuccessFlag
    )

    $instances = $ExistingInstances
    if ($null -eq $instances) {
        $instances = @(Get-TargetInstances)
    }

    $count = $instances.Count
    $names = ($instances | ForEach-Object {
        $currentOcpus = Get-ShapeConfigValue -Instance $_ -Name "ocpus"
        $currentMemoryGb = Get-ShapeConfigValue -Instance $_ -Name "memory-in-gbs"
        "$($_.'display-name'):$($_.'lifecycle-state'):${currentOcpus}ocpu/${currentMemoryGb}gb"
    }) -join ", "
    if ([string]::IsNullOrWhiteSpace($names)) {
        $names = "none"
    }

    Write-Log "Target instance check: count=$count target=$targetInstanceCount instances=$names"
    if ($count -ge $targetInstanceCount -and @($instances | Where-Object { -not (Test-InstanceUpgraded -Instance $_) }).Count -eq 0) {
        if ($WriteSuccessFlag) {
            New-Item -ItemType File -Force -Path $successFlag | Out-Null
            Write-Log "Target reached. Success flag created: $successFlag"
        }
        return $true
    }

    if ($count -ge $targetInstanceCount -and $upgradeAfterCreate) {
        $finalStep = $upgradeSteps[$upgradeSteps.Count - 1]
        Write-Log "Target instance exists, upgrade pending: desired=$($finalStep.Ocpus)ocpu/$($finalStep.MemoryGb)gb"
    }

    return $false
}

function Invoke-UpgradeAttempt {
    param([object]$Instance)

    if ($null -eq $Instance) {
        return 1
    }

    $instanceId = [string]$Instance.id
    $instanceDisplayName = [string]$Instance.'display-name'
    $instanceRegion = [string]$Instance.__region
    $instanceRegionLabel = [string]$Instance.__regionLabel
    $currentOcpus = Get-ShapeConfigValue -Instance $Instance -Name "ocpus"
    $currentMemoryGb = Get-ShapeConfigValue -Instance $Instance -Name "memory-in-gbs"
    $nextStep = Get-NextUpgradeStep -Instance $Instance
    $tempShapeConfigFile = $null

    if ($null -eq $nextStep) {
        Test-TargetReached -WriteSuccessFlag | Out-Null
        return 0
    }

    try {
        Write-Log "Attempting to upgrade instance: region=$instanceRegionLabel name=$instanceDisplayName id=$instanceId current=${currentOcpus}ocpu/${currentMemoryGb}gb target=$($nextStep.Ocpus)ocpu/$($nextStep.MemoryGb)gb"

        $tempShapeConfigFile = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $tempShapeConfigFile -Value "{`"ocpus`": $($nextStep.Ocpus), `"memoryInGBs`": $($nextStep.MemoryGb)}" -Encoding ascii
        $shapeConfig = "file://$($tempShapeConfigFile.Replace('\', '/'))"
        $result = Invoke-OciCommand -Region $instanceRegion -Arguments @(
            "compute", "instance", "update",
            "--instance-id", $instanceId,
            "--shape-config", $shapeConfig,
            "--force"
        )

        if ($result.ExitCode -eq 0) {
            Write-Log "Upgrade request succeeded: $instanceDisplayName"
            Add-LogContent $result.Text
            Test-TargetReached -WriteSuccessFlag | Out-Null
            return 0
        }

        $resultText = $result.Text
        Write-Log "Upgrade failed (exit code: $($result.ExitCode))"
        Add-LogContent $resultText
        Add-LogContent "---"
        if ($resultText -match "TooManyRequests|`"status`": 429|status': 429") {
            return 2
        }
        if ($resultText -match "timed out|timeout|RequestException") {
            return 3
        }
        return 1
    } finally {
        if ($tempShapeConfigFile -and (Test-Path -LiteralPath $tempShapeConfigFile)) {
            Remove-Item -LiteralPath $tempShapeConfigFile -Force
        }
    }
}

function Invoke-CreateAttempt {
    if (Test-Path -LiteralPath $successFlag) {
        Write-Log "Success flag exists. Nothing to do."
        return 0
    }

    $shouldCheckExisting = Should-CheckExistingInstances
    if ($shouldCheckExisting) {
        $existingInstances = @(Get-TargetInstances)
    } else {
        $existingInstances = @()
        Write-Log "Skipping target instance check to reduce OCI API calls: attempt=$script:attempt nextCheckEvery=$existingCheckEveryAttempts"
    }

    if ($ValidateOnly) {
        Test-TargetReached -ExistingInstances $existingInstances | Out-Null
    } elseif ($shouldCheckExisting -and (Test-TargetReached -ExistingInstances $existingInstances -WriteSuccessFlag)) {
        return 0
    }

    if (-not $ValidateOnly -and $shouldCheckExisting -and $upgradeAfterCreate -and $existingInstances.Count -ge $targetInstanceCount) {
        $primaryInstance = Get-PrimaryTargetInstance -ExistingInstances $existingInstances
        return Invoke-UpgradeAttempt -Instance $primaryInstance
    }

    $tempKeyFile = $null
    $tempShapeConfigFile = $null
    $tempSourceDetailsFile = $null
    $authorizedKeyFile = $sshKeyFile
    if (-not [string]::IsNullOrWhiteSpace($sshPublicKey)) {
        $tempKeyFile = Join-Path $env:TEMP "oci-instance-creator-ssh-key-$PID.pub"
        Set-Content -LiteralPath $tempKeyFile -Value $sshPublicKey -Encoding ascii
        $authorizedKeyFile = $tempKeyFile
    } elseif (-not (Test-Path -LiteralPath $sshKeyFile)) {
        throw "SSH public key file not found: $sshKeyFile"
    }

    try {
        if ($ValidateOnly) {
            $resolvedLabels = (@(Get-ResolvedRegionTargets) | ForEach-Object { $_.Label }) -join ","
            Write-Log "Validation passed: namePrefix=$instanceNamePrefix target=$targetInstanceCount upgradeAfterCreate=$upgradeAfterCreate regions=$resolvedLabels"
            Write-Output "Validation passed."
            return 0
        }

        $regionTarget = Get-CreateRegionTarget
        if ($null -eq $regionTarget) {
            Write-Log "No usable region target found."
            return 1
        }

        $createInstanceName = Get-TargetInstanceName -ExistingInstances $existingInstances
        Write-Log "Attempting to create instance: region=$($regionTarget.Label) name=$createInstanceName target=$targetInstanceCount existing=$($existingInstances.Count) shape=$shape ocpus=$ocpus memoryGB=$memoryGb publicIp=$assignPublicIp"

        $tempShapeConfigFile = [System.IO.Path]::GetTempFileName()
        $tempSourceDetailsFile = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $tempShapeConfigFile -Value "{`"ocpus`": $ocpus, `"memoryInGBs`": $memoryGb}" -Encoding ascii
        Set-Content -LiteralPath $tempSourceDetailsFile -Value "{`"sourceType`":`"image`",`"imageId`":`"$($regionTarget.ImageId)`",`"bootVolumeSizeInGBs`":$bootVolumeGb}" -Encoding ascii
        $shapeConfig = "file://$($tempShapeConfigFile.Replace('\', '/'))"
        $sourceDetails = "file://$($tempSourceDetailsFile.Replace('\', '/'))"
        $result = Invoke-OciCommand -Region $regionTarget.Region -Arguments @(
            "compute", "instance", "launch",
            "--compartment-id", $compartmentId,
            "--availability-domain", $regionTarget.AvailabilityDomain,
            "--shape", $shape,
            "--shape-config", $shapeConfig,
            "--subnet-id", $regionTarget.SubnetId,
            "--source-details", $sourceDetails,
            "--assign-public-ip", $assignPublicIp,
            "--ssh-authorized-keys-file", $authorizedKeyFile,
            "--display-name", $createInstanceName
        )

        if ($result.ExitCode -eq 0 -and ($result.Text -match "ocid1.instance")) {
            Write-Log "Create request succeeded: $createInstanceName"
            Add-LogContent $result.Text
            $createdInstances = @(Get-TargetInstances)
            if ($createdInstances.Count -ge $targetInstanceCount -and $upgradeAfterCreate) {
                $primaryInstance = Get-PrimaryTargetInstance -ExistingInstances $createdInstances
                Invoke-UpgradeAttempt -Instance $primaryInstance | Out-Null
            } else {
                Test-TargetReached -ExistingInstances $createdInstances -WriteSuccessFlag | Out-Null
            }
            return 0
        }

        $resultText = $result.Text
        Write-Log "Failed (exit code: $($result.ExitCode))"
        Add-LogContent $resultText
        Add-LogContent "---"
        if ($resultText -match "TooManyRequests|`"status`": 429|status': 429") {
            return 2
        }
        if ($resultText -match "timed out|timeout|RequestException") {
            return 3
        }
        return 1
    } finally {
        if ($tempKeyFile -and (Test-Path -LiteralPath $tempKeyFile)) {
            Remove-Item -LiteralPath $tempKeyFile -Force
        }
        if ($tempShapeConfigFile -and (Test-Path -LiteralPath $tempShapeConfigFile)) {
            Remove-Item -LiteralPath $tempShapeConfigFile -Force
        }
        if ($tempSourceDetailsFile -and (Test-Path -LiteralPath $tempSourceDetailsFile)) {
            Remove-Item -LiteralPath $tempSourceDetailsFile -Force
        }
    }
}

$script:attempt = 1
$throttleState = Read-ThrottleState
Write-Log "Throttle state loaded: interval=$($throttleState.CurrentIntervalSeconds) consecutiveNon429=$($throttleState.ConsecutiveNon429)"
while (-not (Test-Path -LiteralPath $successFlag)) {
    if ($maxAttempts -gt 0 -and $script:attempt -gt $maxAttempts) {
        Write-Output "Max attempts reached: $maxAttempts"
        exit 1
    }

    Write-Output "Attempt $script:attempt at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
    $resultCode = Invoke-CreateAttempt

    if ($ValidateOnly -or $Once -or (Test-Path -LiteralPath $successFlag)) {
        exit $resultCode
    }

    $sleepSeconds = Get-AdaptiveSleepSeconds -ResultCode $resultCode -State $throttleState
    Write-Output "Sleeping $sleepSeconds seconds"
    Write-Log "Sleeping $sleepSeconds seconds before next attempt."

    $script:attempt++
    Start-Sleep -Seconds $sleepSeconds
}

Write-Output "Success flag already exists: $successFlag"
