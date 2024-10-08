using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

Write-Information ("Incoming {0} {1}" -f $Request.Method,$Request.Url)

Function ImmediateFailure ($Message) {
    Write-Error $Message
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        headers    = @{'content-type' = 'application\json' }
        StatusCode = [httpstatuscode]::OK
        Body       = @{"Error" = $Message } | convertto-json
    })
    exit 1
}

# Parse api url whitelist and primary api url list
$APIURLWhitelist = $ENV:ITGAPIURL_WHITELIST -split ", "
$PrimaryITGAPIs = $ENV:ITG_PRIMARY_API_URLS -split ", "

# Verify the sender has permission to access this resource (check IP and API key)
if ($Request.Body.apiurl -in $PrimaryITGAPIs) {
    # Using the main ITG API, just grab a random piece of data and ensure the API key works
    Write-Information ("Using the main ITG API")
    $Headers = @{
        "x-api-key" = $request.headers.'x-api-key'
    }

    $Params = @{
        Method = "Get"
        Uri = $request.body.apiurl + "/organizations/" + $Request.body.itgOrgID
        Headers = $Headers
        ContentType = "application/json"
    }
    $FromDeviceAudit_STS_Scripts = $false
    if ($Request.body.HelloWorld -and $Request.body.HelloWorld -eq "success") {
        $FromDeviceAudit_STS_Scripts = $true
    }


    try {
        $OrgDetails = Invoke-RestMethod @Params 
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 504) {
            Start-Sleep -Seconds 5
            # Try a 2nd time if the api call timed out
            try {
                $OrgDetails = Invoke-RestMethod @Params 
            } catch {
                $Err = "$($_.Exception.Response.StatusCode.value__) - API token does not match or there was an API error for Org $($Request.body.itgOrgID). (using url $($request.body.apiurl) and key $($request.headers.'x-api-key')) (description: $($_.Exception.Response.StatusDescription)) 1"
                if ($_.ErrorDetails.Message){
                    $Err += "(Inner Error: $_.ErrorDetails.Message)"
                }
                if ($FromDeviceAudit_STS_Scripts) {
                    $Err += " - FROM DeviceAudit-Automated on STS-Scripts"
                }

                $ClientIP = ($request.headers.'X-Forwarded-For' -split ':')[0]
                Write-Information ("Client IP: {0}" -f $ClientIP)
                ImmediateFailure $Err
            }
        } else {
            $Err = "$($_.Exception.Response.StatusCode.value__) - API token does not match or there was an API error for Org $($Request.body.itgOrgID). (using url $($request.body.apiurl) and key $($request.headers.'x-api-key')) (description: $($_.Exception.Response.StatusDescription)) 1.5"
            if ($_.ErrorDetails.Message){
                $Err += "(Inner Error: $_.ErrorDetails.Message)"
            }
            if ($FromDeviceAudit_STS_Scripts) {
                $Err += " - FROM DeviceAudit-Automated on STS-Scripts"
            }

            $ClientIP = ($request.headers.'X-Forwarded-For' -split ':')[0]
            Write-Information ("Client IP: {0}" -f $ClientIP)
            ImmediateFailure $Err
        }
    }
    
    if (!$OrgDetails -or !$OrgDetails.data) {
        $ClientIP = ($request.headers.'X-Forwarded-For' -split ':')[0]
        Write-Information ("Client IP: {0}" -f $ClientIP)
        ImmediateFailure "401 - API token does not match or there was an API error for Org $($Request.body.itgOrgID). (using url $($request.body.apiurl) and key $($request.headers.'x-api-key')) 2"
    } else {
        Write-Information "Updating Last Updated info for: $($OrgDetails.data[0].attributes.name)"
    }
    $APIKey = $request.headers.'x-api-key'
} else {
    # Using the API forwarder, use custom check
    Write-Information ("Using the ITG API Forwarder")
    $Headers = @{
        "x-api-key" = $request.headers.'x-api-key'
        "Originating-IP" = ($request.headers.'X-Forwarded-For' -split ':')[0]
    }
    $Body = @{
        PermissionsCheckOnly = $true
    }

    $Params = @{
        Method = "Post"
        Uri = $request.body.apiurl
        Headers = $Headers
        Body = ($Body | ConvertTo-Json)
        ContentType = "application/json"
    }			
    try {
        $PermCheckResult = Invoke-RestMethod @Params 
    } catch {
        $ClientIP = ($request.headers.'X-Forwarded-For' -split ':')[0]
        Write-Information ("Client IP: {0}" -f $ClientIP)
        ImmediateFailure "$($_.Exception.Response.StatusCode.value__) - API token does not match or IP not found in allowed list for Org $($Request.body.itgOrgID). (using url $($request.body.apiurl) and key $($request.headers.'x-api-key')) 3"
    }

    if ($PermCheckResult -ne "success") {
        $ClientIP = ($request.headers.'X-Forwarded-For' -split ':')[0]
        Write-Information ("Client IP: {0}" -f $ClientIP)
        ImmediateFailure "401 - API token does not match or IP not found in allowed list for Org $($Request.body.itgOrgID). (using url $($request.body.apiurl) and key $($request.headers.'x-api-key')) 4"
    }
    $APIKey = $Env:ITG_API_Forwarder_APIKey
}

