# Beginner installation guide

This is written for someone who has never managed a server before. You only
need to know how to create an Ubuntu virtual server, open its terminal, and
paste a command.

> Cloud servers can cost money. If you are under 18, ask a parent or guardian
> before creating one, entering payment details, or changing a home router.

You do **not** need to install OpenRCT2, Python, a database or a web server.

## 1. Create the server

Choose Ubuntu Server 24.04 and at least 1 GB RAM. In AWS Lightsail, create an
Ubuntu instance and give it a **static IP**. The public IP looks like four
numbers separated by dots, for example `203.0.113.10`. It is the server's
internet address.

## 2. Paste one installation command

Open the server's browser terminal. Copy this whole command, paste it into the
black terminal window, and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/SharpyUK08/openrct2-server-manager/main/outputs/install-openrct2-manager.sh -o /tmp/openrct2-manager-install.sh && sudo bash /tmp/openrct2-manager-install.sh
```

It may take several minutes and print lots of text. That is normal. Do not close
the window. When it finishes, look for `OpenRCT2 Server Manager is ready` and
save the numbered `NEXT STEP` section and one-time password.

## 3. Allow OpenRCT2 players to connect

The server has numbered internet “doors” called ports. Players need door
**11753** opened. The website and private control doors must stay closed.

For AWS Lightsail:

1. Go back to the Lightsail page showing your server.
2. Choose **Networking**.
3. Under **IPv4 Firewall**, choose **Add rule**.
4. Choose **Custom**, then **TCP**, and enter `11753`.
5. Save the rule.

For other hosting:

- **AWS EC2:** Security Groups → the instance's group → Edit inbound rules →
  Custom TCP, port 11753.
- **Azure, Google Cloud or another VPS:** find the VM's Firewall, Network,
  Security Group or Inbound Rules and allow TCP 11753.
- **A server at home:** forward TCP 11753 in the router to the Ubuntu machine's
  private LAN address. Also allow TCP 11753 in Ubuntu's firewall if enabled.

Do not add a UDP rule. Do not open ports 11754, 11755 or 8080 to everyone.

## 4. Open the private setup page

The setup website is private at first. On your own computer—not inside the AWS
terminal—open Terminal on macOS/Linux or PowerShell on Windows and paste the
command printed by the installer. It looks like:

```bash
ssh -L 8080:127.0.0.1:8080 ubuntu@YOUR_SERVER_IP
```

Keep that window open. In Chrome, visit <http://127.0.0.1:8080/>. Enter the
one-time password and follow the five short setup sections. You will choose a
new permanent password here.

## 5. Optional domain and HTTPS

You can skip this during first setup. If you own a domain later, the browser
guide explains how to point it at the server and create secure HTTPS access.
It will give you one command like:

```bash
sudo openrct2-manager-enable-https parks.example.com
```

After HTTPS works, leave ports 8080, 11754 and 11755 closed publicly. Only TCP
11753 for the game and TCP 80/443 for the manager should be internet-facing.

## 6. Upload and launch a park

Sign into the website, choose **Scenarios**, upload a saved park or scenario,
and choose **Launch**. The game server intentionally stays off until you do
this. Your friends then connect to the `Game address` printed by the installer.

## If something goes wrong

Do not delete the server and start again. Copy the last 30 lines from the black
terminal window and include them when asking for help. Running the same install
command again is safe: it keeps existing settings and saved parks.
