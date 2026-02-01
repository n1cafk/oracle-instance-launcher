#######################################################################
# Oracle Cloud Always Free Instance Auto-Launcher
# Retry every 90 seconds to create OCI instance for OpenClaw deployment
# Always Free ARM limit: 4 OCPU, 24GB RAM, 200GB Boot Volume
#######################################################################

# Suppress warnings
$env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = "True"
$env:SUPPRESS_LABEL_WARNING = "True"
$env:Path += ";$env:USERPROFILE\bin"

# ========================= Configuration =========================

$CONFIG = @{
    # OCI Resources (from your account)
    CompartmentId      = "ocid1.tenancy.oc1..aaaaaaaa7fcsjjychxoo6dbh3olzujvcrsm4rbqj5o4fiayzhsmtfdxoxqjq"
    AvailabilityDomain = "nIzJ:AP-SINGAPORE-1-AD-1"
    SubnetId           = "ocid1.subnet.oc1.ap-singapore-1.aaaaaaaadyy6k2ama3xrtm6j63hl7bu4zvffso7mewkhiiuwtgmfqscc7n6a"
    ImageId            = "ocid1.image.oc1.ap-singapore-1.aaaaaaaaoxse7qaw6z6nzgizzhcgu7vtwfrj4v32dzrphtlz7rgttbudauba"
    
    # Instance config - Always Free ARM max
    Shape               = "VM.Standard.A1.Flex"
    Ocpus               = 4
    MemoryInGBs         = 24
    BootVolumeSizeInGBs = 200
    
    # Instance name
    DisplayName         = "openclaw-server"
    
    # Retry settings
    RetryIntervalSeconds = 90
    
    # SSH key path
    SshKeyPath          = "$env:USERPROFILE\.ssh\oci_openclaw"
}

# Cloud-init script - Auto install Docker and prepare OpenClaw environment
$CLOUD_INIT_SCRIPT = @'
#!/bin/bash
set -e
dnf update -y
dnf install -y dnf-utils
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker opc
dnf install -y git wget curl vim nano htop
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=3000/tcp
firewall-cmd --reload
mkdir -p /home/opc/openclaw
chown opc:opc /home/opc/openclaw
echo "OpenClaw server setup completed at $(date)" > /home/opc/setup_complete.txt
chown opc:opc /home/opc/setup_complete.txt
'@

# ========================= Functions =========================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-SshPublicKey {
    $pubKeyPath = "$($CONFIG.SshKeyPath).pub"
    
    if (-not (Test-Path $pubKeyPath)) {
        Write-Log "SSH key not found, generating..." "INFO"
        
        $sshDir = Split-Path $CONFIG.SshKeyPath -Parent
        if (-not (Test-Path $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        }
        
        & ssh-keygen -t rsa -b 4096 -f $CONFIG.SshKeyPath -N '""' -q
        Write-Log "SSH key generated" "SUCCESS"
    }
    
    return Get-Content $pubKeyPath -Raw
}

