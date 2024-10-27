#!/bin/bash

# So that it exits on error
set -e

# Defaults
force=false
verbose=false

# Secret stuff, protect these files properly!
myemail=$(cat .myemail)
zone_id=$(cat .zone_id)
record_id=$(cat .record_id)
token=$(cat .dns_token)
domain=$(cat .domain)

usage()
{
    echo -e "Usage: ip-change [-h][-f][-v]\n"
    echo -e "  -h: print this message\n"
    echo -e "  -f: force update (default: check whether IP changed)\n"
    echo -e "  -v: verbose update (default: email on IP change or error)\n"
}

# Check public IPv4 with three methods
# If at least two agree and the format fits, accept
# Otherwise send email
# Not checked: are the numbers <=255?
get_public_ip()
{
    ip1=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/"//g')
    ip2=$(curl -s -4 ifconfig.me)
    ip3=$(wget -qO  - checkip.amazonaws.com)

    if [[ "$ip1" == "$ip2" && "$ip" == "$ip3" && "$ip1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip1"
    elif [[ "$ip1" == "$ip2" && "$ip1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip1"
    elif [[ "$ip2" == "$ip3" && "$ip2" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip2"
    elif [[ "$ip1" == "$ip3" && "$ip1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip1"
    else
        echo "IP detection failed\nip1=$ip1\nip2=$ip2\nip3=$ip3" | \
             mail -s "IP detection failed" "$myemail"
        return 1
    fi
}

update_dns_cf()
{
    # Easier to read if we name variables
    zone_id="$1"
    record_id="$2"
    dns_token="$3"
    domain="$4"
    ip="$5"
    
    # Note the multiple quotes for the domain name and ip
    # This is needed to expand variables inside a json string, see
    # https://unix.stackexchange.com/questions/312702/bash-variable-substitution-in-a-json-string
    curl -s --request PATCH \
      --url https://api.cloudflare.com/client/v4/zones/"$zone_id"/dns_records/"$record_id" \
      --header "Authorization: Bearer $token" \
      --header "Content-Type: application/json" \
      --data '{
      "comment": "External IP",
      "name": "'"$domain"'",
      "proxied": false,
      "settings": {},
      "tags": [],
      "ttl": 1,
      "content": "'"$ip"'",
      "type": "A"
    }'
}

# In the case of duckdns we don't have to provide an IP,
# as by default it sets the IP to that of the sender
# TODO: maybe do it so that this return a kind of json
# string so that the result parsing is the same as for
# the Cloudflare one
update_dns_duckdns()
{
    domains="$1"
    token=$(cat /path/to/duck.token)
    url="https://www.duckdns.org/update?domains=$domains&token=$token"

    result=$(echo "url=$url" | curl -s -K -)

    # Retry a few times if it does not work
    if [[ "$result" != "OK" ]]; then
        max_retry=5
        retry=0
        while [[ "$result" != "OK" && "$retry" < "$max_retry" ]]; do
            sleep 5
            result=$(echo "url=$url" | curl -s -K -)
            retry=$((retry+1))
        done
    fi

    if [[ "$result" == "OK" ]]; then
        echo 0
    elif [[ "$result" == "KO" ]]; then
        echo 1
    elif grep -q "502 Bad Gateway" "$result"; then
        echo 2
    else
        echo 3 # Unknown error
    fi
}

while getopts ":fv" opt; do
    case $opt in
        f)
            force=true ;;
        v)
            verbose=true ;;
        h)
            usage && exit 0 ;;
        \?)
            usage && exit 1 ;;
    esac
done

# Force & verbose:
# No check old IP, no email is sent
if $force && $verbose; then
    myip=$(get_public_ip)

    update_status=$(update_dns_cf "$zone_id" "$record_id" "$token" "$domain" "$myip")

    # Use python to parse the json output because it's already there
    # We could use jq or similar but this works
    if [[ $(echo "$update_status" | \
            python3 -c "import sys, json; print(json.load(sys.stdin)['success'])") \
            == "True" ]]; then
      # Only update file if successful!
      echo "$myip" > ./.myoldip
      echo "Update successful, new ip $myip"
    else
       template="import sys, json;"
      template+="output=json.load(sys.stdin);"
      template+="print('CF DNS update failed with code',end=' ');"
      template+="print(output['errors'][0]['code'],end=': ');"
      template+="print(output['errors'][0]['message'])"
      echo -n "$update_status" | python3 -c "$template"
    fi

# Verbose but not force:
# Check old IP, no email is sent
elif $verbose; then
    myip=$(get_public_ip)
    myoldip=$(cat ./.myoldip)
    echo "New ip: $myip, old IP: $myoldip"
    if [[ "$myip" == "$myoldip" ]]; then
        echo "IP did not change"
    else
        update_status=$(update_dns_cf "$zone_id" "$record_id" "$token" "$domain" "$myip")

        # Use python to parse the json output because it's already there
        # We could use jq or similar but this works
        if [[ $(echo "$update_status" | \
                python3 -c "import sys, json; print(json.load(sys.stdin)['success'])") \
                == "True" ]]; then
            # Only update file if successful!
            echo "$myip" > ./.myoldip
            echo "Update successful, new ip $myip"
        else
           template="import sys, json;"
          template+="output=json.load(sys.stdin);"
          template+="print('CF DNS update failed with code',end=' ');"
          template+="print(output['errors'][0]['code'],end=': ');"
          template+="print(output['errors'][0]['message'])"
          echo -n "$update_status" | python3 -c "$template" && echo "New IP: $myip"
        fi

    fi

# Force but not verbose:
# No check old ip, email is sent
elif $force; then
    myip=$(get_public_ip)
    update_status=$(update_dns_cf "$zone_id" "$record_id" "$token" "$domain" "$myip")

    # Use python to parse the json output because it's already there
    # We could use jq or similar but this works
    if [[ $(echo "$update_status" | \
            python3 -c "import sys, json; print(json.load(sys.stdin)['success'])") \
            == "True" ]]; then
        # Only update file if successful!
        echo "$myip" > ./.myoldip
        echo "Current IP: $myip" | mail -s "Forced DNS update successful" "$myemail"
    else
        template="import sys, json;"
        template+="output=json.load(sys.stdin);"
        template+="print('CF DNS update failed with code',end=' ');"
        template+="print(output['errors'][0]['code'],end=': ');"
        template+="print(output['errors'][0]['message'])"
        result=$(echo -n "$update_status" | python3 -c "$template")
        echo -e "$result\nNew IP: $myip" | mail -s "Forced DNS update failed" "$myemail"
    fi

# Default case: not force, not verbose
# Check old ip, email is sent if changed
else
    myip=$(get_public_ip)
    myoldip=$(cat ./.myoldip)

    if [[ "$myip" != "$myoldip" ]]; then
        update_status=$(update_dns_cf "$zone_id" "$record_id" "$token" "$domain" "$myip")

        # Use python to parse the json output because it's already there
        # We could use jq or similar but this works
        if [[ $(echo "$update_status" | \
                python3 -c "import sys, json; print(json.load(sys.stdin)['success'])") \
                == "True" ]]; then
            # Only update file if successful!
            echo "$myip" > ./.myoldip
            echo "Current IP: $myip" | mail -s "IP changed, DNS update successful" "$myemail"
        else
            template="import sys, json;"
            template+="output=json.load(sys.stdin);"
            template+="print('CF DNS update failed with code',end=' ');"
            template+="print(output['errors'][0]['code'],end=': ');"
            template+="print(output['errors'][0]['message'])"
            result=$(echo -n "$update_status" | python3 -c "$template")
            echo -e "$result\nNew IP: $myip" | mail -s "IP changed, DNS update failed" "$myemail"
        fi
    fi

fi
