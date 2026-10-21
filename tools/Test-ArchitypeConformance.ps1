<#
.SYNOPSIS
  Validate one architype folder against the Concierge seeding contract (schemaVersion 1).
.DESCRIPTION
  Implements the checks D-65 requires of `innofactororg/concierge-architypes` CI:

    1. Manifest schema      - manifest.json exists, parses, schemaVersion 1, at least one of
                               configFile/files, every entry has source+target, source relative
                               with no leading separator and no '..', targets unique, no binary
                               source extension. These are exactly the rules
                               Set-NewSpokeConfig.ps1's STEP 1b parser enforces at run time.
    2. Source resolution     - every manifest `source` resolves 200 over anonymous raw HTTP at
       over raw HTTP           {RepoRawBase}/{Ref}/{ArchitypeName}/{source}. This is the check
                               D-65 singles out: it prevents a missing architype file aborting
                               step 05 after a billable subscription exists (T-02-1201).
    3. Reserved-token         - no file the manifest seeds contains a [#_..._#]-shaped token
       conformance             outside the reserved vocabulary this script carries its own copy
                               of. CI cross-checks that copy against Get-NewSpokeReservedToken in
                               concierge-app so the two cannot drift apart silently (T-02-1202).
    4. Canonical parameter    - Bicep architypes only (gated on the manifest's configFile source
       names                   ending in .bicepparam): every token assignment in the config file
                               uses that token's canonical parameter name.
    5. Bicep build            - Bicep architypes only: `az bicep build` on the shared template,
                               and `az bicep build-params` on the config file with every token
                               substituted for a representative literal.
    6. PSRule                 - Bicep architypes only: PSRule against the built template using
                               the architype's own ps-rule.yaml.

  Checks 4-6 are skipped - not failed - for a non-Bicep architype (network-terraform has no
  Bicep to build; network-arm is legacy content preserved rather than promoted). bicepconfig.json
  presence is never gated (RESEARCH.md Open Question 1, resolved) - neither ks5cae nor salgsl.IaC
  has one.
.PARAMETER Path
  The architype folder to validate (e.g. ../concierge-architypes/network).
.PARAMETER Ref
  The git ref whose published raw URLs check 2 probes. Defaults to the current branch of the git
  repository Path lives in. Passed explicitly so the identical checker can be re-pointed at `main`
  after a merge (02-12 Task 3) without a second, differently-written checker.
.PARAMETER RepoSlug
  The GitHub `owner/repo` slug raw URLs are built against. Defaults to
  innofactororg/concierge-architypes.
.EXAMPLE
  ./Test-ArchitypeConformance.ps1 -Path ../concierge-architypes/network
.EXAMPLE
  ./Test-ArchitypeConformance.ps1 -Path ../concierge-architypes/network -Ref main
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]
  $Path,

  [Parameter(Mandatory = $false)]
  [string]
  $Ref,

  [Parameter(Mandatory = $false)]
  [string]
  $RepoSlug = 'innofactororg/concierge-architypes'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -----------------------------------------------------------------------------------------------
# Reserved-token vocabulary - this checker's own copy (it cannot import the Concierge module).
# Loaded from tools/ReservedTokens.psd1, a single-source-of-truth data file. CI's vocabulary-
# parity job (architype-ci.yml) checks out concierge-app and asserts that file is identical to
# Get-NewSpokeReservedToken's output there, so the two cannot drift apart silently (T-02-1202).
# -----------------------------------------------------------------------------------------------
$vocabularyPath = Join-Path -Path $PSScriptRoot -ChildPath 'ReservedTokens.psd1'
$vocabularyData = Import-PowerShellDataFile -Path $vocabularyPath
$script:ReservedTokens = @($vocabularyData.Tokens | ForEach-Object { [pscustomobject]$_ })

$script:BinaryFileExtensions = @(
  '.7z', '.bmp', '.bz2', '.class', '.dll', '.dmg', '.eot', '.exe', '.gif', '.gz',
  '.ico', '.jar', '.jpeg', '.jpg', '.mp3', '.mp4', '.msi', '.otf', '.p12', '.pdf',
  '.pfx', '.png', '.rar', '.so', '.snk', '.tar', '.tgz', '.ttf', '.woff', '.woff2', '.zip'
)

