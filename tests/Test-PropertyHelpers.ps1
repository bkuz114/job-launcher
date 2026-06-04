# Test-PropertyHelpers.ps1
# Self-contained test script for JobLauncher.ps1 functions

Write-Host "Loading functions from JobLauncher.ps1..." -ForegroundColor Cyan

# Dot-source JobLauncher.ps1 from parent directory
$scriptRoot = Split-Path $PSScriptRoot -Parent
$jobLauncherPath = Join-Path $scriptRoot "JobLauncher.ps1"
. $jobLauncherPath

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Testing Get-PSObjectProperty"
Write-Host "========================================`n" -ForegroundColor Cyan

# Create test object
$testObject = [PSCustomObject]@{
    FirstName = "Ivan"
    LastName = "Kozlov"
    Department = "Engineering"
    EmployeeId = 12345
}

Write-Host "Test object created with properties: FirstName, LastName, Department, EmployeeId`n" -ForegroundColor Gray

# Test 1: Existing property
Write-Host "TEST 1: Existing property" -ForegroundColor Yellow
$result = Get-PSObjectProperty -Object $testObject -Property "FirstName"
Write-Host "  Get-PSObjectProperty -Object `$testObject -Property 'FirstName'" -ForegroundColor Gray
Write-Host "  Result: $result" -ForegroundColor Green
Write-Host "  Expected: Boris" -ForegroundColor Green
Write-Host ""

# Test 2: Missing property with default
Write-Host "TEST 2: Missing property with default value" -ForegroundColor Yellow
$result = Get-PSObjectProperty -Object $testObject -Property "MiddleName" -Default "N/A"
Write-Host "  Get-PSObjectProperty -Object `$testObject -Property 'MiddleName' -Default 'N/A'" -ForegroundColor Gray
Write-Host "  Result: $result" -ForegroundColor Green
Write-Host "  Expected: N/A" -ForegroundColor Green
Write-Host ""

# Test 3: Missing property without default (should return $null)
Write-Host "TEST 3: Missing property without default" -ForegroundColor Yellow
$result = Get-PSObjectProperty -Object $testObject -Property "MiddleName"
Write-Host "  Get-PSObjectProperty -Object `$testObject -Property 'MiddleName'" -ForegroundColor Gray
if ($result -eq $null) {
    Write-Host "  Result: `$null" -ForegroundColor Green
} else {
    Write-Host "  Result: $result" -ForegroundColor Red
}
Write-Host "  Expected: `$null" -ForegroundColor Green
Write-Host ""

# Test 4: FailIfMissing with existing property (should not throw)
Write-Host "TEST 4: FailIfMissing with existing property" -ForegroundColor Yellow
try {
    $result = Get-PSObjectProperty -Object $testObject -Property "LastName" -FailIfMissing
    Write-Host "  Get-PSObjectProperty -Object `$testObject -Property 'LastName' -FailIfMissing" -ForegroundColor Gray
    Write-Host "  Result: $result (no error thrown)" -ForegroundColor Green
    Write-Host "  Expected: Kuznetzov" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
    Write-Host "  Expected: No error" -ForegroundColor Red
}
Write-Host ""

# Test 5: FailIfMissing with missing property (should throw)
Write-Host "TEST 5: FailIfMissing with missing property" -ForegroundColor Yellow
try {
    $result = Get-PSObjectProperty -Object $testObject -Property "MissingProperty" -FailIfMissing -ErrorContext "TestScript"
    Write-Host "  Get-PSObjectProperty -Object `$testObject -Property 'MissingProperty' -FailIfMissing -ErrorContext 'TestScript'" -ForegroundColor Gray
    Write-Host "  Result: ERROR SHOULD HAVE BEEN THROWN" -ForegroundColor Red
} catch {
    Write-Host "  Get-PSObjectProperty -Object `$testObject -Property 'MissingProperty' -FailIfMissing -ErrorContext 'TestScript'" -ForegroundColor Gray
    Write-Host "  Caught error: $($_.Exception.Message)" -ForegroundColor Green
    Write-Host "  Expected: Error containing 'MissingProperty' and 'TestScript'" -ForegroundColor Green
}
Write-Host ""

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Testing Get-HashTableProperty"
Write-Host "========================================`n" -ForegroundColor Cyan

