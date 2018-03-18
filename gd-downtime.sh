#!/usr/bin/env bash

function gettime()
{
  date +"%Y-%m-%d %H:%M:%S"
}

START=$(date +%s)
PID=$$
ES=0
RETRY=30

STEP1FILE="$TMPDIR/step1.$PID"
STEP2FILE="$TMPDIR/step2.$PID"
STEP3FILE="$TMPDIR/step3.$PID"

#TODO
#Message in case that package exists
#show json response only when debug is used
#test validity of date of week and timerange
#generation of config for global downtime
#better parameters handling

# jq is used within the script
if ! [ -x "$(command -v jq)" ]; then
    echo 'ERROR: jq(https://stedolan.github.io/jq) not found but required by downtime script.' >&2
    exit 1
fi

declare -A DC2CLUSTER
DC2CLUSTER["na"]="51"
DC2CLUSTER["eu1"]="101"
DC2CLUSTER["ca1"]="151"

#test existence of input parameters
if [ "$#" -ne 4 ]; then
    echo "ERROR - not all required parameters given."
    echo "Usage: $0 [datacenter] [dayinweek] [time range] [jira ticket]"
    echo "Example: $0 ca1 saturday 08:00-12:00 GD-666"
    exit 1
fi

DC="$1"
DAYINWEEK="$2"
RANGE="$3"
JIRA="$4"

if [ -z ${DC2CLUSTER["$DC"]} ]; then
    echo "ERROR - given datacenter($DC) doesn't exist."
    exit 1
fi

COMMENT="Platform maintenance - $JIRA"
ICINGAHOST="https://icinga2-master01.na.intgdc.com:8443"
ICINGAPKG="$DC-downtime"
APICREATEPACKAGE="/v1/config/packages/$ICINGAPKG"
APIUPLOADCONF="/v1/config/stages/$ICINGAPKG"
APISTAGELOG="/v1/config/files/$ICINGAPKG"
#main downtime configuration
CONFFILE='zones.d/'"$DC"'/'"$DC"'-downtime.conf'
#on the basics of parameters a particular API command is constructed
case $DC in
"global")
    ;;
*)
    CONFDEF='apply ScheduledDowntime \"'"$DC"'-host-downtime\" to Host {author=\"'"$USER"'\", comment=\"'"$COMMENT"'\", ranges={'"$DAYINWEEK"'=\"'"$RANGE"'\"}, assign where \"Cluster '"${DC2CLUSTER[$DC]}"'\" in host.groups}\napply ScheduledDowntime \"'"$DC"'-service-downtime\" to Service {author=\"'"$USER"'\", comment=\"'"$COMMENT"'\", ranges={'"$DAYINWEEK"'=\"'"$RANGE"'\"}, assign where \"Cluster '"${DC2CLUSTER[$DC]}"'\" in host.groups}'
    APIUPLOADCONFDATA='{ "files": { "'"$CONFFILE"'" : "'"$CONFDEF"'"}}'
    ;;
esac

CURL1=`curl --silent --output $STEP1FILE \
    --write-out "%{http_code}" \
    -u : --negotiate \
    --include -H "Accept: application/json" \
    --request POST "$ICINGAHOST$APICREATEPACKAGE"`
CURLRT="$?"

echo "$(gettime) Step 1 - Creating of config package:  $APICREATEPACKAGE --> $CURL1"

if [ "$CURLRT" -gt 0 ]; then
    echo "ERROR during contacting Icinga2 API - curl returned code $CURLRT - check https://curl.haxx.se/libcurl/c/libcurl-errors.html for details." >&2
    exit 1
elif [ "$CURL1" != "200" ]; then
    echo "ERROR - check details below:" >&2
    cat $STEP1FILE >&2
    exit 1
else
    tail -n1 $STEP1FILE | jq;echo ""
fi

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

        echo "$(gettime) Step 3 - Configuration package stage details:  $APISTAGELOG/$STAGE/startup.log --> "

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
