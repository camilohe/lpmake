function New-ProjectFromLinqpadQuery
{
	<#
	.Synopsis
		Creates a new project from specified linqpad query and build it.
	.Example
		PS> New-ProjectFromLinqpadQuery .\MyQuery.linq
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[string] $QueryPath,

		# Used to store the generated files; will create a new temporary directory if not specified.
		[string] $TargetDir,

		# Used as the source file name as well as assembly and namespace name; will be inferrred from the query file if not specified.
		[string] $Name,

		# TODO: how do I detect this from code using Roslyn?
		[switch] $Unsafe,

		[ValidateSet('Library', 'Exe')]
		[string] $OutputType = 'Library',

		[string] $ObjectDumper = 'ObjectDumperLib',

        # Immediately load the built assembly into PowerShell
        [switch] $Load,

        # Publish as a nuget package using command `Publish-MyNugetPackage` which you needs
        # to define yourself, it requires a mandatory parameter which is the package id.
        [switch] $Publish
		)
	$csharpImports = @(
			'System'
			'System.IO'
			'System.Text'
			'System.Text.RegularExpressions'
			'System.Diagnostics'
			'System.Threading'
			'System.Reflection'
			'System.Collections'
			'System.Collections.Generic'
			'System.Linq'
			'System.Linq.Expressions'
			'System.Data'
			'System.Data.SqlClient'
			'System.Data.Linq'
			'System.Data.Linq.SqlClient'
			'System.Xml'
			'System.Xml.Linq'
			'System.Xml.XPath'
		)
	$fsharpImports = @(
			'System'
			'System.IO'
			'System.Text'
			'System.Text.RegularExpressions'
			'System.Diagnostics'
			'System.Threading'
			'System.Reflection'
		)

	function GetCommonNamespaces($namespaces, $fsharp) {
		$(if ($fsharp) { $fsharpImports } else { $csharpImports }) | % {
			if ($fsharp) {
				"open $_"
			} else {
				"using $_;"
			}
		}

		foreach($ns in $namespaces) {
			if ($fsharp) {
				"open $ns"
			} else {
				"using $ns;"
			}
		}
	}
	
	function AddNamespace($query, $ns) {
		if (!$query.Namespaces) { $query.Namespaces = @() }
		if ($query.Namespaces -notcontains $ns) { $query.Namespaces += $ns }
	}

	function AddNugetRef($query, $name, $version) {
		if (!$query.NuGetReferences) { $query.NugetReferences = @() }
		$existing = $query.NugetReferences | ? { $_.Name -eq $name }
		if (!$existing) {
			$newobj = [PsCustomObject] @{
				Name = $name
				Version = $version
			}
			$query.NugetReferences += $newobj
		}
	}

	$ErrorActionPreference = 'Stop'

	if (!$TargetDir) { $TargetDir = New-TempDirectory }
	if (!$Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($QueryPath).Replace(' ', '') }

	$query = ConvertFrom-LinqpadQuery $QueryPath
	$supportedKinds = @('Program', 'FSharpProgram')
	if ($supportedKinds -notcontains $query.Kind) { 
		throw "Currently only supports following kinds: $($supportedKinds -join ', '); the query $QueryPath has kind: $($query.Path)" 
	}
	$fsharp = $(if ($query.Kind -eq 'FSharpProgram') { $true })
	$islib = $OutputType -eq 'Library'

	# Lines after the flags are considered top level classes; before it are
	# embedded code which needs to be wrapped in a class with entry point if 
	# we are creating exe.
	$FLAG= '^(// Define other methods and classes here|//////////)'
	$flagFound = $false
	$libcode = @()
	$maincode = @()
	foreach($line in $query.Code) {
		if (!$flagFound -AND ($line -match $FLAG)) {
			$flagFound = $true
		} elseif ($flagFound) {
			$libcode += $line
		} else {
			$maincode += $line
		}
	}

	if ($fsharp) {
		# in the case of F# program, test code will be after library code
		$libcode, $maincode = $maincode, $libcode
	}

	if ($islib -AND ($libcode.Length -eq 0)) {
		# only validate when it is a library but no library code found
		throw "No valid library code found; please ensure you have $FLAG in source, only code after it will be compiled."
	}

	# validate files to be written don't exist already
	$ft = $(if ($fsharp) { 'f' } else { 'c' })
	$projectFile = [IO.Path]::Combine($TargetDir, "$Name.${ft}sproj")
	if (Test-Path $projectFile) { throw "$projectFile already exists" }
	$sourceFile = [IO.Path]::Combine($TargetDir, "$Name.${ft}s")
	if (Test-Path $sourceFile) { throw "$sourceFile already exists" }
    $projectJson = [IO.Path]::Combine($TargetDir, "project.json")

	# generate project.json
    if (!$islib) {
        AddNamespace $query $ObjectDumper
        AddNugetRef $query $ObjectDumper '*'
    }

    if ($fsharp) {
        if (!$islib) {
            AddNamespace $query $ObjectDumper
        }
        AddNugetRef $query 'FSharp.Core' '4.0.0.1'
    }
	if ($query.NugetReferences) {
        $query.NugetReferences | New-ProjectJson | Out-File $projectJson -Encoding UTF8
    }

	# generate source file
	$(
		if ($fsharp) {
			if ($islib) {
				"namespace $Name"
			}
		} else {
			"namespace $Name"
			'{'
		}
		GetCommonNamespaces $query.Namespaces $fsharp

		if (!$fsharp) {
			if (!$islib) {
				@'
				internal class Program 
				{
					static void Main(string[] args) {
						new Program().Main();
					}
'@
				$maincode
				'}'
			}

			$libcode
			'}'
		} else {
			if (!$islib) {
                'let Dump = ObjectDumper.Write'
				$query.Code
			} else {
				$libcode
			}
		}
	) | Out-File $sourceFile -Encoding UTF8

	# generate config files
	$contents = @()
	if ($query.NugetReferences) {
		$contents = @('project.json')
	}

	$references = $(
		if ($query.References) {
			$query.References
		}
		if ($query.GacReferences) {
			$query.GacReferences | % {
				$_.Name
			}
		}
	)

	# generate project file
	if ($fsharp) {
		$content = New-Fsproj -Name $Name -References $references -Sources @([IO.Path]::GetFileName($sourceFile)) -Contents $contents -OutputType $OutputType 
	} else {
		$content = New-Csproj -Name $Name -References $references -Sources @([IO.Path]::GetFileName($sourceFile)) -Contents $contents -Unsafe:$Unsafe -OutputType $OutputType
	}
	$content | Out-File $projectFile -Encoding UTF8

	Push-Location $TargetDir
	if ($query.NuGetReferences) {
		nuget restore $projectJson
	}

	$msbuild = "$([Environment]::GetFolderPath('ProgramFilesX86'))\Msbuild\14.0\bin\msbuild.exe"
	if (!(Test-Path $msbuild)) { 
		throw "Unable to find $msbuild"
	}

	& $msbuild $projectFile
    if ($LastExitCode -eq 0) {
        if ($islib) {
            if ($Load) {
                Add-Type -Path "bin\debug\$Name.dll"
            }
            if ($Publish) {
                if (Get-Command Publish-MyNugetPackage -ErrorAction SilentlyContinue) {
                    Publish-MyNugetPackage $Name
                } else {
                    throw "You need to write a script or module function named Publish-MyNugetPackage to publish the nuget package to your own nuget source." 
                }
            }
        }
    }
}

Set-Alias lpmake New-ProjectFromLinqpadQuery -Force
