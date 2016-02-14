﻿Import-Module Pester
Import-Module $PSScriptRoot -Force


#cls

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$TestSqlServer = '.'
$TestDatabase = 'ScriptTest'

$DeleteDatabaseScript = @"
IF EXISTS(select * from sys.databases where name='{0}')
BEGIN
    ALTER DATABASE [{0}] SET  SINGLE_USER WITH ROLLBACK IMMEDIATE
    DROP DATABASE [{0}]
END
"@

$CreateDatabaseScript = 'CREATE DATABASE [{0}]'

function Initialize-TestDatabase
{
     param
     (
         [string] $ServerName,
         [string] $DatabaseName
     )

    try
    {
        $IntegratedConnectionString = 'Data Source={0}; Integrated Security=True;MultipleActiveResultSets=False;Application Name="SQL Management"'
        $Connection = (New-Object 'System.Data.SqlClient.SqlConnection')
        $Connection.ConnectionString = $IntegratedConnectionString -f $ServerName
        $Connection.Open()

        $SqlCmd = $Connection.CreateCommand()
        $SqlCmd.CommandType = [System.Data.CommandType]::Text

        $SqlCmd.CommandText = ($DeleteDatabaseScript -f $TestDatabase)
        Write-Verbose $SqlCmd.CommandText
        [void]($SqlCmd.ExecuteNonQuery())

        $SqlCmd.CommandText = ($CreateDatabaseScript -f $TestDatabase)
        Write-Verbose $SqlCmd.CommandText
        [void]($SqlCmd.ExecuteNonQuery())

        $Connection.ChangeDatabase($TestDatabase)

        $Connection
    }
    Catch
    {
        Write-Error ('Error while Re-Creating Datbase {0}.{1} - {2}' -f $ServerName,$DatabaseName,$_)
    }

}


#$Connection = $null
#Describe "Get-SqlConnecti)n" {
#    It 'Connects to our Test SQL Server ' {
#        $script:connection = Get-SqlConnection $TestSqlServer
#        $connection.State | Should Be 'Open'
#    }
#}
#
#$Connection.State

function Test-ForPatches
{
     param
     (
         [Array] $TestPatchNames,

         [switch] $PartialList,

         [string] $Description='Verify Patches Included'
     )

    $PatchNames = $QueuedPatches | %{$_.PatchName}
    Describe $Description {
        if (! $PartialList)
        { 
            It "Should contain $($TestPatchNames.Count) Patches" {
                ($PatchNames.Count) | Should be $TestPatchNames.Count
            }
        }

        foreach ($TestPatchName in $TestPatchNames)
        {
            It "Should contain $TestPatchName" {
                $PatchNames -contains $TestPatchName | Should be $true
            }
        }
    }

}

function Test-ForSqlObjects
{
     param
     (
         [Array] $ObjectNames,
         [string] $objectType = 'U',
         [switch] $TestDoesntExist,

         [string] $Description='Verify Sql Objects'
     )
    $ObjectIdForObjectSql = "SELECT OBJECT_ID(N'{0}', N'{1}')"

    $SqlCmd = $Connection.CreateCommand()
    $SqlCmd.CommandType = [System.Data.CommandType]::Text

    if ($TestDoesntExist)
    {
        $TestMessage = 'Verify {0} does not exist'
    }
    else
    {
        $TestMessage = 'Verify {0} exists'
    }

    Describe $Description {
        foreach ($ObjectName in $ObjectNames)
        {
            $SqlCmd.CommandText = ($ObjectIdForObjectSql -f $objectName,$objectType)
            $ObjectId = $SqlCmd.ExecuteScalar()
            $ObjectDoesNotExist = $ObjectId -is [System.DBNull]
            It ($TestMessage -f $ObjectName) {
                $ObjectDoesNotExist | Should be $TestDoesntExist
            }
        }
    }
}


$outFolderPath = Join-Path $PSScriptRoot 'TestOutput'
$rootFolderPath = Join-Path $PSScriptRoot 'Tests\SqlScripts'

function InitDbPatches
{
     param
     (
         [string] $Environment = ''
     )

    Initialize-SqlServerSafePatch -ServerName $TestSqlServer `
                          -DatabaseName $TestDatabase `
                          -RootFolderPath $rootFolderPath `
                          -OutFolderPath $outFolderPath `
                          -Environment $Environment 
}


##############################################################################################################################

$Connection = Initialize-TestDatabase $TestSqlServer

InitDbPatches -Environment 'Dev'

Get-ChildItem $rootFolderPath -recurse -Filter *.sql | Add-SqlDbPatches #-Verbose   

function Test-EnvironmentPatches
{
     param
     (
         [string] $Environment,
         [int]    $TestPatchCount = 0
     )

    InitDbPatches -Environment $Environment

    Get-ChildItem $rootFolderPath -recurse -Filter *.sql | Add-SqlDbPatches #-Verbose   

    Test-ForPatches -Description "Test Environment Patches for '$Environment'"  -TestPatchNames @(
        "BeforeOneTime\00_Initialize.($Environment).sql"
        'BeforeOneTime\01_SampleItems.sql'
        'BeforeOneTime\02_ScriptsRun.sql'
        'BeforeOneTime\03_ScriptsRunErrors.sql'
        'BeforeOneTime\04_Version.sql'
    )
}

# ------------------------------------

Test-EnvironmentPatches -Environment 'Dev' -TestPatchCount 5
Test-EnvironmentPatches -Environment 'Test' -TestPatchCount 5
Test-EnvironmentPatches -Environment 'Prod' -TestPatchCount 5


Get-ChildItem $rootFolderPath -recurse -Filter *.sql | Select-Object -First 5 | Add-SqlDbPatches #-Verbose   

##############################################################################################################################

# $Connection = Initialize-TestDatabase $TestSqlServer

InitDbPatches

Get-ChildItem $rootFolderPath -recurse -Filter *.sql | Add-SqlDbPatches #-Verbose   

Test-ForPatches -TestPatchNames @(
    'BeforeOneTime\01_SampleItems.sql'
    'BeforeOneTime\02_ScriptsRun.sql'
    'BeforeOneTime\03_ScriptsRunErrors.sql'
    'BeforeOneTime\04_Version.sql'
)

Test-ForSqlObjects -TestDoesntExist -ObjectNames @('dbo.SampleItems','dbo.ScriptsRun','dbo.ScriptsRunErrors','dbo.Version') -Description 'Tables are not created'

Publish-Patches

Test-ForSqlObjects -ObjectNames @('dbo.SampleItems','dbo.ScriptsRun','dbo.ScriptsRunErrors','dbo.Version') -Description 'Tables got created'

# ------------------------------------

InitDbPatches
Get-ChildItem $rootFolderPath -recurse -Filter *.sql | Add-SqlDbPatches 

Describe 'Verify No Patches to be run after publish' {
    It 'Should contain 0 Patches' {
        ($QueuedPatches.Count) | Should be 0
    }
}

Publish-Patches

##############################################################################################################################


