# PowerShell URL tester
# Continously test response time using integrated Windows authentication.
# Anders Nordby <anders.nordby@fupp.net>, 2017-06-23

Param(
    [string]$url,
    [int]$iterations = 3
)

function usage {
    write-host "Usage: ckurl.ps1 <url> [<iterations>]"
    exit 1
}

function stats ($attempts, $mstotal, $responses) {
    $ms_avg = [math]::Round($mstotal/$attempts, 2)
    if ($attempts -gt 40) {
        write-host
        write-host "url=$($global:url) iterations=$($global:iterations)"
    }
    write-host "Statistics:"
    write-host "$attempts attempts, $ms_avg ms average response time."
    write-host "Responses (990=timeout):"
    $rtxt = $responses | out-string
    write-host $rtxt
    exit 0
}

if ([string]::IsNullOrEmpty($url)) {
    usage
}
$headers = @{
    "X-UserName" = "b050ann"
    "Username" = "b050ann"
}
#    $headers = @{}

write-host "url=$url iterations=$iterations"

# Avoid problems with protocols not supported by default
#[Net.ServicePointManager]::SecurityProtocol = "Tls12, Tls11, Tls, Ssl3"
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"
$global:url = $url
$global:iterations = $iterations

#exit 0
$timeout = 50
$responses = @{}

$i = 1
$endloop = 0
$totaltime = 0
while ($i -le $iterations) {
    $starttime = (Get-Date)

    Try {
        $request = Invoke-WebRequest -uri $url -UseDefaultCredentials -Method Get -UseBasicParsing -ErrorAction Stop -TimeoutSec $timeout -Headers $headers
        $StatusCode = [int]$request.StatusCode
        $content = $request.Content
    } Catch {
        $ErrorMessage = $_.Exception.Message
        $Response = $_.Exception.Response
        $StatusCode = [int]$Response.StatusCode
        $SCType = $StatusCode.GetType()
        if ($StatusCode -eq 0) {
            if ($ErrorMessage -match "The operation has timed out") {
                $StatusCode=990
            } else {
                write-host "Unknown error:"
                write-host "Error: $ErrorMessage"
                write-host "Response: $Response"
                write-host "StatusCode: $StatusCode"
            }
        }
    }
    $endtime = (Get-Date)
    $spentms = ($endtime - $starttime).TotalMilliseconds
    $totaltime = $totaltime + $spentms
    if ($responses.containsKey($StatusCode)) {
        $responses[$StatusCode]++
    } else {
        $responses[$StatusCode] = 1
    }

    write-host "StatusCode=$StatusCode RespTime=$spentms"

    if ($i -le $iterations) {
        Start-Sleep -s 1
    }
    if (([console]::KeyAvailable) -or ($i -ge $iterations -and $i -gt 1)) {
        stats $i $totaltime $responses
    }
    $i++
}
