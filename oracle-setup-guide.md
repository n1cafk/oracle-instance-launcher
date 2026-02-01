# Oracle Cloud Always Free 實例自動創建器 - 設置指南

## 前提條件

### 1. 安裝 OCI CLI

在 PowerShell 中執行：
```powershell
# 使用官方安裝腳本
Invoke-WebRequest https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1 -OutFile install.ps1
.\install.ps1 -AcceptAllDefaults
```

### 2. 配置 OCI CLI

```powershell
oci setup config
```

需要準備以下資料（從 OCI Console 獲取）：
- User OCID: `Profile` → `My Profile` → OCID
- Tenancy OCID: `Profile` → `Tenancy` → OCID  
- Region: 例如 `ap-singapore-1`, `ap-tokyo-1`
- 產生 API Key 並上傳公鑰到 OCI

## 獲取配置值

### Compartment OCID
1. OCI Console → `Identity & Security` → `Compartments`
2. 點擊你的 Compartment → 複製 OCID

### Availability Domain
1. OCI Console → `Compute` → `Instances`
2. 點擊 `Create Instance` 
3. 查看 `Availability Domain` 下拉選單的值

### Subnet OCID
1. OCI Console → `Networking` → `Virtual Cloud Networks`
2. 選擇你的 VCN → `Subnets`
3. 選擇一個 **Public Subnet** → 複製 OCID

### Image OCID (推薦使用 Oracle Linux 或 Ubuntu)
1. OCI Console → `Compute` → `Instances`
2. 點擊 `Create Instance`
3. 在 `Image and shape` 選擇 OS
4. 選擇 ARM 相容的 Image (例如 Oracle Linux 8 - aarch64)
5. 在 URL 中或頁面上找到 Image OCID

**常用 Image OCID (Singapore Region):**
- 需要從 OCI Console 獲取最新的 Image OCID

### SSH 公鑰
如果沒有，生成一個：
```powershell
ssh-keygen -t rsa -b 4096 -f $env:USERPROFILE\.ssh\id_rsa
```

## Always Free 資源限制

| 資源 | 上限 |
|------|------|
| ARM (A1.Flex) OCPU | 4 個總共 |
| ARM (A1.Flex) 記憶體 | 24 GB 總共 |
| Boot Volume | 200 GB 總共 |
| AMD (E2.1.Micro) | 2 個實例 |

**注意:** ARM 資源可以分配到 1-4 個實例，腳本預設使用單一實例用盡所有配額。

## 修改腳本配置

編輯 `oracle-instance-launcher.ps1`，填入你的值：

```powershell
$CONFIG = @{
    CompartmentId      = "ocid1.compartment.oc1..你的值"
    AvailabilityDomain = "xxxx:AP-SINGAPORE-1-AD-1"
    SubnetId           = "ocid1.subnet.oc1.ap-singapore-1.你的值"
    ImageId            = "ocid1.image.oc1.ap-singapore-1.你的值"
    SshPublicKeyPath   = "C:\Users\yeung\.ssh\id_rsa.pub"
    # ... 其他配置 ...
}
```

## 執行腳本

```powershell
cd c:\Cursor
.\oracle-instance-launcher.ps1
```

腳本會每 90 秒嘗試創建一次，直到成功為止。

## 常見錯誤

| 錯誤 | 解決方案 |
|------|----------|
| Out of host capacity | 資源不足，繼續等待重試 |
| LimitExceeded | 已有實例佔用配額，刪除舊實例 |
| NotAuthorized | 檢查 API Key 是否正確上傳 |
| InvalidParameter | 檢查 OCID 格式是否正確 |

## 成功後

連接到實例：
```bash
ssh opc@<PUBLIC_IP>
```

然後就可以部署 OpenClaw 了！
