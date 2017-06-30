# Continously test response time of various variants of a webapp using
# integrated Windows authentication.
#
# Anders Nordby <anders.nordby@fupp.net>, 2017-06-23

Param(
    [string]$env,
    [bool]$direct = 0,
    [int]$iterations = 3
)

function usage {
    write-host "Usage: ckfooapp.ps1 <dev|test|staging|prod>"
    exit 1
}

function stats ($attempts, $mstotal, $responses) {
    $ms_avg = [math]::Round($mstotal/$attempts, 2)
    if ($attempts -gt 40) {
        write-host
        write-host "env=$($global:env) url=$($global:url) iterations=$($global:iterations) direct=$($global:direct)"
    }
    write-host "Statistics:"
    write-host "$attempts attempts, $ms_avg ms average response time."
    write-host "Responses (990=timeout):"
    $rtxt = $responses | out-string
    write-host $rtxt
    exit 0
}

switch ($env) {
    "staging" {
        if ($direct -eq 1) {
            $url = "http://fooapp-test0.barcompany.com/FooApp"
        } else {
            $url = "https://fooapp-test.barcompany.com/FooApp"
        }
    }
    "prod" {
            if ($direct -eq 1) {
                $url = "http://fooapp0.barcompany.com/FooApp"
            } else {
                $url = "https://fooapp.barcompany.com/FooApp"
            }
    }
    "dev" {
            if ($direct -eq 1) {
                $url = "http://fooapp-dev0.barcompany.com/FooApp"
            } else {
                $url = "https://fooapp-dev.barcompany.com/FooApp"
            }
    }
    "test" {
            if ($direct -eq 1) {
                $url = "http://fooapp-tester0.barcompany.com/FooApp"
            } else {
                $url = "https://fooapp-tester.barcompany.com/FooApp"
            }
    }
    default {
        usage
    }
}

if ($direct -eq 1) {
    $headers = @{
        "X-UserName" = "b050ann"
    }
} else {
    $headers = @{}
}

write-host "env=$env url=$url iterations=$iterations direct=$direct"
$global:env = $env
$global:url = $url
$global:iterations = $iterations
$global:direct = $direct

#exit 0
$ckstring = "<title>Foo App</title>"
$timeout = 5
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

    $match = 0
    if ($StatusCode -eq 200) {
#        write-host "Lastet fooapp OK? Ja. SC=$StatusCode"
        if ($content -match $ckstring) {
            $match = 1
        }
    }
    write-host "StatusCode=$StatusCode ContentMatch=$match RespTime=$spentms"

    if ($i -le $iterations) {
        Start-Sleep -s 1
    }
    if (([console]::KeyAvailable) -or ($i -ge $iterations -and $i -gt 1)) {
        stats $i $totaltime $responses
    }
    $i++
}
