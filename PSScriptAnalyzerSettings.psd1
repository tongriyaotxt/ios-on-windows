@{
    # 只保留能真正拦住 bug 的规则；风格类交给 review。
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',              # 这是 CLI 工具，Write-Host 是有意的
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules        = @{
        PSAvoidUsingCmdletAliases        = @{ Enable = $true }
        PSAvoidUsingInvokeExpression     = @{ Enable = $true }
        PSAvoidUsingPositionalParameters = @{ Enable = $true }
        PSUseApprovedVerbs               = @{ Enable = $true }
        PSAvoidTrailingWhitespace        = @{ Enable = $true }
        PSAvoidUsingDoubleQuotesForConstantString = @{ Enable = $false }
        PSUseSingularNouns               = @{ Enable = $false }
        PSPossibleIncorrectComparisonWithNull = @{ Enable = $true }
    }
}
