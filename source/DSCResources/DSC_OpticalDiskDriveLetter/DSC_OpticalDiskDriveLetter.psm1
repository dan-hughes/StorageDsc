$modulePath = Join-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -ChildPath 'Modules'

# Import the Storage Common Module.
Import-Module -Name (Join-Path -Path $modulePath `
        -ChildPath (Join-Path -Path 'StorageDsc.Common' `
            -ChildPath 'StorageDsc.Common.psm1'))

Import-Module -Name (Join-Path -Path $modulePath -ChildPath 'DscResource.Common')

# Import Localization Strings.
$script:localizedData = Get-LocalizedData -DefaultUICulture 'en-US'

<#
    .SYNOPSIS
        This helper function determines if an optical disk can be managed
        or not by this resource.

    .PARAMETER OpticalIdsk
        The cimv2:Win32_CDROMDrive instance of the optical disk that should
        be checked.

    .OUTPUTS
        System.Boolean

    .NOTES
        This function will use the following logic when determining if a drive is
        a mounted ISO and therefore should **not** be mnanaged by this resource:

        - Get the Drive letter assigned to the drive in the `cimv2:Win32_CDROMDrive`
          instance
        - If the drive letter is set, query the volume information for the device
           using drive letter and get the device path.
        - If the drive letter is not set, just use the drive as the device path.
        - Look up the disk image using the device path.
        - If no error occurs then the device is a mounted ISO and should not be
          used with this resource.
          If a "The specified disk is not a virtual disk." error occurs then it
          is not an ISO and can be managed by this resource.
#>
function Test-OpticalDiskCanBeManaged
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]
        $OpticalDisk
    )

    $diskCanBeManaged = $false
    <#
        If the OpticalDisk.Drive matches Volume{<Guid>} then the disk is not
        assigned a drive letter and so just use the drive value as a device
        path.
    #>
    if ($OpticalDisk.Drive -match 'Volume{.*}')
    {
        $devicePath = "\\?\$($OpticalDisk.Drive)"

        Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($script:localizedData.TestOpticalDiskWithoutDriveLetterCanBeManaged -f $devicePath)
        ) -join '')
    }
    else
    {
        $driveLetter = $OpticalDisk.Drive
        $devicePath = (Get-CimInstance `
            -ClassName Win32_Volume `
            -Filter "DriveLetter = '$($driveLetter)'").DeviceId -replace "\\$"

        if ([System.String]::IsNullOrEmpty($devicePath))
        {
            <#
                A drive letter is not assigned to this disk, but the Drive property does
                not contain a Volume{<Guid>} value. This has prevented the volume to be
                matched to the disk. This prevents this disk from being managed, but it
                is not a terminal error.
            #>
            Write-Warning -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($script:localizedData.TestOpticalDiskVolumeNotMatchableWarning -f $driveLetter)
            ) -join '')
        }
        else
        {
            Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($script:localizedData.TestOpticalDiskWithDriveLetterCanBeManaged -f $devicePath, $driveLetter)
            ) -join '')
        }
    }

    if ($devicePath)
    {
        try
        {
            <#
                If the device is not a mounted ISO then the Get-DiskImage will throw an
                Microsoft.Management.Infrastructure.CimException exception with the
                message "The specified disk is not a virtual disk."
            #>
            Get-DiskImage -DevicePath $devicePath -ErrorAction Stop | Out-Null
        }
        catch [Microsoft.Management.Infrastructure.CimException]
        {
            if ($_.Exception.Message.TrimEnd() -eq $script:localizedData.DiskIsNotAVirtualDiskError)
            {
                # This is not a mounted ISO, so it can managed
                $diskCanBeManaged = $true
            }
            else
            {
                throw $_
            }
        }

        Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($script:localizedData.OpticalDiskCanBeManagedStatus -f $devicePath, @('can not', 'can')[0, 1][$diskCanBeManaged])
        ) -join '')
    }

    return $diskCanBeManaged
}

<#
    .SYNOPSIS
        This helper function returns a hashtable containing the current
        drive letter assigned to the optical disk in the system matching
        the disk number.

        If the drive exists but is not mounted to a drive letter then
        the DriveLetter will be empty, but the DeviceId will contain the
        DeviceId representing the optical disk.

        If there are no optical disks found in the system an exception
        will be thrown.

        The function will exclude all optical disks that are mounted ISOs
        as determined by the Test-OpticalDiskCanBeManaged function because
        these should be managed by the DSC_MountImage resource.

    .PARAMETER DiskId
        Specifies the optical disk number for the disk to return the drive
        letter of.