$script:Failures = @()
function Write-CheckResult {
  param([string]$Check, [bool]$Ok, [string]$Detail)
  if ($Ok) {
    Write-Host "  [PASS] $($Check): $($Detail)" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] $($Check): $($Detail)" -ForegroundColor Red
    $script:Failures += "$($Check): $($Detail)"
  }
}

function Get-ManifestNodeValue {
  param($InputObject, [string]$Name)
  if ($null -eq $InputObject) { return $null }
  $prop = $InputObject.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $null }
  return $prop.Value
}

# -----------------------------------------------------------------------------------------------
# Resolve inputs
# -----------------------------------------------------------------------------------------------
$archPath = (Resolve-Path -Path $Path).Path.TrimEnd('/', '\')
$archName = Split-Path -Path $archPath -Leaf
if (-not $Ref) {
  $Ref = $(
    Push-Location $archPath
    try { git rev-parse --abbrev-ref HEAD 2>$null } finally { Pop-Location }
  )
}

Write-Host "Architype conformance: $($archName) (path: $($archPath), ref: $($Ref))"

$manifestPath = Join-Path -Path $archPath -ChildPath 'manifest.json'
if (-not (Test-Path -Path $manifestPath)) {
  Write-CheckResult -Check 'manifest-exists' -Ok $false -Detail "manifest.json not found at $($manifestPath)"
  exit 1
}

# -----------------------------------------------------------------------------------------------
# Check 1: Manifest schema
# -----------------------------------------------------------------------------------------------
try {
  $manifestRaw = Get-Content -Path $manifestPath -Raw
  $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop
  Write-CheckResult -Check 'manifest-parses' -Ok $true -Detail 'manifest.json is valid JSON'
} catch {
  Write-CheckResult -Check 'manifest-parses' -Ok $false -Detail "manifest.json is not valid JSON: $($_.Exception.Message)"
  exit 1
}

$schemaVersion = Get-ManifestNodeValue -InputObject $manifest -Name 'schemaVersion'
Write-CheckResult -Check 'schemaVersion' -Ok ([int]$schemaVersion -eq 1) -Detail "schemaVersion is $($schemaVersion), expected 1"

$configFileNode = Get-ManifestNodeValue -InputObject $manifest -Name 'configFile'
$filesNode = @(Get-ManifestNodeValue -InputObject $manifest -Name 'files' | Where-Object { $null -ne $_ })

$entries = @()
if ($null -ne $configFileNode) {
  $entries += [pscustomobject]@{
    Source   = [string](Get-ManifestNodeValue -InputObject $configFileNode -Name 'source')
    Target   = [string](Get-ManifestNodeValue -InputObject $configFileNode -Name 'target')
    IsConfig = $true
  }
}
foreach ($f in $filesNode) {
  $entries += [pscustomobject]@{
    Source   = [string](Get-ManifestNodeValue -InputObject $f -Name 'source')
    Target   = [string](Get-ManifestNodeValue -InputObject $f -Name 'target')
    IsConfig = $false
  }
}

Write-CheckResult -Check 'declares-entries' -Ok ($entries.Count -gt 0) -Detail "manifest declares $($entries.Count) entr$(if ($entries.Count -eq 1) {'y'} else {'ies'}) across configFile+files"

$seenTargets = @{}
foreach ($e in $entries) {
  $label = "source=$($e.Source)"
  if ([string]::IsNullOrWhiteSpace($e.Source)) {
    Write-CheckResult -Check 'entry-has-source' -Ok $false -Detail 'an entry has an empty source'
    continue
  }
  if ([string]::IsNullOrWhiteSpace($e.Target)) {
    Write-CheckResult -Check 'entry-has-target' -Ok $false -Detail "$($label) has no target"
  }
  $sourceRelative = -not ($e.Source -match '^[/\\]') -and ($e.Source -notmatch '\.\.')
  Write-CheckResult -Check 'source-relative' -Ok $sourceRelative -Detail "$($label) must be relative with no leading separator and no '..'"

  $ext = [System.IO.Path]::GetExtension($e.Source).ToLowerInvariant()
  $notBinary = $ext -notin $script:BinaryFileExtensions
  Write-CheckResult -Check 'source-not-binary' -Ok $notBinary -Detail "$($label) has extension '$($ext)'"

  if ($seenTargets.ContainsKey($e.Target)) {
    Write-CheckResult -Check 'target-unique' -Ok $false -Detail "target '$($e.Target)' is declared more than once"
  } else {
    $seenTargets[$e.Target] = $true
  }
}

# -----------------------------------------------------------------------------------------------
# Check 2: Source resolution over raw HTTP
# -----------------------------------------------------------------------------------------------
$rawBase = "https://raw.githubusercontent.com/$($RepoSlug)/$($Ref)/$($archName)"
foreach ($e in $entries) {
  if ([string]::IsNullOrWhiteSpace($e.Source)) { continue }
  $url = "$($rawBase)/$($e.Source)"
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head -TimeoutSec 15
    Write-CheckResult -Check 'source-resolves-200' -Ok ($resp.StatusCode -eq 200) -Detail "$($url) returned $($resp.StatusCode)"
  } catch {
    $statusCode = $(
      if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
        [int]$_.Exception.Response.StatusCode
      } else {
        'no response'
      }
    )
    Write-CheckResult -Check 'source-resolves-200' -Ok $false -Detail "$($url) failed ($($statusCode)): $($_.Exception.Message)"
  }
}

