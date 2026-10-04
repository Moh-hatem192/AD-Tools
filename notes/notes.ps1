# Open HTTP Server
\webserver.ps1 <specify port if needed>

# unzip
Expand-Archive -Path ~\Desktop\BloodHound.zip -DestinationPath ~\Desktop\BloodHound

# Disable Defender and Firewall
Get-MpComputerStatus
Set-MpPreference -DisableRealtimeMonitoring $true
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

