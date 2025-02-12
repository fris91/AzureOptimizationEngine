param(
    [Parameter(Mandatory = $false)]
    [string] $TargetSubscription = $null,

    [Parameter(Mandatory = $false)]
    [string] $externalCloudEnvironment = "",

    [Parameter(Mandatory = $false)]
    [string] $externalTenantId = "",

    [Parameter(Mandatory = $false)]
    [string] $externalCredentialName = "",

    [Parameter(Mandatory = $false)] 
    [string] $targetStartDate = "", # YYYY-MM-DD format

    [Parameter(Mandatory = $false)] 
    [string] $targetEndDate = "" # YYYY-MM-DD format
)

$ErrorActionPreference = "Stop"

function Authenticate-AzureWithOption {
    param (
        [string] $authOption = "ManagedIdentity",
        [string] $cloudEnv = "AzureCloud"
    )

    switch ($authOption) {
        "RunAsAccount" { 
            $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
            Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnv -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
            break
        }
        "ManagedIdentity" { 
            Connect-AzAccount -Identity -EnvironmentName $cloudEnv
            break
        }
        Default {
            $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
            Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnv -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
            break
        }
    }        
}

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name  "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "ManagedIdentity"
}

# get Consumption exports sink (storage account) details
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_ConsumptionContainer" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($storageAccountSinkContainer))
{
    $storageAccountSinkContainer = "consumptionexports"
}

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    $externalCredential = Get-AutomationPSCredential -Name $externalCredentialName
}

$consumptionOffsetDays = [int] (Get-AutomationVariable -Name  "AzureOptimization_ConsumptionOffsetDays")

$consumptionMetric = Get-AutomationVariable -Name  "AzureOptimization_ConsumptionMetric" -ErrorAction SilentlyContinue # AmortizedCost|ActualCost
if ([string]::IsNullOrEmpty($consumptionMetric))
{
    $consumptionMetric = "ActualCost"
}

$consumptionAPIOption = Get-AutomationVariable -Name  "AzureOptimization_ConsumptionAPIOption" -ErrorAction SilentlyContinue # CostDetails|UsageDetails
if ([string]::IsNullOrEmpty($consumptionMetric))
{
    $consumptionAPIOption = "CostDetails"
}

$consumptionScope = Get-AutomationVariable -Name  "AzureOptimization_ConsumptionScope" -ErrorAction SilentlyContinue # Subscription|BillingAccount
if ([string]::IsNullOrEmpty($consumptionScope))
{
    Write-Output "Consumption Scope not specified, defaulting to Subscription"
    $consumptionScope = "Subscription"
}
else
{
    Write-Output "Consumption Scope is $consumptionScope"
    if ($consumptionScope -eq "BillingAccount")
    {
        $BillingAccountID = Get-AutomationVariable -Name  "AzureOptimization_BillingAccountID"        
    }
    else
    {
        throw "Invalid value for AzureOptimization_ConsumptionScope. Valid values are 'Subscription' or 'BillingAccount'."
    }
}

Write-Output "Logging in to Azure with $authenticationOption..."

Authenticate-AzureWithOption -authOption $authenticationOption -cloudEnv $cloudEnvironment

# get reference to storage sink
Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    Connect-AzAccount -ServicePrincipal -EnvironmentName $externalCloudEnvironment -Tenant $externalTenantId -Credential $externalCredential 
    $cloudEnvironment = $externalCloudEnvironment   
}

# compute start+end dates

if ([string]::IsNullOrEmpty($targetStartDate) -or [string]::IsNullOrEmpty($targetEndDate))
{
    $targetStartDate = (Get-Date).Date.AddDays($consumptionOffsetDays * -1).ToString("yyyy-MM-dd")
    $targetEndDate = $targetStartDate    
}

if ($consumptionScope -eq "Subscription")
{
    if (-not([string]::IsNullOrEmpty($TargetSubscription)))
    {
        $subscriptions = Get-AzSubscription -SubscriptionId $TargetSubscription
    }
    else
    {
        $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
    }    
    Write-Output "Exporting consumption data from $targetStartDate to $targetEndDate for $($subscriptions.Count) subscriptions..."
}
else
{
    Write-Output "Exporting consumption data from $targetStartDate to $targetEndDate for Billing Account ID $BillingAccountID..."
}


