#!/bin/sh
# Build an BastilleBSD jail and install Apache Guacamole
# git clone https://github.com/tschettervictor/bastillebsd-scripts/guacamole

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
POOL_PATH=""
DB_PATH=""
JAIL_NAME="guacamole"
HOST_NAME=""
SELFSIGNED_CERT=0
STANDALONE_CERT=0
DNS_CERT=0
NO_CERT=0
CERT_EMAIL=""
CONFIG_NAME="guacamole-config"
DATABASE="mariadb"
DB_NAME="guacamole"
DB_USER="guacamole"
DB_ROOT_PASSWORD=$(openssl rand -base64 15)
DB_PASSWORD=$(openssl rand -base64 15)

# Check for guacamole-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"
INCLUDES_PATH="${SCRIPTPATH}"/includes

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"
# If release is 13.1-RELEASE, change to 13.2-RELEASE
if [ "${RELEASE}" = "13.1-RELEASE" ]; then
  RELEASE="13.2-RELEASE"
fi 

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by guacamole-config
if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
JAIL_INTERFACES="vnet0:bridge0"
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
if [ -z "${POOL_PATH}" ]; then
  echo 'Configuration error: POOL_PATH must be set'
  exit 1
fi
if [ -z "${HOST_NAME}" ]; then
  echo 'Configuration error: HOST_NAME must be set'
  exit 1
fi

# Check cert config
if [ $STANDALONE_CERT -eq 0 ] && [ $DNS_CERT -eq 0 ] && [ $NO_CERT -eq 0 ] && [ $SELFSIGNED_CERT -eq 0 ]; then
  echo 'Configuration error: Either STANDALONE_CERT, DNS_CERT, NO_CERT,'
  echo 'or SELFSIGNED_CERT must be set to 1.'
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ $DNS_CERT -eq 1 ] ; then
  echo 'Configuration error: Only one of STANDALONE_CERT and DNS_CERT'
  echo 'may be set to 1.'
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ -z "${DNS_PLUGIN}" ] ; then
  echo "DNS_PLUGIN must be set to a supported DNS provider."
  echo "See https://caddyserver.com/download for available plugins."
  echo "Use only the last part of the name.  E.g., for"
  echo "\"github.com/caddy-dns/cloudflare\", enter \"coudflare\"."
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi

# If DB_PATH and CONFIG_PATH weren't set, set them
if [ -z "${DB_PATH}" ]; then
  DB_PATH="${POOL_PATH}"/guacamole/db
fi

# Sanity check DB_PATH must be different from POOL_PATH
if [ "${DB_PATH}" = "${POOL_PATH}" ]
then
  echo "DB_PATH must be different from POOL_PATH!"
  exit 1
fi

# Extract IP and netmask, sanity check netmask
IP=$(echo ${JAIL_IP} | cut -f1 -d/)
NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]
then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
then
  NETMASK="24"
fi

# Check for reinstall
if [ "$(ls -A "${DB_PATH}")" ]; then
	echo "Existing Guacamole database detected. Checking compatability for reinstall."
	if [ "$(ls -A "${DB_PATH}/${DATABASE}")" ]; then
		echo "Database is compatible, continuing..."
		REINSTALL="true"
	else
		echo "ERROR: You can not reinstall without the previous database"
		echo "Please try again after removing the database, or using the same database used previously"
		exit 1
	fi
fi

#####
#
# Jail Creation
#
#####

# List packages to be auto-installed after jail creation
cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "nano",
  "go",
  "guacamole-server",
  "guacamole-client",
  "mariadb106-server",
  "mariadb106-client",
  "mysql-connector-j"
  ]
}
__EOF__

# Create the jail and install previously listed packages
if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
	echo "Failed to create jail"
	exit 1
fi
rm /tmp/pkg.json

#####
#
# Directory Creation and Mounting
#
#####

mkdir -p "${DB_PATH}"/"${DATABASE}"
chown -R 88:88 "${DB_PATH}"/
iocage exec "${JAIL_NAME}" mkdir -p /var/db/mysql
iocage exec "${JAIL_NAME}" mkdir -p /mnt/includes
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/rc.d
iocage fstab -a "${JAIL_NAME}" "${DB_PATH}"/"${DATABASE}" /var/db/mysql nullfs rw 0 0
iocage fstab -a "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/guacamole-client/lib
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/guacamole-client/extensions

#####
#
# Guacamole Install
#
#####

# Enable services
iocage exec "${JAIL_NAME}" sysrc guacd_enable="YES"
iocage exec "${JAIL_NAME}" sysrc tomcat9_enable="YES"
iocage exec "${JAIL_NAME}" sysrc mysql_enable="YES"

