#!/usr/bin/env bash

#TODO
#Message in case that package exists
#show json response only when debug is used
#generation of config for global downtime
#check that downtime is really set on some host and service

function gettime()
{
  date +"%Y-%m-%d %H:%M:%S"
}
function help()
{
    echo "Kerberos is used for authentication to Icinga2 API - run kinit before use"
    echo ""
    echo "Usage:"
    echo ""
    echo "Downtime set:"
    echo "-d datacenter (na, eu1, ca1)"
    echo "-t ticket"
    echo "-w date in format YYYY-MM-DD"
    echo "-r range in format start(HH:MM)-stop(HH-MM) - multiple ranges has to be delimited by coma (see examples)"
    echo "Examples:"
    echo "$0 -t GD1234 -d ca1 -w 2018-03-01 -r 08:00-12:00"
    echo "$0 -t GD1235 -d eu1 -w 2018-12-24 -r 08:00-12:00,16:00-18:00"
    echo ""
    echo "Downtime unset:"
    echo "-l list of set downtimes"
    echo "-u unset given downtime"
    echo "Example: $0 -u na-down-GD1234"
}
function ispemptyexit()
{
    if [[ $1 = -* ]]; then
        echo "ERROR: all given parameters MUST have value." >&2
        help
        exit 1
     fi
}
# processing of curl response for step1 commands
function curl_response()
{
    CURLRT="$?"
    CURLOUT=$1
    echo ${CURLOUT}
    if [ "$CURLRT" -gt 0 ]; then
        echo "ERROR during contacting Icinga2 API - curl returned code $CURLRT - check https://curl.haxx.se/libcurl/c/libcurl-errors.html for details." >&2
        exit 1
    fi
    if [ "$CURLOUT" != "200" ]; then
        echo "ERROR - check details below:" >&2
        # strip base auth string for case it will be run from systems which perform logging of output
        grep -v "Negotiate" $STEP1FILE >&2
        rm -f $STEP1FILE
        exit 1
    fi
}

# jq is used within the script
if ! [ -x "$(command -v jq)" ]; then
    echo 'ERROR: jq(https://stedolan.github.io/jq) not found but required by downtime script.' >&2
    exit 1
fi

# parameters required
if [[ ! $@ =~ ^\-.+ ]]; then
  help
  exit 1
fi

ICINGAHOST="https://icinga2-master01.na.intgdc.com:8443"
START=$(date +%s)
PID=$$
ES=0
RETRY=30

STEP1FILE="$TMPDIR/step1.$PID"
STEP2FILE="$TMPDIR/step2.$PID"
STEP3FILE="$TMPDIR/step3.$PID"

declare -A DC2CLUSTER
DC2CLUSTER["na"]="51"
DC2CLUSTER["eu1"]="101"
DC2CLUSTER["ca1"]="151"

# params to vars
while getopts ":d:lr:t:u:w:" opt; do
    case $opt in
    d)
        ispemptyexit $OPTARG
        DC="$OPTARG"
        ;;
    l)
        #list package
        APILISTPKGS="/v1/config/packages"
        echo -n "$(gettime) List of downtime packages: ${APILISTPKGS} --> "
        curl_response $(curl -s -o $STEP1FILE --write-out "%{http_code}" -u : --negotiate -i -H "Accept: application/json" "${ICINGAHOST}${APILISTPKGS}")
        tail -n1 $STEP1FILE | jq '.results[] | .name' | grep -v "^\"_" | grep "down-"
        rm -f $STEP1FILE
        exit 0
        ;;
    r)
        ispemptyexit $OPTARG
        RANGE="$OPTARG"
        ;;
    t)
        ispemptyexit $OPTARG
        JIRA="$OPTARG"
        ;;
    u)
        ispemptyexit $OPTARG
        APIPKGDEL="/v1/config/packages/${OPTARG}"
        #delete package
        echo -n "$(gettime) Delete downtime package: ${APIPKGDEL} --> "
        curl_response $(curl -s -o $STEP1FILE --write-out "%{http_code}" -u : --negotiate -i -H "Accept: application/json" --request DELETE "${ICINGAHOST}${APIPKGDEL}")
        tail -n1 $STEP1FILE | jq
        rm -f $STEP1FILE
        exit 0
        ;;
    w)
        ispemptyexit $OPTARG
        if [[ $OPTARG =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            date -d "$OPTARG" +"%Y-%m-%d" > /dev/null 2>&1
            if [ "$?" -gt 0 ]; then
                echo "Ivalid date: -w ${OPTARG}" >&2
                exit 1
            fi
        else
            echo "Ivalid date format: -w ${OPTARG}" >&2
            exit 1
        fi
        DAY="$OPTARG"
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        help
        exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      help
      exit 1
      ;;
  esac
done

# params values must be given
for VARIABLE in "$DC" "$RANGE" "$JIRA" "$DAY"
do
    if [ -z "$VARIABLE" ]; then
        echo "ERROR - Mandatory parameters missing or are empty." >&2
        help
        exit 1
    fi
done

# test if given cluster exists
if [ -z ${DC2CLUSTER["$DC"]} ]; then
    echo "ERROR - given datacenter(${DC}) doesn't exist."
    exit 1
fi

COMMENT="Platform maintenance $JIRA"
ICINGAPKG="${DC}-down-${JIRA}"
APICREATEPACKAGE="/v1/config/packages/$ICINGAPKG"
APIUPLOADCONF="/v1/config/stages/$ICINGAPKG"
APISTAGELOG="/v1/config/files/$ICINGAPKG"

#main downtime configuration
CONFFILE='zones.d/'"$DC"'/'"$DC"'-down-'"$JIRA"'.conf'
#on the basics of parameters a particular API command is constructed
case $DC in
"global")
    ;;
*)
    CONFDEF='apply ScheduledDowntime \"'"$DC"'-host-down-'"$JIRA"'\" to Host {author=\"'"$USER"'\", comment=\"'"$COMMENT"'\", ranges={\"'"$DAY"'\"=\"'"$RANGE"'\"}, assign where \"Cluster '"${DC2CLUSTER[$DC]}"'\" in host.groups}\napply ScheduledDowntime \"'"$DC"'-service-down-'"$JIRA"'\" to Service {author=\"'"$USER"'\", comment=\"'"$COMMENT"'\", ranges={\"'"$DAY"'\"=\"'"$RANGE"'\"}, assign where \"Cluster '"${DC2CLUSTER[$DC]}"'\" in host.groups}'
    APIUPLOADCONFDATA='{ "files": { "'"$CONFFILE"'" : "'"$CONFDEF"'"}}'
    ;;
