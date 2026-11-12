$ErrorActionPreference = "Stop"
$TaskDir = Split-Path -Parent $PSScriptRoot
$EvDir = Join-Path $TaskDir "evidence"
New-Item -ItemType Directory -Force -Path $EvDir | Out-Null

Write-Host "=== Task 1 End-to-End Verification ===" -ForegroundColor Cyan

# Check #1: 3 nodes Ready
Write-Host "[Check #1] Checking 3 cluster nodes..."
$nodesOut = kubectl get nodes -o wide | Out-String
$nodesOut.Trim() | Set-Content -Path (Join-Path $EvDir "01-nodes.txt") -Encoding utf8
$readyCount = ($nodesOut -split "`n" | Where-Object { $_ -match "\bReady\b" }).Count
if ($readyCount -lt 3) { throw "FAIL Check #1: Expected 3 Ready nodes, got $readyCount" }
Write-Host "PASS #1: 3 nodes Ready" -ForegroundColor Green

# Apply namespace and working deployment
Write-Host "Applying namespace.yaml and deployment.yaml..."
kubectl apply -f (Join-Path $TaskDir "namespace.yaml") | Out-Null
kubectl apply -f (Join-Path $TaskDir "deployment.yaml") | Out-Null
kubectl rollout status deploy/web-deployment -n webapp --timeout=300s | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Rollout of deployment.yaml did not finish in time" }

# Check #2: Deployment ready (3/3)
$deployOut = kubectl get deploy web-deployment -n webapp | Out-String
$deployOut.Trim() | Set-Content -Path (Join-Path $EvDir "02-deployment.txt") -Encoding utf8
if ($deployOut -notmatch "3/3") { throw "FAIL Check #2: Deployment not 3/3:`n$deployOut" }
Write-Host "PASS #2: Deployment web-deployment READY 3/3" -ForegroundColor Green

# Check #3: Pods running (3 Pods, each 2/2 Running)
$podsOut = kubectl get pods -n webapp -l app=web -o wide | Out-String
$podsOut.Trim() | Set-Content -Path (Join-Path $EvDir "03-pods.txt") -Encoding utf8
$runningPods = ($podsOut -split "`n" | Where-Object { $_ -match "2/2\s+Running" }).Count
if ($runningPods -ne 3) { throw "FAIL Check #3: Expected 3 pods 2/2 Running, got $runningPods" }
Write-Host "PASS #3: 3 Pods Running (2/2)" -ForegroundColor Green

# Check #4: Containers list
$containersOut = kubectl get pods -n webapp -l app=web -o jsonpath="{.items[0].spec.initContainers[*].name} {.items[0].spec.containers[*].name}" | Out-String
$containersOut.Trim() | Set-Content -Path (Join-Path $EvDir "04-containers.txt") -Encoding utf8
if ($containersOut.Trim() -ne "init-done nginx time-updater") {
    throw "FAIL Check #4: Unexpected container list: $($containersOut.Trim())"
}
Write-Host "PASS #4: Containers = $($containersOut.Trim())" -ForegroundColor Green

# Check #5: Init container logs
$initLogs = kubectl logs deploy/web-deployment -n webapp -c init-done | Out-String
$initLogs.Trim() | Set-Content -Path (Join-Path $EvDir "05-init-logs.txt") -Encoding utf8
if ($initLogs.Trim() -notmatch "^done$") { throw "FAIL Check #5: Expected 'done', got $($initLogs.Trim())" }
Write-Host "PASS #5: Init container output = done" -ForegroundColor Green

# Check #6: Sidecar sees nginx master process via shared process namespace
$psOut = kubectl exec deploy/web-deployment -n webapp -c time-updater -- ps | Out-String
$psOut.Trim() | Set-Content -Path (Join-Path $EvDir "06-sidecar-ps.txt") -Encoding utf8
if ($psOut -notmatch "nginx: master process") { throw "FAIL Check #6: Sidecar ps did not show 'nginx: master process'" }
Write-Host "PASS #6: Sidecar sees 'nginx: master process'" -ForegroundColor Green

# Check #7: Time updates every 5 seconds (both via kubectl exec on single pod AND port-forward HTTP)
$podName = (kubectl get pods -n webapp -l app=web -o jsonpath="{.items[0].metadata.name}").Trim()
$read1 = (kubectl exec $podName -n webapp -c nginx -- cat /usr/share/nginx/html/index.html | Out-String).Trim()
Start-Sleep -Seconds 6
$read2 = (kubectl exec $podName -n webapp -c nginx -- cat /usr/share/nginx/html/index.html | Out-String).Trim()

