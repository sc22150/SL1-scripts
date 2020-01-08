#!/bin/bash
# Author: Steve Chapman (stevcha@cdw.com)
# Purpose: Provide insight into SIGTERM log messages
#
# New in version:
#  1.3 - Expanded device and app reports to include what failed with what
#      - Dev report shows collection frequency, with * if override in place
#  1.2 - Support for reviewing a collector group
#      - introduced log_it function to reduce code size
#  1.1 - MySQL errors suppressed
#      - Invalid process ID check added
#      - List collectors in columns to fit screen
#      - List device results in columns on screen
#      - Clean up text when no results found
#      - Code clean-up
#      - Support for using Collector Name instead of ID
#
VER="1.3"
re='^[0-9]+$'
declare -a APP_CAT DEV_CAT

help_msg () {
        echo ; echo "Usage: $0 [-c {collector ID}] [-g {Collector Group ID}] [-o {output file}] [-p {process ID}] [-t {date}] [-d] [-i] [-s] [-a] [-f] [-s] [-h] [-v]"
        echo "  Where:"
        echo "    -a = Availability SIGTERMs"
        echo "    -c = Collector appliance ID"
        echo "    -d = Dynamic App SIGTERMs"
        echo "    -f = Filesystem Statistics SIGTERMs"
        echo "    -g = Collector Group (CUG) ID"
        echo "    -i = Interface Bandwidth SIGTERMs"
        echo "    -o = output results to filename provided"
        echo "    -p = the process ID for which you wish to collect SIGTERM info"
        echo "    -s = SNMP Detail SIGTERMs"
        echo "    -t = Specific date to pull in format YYYY-MM-DD"
        echo "    -h = Help message (what you're reading now)"
        echo "    -v = version information" ; echo
}

sql_cmd () {
        /opt/em7/bin/silo_mysql -NBe "$1" 2>/dev/null
}

while getopts "ac:dfg:hio:p:st:v" opt ; do
        case $opt in
                "a") PROCESS="Availability" ; PROC_NUM=10 ;;
                "c") MODULE=$OPTARG ;;
                "d") PROCESS="Dynamic App" ; PROC_NUM=11 ;;
                "f") PROCESS="Filesystem statistics" ; PROC_NUM=32 ;;
                "g") CUG_ID="$OPTARG" ;;
                "i") PROCESS="Interface Bandwidth" ; PROC_NUM=12 ;;
                "o") LOGFILE="$OPTARG" ; [[ $LOGFILE ]] && rm -f $LOGFILE ;;
                "p") PROC_NUM=$OPTARG ; PROCESS="$(echo $(sql_cmd "SELECT name FROM master.system_settings_procs WHERE aid=$PROC_NUM") | awk -F": " {'print $2'})" ;;
                "s") PROCESS="SNMP Detail" ; PROC_NUM=24 ;;
                "t") QUERY="AND DATE(date_edit) = \"$OPTARG\"" ;;
                "h") help_msg ; exit 0 ;;
                "v") echo ; echo "$0, version $VER" ; echo ; exit 0 ;;
                *) help_msg ; exit 1 ;;
        esac
done

log_it () {
        [[ $LOGFILE ]] && echo "$1" >> $LOGFILE
        echo "$1"
}

get_logs () {
        sql_cmd "SELECT date_edit,message FROM master_logs.system_messages WHERE module=$MODULE AND message LIKE \"%${PROCESS}%list at term%\" $QUERY ORDER BY date_edit DESC" > $OUTFILE 
}

start_report () {
        COL_NAME="$(sql_cmd "SELECT name FROM master.system_settings_licenses WHERE id=$MODULE")"
        echo ; log_it "Report for $PROCESS SIGTERMs on Collector $COL_NAME [$MODULE]" ; log_it ""
}

