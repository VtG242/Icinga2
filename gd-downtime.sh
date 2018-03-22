#!/usr/bin/env bash

#TODO
#Message in case that package exists
#show json response only when debug is used
#test validity of date of week and timerange
#generation of config for global downtime
#better parameters handling
#curl calls as function
#handling error states for -l -u option
#check that downtime is really set on some host and service using dummy objects

function gettime()
{
  date +"%Y-%m-%d %H:%M:%S"
}
function help()
{
    echo "Usage:"
    echo ""
    echo "Downtime set:"
    echo "-d datacenter (na, eu1, ca1)"
    echo "-t ticket"
    echo "-r range in format start(HH:MM)-stop(HH-MM)"
    echo "-w day in week as string"
    echo "Example: $0 -t GD1234 -d ca1 -w saturday -r 08:00-12:00"
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

# params to vars
while getopts ":d:lr:t:u:w:" opt; do
    case $opt in
    d)
        ispemptyexit $OPTARG
        DC="$OPTARG"
        ;;
    l)
        #list package
        STEP0FILE="$TMPDIR/step0.$PID"
        CURL0=`curl --silent --output $STEP0FILE \
        --write-out "%{http_code}" \
        -u : --negotiate \
        --include -H "Accept: application/json" \
        "${ICINGAHOST}/v1/config/packages"`
        CURLRT="$?"
        echo "List of downtime packages:"
        tail -n1 $STEP0FILE | jq '.results[] | .name' | grep -v "^\"_" | grep "down-"
        rm -f $STEP0FILE
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
        PKG2DEL="$OPTARG"
        #delete package
        STEP0FILE="$TMPDIR/step0.$PID"
        CURL0=`curl --silent --output $STEP0FILE \
        --write-out "%{http_code}" \
        -u : --negotiate \
        --include -H "Accept: application/json" \
        --request DELETE "${ICINGAHOST}/v1/config/packages/${PKG2DEL}"`
        CURLRT="$?"
        tail -n1 $STEP0FILE | jq
        rm -f $STEP0FILE
        exit 0
        ;;
    w)
        ispemptyexit $OPTARG
        DAYINWEEK="$OPTARG"
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
for VARIABLE in "$DC" "$RANGE" "$JIRA" "$DAYINWEEK"
do
    if [ -z "$VARIABLE" ]; then
        echo "ERROR - Mandatory parameters missing or are empty." >&2
        help
        exit 1
    fi
done

STEP1FILE="$TMPDIR/step1.$PID"
STEP2FILE="$TMPDIR/step2.$PID"
STEP3FILE="$TMPDIR/step3.$PID"

declare -A DC2CLUSTER
DC2CLUSTER["na"]="51"
DC2CLUSTER["eu1"]="101"
DC2CLUSTER["ca1"]="151"

# test if given cluster exists
if [ -z ${DC2CLUSTER["$DC"]} ]; then
    echo "ERROR - given datacenter(${DC}) doesn't exist."
    exit 1
fi

COMMENT="Platform maintenance - $JIRA"
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
    CONFDEF='apply ScheduledDowntime \"'"$DC"'-host-down-'"$JIRA"'\" to Host {author=\"'"$USER"'\", comment=\"'"$COMMENT"'\", ranges={'"$DAYINWEEK"'=\"'"$RANGE"'\"}, assign where \"Cluster '"${DC2CLUSTER[$DC]}"'\" in host.groups}\napply ScheduledDowntime \"'"$DC"'-service-down-'"$JIRA"'\" to Service {author=\"'"$USER"'\", comment=\"'"$COMMENT"'\", ranges={'"$DAYINWEEK"'=\"'"$RANGE"'\"}, assign where \"Cluster '"${DC2CLUSTER[$DC]}"'\" in host.groups}'
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
