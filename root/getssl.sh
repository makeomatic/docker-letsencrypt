#!/bin/bash
# ---------------------------------------------------------------------------
# getssl - Obtain SSL certificates from the letsencrypt.org ACME server

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	See the
# GNU General Public License at <http://www.gnu.org/licenses/> for
# more details.

# For usage, run "getssl -h" or see https://github.com/srvrco/getssl
# ---------------------------------------------------------------------------
PROGNAME=${0##*/}
VERSION="1.05"

# defaults
CODE_LOCATION="https://raw.githubusercontent.com/srvrco/getssl/master/getssl"
CA="https://acme-staging.api.letsencrypt.org"
AGREEMENT="https://letsencrypt.org/documents/LE-SA-v1.0.1-July-27-2015.pdf"
ACCOUNT_KEY_LENGTH=4096
WORKING_DIR=/.getssl
DOMAIN_KEY_LENGTH=4096
SSLCONF="$(openssl version -d | cut -d\" -f2)/openssl.cnf"
VALIDATE_VIA_DNS=""
RELOAD_CMD=""
RENEW_ALLOW="30"
PRIVATE_KEY_ALG="rsa"
SERVER_TYPE="webserver"
CHECK_REMOTE="true"
DNS_WAIT=10
DNS_EXTRA_WAIT=""
PUBLIC_DNS_SERVER=""
ORIG_UMASK=$(umask)
_USE_DEBUG=0
_CREATE_CONFIG=0
_CHECK_ALL=0
_FORCE_RENEW=0
_QUIET=0
_UPGRADE=0

# store copy of original command in case of upgrading script and re-running
ORIGCMD="$0 $*"

cert_archive() {	# Archive certificate file by copying with dates at end.
	certfile=$1
	enddate=$(openssl x509 -in "$certfile" -noout -enddate 2>/dev/null| cut -d= -f 2-)
	formatted_enddate=$(date -d "${enddate}" +%F)
	startdate=$(openssl x509 -in "$certfile" -noout -startdate 2>/dev/null| cut -d= -f 2-)
	formatted_startdate=$(date -d "${startdate}" +%F)
	mv "${certfile}" "${certfile}_${formatted_startdate}_${formatted_enddate}"
	info "archiving old certificate file to ${certfile}_${formatted_startdate}_${formatted_enddate}"
}

check_challenge_completion() { # checks with the ACME server if our challenge is OK
	uri=$1
	domain=$2
	keyauthorization=$3

	debug "sending request to ACME server saying we're ready for challenge"
	send_signed_request "$uri" "{\"resource\": \"challenge\", \"keyAuthorization\": \"$keyauthorization\"}"

	# check respose from our request to perform challenge
	if [ ! -z "$code" ] && [ ! "$code" == '202' ] ; then
		error_exit "$domain:Challenge error: $code"
	fi

	# loop "forever" to keep checking for a response from the ACME server.
	# shellcheck disable=SC2078
	while [ "1" ] ; do
		debug "checking"
		if ! getcr "$uri" ; then
			error_exit "$domain:Verify error:$code"
		fi

		# shellcheck disable=SC2086
		status=$(echo $response | grep -Po '"status":[ ]*"[^"]+"' | cut -d '"' -f 4)

		# If ACME respose is valid, then break out of loop
		if [ "$status" == "valid" ] ; then
			info "Verified $domain"
			break;
		fi

		# if ACME response is that their check gave an invalid response, error exit
		if [ "$status" == "invalid" ] ; then
			error=$(echo "$response" | grep -Po '"error":[ ]*{[^}]*}' | grep -o '"detail":"[^"]*"' | cut -d '"' -f 4)
			error_exit "$domain:Verify error:$error"
		fi

		# if ACME response is pending ( they haven't completed checks yet) then wait and try again.
		if [ "$status" == "pending" ] ; then
			info "Pending"
		else
			error_exit "$domain:Verify error:$response"
		fi
		debug "sleep 5 secs before testing verify again"
		sleep 5
	done
}

check_getssl_upgrade() { # check if a more recent version of code is available available
	latestcode=$(curl --silent "$CODE_LOCATION")
	latestversion=$(echo "$latestcode" | grep VERSION= | head -1| awk -F'"' '{print $2}')
	latestvdec=$(echo "$latestversion"| tr -d '.')
	localvdec=$(echo "$VERSION"| tr -d '.' )
	debug "current code is version ${VERSION}"
	debug "Most recent version is	${latestversion}"
	# use a default of 0 for cases where the latest code has not been obtained.
	if [ "${latestvdec:-0}" -gt "$localvdec" ]; then
		if [ ${_UPGRADE} -eq 1 ]; then
			temp_upgrade="$(mktemp)"
			echo "$latestcode" > "$temp_upgrade"
			install "$0" "${0}.v${VERSION}"
			install "$temp_upgrade" "$0"
			rm -f "$temp_upgrade"
			info "Updated getssl from v${VERSION} to v${latestversion}"
			eval "$ORIGCMD"
			graceful_exit
		else
			info ""
			info "A more recent version (v${latestversion}) of getssl is available, please update"
			info "the easiest way is to use the -u or --upgrade flag"
			info ""
		fi
	fi
}

clean_up() { # Perform pre-exit housekeeping
	umask "$ORIG_UMASK"
	if [ ! -z "$DOMAIN_DIR" ]; then
		rm -rf "${TEMP_DIR:?}"
	fi
	if [[ $VALIDATE_VIA_DNS == "true" ]]; then
		# Tidy up DNS entries if things failed part way though.
		shopt -s nullglob
		for dnsfile in $TEMP_DIR/dns_verify/*; do
			. "$dnsfile"
			debug "attempting to clean up DNS entry for $d"
			$DNS_DEL_COMMAND "$d"
		done
		shopt -u nullglob
	fi
}

copy_file_to_location() { # copies a file, using scp if required.
	cert=$1	 # descriptive name, just used for display
	from=$2	 # current file location
	to=$3		 # location to move file to.
	if [ ! -z "$to" ]; then
		info "copying $cert to $to"
		debug "copying from $from to $to"
		if [[ "${to:0:4}" == "ssh:" ]] ; then
			debug "using scp scp -q $from ${to:4}"
			scp -q "$from" "${to:4}" >/dev/null 2>&1
			if [ $? -gt 0 ]; then
				error_exit "problem copying file to the server using scp.
				scp $from ${to:4}"
			fi
		elif [[ "${to:0:4}" == "ftp:" ]] ; then
			if [[ "$cert" != "challenge token" ]] ; then
				error_exit "ftp is not a sercure method for copying certificates or keys"
			fi
			debug "using ftp to copy the file from $from"
			ftpuser=$(echo "$to"| awk -F: '{print $2}')
			ftppass=$(echo "$to"| awk -F: '{print $3}')
			ftphost=$(echo "$to"| awk -F: '{print $4}')
			ftplocn=$(echo "$to"| awk -F: '{print $5}')
			ftpdirn=$(dirname "$ftplocn")
			ftpfile=$(basename "$ftplocn")
			fromdir=$(dirname "$from")
			fromfile=$(basename "$from")
			debug "ftp user=$ftpuser - pass=$ftppass - host=$ftphost dir=$ftpdirn file=$ftpfile"
			debug "from dir=$fromdir	file=$fromfile"
			ftp -n <<- _EOF
			open $ftphost
			user $ftpuser $ftppass
			cd $ftpdirn
			lcd $fromdir
			put $fromfile
			_EOF
		elif [[ "${to:0:5}" == "sftp:" ]] ; then
			debug "using sftp to copy the file from $from"
			ftpuser=$(echo "$to"| awk -F: '{print $2}')
			ftppass=$(echo "$to"| awk -F: '{print $3}')
			ftphost=$(echo "$to"| awk -F: '{print $4}')
			ftplocn=$(echo "$to"| awk -F: '{print $5}')
			ftpdirn=$(dirname "$ftplocn")
			ftpfile=$(basename "$ftplocn")
			fromdir=$(dirname "$from")
			fromfile=$(basename "$from")
			debug "sftp user=$ftpuser - pass=$ftppass - host=$ftphost dir=$ftpdirn file=$ftpfile"
			debug "from dir=$fromdir	file=$fromfile"
			sshpass -p "$ftppass" sftp "$ftpuser@$ftphost" <<- _EOF
			cd $ftpdirn
			lcd $fromdir
			put $fromfile
			_EOF
		else
			mkdir -p "$(dirname "$to")"
			if [ $? -gt 0 ]; then
				error_exit "cannot create ACL directory $(basename "$to")"
			fi
			cp "$from" "$to"
			if [ $? -ne 0 ]; then
				error_exit "cannot copy $from to $to"
			fi
		fi
		debug "copied $from to $to"
	fi
}

debug() { # write out debug info if the debug flag has been set
	if [ ${_USE_DEBUG} -eq 1 ]; then
		echo "$@"
	fi
}

error_exit() { # give error message on error exit
	echo -e "${PROGNAME}: ${1:-"Unknown Error"}" >&2
	clean_up
	exit 1
}

getcr() { # get curl response
	url="$1"
	debug url "$url"
	response=$(curl --silent "$url")
	ret=$?
	debug response	"$response"
	# shellcheck disable=SC2086
	code=$(echo $response | grep -Eo '"status":[ ]*[0-9]*' | cut -d : -f 2)
	debug code "$code"
	debug getcr return code $ret
	return $ret
}

graceful_exit() { # normal exit function.
	clean_up
	exit
}

help_message() { # print out the help message
	cat <<- _EOF_
	$PROGNAME ver. $VERSION
	Obtain SSL certificates from the letsencrypt.org ACME server

	$(usage)

	Options:
		-h, --help			Display this help message and exit
		-d, --debug		 Outputs debug information
		-c, --create		Create default config files
		-f, --force		 Force renewal of cert (overrides expiry checks)
		-a, --all			 Check all certificates
		-q, --quiet		 Quiet mode (only outputs on error)
		-u, --upgrade	 Upgrade getssl if a more recent version is available
		-w working_dir	Working directory

	_EOF_
}

hex2bin() { # Remove spaces, add leading zero, escape as hex string and parse with printf
	printf -- "$(cat | os_sed -e 's/[[:space:]]//g' -e 's/^(.(.{2})*)$/0\1/' -e 's/(.{2})/\\x\1/g')"
}

info() { # write out info as long as the quiet flag has not been set.
	if [ ${_QUIET} -eq 0 ]; then
		echo "$@"
	fi
}

os_sed() { # Use different sed version for different os types...
	if [[ "$OSTYPE" == "linux-gnu" ]]; then
		sed -r "${@}"
	else
		sed -E "${@}"
	fi
}

reload_service() {	# Runs a command to reload services ( via ssh if needed)
	if [ ! -z "$RELOAD_CMD" ]; then
		info "reloading SSL services"
		if [[ "${RELOAD_CMD:0:4}" == "ssh:" ]] ; then
			sshhost=$(echo "$RELOAD_CMD"| awk -F: '{print $2}')
			command=${RELOAD_CMD:(( ${#sshhost} + 5))}
			debug "running following comand to reload cert"
			debug "ssh $sshhost ${command}"
			# shellcheck disable=SC2029
			ssh "$sshhost" "${command}" 1>/dev/null 2>&1
			# allow 2 seconds for services to restart
			sleep 2
		else
			debug "running reload command $RELOAD_CMD"
			$RELOAD_CMD
			if [ $? -gt 0 ]; then
				error_exit "error running $RELOAD_CMD"
			fi
		fi
	fi
}

requires() { # check if required function is available
	result=$(which "$1" 2>/dev/null)
	debug "checking for required $1 ... $result"
	if [ -z "$result" ]; then
		error_exit "This script requires $1 installed"
	fi
}

send_signed_request() { # Sends a request to the ACME server, signed with your private key.
	url=$1
	payload=$2
	needbase64=$3

	debug url "$url"
	debug payload "$payload"

	CURL_HEADER="$TEMP_DIR/curl.header"
	dp="$TEMP_DIR/curl.dump"
	CURL="curl --silent --dump-header $CURL_HEADER "
	if [ ${_USE_DEBUG} -eq 1 ]; then
		CURL="$CURL --trace-ascii $dp "
	fi

	# convert payload to url base 64
	payload64="$(printf '%s' "${payload}" | urlbase64)"
	debug payload64 "$payload64"

	# get nonce from ACME server
	nonceurl="$CA/directory"
	nonce=$($CURL -I $nonceurl | grep "^Replay-Nonce:" | sed s/\\r//|sed s/\\n//| cut -d ' ' -f 2)

	debug nonce "$nonce"

	# Build header with just our public key and algorithm information
	header='{"alg": "RS256", "jwk": {"e": "'"${pub_exp64}"'", "kty": "RSA", "n": "'"${pub_mod64}"'"}}'

	# Build another header which also contains the previously received nonce and encode it as urlbase64
	protected='{"alg": "RS256", "jwk": {"e": "'"${pub_exp64}"'", "kty": "RSA", "n": "'"${pub_mod64}"'"}, "nonce": "'"${nonce}"'"}'
	protected64="$(printf '%s' "${protected}" | urlbase64)"
	debug protected "$protected"

	# Sign header with nonce and our payload with our private key and encode signature as urlbase64
	signed64="$(printf '%s' "${protected64}.${payload64}" | openssl dgst -sha256 -sign "${ACCOUNT_KEY}" | urlbase64)"

	# Send header + extended header + payload + signature to the acme-server
	body='{"header": '"${header}"', "protected": "'"${protected64}"'", "payload": "'"${payload64}"'", "signature": "'"${signed64}"'"}'
	debug "data for account registration = $body"

	if [ "$needbase64" ] ; then
		response=$($CURL -X POST --data "$body" "$url" | urlbase64)
	else
		response=$($CURL -X POST --data "$body" "$url")
	fi

	responseHeaders=$(sed 's/\r//g' "$CURL_HEADER")
	debug responseHeaders "$responseHeaders"
	debug response	"$response"
	code=$(grep ^HTTP "$CURL_HEADER" | tail -1 | cut -d " " -f 2)
	debug code "$code"
}

signal_exit() { # Handle trapped signals
	case $1 in
		INT)
			error_exit "Program interrupted by user" ;;
		TERM)
			echo -e "\n$PROGNAME: Program terminated" >&2
			graceful_exit ;;
		*)
			error_exit "$PROGNAME: Terminating on unknown signal" ;;
	esac
}

urlbase64() { # urlbase64: base64 encoded string with '+' replaced with '-' and '/' replaced with '_'
	openssl base64 -e | tr -d '\n\r' | os_sed -e 's:=*$::g' -e 'y:+/:-_:'
}

usage() { # program usage
	echo "Usage: $PROGNAME [-h|--help] [-d|--debug] [-c|--create] [-f|--force] [-a|--all] [-q|--quiet] [-u|--upgrade] [-w working_dir] domain"
}

write_domain_template() { # write out a template file for a domain.
	cat > "$1" <<- _EOF_domain_
	# Uncomment and modify any variables you need
	# The staging server is best for testing
	#CA="https://acme-staging.api.letsencrypt.org"
	# This server issues full certificates, however has rate limits
	#CA="https://acme-v01.api.letsencrypt.org"

	#AGREEMENT="https://letsencrypt.org/documents/LE-SA-v1.0.1-July-27-2015.pdf"

	# Set an email address associated with your account - generally set at account level rather than domain.
	#ACCOUNT_EMAIL="me@example.com"
	#ACCOUNT_KEY_LENGTH=4096
	#ACCOUNT_KEY="$WORKING_DIR/account.key"
	PRIVATE_KEY_ALG="rsa"

	# Additional domains - this could be multiple domains / subdomains in a comma separated list
	SANS=${EX_SANS}

	# Acme Challenge Location. The first line for the domain, the following ones for each additional domain.
	# If these start with ssh: then the next variable is assumed to be the hostname and the rest the location.
	# An ssh key will be needed to provide you with access to the remote server.
	# If these start with ftp: then the next variables are ftpuserid:ftppassword:servername:ACL_location
	#ACL=('/var/www/${DOMAIN}/web/.well-known/acme-challenge'
	#		 'ssh:server5:/var/www/${DOMAIN}/web/.well-known/acme-challenge'
	#		 'ftp:ftpuserid:ftppassword:${DOMAIN}:/web/.well-known/acme-challenge')

	# Location for all your certs, these can either be on the server (so full path name) or using ssh as for the ACL
	#DOMAIN_CERT_LOCATION="ssh:server5:/etc/ssl/domain.crt"
	#DOMAIN_KEY_LOCATION="ssh:server5:/etc/ssl/domain.key"
	#CA_CERT_LOCATION="/etc/ssl/chain.crt"
	#DOMAIN_CHAIN_LOCATION="" this is the domain cert and CA cert
	#DOMAIN_PEM_LOCATION="" this is the domain_key. domain cert and CA cert

	# The command needed to reload apache / nginx or whatever you use
	#RELOAD_CMD=""
	# The time period within which you want to allow renewal of a certificate
	#	this prevents hitting some of the rate limits.
	RENEW_ALLOW="30"

	# Define the server type.	This can either be a webserver, ldaps or a port number which
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
	_EOF_domain_
}

write_getssl_template() { # write out the main template file
	cat > "$1" <<- _EOF_getssl_
		# Uncomment and modify any variables you need
		# The staging server is best for testing (hence set as default)
		CA="${LE_CA}"
		AGREEMENT="https://letsencrypt.org/documents/LE-SA-v1.0.1-July-27-2015.pdf"
	_EOF_getssl_

	# Set an email address associated with your account - generally set at account level rather than domain.
	if [ -n "${LE_EMAIL}" ]; then
		cat >> "$1" <<- _EOF_getssl_
			ACCOUNT_EMAIL="${LE_EMAIL}"
		_EOF_getssl_
	fi

	cat >> "$1" <<- _EOF_getssl_
		ACCOUNT_KEY_LENGTH=4096
		ACCOUNT_KEY="$WORKING_DIR/account.key"
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
		SSLCONF="$SSLCONF"
	_EOF_getssl_

	# Use the following 3 variables if you want to validate via DNS
	if [[ "${LE_VALIDATE_VIA_DNS}" -eq "true" ]]; then
		cat >> "$1" <<- _EOF_getssl_
			VALIDATE_VIA_DNS="true"
			DNS_ADD_COMMAND="${LE_DNS_ADD_CMD}"
			DNS_DEL_COMMAND="${LE_DNS_DEL_CMD}"
			DNS_WAIT=${DNS_WAIT:-10}
			DNS_EXTRA_WAIT=${DNS_EXTRA_WAIT:-60}
		_EOF_getssl_

		if [ -n "${LE_AUTH_DNS_SERVER}" ]; then
			cat >> "$1" <<- _EOF_getssl_
				AUTH_DNS_SERVER="${LE_AUTH_DNS_SERVER}"
			_EOF_getssl_
		fi
	fi
}

write_openssl_conf() { # write out a minimal openssl conf
	cat > "$1" <<- _EOF_openssl_conf_
	# minimal openssl.cnf file
	distinguished_name	= req_distinguished_name
	[ req_distinguished_name ]
	[v3_req]
	[v3_ca]
	_EOF_openssl_conf_
}

# Trap signals
trap "signal_exit TERM" TERM HUP
trap "signal_exit INT"	INT

# Parse command-line
while [[ -n $1 ]]; do
	case $1 in
		-h | --help)
			help_message; graceful_exit ;;
		-d | --debug)
		 _USE_DEBUG=1 ;;
		-c | --create)
		 _CREATE_CONFIG=1 ;;
		-f | --force)
		 _FORCE_RENEW=1 ;;
		-a | --all)
		 _CHECK_ALL=1 ;;
		-q | --quiet)
		 _QUIET=1 ;;
		-u | --upgrade)
		 _UPGRADE=1 ;;
		-w)
			shift; WORKING_DIR="$1" ;;
		-* | --*)
			usage
			error_exit "Unknown option $1" ;;
		*)
			DOMAIN="$1" ;;
	esac
	shift
done

# Main logic

#check if required applications are included

requires openssl
requires curl
requires nslookup
requires sed
requires grep
requires awk
requires tr

# Check if upgrades are available
check_getssl_upgrade

# if "-a" option then check other parameters and create run for each domain.
if [ ${_CHECK_ALL} -eq 1 ]; then
	info "Check all certificates"

	if [ ${_CREATE_CONFIG} -eq 1 ]; then
		error_exit "cannot combine -c|--create with -a|--all"
	fi

	if [ ${_FORCE_RENEW} -eq 1 ]; then
		error_exit "cannot combine -f|--force with -a|--all because of rate limits"
	fi

	if [ ! -d "$WORKING_DIR" ]; then
		error_exit "working dir not found or not set - $WORKING_DIR"
	fi

	for dir in ${WORKING_DIR}/*; do
		if [ -d "$dir" ]; then
			debug "Checking $dir"
			cmd="$0 -w '$WORKING_DIR'"
			if [ ${_USE_DEBUG} -eq 1 ]; then
				cmd="$cmd -d"
			fi
			if [ ${_QUIET} -eq 1 ]; then
				cmd="$cmd -q"
			fi
			cmd="$cmd $(basename "$dir")"

			debug "CMD: $cmd"
			eval "$cmd"
		fi
	done

	graceful_exit
fi	# end of "-a" option.

# if nothing in command line, print help and exit.
if [ -z "$DOMAIN" ]; then
	help_message
	graceful_exit
fi

# if the "working directory" doesn't exist, then create it.
if [ ! -d "$WORKING_DIR" ]; then
	debug "Making working directory - $WORKING_DIR"
	mkdir -p "$WORKING_DIR"
fi

# Define default file locations.
ACCOUNT_KEY="$WORKING_DIR/account.key"
DOMAIN_DIR="$WORKING_DIR/$DOMAIN"
CERT_FILE="$DOMAIN_DIR/${DOMAIN}.crt"
CA_CERT="$DOMAIN_DIR/chain.crt"
TEMP_DIR="$DOMAIN_DIR/tmp"

# if "-c|--create" option used, then create config files.
if [ ${_CREATE_CONFIG} -eq 1 ]; then
	# If main config file exists, read it, if not then create it.
	if [ -f "$WORKING_DIR/getssl.cfg" ]; then
		info "reading main config from existing $WORKING_DIR/getssl.cfg"
		. "$WORKING_DIR/getssl.cfg"
	else
		info "creating main config file $WORKING_DIR/getssl.cfg"
		if [[ ! -f "$SSLCONF" ]]; then
			SSLCONF="$WORKING_DIR/openssl.cnf"
			write_openssl_conf "$SSLCONF"
		fi
		write_getssl_template "$WORKING_DIR/getssl.cfg"
	fi
	# If domain and domain config don't exist then create them.
	if [ ! -d "$DOMAIN_DIR" ]; then
		info "Making domain directory - $DOMAIN_DIR"
		mkdir -p "$DOMAIN_DIR"
	fi
	if [ -f "$DOMAIN_DIR/getssl.cfg" ]; then
		info "domain config already exists $DOMAIN_DIR/getssl.cfg"
	else
		info "creating domain config file in $DOMAIN_DIR/getssl.cfg"
		# if domain has an existsing cert, copy from domain and use to create defaults.
		EX_CERT=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:443" 2>/dev/null | openssl x509 2>/dev/null)
		EX_SANS="www.${DOMAIN}"
		if [ ! -z "${EX_CERT}" ]; then
			if [ ! -f "$DOMAIN_DIR/${DOMAIN}.crt" ]; then
				echo "$EX_CERT" > "$DOMAIN_DIR/${DOMAIN}.crt"
			fi
			EX_SANS=$(echo "$EX_CERT" | openssl x509 -noout -text 2>/dev/null| grep "Subject Alternative Name" -A2 \
								| grep -Eo "DNS:[a-zA-Z 0-9.-]*" | sed "s@DNS:$DOMAIN@@g" | grep -v '^$' | cut -c 5-)
			EX_SANS=${EX_SANS//$'\n'/','}
		fi
		write_domain_template "$DOMAIN_DIR/getssl.cfg"
	fi
	TEMP_DIR="$DOMAIN_DIR/tmp"
	# end of "-c|--create" option, so exit
	graceful_exit
fi # end of "-c|--create" option to create config file.

# read any variables from config in working directory
if [ -f "$WORKING_DIR/getssl.cfg" ]; then
	debug "reading config from $WORKING_DIR/getssl.cfg"
	. "$WORKING_DIR/getssl.cfg"
fi

# if domain directory doesn't exist, then create it.
if [ ! -d "$DOMAIN_DIR" ]; then
	debug "Making working directory - $DOMAIN_DIR"
	mkdir -p "$DOMAIN_DIR"
fi

# define a temporary directory, and if it doesn't exist, create it.
TEMP_DIR="$DOMAIN_DIR/tmp"
if [ ! -d "${TEMP_DIR}" ]; then
	debug "Making temp directory - ${TEMP_DIR}"
	mkdir -p "${TEMP_DIR}"
fi

# read any variables from config in domain directory
if [ -f "$DOMAIN_DIR/getssl.cfg" ]; then
	debug "reading config from $DOMAIN_DIR/getssl.cfg"
	. "$DOMAIN_DIR/getssl.cfg"
fi

if [[ ${SERVER_TYPE} == "webserver" ]]; then
	REMOTE_PORT=443
elif [[ ${SERVER_TYPE} == "ldaps" ]]; then
	REMOTE_PORT=636
elif [[ ${SERVER_TYPE} =~ ^[0-9]+$ ]]; then
	REMOTE_PORT=${SERVER_TYPE}
else
	error_exit "unknown server type"
fi

# if check_remote is true then connect and obtain the current certificate (if not forcing renewal)
if [[ "${CHECK_REMOTE}" == "true" ]] && [ $_FORCE_RENEW -eq 0 ]; then
	debug "getting certificate for $DOMAIN from remote server"
	EX_CERT=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${REMOTE_PORT}" 2>/dev/null | openssl x509 2>/dev/null)
	if [ ! -z "$EX_CERT" ]; then # if obtained a cert
		if [ -f "$CERT_FILE" ]; then # if local exists
			CERT_REMOTE=$(echo "$EX_CERT" | openssl x509 -noout -fingerprint 2>/dev/null)
			CERT_LOCAL=$(openssl x509 -noout -fingerprint < "$CERT_FILE" 2>/dev/null)
			if [ "$CERT_LOCAL" == "$CERT_REMOTE" ]; then
				debug "certificate on server is same as the local cert"
			else
				# check if the certificate is for the right domain
				EX_CERT_DOMAIN=$(echo "$EX_CERT" | openssl x509 -noout -subject | sed s/.*CN=//)
				if [ "$EX_CERT_DOMAIN" == "$DOMAIN" ]; then
					# check renew-date on ex_cert and compare to local ( if local exists)
					enddate_ex=$(echo "$EX_CERT" | openssl x509 -noout -enddate 2>/dev/null| cut -d= -f 2-)
					enddate_lc=$(openssl x509 -noout -enddate < "$CERT_FILE" 2>/dev/null| cut -d= -f 2-)
					if [ "$(date -d "$enddate_ex" +%s)" -gt "$(date -d "$enddate_lc" +%s)" ]; then
						# remote has longer to expiry date than local copy.
						# archive local copy and save remote to local
						cert_archive "$CERT_FILE"
						debug "copying remote certificate to local"
						echo "$EX_CERT" > "$DOMAIN_DIR/${DOMAIN}.crt"
					else
						info "remote expires sooner than local ..... will attempt to upload from local"
						echo "$EX_CERT" > "$DOMAIN_DIR/${DOMAIN}.crt.remote"
						cert_archive "$DOMAIN_DIR/${DOMAIN}.crt.remote"
						copy_file_to_location "domain certificate" "$CERT_FILE" "$DOMAIN_CERT_LOCATION"
						copy_file_to_location "private key" "$DOMAIN_DIR/${DOMAIN}.key" "$DOMAIN_KEY_LOCATION"
						copy_file_to_location "CA certificate" "$CA_CERT" "$CA_CERT_LOCATION"
						cat "$CERT_FILE" "$CA_CERT" > "$TEMP_DIR/${DOMAIN}_chain.pem"
						copy_file_to_location "full pem" "$TEMP_DIR/${DOMAIN}_chain.pem"	"$DOMAIN_CHAIN_LOCATION"
						cat "$DOMAIN_DIR/${DOMAIN}.key" "$CERT_FILE" "$CA_CERT" > "$TEMP_DIR/${DOMAIN}.pem"
						copy_file_to_location "full pem" "$TEMP_DIR/${DOMAIN}.pem"	"$DOMAIN_PEM_LOCATION"
						reload_service
					fi
				else
					info "Certificate on remote domain does not match domain, ignoring remote certificate"
				fi
			fi
		else # local cert doesn't exist"
			debug "local certificate doesn't exist, saving a copy from remote"
			echo "$EX_CERT" > "$DOMAIN_DIR/${DOMAIN}.crt"
		fi # end of .... if local exists
	else
		info "no certificate obtained from host"
	fi # end of .... if obtained a cert
fi # end of .... check_remote is true then connect and obtain the current certificate

# if force renew is set, set the date validity checks to 365 days
if [ $_FORCE_RENEW -eq 1 ]; then
	RENEW_ALLOW=365
fi

# if there is an existsing certificate file, check details.
if [ -f "$CERT_FILE" ]; then
	debug "certificate $CERT_FILE exists"
	enddate=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null| cut -d= -f 2-)
	debug "enddate is $enddate"
	if [[ "$enddate" != "-" ]]; then
		if [[ $(date -d "${RENEW_ALLOW} days" +%s) -lt $(date -d "$enddate" +%s) ]]; then
			info "certificate for $DOMAIN is still valid for more than $RENEW_ALLOW days (until $enddate)"
			# everything is OK, so exit.
			graceful_exit
		else
			# certificate needs renewal, archive current cert and continue.
			debug "certificate	for $DOMAIN needs renewal"
			cert_archive "${CERT_FILE}"
		fi
	fi
fi # end of .... if there is an existsing certificate file, check details.

# create account key if it doesn't exist.
if [ -f "$ACCOUNT_KEY" ]; then
	debug "Account key exists at $ACCOUNT_KEY skipping generation"
else
	info "creating account key $ACCOUNT_KEY"
	openssl genrsa $ACCOUNT_KEY_LENGTH > "$ACCOUNT_KEY"
fi

# check if domain key exists, if not then create it.
if [ -f "$DOMAIN_DIR/${DOMAIN}.key" ]; then
	debug "domain key exists at $DOMAIN_DIR/${DOMAIN}.key - skipping generation"
	# ideally need to check validity of domain key
else
	umask 077
	info "creating domain key - $DOMAIN_DIR/${DOMAIN}.key"
	if [[ "${PRIVATE_KEY_ALG}" == "rsa" ]]; then
		openssl genrsa "$DOMAIN_KEY_LENGTH" > "$DOMAIN_DIR/${DOMAIN}.key"
	elif [[ "${PRIVATE_KEY_ALG}" == "prime256v1" ]]; then
		openssl ecparam -genkey -name prime256v1 > "$DOMAIN_DIR/${DOMAIN}.key"
	else
		error_exit "unknown private key algorithm type ${PRIVATE_KEY_ALG}"
	fi
	umask "$ORIG_UMASK"
fi

#create SAN
if [ -z "$SANS" ]; then
	SANLIST="subjectAltName=DNS:${DOMAIN}"
else
	SANLIST="subjectAltName=DNS:${DOMAIN},DNS:${SANS//,/,DNS:}"
fi
debug "created SAN list = $SANLIST"

# check nslookup for domains
alldomains=$(echo "$DOMAIN,$SANS" | sed "s/,/ /g")
if [[ $VALIDATE_VIA_DNS != "true" ]]; then
		for d in $alldomains; do
			debug "checking nslookup for ${d}"
			# shellcheck disable=SC2034
			exists=$(nslookup "${d}")
			if [ "$?" != "0" ]; then
				error_exit "DNS lookup failed for $d"
			fi
		done
fi


# check if domain csr exists - if not then create it
if [ -f "$DOMAIN_DIR/${DOMAIN}.csr" ]; then
	debug "domain csr exists at - $DOMAIN_DIR/${DOMAIN}.csr"
	# check all domains in config are in csr
	alldomains=$(echo "$DOMAIN,$SANS" | tr -d " " |tr , '\n')
	domains_in_csr=$(openssl req -noout -text -in "$DOMAIN_DIR/${DOMAIN}.csr" |grep "DNS:.*" |tr -d "DNS:" |tr -d " " |tr , '\n')
	for d in $alldomains; do
		if [ "$(echo "${domains_in_csr}"| grep "^${d}$")" != "${d}" ]; then
			info "existing csr at $DOMAIN_DIR/${DOMAIN}.csr does not contain ${d} - re-create-csr .... $(echo "${domains_in_csr}"| grep "^${d}$")"
			_RECREATE_CSR=1
		fi
	done
	# check all domains in csr are in config
	if [ "$alldomains" != "$domains_in_csr" ]; then
		info "existing csr at $DOMAIN_DIR/${DOMAIN}.csr does not have the same domains as the config - re-create-csr"
		_RECREATE_CSR=1
	fi
fi # end of ... check if domain csr exists - if not then create it

# if CSR does not exist, or flag set to recreate, then create csr
if [ ! -f "$DOMAIN_DIR/${DOMAIN}.csr" ] || [ "$_RECREATE_CSR" == "1" ]; then
	debug "creating domain csr - $DOMAIN_DIR/${DOMAIN}.csr"
	openssl req -new -sha256 -key "$DOMAIN_DIR/${DOMAIN}.key" -subj "/" -reqexts SAN -config \
	<(cat "$SSLCONF" <(printf "[SAN]\n%s" "$SANLIST")) > "$DOMAIN_DIR/${DOMAIN}.csr"
fi

# use account key to register with CA
# currrently the code registeres every time, and gets an "already registered" back if it has been.
# public component and modulus of key in base64
pub_exp64=$(openssl rsa -in "${ACCOUNT_KEY}" -noout -text | grep publicExponent | grep -oE "0x[a-f0-9]+" | cut -d'x' -f2 | hex2bin | urlbase64)
pub_mod64=$(openssl rsa -in "${ACCOUNT_KEY}" -noout -modulus | cut -d'=' -f2 | hex2bin | urlbase64)

thumbprint="$(printf '{"e":"%s","kty":"RSA","n":"%s"}' "${pub_exp64}" "${pub_mod64}" | openssl sha -sha256 -binary | urlbase64)"

if [ "$ACCOUNT_EMAIL" ] ; then
	regjson='{"resource": "new-reg", "contact": ["mailto: '$ACCOUNT_EMAIL'"], "agreement": "'$AGREEMENT'"}'
else
	regjson='{"resource": "new-reg", "agreement": "'$AGREEMENT'"}'
fi

info "Registering account"
regjson='{"resource": "new-reg", "agreement": "'$AGREEMENT'"}'
if [ "$ACCOUNT_EMAIL" ] ; then
	regjson='{"resource": "new-reg", "contact": ["mailto: '$ACCOUNT_EMAIL'"], "agreement": "'$AGREEMENT'"}'
fi
# send the request to the ACME server.
send_signed_request	 "$CA/acme/new-reg"	"$regjson"

if [ "$code" == "" ] || [ "$code" == '201' ] ; then
	info "Registered"
	echo "$response" > "$TEMP_DIR/account.json"
elif [ "$code" == '409' ] ; then
	debug "Already registered"
else
	error_exit "Error registering account"
fi
# end of registering account with CA

# verify each domain
info "Verify each domain"

# loop through domains for cert ( from SANS list)
alldomains=$(echo "$DOMAIN,$SANS" | sed "s/,/ /g")
dn=0
for d in $alldomains; do
	# $d is domain in current loop, which is number $dn for ACL
	info "Verifing $d"
	debug "domain $d has location ${ACL[$dn]}"

	# check if we have the information needed to place the challenge
	if [[ $VALIDATE_VIA_DNS == "true" ]]; then
		if [[ -z "$DNS_ADD_COMMAND" ]]; then
			error_exit "DNS_ADD_COMMAND not defined for domain $d"
		fi
		if [[ -z "$DNS_DEL_COMMAND" ]]; then
			error_exit "DNS_DEL_COMMAND not defined for domain $d"
		fi
	else
		if [ -z "${ACL[$dn]}" ]; then
			error_exit "ACL location not specified for domain $d in $DOMAIN_DIR/getssl.cfg"
		fi
	fi

	# request a challenge token from ACME server
	send_signed_request "$CA/acme/new-authz" "{\"resource\": \"new-authz\", \"identifier\": {\"type\": \"dns\", \"value\": \"$d\"}}"

	debug "completed send_signed_request"
	# check if we got a valid response and token, if not then error exit
	if [ ! -z "$code" ] && [ ! "$code" == '201' ] ; then
		error_exit "new-authz error: $response"
	fi

	if [[ $VALIDATE_VIA_DNS == "true" ]]; then # set up the correct DNS token for verification
		# get the dns component of the ACME response
		# shellcheck disable=SC2086
		dns01=$(echo $response | grep -Po	'{[^{]*"type":[ ]*"dns-01"[^}]*')
		debug dns01 "$dns01"

		# get the token from the dns component
		token=$(echo "$dns01" | sed 's/,/\n'/g| grep '"token":'| cut -d '"' -f 4)
		debug token "$token"

		uri=$(echo "$dns01" | sed 's/,/\n'/g| grep '"uri":'| cut -d '"' -f 4)
		debug uri "$uri"

		keyauthorization="$token.$thumbprint"
		debug keyauthorization "$keyauthorization"

		#create signed authorization key from token.
		auth_key=$(printf '%s' "$keyauthorization" | openssl sha -sha256 -binary | openssl base64 -e | tr -d '\n\r' | sed -e 's:=*$::g' -e 'y:+/:-_:')
		debug auth_key "$auth_key"

		debug "adding dns via command: $DNS_ADD_COMMAND $d $auth_key"
		$DNS_ADD_COMMAND "$d" "$auth_key"
		if [ $? -gt 0 ]; then
			error_exit "DNS_ADD_COMMAND failed for domain $d"
		fi

		# find a primary / authoritative DNS server for the domain
		if [ -z "$AUTH_DNS_SERVER" ]; then
			primary_ns=$(nslookup -type=soa "${d}" ${PUBLIC_DNS_SERVER} | grep origin | awk '{print $3}')
			if [ -z "$primary_ns" ]; then
				primary_ns=$(nslookup -type=soa "${d}" -debug=1 ${PUBLIC_DNS_SERVER} | grep origin | awk '{print $3}')
			fi
		else
			primary_ns="$AUTH_DNS_SERVER"
		fi
		debug primary_ns "$primary_ns"

		# make a directory to hold pending dns-challenges
		if [ ! -d "$TEMP_DIR/dns_verify" ]; then
			mkdir "$TEMP_DIR/dns_verify"
		fi

		# generate a file with the current variables for the dns-challenge
		cat > "$TEMP_DIR/dns_verify/$d" <<- _EOF_
		token="${token}"
		uri="${uri}"
		keyauthorization="${keyauthorization}"
		d="${d}"
		primary_ns="${primary_ns}"
		auth_key="${auth_key}"
		_EOF_

	else			# set up the correct http token for verification
		# get the http component of the ACME response
		# shellcheck disable=SC2086
		http01=$(echo $response | grep -Po '{[ ]*"type":[ ]*"http-01"[^}]*')
		debug http01 "$http01"

		# get the token from the http component
		token=$(echo "$http01" | sed 's/,/\n'/g| grep '"token":'| cut -d '"' -f 4)
		debug token "$token"

		uri=$(echo "$http01" | sed 's/,/\n'/g| grep '"uri":'| cut -d '"' -f 4)
		debug uri "$uri"

		#create signed authorization key from token.
		keyauthorization="$token.$thumbprint"
		debug keyauthorization "$keyauthorization"

		# save variable into temporary file
		echo -n "$keyauthorization" > "$TEMP_DIR/$token"
		chmod 755 "$TEMP_DIR/$token"

		# copy to token to acme challenge location
		debug "copying file from $TEMP_DIR/$token to ${ACL[$dn]}"
		copy_file_to_location "challenge token" "$TEMP_DIR/$token" "${ACL[$dn]}/$token"

		wellknown_url="http://$d/.well-known/acme-challenge/$token"
		debug wellknown_url "$wellknown_url"

		# check that we can reach the challenge ourselves, if not, then error
		if [ ! "$(curl --silent --location "$wellknown_url")" == "$keyauthorization" ]; then
			error_exit "for some reason could not reach $wellknown_url - please check it manually"
		fi

		check_challenge_completion "$uri" "$d" "$keyauthorization"

		debug "remove token from ${ACL[$dn]}"
		if [[ "${ACL[$dn]:0:4}" == "ssh:" ]] ; then
			sshhost=$(echo "${ACL[$dn]}"| awk -F: '{print $2}')
			command="rm -f ${ACL[$dn]:(( ${#sshhost} + 5))}/${token:?}"
			debug "running following comand to remove token"
			debug "ssh $sshhost ${command}"
			# shellcheck disable=SC2029
			ssh "$sshhost" "${command}" 1>/dev/null 2>&1
			rm -f "${TEMP_DIR:?}/${token:?}"
		elif [[ "${ACL[$dn]:0:4}" == "ftp:" ]] ; then
			debug "using ftp to remove token file"
			ftpuser=$(echo "${ACL[$dn]}"| awk -F: '{print $2}')
			ftppass=$(echo "${ACL[$dn]}"| awk -F: '{print $3}')
			ftphost=$(echo "${ACL[$dn]}"| awk -F: '{print $4}')
			ftplocn=$(echo "${ACL[$dn]}"| awk -F: '{print $5}')
			debug "ftp user=$ftpuser - pass=$ftppass - host=$ftphost loction=$ftplocn"
			ftp -n <<- EOF
			open $ftphost
			user $ftpuser $ftppass
			cd $ftplocn
			delete ${token:?}
			EOF
		else
			rm -f "${ACL[$dn]:?}/${token:?}"
		fi
	fi
	# increment domain-counter
	let dn=dn+1;
done # end of ... loop through domains for cert ( from SANS list)

# perform validation if via DNS challenge
if [[ $VALIDATE_VIA_DNS == "true" ]]; then
	# loop through dns-variable files to check if dns has been changed
	for dnsfile in $TEMP_DIR/dns_verify/*; do
		debug "loading DNSfile: $dnsfile"
		. "$dnsfile"

		# check for token at public dns server, waiting for a valid response.
		ntries=0
		check_dns="fail"
		while [ "$check_dns" == "fail" ]; do
			check_result=$(nslookup -type=txt "_acme-challenge.${d}" "${primary_ns}" | grep ^_acme|awk -F'"' '{ print $2}')
			debug result "$check_result"

			if [[ "$check_result" == "$auth_key" ]]; then
				check_dns="success"
				debug "checking DNS ... _acme-challenge.$d gave $check_result"
			else
				if [[ $ntries -lt 100 ]]; then
					ntries=$(( ntries + 1 ))
					info "checking DNS for ${d}. Attempt $ntries/100 gave wrong result, waiting $DNS_WAIT secs before checking again"
					sleep $DNS_WAIT
				else
					debug "dns check failed - removing existing value"
					error_exit "checking _acme-challenge.$DOMAIN gave $check_result not $auth_key"
				fi
			fi
		done
	done

	if [ "$DNS_EXTRA_WAIT" != "" ]; then
		info "sleeping $DNS_EXTRA_WAIT seconds before asking the ACME-server to check the dns"
		sleep "$DNS_EXTRA_WAIT"
	fi

	# loop through dns-variable files to let the ACME server check the challenges
	for dnsfile in $TEMP_DIR/dns_verify/*; do
		debug "loading DNSfile: $dnsfile"
		. "$dnsfile"

		check_challenge_completion "$uri" "$d" "$keyauthorization"

		debug "remove DNS entry"
		$DNS_DEL_COMMAND "$d"
		# remove $dnsfile after each loop.
		rm -f "$dnsfile"
	done
fi # end of ... perform validation if via DNS challenge

# Verification has been completed for all SANS, so	request certificate.
info "Verification completed, obtaining certificate."
der=$(openssl req	-in "$DOMAIN_DIR/${DOMAIN}.csr" -outform DER | urlbase64)
debug "der $der"
send_signed_request "$CA/acme/new-cert" "{\"resource\": \"new-cert\", \"csr\": \"$der\"}" "needbase64"

# convert certificate information into correct format and save to file.
CertData=$(grep -i -o '^Location.*' "$CURL_HEADER" |sed 's/\r//g'| cut -d " " -f 2)
if [ "$CertData" ] ; then
	echo -----BEGIN CERTIFICATE----- > "$CERT_FILE"
	curl --silent "$CertData" | openssl base64 -e	>> "$CERT_FILE"
	echo -----END CERTIFICATE-----	>> "$CERT_FILE"
	info "Certificate saved in $CERT_FILE"
fi

# If certificate wasn't a valid certificate, error exit.
if [ -z "$CertData" ] ; then
	response2=$(echo "$response" | openssl base64 -e)
	debug "respose was $response"
	error_exit "Sign failed: $(echo "$response2" | grep -o	'"detail":"[^"]*"')"
fi

# get a copy of the CA certificate.
IssuerData=$(grep -i '^Link' "$CURL_HEADER" | cut -d " " -f 2| cut -d ';' -f 1 | sed 's/<//g' | sed 's/>//g')
if [ "$IssuerData" ] ; then
	echo -----BEGIN CERTIFICATE----- > "$CA_CERT"
	curl --silent "$IssuerData" | openssl base64 -e	>> "$CA_CERT"
	echo -----END CERTIFICATE-----	>> "$CA_CERT"
	info "The intermediate CA cert is in $CA_CERT"
fi

# copy certs to the correct location (creating concatenated files as required)

copy_file_to_location "domain certificate" "$CERT_FILE" "$DOMAIN_CERT_LOCATION"
copy_file_to_location "private key" "$DOMAIN_DIR/${DOMAIN}.key" "$DOMAIN_KEY_LOCATION"
copy_file_to_location "CA certificate" "$CA_CERT" "$CA_CERT_LOCATION"
cat "$CERT_FILE" "$CA_CERT" > "$TEMP_DIR/${DOMAIN}_chain.pem"
copy_file_to_location "full pem" "$TEMP_DIR/${DOMAIN}_chain.pem"	"$DOMAIN_CHAIN_LOCATION"
cat "$DOMAIN_DIR/${DOMAIN}.key" "$CERT_FILE" "$CA_CERT" > "$TEMP_DIR/${DOMAIN}.pem"
copy_file_to_location "full pem" "$TEMP_DIR/${DOMAIN}.pem"	"$DOMAIN_PEM_LOCATION"

# Run reload command to restart apache / nginx or whatever system

reload_service

# Check if the certificate is installed correctly
if [[ ${CHECK_REMOTE} == "true" ]]; then
	CERT_REMOTE=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${REMOTE_PORT}" 2>/dev/null | openssl x509 -noout -fingerprint 2>/dev/null)
	CERT_LOCAL=$(openssl x509 -noout -fingerprint < "$CERT_FILE" 2>/dev/null)
	if [ "$CERT_LOCAL" == "$CERT_REMOTE" ]; then
		info "certificate installed OK on server"
	else
		error_exit "certificate on server is different from local certificate"
	fi
fi

# To have reached here, a certificate should have been successfully obtained.	Ese echo rather than info so that 'quiet' is ignored.
echo "certificate obtained for ${DOMAIN}"

graceful_exit