# Get the API key, URL, and ITG ORG ID to send this request to
$APIURL = $request.body.apiurl
$OrgID = $Request.body.itgOrgID

Write-Information "Running for org $OrgID"

if (!$APIURL) {
    ImmediateFailure "401 - An API URL is required. Set 'apiurl' in the request body."
}
if (!$APIKey) {
    $ClientIP = ($request.headers.'X-Forwarded-For' -split ':')[0]
    Write-Information ("Client IP: {0}" -f $ClientIP)
    ImmediateFailure "401 - An API Key is required. Set 'x-api-key' in the request headers."
}
if (!$OrgID) {
    ImmediateFailure "401 - ITG Org ID is required. Set 'itgOrgID' in the request body."
}
if ($APIURL -notin $APIURLWhitelist) {
    ImmediateFailure "401 - API URL '$($APIURL)' was not found in the api url whitelist."
}

# Configure ITG API
if (!(Get-Command 'Add-ITGlueBaseURI' -errorAction SilentlyContinue)) {
    Import-Module ITGlueAPI
}
Add-ITGlueBaseURI -base_uri $APIURL
Add-ITGlueAPIKey $APIKey
Set-Variable -Name "ITGlue_JSON_Conversion_Depth" -Value 100 -Scope global -Force

# Get the existing asset (if exists)
$LastUpdatedPage = Get-ITGlueFlexibleAssets -filter_flexible_asset_type_id $ENV:SCRIPTS_LAST_RUN_ASSET_TYPE_ID -filter_organization_id $OrgID
if ($LastUpdatedPage -and $LastUpdatedPage.data) {
    $LastUpdatedPage.data = $LastUpdatedPage.data | Where-Object { !$_.attributes.archived }
}

if (!$LastUpdatedPage -or !$LastUpdatedPage.data) {
    # If no existing asset, just exit and throw a warning
    Write-Warning "404 - No existing asset to update. Create a new asset and then try the update again."
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        headers    = @{'content-type' = 'application\json' }
        StatusCode = [httpstatuscode]::OK
        Body       = @{"Warning" = "404 - No existing asset to update. Create a new asset and then try the update again." } | convertto-json
    })
    exit 1
}

if (($LastUpdatedPage.data | Measure-Object).Count -gt 1) {
    $LastUpdatedPage.data = $LastUpdatedPage.data | Sort-Object -Property {$_.attributes.'created-at'} | Select-Object -First 1
}