# for each subscription, get billing data

$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

$hadErrors = $false

function Generate-CostDetails {
    param (        
        [string] $ScopeId,
        [string] $ScopeName 
    )

    $MaxTries = 9 # The typical Retry-After is set to 20 seconds. We'll give 3 minutes overall to download the cost details report

    $CostDetailsApiPath = "$ScopeId/providers/Microsoft.CostManagement/generateCostDetailsReport?api-version=2022-05-01"
    $body = "{ `"metric`": `"$consumptionMetric`", `"timePeriod`": { `"start`": `"$targetStartDate`", `"end`": `"$targetEndDate`" } }"
    $result = Invoke-AzRestMethod -Path $CostDetailsApiPath -Method POST -Payload $body
    $requestResultPath = $result.Headers.Location.PathAndQuery
    if ($result.StatusCode -in (200,202))
    {
        $tries = 0
        $requestSuccess = $false

        Write-Output "Obtained cost detail results endpoint: $requestResultPath..."

        Write-Output "Was told to wait $($result.Headers.RetryAfter.Delta.TotalSeconds) seconds."

        $sleepSeconds = 60
        if ($result.Headers.RetryAfter.Delta.TotalSeconds -gt 0)
        {
            $sleepSeconds = $result.Headers.RetryAfter.Delta.TotalSeconds
        }

        do
        {
            $tries++
            Write-Output "Checking whether export is ready (try $tries)..."
            
            Start-Sleep -Seconds $sleepSeconds
            $downloadResult = Invoke-AzRestMethod -Method GET -Path $requestResultPath

            if ($downloadResult.StatusCode -eq 200)
            {

                Write-Output "Export is ready. Proceeding with CSV download..."

                $downloadBlobJson = $downloadResult.Content | ConvertFrom-Json

                $blobCounter = 0
                foreach ($blob in $downloadBlobJson.manifest.blobs)
                {
                    $blobCounter++

                    Write-Output "Downloading blob $blobCounter..."

                    $csvExportPath = "$env:TEMP\$targetStartDate-$ScopeName-$consumptionMetric-$blobCounter.csv"
                    $finalCsvExportPath = "$env:TEMP\$targetStartDate-$ScopeName-$consumptionMetric-$blobCounter-final.csv"

                    Invoke-WebRequest -Uri $blob.blobLink -OutFile $csvExportPath

                    Write-Output "Blob downloaded to $csvExportPath successfully."

                    $r = [IO.File]::OpenText($csvExportPath)
                    $w = [System.IO.StreamWriter]::new($finalCsvExportPath)

                    # header normalization between MCA and EA
                    $headerConversion = @{
                        additionalInfo = "AdditionalInfo";
                        billingAccountId = "BillingAccountId";
                        billingAccountName = "BillingAccountName";
                        billingCurrency = "BillingCurrencyCode";
                        billingPeriodEndDate = "BillingPeriodEndDate";
                        billingPeriodStartDate = "BillingPeriodStartDate";
                        billingProfileId = "BillingProfileId";
                        billingProfileName = "BillingProfileName";
                        chargeType = "ChargeType";
                        consumedService = "ConsumedService";
                        costAllocationRuleName = "CostAllocationRuleName";
                        costCenter = "CostCenter";
                        costInBillingCurrency = "CostInBillingCurrency";
                        date = "Date";
                        effectivePrice = "EffectivePrice";
                        frequency = "Frequency";
                        invoiceSectionId = "InvoiceSectionId";
                        invoiceSectionName = "InvoiceSectionName";
                        isAzureCreditEligible = "IsAzureCreditEligible";
                        meterCategory = "MeterCategory";
                        meterId = "MeterId";
                        meterName = "MeterName";
                        meterRegion = "MeterRegion";
                        meterSubCategory = "MeterSubCategory";
                        offerId = "OfferId";
                        pricingModel = "PricingModel";
                        productOrderId = "ProductOrderId";
                        productOrderName = "ProductOrderName";
                        publisherName = "PublisherName";
                        publisherType = "PublisherType";
                        quantity = "Quantity";
                        reservationId = "ReservationId";
                        reservationName = "ReservationName";
                        resourceGroupName = "ResourceGroup";
                        resourceLocation = "ResourceLocation";
                        serviceFamily = "ServiceFamily";
                        serviceInfo1 = "ServiceInfo1";
                        serviceInfo2 = "ServiceInfo2";
                        subscriptionName = "SubscriptionName";
                        tags = "Tags";
                        term = "Term";
                        unitOfMeasure = "UnitOfMeasure";
                        unitPrice = "UnitPrice"
                    }

                    $lineCounter = 0
                    while ($r.Peek() -ge 0) {
                        $line = $r.ReadLine()
                        $lineCounter++
                        if ($lineCounter -eq 1)
                        {
                            $headers = $line.Split(",")

                            for ($i = 0; $i -lt $headers.Length; $i++)
                            {
                                $header = $headers[$i]
                                if ($headerConversion.ContainsKey($header))
                                {
                                    $headers[$i] = $headerConversion[$header]
                                }
                            }

                            $line = $headers -join ","

                            $w.WriteLine($line)
                        }
                        else
                        {
                            $w.WriteLine($line)
                        }
                    }
                    $r.Dispose()
                    $w.Close()        

                    $csvBlobName = [System.IO.Path]::GetFileName($finalCsvExportPath)
                    $csvProperties = @{"ContentType" = "text/csv"};
                    Set-AzStorageBlobContent -File $finalCsvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force
                    
                    $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
                    Write-Output "[$now] Uploaded $csvBlobName to Blob Storage..."
                
                    Remove-Item -Path $csvExportPath -Force
                
                    $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
                    Write-Output "[$now] Removed $csvExportPath from local disk..."                    

                    Remove-Item -Path $finalCsvExportPath -Force
        
                    $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
                    Write-Output "[$now] Removed $finalCsvExportPath from local disk..."                            
                }

                $requestSuccess = $true
            }
            elseif ($downloadResult.StatusCode -eq 202)
            {
                Write-Output "Was told to wait a bit more... $($downloadResult.Headers.RetryAfter.Delta.TotalSeconds) seconds."

                $sleepSeconds = 60
                if ($downloadResult.Headers.RetryAfter.Delta.TotalSeconds -gt 0)
                {
                    $sleepSeconds = $downloadResult.Headers.RetryAfter.Delta.TotalSeconds
                }
            }
            elseif ($downloadResult.StatusCode -eq 401)
            {
                Write-Output "Had an authentication issue. Will login again and sleep just a couple of seconds."

                Authenticate-AzureWithOption -authOption $authenticationOption -cloudEnv $cloudEnvironment

                $sleepSeconds = 2
            }
            else
            {
                $hadErrors = $true
                Write-Warning "Got an unexpected response code: $($downloadResult.StatusCode)"
            }
        } 
        while (-not($requestSuccess) -and $tries -lt $MaxTries)

        if (-not($requestSuccess))
        {
            $hadErrors = $true
            Write-Warning "Error returned by the Download Cost Details API. Status Code: $($downloadResult.StatusCode). Message: $($downloadResult.Content)"
        }
        else
        {
            Write-Output "Export download processing complete."
        }
    }
    else
    {
        if ($result.StatusCode -ne 204)
        {
            $hadErrors = $true
            Write-Warning "Error returned by the Generate Cost Details API. Status Code: $($result.StatusCode). Message: $($result.Content)"
        }
        else
        {
            Write-Output "Request returned 204 No Content"
        }
    }    
}

if ($consumptionScope -eq "Subscription")
{
    $CostDetailsSupportedQuotaIDs = @('EnterpriseAgreement_2014-09-01','Internal_2014-09-01','CSP_2015-05-01')
    $ConsumptionSupportedQuotaIDs = @('PayAsYouGo_2014-09-01','MSDN_2014-09-01')
    
    foreach ($subscription in $subscriptions)
    {
        $subscriptionQuotaID = $subscription.SubscriptionPolicies.QuotaId
    
        if ($subscriptionQuotaID -in $ConsumptionSupportedQuotaIDs -or $consumptionAPIOption -eq "UsageDetails")
        {
            $consumption = $null
            $billingEntries = @()
        
            $ConsumptionApiPath = "/subscriptions/$($subscription.Id)/providers/Microsoft.Consumption/usageDetails?api-version=2021-10-01&metric=$($consumptionMetric.ToLower())&%24expand=properties%2FmeterDetails%2Cproperties%2FadditionalInfo&%24filter=properties%2FusageStart%20ge%20%27$targetStartDate%27%20and%20properties%2FusageEnd%20le%20%27$targetEndDate%27"
        
            Write-Output "Starting consumption export process from $targetStartDate to $targetEndDate for subscription $($subscription.Name)..."
        
            do
            {
                if (-not([string]::IsNullOrEmpty($consumption.nextLink)))
                {
                    $ConsumptionApiPath = $consumption.nextLink.Substring($consumption.nextLink.IndexOf("/subscriptions/"))
                }
                $tries = 0
                $requestSuccess = $false
                do 
                {        
                    try {
                        $tries++
                        $consumption = (Invoke-AzRestMethod -Path $ConsumptionApiPath -Method GET).Content | ConvertFrom-Json                    
                        $requestSuccess = $true
                    }
                    catch {
                        $ErrorMessage = $_.Exception.Message
                        Write-Warning "Error getting consumption data: $ErrorMessage. $tries of 3 tries. Waiting 60 seconds..."
                        Start-Sleep -s 60   
                    }
                } while ( -not($requestSuccess) -and $tries -lt 3 )
        
                foreach ($consumptionLine in $consumption.value)
                {
                    if ($consumptionLine.tags)
                    {
                        $tags = $consumptionLine.tags | ConvertTo-Json
                    }
                    else
                    {
                        $tags = $null
                    }
    
                    $billingEntry = New-Object PSObject -Property @{
                        Timestamp = $timestamp
                        AccountName = $consumptionLine.properties.accountName
                        AccountOwnerId = $consumptionLine.properties.accountOwnerId
                        AdditionalInfo = $consumptionLine.properties.additionalInfo
                        benefitId = $consumptionLine.properties.benefitId
                        benefitName = $consumptionLine.properties.benefitName
                        BillingAccountId = $consumptionLine.properties.billingAccountId
                        BillingAccountName = $consumptionLine.properties.billingAccountName
                        BillingCurrencyCode = $consumptionLine.properties.billingCurrency
                        BillingPeriodEndDate= $consumptionLine.properties.billingPeriodEndDate
                        BillingPeriodStartDate= $consumptionLine.properties.billingPeriodStartDate
                        BillingProfileId = $consumptionLine.properties.billingProfileId
                        BillingProfileName= $consumptionLine.properties.billingProfileName
                        ChargeType = $consumptionLine.properties.chargeType
                        ConsumedService = $consumptionLine.properties.consumedService
                        CostAllocationRuleName = $consumptionLine.properties.costAllocationRuleName
                        CostCenter = $consumptionLine.properties.costCenter
                        CostInBillingCurrency = $consumptionLine.properties.cost
                        Date = (Get-Date $consumptionLine.properties.date).ToString("MM/dd/yyyy")
                        EffectivePrice = $consumptionLine.properties.effectivePrice
                        Frequency = $consumptionLine.properties.frequency
                        InvoiceSectionName = $consumptionLine.properties.invoiceSection
                        IsAzureCreditEligible = $consumptionLine.properties.isAzureCreditEligible
                        MeterCategory = $consumptionLine.properties.meterDetails.meterCategory
                        MeterId = $consumptionLine.properties.meterId
                        MeterName = $consumptionLine.properties.meterDetails.meterName
                        MeterRegion = $consumptionLine.properties.meterDetails.meterRegion
                        MeterSubCategory = $consumptionLine.properties.meterDetails.meterSubCategory
                        OfferId = $consumptionLine.properties.offerId
                        PartNumber = $consumptionLine.properties.partNumber
                        PayGPrice = $consumptionLine.properties.PayGPrice
                        PlanName = $consumptionLine.properties.planName
                        PricingModel = $consumptionLine.properties.pricingModel
                        ProductName = $consumptionLine.properties.product
                        PublisherName = $consumptionLine.properties.publisherName
                        PublisherType = $consumptionLine.properties.publisherType
                        Quantity = $consumptionLine.properties.quantity
                        ReservationId = $consumptionLine.properties.reservationId
                        ReservationName = $consumptionLine.properties.reservationName
                        ResourceGroup = $consumptionLine.properties.resourceGroup
                        ResourceId = $consumptionLine.properties.resourceId
                        ResourceLocation = $consumptionLine.properties.resourceLocation
                        ResourceName = $consumptionLine.properties.resourceName
                        ServiceFamily = $consumptionLine.properties.meterDetails.serviceFamily
                        SubscriptionId = $consumptionLine.properties.subscriptionId
                        SubscriptionName = $consumptionLine.properties.subscriptionName
                        Tags = $tags
                        Term = $consumptionLine.properties.term
                        UnitOfMeasure = $consumptionLine.properties.meterDetails.unitOfMeasure
                        UnitPrice = $consumptionLine.properties.unitPrice
                    }            
                    $billingEntries += $billingEntry
                }    
            }
            while ($requestSuccess -and -not([string]::IsNullOrEmpty($consumption.nextLink)))
        
            if ($requestSuccess)
            {
                Write-Output "Generated $($billingEntries.Count) entries..."
            
                Write-Output "Uploading CSV to Storage"
            
                $ci = [CultureInfo]::new([System.Threading.Thread]::CurrentThread.CurrentCulture.Name)
                if ($ci.NumberFormat.NumberDecimalSeparator -ne '.')
                {
                    Write-Output "Current culture ($($ci.Name)) does not use . as decimal separator"    
                    $ci.NumberFormat.NumberDecimalSeparator = '.'
                    [System.Threading.Thread]::CurrentThread.CurrentCulture = $ci
                }
            
                $csvExportPath = "$targetStartDate-$($subscription.Id)-$consumptionMetric.csv"
        
                $billingEntries | Export-Csv -Path $csvExportPath -NoTypeInformation    
        
                $csvBlobName = $csvExportPath
                $csvProperties = @{"ContentType" = "text/csv"};
                Set-AzStorageBlobContent -File $csvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force
                
                $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
                Write-Output "[$now] Uploaded $csvBlobName to Blob Storage..."
            
                Remove-Item -Path $csvExportPath -Force
            
                $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
                Write-Output "[$now] Removed $csvExportPath from local disk..."        
            }
            else
            {
                $hadErrors = $true
                Write-Warning "Failed to get consumption data for subscription $($subscription.Name)..."
            }
        }
        elseif ($subscriptionQuotaID -in $CostDetailsSupportedQuotaIDs -or $consumptionAPIOption -eq "CostDetails")
        {
            Write-Output "Starting cost details export process from $targetStartDate to $targetEndDate for subscription $($subscription.Name)..."
            Generate-CostDetails -ScopeId "/subscriptions/$($subscription.Id)" -ScopeName $subscription.Id
        }
        else
        {
            $hadErrors = $true
            Write-Warning "Subscription quota $subscriptionQuotaID not supported"
        }
    }    
}
else
{
    Write-Output "Starting cost details export process from $targetStartDate to $targetEndDate for Billing Account ID $BillingAccountID..."
    Generate-CostDetails -ScopeId "/providers/Microsoft.Billing/billingAccounts/$BillingAccountID" -ScopeName $BillingAccountID
}

if ($hadErrors)
{
    throw "There were errors during the export process. Please check the output for details."
}