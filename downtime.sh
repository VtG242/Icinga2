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
#Test that jq binary is available
#Message in case that package exists
#Logic how APIUPLOADCONFDATA will be assemble in case of given parameters - downtime for na,ca1,eu1 or for all dcs

ICINGAHOST="https://icinga2-master01.na.intgdc.com:8443"
APICREATEPACKAGE="/v1/config/packages/VVO"
APIUPLOADCONF="/v1/config/stages/VVO"
APIUPLOADCONFDATA='{ "files": { "zones.d/na/VV0-downtime.conf": "apply ScheduledDowntime \"host-downtime-vvo\" to Host {author=\"VVO\", comment=\"Maintenance for host - VVO\", ranges={tuesday=\"20:00-20:05\"}, assign where \"Cluster 7001\" in host.groups}\napply ScheduledDowntime \"service-downtime-vvo\" to Service {author=\"VVO\", comment=\"Maintenance for service - VVO\", ranges ={thursday=\"20:00-20:05\"}, assign where \"Cluster 7001\" in host.groups}"}}'
APISTAGELOG="/v1/config/files/VVO"

curl --silent --output $STEP1FILE \
    --write-out "$(gettime) Step 1 - Creating of config package:  $APICREATEPACKAGE --> %{http_code}\n" \
    -u : --negotiate \
    --include -H "Accept: application/json" \
    --request POST "$ICINGAHOST$APICREATEPACKAGE"
CURLRT="$?"

if [ "$CURLRT" -gt 0 ]; then
    echo "ERROR during contacting Icinga2 API - curl returned code $CURLRT - check https://curl.haxx.se/libcurl/c/libcurl-errors.html for details."
    exit 1
fi

tail -n1 $STEP1FILE;echo ""

curl --silent --output $STEP2FILE \
    --write-out "$(gettime) Step 2 - Uploading configuration:  $APIUPLOADCONF --> %{http_code}\n" \
    -u : --negotiate \
    --include -H "Accept: application/json" \
    --request POST "$ICINGAHOST$APIUPLOADCONF" \
    -d "$APIUPLOADCONFDATA"
tail -n1 $STEP2FILE;echo ""

# in case that request ended with 200 a startup.log will be displayed
if [ `cat $STEP2FILE | grep HTTP/1.1 | awk {'print $2'} | tail -n1` == "200" ];then

    STAGE=`tail -n1 $STEP2FILE | jq -r .results[0].stage`

    while :
    do
        #poll to startup.log
        curl  --silent --output $STEP3FILE \
            --write-out "$(gettime) Step 3 - Configuration package stage details:  $APISTAGELOG/$STAGE/startup.log --> %{http_code}\n" \
            -u : --negotiate \
            --include \
            "$ICINGAHOST$APISTAGELOG/$STAGE/startup.log"

        case `cat $STEP3FILE | grep HTTP/1.1 | awk {'print $2'} | tail -n1` in
        200)
            NOERR=`cat $STEP3FILE | grep error | wc -l`
            if [ $NOERR -gt 0 ]; then
                echo "ERROR durring applying downtime configuration check details below:"
                grep -v "Negotiate" $STEP3FILE
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
    echo "ERROR during uploading configuration check details below:":
    grep -v "Negotiate" $STEP2FILE
    ES=1
fi

END=$(date +%s)

echo "$(gettime) API request comleted in $(($END - $START)) seconds with status $ES."
#clean the mess
rm -f $STEP1FILE $STEP2FILE $STEP3FILE

exit $ES
