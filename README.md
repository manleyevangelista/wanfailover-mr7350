# Automatic WAN Failover for Linksys MR7350 (OpenWRT)

## Disclaimer

I have tried this on my router, and currently using it in production. I currently take online classes and needed a reliable internet connection, hence the reason I use this script. 

While I believe this shouldn't harm anything, I am not responsible if anything happens to you or any of your equipment as result of using this script. Use this at your own risk. 

I have partially used artificial intelligence (AI) to help me tailor **kekneus373**'s `mwan-diy` script for my Linksys MR7350, as  programming is not my strongest skill. Aside from that, parts of the script and configurations were tweaked by hand. The actual network administration and testing were also done by hand as well. 

## Introduction

Based on **kekneus373's** [mwan-diy](https://github.com/kekneus373/mwan-diy) script. Renamed to **wanfailover-mr7350**, and tailored for Linksys MR7350 router.

For the uninitiated, to get WAN failover on OpenWRT is to use mwan3. However, its latest release is not compatible with newer version of OpenWRT (25.12.x) as they are using nftables instead of iptables, which older OpenWRT version use and what mwan3 depends on. Now, there is an unofficial version of mwan3 works with nftables. While it works, in my experience it does not get along with Tailscale, which what I use to access my home network from a remote location. 

I wanted reliable WAN failover that works with Tailscale. After a bit of searching on Google, I came across [kekneus373](https://github.com/kekneus373)'s script. Once I confirmed that works for me, I had tailored this script for my router with AI assistance. 

This does not have any dependencies from mwan3. 

For the description of this script, I will simply quote kekneus373. As this script is based from **mwan-diy**. 

>This is a lightweight shell script that monitors your primary WAN interface and automatically fails over to a backup WAN when things go sideways. It was built out of necessity:  mwan3  [*"needs to be migrated/refactored to use nftables"*](https://forum.openwrt.org/t/mwan3-compatibility-in-openwrt-24-10/219952/2) for newer OpenWRT releases and isn't reliable in the meantime. This script fills that gap with no frills, no bloat, and no 800-line Lua packages.

Tested this on my Linksys MR7350 router with Tailscale installed, and one of its LAN ports repurposed as a secondary WAN.

----------

##  What it does

-   Monitors a primary WAN (`wan`) and fails over to a secondary WAN (`lan4`)
-   Health checks via ICMP ping to multiple targets (Google, Cloudflare, Cisco)
-   **Requires failover after one failure:** Switches to backup as soon as the primary WAN is offline. Though this could be tweaked with higher number if flapping is an issue
-   Cycles the secondary WAN (`lan4`) using `ifdown` and `ifup` to ensure successful failover
-   Changes the router's LED, depending on the state of the failover. Can be tweaked to use different colors. (`Turquoise` = primary WAN, `Green` = secondary WAN, `Red` = both offline)
-   **Cooldown period**  after failover to prevent bouncing between links
-   Automatically  **restores the primary**  when it recovers
-   Detects and fixes UCI-disabled interfaces on the fly
-   Logs everything to  `/var/log/wanfailover-mr7350.log`  with built-in rotation
-   Runs as a proper  `procd`  service (auto-restart, clean shutdown)

##  Requirements

-   OpenWRT
-   `bash`  (`apk -U add bash`) - the script's base
-   `jq`  (`apk -U add jq`) - extracts the default route from any of 2 WANs ([even inactive](https://gist.github.com/kekneus373/96b0b0153dc598d7faad3b5250e0def0))
-   Root access (the script checks for this)
-   Two WAN interfaces configured in  `/etc/config/network`

## Configuring secondary WAN

By default, the Linksys MR7350 only has one designated WAN port. However, we could repurpose one of the LAN ports to serve as secondary WAN. 

These are the steps for OpenWRT 25.12.x (25.12.6). Steps may differ on future versions. 

1. Go to: **Network** > **Devices** > **Devices** > **configure...** (br-lan)
2. Remove `LAN 4` from **Bridge Ports**, then hit **Save**
3. Click **Add device configuration...**
4. Device Type: `VLAN (802.1q)`. Hit save
5. Click **Save and Apply**
6. Go to: **Network** > **Interfaces**
7. Click **Add new interface...**
8. Name: `lan4`, Protocol: `DHCP client`, Device: `lan4`
8. Click **Add new interface...**
9. Name: `lan46`, Protocol: `DHCPv6 client`, Device: `lan4`
10. For both `lan4` and `lan46` go to: **Edit** > **Firewall Settings** > **Create/Assign firewall-zone**: `wan`. Click **Save**
11. Click **Save and Apply**. Then reboot router 

**Note: You may substitute a different LAN port (such as LAN1, LAN2, or LAN 3). I had chosen `LAN4` because it is adjacent to the WAN port. Just make sure to name your interfaces accordingly (LAN4 or LAN46 to LAN1 or LAN16). 

You may also name the interface to anything you want (like WAN2, WANB, etc). For simplicity sake, I named it `LAN4`. Just ensure that the interface names and the configuration reflects that. 

##  Installing Prerequisites. 

This script requires **bash** (what is used to run this script), and **jq** (deals with routing table from both WANs). Here's how to install them.

Access the router via **SSH** using Terminal (Windows 11, macOS, Linux), then type these commands.

1. `apk upgrade` (updates packages)
2. `apk -U add bash` (installs **bash**)
3. `apk -U add jq` (installs **jq**)

## Installing the script. 

Log-out of SSH by typing `exit`. Then, while staying on Terminal, copy these files. 

1. `scp <path to: wanfailover_monitor.sh> <username>@<MR7350's IP>:/etc/"`
2. `scp <path to: wanfailover-mr7350 <username>@<MR7350's IP>:/etc/init.d/"`

**FOR EXAMPLE:** If your router's login is `root` and its IP address is `192.168.1.1`, then your commands should look like this.

1. `scp <path to: wanfailover_monitor.sh root>@192.268.1.1:/etc/"`
2. `scp <path to: wanfailover-mr7350 root@192.168.1.1:/etc/init.d/"`

Log-in to SSH again, then execute these commands.

1. `chown root /etc/wanfailover_monitor.sh` (**wanfailover_monitor.sh** - sets root as owner to)
2. `chown root /etc/init.d/wanfailover-mr7350` (**wanfailover-mr7350** - sets root as owner to)
3. `chmod 755 /etc/wanfailover_monitor.sh` (**wanfailover_monitor.sh** - sets read, write, and execute to owner only. Read and execute only for others)
4. `chmod 755 /etc/init.d/wanfailover-mr7350` (**wanfailover-mr7350** - sets read, write, and execute to owner only. Read and execute only for others)

Append **sysupgrade.conf** to preserve script when upgrading OpenWRT.

1. Type: `vi /etc/sysupgrade.conf`
2. Press **I** on keyboard
3. Type: `/etc/wanfailover_monitor.sh`
4. Press **ENTER** to start a new line
5. Type: `/etc/init.d/wanfailover-mr7350`
6. Press **ESC** on keyboard
7. Type `:wq` on keyboard to save and quit

Start and verify the script.

1. `/etc/init.d/wanfailover-mr7350 start` (executes the script)
2. `/etc/init.d/wanfailover-mr7350 status` (verifies that the script is running)

Enable script on boot-up. 

1. `service wanfailover-mr7350 enable`

After that, reboot the router to verify that it works. Try to simulate a WAN failure (by unplugging or turning off WAN source) to test the script in practice. The router's LED light should change accordingly. 


## Configuration

1. In SSH, type: `vi /etc/wanfailover_monitor.sh`
2. Press **I** on keyboard
3. Edit the configuration
4. When done, press **ESC** on keyboard
5. Type: `:wq` to save and quit

```
PRIORITY_WAN="wan"							# Preferred gateway
BACKUP_WAN="lan4"							# Fallback
INTERFACE_NAME_PRIMARY="wan"						# Logical name in /etc/config/network
INTERFACE_NAME_BACKUP="lan4"     					# Logical name in /etc/config/network
PING_TARGETS="8.8.8.8 1.1.1.1 208.67.222.222"				# Google, Cloudflare, Cisco
RETRIES_PER_TARGET=1							# Maximum ping retry count
CONSECUTIVE_FAILURES_REQUIRED=1						# Failed cycles count to trigger fallback
CHECK_INTERVAL=30							# Between full cycles
COOLDOWN_AFTER_FAILOVER=30						# Prevent flapping
INITIAL_DELAY=10							# Let DHCP settle at boot
LOG_FILE="/var/log/wanfailover-mr7350.log"				# Current logfile
MAX_LOG_SIZE_KB=1500							# Rotate when exceeding this size

# RGB status LED: turquoise = WAN, green = LAN4, red = no confirmed connection
set_status_led() {
    local color="$1"
    local led_dir="/sys/class/leds"
    local channel

    for channel in red green blue; do
        [ -e "$led_dir/$channel:status/trigger" ] || return 0
    done

    for channel in red green blue; do
        echo none > "$led_dir/$channel:status/trigger"
        echo 0 > "$led_dir/$channel:status/brightness"
    done

    case "$color" in
        turquoise)
            echo 255 > "$led_dir/green:status/brightness"
            echo 255 > "$led_dir/blue:status/brightness"
            ;;
        green)
            echo 255 > "$led_dir/green:status/brightness"
            ;;
        red)
            echo 255 > "$led_dir/red:status/brightness"
            ;;
    esac
}
```

**NOTE:** If you used the steps earlier to repurpose a LAN port as a secondary WAN, then you do not need to change the interface names. Though feel free to change the other settings. Especially the LED colors if you want different colors.

I had poked around the system files to locate the file that's responsible for controlling the LEDS, then experimented with it to see what other colors the router could produce. Though feel free to play around with the value to experiment with other colors, as there might be many more other color combinations listed below. 

**Off**

```
echo 0 > "$led_dir/blue:status/brightness"
echo 0 > "$led_dir/green:status/brightness"
echo 0 > "$led_dir/red:status/brightness"
```

**Blue**

```
echo 255 > "$led_dir/blue:status/brightness"
echo 0 > "$led_dir/green:status/brightness"
echo 0 > "$led_dir/red:status/brightness"
```

**Green**

```
echo 0 > "$led_dir/blue:status/brightness"
echo 255 > "$led_dir/green:status/brightness"
echo 0 > "$led_dir/red:status/brightness"
```

**Red**

```
echo 255 > "$led_dir/blue:status/brightness"
echo 0 > "$led_dir/green:status/brightness"
echo 0 > "$led_dir/red:status/brightness"
```

**Yellow**

```
echo 0 > "$led_dir/blue:status/brightness"
echo 255 > "$led_dir/green:status/brightness"
echo 255 > "$led_dir/red:status/brightness"
```

**Pink**

```
echo 255 > "$led_dir/blue:status/brightness"
echo 0 > "$led_dir/green:status/brightness"
echo 255 > "$led_dir/red:status/brightness"
```

**Turquoise or Light Blue**

```
echo 255 > "$led_dir/blue:status/brightness"
echo 255 > "$led_dir/green:status/brightness"
echo 0 > "$led_dir/red:status/brightness"
```

**White or Light Pink**

```
echo 255 > "$led_dir/blue:status/brightness"
echo 255 > "$led_dir/green:status/brightness"
echo 255 > "$led_dir/red:status/brightness"
```

## Uninstall

If you no longer require or want this, you may uninstall it using these commands through ssh. 

Stop and disable **wanfailover-mr7350**.

`service wanfailover-mr7350 stop` (stops the script)
`service wanfailover-mr7350 disable` (disables the service)
`rm /etc/wanfailover_monitor.sh` (removes **wanfailover_monitor.sh**)
`rm /etc/init.d/wanfailover-mr7350` (removes **wanfailover-mr7350**)

Edit **sysuprade.conf** to remove lines that preserves wanfailover-mr7350 when upgrading OpenWRT.

1. Type: `vi /etc/sysupgrade.conf`
2. Press **I** on keyboard
3. Remove both '/etc/multi_wan_failover.sh` and `/etc/init.d/wanfailover-mr7350`
4. Press **ESC** on keyboard
5. Type: `:wq` to save and quit

**Optional:** Remove **bash** and **jq**, if you are sure nothing else uses it on your router.

1. `apk del bash` (removes bash)
2. `apk del jq` (removes jq)

**Optional:** Revert the secondary WAN as LAN again.

1. In OpenWRT, go to: **Network** > **Interfaces**
2. Click **Delete** on both `lan4` and `lan46`
3. Go to: **Network** > **Devices**
4. Click **Unconfigure** on `lan4.10` or LAN4 VLAN
5. Click **Configure...** on `br-lan`
6. In **Bridge ports**, add `lan4`. Click Save
7. Click **Save & Apply**. 

Last but not least, reboot the router. 

The service auto-restarts on crash thanks to  `procd respawn`. Default respawn settings are 5s timeout, 5 retries, 3600s threshold — tweak in  `/etc/init.d/wanfailover-mr7350`  if you want different behavior.

## Logs

Watch live logs
`tail -f /var/log/wanfailover-mr7350.log`

Or check syslog for startup/shutdown events
`logread -e wanfailover-mr7350`

Logs auto-rotate at 1.5MB with 3 backup copies kept (`.1`,  `.2`,  `.3`).

## Limitations

-   **Two WAN interfaces only**  (primary + backup). No 3+ WAN chaining. 
-   **ICMP-based health checks**  — won't detect application-layer issues (e.g., DNS works but HTTP is blocked upstream).
-   **Route-based failover**  — uses  `ip route replace`  for the default route. If your OpenWRT setup uses policy routing,  `mptcp`, or other advanced routing configs, you may need to adapt the failover logic.
-   Tested on OpenWRT with  `bash`  installed. BusyBox  `ash`  **won't work**  due to bashisms (`(( ))`,  `local`, arrays-ish behavior). Install bash.

## Troubleshooting

**Service won't start:**  Ensure that both `/etc/wanfailover_monitor.sh` and '/etc/init.d/wanfailover-mr7350' has the correct owner and permissions. In SSH.

1. Type: `ls -l /etc/`
2. Verify that `wanfailover_monitor.sh` permissions and owner are correct:
  
``` 
-rwxr-xr-x    1 root     root         14608 Nov 11 17:52 wanfailover_monitor.sh
```

6. Type: `ls -l /etc/init.d`
7. Verify that `wanfailover-mr7350.sh` permissions and owner are correct:

```
-rwxr-xr-x    1 root     root           649 Nov 11 17:52 wanfailover-mr7350`
```

7. If any is incorrect, then please refer to **Installing the script** section of this document

**Failover doesn't trigger:**  Tail the log:  `tail -f /var/log/wanfailover-mr7350.log`. Look for the connectivity check messages. Make sure your  `PING_TARGETS`  aren't being blocked by your ISP or firewall.

**Route replacement fails:**  The script pulls gateway info from  `ifstatus <interface>`. Make sure your backup WAN interface actually gets a gateway assigned by your modem/DHCP. Run  `ifstatus lan4 | jq .`  to verify.

**Both WANs show as down:**  Either your internet is actually dead on both lines, or the  `PING_TARGETS`  are being blocked. Try replacing them with IPs you know respond (your ISP's DNS, for example).

## License

Do whatever you want with this. Feel free to adapt this to other models, like I did with my Linksys MR7350. Attribution would be appreciated. 