#>
function Get-OpticalDiskDriveLetter
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $DiskId
    )

    $driveLetter = $null
    $deviceId = $null

    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($script:localizedData.UsingGetCimInstanceToFetchDriveLetter -f $DiskId)
        ) -join '' )

    # Get all optical disks in the system that are not mounted ISOs
    $opticalDisks = Get-CimInstance -ClassName Win32_CDROMDrive |
        Where-Object -FilterScript {
            Test-OpticalDiskCanBeManaged -OpticalDisk $_
        }

    if ($opticalDisks)
    {
        <#
            To behave in a similar fashion to the other StorageDsc resources the
            DiskId represents the number of the optical disk in the system.
            However as these are returned as an array of 0..x elements then
            subtract one from the DiskId to get the actual optical disk number
            that is required.
        #>
        $opticalDisk = $opticalDisks[$DiskId - 1]

        if ($opticalDisk)
        {
            try
            {
                # Make sure the current DriveLetter is an actual drive letter
                $driveLetter = Assert-DriveLetterValid -DriveLetter $opticalDisk.Drive -Colon
            }
            catch
            {
                # Optical drive exists but is not mounted to a drive letter
                $driveLetter = ''

                Write-Verbose -Message ( @(
                        "$($MyInvocation.MyCommand): "
                        $($script:localizedData.OpticalDiskNotAssignedDriveLetter -f $DiskId)
                    ) -join '' )
            }

            $deviceId = $opticalDisk.Drive
        }
    }

    if ([System.String]::IsNullOrEmpty($deviceId))
    {
        # The requested optical drive does not exist in the system
        Write-Warning -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($script:localizedData.OpticalDiskDriveDoesNotExist -f $DiskId)
            ) -join '' )
    }

    return @{
        DriveLetter = $driveLetter
        DeviceId    = $deviceId
    }
}

<#
    .SYNOPSIS
        Returns the current drive letter assigned to the optical disk.

    .PARAMETER DiskId
        Specifies the optical disk number for the disk to assign the drive
        letter to.

    .PARAMETER DriveLetter
        Specifies the drive letter to assign to the optical disk. Can be a
        single letter, optionally followed by a colon. This value is ignored
        if Ensure is set to Absent.
#>
function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $DiskId,

        [Parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter
    )

    $ensure = 'Absent'

    # Get the drive letter assigned to the optical disk
    $currentDriveInfo = Get-OpticalDiskDriveLetter -DiskId $DiskId

    if ([System.String]::IsNullOrEmpty($currentDriveInfo.DeviceId))
    {
        $currentDriveLetter = ''
    }
    else
    {
        $currentDriveLetter = $currentDriveInfo.DriveLetter

        if ([System.String]::IsNullOrWhiteSpace($currentDriveLetter))
        {
            Write-Verbose -Message ( @(
                    "$($MyInvocation.MyCommand): "
                    $($script:localizedData.OpticalDiskNotAssignedDriveLetter -f $DiskId)
                ) -join '' )
        }
        else
        {
            Write-Verbose -Message ( @(
                    "$($MyInvocation.MyCommand): "
                    $($script:localizedData.OpticalDiskAssignedDriveLetter -f $DiskId, $DriveLetter)
                ) -join '' )

            $ensure = 'Present'
        }
    }

    $returnValue = @{
        DiskId      = $DiskId
        DriveLetter = $currentDriveLetter
        Ensure      = $ensure
    }

    return $returnValue
} # Get-TargetResource

<#
    .SYNOPSIS
        Sets the drive letter of an optical disk.

    .PARAMETER DiskId
        Specifies the optical disk number for the disk to assign the drive
        letter to.

    .PARAMETER DriveLetter
        Specifies the drive letter to assign to the optical disk. Can be a
        single letter, optionally followed by a colon. This value is ignored
        if Ensure is set to Absent.

    .PARAMETER Ensure
        Determines whether a drive letter should be assigned to the
        optical disk. Defaults to 'Present'.
