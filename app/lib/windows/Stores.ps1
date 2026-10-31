#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil's built-in secret stores - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    HashiCorp Vault, Azure Key Vault, AWS Secrets Manager and GCP Secret Manager
    over HTTPS with .NET, so nothing else needs installing (SPECIFICATION.md
    6.5.3). The twin of stores.sh. Credentials and tokens are sent in headers
    or request bodies, never in URLs, and live only in variables.

    Get-VigilJsonString -Json <text> -Path <key>...
        The string at that path of objects: @{ Ok; Value; Why }. Strict on
        the path it follows; everything else is only skipped.
    Get-VigilStoreSecret -Root <dir> -Parsed <config> -Store <name> -Type <type> -Name <name>
        @{ Ok; Value; Why }. Why never contains a value.
    Invoke-VigilHttpSend: one request; the conformance suite replaces it.

    Requires Secrets.ps1 and Worker.ps1.
#>

# --- JSON --------------------------------------------------------------------

$Script:VigilJsonNumber = '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$'

# The parser's state: the document and the position being read.
function Skip-VigilJsonSpace {
    param($S)
    while ($S.P -lt $S.J.Length -and " `t`n`r".IndexOf($S.J[$S.P]) -ge 0) { $S.P++ }
}

# Four hex digits at the position, or -1.
function Read-VigilJsonHex4 {
    param($S)
    if ($S.P + 4 -gt $S.J.Length) { return -1 }
    $h = $S.J.Substring($S.P, 4)
    if ($h -notmatch '^[0-9A-Fa-f]{4}$') { return -1 }
    $S.P += 4
    return [Convert]::ToInt32($h, 16)
}

# The string at the position, decoded, or $null when it is not valid.
function Read-VigilJsonString {
    param($S)
    $sb = New-Object System.Text.StringBuilder
    $S.P++
    $stops = [char[]]@('"', '\')
    while ($true) {
        $i = $S.J.IndexOfAny($stops, $S.P)
        if ($i -lt 0) { return $null }
        [void]$sb.Append($S.J, $S.P, $i - $S.P)
        $S.P = $i + 1
        if ($S.J[$i] -eq '"') { return $sb.ToString() }
        if ($S.P -ge $S.J.Length) { return $null }
        $c = $S.J[$S.P]
        $S.P++
        switch -CaseSensitive ([string]$c) {
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            '/' { [void]$sb.Append('/') }
            'b' { [void]$sb.Append([char]8) }
            'f' { [void]$sb.Append([char]12) }
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            'u' {
                $cp = Read-VigilJsonHex4 $S
                if ($cp -lt 0) { return $null }
                # A surrogate pair is one code point; a lone surrogate, or
                # NUL, which no value can hold, is not valid.
                if ($cp -ge 0xD800 -and $cp -le 0xDBFF) {
                    if ($S.P + 2 -gt $S.J.Length -or $S.J.Substring($S.P, 2) -cne '\u') { return $null }
                    $S.P += 2
                    $lo = Read-VigilJsonHex4 $S
                    if ($lo -lt 0xDC00 -or $lo -gt 0xDFFF) { return $null }
                    [void]$sb.Append([char]$cp).Append([char]$lo)
                }
                elseif (($cp -ge 0xDC00 -and $cp -le 0xDFFF) -or $cp -eq 0) { return $null }
                else { [void]$sb.Append([char]$cp) }
            }
            default { return $null }
        }
    }
}

# Skips the value at the position. Containers are only matched for brackets.
function Skip-VigilJsonValue {
    param($S)
    if ($S.P -ge $S.J.Length) { return $false }
    $c = $S.J[$S.P]
    if ($c -eq '"') { return $null -ne (Read-VigilJsonString $S) }
    if ($c -ne '{' -and $c -ne '[') {
        $start = $S.P
        while ($S.P -lt $S.J.Length -and ",}] `t`n`r".IndexOf($S.J[$S.P]) -lt 0) { $S.P++ }
        $run = $S.J.Substring($start, $S.P - $start)
        if ($run -ceq 'true' -or $run -ceq 'false' -or $run -ceq 'null') { return $true }
        return $run -cmatch $Script:VigilJsonNumber
    }
    $depth = 0
    $stops = [char[]]@('"', '{', '}', '[', ']')
    while ($true) {
        $i = $S.J.IndexOfAny($stops, $S.P)
        if ($i -lt 0) { $S.P = $S.J.Length; return $false }
        $S.P = $i
        $c = $S.J[$i]
        if ($c -eq '"') {
            if ($null -eq (Read-VigilJsonString $S)) { return $false }
            continue
        }
        if ($c -eq '{' -or $c -eq '[') { $depth++ } else { $depth-- }
        $S.P++
        if ($depth -eq 0) { return $true }
    }
}

function Get-VigilJsonString {
    param([string]$Json, [string[]]$Path)
    $S = @{ J = $Json; P = 0 }
    $bad = @{ Ok = $false; Why = 'not valid JSON' }
    $name = $Path -join '.'
    $none = @{ Ok = $false; Why = "no $name" }
    Skip-VigilJsonSpace $S
    if ($S.P -ge $S.J.Length -or $S.J[$S.P] -ne '{') { return @{ Ok = $false; Why = 'not a JSON object' } }
    foreach ($k in $Path) {
        if ($S.P -ge $S.J.Length -or $S.J[$S.P] -ne '{') { return $none }
        $S.P++
        while ($true) {
            Skip-VigilJsonSpace $S
            if ($S.P -ge $S.J.Length) { return $bad }
            if ($S.J[$S.P] -eq '}') { return $none }
            if ($S.J[$S.P] -ne '"') { return $bad }
            $key = Read-VigilJsonString $S
            if ($null -eq $key) { return $bad }
            Skip-VigilJsonSpace $S
            if ($S.P -ge $S.J.Length -or $S.J[$S.P] -ne ':') { return $bad }
            $S.P++
            Skip-VigilJsonSpace $S
            # The first of repeated keys counts.
            if ($key -ceq $k) { break }
            if (-not (Skip-VigilJsonValue $S)) { return $bad }
            Skip-VigilJsonSpace $S
            if ($S.P -ge $S.J.Length) { return $bad }
            if ($S.J[$S.P] -eq ',') { $S.P++ }
            elseif ($S.J[$S.P] -eq '}') { return $none }
            else { return $bad }
        }
    }
    if ($S.P -lt $S.J.Length -and $S.J[$S.P] -eq '"') {
        $v = Read-VigilJsonString $S
        if ($null -eq $v) { return $bad }
        return @{ Ok = $true; Value = $v }
    }
    if (-not (Skip-VigilJsonValue $S)) { return $bad }
    return @{ Ok = $false; Why = "$name is not a string" }
}

# --- HTTP --------------------------------------------------------------------

# Percent-encodes UTF-8 bytes, keeping A-Z a-z 0-9 - . _ ~ and, with
# -KeepSlash, /.
function ConvertTo-VigilPercent {
    param([string]$Text, [switch]$KeepSlash)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Text)) {
        $c = [char]$b
        if (($b -ge 0x41 -and $b -le 0x5A) -or ($b -ge 0x61 -and $b -le 0x7A) -or ($b -ge 0x30 -and $b -le 0x39) -or
            '-._~'.IndexOf($c) -ge 0 -or ($KeepSlash -and $c -eq '/')) { [void]$sb.Append($c) }
        else { [void]$sb.Append('%').Append($b.ToString('X2')) }
    }
    return $sb.ToString()
}

