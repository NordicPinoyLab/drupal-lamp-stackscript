#!/bin/bash

# <UDF name="hostname" Label="Linode's Hostname" example="This is the first part of the Fully Qualified Domain Name. e.g. examplehost" />
# <UDF name="fqdn_domain" Label="Domain for FQDN" example="The last part of the Fully Qualified Domain Name" />
# <UDF name="timezone" Label="Time zone" example="e.g. Europe/Oslo />
# <UDF name="ssuser" Label="New limited user" example="username" />
# <UDF name="sspassword" Label="Limited user's password" example="Password" />
# <UDF name="pubkey" Label="Paste your SSH public key" />

# <UDF name="db_name" Label="Database Name" />
# <UDF name="db_user" Label="New user for the database" />
# <UDF name="db_password" Label="Password for the new database user" />

# <UDF name="project_dir" label="Project directory" default="drupal-project" example="The parent directory of your Drupal documentroot, where composer.json and vendors will be installed. Defaults to 'drupal-project'" />
# <UDF name="drupal_dir" label="Drupal root directory" default="web" example="Define Drupal's public directory. E.g. public_html Defaults to 'web'" />

# <UDF name="domain" Label="Domain" example="Domain for the Drupal website" />
# <UDF name="drupal_admin" label="Drupal admin username" />
# <UDF name="drupal_password" label="Drupal admin password" />
# <UDF name="email" label="Drupal admin account's e-mail" />
# <UDF name="drupal_sitename" label="Drupal Site Name" />
# <UDF name="drupal_sitemail" label="Drupal Site E-mail" example="From: for system mailings. eg. admin@example.com" />
# <UDF name="drupal_locale" label="Drupal Default Language" default="en" example="Language code. Defaults to en(English)." />


#### SYSTEM UPGRADE ###########################################################
apt-get -o Acquire::ForceIPv4=true update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

#### SET HOSTNAME AND FULLY QUALIFIED DOMAIN ##################################
IPV4=$(hostname -I | cut -d ' ' -f 1)
IPV6=$(hostname -I | cut -d ' ' -f 2)
FQDN=${HOSTNAME}.${FQDN_DOMAIN}
echo "Setting up hostname to ${HOSTNAME} and Fully Qualified Domain Name to ${FQDN}"
hostnamectl set-hostname "${HOSTNAME}"
echo "${IPV4}" "${FQDN}" "${HOSTNAME}" >> /etc/hosts
echo "${IPV6}" "${FQDN}" "${HOSTNAME}" >> /etc/hosts
hostname -f

#### SET TIMEZONE #############################################################
echo "Setting up the timezone to \"${TIMEZONE}\""
timedatectl set-timezone "${TIMEZONE}"
date

###############################################################################
###################### SETTING UP A SECURE INSTALLATION #######################
###############################################################################

#### ADD LIMITED USER, THEN ADD USER TO SUDO ##################################
echo "Adding new user \"${SSUSER}\" with sudo privileges"
adduser "${SSUSER}" --disabled-password --gecos "" && \
echo "${SSUSER}:${SSPASSWORD}" | chpasswd
adduser "${SSUSER}" sudo >/dev/null


#### ADD PUBKEY FOR USER ######################################################
echo "Adding SSH public key for ${SSUSER}."
mkdir -p /home/"${SSUSER}"/.ssh
chmod -R 700 /home/"${SSUSER}"/.ssh/
echo "${PUBKEY}" >> /home/"${SSUSER}"/.ssh/authorized_keys
chmod 600 /home/"${SSUSER}"/.ssh/authorized_keys
chown -R "${SSUSER}":"${SSUSER}" /home/"${SSUSER}"/.ssh


#### INSTALL UFW AND CONFIGURE BASIC RULES ####################################
echo "Setting up Uncomplicated firewall (ufw)..."
DEBIAN_FRONTEND=noninteractive apt-get -y install ufw
sed -i -e "s/IPV6=no/IPV6=yes/" /etc/default/ufw
sed -i -e "s/#IPV6=yes/IPV6=yes/" /etc/default/ufw
ufw default allow outgoing
ufw default deny incoming
ufw allow ssh
ufw allow http
ufw allow https
ufw enable
ufw version
ufw status verbose


#### INSTALL AND CONFIGURE FAIL2BAN ###########################################
echo "Setting up Fail2ban..."
DEBIAN_FRONTEND=noninteractive apt-get -y install fail2ban
cd /etc/fail2ban || exit
cp fail2ban.conf fail2ban.local
cp jail.conf jail.local
service fail2ban start
service fail2ban status