#>
function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $DiskId,

        [Parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter,

        [Parameter()]
        [ValidateSet('Present', 'Absent')]
        [System.String]
        $Ensure = 'Present'
    )

    # Allow use of drive letter without colon
    $DriveLetter = Assert-DriveLetterValid -DriveLetter $DriveLetter -Colon

    # Get the drive letter assigned to the optical disk
    $currentDriveInfo = Get-OpticalDiskDriveLetter -DiskId $DiskId

    $currentDriveLetter = $currentDriveInfo.DriveLetter

    if ([System.String]::IsNullOrWhiteSpace($currentDriveLetter))
    {
        <#
            If the current drive letter is empty then the volume must be looked up by DeviceId
            The DeviceId in the volume will show as \\?\Volume{bba1802b-e7a1-11e3-824e-806e6f6e6963}\
            So we need to change the currentDriveLetter to match this value when we set the drive letter
        #>
        $deviceId = $currentDriveInfo.DeviceId

        $volume = Get-CimInstance `
            -ClassName Win32_Volume `
            -Filter "DeviceId = '\\\\?\\$deviceId\\'"
    }
    else
    {
        $volume = Get-CimInstance `
            -ClassName Win32_Volume `
            -Filter "DriveLetter = '$currentDriveLetter'"
    }

    # Does the Drive Letter need to be added or removed
    if ($Ensure -eq 'Absent')
    {
        if (-not [System.String]::IsNullOrEmpty($currentDriveInfo.DeviceId))
        {
            Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($script:localizedData.AttemptingToRemoveDriveLetter -f $diskId, $currentDriveLetter)
            ) -join '' )

            $volume | Set-CimInstance -Property @{
                DriveLetter = $null
            }
        }
    }
    else
    {
        Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($script:localizedData.AttemptingToSetDriveLetter -f $diskId, $currentDriveLetter, $DriveLetter)
        ) -join '' )

        $volume | Set-CimInstance -Property @{
            DriveLetter = $DriveLetter
        }
    }
} # Set-TargetResource

<#
    .SYNOPSIS
        Tests the disk letter assigned to an optical disk is correct.

    .PARAMETER DiskId
        Specifies the optical disk number for the disk to assign the drive
        letter to.

    .PARAMETER DriveLetter
        Specifies the drive letter to assign to the optical disk. Can be a
        single letter, optionally followed by a colon. This value is ignored
        if Ensure is set to Absent.

    .PARAMETER Ensure
        Determines whether a drive letter should be assigned to the
        optical disk. Defaults to 'Present'.
#>
function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $DiskId,

        [Parameter(Mandatory = $true)]
        [System.String]
        $DriveLetter,

        [Parameter()]
        [ValidateSet('Present', 'Absent')]
        [System.String]
        $Ensure = 'Present'
    )

    $desiredConfigurationMatch = $true

    # Allow use of drive letter without colon
    $DriveLetter = Assert-DriveLetterValid -DriveLetter $DriveLetter -Colon

    # Get the drive letter assigned to the optical disk
    $currentDriveInfo = Get-OpticalDiskDriveLetter -DiskId $DiskId

    $currentDriveLetter = $currentDriveInfo.DriveLetter

    if ($Ensure -eq 'Absent')
    {
        if (-not [System.String]::IsNullOrEmpty($currentDriveInfo.DeviceId))
        {
            # The Drive Letter should be absent from the optical disk
            if ([System.String]::IsNullOrWhiteSpace($currentDriveLetter))
            {
                Write-Verbose -Message ( @(
                        "$($MyInvocation.MyCommand): "
                        $($script:localizedData.DriveLetterDoesNotExistAndShouldNot -f $DiskId)
                    ) -join '' )
            }
            else
            {
                # The Drive Letter needs to be dismounted
                Write-Verbose -Message ( @(
                        "$($MyInvocation.MyCommand): "
                        $($script:localizedData.DriveLetterExistsButShouldNot -f $DiskId, $currentDriveLetter)
                    ) -join '' )

                $desiredConfigurationMatch = $false
            }
        }
    }
    else
    {
        # Throw an exception if the desired optical disk does not exist
        if ([System.String]::IsNullOrEmpty($currentDriveInfo.DeviceId))
        {
            New-ArgumentException `
                -Message ($script:localizedData.NoOpticalDiskDriveError -f $DiskId) `
                -ArgumentName 'DiskId'
        }

        if ($currentDriveLetter -eq $DriveLetter)
        {
            # The optical disk drive letter is already set correctly
            Write-Verbose -Message ( @(
                    "$($MyInvocation.MyCommand): "
                    $($script:localizedData.DriverLetterExistsAndIsCorrect -f $DiskId, $DriveLetter)
                ) -join '' )
        }
        else
        {
            # Is a desired drive letter already assigned to a different drive?
            $existingVolume = Get-CimInstance `
                -ClassName Win32_Volume `
                -Filter "DriveLetter = '$DriveLetter'"

            if ($existingVolume)
            {
                # The desired drive letter is already assigned to another drive - can't proceed
                New-InvalidOperationException `
                    -Message $($script:localizedData.DriveLetterAssignedToAnotherDrive -f $DriveLetter)
            }
            else
            {
                # The optical drive letter needs to be changed
                Write-Verbose -Message ( @(
                        "$($MyInvocation.MyCommand): "
                        $($script:localizedData.DriverLetterExistsAndIsNotCorrect -f $DiskId, $currentDriveLetter, $DriveLetter)
                    ) -join '' )

                $desiredConfigurationMatch = $false
            }
        }
    }

    return $desiredConfigurationMatch
}

Export-ModuleMember -Function *-TargetResource
