#!/bin/bash

# Upload a file to Google Drive
#
# Usage: upload.sh <access_token> <file> [title] [path] [mime]
# https://developers.google.com/drive/web/about-auth


set -e

function prettyjson_test {
#Convert JSON data to human-readable form.
#(Reads from stdin and writes to stdout)
#local DATA=""
#while read data; do
#       DATA=$DATA$data
#done
PYTHON_ARG="$1" python - <<END
import os
import simplejson as json
json_data=os.environ['PYTHON_ARG']
print json.dumps(json.loads(json_data), indent=4)
END
}

function auth2 {
# A simple cURL OAuth2 authenticator
# depends on Python's built-in json module to prettify output
#
# Usage:
#       ./google-oauth2.sh create - authenticates a user
#       ./google-oauth2.sh refresh <token> - gets a new token
#
# Set CLIENT_ID and CLIENT_SECRET and SCOPE

CLIENT_ID=""
CLIENT_SECRET=""
SCOPE=${SCOPE:-"https://docs.google.com/feeds"}

if [ "$1" == "create" ]; then
	
	local RESPONSE=`curl --silent "https://accounts.google.com/o/oauth2/device/code" --data "client_id=$CLIENT_ID&scope=$SCOPE"`
	local DEVICE_CODE=`echo $RESPONSE | prettyjson | grep 'device_code' | cut -d ':' -f 2 | sed 's/"//g' | sed 's/,//g' | sed 's/\ //g'`
	local USER_CODE=`echo "$RESPONSE" | prettyjson | grep 'user_code' | cut -d ':' -f 2 | sed 's/"//g' | sed 's/,//g' | sed 's/\ //g'`
	local URL=`echo "$RESPONSE" | prettyjson | grep 'verification_url' | cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
	URL=$URL':'`echo "$RESPONSE" | prettyjson | grep 'verification_url' | cut -d ':' -f 3 | sed 's/"//g' | sed 's/\ //g'`
	local TOKEN_TTL=`echo "$RESPONSE" | prettyjson | grep 'expires_in' | cut -d ':' -f 3 | sed 's/"//g' | sed 's/\ //g'`
	echo -n "Go to $URL and enter $USER_CODE to grant access to this application. Hit enter when done..."
	read -t $TOKEN_TTL ENTER_KEY
	ENTER_KEY=${ENTER_KEY:-timeout}
	if [ $ENTER_KEY == "timeout" ]; then exit 1
	RESPONSE=`curl --silent "https://accounts.google.com/o/oauth2/token" --data "client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code=$DEVICE_CODE&grant_type=http://oauth.net/grant_type/device/1.0"`
	ACCESS_TOKEN=`echo "$RESPONSE" | prettyjson | grep 'access_token' | cut -d ',' -f 1 | cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
	REFRESH_TOKEN=`echo "$RESPONSE" | prettyjson | grep 'refresh_token' | cut -d ',' -f 1 | cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
elif [ "$1" == "refresh" ]; then
        REFRESH_TOKEN="$2"
        local RESPONSE=`curl --silent "https://accounts.google.com/o/oauth2/token" --data "client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&refresh_token=$REFRESH_TOKEN&grant_type=refresh_token"`
        ACCESS_TOKEN=`echo $RESPONSE | prettyjson | grep 'access_token' | cut -d ',' -f 1 | cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
fi
}

