# LastUpdatedAsset-Updater
This Azure function is used to update the 'Scripts - Last Updated' asset in IT Glue. While we can directly update this asset from a script, using this function instead means we can more easily modify the 'Last Updated' asset. For example, if we add a new Auto Documentation script, we will want to add a field for this on the 'Last Updated' page. When we do this, every bit of code that updates this page will need to be modified. This is an ITG limitation: when updating a flexible asset you must update all the fields or they will be set to null. Because this is being updated by many scripts across many servers, we would need to modify every single script to include this new field. By using this function, instead we can just add the field into once place, this function! 

When sending a query to this function you must include the IT Glue API URL and API Key. This script will then verify your Key and URL and if everything looks correct, it will send the request through. It can handle calls to both the default IT Glue API as well as our custom IT Glue API Forwarder. 

# Configuration
- `ITGAPIURL_WHITELIST` - This is a comma separated list of API URL's that will be accepted.
- `ITG_PRIMARY_API_URLS` - A command separated list of API URL's that are IT Glue's actual API (not our forwarder).
- `SCRIPTS_LAST_RUN_ASSET_TYPE_ID` - The flexible asset ID of the 'Scripts - Last Run' asset in IT Glue.
- `ITG_API_Forwarder_APIKey` - An API key for this script that comes from the IT Glue API Forwarder. It must allow all organizations and IP's (if using a Premium function you could lock this down to the function's outgoing IP, but this isn't possible with a 'Consumption' function).

# Usage Example
```powershell
# Where $LastUpdatedUpdater is the URL of this Azure function

if ($LastUpdatedUpdater_APIURL -and $ITGOrgID) {
    $Headers = @{
        "x-api-key" = $ITG_APIKey
    }
	# Simply include an fields to update in the body, it will search for all applicable field names and update any it finds
    $Body = @{
        "apiurl" = $ITG_APIEndpoint
        "itgOrgID" = $ITGOrgID
        "HostDevice" = $env:computername
        "field-to-update" = (Get-Date).ToString("yyyy-MM-dd")
    }

    $Params = @{
        Method = "Post"
        Uri = $LastUpdatedUpdater_APIURL
        Headers = $Headers
        Body = ($Body | ConvertTo-Json)
        ContentType = "application/json"
    }			
    Invoke-RestMethod @Params 
}
```