# A JSON string. Control characters never get here.
function ConvertTo-VigilJsonQuoted {
    param([string]$Text)
    return '"' + $Text.Replace('\', '\\').Replace('"', '\"') + '"'
}

# The first exception in a chain that says what went wrong.
function Get-VigilHttpFailure {
    param($Exception)
    $e = $Exception
    while ($e) {
        if ($e -is [System.Net.WebException]) {
            switch ([string]$e.Status) {
                'NameResolutionFailure' { return 'resolve' }
                'ProxyNameResolutionFailure' { return 'resolve' }
                'ConnectFailure' { return 'connect' }
                'Timeout' { return 'timeout' }
                'TrustFailure' { return 'untrusted' }
                'SecureChannelFailure' { return 'tls' }
            }
        }
        if ($e -is [System.Net.Sockets.SocketException]) {
            if (@('HostNotFound', 'NoData', 'TryAgain') -contains [string]$e.SocketErrorCode) { return 'resolve' }
            return 'connect'
        }
        if ($e -is [System.Security.Authentication.AuthenticationException]) {
            if ($e.Message -match 'certificate') { return 'untrusted' }
            return 'tls'
        }
        if ($e -is [System.TimeoutException] -or $e -is [System.Threading.Tasks.TaskCanceledException]) { return 'timeout' }
        $e = $e.InnerException
    }
    return 'other'
}

<#
    One request, returning @{ Ok; Status; Body } or @{ Ok = $false; Fail }
    with Fail one of resolve, connect, timeout, untrusted, tls, other. Only
    https, except -Metadata: the instance metadata endpoint, plain http and
    never through a proxy. Redirects are never followed. With -CaFile, the
    server's certificate must chain to that CA instead of the system's.
#>
function Invoke-VigilHttpSend {
    param([int]$Timeout, [string]$Method, [string]$Url, [string]$CaFile, [bool]$Metadata, [string[]]$Headers, [string]$Body)
    $scheme = if ($Metadata) { 'http://' } else { 'https://' }
    if (-not $Url.StartsWith($scheme, [System.StringComparison]::Ordinal)) { return @{ Ok = $false; Fail = 'other' } }
    $ca = $null
    if ($CaFile) {
        try { $ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $CaFile }
        catch { return @{ Ok = $false; Fail = 'cafile' } }
    }
    $bytes = if ($Method -ceq 'POST') { [System.Text.Encoding]::UTF8.GetBytes($Body) } else { $null }
    if ($PSVersionTable.PSEdition -ceq 'Core') {
        $h = New-Object System.Net.Http.SocketsHttpHandler
        $h.AllowAutoRedirect = $false
        if ($Metadata) { $h.UseProxy = $false }
        if ($ca) {
            # .NET 7 and later: the CA as the only root, no callback. A
            # private CA rarely publishes revocation lists; curl does not
            # check them either.
            $policy = New-Object System.Security.Cryptography.X509Certificates.X509ChainPolicy
            $policy.TrustMode = 'CustomRootTrust'
            $policy.RevocationMode = 'NoCheck'
            [void]$policy.CustomTrustStore.Add($ca)
            $h.SslOptions.CertificateChainPolicy = $policy
        }
        $client = New-Object System.Net.Http.HttpClient -ArgumentList $h
        $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
        try {
            $m = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod $Method), $Url
            $type = $null
            foreach ($line in $Headers) {
                $c = $line.IndexOf(':')
                $n = $line.Substring(0, $c)
                $v = $line.Substring($c + 1).Trim()
                if ($n -ceq 'Content-Type') { $type = $v } else { [void]$m.Headers.TryAddWithoutValidation($n, $v) }
            }
            if ($null -ne $bytes) {
                $m.Content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
                if ($type) { [void]$m.Content.Headers.TryAddWithoutValidation('Content-Type', $type) }
            }
            $r = $client.SendAsync($m).GetAwaiter().GetResult()
            $text = [System.Text.Encoding]::UTF8.GetString($r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
            return @{ Ok = $true; Status = [int]$r.StatusCode; Body = $text }
        }
        catch { return @{ Ok = $false; Fail = (Get-VigilHttpFailure $_.Exception) } }
        finally { $client.Dispose() }
    }
    # Windows PowerShell 5.1: HttpWebRequest, with TLS 1.2 allowed.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $Timeout * 1000
    $req.ReadWriteTimeout = $Timeout * 1000
    $req.AllowAutoRedirect = $false
    if ($Metadata) { $req.Proxy = $null }
    if ($ca) {
        $req.ServerCertificateValidationCallback = {
            param($sender, $cert, $chain, $errors)
            if ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) { return $false }
            if ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNotAvailable) { return $false }
            $c = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $c.ChainPolicy.RevocationMode = 'NoCheck'
            $c.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
            [void]$c.ChainPolicy.ExtraStore.Add($ca)
            if (-not $c.Build([System.Security.Cryptography.X509Certificates.X509Certificate2]$cert)) { return $false }
            return $c.ChainElements[$c.ChainElements.Count - 1].Certificate.Thumbprint -ceq $ca.Thumbprint
        }.GetNewClosure()
    }
    foreach ($line in $Headers) {
        $c = $line.IndexOf(':')
        $n = $line.Substring(0, $c)
        $v = $line.Substring($c + 1).Trim()
        if ($n -ceq 'Content-Type') { $req.ContentType = $v } else { $req.Headers.Add($n, $v) }
    }
    $resp = $null
    try {
        if ($null -ne $bytes) {
            $req.ContentLength = $bytes.Length
            $s = $req.GetRequestStream()
            $s.Write($bytes, 0, $bytes.Length)
            $s.Close()
        }
        elseif ($Method -ceq 'PUT') { $req.ContentLength = 0 }
        $resp = $req.GetResponse()
    }
    catch {
        $e = $_.Exception
        while ($e -and -not ($e -is [System.Net.WebException])) { $e = $e.InnerException }
        if ($e -and $e.Response) { $resp = $e.Response }
        else { return @{ Ok = $false; Fail = (Get-VigilHttpFailure $_.Exception) } }
    }
    try {
        $reader = New-Object System.IO.StreamReader -ArgumentList $resp.GetResponseStream(), ([System.Text.Encoding]::UTF8)
        return @{ Ok = $true; Status = [int]$resp.StatusCode; Body = $reader.ReadToEnd() }
    }
    catch { return @{ Ok = $false; Fail = (Get-VigilHttpFailure $_.Exception) } }
    finally { $resp.Close() }
}