# Extract java connector to guacamole
iocage exec "${JAIL_NAME}" "cp -f /usr/local/share/java/classes/mysql-connector-j.jar /usr/local/etc/guacamole-client/lib"
iocage exec "${JAIL_NAME}" "tar xvfz /usr/local/share/guacamole-client/guacamole-auth-jdbc.tar.gz -C /tmp/"
iocage exec "${JAIL_NAME}" "cp -f /tmp/guacamole-auth-jdbc-*/mysql/*.jar /usr/local/etc/guacamole-client/extensions"

# Copy guacamole server files
iocage exec "${JAIL_NAME}" "cp -f /usr/local/etc/guacamole-server/guacd.conf.sample /usr/local/etc/guacamole-server/guacd.conf"
iocage exec "${JAIL_NAME}" "cp -f /usr/local/etc/guacamole-client/logback.xml.sample /usr/local/etc/guacamole-client/logback.xml"
iocage exec "${JAIL_NAME}" "cp -f /usr/local/etc/guacamole-client/guacamole.properties.sample /usr/local/etc/guacamole-client/guacamole.properties"

# Change default bind host ip
iocage exec "${JAIL_NAME}" sed -i -e 's/'localhost'/'0.0.0.0'/g' /usr/local/etc/guacamole-server/guacd.conf

# Add database connection
iocage exec "${JAIL_NAME}" 'echo "mysql-hostname: localhost" >> /usr/local/etc/guacamole-client/guacamole.properties'
iocage exec "${JAIL_NAME}" 'echo "mysql-port:     3306" >> /usr/local/etc/guacamole-client/guacamole.properties'
iocage exec "${JAIL_NAME}" 'echo "mysql-database: '${DB_NAME}'" >> /usr/local/etc/guacamole-client/guacamole.properties'
iocage exec "${JAIL_NAME}" 'echo "mysql-username: '${DB_USER}'" >> /usr/local/etc/guacamole-client/guacamole.properties'
iocage exec "${JAIL_NAME}" 'echo "mysql-password: '${DB_PASSWORD}'" >> /usr/local/etc/guacamole-client/guacamole.properties'
iocage exec "${JAIL_NAME}" service mysql-server start

if [ "${REINSTALL}" == "true" ]; then
	echo "You did a reinstall, but database passwords will still be changed."
 	echo "New passwords will still be saved in the TrueNAS root directory."
 	iocage exec "${JAIL_NAME}" mysql -u root -e "SET PASSWORD FOR '${DB_USER}'@localhost = PASSWORD('${DB_PASSWORD}');"
 	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/my.cnf /root/.my.cnf
  	iocage exec "${JAIL_NAME}" sed -i '' "s|mypassword|${DB_ROOT_PASSWORD}|" /root/.my.cnf
else
	if ! iocage exec "${JAIL_NAME}" mysql -u root -e "CREATE DATABASE ${DB_NAME};"; then
		echo "Failed to create MariaDB database, aborting"
		exit 1
	fi
		iocage exec "${JAIL_NAME}" mysql -u root -e "GRANT ALL ON ${DB_NAME}.* TO '${DB_USER}'@localhost IDENTIFIED BY '${DB_PASSWORD}';"
		iocage exec "${JAIL_NAME}" mysql -u root -e "DELETE FROM mysql.user WHERE User='';"
		iocage exec "${JAIL_NAME}" mysql -u root -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
		iocage exec "${JAIL_NAME}" mysql -u root -e "DROP DATABASE IF EXISTS test;"
		iocage exec "${JAIL_NAME}" mysql -u root -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
		iocage exec "${JAIL_NAME}" mysql -u root -e "FLUSH PRIVILEGES;"
		iocage exec "${JAIL_NAME}" mysqladmin --user=root password "${DB_ROOT_PASSWORD}" reload
		iocage exec "${JAIL_NAME}" cp -f /mnt/includes/my.cnf /root/.my.cnf
		iocage exec "${JAIL_NAME}" sed -i '' "s|mypassword|${DB_ROOT_PASSWORD}|" /root/.my.cnf
		iocage exec "${JAIL_NAME}" "cat /tmp/guacamole-auth-jdbc-*/mysql/schema/*.sql | mysql -u root -p"${DB_ROOT_PASSWORD}" ${DB_NAME}"
fi

# Copy server.xml file for tomcat9 (adds internalProxies valve)
iocage exec "${JAIL_NAME}" cp /usr/local/apache-tomcat-9.0/conf/server.xml /usr/local/apache-tomcat-9.0/conf/server.xml.bak
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/server.xml /usr/local/apache-tomcat-9.0/conf/server.xml

# Start services
iocage exec "${JAIL_NAME}" service mysql-server restart
iocage exec "${JAIL_NAME}" service guacd restart
iocage exec "${JAIL_NAME}" service tomcat9 restart

#####
#
# Caddy Installation
#
#####

# Build xcaddy, use it to build Caddy
if ! iocage exec "${JAIL_NAME}" "go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest"
then
  echo "Failed to get xcaddy, terminating."
  exit 1