function New-OciInstance {
    param([string]$SshPublicKey)
    
    # Convert cloud-init to base64
    $cloudInitBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($CLOUD_INIT_SCRIPT))
    
    # Create JSON files for OCI CLI
    $metadataJson = '{"ssh_authorized_keys": "' + $SshPublicKey.Trim() + '", "user_data": "' + $cloudInitBase64 + '"}'
    $metadataFile = "$env:TEMP\oci_metadata.json"
    [System.IO.File]::WriteAllText($metadataFile, $metadataJson)
    
    $shapeConfigJson = '{"ocpus": ' + $CONFIG.Ocpus + ', "memoryInGBs": ' + $CONFIG.MemoryInGBs + '}'
    $shapeConfigFile = "$env:TEMP\oci_shape_config.json"
    [System.IO.File]::WriteAllText($shapeConfigFile, $shapeConfigJson)
    
    $sourceDetailsJson = '{"sourceType": "image", "imageId": "' + $CONFIG.ImageId + '", "bootVolumeSizeInGBs": ' + $CONFIG.BootVolumeSizeInGBs + '}'
    $sourceDetailsFile = "$env:TEMP\oci_source_details.json"
    [System.IO.File]::WriteAllText($sourceDetailsFile, $sourceDetailsJson)

    try {
        Write-Log "Attempting to create instance..." "INFO"
        
        $result = & "$env:USERPROFILE\bin\oci.exe" compute instance launch `
            --compartment-id $CONFIG.CompartmentId `
            --availability-domain $CONFIG.AvailabilityDomain `
            --shape $CONFIG.Shape `
            --display-name $CONFIG.DisplayName `
            --subnet-id $CONFIG.SubnetId `
            --assign-public-ip true `
            --shape-config "file://$shapeConfigFile" `
            --source-details "file://$sourceDetailsFile" `
            --metadata "file://$metadataFile" 2>&1
        
        $resultText = $result -join "`n"
        
        if ($resultText -match '"id"\s*:\s*"(ocid1\.instance\.[^"]+)"') {
            return @{
                Success = $true
                InstanceId = $matches[1]
                DisplayName = $CONFIG.DisplayName
            }
        }
        elseif ($resultText -match "Out of host capacity") {
            return @{ Success = $false; Error = "Out of host capacity - will retry"; Retry = $true }
        }
        elseif ($resultText -match "LimitExceeded") {
            return @{ Success = $false; Error = "Limit exceeded - delete existing instances first"; Retry = $false }
        }
        elseif ($resultText -match "TooManyRequests") {
            return @{ Success = $false; Error = "Too many requests - will retry"; Retry = $true }
        }
        elseif ($resultText -match "InternalError") {
            return @{ Success = $false; Error = "OCI internal error (likely Out of host capacity) - will retry"; Retry = $true }
        }
        elseif ($resultText -match "NotAuthorized") {
            return @{ Success = $false; Error = "Not authorized - check API key configuration"; Retry = $false }
        }
        else {
            if ($resultText -match "PROVISIONING" -or $resultText -match "lifecycle-state") {
                if ($resultText -match '"id"\s*:\s*"([^"]+)"') {
                    return @{
                        Success = $true
                        InstanceId = $matches[1]
                        DisplayName = $CONFIG.DisplayName
                    }
                }
            }
            $errMsg = $resultText
            if ($errMsg.Length -gt 300) { $errMsg = $errMsg.Substring(0, 300) }
            return @{ Success = $false; Error = "Error: $errMsg"; Retry = $true }
        }
    }
    finally {
        Remove-Item $metadataFile -ErrorAction SilentlyContinue
        Remove-Item $shapeConfigFile -ErrorAction SilentlyContinue
        Remove-Item $sourceDetailsFile -ErrorAction SilentlyContinue
    }
}

function Get-InstancePublicIp {
    param([string]$InstanceId)
    
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 15
        $waitTime = $i * 15
        Write-Host "`rWaiting for instance to start... ($waitTime s)  " -NoNewline -ForegroundColor DarkGray
        
        try {
            $vnicResult = & "$env:USERPROFILE\bin\oci.exe" compute vnic-attachment list --compartment-id $CONFIG.CompartmentId --instance-id $InstanceId 2>&1
            $vnicText = $vnicResult -join "`n"
            
            if ($vnicText -match '"vnic-id"\s*:\s*"([^"]+)"') {
                $vnicId = $matches[1]
                
                $vnicDetails = & "$env:USERPROFILE\bin\oci.exe" network vnic get --vnic-id $vnicId 2>&1
                $vnicDetailsText = $vnicDetails -join "`n"
                
                if ($vnicDetailsText -match '"public-ip"\s*:\s*"([^"]+)"') {
                    Write-Host ""
                    return $matches[1]
                }
            }
        }
        catch {
            # Continue waiting
        }
    }
    
    Write-Host ""
    return $null
}

# ========================= Main Program =========================

Clear-Host
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "  |                                                              |" -ForegroundColor Cyan
Write-Host "  |     Oracle Cloud Always Free Instance Auto-Launcher          |" -ForegroundColor Cyan
Write-Host "  |     For OpenClaw Deployment                                  |" -ForegroundColor Cyan
Write-Host "  |                                                              |" -ForegroundColor Cyan
Write-Host "  |     Config: 4 OCPU | 24GB RAM | 200GB Disk | ARM (A1.Flex)  |" -ForegroundColor Cyan
Write-Host "  |                                                              |" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

# Get SSH key
Write-Log "Checking SSH key..." "INFO"
$sshPublicKey = Get-SshPublicKey

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Yellow
Write-Host "  |  SSH Public Key (for server connection):                     |" -ForegroundColor Yellow
Write-Host "  ================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host $sshPublicKey -ForegroundColor Gray
Write-Host ""

Write-Log "SSH key ready: $($CONFIG.SshKeyPath)" "SUCCESS"