# -----------------------------------------------------------------------------------------------
# Check 3: Reserved-token conformance - every local file the manifest seeds
# -----------------------------------------------------------------------------------------------
$literalTokens = @($script:ReservedTokens | Where-Object { -not $_.Indexed } | Select-Object -ExpandProperty Token)
$indexedPatterns = @(
  $script:ReservedTokens | Where-Object { $_.Indexed } | ForEach-Object {
    '^' + ([regex]::Escape($_.Token) -replace 'NN', '\d{2}') + '$'
  }
)
function Test-ReservedTokenContent {
  param([string]$Content)
  $found = @(
    [regex]::Matches($Content, '\[#_[^\]]+_#\]') | Select-Object -ExpandProperty Value | Select-Object -Unique
  )
  return @(
    $found | Where-Object {
      $candidate = $_
      $isLiteral = $literalTokens -contains $candidate
      $isIndexed = [bool]($indexedPatterns | Where-Object { $candidate -match $_ })
      -not ($isLiteral -or $isIndexed)
    }
  )
}

foreach ($e in $entries) {
  if ([string]::IsNullOrWhiteSpace($e.Source)) { continue }
  $localFile = Join-Path -Path $archPath -ChildPath $e.Source
  if (-not (Test-Path -Path $localFile)) {
    Write-CheckResult -Check 'source-exists-locally' -Ok $false -Detail "$($e.Source) does not exist under $($archPath)"
    continue
  }
  $content = Get-Content -Path $localFile -Raw
  # @() guards against PowerShell flattening an empty-array `return` to $null on assignment.
  $unreserved = @(Test-ReservedTokenContent -Content $content)
  Write-CheckResult -Check 'reserved-token-conformance' -Ok ($unreserved.Count -eq 0) -Detail "$($e.Source): $(if ($unreserved.Count -eq 0) { 'no unreserved tokens' } else { "unreserved token(s) found: $($unreserved -join ', ')" })"
}

# -----------------------------------------------------------------------------------------------
# Bicep-architype gate: only when the manifest's configFile source ends in .bicepparam
# -----------------------------------------------------------------------------------------------
$configSource = $(if ($configFileNode) { [string](Get-ManifestNodeValue -InputObject $configFileNode -Name 'source') } else { $null })
$isBicepArchitype = $configSource -and $configSource.ToLowerInvariant().EndsWith('.bicepparam')