# --- Stores ------------------------------------------------------------------

# A store section's keys, with their defaults.
function Get-VigilStoreKeys {
    param([string]$Root, $Parsed, [string]$Store)
    $k = @{
        url = ''; vault = ''; mount = 'secret'; field = ''; auth = ''; token = ''; role_id = ''; secret_id = ''
        tenant_id = ''; client_id = ''; client_secret = ''; authority = 'https://login.microsoftonline.com'; ca_file = ''; timeout = 10
        region = ''; access_key_id = ''; secret_access_key = ''; endpoint = ''; project = ''; service_account_key = ''; client = 'auto'
    }
    foreach ($e in $Parsed.Entries) {
        if ($e.Section -cne "secret_store.$Store") { continue }
        if ($e.Key -ceq 'timeout') { $k.timeout = ConvertTo-VigilSeconds $e.Value }
        elseif ($k.ContainsKey($e.Key)) { $k[$e.Key] = $e.Value }
    }
    if ($k.ca_file -and -not [System.IO.Path]::IsPathRooted($k.ca_file)) { $k.ca_file = Join-Path $Root $k.ca_file }
    return $k
}

# The store's own credential: @{ Ok; Value; Why }.
function Get-VigilStoreCredential {
    param([string]$Root, $Parsed, [string]$Key, [string]$Reference)
    if (-not $Reference) { return @{ Ok = $false; Why = "the store needs '$Key'" } }
    $r = Resolve-VigilSecret -Root $Root -Parsed $Parsed -Reference $Reference
    if (-not $r.Ok) { return @{ Ok = $false; Why = "$Key ${Reference}: $($r.Why)" } }
    if ($r.Value -match '[\x00-\x1f\x7f]') { return @{ Ok = $false; Why = "$Key ${Reference}: contains a control character" } }
    return $r
}

# One request of a store: @{ Ok; Body } on HTTP 200, else @{ Ok; Why } with
# Why starting with the prefix, and after any other HTTP status, the
# answer's Status and Body.
function Invoke-VigilStoreRequest {
    param($Keys, [string]$Prefix, [string]$Method, [string]$Url, [bool]$Metadata, [string[]]$Headers, [string]$Body)
    $hostPart = $Url.Substring($Url.IndexOf('://') + 3)
    $hostPart = $hostPart.Split('/')[0].Split('?')[0]
    $ca = if ($Metadata) { '' } else { $Keys.ca_file }
    $r = Invoke-VigilHttpSend -Timeout $Keys.timeout -Method $Method -Url $Url -CaFile $ca -Metadata $Metadata -Headers $Headers -Body $Body
    if (-not $r.Ok) {
        $why = switch ($r.Fail) {
            'resolve' { "cannot resolve $hostPart" }
            'connect' { "cannot connect to $hostPart" }
            'timeout' { "no answer from $hostPart within $($Keys.timeout)s" }
            'untrusted' { "the certificate of $hostPart is not trusted" }
            'tls' { "no secure connection to $hostPart" }
            'cafile' { "cannot read ca_file $($Keys.ca_file)" }
            default { "the request to $hostPart failed" }
        }
    }
    elseif ($r.Status -eq 200) { return @{ Ok = $true; Body = $r.Body } }
    elseif ($r.Status -eq 404) { $why = 'not found (HTTP 404)' }
    elseif ($r.Status -eq 401 -or $r.Status -eq 403) { $why = "permission denied (HTTP $($r.Status))" }
    else { $why = "HTTP $($r.Status) from $hostPart" }
    if ($r.Ok) { return @{ Ok = $false; Why = "$Prefix$why"; Status = $r.Status; Body = $r.Body } }
    return @{ Ok = $false; Why = "$Prefix$why" }
}

# The string at a path of an answer.
function Get-VigilStoreAnswer {
    param([string]$Prefix, [string]$Body, [string[]]$Path)
    $j = Get-VigilJsonString -Json $Body -Path $Path
    if (-not $j.Ok) { return @{ Ok = $false; Why = "${Prefix}unexpected answer: $($j.Why)" } }
    return $j
}

