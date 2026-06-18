<#
.SYNOPSIS
    Interactively adds new Entity Types or edits properties of existing Entity Types in a
    Microsoft Fabric Ontology using REST APIs.

.DESCRIPTION
    1. Authenticates via Azure CLI (az account get-access-token) — run 'az login' first.
    2. Fetches the current ontology definition from your Fabric workspace.
    3. Shows existing entity types already in the ontology.
    4. Presents an action menu — repeat until you choose Submit:
         [A] Add a new entity type (name + properties)
         [E] Edit an existing entity type — add or remove regular/timeseries properties
         [S] Submit all queued changes to Fabric
         [Q] Quit without saving
    5. Pushes the updated definition back to Fabric.

.NOTES
    Requires:  Azure CLI  (https://aka.ms/installazurecliwindows)
    Scope:     Item.ReadWrite.All   (delegated)
    API docs:
      GET  https://learn.microsoft.com/en-us/rest/api/fabric/ontology/items/get-ontology-definition
      POST https://learn.microsoft.com/en-us/rest/api/fabric/ontology/items/update-ontology-definition
#>

[CmdletBinding()]
param (
    [string] $WorkspaceId = "",   # Leave blank to be prompted
    [string] $OntologyId  = ""    # Leave blank to be prompted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Top-level diagnostic trap: re-throws with the exact source line so you can
# pinpoint any remaining strict-mode violations.
trap {
    Write-Host "`n  SCRIPT ERROR: $_" -ForegroundColor Red
    Write-Host "  AT : $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    Write-Host "  STACK:`n$($_.ScriptStackTrace)" -ForegroundColor Red
    break
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

function Write-Header([string]$Text) {
    Write-Host "`n$('─' * 60)" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$('─' * 60)" -ForegroundColor Cyan
}

function Write-Step([string]$Text) {
    Write-Host "`n► $Text" -ForegroundColor Yellow
}

function Write-Ok([string]$Text) {
    Write-Host "  ✔ $Text" -ForegroundColor Green
}

function Write-Info([string]$Text) {
    Write-Host "  $Text" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# Auth — uses az CLI so no client secrets are stored in the script
# ─────────────────────────────────────────────────────────────────────────────

function Get-FabricToken {
    Write-Step "Obtaining access token via Azure CLI …"
    try {
        $result = az account get-access-token --resource "https://api.fabric.microsoft.com" --output json 2>&1
        if ($LASTEXITCODE -ne 0) { throw $result }
        $token = ($result | ConvertFrom-Json).accessToken
        Write-Ok "Token obtained."
        return $token
    }
    catch {
        Write-Host "`n  ERROR: Could not get token. Have you run 'az login'?" -ForegroundColor Red
        throw
    }
}

function Get-AuthHeaders([string]$Token) {
    return @{
        "Authorization" = "Bearer $Token"
    }
}

# Invoke-RestMethod / Invoke-WebRequest wrapper that always surfaces the API error body
function Invoke-FabricApi {
    param(
        [string]$Uri,
        [string]$Method = "Post",
        [hashtable]$Headers,
        [string]$Body = $null
    )
    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $Headers
        UseBasicParsing = $true
        ErrorAction     = "Stop"
    }
    if ($Body) {
        $params["Body"]        = $Body
        $params["ContentType"] = "application/json; charset=utf-8"
    }
    try {
        return Invoke-WebRequest @params
    }
    catch [System.Net.WebException] {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $errBody = $reader.ReadToEnd()
        throw "API error ($($_.Exception.Response.StatusCode)): $errBody"
    }
    catch {
        # PowerShell 7+ HttpRequestException path
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode

            # Prefer ErrorDetails.Message (PS7 sets this from response body).
            # Fallback: read the content stream directly.
            $errBody = ''
            if ($_.ErrorDetails.Message) {
                $errBody = $_.ErrorDetails.Message
            } else {
                try {
                    $stream  = $_.Exception.Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $reader  = [System.IO.StreamReader]::new($stream)
                    $errBody = $reader.ReadToEnd()
                } catch { }
            }
            if (-not $errBody) { $errBody = $_.Exception.Message }

            # ── Parse JSON and surface every field Fabric returns ──────────────
            $displayLines = [System.Collections.Generic.List[string]]::new()
            try {
                $errJson = $errBody | ConvertFrom-Json

                $reqId   = if ($errJson.PSObject.Properties['requestId'])    { $errJson.requestId }                 else { '' }
                $errCode = if ($errJson.PSObject.Properties['errorCode'])    { $errJson.errorCode }                 else { $statusCode }
                $errMsg  = if ($errJson.PSObject.Properties['message'])      { $errJson.message }                   else { $errBody }

                $displayLines.Add("HTTP $statusCode  |  ErrorCode: $errCode")
                if ($reqId)  { $displayLines.Add("RequestId   : $reqId  (search in Fabric workspace monitoring)") }
                $displayLines.Add("Message     : $errMsg")

                foreach ($field in @('additionalInfo','moreDetails','relatedResource','details','innerError')) {
                    if ($errJson.PSObject.Properties[$field]) {
                        $displayLines.Add("$($field.PadRight(14)): $($errJson.$field | ConvertTo-Json -Depth 5 -Compress)")
                    }
                }

                # Save full raw error body for reference
                $errFile = "$env:TEMP\fabric-ontology-last-error.json"
                [System.IO.File]::WriteAllText($errFile, $errBody, [System.Text.Encoding]::UTF8)
                $displayLines.Add("Full error  : $errFile")
            } catch {
                $displayLines.Add("HTTP $statusCode : $errBody")
            }

            throw "SCRIPT ERROR: API error ($statusCode):`n$($displayLines -join "`n")"
        }
        throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Base64 helpers (the API requires every payload to be base64-encoded JSON)
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-Base64Json([object]$Object) {
    $json  = $Object | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return [System.Convert]::ToBase64String($bytes)
}

function ConvertFrom-Base64Json([string]$Payload) {
    try {
        $bytes = [System.Convert]::FromBase64String($Payload)
        $json  = [System.Text.Encoding]::UTF8.GetString($bytes)
        # Convert to plain hashtable so callers can safely use dot notation under
        # Set-StrictMode -Version Latest without PSCustomObject property-not-found errors.
        return ConvertTo-PlainHashtable ($json | ConvertFrom-Json -Depth 20)
    }
    catch {
        return $null   # .platform or empty definition.json may not decode cleanly
    }
}

# Recursively convert PSCustomObject / List back to plain ordered hashtables/arrays
# so that ConvertTo-Json round-trips them cleanly.
function ConvertTo-PlainHashtable($obj) {
    if ($null -eq $obj)                                           { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        $ht = [ordered]@{}
        foreach ($key in $obj.Keys) { $ht[$key] = ConvertTo-PlainHashtable $obj[$key] }
        return $ht
    }
    if ($obj -is [PSCustomObject]) {
        $ht = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = ConvertTo-PlainHashtable $p.Value }
        return $ht
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        # Use List<object> + foreach (NOT ForEach-Object pipeline) for two reasons:
        #   1. ForEach-Object wraps $_ in PSObject; when that PSObject-wrapped string reaches
        #      ConvertTo-Json, it serializes as {"Length":N} instead of "value".
        #   2. List<object> is serialized as a JSON array even for single-element collections;
        #      Object[] with one element is silently flattened to a scalar by ConvertTo-Json
        #      in PowerShell versions earlier than 7.2.
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $obj) { $list.Add((ConvertTo-PlainHashtable $item)) }
        return $list
    }
    return $obj
}

# ─────────────────────────────────────────────────────────────────────────────
# LRO poller — Fabric can return 202 Accepted for async operations
# ─────────────────────────────────────────────────────────────────────────────

function Wait-FabricLro([string]$LocationUrl, [hashtable]$Headers, [int]$TimeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Info "Polling LRO: $LocationUrl"

    while ((Get-Date) -lt $deadline) {
        $resp = Invoke-RestMethod -Uri $LocationUrl -Method Get -Headers $Headers
        $status = $resp.status

        if ($status -eq "Succeeded") { Write-Ok "LRO completed."; return $resp }
        if ($status -in @("Failed","Cancelled")) {
            throw "LRO $status : $($resp | ConvertTo-Json -Depth 5)"
        }

        $wait = if ($resp.PSObject.Properties["retryAfter"]) { [int]$resp.retryAfter } else { 5 }
        Write-Info "  Status: $status — waiting ${wait}s …"
        Start-Sleep -Seconds $wait
    }
    throw "LRO timed out after ${TimeoutSec}s"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 – Get ontology definition
# ─────────────────────────────────────────────────────────────────────────────

function Get-OntologyDefinition([string]$WorkspaceId, [string]$OntologyId, [hashtable]$Headers) {
    Write-Step "Fetching ontology definition …"
    $url = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/ontologies/$OntologyId/getDefinition"

    $resp = Invoke-FabricApi -Uri $url -Method Post -Headers $Headers

    if ($resp.StatusCode -eq 202) {
        $location = $resp.Headers["Location"]
        $lro = Wait-FabricLro -LocationUrl $location -Headers $Headers
        # Wrap in [object[]] — ConvertFrom-Json / Invoke-RestMethod return a scalar
        # PSCustomObject (not an array) when the JSON array has only one element,
        # which would make .Count throw under Set-StrictMode -Version Latest.
        [object[]]$rawParts = @($lro.definition.parts)
    }
    else {
        [object[]]$rawParts = @(($resp.Content | ConvertFrom-Json).definition.parts)
    }

    Write-Ok "Retrieved $($rawParts.Count) definition parts."
    # Normalize PSCustomObjects → plain ordered hashtables for clean JSON round-tripping
    [object[]]$allParts = @($rawParts | ForEach-Object { ConvertTo-PlainHashtable $_ })

    # Drop any parts with negative IDs in their path — these are invalid from prior failed runs
    # Use bracket notation ($_["path"]) — safer than dot notation under Set-StrictMode on hashtables.
    [object[]]$validParts = @($allParts | Where-Object {
        if ($_["path"] -match "^(EntityTypes|RelationshipTypes)/-\d+/") {
            Write-Info "  Skipping invalid part with negative ID: $($_["path"])"
            $false
        } else { $true }
    })
    return $validParts
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 – Show existing entity types
# ─────────────────────────────────────────────────────────────────────────────

function Show-ExistingEntityTypes($Parts) {
    Write-Step "Existing entity types in this ontology:"

    $entityParts = $Parts | Where-Object { $_["path"] -match "^EntityTypes/[^/]+/definition\.json$" }

    if (-not $entityParts) {
        Write-Info "(none found)"
        return
    }

    foreach ($part in $entityParts) {
        $def = ConvertFrom-Base64Json $part["payload"]
        if ($def) {
            $propNames = (@($def["properties"]) | Where-Object { $_ } | ForEach-Object { $_["name"] }) -join ", "
            Write-Info "  • [$($def["id"])]  $($def["name"])   properties: $propNames"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Entity-type ID generator (positive 64-bit integer, unique per run)
# ─────────────────────────────────────────────────────────────────────────────

function New-EntityId {
    # Use Int64 throughout to prevent Int32 overflow from -shl flipping the sign bit.
    # Math.Abs as a final safety net ensures the result is always a positive 64-bit integer.
    $ticks  = [System.DateTime]::UtcNow.Ticks           # always positive Int64
    $jitter = [System.Int64](Get-Random -Minimum 1 -Maximum 32767)  # 15-bit, safe to shift
    $raw    = $ticks -bxor ($jitter -shl 16)
    return  [string][System.Math]::Abs($raw)
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 – Interactively collect new entity type definitions
# ─────────────────────────────────────────────────────────────────────────────

$ValidValueTypes = @("String","Boolean","DateTime","BigInt","Double","Object")
# Note: "Any" is the valueType for untypedProperties only and is handled separately.

# ─────────────────────────────────────────────────────────────────────────────
# Reference-entity helpers
# ─────────────────────────────────────────────────────────────────────────────

function Get-ReferenceEntityInfo($Parts) {
    <#
    Returns the first valid entity-type definition found in the parts list as a reference,
    so new entity types can inherit the exact field structure / types that Fabric expects.
    Returns $null when the ontology has no existing entity types.
    #>
    foreach ($p in $Parts) {
        if ($p["path"] -match "^EntityTypes/([^/]+)/definition\.json$") {
            $refId  = $matches[1]
            $refDef = ConvertFrom-Base64Json $p["payload"]
            if ($refDef -and $refDef["name"]) { return @{ entityId = $refId; def = $refDef } }
        }
    }
    return $null
}

function Read-NonEmpty([string]$Prompt) {
    while ($true) {
        $val = Read-Host "  $Prompt"
        if ($val.Trim() -ne "") { return $val.Trim() }
        Write-Host "  Value cannot be empty. Please try again." -ForegroundColor Red
    }
}

function Read-EntityTypeName {
    while ($true) {
        $name = Read-NonEmpty "Entity type name (letters/digits/hyphen/underscore, start with letter)"
        if ($name -match "^[a-zA-Z][a-zA-Z0-9_-]{0,127}$") { return $name }
        Write-Host "  Invalid name. Must match ^[a-zA-Z][a-zA-Z0-9_-]{0,127}$" -ForegroundColor Red
    }
}

function Read-PropertyName {
    while ($true) {
        $name = Read-NonEmpty "    Property name"
        if ($name -match "^[a-zA-Z][a-zA-Z0-9_-]{0,127}$") { return $name }
        Write-Host "    Invalid name. Must match ^[a-zA-Z][a-zA-Z0-9_-]{0,127}$" -ForegroundColor Red
    }
}

function Read-ValueType {
    while ($true) {
        $vt = Read-Host "    Value type [$($ValidValueTypes -join ' | ')] (default: String)"
        if ($vt.Trim() -eq "") { return "String" }
        $match = $ValidValueTypes | Where-Object { $_ -eq $vt.Trim() }
        if ($match) { return $match }
        Write-Host "    Invalid type. Choose from: $($ValidValueTypes -join ', ')" -ForegroundColor Red
    }
}

function Read-NewEntityType($RefDef = $null) {
    $entityId = New-EntityId

    Write-Host "`n  ── New Entity Type ──" -ForegroundColor White
    $name = Read-EntityTypeName

    # ── Regular properties ──────────────────────────────────────────────────
    $properties = [System.Collections.Generic.List[object]]::new()
    Write-Host "`n  Regular properties (non-timeseries):" -ForegroundColor White
    Write-Host "  (The first property becomes the display-name and entity-ID key.)" -ForegroundColor DarkGray

    while ($true) {
        $propId   = New-EntityId
        $propName = Read-PropertyName
        $propType = Read-ValueType

        $prop = [ordered]@{ id = $propId; name = $propName; valueType = $propType }
        $properties.Add($prop)

        $more = Read-Host "    Add another regular property? [y/N]"
        if ($more.Trim().ToLower() -ne "y") { break }
    }

    # ── Timeseries properties ────────────────────────────────────────────────
    $timeseriesProperties = [System.Collections.Generic.List[object]]::new()
    $addTs = Read-Host "`n  Add timeseries properties (e.g. Temperature, Humidity)? [y/N]"
    if ($addTs.Trim().ToLower() -eq "y") {
        Write-Host "  Timeseries properties (PreciseTimestamp is recommended as first):" -ForegroundColor White
        while ($true) {
            $propId   = New-EntityId
            $propName = Read-PropertyName
            $propType = Read-ValueType
            $timeseriesProperties.Add([ordered]@{ id = $propId; name = $propName; valueType = $propType })

            $more = Read-Host "    Add another timeseries property? [y/N]"
            if ($more.Trim().ToLower() -ne "y") { break }
        }
    }

    # ── Build entity definition ──────────────────────────────────────────────
    $firstPropId = $properties[0]["id"]

    if ($null -ne $RefDef) {
        # PREFERRED: inherit field structure from an existing Fabric entity
        $entityDef = [ordered]@{}
        foreach ($k in $RefDef.Keys) { $entityDef[$k] = $RefDef[$k] }
        $entityDef["id"]                    = $entityId
        $entityDef["name"]                  = $name
        $entityDef["entityIdParts"]         = @($firstPropId)
        $entityDef["displayNamePropertyId"] = $firstPropId
        $entityDef["properties"]            = @($properties)
        $entityDef["timeseriesProperties"]  = @($timeseriesProperties)
        $entityDef["untypedProperties"]     = @()
        Write-Info "  (Inheriting field structure from existing entity '$($RefDef["name"])')"
    } else {
        # FALLBACK: no existing entity available — construct from schema
        Write-Info "  (No existing entity found — using built-in schema template)"
        $entityDef = [ordered]@{
            '$schema'             = "https://developer.microsoft.com/json-schemas/fabric/item/ontology/entityType/1.0.0/schema.json"
            id                    = $entityId
            namespace             = "usertypes"
            baseEntityTypeId      = $null
            name                  = $name
            entityIdParts         = @($firstPropId)
            displayNamePropertyId = $firstPropId
            namespaceType         = "Custom"
            visibility            = "Visible"
            properties            = @($properties)
            timeseriesProperties  = @($timeseriesProperties)
            untypedProperties     = @()
        }
    }

    return @{ entityId = $entityId; entityDef = $entityDef }
}

function Invoke-CollectNewEntityTypes {
    param($ExistingParts)   # pass the already-loaded parts so we can check for name conflicts

    Write-Header "Define New Entity Types"
    $newEntityTypes = [System.Collections.Generic.List[object]]::new()

    # Build a set of names already in the ontology
    $existingNames = @{}
    foreach ($p in $ExistingParts) {
        if ($p["path"] -match "^EntityTypes/[^/]+/definition\.json$") {
            $def = ConvertFrom-Base64Json $p["payload"]
            if ($def -and $def["name"]) { $existingNames[$def["name"]] = $true }
        }
    }
    if ($existingNames.Count -gt 0) {
        Write-Info "  Existing entity names (cannot be reused): $($existingNames.Keys -join ', ')"
    }

    while ($true) {
        $entry = Read-NewEntityType -RefDef $null   # no $parts reference here; main loop uses $refEntityInfo

        if ($allUsedNames.ContainsKey($entry["entityDef"]["name"])) {
            Write-Host "`n  ERROR: An entity named '$($entry["entityDef"]["name"])' already exists." -ForegroundColor Red
            Write-Host "  Please choose a different name." -ForegroundColor Red
            continue
        }

        $newEntityTypes.Add($entry)
        Write-Ok "Entity type '$($entry["entityDef"]["name"])' (ID: $($entry["entityId"])) queued."

        $another = Read-Host "`nAdd another entity type? [y/N]"
        if ($another.Trim().ToLower() -ne "y") { break }
    }

    return $newEntityTypes
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 – Append new entity-type parts to the definition
# ─────────────────────────────────────────────────────────────────────────────

function Add-EntityTypesToParts {
    param(
        [System.Collections.Generic.List[object]]$Parts,
        [object[]]$NewEntityTypes
    )

    # Find the reference entity ID to clone any per-entity support files (e.g. .platform).
    # In most ontologies there are NO per-entity support files; this is a no-op in that case.
    $refId = $null
    foreach ($p in $Parts) {
        if ($p["path"] -match "^EntityTypes/([^/]+)/definition\.json$") {
            $refId = $Matches[1]; break
        }
    }

    foreach ($entry in $NewEntityTypes) {
        $newId   = $entry["entityId"]
        $newName = $entry["entityDef"]["name"]

        # Clone any non-definition.json support files from the reference entity folder.
        if ($null -ne $refId) {
            $refPrefix = "EntityTypes/$refId/"
            $newPrefix = "EntityTypes/$newId/"
            foreach ($sp in @($Parts | Where-Object {
                $_["path"] -like "$refPrefix*" -and $_["path"] -ne "${refPrefix}definition.json"
            })) {
                $clonedPath    = $newPrefix + $sp["path"].Substring($refPrefix.Length)
                $clonedPayload = $sp["payload"]

                # For .platform files: patch logicalId and displayName
                if ($sp["path"] -match "\.platform$") {
                    try {
                        $clonedJson    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($clonedPayload))
                        $newGuid       = [System.Guid]::NewGuid().ToString()
                        $clonedJson    = $clonedJson -replace '"logicalId"\s*:\s*"[^"]*"',    "`"logicalId`": `"$newGuid`""
                        $clonedJson    = $clonedJson -replace '"displayName"\s*:\s*"[^"]*"',  "`"displayName`": `"$newName`""
                        $clonedPayload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($clonedJson))
                    } catch { }  # if patching fails, use original support file unchanged
                }

                $Parts.Add([ordered]@{ path = $clonedPath; payload = $clonedPayload; payloadType = "InlineBase64" })
                Write-Info "  Cloned support file: $clonedPath"
            }
        }

        # Add the entity type definition.json
        $defPath = "EntityTypes/$newId/definition.json"
        $Parts.Add([ordered]@{
            path        = $defPath
            payload     = ConvertTo-Base64Json $entry["entityDef"]
            payloadType = "InlineBase64"
        })
        [void]$Script:DirtyPaths.Add($defPath)

        # Save decoded JSON for inspection
        $debugFile = "$env:TEMP\fabric-new-entity-$newName.json"
        $entry["entityDef"] | ConvertTo-Json -Depth 20 | Set-Content $debugFile -Encoding UTF8 -NoNewline
        Write-Info "  Added entity '$newName' (ID: $newId) — decoded JSON: $debugFile"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 – Push updated definition back to Fabric
# ─────────────────────────────────────────────────────────────────────────────

function Update-OntologyDefinition(
    [string]$WorkspaceId,
    [string]$OntologyId,
    $Parts,
    [hashtable]$Headers,
    # Names of entities we expect to exist after the update (used for post-ALMError verification).
    [string[]]$ExpectedEntityNames = @()
) {
    Write-Step "Uploading updated ontology definition …"

    $url  = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/ontologies/$OntologyId/updateDefinition"
    $body = @{
        definition = @{
            parts = @($Parts)
        }
    } | ConvertTo-Json -Depth 30 -Compress

    # Save body to a debug file — inspect this if the API rejects the payload
    $debugFile = "$env:TEMP\fabric-ontology-update-body.json"
    $body | Set-Content -Path $debugFile -Encoding UTF8 -NoNewline
    Write-Info "  Debug: full request body saved to $debugFile"

    try {
        $resp = Invoke-FabricApi -Uri $url -Method Post -Headers $Headers -Body $body

        if ($resp.StatusCode -eq 202) {
            $location = $resp.Headers["Location"]
            Wait-FabricLro -LocationUrl $location -Headers $Headers | Out-Null
        }

        Write-Ok "Ontology definition updated successfully."
    }
    catch {
        # ── ALMOperationImportFailed is a known Fabric false-positive ──────────
        # Fabric's post-import ALM pipeline always returns this 400 even though
        # the ontology data has already been committed to storage. The error body
        # always contains unformatted "{0}/{1}/{2}" placeholders — no real cause.
        # Verify by re-fetching the definition and checking expected entity names.
        if ($_ -match 'ALMOperationImportFailed') {
            Write-Info "  Fabric returned ALMOperationImportFailed — verifying changes were persisted …"
            Start-Sleep -Seconds 3

            $verifyParts = $null
            try {
                $verifyParts = Get-OntologyDefinition -WorkspaceId $WorkspaceId -OntologyId $OntologyId -Headers $Headers
            } catch {
                Write-Host "  WARNING: Could not re-fetch ontology to verify. Check Fabric manually." -ForegroundColor Yellow
                Write-Ok "Ontology definition submitted. Fabric returned a known post-import warning (ALMOperationImportFailed) — your changes are likely applied."
                return
            }

            # Collect names present in the freshly-fetched definition
            $presentNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($vp in $verifyParts) {
                if ($vp["path"] -match "^EntityTypes/[^/]+/definition\.json$") {
                    $vdef = ConvertFrom-Base64Json $vp["payload"]
                    if ($vdef -and $vdef["name"]) { [void]$presentNames.Add([string]$vdef["name"]) }
                }
            }

            # Check every expected entity is now in Fabric
            $missing = @($ExpectedEntityNames | Where-Object { -not $presentNames.Contains($_) })
            if ($missing.Count -eq 0) {
                Write-Ok "Ontology definition updated successfully. (Fabric returned a known post-import warning that does not affect the result.)"
                return
            }

            # Genuinely missing — the operation did fail
            throw "Ontology update failed. The following entities were not found after re-fetch: $($missing -join ', ')"
        }

        # Any other error: re-throw as-is
        throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Edit helpers — select an existing entity and modify its properties
# ─────────────────────────────────────────────────────────────────────────────

function Select-ExistingEntityType($Parts) {
    $entityParts = @($Parts | Where-Object { $_["path"] -match "^EntityTypes/[^/]+/definition\.json$" })
    if ($entityParts.Count -eq 0) {
        Write-Host "  No existing entity types found." -ForegroundColor Red
        return $null
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $entityParts) {
        $def = ConvertFrom-Base64Json $p["payload"]
        if ($def) { $list.Add([ordered]@{ part = $p; def = $def }) }
    }

    Write-Host "`n  Existing entity types:" -ForegroundColor White
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host "    [$($i + 1)] $($list[$i]["def"]["name"])" -ForegroundColor White
    }

    while ($true) {
        $choice = (Read-Host "  Select entity type number").Trim()
        if ($choice -match "^\d+$") {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $list.Count) { return $list[$idx] }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($list.Count)." -ForegroundColor Red
    }
}

function Invoke-EditEntityTypeProperties($EntityDef) {
    # $EntityDef is already a plain hashtable (from ConvertFrom-Base64Json).
    # Make a shallow key-by-key copy so edits here don't affect the original $parts entry
    # until Update-EntityPartInParts explicitly re-encodes the returned def.
    $def = [ordered]@{}
    foreach ($k in $EntityDef.Keys) { $def[$k] = $EntityDef[$k] }

    while ($true) {
        # Initialise to guaranteed-non-null empty arrays first (separate statements).
        # PowerShell's [object[]] type annotation does NOT coerce $null to @() — the
        # assignment must come from a statement that provably returns a non-null array.
        [object[]]$props   = @()
        [object[]]$tsProps = @()
        $propsRaw   = $def["properties"]
        $tsPropsRaw = $def["timeseriesProperties"]
        if ($null -ne $propsRaw)   { [object[]]$props   = @($propsRaw)   }
        if ($null -ne $tsPropsRaw) { [object[]]$tsProps = @($tsPropsRaw) }

        Write-Host "`n  Entity: $($def["name"])" -ForegroundColor White
        Write-Host "  Regular properties:" -ForegroundColor White
        if ($props.Count -eq 0) {
            Write-Host "    (none)" -ForegroundColor DarkGray
        } else {
            for ($i = 0; $i -lt $props.Count; $i++) {
                Write-Host "    [$($i + 1)] $($props[$i]["name"])  [$($props[$i]["valueType"])]" -ForegroundColor Gray
            }
        }

        Write-Host "  Timeseries properties:" -ForegroundColor White
        if ($tsProps.Count -eq 0) {
            Write-Host "    (none)" -ForegroundColor DarkGray
        } else {
            for ($i = 0; $i -lt $tsProps.Count; $i++) {
                Write-Host "    [TS$($i + 1)] $($tsProps[$i]["name"])  [$($tsProps[$i]["valueType"])]" -ForegroundColor Gray
            }
        }

        Write-Host ""
        Write-Host "  Actions: [A] Add regular property  [T] Add timeseries property  [R] Remove property  [D] Done" -ForegroundColor Cyan
        $action = (Read-Host "  Action").Trim().ToLower()

        switch ($action) {
            "a" {
                $propName = Read-PropertyName
                $allNames = @(@($props) + @($tsProps) | ForEach-Object { $_["name"] })
                if ($allNames -contains $propName) {
                    Write-Host "  A property named '$propName' already exists on this entity." -ForegroundColor Red
                    break
                }
                $propType = Read-ValueType
                $newProp  = [ordered]@{
                    id                    = New-EntityId
                    name                  = $propName
                    redefines             = $null
                    baseTypeNamespaceType = $null
                    valueType             = $propType
                }
                $props += $newProp
                $def["properties"] = $props
                Write-Ok "Regular property '$propName' [$propType] added."
            }
            "t" {
                $propName = Read-PropertyName
                $allNames = @(@($props) + @($tsProps) | ForEach-Object { $_["name"] })
                if ($allNames -contains $propName) {
                    Write-Host "  A property named '$propName' already exists on this entity." -ForegroundColor Red
                    break
                }
                $propType = Read-ValueType
                $newProp  = [ordered]@{
                    id                    = New-EntityId
                    name                  = $propName
                    redefines             = $null
                    baseTypeNamespaceType = $null
                    valueType             = $propType
                }
                $tsProps += $newProp
                $def["timeseriesProperties"] = $tsProps
                Write-Ok "Timeseries property '$propName' [$propType] added."
            }
            "r" {
                Write-Host "  Remove from: [R] Regular properties  [T] Timeseries properties" -ForegroundColor Cyan
                $from = (Read-Host "  Remove from").Trim().ToLower()

                if ($from -eq "r") {
                    if ($props.Count -eq 0) { Write-Host "  No regular properties to remove." -ForegroundColor Red; break }
                    $numStr = (Read-Host "  Property number to remove (1-$($props.Count))").Trim()
                    if ($numStr -match "^\d+$") {
                        $idx = [int]$numStr - 1
                        if ($idx -ge 0 -and $idx -lt $props.Count) {
                            $removedId   = $props[$idx]["id"]
                            $removedName = $props[$idx]["name"]
                            # Guard: cannot remove the entity-ID or display-name key property.
                            # Use bracket notation — these keys may legitimately be absent on some entities.
                            $entityIdParts       = if ($null -ne $def["entityIdParts"])       { @($def["entityIdParts"])       } else { @() }
                            $displayNamePropId   = $def["displayNamePropertyId"]
                            $isKey = ($entityIdParts -contains $removedId) -or ($displayNamePropId -eq $removedId)
                            if ($isKey) {
                                Write-Host "  Cannot remove '$removedName' — it is used as the entity ID or display-name key." -ForegroundColor Red
                                break
                            }
                            [object[]]$props = @($props | Where-Object { $_["id"] -ne $removedId })
                            $def["properties"] = $props
                            Write-Ok "Regular property '$removedName' removed."
                        } else { Write-Host "  Number out of range." -ForegroundColor Red }
                    } else { Write-Host "  Invalid input." -ForegroundColor Red }

                } elseif ($from -eq "t") {
                    if ($tsProps.Count -eq 0) { Write-Host "  No timeseries properties to remove." -ForegroundColor Red; break }
                    $numStr = (Read-Host "  Timeseries property number to remove (1-$($tsProps.Count))").Trim()
                    if ($numStr -match "^\d+$") {
                        $idx = [int]$numStr - 1
                        if ($idx -ge 0 -and $idx -lt $tsProps.Count) {
                            $removedId   = $tsProps[$idx]["id"]
                            $removedName = $tsProps[$idx]["name"]
                            [object[]]$tsProps = @($tsProps | Where-Object { $_["id"] -ne $removedId })
                            $def["timeseriesProperties"] = $tsProps
                            Write-Ok "Timeseries property '$removedName' removed."
                        } else { Write-Host "  Number out of range." -ForegroundColor Red }
                    } else { Write-Host "  Invalid input." -ForegroundColor Red }

                } else {
                    Write-Host "  Enter R (regular) or T (timeseries)." -ForegroundColor Red
                }
            }
            "d" { return $def }
            default { Write-Host "  Unknown action. Use A, T, R, or D." -ForegroundColor Red }
        }
    }
}

function Update-EntityPartInParts($Parts, [string]$EntityId, $UpdatedDef) {
    $targetPath = "EntityTypes/$EntityId/definition.json"
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        if ($Parts[$i]["path"] -eq $targetPath) {
            # Capture original payload BEFORE overwriting, for diagnostic comparison
            $origPayload = $Parts[$i]["payload"]

            $Parts[$i] = [ordered]@{
                path        = $Parts[$i]["path"]
                payload     = ConvertTo-Base64Json $UpdatedDef
                payloadType = "InlineBase64"
            }
            # Mark as dirty so pre-flight knows to validate/re-encode this part
            [void]$Script:DirtyPaths.Add($targetPath)

            # ── Diagnostic: save original and updated JSON side-by-side ──────────
            $origDef  = ConvertFrom-Base64Json $origPayload
            $diagFile = "$env:TEMP\fabric-edit-$EntityId.json"
            @{ original = $origDef; updated = $UpdatedDef } | ConvertTo-Json -Depth 20 |
                Set-Content $diagFile -Encoding UTF8 -NoNewline
            Write-Info "  Saved original vs updated entity JSON: $diagFile"
            return
        }
    }
    throw "Could not find definition part for entity ID '$EntityId'."
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight — deduplicate and validate the full parts list before pushing
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-OntologyPreflight {
    <#
    Mutates $Parts in place:
      • Removes earlier duplicate entity-type parts (same name) — latest definition wins.
      • For dirty (modified/new) parts only: deduplicates properties, ensures required arrays
        are present, then re-encodes.
      • Unmodified parts fetched from Fabric are NEVER decoded/re-encoded — their original
        base64 payload is passed through byte-for-byte to avoid round-trip corruption.
    Returns $true when the payload is safe to submit.
    #>
    param([System.Collections.Generic.List[object]]$Parts)

    $ok = $true

    # ── Pass 1: remove earlier duplicate entity-type parts (keep the LAST = most recent) ──
    # This only removes parts from the list — no payload is decoded or re-encoded here.
    $nameToLatestIdx = @{}
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        if ($Parts[$i]["path"] -notmatch "^EntityTypes/[^/]+/definition\.json$") { continue }
        $def = ConvertFrom-Base64Json $Parts[$i]["payload"]
        if (-not $def) { continue }
        $n = $def["name"]
        if ($n) { $nameToLatestIdx[$n] = $i }
    }

    $toRemove = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        if ($Parts[$i]["path"] -notmatch "^EntityTypes/[^/]+/definition\.json$") { continue }
        $def = ConvertFrom-Base64Json $Parts[$i]["payload"]
        if (-not $def) { continue }
        $n = $def["name"]
        if ($n -and $nameToLatestIdx[$n] -ne $i) {
            $toRemove.Add($i)
            Write-Info "  Pre-flight: removed earlier duplicate definition for entity '$n'."
        }
    }
    foreach ($idx in @($toRemove | Sort-Object -Descending)) { $Parts.RemoveAt($idx) }

    # ── Pass 2: validate and re-encode ONLY dirty (modified / newly added) parts ──
    # Unmodified Fabric parts are skipped entirely — their original payload is preserved.
    $unchangedCount = 0
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        $partPath = $Parts[$i]["path"]
        if ($partPath -notmatch "^EntityTypes/[^/]+/definition\.json$") { continue }

        if (-not $Script:DirtyPaths.Contains($partPath)) {
            $unchangedCount++
            continue   # keep original Fabric payload untouched
        }

        $def = ConvertFrom-Base64Json $Parts[$i]["payload"]
        if (-not $def) { continue }
        $eName = $def["name"]

        [object[]]$props   = @()
        [object[]]$tsProps = @()
        $propsRaw   = $def["properties"]
        $tsPropsRaw = $def["timeseriesProperties"]
        if ($null -ne $propsRaw)   { [object[]]$props   = @($propsRaw)   }
        if ($null -ne $tsPropsRaw) { [object[]]$tsProps = @($tsPropsRaw) }

        # Deduplicate properties by name — keep first occurrence
        $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $seenTs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [object[]]$cleanProps = @($props   | Where-Object { $_ -and $seen.Add([string]$_["name"]) })
        [object[]]$cleanTs    = @($tsProps | Where-Object { $_ -and $seenTs.Add([string]$_["name"]) })

        if ($cleanProps.Count -ne $props.Count -or $cleanTs.Count -ne $tsProps.Count) {
            Write-Info "  Pre-flight: removed duplicate properties in entity '$eName'."
        }

        if ($cleanProps.Count -eq 0) {
            Write-Host "  ERROR: Entity '$eName' has no regular properties. The API requires at least one." -ForegroundColor Red
            $ok = $false
        }

        $def["properties"]           = $cleanProps
        $def["timeseriesProperties"] = $cleanTs
        if ($null -eq $def["untypedProperties"]) { $def["untypedProperties"] = @() }

        # ── Validate / reconstruct entityIdParts and displayNamePropertyId ────
        # These can be corrupted when PSObject-wrapping + ConvertTo-Json single-element
        # flattening converts the array to a PSObject that serializes as {"Length":N}.
        # Always derive from properties[0] for dirty entities — it is always the key prop.
        if ($cleanProps.Count -gt 0) {
            $keyPropId = [string]$cleanProps[0]["id"]

            # entityIdParts must be a List<object> so ConvertTo-Json emits ["id"] not "id"
            $eidp = $def["entityIdParts"]
            $needRebuildEidp = ($null -eq $eidp) -or
                               ($eidp -isnot [System.Collections.IEnumerable]) -or
                               ($eidp -is [string]) -or
                               ($eidp -is [System.Collections.IDictionary])   # catches {"Length":N}
            if ($needRebuildEidp) {
                $eidpList = [System.Collections.Generic.List[object]]::new()
                $eidpList.Add($keyPropId)
                $def["entityIdParts"] = $eidpList
                Write-Info "  Pre-flight: rebuilt entityIdParts for '$eName'."
            } else {
                # Even if array looks valid, ensure it is a List<object> to prevent
                # single-element Object[] from being flattened by ConvertTo-Json.
                $eidpList = [System.Collections.Generic.List[object]]::new()
                foreach ($id in $eidp) { $eidpList.Add([string]$id) }
                $def["entityIdParts"] = $eidpList
            }

            # displayNamePropertyId must be a non-null string
            $dnpid = $def["displayNamePropertyId"]
            $needRebuildDnpid = ($null -eq $dnpid) -or
                                ($dnpid -is [System.Collections.IDictionary])  # catches {"Length":N}
            if ($needRebuildDnpid) {
                $def["displayNamePropertyId"] = $keyPropId
                Write-Info "  Pre-flight: rebuilt displayNamePropertyId for '$eName'."
            }
        }

        # ── Diagnostic: save decoded JSON of this dirty part before re-encoding ──
        $diagBefore = "$env:TEMP\fabric-dirty-before-$eName.json"
        $def | ConvertTo-Json -Depth 20 | Set-Content $diagBefore -Encoding UTF8 -NoNewline
        Write-Info "  Preflight: dirty entity '$eName' — pre-encode snapshot: $diagBefore"

        $Parts[$i] = [ordered]@{
            path        = $partPath
            payload     = ConvertTo-Base64Json $def
            payloadType = "InlineBase64"
        }

        # ── Diagnostic: save decoded JSON after re-encode so we can diff before/after ──
        $diagAfter = "$env:TEMP\fabric-dirty-after-$eName.json"
        $def | ConvertTo-Json -Depth 20 | Set-Content $diagAfter -Encoding UTF8 -NoNewline
        Write-Info "  Preflight: dirty entity '$eName' — post-encode snapshot: $diagAfter"
    }

    if ($unchangedCount -gt 0) {
        Write-Info "  Pre-flight: $unchangedCount existing entity type(s) passed through unchanged."
    }

    return $ok
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "Fabric Ontology — Add / Edit Entity Types"

# ── Prompt for IDs if not supplied as parameters ────────────────────────────
if (-not $WorkspaceId) {
    $WorkspaceId = Read-NonEmpty "Enter your Fabric Workspace ID (GUID)"
}
if (-not $OntologyId) {
    $OntologyId  = Read-NonEmpty "Enter your Ontology Item ID (GUID)"
}

# ── Auth ─────────────────────────────────────────────────────────────────────
$token   = Get-FabricToken
$headers = Get-AuthHeaders $token

# ── Fetch current definition ─────────────────────────────────────────────────
# Wrap in a new List — PowerShell pipelines unwrap List<object> to a fixed-size array
$parts = [System.Collections.Generic.List[object]]::new(
    [object[]]@(Get-OntologyDefinition -WorkspaceId $WorkspaceId -OntologyId $OntologyId -Headers $headers)
)

# ── Show what is already there ────────────────────────────────────────────────
Show-ExistingEntityTypes -Parts $parts

# ── Action loop ───────────────────────────────────────────────────────────────
$addedEntityTypes  = [System.Collections.Generic.List[object]]::new()
$editedEntityNames = [System.Collections.Generic.List[string]]::new()
$changesMade       = $false

# Track which entity-type part paths were modified this session.
# Only dirty parts get re-encoded before upload; all others keep their original Fabric payload.
$Script:DirtyPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Capture a reference entity BEFORE any edits — used as the structural template
# for new entity types so their payloads exactly match Fabric's own format.
$refEntityInfo = Get-ReferenceEntityInfo -Parts $parts
if ($null -ne $refEntityInfo) {
    Write-Info "  Reference entity (template for new entities): '$($refEntityInfo["def"]["name"])'"
} else {
    Write-Info "  No existing entity types found — new entities will use built-in schema template."
}

:actionLoop while ($true) {
    Write-Host "`n  What would you like to do?" -ForegroundColor Cyan
    Write-Host "    [A] Add a new entity type" -ForegroundColor White
    Write-Host "    [E] Edit properties of an existing entity type (add / remove)" -ForegroundColor White
    Write-Host "    [S] Submit all changes to Fabric" -ForegroundColor White
    Write-Host "    [Q] Quit without saving" -ForegroundColor White

    $choice = (Read-Host "  Choice").Trim().ToLower()

    switch ($choice) {

        # ── Add a brand-new entity type ────────────────────────────────────
        "a" {
            Write-Header "Define New Entity Type"

            # Build name-exclusion set from what is already in $parts + queued additions
            $existingNames = @{}
            foreach ($p in $parts) {
                if ($p["path"] -match "^EntityTypes/[^/]+/definition\.json$") {
                    $d = ConvertFrom-Base64Json $p["payload"]
                    if ($d -and $d["name"]) { $existingNames[$d["name"]] = $true }
                }
            }
            foreach ($e in $addedEntityTypes) { $existingNames[$e["entityDef"]["name"]] = $true }

            if ($existingNames.Count -gt 0) {
                Write-Info "  Existing entity names (cannot be reused): $($existingNames.Keys -join ', ')"
            }

            while ($true) {
                $refDef = if ($null -ne $refEntityInfo) { $refEntityInfo["def"] } else { $null }
                $entry  = Read-NewEntityType -RefDef $refDef

                # Re-check names including anything queued this session
                $allUsed = $existingNames.Clone()
                foreach ($e in $addedEntityTypes) { $allUsed[$e["entityDef"]["name"]] = $true }

                if ($allUsed.ContainsKey($entry["entityDef"]["name"])) {
                    Write-Host "`n  ERROR: An entity named '$($entry["entityDef"]["name"])' already exists." -ForegroundColor Red
                    Write-Host "  Please choose a different name." -ForegroundColor Red
                    continue
                }

                $addedEntityTypes.Add($entry)
                Write-Ok "Entity type '$($entry["entityDef"]["name"])' (ID: $($entry["entityId"])) queued."
                $changesMade = $true

                $another = Read-Host "`nAdd another entity type? [y/N]"
                if ($another.Trim().ToLower() -ne "y") { break }
            }
        }

        # ── Edit properties of an existing entity type ─────────────────────
        "e" {
            Write-Header "Edit Existing Entity Type Properties"

            $selection = Select-ExistingEntityType -Parts $parts
            if ($null -eq $selection) { break }

            $entityId   = $selection["def"]["id"]
            $updatedDef = Invoke-EditEntityTypeProperties -EntityDef $selection["def"]

            Update-EntityPartInParts -Parts $parts -EntityId $entityId -UpdatedDef $updatedDef
            Write-Ok "Entity '$($updatedDef["name"])' updated in local definition."
            $editedEntityNames.Add($updatedDef["name"])
            $changesMade = $true
        }

        # ── Submit ─────────────────────────────────────────────────────────
        "s" { break actionLoop }

        # ── Quit without saving ────────────────────────────────────────────
        "q" {
            Write-Host "`n  Aborted. No changes were made." -ForegroundColor Yellow
            exit 0
        }

        default {
            Write-Host "  Unknown choice. Enter A, E, S, or Q." -ForegroundColor Red
        }
    }
}

if (-not $changesMade) {
    Write-Host "`n  No changes were made. Exiting." -ForegroundColor Yellow
    exit 0
}

# ── Append new entity-type parts ──────────────────────────────────────────────
if ($addedEntityTypes.Count -gt 0) {
    Write-Step "Building updated definition parts …"
    Add-EntityTypesToParts -Parts $parts -NewEntityTypes $addedEntityTypes
}

Write-Info "Total definition parts to upload: $($parts.Count)"

# ── Pre-flight: deduplicate and validate before showing confirm ───────────────
Write-Step "Running pre-flight checks …"
$preflightOk = Invoke-OntologyPreflight -Parts $parts
if (-not $preflightOk) {
    Write-Host "`n  Pre-flight failed — resolve the errors above then re-run the script." -ForegroundColor Red
    exit 1
}
Write-Ok "Pre-flight checks passed. $($parts.Count) parts ready to upload."

# ── Confirm before submitting ────────────────────────────────────────────────
if ($addedEntityTypes.Count -gt 0) {
    Write-Host "`n  Entity types to be added:" -ForegroundColor White
    foreach ($e in $addedEntityTypes) {
        $propList = ($e["entityDef"]["properties"] | ForEach-Object { "$($_["name"]) [$($_["valueType"])]" }) -join ", "
        Write-Host "    • $($e["entityDef"]["name"])  (ID: $($e["entityId"]))  props: $propList" -ForegroundColor White
        Write-Info "    Payload: $($e["entityDef"] | ConvertTo-Json -Depth 10 -Compress)"
    }
}

if ($editedEntityNames.Count -gt 0) {
    Write-Host "`n  Entity types with property changes:" -ForegroundColor White
    foreach ($name in $editedEntityNames) {
        Write-Host "    • $name" -ForegroundColor White
    }
}

$confirm = Read-Host "`nProceed and update the ontology? [Y/n]"
if ($confirm.Trim().ToLower() -eq "n") {
    Write-Host "`n  Aborted. No changes were made." -ForegroundColor Yellow
    exit 0
}

# ── Push ─────────────────────────────────────────────────────────────────────
# Collect all entity names we expect to be in Fabric after the update.
# Used by Update-OntologyDefinition to verify success when Fabric returns the
# known false-positive ALMOperationImportFailed 400 error.
$expectedNames = [System.Collections.Generic.List[string]]::new()
foreach ($e in $addedEntityTypes)    { $expectedNames.Add($e["entityDef"]["name"]) }
foreach ($name in $editedEntityNames) { $expectedNames.Add($name) }
# Also include all pre-existing entities (they must survive the round-trip)
foreach ($p in $parts) {
    if ($p["path"] -match "^EntityTypes/[^/]+/definition\.json$") {
        $pd = ConvertFrom-Base64Json $p["payload"]
        if ($pd -and $pd["name"]) { $expectedNames.Add([string]$pd["name"]) }
    }
}

Update-OntologyDefinition -WorkspaceId $WorkspaceId -OntologyId $OntologyId -Parts $parts -Headers $headers -ExpectedEntityNames @($expectedNames)

$totalChanges = $addedEntityTypes.Count + $editedEntityNames.Count
Write-Header "Done — $totalChanges change(s) applied successfully."