fi
if ! iocage exec "${JAIL_NAME}" cp /root/go/bin/xcaddy /usr/local/bin/xcaddy
then
  echo "Failed to move xcaddy to path, terminating."
  exit 1
fi
if [ ${DNS_CERT} -eq 1 ]; then
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy --with github.com/caddy-dns/"${DNS_PLUGIN}"
  then
    echo "Failed to build Caddy with ${DNS_PLUGIN} plugin, terminating."
    exit 1
  fi  
else
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy
  then
    echo "Failed to build Caddy without plugin, terminating."
    exit 1
  fi  
fi

# Generate and insall self-signed cert, if necessary
if [ $SELFSIGNED_CERT -eq 1 ]; then
	iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/private
	iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/certs
	openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=${HOST_NAME}" -keyout "${INCLUDES_PATH}"/privkey.pem -out "${INCLUDES_PATH}"/fullchain.pem
	iocage exec "${JAIL_NAME}" cp /mnt/includes/privkey.pem /usr/local/etc/pki/tls/private/privkey.pem
	iocage exec "${JAIL_NAME}" cp /mnt/includes/fullchain.pem /usr/local/etc/pki/tls/certs/fullchain.pem
fi

if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/remove-staging.sh /root/
fi
if [ $NO_CERT -eq 1 ]; then
	echo "Copying Caddyfile for no SSL"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-nossl /usr/local/www/Caddyfile
elif [ $SELFSIGNED_CERT -eq 1 ]; then
	echo "Copying Caddyfile for self-signed cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-selfsigned /usr/local/www/Caddyfile
elif [ $DNS_CERT -eq 1 ]; then
	echo "Copying Caddyfile for Lets's Encrypt DNS cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-dns /usr/local/www/Caddyfile
else
	echo "Copying Caddyfile for Let's Encrypt cert"
	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-standalone /usr/local/www/Caddyfile	
fi
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/caddy /usr/local/etc/rc.d/
iocage exec "${JAIL_NAME}" sed -i '' "s/yourhostnamehere/${HOST_NAME}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/dns_plugin/${DNS_PLUGIN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/api_token/${DNS_TOKEN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/youremailhere/${CERT_EMAIL}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sysrc caddy_config="/usr/local/www/Caddyfile"
iocage exec "${JAIL_NAME}" sysrc caddy_enable="YES"

# Save passwords for later reference
echo "${DATABASE} root user is root and password is ${DB_ROOT_PASSWORD}" > /root/${JAIL_NAME}_db_password.txt
echo "Guacamole database user is ${DB_USER} and password is ${DB_PASSWORD}" >> /root/${JAIL_NAME}_db_password.txt
echo "Guacamole default username and password are both guacadmin." >> /root/${JAIL_NAME}_db_password.txt

# Don't need /mnt/includes any more, so unmount it
iocage fstab -r "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

iocage restart "${JAIL_NAME}"

echo "---------------"
echo "Installation complete."
echo "---------------"
if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  echo ""
  echo "You have obtained your Let's Encrypt certificate using the staging server."
  echo "This certificate will not be trusted by your browser and will cause SSL errors"
  echo "when you connect.  Once you've verified that everything else is working"
  echo "correctly, you should issue a trusted certificate.  To do this, run:"
  echo "  iocage exec ${JAIL_NAME} /root/remove-staging.sh"
  echo ""
elif [ $SELFSIGNED_CERT -eq 1 ]; then
  echo "You have chosen to create a self-signed TLS certificate for your installation."
  echo "installation.  This certificate will not be trusted by your browser and"
  echo "will cause SSL errors when you connect.  If you wish to replace this certificate"
  echo "with one obtained elsewhere, the private key is located at:"
  echo "/usr/local/etc/pki/tls/private/privkey.pem"
  echo "The full chain (server + intermediate certificates together) is at:"
  echo "/usr/local/etc/pki/tls/certs/fullchain.pem"
  echo ""
  echo "---------------"
fi
if [ $NO_CERT -eq 1 ]; then
  echo "Using your web browser, go to http://${HOST_NAME}/guacamole to log in"
else
  echo "Using your web browser, go to https://${HOST_NAME}/guacamole to log in"
fi
echo "---------------"
echo "Database Information"
echo "MySQL Username: root"
echo "MySQL Password: $DB_ROOT_PASSWORD"
echo "Guacamole DB User: $DB_USER"
echo "Guacamole DB Password: "$DB_PASSWORD""
if [ "${REINSTALL}" == "true" ]; then
	echo "---------------"
	echo "You did a reinstall, please user your old credentials to log in."
else
	echo "---------------"
	echo "User Information"
	echo "Default user is guacadmin"
	echo "Default password is guacadmin"
fi
echo "---------------"
echo "All passwords are saved in /root/${JAIL_NAME}_db_password.txt"
echo "---------------"
