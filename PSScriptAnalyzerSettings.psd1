# PSScriptAnalyzer settings for this repo: Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @(
        # The installers and tests talk to a person at a console; Write-Host is the point.
        'PSAvoidUsingWriteHost',
        # The hook's catch blocks are empty on purpose: on any error it prints nothing, and
        # Claude Code shows the prompt as usual.
        'PSAvoidUsingEmptyCatchBlock',
        # Small private helpers in scripts, not exported cmdlets.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSAvoidUsingPositionalParameters'
    )
}
