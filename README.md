# Alpine Linux Docker Letsencrypt / Certbot

Installation of https://github.com/certbot/certbot

## Docs

https://certbot.eff.org/docs/using.html

## Using with haproxy

Use `makeomatic/haproxy-consul:letsencrypt` image

## Automatic renewals

Change entrypoint to `/usr/sbin/crond` and pass args ["-f","-d","5"], mount `.getssl` dir and provide configurations.
Sample is provded below and more information can be found at script's original repo https://github.com/srvrco/getssl
This version is adapted to alpine linux docker image

## Sample configurations

```sh
# .getssl/getssl.cfg

# Uncomment and modify any variables you need
# The staging server is best for testing (hence set as default)
CA="https://acme-staging.api.letsencrypt.org"
AGREEMENT="https://letsencrypt.org/documents/LE-SA-v1.0.1-July-27-2015.pdf"
ACCOUNT_EMAIL="email@example.com"
ACCOUNT_KEY_LENGTH=4096
ACCOUNT_KEY="/.getssl/account.key"
PRIVATE_KEY_ALG="rsa"

# The command needed to reload apache / nginx or whatever you use
#RELOAD_CMD=""
# The time period within which you want to allow renewal of a certificate
#	this prevents hitting some of the rate limits.
RENEW_ALLOW="30"

# Define the server type.	This can either be a webserver, ldaps or a port number which
# will be checked for certificate expiry and also will be checked after
# an update to confirm correct certificate is running (if CHECK_REMOTE) is set to true
SERVER_TYPE="webserver"
CHECK_REMOTE="true"

# openssl config file.	The default should work in most cases.
SSLCONF="/etc/ssl/openssl.cnf"
VALIDATE_VIA_DNS="true"
DNS_ADD_COMMAND="/usr/local/bin/dns_add_cloudflare"
DNS_DEL_COMMAND="/usr/local/bin/dns_del_cloudflare"
DNS_WAIT=3
DNS_EXTRA_WAIT=30
```

```sh
# .getssl/domain.tld/getssl.cfg
# Uncomment and modify any variables you need
# Global getssl.cfg vars are overwritten here

# This server issues full certificates, however has rate limits
CA="https://acme-staging.api.letsencrypt.org"

# Set an email address associated with your account - generally set at account level rather than domain.
PRIVATE_KEY_ALG="rsa"

# Additional domains - this could be multiple domains / subdomains in a comma separated list
SANS=www.example.tld,admin.example.tld

# Acme Challenge Location. The first line for the domain, the following ones for each additional domain.
# If these start with ssh: then the next variable is assumed to be the hostname and the rest the location.
# An ssh key will be needed to provide you with access to the remote server.
# If these start with ftp: then the next variables are ftpuserid:ftppassword:servername:ACL_location
#ACL=('/var/www/radiofx.co/web/.well-known/acme-challenge'
#     'ssh:server5:/var/www/radiofx.co/web/.well-known/acme-challenge'
#     'ftp:ftpuserid:ftppassword:radiofx.co:/web/.well-known/acme-challenge')

# Location for all your certs, these can either be on the server (so full path name) or using ssh as for the ACL
# consul:host:port:/prefix
# only http is available at the moment
DOMAIN_CERT_LOCATION="consul:localhost:8500:/letsencrypt"
DOMAIN_KEY_LOCATION="consul:localhost:8500:/letsencrypt"
CA_CERT_LOCATION="consul:localhost:8500:/letsencrypt"
DOMAIN_CHAIN_LOCATION="consul:localhost:8500:/letsencrypt"
DOMAIN_PEM_LOCATION="consul:localhost:8500:/letsencrypt"

# The command needed to reload apache / nginx or whatever you use
#RELOAD_CMD=""
# The time period within which you want to allow renewal of a certificate
#  this prevents hitting some of the rate limits.
RENEW_ALLOW="30"

# Define the server type.  This can either be a webserver, ldaps or a port number which
# will be checked for certificate expiry and also will be checked after
# an update to confirm correct certificate is running (if CHECK_REMOTE) is set to true
#SERVER_TYPE="webserver"
#CHECK_REMOTE="true"

# Use the following 3 variables if you want to validate via DNS
#VALIDATE_VIA_DNS="true"
#DNS_ADD_COMMAND=
#DNS_DEL_COMMAND=
#AUTH_DNS_SERVER=""
#DNS_WAIT=10
#DNS_EXTRA_WAIT=60
```