esac

echo -n "$(gettime) Step 1 - Creating of downtime config package: ${APICREATEPACKAGE} --> "
curl_response $(curl -s -o $STEP1FILE --write-out "%{http_code}" -u : --negotiate -i -H "Accept: application/json" --request POST "${ICINGAHOST}${APICREATEPACKAGE}")
tail -n1 $STEP1FILE | jq;echo ""

CURL2=`curl --silent --output $STEP2FILE \
    --write-out "%{http_code}\n" \
    -u : --negotiate \
    --include -H "Accept: application/json" \
    --request POST "$ICINGAHOST$APIUPLOADCONF" \
    -d "$APIUPLOADCONFDATA"`
CURLRT="$?"

echo "$(gettime) Step 2 - Uploading configuration:  $APIUPLOADCONF --> $CURL2"
echo $APIUPLOADCONFDATA | jq
tail -n1 $STEP2FILE | jq;echo ""

# in case that request ended with 200 a startup.log will be displayed
if [ $CURL2 == "200" ];then

    # pick current stage id
    STAGE=`tail -n1 $STEP2FILE | jq -r .results[0].stage`

    while :
    do
        #poll to startup.log
        CURL3=`curl  --silent --output $STEP3FILE \
            --write-out "%{http_code}\n" \
            -u : --negotiate \
            --include \
            "$ICINGAHOST$APISTAGELOG/$STAGE/startup.log"`
        CURLRT="$?"

        echo "$(gettime) Step 3 - Configuration package stage details:  $APISTAGELOG/$STAGE/startup.log --> $CURL3"

        case "$CURL3" in
        200)
            NOERR=`cat $STEP3FILE | grep error | wc -l`
            if [ $NOERR -gt 0 ]; then
                echo "ERROR durring applying downtime configuration - check details below:" >&2
                grep -v "Negotiate" $STEP3FILE >&2
                ES=1
            else
                cat $STEP3FILE | grep ScheduledDowntimes
                echo "Downtime has been applied without errors and it will take some time than it appears within Icinga2Web."
                ES=0
            fi
            break
            ;;
        *)
            if [ $RETRY == "0" ]; then
                echo "A numer of max attempts to get a state of stage reached ... give it up."
                break;
                ES=1
            fi
            #echo "Debug: $RETRY"
            echo "INFO: The config stage hasn't been applied - next retry in 10 seconds ..."
            sleep 10
            let "RETRY-=1";
            ;;
         esac
    done

else
    echo "ERROR during uploading configuration - check details below:" >&2
    grep -v "Negotiate" $STEP2FILE >&2
    ES=1
fi

END=$(date +%s)

echo "$(gettime) API request comleted in $(($END - $START)) seconds with status $ES."
#clean the mess
rm -f $STEP1FILE $STEP2FILE $STEP3FILE

exit $ES