function upload {
BOUNDARY=`cat /dev/urandom | head -c 16 | xxd -ps`
MIME_TYPE=${5:-"application/octet-stream"}

FILENAME=$(basename "$2")

( echo "--$BOUNDARY
Content-Type: application/json; charset=UTF-8

{ \"title\": \"$FILENAME\", \"parents\": [ { \"id\": \"$UPLOAD_DIR_ID\" } ] }

--$BOUNDARY
Content-Type: $MIME_TYPE
" \
&& cat $2 && echo "
--$BOUNDARY--" ) \
        | curl -v "https://www.googleapis.com/upload/drive/v2/files/?uploadType=multipart" \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Content-Type: multipart/related; boundary=\"$BOUNDARY\"" \
        --data-binary "@-"
}

function create_opt {
auth2 create
        cat >/usr/local/bin/.wpbak2gdrive.opt <<EOL
ACCESS_TOKEN=${ACCESS_TOKEN}
REFRESH_TOKEN=${REFRESH_TOKEN}
EOL
}

function gd_delete_file {
local DEL_ID="$1"
echo "delete file ID : "$DEL_ID
local RESPONSE=`curl --silent -X "DELETE" "https://www.googleapis.com/drive/v2/files/$DEL_ID" --header "Authorization: Bearer $ACCESS_TOKEN"`
}

function gd_get_file_info {
local GD_FILE_ID="$1"
local RESPONSE=`curl --silent "https://www.googleapis.com/drive/v2/files/$GD_FILE" --header "Authorization: Bearer $ACCESS_TOKEN"`
local GD_FILE_NAME=`echo "$RESPONSE" | prettyjson | grep "title" | cut -d '"' -f 4`
local GD_FILE_SIZE=`echo "$RESPONSE" | prettyjson | grep "fileSize" | cut -d '"' -f 4`
local ARRAY_GD_INFO_FILE=("$GD_FILE_ID" "$GD_FILE_NAME" "$GD_FILE_SIZE")
echo ${ARRAY_GD_INFO_FILE[*]}
}

function gd_get_existing_file_list {
GD_ARRAY_FILE=()
local RESPONSE=`curl --silent "https://www.googleapis.com/drive/v2/files/$UPLOAD_DIR_ID/children?q=trashed%3Dfalse" --header "Authorization: Bearer $ACCESS_TOKEN"`
local GD_FILE_LIST=`echo "$RESPONSE" | prettyjson | grep "id" | cut -d '"' -f 4`
local count_index=0
local MY_ARRAY
for file_id in $GD_FILE_LIST; do
        MY_ARRAY='gd_id'$count_index'=('$(gd_get_file_info $file_id)')'
        GD_ARRAY_FILE=("${GD_ARRAY_FILE[@]}" "$MY_ARRAY")
        count_index=`expr $count_index + 1`
done
}

function bak_get_existing_file_list {
BAK_ARRAY_FILE=()
local count_index=0
local MY_ARRAY
for BAK_FILE in "${BAKDIR}*.zip"; do
	local BAK_FILESIZE=$(stat -c%s "$BAK_FILE")
	local BAK_FILENAME=$(basename "$BAK_FILE")
	MY_ARRAY='bak_id'$count_index'=('$BAK_FILE' '$BAK_FILENAME' '$BAK_FILESIZE')'
	BAK_ARRAY_FILE=("${BAK_ARRAY_FILE[@]}" "$MY_ARRAY")
	count_index=`expr $count_index + 1`
done
}

function comp_gd_bak_file {
local count_index=0
for i in "${GD_ARRAY_FILE[@]}"; do
        eval $i
        eval "local FILE=`echo '$BAKDIR${id'$count_index'[1]}'`"
        if [ ! -e "$FILE" ]; then
                eval "local FILE_ID=`echo '${id'$count_index'[0]}'`"
                gd_delete_file $FILE_ID
        fi
        count_index=`expr $count_index + 1`
done
}

function comp_bak_gd_file {
for elt in "${GD_ARRAY_FILE[@]}"; do
       eval $elt
done
BAK_TO_GD=()
for file in "${BAKDIR}*.zip"; do
        count_index=0
        for i in $(seq 1 ${#GD_ARRAY_FILE[@]});do
                eval "local GD_FILEID=`echo '${id'$count_index'[0]}'`"
                eval "local GD_FILENAME=`echo '{id'$count_index'[1]}'`"
                eval "local GD_FILESIZE=`echo '${id'$count_index'[2]}'`"
                local BAK_FILENAME=$BAKDIR$GD_FILENAME
                if [ ! -e "$BAK_FILENAME" ]; then
                        BAK_TO_GD=("${BAK_TO_GD[@]}" "$BAK_FILENAME")
                else
                        local BAK_FILESIZE=$(stat -c%s "$BAK_FILENAME")
                        if [ "$BAK_FILESIZE" -ne "$GD_FILESIZE" ]; then
                                gd_delete_file $GD_FILEID
                                BAK_TO_GD=("${BAK_TO_GD[@]}" "$BAK_FILENAME")
                        fi
                fi
        done
done
}

function refresh_opt {
        cat >/usr/local/bin/.wpbak2gdrive.opt <<EOL
ACCESS_TOKEN=${ACCESS_TOKEN}
REFRESH_TOKEN=${REFRESH_TOKEN}
EOL
}
if [ -r /etc/default/gd_bakfile.conf ]; then
	. /etc/default/gd_bakfile.conf
	SCOPE=${SCOPE:-"https://docs.google.com/feeds"}
else
	read -p "Enter Client ID :" CLIENT_ID
	read -p "Enter Client Secret :" CLIENT_SECRET
	read -p "Enter Google scope (or leave blank for default) :" SCOPE
	read -p "Enter Directory to backup:" BAKDIR
	read -p "Enter Google Directory destination (if not exist it will be created):" UPLOAD_DIR
        cat >/usr/local/bin/.wpbak2gdrive.opt <<EOL
BAKDIR="${BAKDIR}"
UPLOAD_DIR_ID="$(gd_get_folder_id)"
CLIENT_ID="${CLIENT_ID}"
CLIENT_SECRET="${CLIENT_SECRET}"
SCOPE=${SCOPE:-"https://docs.google.com/feeds"}
EOL
fi

if [ -r /usr/local/bin/.wpbak2gdrive.opt ]; then
	. /usr/local/bin/.wpbak2gdrive.opt
	auth2 refresh $REFRESH_TOKEN
	refresh_opt
else
	create_opt
	. /usr/local/bin/.wpbak2gdrive.opt
fi
gd_get_existing_file_list
bak_get_existing_file_list

comp_gd_bak_file
gd_get_existing_file
comp_bak_gd_file
for BAK_FILENAME in "${BAK_TO_GD[@]}"; do
        upload "$BAK_FILENAME"
        upload $ACCESS_TOKEN "$BAK_FILENAME"
done