# Create test hashtable
$testHashtable = @{
    ServerName = "SQL01"
    Database = "Production"
    Port = 1433
    Timeout = 30
}

Write-Host "Test hashtable created with keys: ServerName, Database, Port, Timeout`n" -ForegroundColor Gray

# Test 6: Existing key
Write-Host "TEST 6: Existing key" -ForegroundColor Yellow
$result = Get-HashTableProperty -Hashtable $testHashtable -Key "ServerName"
Write-Host "  Get-HashTableProperty -Hashtable `$testHashtable -Key 'ServerName'" -ForegroundColor Gray
Write-Host "  Result: $result" -ForegroundColor Green
Write-Host "  Expected: SQL01" -ForegroundColor Green
Write-Host ""

# Test 7: Missing key with default
Write-Host "TEST 7: Missing key with default value" -ForegroundColor Yellow
$result = Get-HashTableProperty -Hashtable $testHashtable -Key "MaxConnections" -Default 100
Write-Host "  Get-HashTableProperty -Hashtable `$testHashtable -Key 'MaxConnections' -Default 100" -ForegroundColor Gray
Write-Host "  Result: $result" -ForegroundColor Green
Write-Host "  Expected: 100" -ForegroundColor Green
Write-Host ""

# Test 8: Missing key without default (should return $null)
Write-Host "TEST 8: Missing key without default" -ForegroundColor Yellow
$result = Get-HashTableProperty -Hashtable $testHashtable -Key "MaxConnections"
Write-Host "  Get-HashTableProperty -Hashtable `$testHashtable -Key 'MaxConnections'" -ForegroundColor Gray
if ($result -eq $null) {
    Write-Host "  Result: `$null" -ForegroundColor Green
} else {
    Write-Host "  Result: $result" -ForegroundColor Red
}
Write-Host "  Expected: `$null" -ForegroundColor Green
Write-Host ""

# Test 9: Key with $null value (should return $null, not default)
Write-Host "TEST 9: Key exists with `$null value" -ForegroundColor Yellow
$testHashtableWithNull = @{ Status = $null }
$result = Get-HashTableProperty -Hashtable $testHashtableWithNull -Key "Status" -Default "Fallback"
Write-Host "  `$ht = @{ Status = `$null }" -ForegroundColor Gray
Write-Host "  Get-HashTableProperty -Hashtable `$ht -Key 'Status' -Default 'Fallback'" -ForegroundColor Gray
if ($result -eq $null) {
    Write-Host "  Result: `$null (key exists, so Default ignored)" -ForegroundColor Green
} else {
    Write-Host "  Result: $result" -ForegroundColor Red
}
Write-Host "  Expected: `$null (actual stored value)" -ForegroundColor Green
Write-Host ""

# Test 10: FailIfMissing with missing key (should throw)
Write-Host "TEST 10: FailIfMissing with missing key" -ForegroundColor Yellow
try {
    $result = Get-HashTableProperty -Hashtable $testHashtable -Key "MissingKey" -FailIfMissing -ErrorContext "DatabaseLookup"
    Write-Host "  Get-HashTableProperty -Hashtable `$testHashtable -Key 'MissingKey' -FailIfMissing -ErrorContext 'DatabaseLookup'" -ForegroundColor Gray
    Write-Host "  Result: ERROR SHOULD HAVE BEEN THROWN" -ForegroundColor Red
} catch {
    Write-Host "  Get-HashTableProperty -Hashtable `$testHashtable -Key 'MissingKey' -FailIfMissing -ErrorContext 'DatabaseLookup'" -ForegroundColor Gray
    Write-Host "  Caught error: $($_.Exception.Message)" -ForegroundColor Green
    Write-Host "  Expected: Error containing 'MissingKey' and 'DatabaseLookup'" -ForegroundColor Green
}
Write-Host ""

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All tests completed!"
Write-Host "========================================" -ForegroundColor Cyan
