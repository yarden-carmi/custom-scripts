<#
.SYNOPSIS
  Copies a local SSH public key to a remote host's authorized_keys file,
  creating the directory and setting correct permissions.

.DESCRIPTION
  This script provides functionality similar to the Linux 'ssh-copy-id' utility
  for PowerShell users. It reads a local public key and appends it to the
  ~/.ssh/authorized_keys file on a remote server.

  It automatically handles:
  - Creating the ~/.ssh directory if it doesn't exist.
  - Setting the directory permissions to 700.
  - Setting the authorized_keys file permissions to 600.

.PARAMETER RemoteHost
  The remote host to copy the key to, in 'user@hostname' format.
  This parameter is mandatory and positional.

.PARAMETER KeyFile
  The path to the local public key file.
  Defaults to '$env:USERPROFILE\.ssh\id_rsa.pub'.

.EXAMPLE
  .\ssh-copy-id.ps1 user@remote-server.com

.EXAMPLE
  .\ssh-copy-id.ps1 -RemoteHost user@192.168.1.100

.EXAMPLE
  .\ssh-copy-id.ps1 user@server -KeyFile C:\Users\yarde\.ssh\my_other_key.pub
#>
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$RemoteHost,

    [Parameter(Mandatory = $false)]
    [string]$KeyFile = "$env:USERPROFILE\.ssh\id_rsa.pub"
)

# 1. Check if the local public key file exists
if (-not (Test-Path $KeyFile)) {
    Write-Error "Public key file not found at: $KeyFile"
    Write-Error "Please generate a key pair using 'ssh-keygen' or specify the correct path using -KeyFile."
    return
}

# 2. Define the remote command to be executed
#    - mkdir -p ~/.ssh: Creates the .ssh directory if it doesn't exist.
#    - chmod 700 ~/.ssh: Sets directory permissions to rwx------ (only owner).
#    - cat >> ~/.ssh/authorized_keys: Appends stdin (the key) to the file.
#    - chmod 600 ~/.ssh/authorized_keys: Sets file permissions to rw------- (only owner).
$remoteCommand = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# 3. Read the key and pipe it to the SSH command
try {
    Write-Host "Attempting to copy public key from $KeyFile to $RemoteHost..."
    Write-Host "You will be prompted for the password for $RemoteHost."

    Get-Content $KeyFile | ssh $RemoteHost $remoteCommand

    Write-Host ""
    Write-Host "****************************************************************"
    Write-Host "Success! Key copied and permissions set on $RemoteHost."
    Write-Host "You should now be able to log in without a password."
    Write-Host "Try: ssh $RemoteHost"
    Write-Host "****************************************************************"
}
catch {
    Write-Error "An error occurred during the SSH operation."
    Write-Error $_
}