Write-Host ""
Write-Host "  Configuration Summary:" -ForegroundColor DarkGray
Write-Host "  - Region: ap-singapore-1" -ForegroundColor DarkGray
Write-Host "  - Shape: $($CONFIG.Shape)" -ForegroundColor DarkGray
Write-Host "  - OCPU: $($CONFIG.Ocpus)" -ForegroundColor DarkGray
Write-Host "  - Memory: $($CONFIG.MemoryInGBs) GB" -ForegroundColor DarkGray
Write-Host "  - Boot Volume: $($CONFIG.BootVolumeSizeInGBs) GB" -ForegroundColor DarkGray
Write-Host "  - OS: Oracle Linux 8 (ARM)" -ForegroundColor DarkGray
Write-Host "  - Retry Interval: $($CONFIG.RetryIntervalSeconds) seconds" -ForegroundColor DarkGray
Write-Host ""

Write-Log "Starting instance creation (retry every $($CONFIG.RetryIntervalSeconds) seconds)..." "INFO"
Write-Host ""

$attemptCount = 0
$startTime = Get-Date

while ($true) {
    $attemptCount++
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    
    Write-Log "Attempt #$attemptCount (running for $elapsed minutes)" "INFO"
    
    $result = New-OciInstance -SshPublicKey $sshPublicKey
    
    if ($result.Success) {
        Write-Host ""
        Write-Log "Instance created successfully!" "SUCCESS"
        Write-Host ""
        Write-Host "  ================================================================" -ForegroundColor Green
        Write-Host "  |                  INSTANCE CREATED SUCCESSFULLY!              |" -ForegroundColor Green
        Write-Host "  ================================================================" -ForegroundColor Green
        Write-Host "  Instance ID: $($result.InstanceId)" -ForegroundColor Green
        Write-Host "  Name: $($result.DisplayName)" -ForegroundColor Green
        Write-Host "  ================================================================" -ForegroundColor Green
        
        Write-Log "Getting Public IP (waiting 2-5 minutes for instance to start)..." "INFO"
        $publicIp = Get-InstancePublicIp -InstanceId $result.InstanceId
        
        Write-Host ""
        if ($publicIp) {
            Write-Host "  ================================================================" -ForegroundColor Cyan
            Write-Host "  |                    CONNECTION INFO                          |" -ForegroundColor Cyan
            Write-Host "  ================================================================" -ForegroundColor Cyan
            Write-Host "  Public IP: $publicIp" -ForegroundColor Cyan
            Write-Host "" -ForegroundColor Cyan
            Write-Host "  SSH Command:" -ForegroundColor Cyan
            Write-Host "  ssh -i $($CONFIG.SshKeyPath) opc@$publicIp" -ForegroundColor Yellow
            Write-Host "  ================================================================" -ForegroundColor Cyan
            
            # Save connection info
            $infoFile = "c:\Cursor\openclaw-server-info.txt"
            $infoContent = @"
OpenClaw Server Information
============================
Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Instance ID: $($result.InstanceId)
Public IP: $publicIp

SSH Command:
ssh -i $($CONFIG.SshKeyPath) opc@$publicIp

SSH Private Key: $($CONFIG.SshKeyPath)
SSH Public Key: $($CONFIG.SshKeyPath).pub

Cloud-init auto-installs:
- Docker and Docker Compose
- Git, wget, curl, vim, htop
- Firewall opens ports: 22, 80, 443, 3000, 8080

OpenClaw directory: /home/opc/openclaw

Check setup status:
cat /home/opc/setup_complete.txt
"@
            $infoContent | Out-File -FilePath $infoFile -Encoding UTF8
            
            Write-Log "Connection info saved to: $infoFile" "INFO"
        }
        else {
            Write-Log "Could not get Public IP, please check OCI Console" "WARNING"
        }
        
        # Play notification sound
        [System.Console]::Beep(523, 200)
        [System.Console]::Beep(659, 200)
        [System.Console]::Beep(784, 200)
        [System.Console]::Beep(1047, 400)
        
        Write-Host ""
        Write-Log "Done! Total attempts: $attemptCount, Time elapsed: $elapsed minutes" "SUCCESS"
        Write-Host ""
        Write-Host "  Cloud-init is installing Docker in background, wait 5-10 minutes" -ForegroundColor Yellow
        Write-Host "  After login, run: cat /home/opc/setup_complete.txt" -ForegroundColor Yellow
        Write-Host ""
        break
    }
    else {
        Write-Log $result.Error "WARNING"
        
        if ($result.Retry -eq $false) {
            Write-Log "Error cannot be resolved by retry, please fix and run again" "ERROR"
            exit 1
        }
        
        Write-Log "Waiting $($CONFIG.RetryIntervalSeconds) seconds before retry..." "INFO"
        
        # Show countdown
        for ($i = $CONFIG.RetryIntervalSeconds; $i -gt 0; $i--) {
            Write-Host "`rNext attempt in: $i seconds  " -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
        Write-Host "`r                              `r" -NoNewline
        Write-Host ""
    }
}