# HashiCorp Vault, KV version 2.
function Get-VigilVaultSecret {
    param([string]$Root, $Parsed, $Keys, [string]$Name)
    if ("/$Name/" -match '//|/\./|/\.\./') { return @{ Ok = $false; Why = 'not a valid secret path' } }
    $url = $Keys.url.TrimEnd('/')
    if ($Keys.auth -ceq 'token') {
        $token = Get-VigilStoreCredential $Root $Parsed 'token' $Keys.token
        if (-not $token.Ok) { return $token }
    }
    elseif ($Keys.auth -ceq 'approle') {
        $sid = Get-VigilStoreCredential $Root $Parsed 'secret_id' $Keys.secret_id
        if (-not $sid.Ok) { return $sid }
        $body = '{"role_id":' + (ConvertTo-VigilJsonQuoted $Keys.role_id) + ',"secret_id":' + (ConvertTo-VigilJsonQuoted $sid.Value) + '}'
        $sid = $null
        $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'POST' "$url/v1/auth/approle/login" $false @('Content-Type: application/json') $body
        $body = $null
        if (-not $r.Ok) { return $r }
        $token = Get-VigilStoreAnswer 'sign-in failed: ' $r.Body @('auth', 'client_token')
        if (-not $token.Ok) { return $token }
    }
    else { return @{ Ok = $false; Why = "the store needs 'auth'" } }
    $path = "$url/v1/$(ConvertTo-VigilPercent $Keys.mount -KeepSlash)/data/$(ConvertTo-VigilPercent $Name -KeepSlash)"
    $r = Invoke-VigilStoreRequest $Keys '' 'GET' $path $false @("X-Vault-Token: $($token.Value)") ''
    $token = $null
    if (-not $r.Ok) { return $r }
    $field = if ($Keys.field) { $Keys.field } else { 'value' }
    return Get-VigilStoreAnswer '' $r.Body @('data', 'data', $field)
}

# Azure Key Vault.
function Get-VigilKeyVaultSecret {
    param([string]$Root, $Parsed, $Keys, [string]$Name)
    if ($Name -cnotmatch '^[0-9A-Za-z-]+(/[0-9A-Za-z]+)?$') { return @{ Ok = $false; Why = 'not a valid Key Vault secret name' } }
    $vault = $Keys.vault.TrimEnd('/')
    # Tokens are for the vault's cloud: ops-kv.vault.azure.net is in
    # vault.azure.net.
    $hostName = $vault.Substring(8).Split('/')[0].Split(':')[0]
    $resource = if ($hostName -match '^[^.]*\.[^.]*\.') { $hostName.Substring($hostName.IndexOf('.') + 1) } else { $hostName }
    if ($Keys.auth -ceq 'managed_identity') {
        $imds = Get-VigilImdsBase
        $q ="api-version=2018-02-01&resource=$(ConvertTo-VigilPercent "https://$resource")"
        if ($Keys.client_id) { $q += "&client_id=$(ConvertTo-VigilPercent $Keys.client_id)" }
        $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'GET' "$imds/metadata/identity/oauth2/token?$q" $true @('Metadata: true') ''
    }
    elseif ($Keys.auth -ceq 'service_principal') {
        $cs = Get-VigilStoreCredential $Root $Parsed 'client_secret' $Keys.client_secret
        if (-not $cs.Ok) { return $cs }
        $body = "grant_type=client_credentials&client_id=$(ConvertTo-VigilPercent $Keys.client_id)" +
            "&client_secret=$(ConvertTo-VigilPercent $cs.Value)&scope=$(ConvertTo-VigilPercent "https://$resource/.default")"
        $cs = $null
        $url = "$($Keys.authority.TrimEnd('/'))/$(ConvertTo-VigilPercent $Keys.tenant_id)/oauth2/v2.0/token"
        $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'POST' $url $false @('Content-Type: application/x-www-form-urlencoded') $body
        $body = $null
    }
    else { return @{ Ok = $false; Why = "the store needs 'auth'" } }
    if (-not $r.Ok) { return $r }
    $token = Get-VigilStoreAnswer 'sign-in failed: ' $r.Body @('access_token')
    if (-not $token.Ok) { return $token }
    $r = Invoke-VigilStoreRequest $Keys '' 'GET' "$vault/secrets/${Name}?api-version=7.4" $false @("Authorization: Bearer $($token.Value)") ''
    $token = $null
    if (-not $r.Ok) { return $r }
    return Get-VigilStoreAnswer '' $r.Body @('value')
}

# --- AWS Signature Version 4 -------------------------------------------------

function ConvertTo-VigilHex {
    param([byte[]]$Bytes)
    return -join ($Bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-VigilSha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ConvertTo-VigilHex $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) }
    finally { $sha.Dispose() }
}

function Get-VigilHmac {
    param([byte[]]$Key, [string]$Message)
    $h = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $Key)
    try { return , $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Message)) }
    finally { $h.Dispose() }
}

<#
    The Authorization header of a request without a query string, signed with
    AWS Signature Version 4. Headers: "name:value", lower-case names, in
    order.
#>
function New-VigilAwsSignature {
    param([string]$Secret, [string]$KeyId, [string]$AmzDate, [string]$Region, [string]$Service,
        [string]$Method, [string]$Path, [string[]]$Headers, [string]$Payload)
    $date = $AmzDate.Substring(0, 8)
    $canon = -join ($Headers | ForEach-Object { "$_`n" })
    $signed = ($Headers | ForEach-Object { $_.Substring(0, $_.IndexOf(':')) }) -join ';'
    $request = "$Method`n$Path`n`n$canon`n$signed`n$(Get-VigilSha256Hex $Payload)"
    $scope = "$date/$Region/$Service/aws4_request"
    $k = Get-VigilHmac ([System.Text.Encoding]::UTF8.GetBytes("AWS4$Secret")) $date
    $k = Get-VigilHmac $k $Region
    $k = Get-VigilHmac $k $Service
    $k = Get-VigilHmac $k 'aws4_request'
    $sig = ConvertTo-VigilHex (Get-VigilHmac $k "AWS4-HMAC-SHA256`n$AmzDate`n$scope`n$(Get-VigilSha256Hex $request)")
    return "AWS4-HMAC-SHA256 Credential=$KeyId/$scope, SignedHeaders=$signed, Signature=$sig"
}