#### DISABLE ROOT SSH ACCESS ##################################################
echo "Disabling SSH root access..."
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i -e "s/#PermitRootLogin no/PermitRootLogin no/" /etc/ssh/sshd_config


#### DISABLE SSH PASSWORD AUTH ################################################
echo "Disabling SSH password authentication..."
sed -i -e "s/PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i -e "s/#PasswordAuthentication no/PasswordAuthentication no/" /etc/ssh/sshd_config


#### ENABLE SUDO WITHOUT PASSWORD #############################################
echo "Enabling sudo without password..."
echo "${SSUSER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers


###############################################################################
############################# LAMP INSTALLATION ###############################
###############################################################################
echo "Starting LAMP installation..."

#### INSTALL APACHE ###########################################################
echo "Installing and configuring Apache..."
DEBIAN_FRONTEND=noninteractive apt-get -y install apache2

# Initial configuration of apache
sed -ie "s/KeepAlive Off/KeepAlive On/g" /etc/apache2/apache2.conf
cat <<END >/etc/apache2/conf-available/httpoxy.conf
<IfModule mod_headers.c>
	RequestHeader unset Proxy early
</IfModule>

END
a2enmod rewrite http2 ssl headers expires
a2enconf httpoxy
systemctl restart apache2
apache2 -v

# Configure vhost file
cp /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/"${DOMAIN}".conf
echo "Setting up virtualhost file for ${DOMAIN}"
cat <<END >"/etc/apache2/sites-available/${DOMAIN}.conf"
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    ServerAdmin sysadmin@${FQDN}
    
    DocumentRoot /var/www/webapps/${DOMAIN}/${PROJECT_DIR}/${DRUPAL_DIR}
    
    <Directory />
        AllowOverride All
    </Directory>
    <Directory /var/www/webapps/${DOMAIN}/${PROJECT_DIR}/${DRUPAL_DIR}>
        Options FollowSymLinks
        AllowOverride All
    </Directory>
    
    ErrorLog /var/www/webapps/${DOMAIN}/logs/error.log
    CustomLog /var/www/webapps/${DOMAIN}/logs/access.log combined
</VirtualHost>
END

# Configure default for error checking.
cat <<END >/etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
    
    ServerAdmin ${EMAIL}    
    DocumentRoot /var/www/html
    
    <Directory />
        AllowOverride All
    </Directory>
    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
    </Directory>
    
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
END

# Create necessary directories so Apache does not complain.
mkdir -p /var/www/webapps/"${DOMAIN}"/{logs,"${PROJECT_DIR}/${DRUPAL_DIR}"}
# Create variable for Drupal root
DRUPALROOT=/var/www/webapps/"${DOMAIN}/${PROJECT_DIR}/${DRUPAL_DIR}"
PROJECTROOT=/var/www/webapps/"${DOMAIN}/${PROJECT_DIR}"
# Add user to the apache group
adduser "${SSUSER}" www-data
# Give user the permissions for /var/www and make it stick.
chown -R  "${SSUSER}":www-data /var/www; chmod -R g+rw /var/www/; find /var/www -type d -print0 | xargs -0 chmod g+s

# Enable virtualhost and restart apache
a2ensite "${DOMAIN}.conf"
systemctl restart apache2