# Construct the ITG update
$FlexAssetBody = 
@{
    type = 'flexible-assets'
    attributes = @{
        traits = @{
            "name" = "Scripts - Last Run"

            "current-version" = $LastUpdatedPage.data.attributes.traits."current-version"
            "contact-audit" = $LastUpdatedPage.data.attributes.traits."contact-audit"
            "contact-audit-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."contact-audit-monitoring-disabled"
            "billing-update-ua" = $LastUpdatedPage.data.attributes.traits."billing-update-ua"
            "billing-update-ua-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."billing-update-ua-monitoring-disabled"
            "o365-license-report" = $LastUpdatedPage.data.attributes.traits."o365-license-report"
            "o365-license-report-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."o365-license-report-monitoring-disabled"

            "device-cleanup" = $LastUpdatedPage.data.attributes.traits."device-cleanup"
            "device-cleanup-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."device-cleanup-monitoring-disabled"
            "device-usage" = $LastUpdatedPage.data.attributes.traits."device-usage"
            "device-usage-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."device-usage-monitoring-disabled"
            "device-locations" = $LastUpdatedPage.data.attributes.traits."device-locations"
            "device-locations-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."device-locations-monitoring-disabled"
            "monthly-stats-rollup" = $LastUpdatedPage.data.attributes.traits."monthly-stats-rollup"
            "monthly-stats-rollup-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."monthly-stats-rollup-monitoring-disabled"
            "device-users" = $LastUpdatedPage.data.attributes.traits."device-users"
            "device-users-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."device-users-monitoring-disabled"
            "billing-update-da" = $LastUpdatedPage.data.attributes.traits."billing-update-da"
            "billing-update-da-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."billing-update-da-monitoring-disabled"

            "contact-cleanup" = $LastUpdatedPage.data.attributes.traits."contact-cleanup"
            "contact-cleanup-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."contact-cleanup-monitoring-disabled"
            "security" = $LastUpdatedPage.data.attributes.traits."security"
            "security-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."security-monitoring-disabled"
            "active-directory" = $LastUpdatedPage.data.attributes.traits."active-directory"
            "active-directory-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."active-directory-monitoring-disabled"
            "ad-groups" = $LastUpdatedPage.data.attributes.traits."ad-groups"
            "ad-groups-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."ad-groups-monitoring-disabled"
            "email" = $LastUpdatedPage.data.attributes.traits."email"
            "email-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."email-monitoring-disabled"
            "o365-groups" = $LastUpdatedPage.data.attributes.traits."o365-groups"
            "o365-groups-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."o365-groups-monitoring-disabled"
            "hyper-v" = $LastUpdatedPage.data.attributes.traits."hyper-v"
            "hyper-v-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."hyper-v-monitoring-disabled"
            "file-shares-file-server" = $LastUpdatedPage.data.attributes.traits."file-shares-file-server"
            "file-shares-ad-server" = $LastUpdatedPage.data.attributes.traits."file-shares-ad-server"
            "file-shares-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."file-shares-monitoring-disabled"
            "licensing-overview" = $LastUpdatedPage.data.attributes.traits."licensing-overview"
            "licensing-overview-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."licensing-overview-monitoring-disabled"
            "meraki-licensing" = $LastUpdatedPage.data.attributes.traits."meraki-licensing"
            "meraki-licensing-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."meraki-licensing-monitoring-disabled"
            "bluebeam-licensing" = $LastUpdatedPage.data.attributes.traits."bluebeam-licensing"
            "bluebeam-licensing-monitoring-disabled" = $LastUpdatedPage.data.attributes.traits."bluebeam-licensing-monitoring-disabled"

            "custom-scripts" = $LastUpdatedPage.data.attributes.traits."custom-scripts"

            "devices-running-autodoc" = $LastUpdatedPage.data.attributes.traits."devices-running-autodoc"
        }
    }
}

$UpdatedParams = @()
foreach ($BodyParam in $Request.Body.Keys) {
    if ($BodyParam -in $FlexAssetBody.attributes.traits.Keys) {
        $FlexAssetBody.attributes.traits[$BodyParam] = $Request.body[$BodyParam]
        $UpdatedParams += $BodyParam
    }
}

if ($Request.Body.HostDevice) {
    $OldDevices = ($LastUpdatedPage.data.attributes.traits."devices-running-autodoc" -replace '<[^>]+>','').Trim() -split ", "
    if ($OldDevices -notcontains $Request.Body.HostDevice) {
        $NewDevices = $OldDevices
        $NewDevices += $Request.Body.HostDevice
        $NewDevices = $NewDevices | Where-Object { $_ } # filter out empty
        $FlexAssetBody.attributes.traits["devices-running-autodoc"] = $NewDevices -join ", "
    }
}

# Filter out empty values
($FlexAssetBody.attributes.traits.GetEnumerator() | Where-Object { -not $_.Value }) | Foreach-Object { 
    $FlexAssetBody.attributes.traits.Remove($_.Name) 
}

$SuccessMsg = "Updated the 'Scripts - Last Run' page for org $($OrgID). Updated: " +  ($UpdatedParams -join ", ")
try {
    $Response = Set-ITGlueFlexibleAssets -id $LastUpdatedPage.data.id -data $FlexAssetBody -ErrorVariable UpdateErr
    if (!$Response.Error) {
        Write-Verbose $SuccessMsg
    }
} catch {
    Write-Error "Could not update LastUpdated page for org $OrgID, from $($Request.Body.HostDevice). Keys to update: $($Request.Body.Keys -join ", ")"
    Write-Error $UpdateErr
}
if ($Response -and $Response.Error) {
    # Error, try again
    Start-Sleep -Seconds 2
    $Response = Set-ITGlueFlexibleAssets -id $LastUpdatedPage.data.id -data $FlexAssetBody
    if (!$Response.Error) {
        Write-Verbose $SuccessMsg
    } else {
        Write-Error "Could not update LastUpdated page for org $OrgID, from $($Request.Body.HostDevice). Keys to update: $($Request.Body.Keys -join ", ")"
        Write-Error $Response.Error
    }
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $SuccessMsg
})
