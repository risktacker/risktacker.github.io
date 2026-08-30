[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

$Downloads = Join-Path $env:USERPROFILE "Downloads"
$ClientSecrets = Get-ChildItem (Join-Path $Downloads "client_secret_*.json") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $ClientSecrets -or -not (Test-Path -LiteralPath $ClientSecrets)) {
    throw "OAuth client JSON not found in Downloads."
}

$ClientDocument = Get-Content -LiteralPath $ClientSecrets -Raw | ConvertFrom-Json
$Client = $ClientDocument.installed
if (-not $Client) {
    throw "The downloaded JSON is not a Desktop OAuth client."
}

$Random = [Security.Cryptography.RandomNumberGenerator]::Create()
$VerifierBytes = New-Object byte[] 64
$StateBytes = New-Object byte[] 32
$Random.GetBytes($VerifierBytes)
$Random.GetBytes($StateBytes)
$Random.Dispose()

$CodeVerifier = ConvertTo-Base64Url $VerifierBytes
$State = ConvertTo-Base64Url $StateBytes
$Sha256 = [Security.Cryptography.SHA256]::Create()
$ChallengeBytes = $Sha256.ComputeHash([Text.Encoding]::ASCII.GetBytes($CodeVerifier))
$Sha256.Dispose()
$CodeChallenge = ConvertTo-Base64Url $ChallengeBytes

$PortProbe = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$PortProbe.Start()
$Port = ([Net.IPEndPoint]$PortProbe.LocalEndpoint).Port
$PortProbe.Stop()

$RedirectUri = "http://127.0.0.1:$Port/"
$Scopes = @(
    "https://www.googleapis.com/auth/youtube.upload",
    "https://www.googleapis.com/auth/youtube.readonly",
    "https://www.googleapis.com/auth/yt-analytics.readonly",
    "https://www.googleapis.com/auth/yt-analytics-monetary.readonly"
)
$ScopeText = $Scopes -join " "

$Query = @(
    "client_id=$([Uri]::EscapeDataString($Client.client_id))",
    "redirect_uri=$([Uri]::EscapeDataString($RedirectUri))",
    "response_type=code",
    "scope=$([Uri]::EscapeDataString($ScopeText))",
    "access_type=offline",
    "prompt=consent",
    "state=$([Uri]::EscapeDataString($State))",
    "code_challenge=$([Uri]::EscapeDataString($CodeChallenge))",
    "code_challenge_method=S256"
) -join "&"
$AuthorizationUrl = "https://accounts.google.com/o/oauth2/v2/auth?$Query"

$Listener = New-Object Net.HttpListener
$Listener.Prefixes.Add($RedirectUri)
$Listener.Start()

Write-Host "Opening Google authorization..." -ForegroundColor Cyan
Start-Process $AuthorizationUrl

try {
    $Context = $Listener.GetContext()
    $ReturnedState = $Context.Request.QueryString["state"]
    $AuthorizationCode = $Context.Request.QueryString["code"]
    $AuthorizationError = $Context.Request.QueryString["error"]

    $ResponseText = if ($AuthorizationCode -and $ReturnedState -eq $State) {
        "GOLIDE YouTube authorization completed. Return to PowerShell."
    } else {
        "GOLIDE authorization failed. Return to PowerShell."
    }
    $ResponseBytes = [Text.Encoding]::UTF8.GetBytes($ResponseText)
    $Context.Response.ContentType = "text/plain; charset=utf-8"
    $Context.Response.ContentLength64 = $ResponseBytes.Length
    $Context.Response.OutputStream.Write($ResponseBytes, 0, $ResponseBytes.Length)
    $Context.Response.OutputStream.Close()

    if ($AuthorizationError) {
        throw "Google authorization failed: $AuthorizationError"
    }
    if (-not $AuthorizationCode -or $ReturnedState -ne $State) {
        throw "Google authorization response was invalid."
    }
}
finally {
    $Listener.Stop()
    $Listener.Close()
}

$Token = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -Body @{
    client_id = $Client.client_id
    client_secret = $Client.client_secret
    code = $AuthorizationCode
    code_verifier = $CodeVerifier
    grant_type = "authorization_code"
    redirect_uri = $RedirectUri
}

if (-not $Token.refresh_token) {
    throw "Google did not return a fresh refresh token."
}

$Channel = Invoke-RestMethod -Method Get -Uri "https://www.googleapis.com/youtube/v3/channels?part=id%2Csnippet&mine=true" -Headers @{
    Authorization = "Bearer $($Token.access_token)"
}

$ExpectedChannelId = "UCqaXVBSBz7iQsRHOupKt-3w"
$Items = @($Channel.items)
if ($Items.Count -ne 1 -or $Items[0].id -ne $ExpectedChannelId) {
    $Found = ($Items | ForEach-Object { $_.id }) -join ","
    throw "Wrong YouTube channel. Expected $ExpectedChannelId; found $Found"
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI is required but was not found."
}
& gh auth status --hostname github.com
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated."
}

$Expiry = [DateTime]::UtcNow.AddSeconds([double]$Token.expires_in).ToString("o")
$CredentialObject = [ordered]@{
    token = $Token.access_token
    refresh_token = $Token.refresh_token
    token_uri = "https://oauth2.googleapis.com/token"
    client_id = $Client.client_id
    client_secret = $Client.client_secret
    scopes = $Scopes
    expiry = $Expiry
    universe_domain = "googleapis.com"
    account = ""
}
$CredentialJson = $CredentialObject | ConvertTo-Json -Depth 5 -Compress
$EncodedToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CredentialJson))

$EncodedToken | & gh secret set YOUTUBE_OAUTH_TOKEN_B64 --repo risktacker/golide-content-engine
if ($LASTEXITCODE -ne 0) {
    throw "Could not save the production OAuth token to GitHub."
}

& gh variable set GOLIDE_ANALYTICS_ENABLED --repo risktacker/golide-content-engine --body true
if ($LASTEXITCODE -ne 0) {
    throw "Could not enable daily analytics."
}

Remove-Item -LiteralPath $ClientSecrets -Force
Write-Host "Channel verified: $($Items[0].snippet.title) ($ExpectedChannelId)" -ForegroundColor Green
Write-Host "SUCCESS: Production OAuth token saved; client JSON deleted." -ForegroundColor Green