devices_only () {
        NUM_FOUND=$(cat $OUTFILE | wc -l)
        [[ $NUM_FOUND -eq 0 ]] && echo "No $PROCESS SIGTERMs found" && return
        start_report
        log_it "Found $NUM_FOUND $PROCESS SIGTERMs:"
        while IFS= read -r LINE ; do
                LINE_DATE="$(echo $LINE | awk -F" ${PROC_NUM}: D" {'print $1'})"
                DEV_FAILS=( $(echo $LINE | awk -F"[" {'print $2'} | awk -F"]" {'print $1'}) )
                [[ $LOGFILE ]] && echo "  * Number of devices not collected at ${LINE_DATE}: ${#DEV_FAILS[@]}" >> $LOGFILE
                if [ ${#DEV_FAILS[@]} -gt 0 ] ; then
                        echo "  * Number of devices not collected at ${LINE_DATE}: ${#DEV_FAILS[@]}"
                        log_it "    * Devices: "
                        for DEVID in $(echo ${DEV_FAILS[@]} | sed 's/,//g') ; do
                                HNAME="$(sql_cmd "SELECT device FROM master_dev.legend_device WHERE id=$DEVID")"
                                log_it "        $HNAME [$DEVID]"
                        done | column -x -c $(tput cols)
                        unset DEV_FAILS DEVID LINE_DATE
                else
                        log_it "  * Though the process SIGTERM'd at ${LINE_DATE}, no devices were listed."
                fi ; log_it ""
        done < $OUTFILE
}

collect_devapp_pairs () {
        while IFS= read -r LINE ; do
                ENTRY_DATE="$(echo $LINE | awk -F" ${PROC_NUM}: D" {'print $1'})"
                LINE_DATE="$(date -d "$ENTRY_DATE" +"%Y%m%d-%H%M%S")"
                DEVAPP_PAIRS="$(echo $LINE | awk -F"[" {'print $2'} | awk -F"]" {'print $1'})"
                echo "$DEVAPP_PAIRS" >> devapp-pairs_${LINE_DATE}.log
                sed -i 's/, 0)//g' devapp-pairs_${LINE_DATE}.log
                sed -i 's/((/(/g' devapp-pairs_${LINE_DATE}.log
                sed -i 's/), /)\n/g' devapp-pairs_${LINE_DATE}.log
                echo "$ENTRY_DATE" > entry_${LINE_DATE}.log
        done < $OUTFILE
}

create_app_catalog () {
        APPID_CAT=( $(cat APPS_*.log | sort | uniq) )
        for AID in ${APPID_CAT[@]} ; do
                APP_CAT[$AID]="$(sql_cmd "SELECT CONCAT(name,' [',aid,']|',poll) FROM master.dynamic_app WHERE aid=$AID")"
        done
}

create_dev_catalog () {
        DEVID_CAT=( $(cat DEVS_*.log | sort | uniq) )
        for DEVID in ${DEVID_CAT[@]} ; do
                DEV_CAT[$DEVID]="$(sql_cmd "SELECT CONCAT(device,' [',id,']') FROM master_dev.legend_device WHERE id=$DEVID")"
        done
}

dynamic_app_device_report () {
        MISSED_APPS+=( $(grep $DEV devapp-pairs_${LINE_DATE}.log | awk -F", " {'print $2'} | awk -F")" {'print $1'}) )
        echo "    * Device ${DEV_CAT[$DEV]} failed to collect on dynamic apps:"
        for MA in ${MISSED_APPS[@]} ; do
                APP_NAME="$(echo "${APP_CAT[$MA]}" | awk -F"|" {'print $1'})"
                APP_FREQ="$(sql_cmd "SELECT freq FROM master.dynamic_app_freq_overrides WHERE app_id=$MA AND did=$DEV")*"
                [[ "$APP_FREQ" == "*" ]] && APP_FREQ=$(echo "${APP_CAT[$MA]}" | awk -F"|" {'print $2'})
                MA_INFO+=( "$APP_NAME (CF $APP_FREQ)" )
        done
        for PRINT_ME in "${MA_INFO[@]}" ; do
                log_it "        $PRINT_ME"
        done | column -x -c $(tput cols)
        unset MISSED_APPS MA_INFO PRINT_ME
        log_it
}

dynamic_app_app_report () {
        MISSED_DEVS+=( $(grep ", $APP" devapp-pairs_${LINE_DATE}.log | awk -F"," {'print $1'} | awk -F"(" {'print $2'}) )
        echo "    * Dynamic app $(echo ${APP_CAT[$APP]} | awk -F"|" {'print $1'}) failed to collect for devices:"
        for PRINT_ME in ${MISSED_DEVS[@]} ; do
                log_it "        ${DEV_CAT[$PRINT_ME]}"
        done | column -x -c $(tput cols)
        unset MISSED_DEVS PRINT_ME
        log_it
}

process_devapp_pairs () {
        [[ $(ls -l devapp-pairs*.log 2>/dev/null | wc -l) -eq 0 ]] && echo "No $PROCESS SIGTERMs found" && return
        start_report
        for FILE in $(ls devapp-pairs*.log) ; do
                LINE_DATE=$(echo $FILE | awk -F"_" {'print $2'} | awk -F"." {'print $1'})
                while IFS= read -r LINE ; do
                        echo $LINE | awk -F", " {'print $1'} | awk -F"(" {'print $2'} >> DEVS_${LINE_DATE}.log
                        echo $LINE | awk -F", " {'print $2'} | awk -F")" {'print $1'} >> APPS_${LINE_DATE}.log
                done < $FILE
        done
        create_app_catalog
        create_dev_catalog
        for FILE in $(ls DEVS_*.log) ; do
                LINE_DATE=$(echo $FILE | awk -F"_" {'print $2'} | awk -F"." {'print $1'})
                ENTRY_DATE="$(cat entry_${LINE_DATE}.log)"
                TOTAL_DEVS=$(sed '/^\s*$/d' DEVS_${LINE_DATE}.log | wc -l)
                if [ $TOTAL_DEVS -gt 0 ] ; then
                        log_it "At $ENTRY_DATE, $TOTAL_DEVS device/app pairs:"
                        for DEV in $(cat DEVS_${LINE_DATE}.log | sort -n | uniq) ; do
                                NUM_DEVS=$(grep $DEV DEVS_${LINE_DATE}.log | wc -l)
                                log_it "  * Device ${DEV_CAT[$DEV]} appears $NUM_DEVS times"
                                dynamic_app_device_report
                        done
                        for APP in $(cat APPS_${LINE_DATE}.log | sort -n | uniq) ; do
                                NUM_APPS=$(grep $APP APPS_${LINE_DATE}.log | wc -l)
                                APP_NAME="$(echo ${APP_CAT[$APP]} | awk -F"|" {'print $1'})"
                                APP_FREQ="$(echo ${APP_CAT[$APP]} | awk -F"|" {'print $2'})"
                                log_it "  * Dynamic App ${APP_NAME} (frequency: $APP_FREQ min) appears $NUM_APPS times"
                                dynamic_app_app_report
                        done
                else
                        log_it "At $ENTRY_DATE, $PROCESS SIGTERM'd with no device/app pairs"
                fi
                log_it ""
                rm -f $FILE DEVS_${LINE_DATE}.log APPS_${LINE_DATE}.log devapp-pairs_${LINE_DATE}.log entry_${LINE_DATE}.log
        done
}

evaluate_cug () {
        ! [[ $CUG_ID =~ $re ]] && CUG_ID="$(sql_cmd "SELECT cug_id FROM master.system_collector_groups WHERE cug_name=\"$CUG_ID\"")"
        CUG_NAME="$(sql_cmd "SELECT cug_name FROM master.system_collector_groups WHERE cug_id=$CUG_ID")"
        [[ ! "$CUG_NAME" ]] && echo "Invalid Collector Group ID provided" && echo && exit 1
        [[ $(sql_cmd "SELECT COUNT(*) FROM master.system_collector_groups_to_collectors WHERE cug_id=$CUG_ID") -eq 0 ]] && echo "$CUG_NAME is a Virtual Collector Group; it has no collectors" && echo && exit 1
        CUG_QUERY="AND module IN (SELECT pid FROM master.system_collector_groups_to_collectors WHERE cug_id=$CUG_ID)"
}

if [ ! $MODULE ] ; then
        [[ $CUG_ID ]] && evaluate_cug
        MOD_OPTIONS=( "$(sql_cmd "SELECT DISTINCT module FROM master_logs.system_messages WHERE message LIKE \"%${PROC_NUM}:%list at term%\" $QUERY $CUG_QUERY")" )
        CHECKVAL="x${MOD_OPTIONS[0]}x"
        [[ "$CHECKVAL" == "xx" ]] && echo "No collectors in ${CUG_NAME} had $PROCESS SIGTERMs" && exit 0
        for ID in ${MOD_OPTIONS[@]} ; do
                COLLECTORS+=( "$(sql_cmd "SELECT CONCAT(name,' [',id,']') FROM master.system_settings_licenses WHERE id=$ID")" )
        done ; echo  
        [[ $CUG_NAME ]] && echo "Please select a collector ID from ${CUG_NAME}. Collectors from this CUG with SIGTERMs are: " || echo "Collector ID (-c) required. Options are: "
        echo ; echo "${COLLECTORS[@]/%/$'\n'}" | sed 's/^ //' | column -c $(tput cols) -x
        echo ; while [ ! $MODULE ] ; do
                printf "Which collector ID do you wish to analyze? "
                read MODULE
                for is_match in ${MOD_OPTIONS[@]} ; do
                        [[ $is_match -eq $MODULE ]] && move_on=1
                done
                [[ ! $move_on ]] && unset MODULE 
        done
        unset move_on
else
        ! [[ $MODULE =~ $re ]] && MODULE=$(sql_cmd "SELECT id FROM master.system_settings_licenses WHERE name=\"$MODULE\"")
        [[ ! $MODULE ]] && echo "Collector not found" && exit 1
fi

if [ ! $PROC_NUM ] ; then
        echo ; echo "No process given. Options are: " ; echo
        PROC_OPTIONS=( "$(echo "$(sql_cmd "SELECT message FROM master_logs.system_messages WHERE module=$MODULE $QUERY AND message LIKE '%list at term%'")" | awk -F":" {'print $1'} | sort | uniq)" )
        for PROC in ${PROC_OPTIONS[@]} ; do
                echo "  $(echo "$(sql_cmd "SELECT name FROM master.system_settings_procs WHERE aid=$PROC")" | awk -F": " {'print $2'}) [Process ID $PROC]"
        done
        echo ; while [ ! $PROC_NUM ] ; do
                printf "Which process ID would you like to analyze? "
                read PROC_NUM
                for is_match in ${PROC_OPTIONS[@]} ; do
                        [[ $is_match -eq $PROC_NUM ]] && move_on=1
                done
                [[ ! $move_on ]] && unset PROC_NUM
        done
        PROCESS="$(sql_cmd "SELECT name FROM master.system_settings_procs WHERE aid=$PROC_NUM" | awk -F": " {'print $2'})"
else
        [[ "$(sql_cmd "SELECT COUNT(*) FROM master.system_settings_procs WHERE aid=$PROC_NUM")" != "1" ]] && echo "Invalid Process ID" && exit 1
fi

OUTFILE="${PROCESS// /_}"
OUTFILE="${MODULE}_${OUTFILE}.log"

if [ $PROC_NUM -eq 11 ] ; then
        QUERY="$QUERY AND message NOT LIKE \"%'%\""
        get_logs
        collect_devapp_pairs
        process_devapp_pairs
else
        get_logs
        devices_only
fi
echo ; rm -f $OUTFILE