#### INSTALL MARIADB ##########################################################
echo "Installing and configuring MariaDB..."
DEBIAN_FRONTEND=noninteractive apt-get -y install mariadb-server expect
systemctl enable mariadb
systemctl start mariadb
SECURE_MYSQL=$(expect -c "
set timeout 10
spawn mysql_secure_installation
expect \"Enter current password for root (enter for none)\"
send \"\r\"
expect \"Switch to unix_socket authentication\"
send \"n\r\"
expect \"Change the root password?\"
send \"n\r\"
expect \"Remove anonymous users?\"
send \"Y\r\"
expect \"Disallow root login remotely?\"
send \"Y\r\"
expect \"Remove test database and access to it?\"
send \"Y\r\"
expect \"Reload privilege tables now?\"
send \"Y\r\"
expect eof
")
echo "${SECURE_MYSQL}"

# Create new user with admin privileges
echo "Creating and giving admin privileges to ${DB_USER}..."
mysql -e "GRANT ALL ON *.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}' WITH GRANT OPTION;";
mysql -e "FLUSH PRIVILEGES;"

# Create Drupal Database
echo "Creating new database ${DB_NAME} for ${DB_USER}..."
mysql -u"${DB_USER}" -p"${DB_PASSWORD}" -e "CREATE DATABASE ${DB_NAME};"
mysql -V


#### INSTALL PHP ##############################################################
echo "Installing and configuring PHP..."
DEBIAN_FRONTEND=noninteractive apt-get install php8.3 php-pear php8.3-curl php8.3-fpm php8.3-gd php8.3-intl php8.3-memcached php8.3-mbstring php8.3-mysql php8.3-uploadprogress php8.3-xml php8.3-xmlrpc php8.3-zip unzip zip memcached

# Use mpm_event with php-fpm
a2dismod php8.3 mpm_prefork
a2enmod proxy_fcgi setenvif mpm_event
a2enconf php8.3-fpm
phpenmod opcache
sed -i 's/pm.max_children = 5/pm.max_children = 10/g' /etc/php/8.3/fpm/pool.d/www.conf
sed -i 's/pm.start_servers = 2/pm.start_servers = 3/g' /etc/php/8.3/fpm/pool.d/www.conf
sed -i 's/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g' /etc/php/8.3/fpm/pool.d/www.conf
sed -i 's/pm.max_spare_servers = 3/pm.max_spare_servers = 5/g' /etc/php/8.3/fpm/pool.d/www.conf
sed -i 's/;pm.max_requests = 500/pm.max_requests = 500/g' /etc/php/8.3/fpm/pool.d/www.conf

sed -i 's/max_execution_time = 30/max_execution_time = 600/g' /etc/php/8.3/fpm/php.ini
sed -i 's/max_input_time = 60/max_input_time = 1000/g' /etc/php/8.3/fpm/php.ini
sed -i 's/;max_input_vars = 1000/max_input_vars = 10000/g' /etc/php/8.3/fpm/php.ini
sed -i 's/memory_limit = 128M/memory_limit = 512M/g' /etc/php/8.3/fpm/php.ini
sed -i 's+;error_log = syslog+error_log = /var/log/php/error.log+g' /etc/php/8.3/fpm/php.ini
sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 128M/g' /etc/php/8.3/fpm/php.ini
sed -i 's/post_max_size = 8M/post_max_size = 128M/g' /etc/php/8.3/fpm/php.ini
# Create the log file we defined in the php.ini file
mkdir /var/log/php
chown www-data /var/log/php
# Restart apache anf php-fpm
systemctl restart apache2
systemctl restart php8.3-fpm
systemctl status php8.3-fpm


###############################################################################
#################### COMPOSER, DRUSH AND DRUPAL INSTALLATIONS #################
###############################################################################

#### INSTALL COMPOSER, DRUSH AND DRUPAL USING USER ############################
echo "Installing Composer, Drush and Drupal..."

# We need to delete the project directory first or else composer will complain
rm -rf "/var/www/webapps/${DOMAIN}/${PROJECT_DIR}"

cd "/home/${SSUSER}/" || exit
cat <<END >/home/"${SSUSER}"/install-composer-drush-drupal.sh
#!/bin/bash

# Install Composer
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php composer-setup.php --quiet
rm composer-setup.php
sudo mv composer.phar /usr/local/bin/composer
echo "Composer is installed!"

# Install Drupal
cd /var/www/webapps/${DOMAIN}
echo "Directory changed to /var/www/webapps/${DOMAIN}"
composer create-project --no-install drupal/recommended-project ${PROJECT_DIR}

cd /var/www/webapps/${DOMAIN}/${PROJECT_DIR}
# Replace web directory to user-defined ${DRUPAL_DIR} directory
sed -i 's+"web/+"${DRUPAL_DIR}/+g' composer.json

# Install Drush and additional contrib modules
composer require drush/drush drupal/memcache

# Create necessary directories for Drupal and fix their permissions.
mkdir $DRUPALROOT/sites/default/files
chmod a+w $DRUPALROOT/sites/default/files
cp $DRUPALROOT/sites/default/default.settings.php $DRUPALROOT/sites/default/settings.php
chmod a+w $DRUPALROOT/sites/default/settings.php

# Add here add drush to path in .bashrc
cat <<EOF >> /home/${SSUSER}/.bashrc

export PATH="./vendor/bin:drush_path"
EOF

sed -i 's/drush_path/\$PATH/g' /home/${SSUSER}/.bashrc

# Install Drupal using Drush
cd $PROJECTROOT/
drush site-install \
--db-url="mysql://${DB_USER}:${DB_PASSWORD}@localhost:3306/${DB_NAME}" \
--account-name="${DRUPAL_ADMIN}" \
--account-pass="${DRUPAL_PASSWORD}" \
--account-mail="${EMAIL}" \
--site-name="${DRUPAL_SITENAME}" \
--site-mail="${DRUPAL_SITEMAIL}" \
--locale="${DRUPAL_LOCALE}" -y

# Enable the Drupal modules
drush en -y memcache memcache_admin

# Set trusted hosts -- this will show a warning in Drupal if it is not set.
echo "Adding trusted hosts and memcache configuration in settings.php"
chmod a+w $DRUPALROOT/sites/default/settings.php
cat <<EOF >> $DRUPALROOT/sites/default/settings.php

drupal_settings['trusted_host_patterns'] = array(
   '^${DOMAIN//\./\\.}$',
   '^www\.${DOMAIN//\./\\.}$',
   '^${IPV4//\./\\.}$',
 );

 // Memcache module
 drupal_settings['cache']['default'] = 'cache.backend.memcache';
 drupal_settings['cache']['bins']['render'] = 'cache.backend.memcache';

EOF

chmod a+w $DRUPALROOT/sites/default $DRUPALROOT/sites/default/settings.php
sed -i 's/drupal_settings/\$settings/g' $DRUPALROOT/sites/default/settings.php
chmod a-w $DRUPALROOT/sites/default/settings.php $DRUPALROOT/sites/default

### INSTALL ACME.SH ###########################################################
cd /home/${SSUSER}/
wget -O - https://get.acme.sh | sh -s email=${EMAIL}

#### Create welcome message in .bash_profile of user
cat <<END >/home/${SSUSER}/.bash_profile

echo ""
echo ""
echo ""
echo "Congratulations ${SSUSER}!"
echo "You have just installed the latest version of Drupal for ${DOMAIN}."
echo ""
echo "You may now visit your site at http://www.${DOMAIN}"
echo "Log in as admin with username '${DRUPAL_ADMIN}'"
echo "with the password you chose during installation."
echo ""
echo "Two aliases have been created for your convenience:"
echo "1. For Drupal system tasks and maintenance:"
echo "   Just type '${DOMAIN}-ctrl' to go to project directory"
echo "   '/var/www/webapps/${DOMAIN}/${PROJECT_DIR}' where you use composer and drush."
echo "2. To go to the public folder of ${DOMAIN}"
echo "   Just type '${DOMAIN}-web'"
echo ""
echo "Next steps:"
echo "  * Install an SSL certificate, run 'acme.sh --help' for details."
echo "  * Disable default site 'sudo a2dissite 000-default.conf'"
echo "  * For creation of more virtualhosts, a script has been installed."
echo "    See: https://github.com/NordicPinoyLab/virtualhost"
echo "  * Read the Drupal user guide: https://www.drupal.org/docs/user_guide/en/index.html"
echo "  * Get Drupal support: https://www.drupal.org/support"
echo "  * Get involved with the Drupal community:"
echo "      https://www.drupal.org/getting-involved"
echo "  * Remove this welcome message by editing your .bash_profile"
echo ""
echo ""
echo ""

if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
#END

#### Add aliases in .bashrc
cat <<END >> /home/${SSUSER}/.bashrc
alias ${DOMAIN}-ctrl='cd /var/www/webapps/${DOMAIN}/${PROJECT_DIR}'
alias ${DOMAIN}-web='cd /var/www/webapps/${DOMAIN}/${PROJECT_DIR}/${DRUPAL_DIR}'
#END

chown ${SSUSER}:${SSUSER} /home/${SSUSER}/.bash_profile

END

sed -i 's/#END/END/g' install-composer-drush-drupal.sh
chmod +x install-composer-drush-drupal.sh
chown "${SSUSER}":"${SSUSER}" install-composer-drush-drupal.sh
su -c "./install-composer-drush-drupal.sh" - "${SSUSER}"

### ADD A VIRTUALHOST CREATION/DELETION SCRIPT FOR FUTURE USE #################
wget -O /usr/local/bin/virtualhost https://raw.githubusercontent.com/NordicPinoyLab/virtualhost/main/virtualhost.sh
sed -i "s/email='sysadmin@example.com'/email='sysadmin@${FQDN}'/g" /usr/local/bin/virtualhost
sed -i "s+publicDir='web'+publicDir='${PROJECT_DIR}/${DRUPAL_DIR}'+g" /usr/local/bin/virtualhost
chmod +x /usr/local/bin/virtualhost


#### POST-INSTALL #############################################################
# Add info.php for default to allow checking of PHP
echo "<?php phpinfo(); ?>" > /var/www/html/info.php
# Restart services
systemctl restart php8.3-fpm
systemctl restart apache2
systemctl restart ssh

#### CLEAN-UP #################################################################
su -c "rm /home/\"${SSUSER}\"/install-composer-drush-drupal.sh" - "${SSUSER}"
apt-get -o Acquire::ForceIPv4=true update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
rm /root/StackScript
echo "Secured HTTP/2 LAMP stack with Apache, MariaDB, PHP 8.3 (php-fpm), Acme (SSL), Composer, Drush, and Drupal installation and configuration complete!"
