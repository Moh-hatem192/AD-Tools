# Open HTTP Server
\webserver.ps1 <specify port if needed>

# unzip
Expand-Archive -Path ~\Desktop\BloodHound.zip -DestinationPath ~\Desktop\BloodHound

# Disable Defender and Firewall
Get-MpComputerStatus
Set-MpPreference -DisableRealtimeMonitoring $true
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Time Sync with DC from linux
sudo timedatectl set-ntp off
sudo ntpdate -u $DC_IP
#if didn't work try
or 
sudo rdate -n $DC_IP

