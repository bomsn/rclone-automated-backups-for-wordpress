## Rclone Automated Backups for WordPress

Automate WordPress backups to various cloud storage providers using rclone automation. Also supports `restic` for incremental backups using rclone.

![Screenshot](/screenshot.png)

## Requirements
- Sudo and SSH access to your server.
- [wp-cli](https://wp-cli.org/) installed.
- [rclone](https://rclone.org/) installed.

## Optional
- [restic](https://restic.readthedocs.io/en/stable/020_installation.html) to add incremental backup support ( no setup or configuration needed ).

## Getting Started

Follow these steps to set up automated WordPress backups:

### How to use:
- Connect to your server via SSH: `ssh root@server.ip.address`
- Download this repo zip file:

```shell
apt-get -y install wget git
git clone https://github.com/bomsn/rclone-automated-backups-for-wordpress.git rclone-wordpress
```
- Run the initilization script

```shell
cd rclone-wordpress
sudo bash config.sh
```  

You'll have options to add domains and configure backups. 

The script will guide you through the process, just make sure to add sites/domains and their correct path, add backup configurations such as backup time, frequency, retention period, and configure rclone remote(s), then create your backups.

**Note:** the domains and associated paths will be saved to `definitions` file, you can change it later if needed. However, note that changing the file doesn't change any running backups.

That's it, once you've completed all the configuration steps, a cron job will be created to take backups automatically using rclone. Feel free to use the menu again to make as many automated backups as you want.

### Subsequent Use:

If you want to add more websites, create additional backups, disable or delete existing backups, or even restore the remote backups created by the script, just run the config script again `sudo bash config.sh` and use the available options.