if (-not $isBicepArchitype) {
  Write-Host "  [SKIP] canonical-parameter-names, bicep-build, ps-rule: $($archName) has no .bicepparam configFile (not a Bicep architype under the consolidated model)" -ForegroundColor Yellow
} else {
  # ---------------------------------------------------------------------------------------------
  # Check 4: Canonical parameter names
  # ---------------------------------------------------------------------------------------------
  $configLocalPath = Join-Path -Path $archPath -ChildPath $configSource
  $configContent = Get-Content -Path $configLocalPath -Raw
  $paramAssignRegex = [regex]'param\s+(\w+)\s*='
  # Walk each `param <name> = ...` statement's own textual block up to the next top-level
  # `param` keyword (or end of file) and look for any reserved token inside that block - this
  # tolerates multi-line array assignments like subnetAddressPrefixes.
  $paramMatches = @($paramAssignRegex.Matches($configContent))
  for ($i = 0; $i -lt $paramMatches.Count; $i++) {
    $paramName = $paramMatches[$i].Groups[1].Value
    $blockStart = $paramMatches[$i].Index
    $blockEnd = $(if ($i + 1 -lt $paramMatches.Count) { $paramMatches[$i + 1].Index } else { $configContent.Length })
    $block = $configContent.Substring($blockStart, $blockEnd - $blockStart)
    $tokensInBlock = @([regex]::Matches($block, '\[#_[^\]]+_#\]') | Select-Object -ExpandProperty Value | Select-Object -Unique)
    foreach ($tok in $tokensInBlock) {
      $known = $script:ReservedTokens | Where-Object {
        (-not $_.Indexed -and $_.Token -eq $tok) -or
        ($_.Indexed -and $tok -match ('^' + ([regex]::Escape($_.Token) -replace 'NN', '\d{2}') + '$'))
      } | Select-Object -First 1
      if ($null -eq $known) { continue } # already reported as an unreserved token by check 3
      $canonicalOk = $paramName -eq $known.CanonicalParameter
      Write-CheckResult -Check 'canonical-parameter-name' -Ok $canonicalOk -Detail "token $($tok) assigned to param '$($paramName)', expected '$($known.CanonicalParameter)'"
    }
  }

  # ---------------------------------------------------------------------------------------------
  # Check 5: Bicep build (shared template) + build-params (config file, tokens substituted)
  # ---------------------------------------------------------------------------------------------
  $bicepEntry = $entries | Where-Object { $_.Source.ToLowerInvariant().EndsWith('.bicep') -and -not $_.IsConfig } | Select-Object -First 1
  $siblingParamFile = $null
  if ($null -eq $bicepEntry) {
    Write-CheckResult -Check 'bicep-build' -Ok $false -Detail "$($archName) declares a .bicepparam configFile but no shared .bicep template in files[]"
  } else {
    $bicepLocalPath = Join-Path -Path $archPath -ChildPath $bicepEntry.Source
    $buildOutput = az bicep build --file $bicepLocalPath --stdout 2>&1
    Write-CheckResult -Check 'bicep-build' -Ok ($LASTEXITCODE -eq 0) -Detail "az bicep build $($bicepEntry.Source): exit $($LASTEXITCODE)"

    # Substitute every reserved token in the config file for a representative literal, so
    # build-params (and, below, PSRule) prove the template and its parameter file compile and
    # scan TOGETHER rather than separately. The raw pre-substitution file legitimately fails
    # build-params on any @allowed-constrained param (e.g. environmentCode) - expected, not a
    # defect (02-11-SUMMARY.md "Issues Encountered").
    $substituted = $configContent
    foreach ($t in $script:ReservedTokens) {
      if ($t.Indexed) {
        $pattern = [regex]([regex]::Escape($t.Token) -replace 'NN', '\d{2}')
        $substituted = $pattern.Replace($substituted, $t.Sample)
      } else {
        $substituted = $substituted.Replace($t.Token, $t.Sample)
      }
    }
    # `using` is relative to the config file's own location, so the substituted copy has to live
    # alongside the real config file (a throwaway sibling name) rather than in a temp directory,
    # or the `using '../../main.bicep'`-shaped path will not resolve.
    $siblingParamFile = Join-Path -Path (Split-Path -Path $configLocalPath -Parent) -ChildPath '._conformance_check.bicepparam'
    Set-Content -Path $siblingParamFile -Value $substituted -NoNewline
    $buildParamsOutput = az bicep build-params --file $siblingParamFile --stdout 2>&1
    Write-CheckResult -Check 'bicep-build-params' -Ok ($LASTEXITCODE -eq 0) -Detail "az bicep build-params (tokens substituted): exit $($LASTEXITCODE)$(if ($LASTEXITCODE -ne 0) { " -- $($buildParamsOutput)" })"
  }

  # ---------------------------------------------------------------------------------------------
  # Check 6: PSRule, using the architype's own ps-rule.yaml
  # ---------------------------------------------------------------------------------------------
  $psRuleConfigPath = Join-Path -Path $archPath -ChildPath 'ps-rule.yaml'
  if (-not (Test-Path -Path $psRuleConfigPath)) {
    Write-CheckResult -Check 'ps-rule' -Ok $false -Detail "$($archName) declares a .bicepparam configFile but has no ps-rule.yaml"
  } elseif ($null -eq $bicepEntry -or $null -eq $siblingParamFile) {
    Write-Host "  [SKIP] ps-rule: no shared .bicep template to build and scan" -ForegroundColor Yellow
  } else {
    try {
      Import-Module Az.Resources -ErrorAction Stop
      Import-Module PSRule.Rules.Azure -ErrorAction Stop
      # PSRule.Rules.Azure's native Bicep-expansion convention needs BOTH `-Format File` and
      # `configuration.AZURE_BICEP_FILE_EXPANSION: true` (the latter is a real gap this check
      # found in ps-rule.yaml as first authored - see the plan summary's deviation log), and
      # -InputPath must point at the .bicepparam file itself, not a pre-built ARM JSON: PSRule
      # invokes the Bicep CLI itself to expand template+params together. `OutputFormat None`
      # overrides ps-rule.yaml's own `output.format: Markdown` (a CI job-summary convenience
      # setting), which otherwise makes Invoke-PSRule return formatted text instead of objects.
      $psRuleOption = New-PSRuleOption -Path $psRuleConfigPath -OutputFormat None
      $psRuleResult = @(Invoke-PSRule -InputPath $siblingParamFile -Option $psRuleOption -Module PSRule.Rules.Azure -Format File -ErrorAction Stop)
      $psRuleFailures = @($psRuleResult | Where-Object { $_.Outcome -eq 'Fail' })
      Write-CheckResult -Check 'ps-rule' -Ok ($psRuleResult.Count -gt 0 -and $psRuleFailures.Count -eq 0) -Detail "$($psRuleResult.Count) rule(s) evaluated, $($psRuleFailures.Count) failed$(if ($psRuleFailures.Count -gt 0) { ': ' + (($psRuleFailures | Select-Object -ExpandProperty RuleName) -join ', ') })"
      # The plan stage does not scan the parameter file: it scans the whole seeded repository (ps-rule-assert,
      # inputType repository). So scan a throwaway copy of the architype the way the pipeline does. This is
      # what catches a ps-rule.yaml that expands main.bicep or a module standalone ("parameter ... not set"),
      # which the parameter-file scan above cannot see.
      $repoScanDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "psrule-repo-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
      try {
        Copy-Item -Path $archPath -Destination $repoScanDir -Recurse
        Get-ChildItem -Path $repoScanDir -Recurse -File | Where-Object { $_.Extension -in '.bicep', '.bicepparam', '.yaml', '.json' } | ForEach-Object {
          $text = Get-Content -Path $_.FullName -Raw
          foreach ($t in $script:ReservedTokens) {
            if ($t.Indexed) { $text = ([regex]([regex]::Escape($t.Token) -replace 'NN', '\d{2}')).Replace($text, $t.Sample) } else { $text = $text.Replace($t.Token, $t.Sample) }
          }
          Set-Content -Path $_.FullName -Value $text -NoNewline
        }
        $scanOption = New-PSRuleOption -Path (Join-Path -Path $repoScanDir -ChildPath 'ps-rule.yaml') -OutputFormat None
        $scanErrors = $null
        # PSRule resolves the repository from the working directory, as the pipeline's checkout is
        Push-Location -Path $repoScanDir
        try {
          $scanResult = @(Invoke-PSRule -InputPath $repoScanDir -Option $scanOption -Module PSRule.Rules.Azure -Format File -ErrorAction SilentlyContinue -ErrorVariable scanErrors)
        } finally {
          Pop-Location
        }
        $expandErrors = @($scanErrors | Where-Object { "$($_)" -match 'Failed to expand bicep source' })
        Write-CheckResult -Check 'ps-rule-repository-scan' -Ok ($scanResult.Count -gt 0 -and $expandErrors.Count -eq 0) -Detail "repository scan: $($scanResult.Count) rule(s) evaluated, $($expandErrors.Count) bicep expansion error(s)$(if ($expandErrors.Count -gt 0) { ": $(("$($expandErrors[0])" -split "`n")[0])" })"
      } finally {
        Remove-Item -Path $repoScanDir -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {
      Write-CheckResult -Check 'ps-rule' -Ok $false -Detail "PSRule run failed: $($_.Exception.Message)"
    }
  }
  if ($siblingParamFile) {
    Remove-Item -Path $siblingParamFile -ErrorAction SilentlyContinue
  }
}

# -----------------------------------------------------------------------------------------------
# Result
# -----------------------------------------------------------------------------------------------
if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "$($archName): $($script:Failures.Count) check(s) failed" -ForegroundColor Red
  exit 1
} else {
  Write-Host ""
  Write-Host "$($archName): all checks passed" -ForegroundColor Green
  exit 0
}