# The time a request is signed at. The conformance suite replaces it.
function Get-VigilAwsTime {
    return [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

# The instance metadata endpoint: 169.254.169.254, or for tests only,
# VIGIL_TEST_IMDS on 127.0.0.1 (spec 22.4.2).
function Get-VigilImdsBase {
    if ($env:VIGIL_TEST_IMDS -and $env:VIGIL_TEST_IMDS -cmatch '^http://127\.0\.0\.1:[0-9]+$') { return $env:VIGIL_TEST_IMDS }
    return 'http://169.254.169.254'
}

# AWS Secrets Manager.
function Get-VigilAwsSecret {
    param([string]$Root, $Parsed, $Keys, [string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9/_+=.@:-]+$') { return @{ Ok = $false; Why = 'not a valid Secrets Manager secret name' } }
    $session = ''
    if ($Keys.auth -ceq 'access_keys') {
        # The key ID is not secret: written as is, or as a reference.
        $akid = $Keys.access_key_id
        if ($akid -cmatch '^(env|secret):') {
            $r = Get-VigilStoreCredential $Root $Parsed 'access_key_id' $akid
            if (-not $r.Ok) { return $r }
            $akid = $r.Value
        }
        $r = Get-VigilStoreCredential $Root $Parsed 'secret_access_key' $Keys.secret_access_key
        if (-not $r.Ok) { return $r }
        $secret = $r.Value
    }
    elseif ($Keys.auth -ceq 'instance_profile') {
        # IMDSv2: a session token, the instance's role, its credentials.
        $imds = Get-VigilImdsBase
        $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'PUT' "$imds/latest/api/token" $true @('X-aws-ec2-metadata-token-ttl-seconds: 300') ''
        if (-not $r.Ok) { return $r }
        $md = @("X-aws-ec2-metadata-token: $($r.Body)")
        $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'GET' "$imds/latest/meta-data/iam/security-credentials/" $true $md ''
        if (-not $r.Ok) { return $r }
        $role = $r.Body.Split("`n")[0].TrimEnd("`r")
        if (-not $role) { return @{ Ok = $false; Why = 'sign-in failed: no IAM role on this instance' } }
        $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'GET' "$imds/latest/meta-data/iam/security-credentials/$(ConvertTo-VigilPercent $role)" $true $md ''
        $md = $null
        if (-not $r.Ok) { return $r }
        $got = @{}
        foreach ($k in @('AccessKeyId', 'SecretAccessKey', 'Token')) {
            $a = Get-VigilStoreAnswer 'sign-in failed: ' $r.Body @($k)
            if (-not $a.Ok) { return $a }
            $got[$k] = $a.Value
        }
        $akid = $got.AccessKeyId
        $secret = $got.SecretAccessKey
        $session = $got.Token
        $got = $null
        if ("$akid$secret$session" -match '[\x00-\x1f\x7f]') { return @{ Ok = $false; Why = 'sign-in failed: unexpected answer: a control character' } }
    }
    else { return @{ Ok = $false; Why = "the store needs 'auth'" } }
    $url = if ($Keys.endpoint) { $Keys.endpoint } else { "https://secretsmanager.$($Keys.region).amazonaws.com" }
    $url = $url.TrimEnd('/')
    $hostName = $url.Substring(8)
    if ($hostName.EndsWith(':443')) { $hostName = $hostName.Substring(0, $hostName.Length - 4) }
    $body = '{"SecretId":' + (ConvertTo-VigilJsonQuoted $Name) + '}'
    $now = Get-VigilAwsTime
    $sign = @('content-type:application/x-amz-json-1.1', "host:$hostName", "x-amz-date:$now")
    if ($session) { $sign += "x-amz-security-token:$session" }
    $sign += 'x-amz-target:secretsmanager.GetSecretValue'
    $auth = New-VigilAwsSignature $secret $akid $now $Keys.region 'secretsmanager' 'POST' '/' $sign $body
    $secret = $null
    $headers = @('Content-Type: application/x-amz-json-1.1', "X-Amz-Date: $now")
    if ($session) { $headers += "X-Amz-Security-Token: $session" }
    $headers += 'X-Amz-Target: secretsmanager.GetSecretValue'
    $headers += "Authorization: $auth"
    $session = $null
    $auth = $null
    $r = Invoke-VigilStoreRequest $Keys '' 'POST' "$url/" $false $headers $body
    $headers = $null
    if (-not $r.Ok) {
        # An error names its type: not found, or the credentials refused.
        if ($r.Body) {
            $t = Get-VigilJsonString -Json $r.Body -Path @('__type')
            if ($t.Ok) {
                $type = $t.Value.Substring($t.Value.LastIndexOf('#') + 1)
                if ($type -ceq 'ResourceNotFoundException') { return @{ Ok = $false; Why = "not found ($type)" } }
                if (@('AccessDeniedException', 'UnrecognizedClientException', 'InvalidSignatureException', 'IncompleteSignature',
                        'InvalidClientTokenId', 'SignatureDoesNotMatch', 'ExpiredTokenException') -ccontains $type) {
                    return @{ Ok = $false; Why = "permission denied ($type)" }
                }
                return @{ Ok = $false; Why = "$type (HTTP $($r.Status))" }
            }
        }
        return @{ Ok = $false; Why = $r.Why }
    }
    return Get-VigilAwsValue $Keys $r.Body
}

# The value in a GetSecretValue answer: its SecretString, or with field,
# one key of it stored as JSON.
function Get-VigilAwsValue {
    param($Keys, [string]$Body)
    $value = Get-VigilStoreAnswer '' $Body @('SecretString')
    if (-not $value.Ok -or -not $Keys.field) { return $value }
    $f = Get-VigilJsonString -Json $value.Value -Path @($Keys.field)
    if (-not $f.Ok) { return @{ Ok = $false; Why = "the secret's value: $($f.Why)" } }
    return $f
}

# --- GCP Secret Manager ------------------------------------------------------

function ConvertTo-VigilB64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# The time a sign-in is made at, in seconds since 1970. The conformance
# suite replaces it.
function Get-VigilEpoch {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# One DER element at the position: @{ Tag; Start; Len }.
function Read-VigilDer {
    param($S)
    $tag = $S.B[$S.P]
    $len = [int]$S.B[$S.P + 1]
    $S.P += 2
    if ($len -band 0x80) {
        $n = $len -band 0x7F
        $len = 0
        for ($i = 0; $i -lt $n; $i++) { $len = $len * 256 + $S.B[$S.P]; $S.P++ }
    }
    if ($S.P + $len -gt $S.B.Length) { throw 'truncated' }
    return @{ Tag = $tag; Start = $S.P; Len = $len }
}

<#
    An RSA private key from PEM: PKCS#8 (BEGIN PRIVATE KEY, as in Google's
    key files) or PKCS#1 (BEGIN RSA PRIVATE KEY). Read here because Windows
    PowerShell 5.1's .NET cannot import PEM. Returns RSAParameters, or $null.
#>
function ConvertFrom-VigilPemRsa {
    param([string]$Pem)
    $m = [regex]::Match($Pem, '-----BEGIN (RSA )?PRIVATE KEY-----([^-]*)-----END (RSA )?PRIVATE KEY-----')
    if (-not $m.Success) { return $null }
    try {
        $S = @{ B = [Convert]::FromBase64String(($m.Groups[2].Value -replace '\s', '')); P = 0 }
        $seq = Read-VigilDer $S
        if (-not $m.Groups[1].Success) {
            # PKCS#8: version, algorithm, then the PKCS#1 key in an OCTET STRING.
            $v = Read-VigilDer $S; $S.P = $v.Start + $v.Len
            $a = Read-VigilDer $S; $S.P = $a.Start + $a.Len
            $o = Read-VigilDer $S
            $seq = Read-VigilDer $S
        }
        $v = Read-VigilDer $S; $S.P = $v.Start + $v.Len
        $ints = @()
        for ($i = 0; $i -lt 8; $i++) {
            $e = Read-VigilDer $S
            $b = New-Object byte[] $e.Len
            [Array]::Copy($S.B, $e.Start, $b, 0, $e.Len)
            $S.P = $e.Start + $e.Len
            $skip = 0
            while ($skip -lt $b.Length - 1 -and $b[$skip] -eq 0) { $skip++ }
            $ints += , ($b[$skip..($b.Length - 1)])
        }
        # .NET wants D the modulus' length and the CRT values half of it.
        $pad = {
            param([byte[]]$x, [int]$n)
            if ($x.Length -ge $n) { return , $x }
            $r = New-Object byte[] $n
            [Array]::Copy($x, 0, $r, $n - $x.Length, $x.Length)
            return , $r
        }
        $n = $ints[0].Length
        $h = [int][Math]::Ceiling($n / 2)
        $p = New-Object System.Security.Cryptography.RSAParameters
        $p.Modulus = [byte[]]$ints[0]
        $p.Exponent = [byte[]]$ints[1]
        $p.D = & $pad $ints[2] $n
        $p.P = & $pad $ints[3] $h
        $p.Q = & $pad $ints[4] $h
        $p.DP = & $pad $ints[5] $h
        $p.DQ = & $pad $ints[6] $h
        $p.InverseQ = & $pad $ints[7] $h
        return $p
    }
    catch { return $null }
}

# A Google access token from a service account key (the reference to its
# JSON key file's contents): a JWT signed RS256, exchanged at its token_uri.
function Get-VigilGcpSaToken {
    param([string]$Root, $Parsed, $Keys)
    $ref = $Keys.service_account_key
    $key = Get-VigilStoreCredential $Root $Parsed 'service_account_key' $ref
    if (-not $key.Ok) { return $key }
    $got = @{}
    foreach ($k in @('client_email', 'private_key')) {
        $j = Get-VigilJsonString -Json $key.Value -Path @($k)
        if (-not $j.Ok) { return @{ Ok = $false; Why = "service_account_key ${ref}: not a service account key ($($j.Why))" } }
        $got[$k] = $j.Value
    }
    $uri = 'https://oauth2.googleapis.com/token'
    $j = Get-VigilJsonString -Json $key.Value -Path @('token_uri')
    if ($j.Ok) { $uri = $j.Value }
    $key = $null
    if (-not $uri.StartsWith('https://', [System.StringComparison]::Ordinal)) {
        return @{ Ok = $false; Why = "service_account_key ${ref}: its token_uri is not https" }
    }
    $params = ConvertFrom-VigilPemRsa $got.private_key
    $got.private_key = $null
    if ($null -eq $params) { return @{ Ok = $false; Why = "service_account_key ${ref}: its private_key cannot sign" } }
    $now = Get-VigilEpoch
    $utf8 = [System.Text.Encoding]::UTF8
    $signing = (ConvertTo-VigilB64Url $utf8.GetBytes('{"alg":"RS256","typ":"JWT"}')) + '.' + (ConvertTo-VigilB64Url $utf8.GetBytes(
            '{"iss":' + (ConvertTo-VigilJsonQuoted $got.client_email) + ',"scope":"https://www.googleapis.com/auth/cloud-platform","aud":' +
            (ConvertTo-VigilJsonQuoted $uri) + ',"iat":' + $now + ',"exp":' + ($now + 3600) + '}'))
    $rsa = if ($PSVersionTable.PSEdition -ceq 'Core') { [System.Security.Cryptography.RSA]::Create() } else { New-Object System.Security.Cryptography.RSACng }
    try {
        $rsa.ImportParameters($params)
        $sig = $rsa.SignData($utf8.GetBytes($signing), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    catch { return @{ Ok = $false; Why = "service_account_key ${ref}: its private_key cannot sign" } }
    finally { $rsa.Dispose(); $params = $null }
    $body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=$signing.$(ConvertTo-VigilB64Url $sig)"
    $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'POST' $uri $false @('Content-Type: application/x-www-form-urlencoded') $body
    if (-not $r.Ok) { return $r }
    return Get-VigilStoreAnswer 'sign-in failed: ' $r.Body @('access_token')
}

# A Secret Manager name, NAME or NAME/<version>: @{ Ok; Name; Version }.
function Split-VigilGcpName {
    param([string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9_-]+(/([0-9]+|latest))?$') { return @{ Ok = $false; Why = 'not a valid Secret Manager secret name' } }
    if (-not $Name.Contains('/')) { return @{ Ok = $true; Name = $Name; Version = 'latest' } }
    return @{ Ok = $true; Name = $Name.Substring(0, $Name.IndexOf('/')); Version = $Name.Substring($Name.IndexOf('/') + 1) }
}

# The value in an access answer: its payload, decoded from base64, exactly
# as stored. The API answers in standard base64, gcloud in its URL-safe
# form; both are read.
function Get-VigilGcpPayload {
    param([string]$Body)
    $data = Get-VigilStoreAnswer '' $Body @('payload', 'data')
    if (-not $data.Ok) { return $data }
    if ($data.Value -cnotmatch '^[A-Za-z0-9+/_-]*={0,2}$') { return @{ Ok = $false; Why = 'unexpected answer: payload.data is not base64' } }
    $b64 = $data.Value.Replace('-', '+').Replace('_', '/')
    while ($b64.Length % 4) { $b64 += '=' }
    try { return @{ Ok = $true; Value = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) } }
    catch { return @{ Ok = $false; Why = 'unexpected answer: payload.data is not base64' } }
}

# GCP Secret Manager.
function Get-VigilGcpSecret {
    param([string]$Root, $Parsed, $Keys, [string]$Name)
    $n = Split-VigilGcpName $Name
    if (-not $n.Ok) { return $n }
    $Name = $n.Name
    $version = $n.Version
    if ($Keys.auth -ceq 'metadata') {
        $r = Invoke-VigilStoreRequest $Keys 'sign-in failed: ' 'GET' "$(Get-VigilImdsBase)/computeMetadata/v1/instance/service-accounts/default/token" $true @('Metadata-Flavor: Google') ''
        if (-not $r.Ok) { return $r }
        $token = Get-VigilStoreAnswer 'sign-in failed: ' $r.Body @('access_token')
    }
    elseif ($Keys.auth -ceq 'service_account_key') { $token = Get-VigilGcpSaToken $Root $Parsed $Keys }
    else { return @{ Ok = $false; Why = "the store needs 'auth'" } }
    if (-not $token.Ok) { return $token }
    $url = if ($Keys.endpoint) { $Keys.endpoint.TrimEnd('/') } else { 'https://secretmanager.googleapis.com' }
    $r = Invoke-VigilStoreRequest $Keys '' 'GET' "$url/v1/projects/$(ConvertTo-VigilPercent $Keys.project)/secrets/$Name/versions/${version}:access" $false @("Authorization: Bearer $($token.Value)") ''
    $token = $null
    if (-not $r.Ok) { return $r }
    return Get-VigilGcpPayload $r.Body
}

# --- The vendor CLIs ---------------------------------------------------------

# Whether a command is installed. The conformance suite replaces it.
function Test-VigilCliFound {
    param([string]$Name)
    return $null -ne (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
}

<#
    Runs a vendor CLI directly, with no input, within the timeout, with Env
    ("NAME=value" each) added to its environment, never its command line.
    Returns @{ Out; Rc; Stopped }, Stopped true when it had to be stopped
    (exit codes alone cannot tell: aws exits 254). The conformance suite
    replaces it. A .cmd or .bat CLI (az and gcloud are) runs through cmd.exe,
    which interprets some characters even inside quotes: an argument with
    one is refused, Rc -1.
#>
function Invoke-VigilCliRun {
    param([int]$Timeout, [string]$Command, [string[]]$Arguments, [string[]]$Env)
    $path = (Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($path -match '\.(cmd|bat)$' -and @($Arguments | Where-Object { $_ -match '["%^&|<>!]' }).Count -gt 0) { return @{ Out = ''; Rc = -1; Stopped = $false } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $path
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-VigilQuotedArg -Arg $_ -Always $false }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($e in $Env) {
        $i = $e.IndexOf('=')
        $psi.EnvironmentVariables[$e.Substring(0, $i)] = $e.Substring($i + 1)
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() }
    catch { return @{ Out = ''; Rc = 127; Stopped = $false } }
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Timeout * 1000)) {
        try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch { }
        return @{ Out = ''; Rc = 1; Stopped = $true }
    }
    $p.WaitForExit()
    [void]$errTask.Result
    return @{ Out = $outTask.Result; Rc = $p.ExitCode; Stopped = $false }
}

# Runs the store's CLI: @{ Ok; Body } with its JSON answer, or @{ Ok; Why }.
function Invoke-VigilStoreCli {
    param($Keys, [string]$Cli, [string[]]$Arguments, [string[]]$Env)
    $r = Invoke-VigilCliRun -Timeout $Keys.timeout -Command $Cli -Arguments $Arguments -Env $Env
    if ($r.Rc -eq -1) { return @{ Ok = $false; Why = "an argument for the $Cli CLI has a character cmd.exe would interpret" } }
    if ($r.Stopped) { return @{ Ok = $false; Why = "the $Cli CLI was stopped after $($Keys.timeout)s" } }
    if ($r.Rc -ne 0) { return @{ Ok = $false; Why = "the $Cli CLI failed (exit code $($r.Rc))" } }
    return @{ Ok = $true; Body = $r.Out }
}

# Which client a store uses (6.5.3): @{ Client (cli or http); Cli; Why }.
function Get-VigilStoreClient {
    param($Keys, [string]$Type)
    $cli = switch -CaseSensitive ($Type) { 'azure_keyvault' { 'az' } 'aws_secrets_manager' { 'aws' } 'gcp_secret_manager' { 'gcloud' } default { '' } }
    if (-not $cli) { return @{ Client = 'http'; Cli = ''; Why = '' } }
    if ($Keys.client -ceq 'cli' -or $Keys.client -ceq 'http') { return @{ Client = $Keys.client; Cli = $cli; Why = "client = $($Keys.client)" } }
    # auto: the CLI when it is installed and can sign in that way.
    if (@('azure_keyvault:service_principal', 'gcp_secret_manager:service_account_key') -ccontains "${Type}:$($Keys.auth)") {
        return @{ Client = 'http'; Cli = $cli; Why = "client = auto; $cli cannot sign in with auth = $($Keys.auth)" }
    }
    if (Test-VigilCliFound $cli) { return @{ Client = 'cli'; Cli = $cli; Why = 'client = auto' } }
    return @{ Client = 'http'; Cli = $cli; Why = "client = auto; $cli is not installed" }
}

# Azure Key Vault with az, signed in as the service account
# (az login --identity).
function Get-VigilCliKeyVaultSecret {
    param([string]$Root, $Parsed, $Keys, [string]$Name)
    if ($Name -cnotmatch '^[0-9A-Za-z-]+(/[0-9A-Za-z]+)?$') { return @{ Ok = $false; Why = 'not a valid Key Vault secret name' } }
    $cenv = @()
    if ($Keys.ca_file) { $cenv = @("REQUESTS_CA_BUNDLE=$($Keys.ca_file)") }
    $r = Invoke-VigilStoreCli $Keys 'az' @('keyvault', 'secret', 'show', '--id', "$($Keys.vault.TrimEnd('/'))/secrets/$Name", '--output', 'json') $cenv
    if (-not $r.Ok) { return $r }
    return Get-VigilStoreAnswer '' $r.Body @('value')
}

# AWS Secrets Manager with aws. Access keys reach it in its environment.
function Get-VigilCliAwsSecret {
    param([string]$Root, $Parsed, $Keys, [string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9/_+=.@:-]+$') { return @{ Ok = $false; Why = 'not a valid Secrets Manager secret name' } }
    $cenv = @()
    if ($Keys.auth -ceq 'access_keys') {
        $akid = $Keys.access_key_id
        if ($akid -cmatch '^(env|secret):') {
            $r = Get-VigilStoreCredential $Root $Parsed 'access_key_id' $akid
            if (-not $r.Ok) { return $r }
            $akid = $r.Value
        }
        $r = Get-VigilStoreCredential $Root $Parsed 'secret_access_key' $Keys.secret_access_key
        if (-not $r.Ok) { return $r }
        $cenv = @("AWS_ACCESS_KEY_ID=$akid", "AWS_SECRET_ACCESS_KEY=$($r.Value)")
    }
    $a = @('secretsmanager', 'get-secret-value', '--secret-id', $Name, '--region', $Keys.region, '--output', 'json')
    if ($Keys.endpoint) { $a += @('--endpoint-url', $Keys.endpoint) }
    if ($Keys.ca_file) { $a += @('--ca-bundle', $Keys.ca_file) }
    $r = Invoke-VigilStoreCli $Keys 'aws' $a $cenv
    $cenv = $null
    if (-not $r.Ok) { return $r }
    return Get-VigilAwsValue $Keys $r.Body
}

# GCP Secret Manager with gcloud, as the instance's service account.
function Get-VigilCliGcpSecret {
    param([string]$Root, $Parsed, $Keys, [string]$Name)
    $n = Split-VigilGcpName $Name
    if (-not $n.Ok) { return $n }
    $cenv = @('CLOUDSDK_CORE_DISABLE_PROMPTS=1')
    if ($Keys.endpoint) { $cenv += "CLOUDSDK_API_ENDPOINT_OVERRIDES_SECRETMANAGER=$($Keys.endpoint.TrimEnd('/'))/" }
    if ($Keys.ca_file) { $cenv += "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE=$($Keys.ca_file)" }
    $r = Invoke-VigilStoreCli $Keys 'gcloud' @('secrets', 'versions', 'access', $n.Version, "--secret=$($n.Name)", "--project=$($Keys.project)", '--format=json') $cenv
    if (-not $r.Ok) { return $r }
    return Get-VigilGcpPayload $r.Body
}

# For vigil precheck: which client a store uses and why. @{ Ok; Text }, Ok
# false when client = cli and the CLI is not installed.
function Get-VigilStoreClientReport {
    param([string]$Root, $Parsed, [string]$Store, [string]$Type)
    $c = Get-VigilStoreClient (Get-VigilStoreKeys $Root $Parsed $Store) $Type
    if ($c.Client -ceq 'cli') {
        if (-not (Test-VigilCliFound $c.Cli)) { return @{ Ok = $false; Text = "client = cli, but $($c.Cli) is not installed" } }
        return @{ Ok = $true; Text = "uses the $($c.Cli) CLI ($($c.Why))" }
    }
    return @{ Ok = $true; Text = "uses Vigil's own HTTPS client ($($c.Why))" }
}

function Get-VigilStoreSecret {
    param([string]$Root, $Parsed, [string]$Store, [string]$Type, [string]$Name)
    $keys = Get-VigilStoreKeys $Root $Parsed $Store
    $c = Get-VigilStoreClient $keys $Type
    if ($c.Client -ceq 'cli') {
        if (-not (Test-VigilCliFound $c.Cli)) { return @{ Ok = $false; Why = "the $($c.Cli) CLI is not installed (client = cli)" } }
        if ($Type -ceq 'azure_keyvault') { return Get-VigilCliKeyVaultSecret $Root $Parsed $keys $Name }
        if ($Type -ceq 'aws_secrets_manager') { return Get-VigilCliAwsSecret $Root $Parsed $keys $Name }
        return Get-VigilCliGcpSecret $Root $Parsed $keys $Name
    }
    if ($Type -ceq 'hashicorp_vault') { return Get-VigilVaultSecret $Root $Parsed $keys $Name }
    if ($Type -ceq 'aws_secrets_manager') { return Get-VigilAwsSecret $Root $Parsed $keys $Name }
    if ($Type -ceq 'gcp_secret_manager') { return Get-VigilGcpSecret $Root $Parsed $keys $Name }
    return Get-VigilKeyVaultSecret $Root $Parsed $keys $Name
}