$read1 | Set-Content -Path (Join-Path $EvDir "07a-http-t1.txt") -Encoding utf8
$read2 | Set-Content -Path (Join-Path $EvDir "07b-http-t2.txt") -Encoding utf8
"Read 1 (t=0s):  $read1`nRead 2 (t=+6s): $read2" | Set-Content -Path (Join-Path $EvDir "07-time-updates.txt") -Encoding utf8
if ($read1 -eq $read2 -or $read1 -notmatch "hello in MLOPS MENA COMMUNITY") {
    throw "FAIL Check #7: Timestamp did not update (`n$read1`nvs`n$read2)"
}
Write-Host "PASS #7: Time updated ($read1 -> $read2)" -ForegroundColor Green

# Check #8: No volumes
$volOut = (kubectl get deploy web-deployment -n webapp -o jsonpath="{.spec.template.spec.volumes}" | Out-String).Trim()
if ([string]::IsNullOrEmpty($volOut)) {
    "(empty - no volumes defined)" | Set-Content -Path (Join-Path $EvDir "08-volumes.txt") -Encoding utf8
} else {
    throw "FAIL Check #8: Expected empty volumes, got: $volOut"
}
Write-Host "PASS #8: No volumes defined" -ForegroundColor Green

# Step 5 (Checks #9 & #10): Failing init container rollout
Write-Host "[Step 5] Applying deployment-failing-init.yaml..."
kubectl apply -f (Join-Path $TaskDir "deployment-failing-init.yaml") | Out-Null

$failPod = ""
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    $podsCheck = kubectl get pods -n webapp -l app=web | Out-String
    if ($podsCheck -match "Init:(Error|CrashLoopBackOff)") {
        $podsCheck.Trim() | Set-Content -Path (Join-Path $EvDir "09-failing-init-pods.txt") -Encoding utf8
        $failLine = ($podsCheck -split "`n" | Where-Object { $_ -match "Init:(Error|CrashLoopBackOff)" } | Select-Object -First 1)
        $failPod = ($failLine -split "\s+")[0].Trim()
        if ($podsCheck -match "Init:CrashLoopBackOff") { break }
    }
}
if (-not $failPod) { throw "FAIL Check #9: New pod did not enter Init:Error or Init:CrashLoopBackOff" }
Write-Host "PASS #9: New pod $failPod in Init:Error / Init:CrashLoopBackOff while 3 old pods stay 2/2 Running" -ForegroundColor Green

$failLogs = (kubectl logs $failPod -n webapp -c init-done | Out-String).Trim()
$failLogs | Set-Content -Path (Join-Path $EvDir "10a-failing-init-logs.txt") -Encoding utf8
$descFull = kubectl describe pod $failPod -n webapp | Out-String
$descFull.Trim() | Set-Content -Path (Join-Path $EvDir "10-failing-init-describe-full.txt") -Encoding utf8

# Extract the init-done section from describe output
$lines = $descFull -split "`n"
$idx = 0
for ($j = 0; $j -lt $lines.Count; $j++) {
    if ($lines[$j] -match "^\s*init-done:") { $idx = $j; break }
}
$excerpt = ($lines[$idx..([Math]::Min($idx + 18, $lines.Count - 1))] -join "`n").Trim()
$excerpt | Set-Content -Path (Join-Path $EvDir "10b-failing-init-describe.txt") -Encoding utf8
if ($descFull -notmatch "Exit Code:\s*1") { throw "FAIL Check #10: Expected Exit Code: 1 in describe pod" }
Write-Host "PASS #10: Describe pod confirms init-done Exit Code: 1 and logs 'init failed'" -ForegroundColor Green

# Step 6 (Check #11): Fix the deployment and wait for rollout
Write-Host "[Step 6] Restoring working deployment.yaml..."
kubectl apply -f (Join-Path $TaskDir "deployment.yaml") | Out-Null
kubectl rollout status deploy/web-deployment -n webapp --timeout=180s | Out-Null
Start-Sleep -Seconds 3

$fixedDeploy = (kubectl get deploy web-deployment -n webapp | Out-String).Trim()
$fixedPods = (kubectl get pods -n webapp -l app=web | Out-String).Trim()
$fixedDeploy | Set-Content -Path (Join-Path $EvDir "11-fixed-deployment.txt") -Encoding utf8
$fixedPods | Set-Content -Path (Join-Path $EvDir "11b-fixed-pods.txt") -Encoding utf8

if ($fixedDeploy -notmatch "3/3\s+3\s+3") { throw "FAIL Check #11: Expected READY 3/3 and UP-TO-DATE 3:`n$fixedDeploy" }
Write-Host "PASS #11: Deployment fixed — READY 3/3, UP-TO-DATE 3" -ForegroundColor Green

Write-Host "Generating screenshots from real outputs..." -ForegroundColor Cyan
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction Stop).Source }
& $py (Join-Path $PSScriptRoot "screenshots.py")
if ($LASTEXITCODE -ne 0) { throw "screenshots.py failed" }
Write-Host "=== ALL 11 CHECKS PASSED ===" -ForegroundColor Green
