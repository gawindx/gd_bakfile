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
#	DATA=$DATA$data
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
#	./google-oauth2.sh create - authenticates a user
#	./google-oauth2.sh refresh <token> - gets a new token
#

if [ "$1" == "create" ]; then
        local RESPONSE=`curl --silent "https://accounts.google.com/o/oauth2/device/code" \
                --data "client_id=$CLIENT_ID&scope=$SCOPE"`
        local DEVICE_CODE=`echo "$RESPONSE" | prettyjson | grep 'device_code' | \
                cut -d ':' -f 2 | sed 's/"//g' | sed 's/,//g' | sed 's/\ //g'`
        local USER_CODE=`echo "$RESPONSE" | prettyjson | grep 'user_code' | \
                cut -d ':' -f 2 | sed 's/"//g' | sed 's/,//g' | sed 's/\ //g'`
        local URL=`echo "$RESPONSE" | prettyjson | grep 'verification_url' | \
                cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
        URL="$URL:"`echo "$RESPONSE" | prettyjson | grep 'verification_url' | \
                        cut -d ':' -f 3 | sed 's/"//g' | sed 's/\ //g'`
        local TOKEN_TTL=`echo "$RESPONSE" | prettyjson | grep 'expires_in' | \
                cut -d ':' -f 2  | sed 's/,//g'| sed 's/\ //g'`
        echo -n "Go to $URL and enter $USER_CODE to grant access to this application. Hit enter when done..."
        read -t $TOKEN_TTL ENTER_KEY
        ENTER_KEY=${ENTER_KEY:-timeout}
#        if [ "$ENTER_KEY" == "timeout" ]; then exit 1
        RESPONSE=`curl --silent "https://accounts.google.com/o/oauth2/token" \
                --data "client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code=$DEVICE_CODE&grant_type=http://oauth.net/grant_type/device/1.0"`
        ACCESS_TOKEN=`echo "$RESPONSE" | prettyjson | grep 'access_token' | \
                cut -d ',' -f 1 | cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
        REFRESH_TOKEN=`echo "$RESPONSE" | prettyjson | grep 'refresh_token' | \
                cut -d ',' -f 1 | cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
elif [ "$1" == "refresh" ]; then
        REFRESH_TOKEN="$2"
        local RESPONSE=`curl --silent "https://accounts.google.com/o/oauth2/token" \
                --data "client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&refresh_token=$REFRESH_TOKEN&grant_type=refresh_token"`
        ACCESS_TOKEN=`echo "$RESPONSE" | prettyjson | grep 'access_token' | \
                cut -d ',' -f 1 | cut -d ':' -f 2 | sed 's/"//g' | sed 's/\ //g'`
fi
}

function upload {
local BOUNDARY=`cat /dev/urandom | head -c 16 | xxd -ps`
local MIME_TYPE=${5:-"application/octet-stream"}
local FULL_PATH="$2"
local FILENAME=$(basename "$FULL_PATH")
local FILESIZE=$(stat -c%s "$FULL_PATH")

if [ "$FILESIZE" -lt "1048576" ]; then
        ( echo "--$BOUNDARY
Content-Type: application/json; charset=UTF-8

{ \"title\": \"$FILENAME\", \"parents\": [ { \"id\": \"$UPLOAD_DIR_ID\" } ] }

--$BOUNDARY
Content-Type: $MIME_TYPE
" \
&& cat $2 && echo "
--$BOUNDARY--" ) \
        | curl --silent "https://www.googleapis.com/upload/drive/v2/files/?uploadType=multipart" \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Content-Type: multipart/related; boundary=\"$BOUNDARY\"" \
        --data-binary "@-" >/dev/null 2>&1
    else
    	local DATA_JSON="{ \"title\": \"$FILENAME\"}"
        echo "Data : $DATA_JSON"
        local DATA_SIZE=${#DATA_JSON}
        echo "Data Size : $DATA_SIZE"
        local RESPONSE=`curl -s -D- -X "POST" "https://www.googleapis.com/upload/drive/v2/files?uploadType=resumable" \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Content-Type: application/json; charset=UTF-8" \
        --header "Content-Length: $DATA_SIZE" \
        --header "X-Upload-Content-Type: $MIME_TYPE" \
        --header "X-Upload-Content-Length: $FILESIZE" \
        --data "$DATA_JSON"`
        echo "First step ended"
        local SESSION_URI=`echo "$RESPONSE" | grep 'Location:' | cut -d ' ' -f 2 | sed 's/\ //g'`
        local NB_CHUNCK=`expr $(echo $((FILESIZE/1048576)) | cut -d '.' -f 1) + 1`
        echo "FILESIZE : $FILESIZE :: nB_CHUNK : $NB_CHUNCK"
        for (( CHUNCK = 0; CHUNCK < $NB_CHUNCK; CHUNCK += 1 )); do
                echo $CHUNCK
                local START_BYTES=$((CHUNCK*1048576))
                local END_BYTES=`expr $(($((CHUNCK+1))*1048576)) - 1`
                echo $START_BYTES
                echo $END_BYTES
                if [ "$END_BYTES" -gt "$FILESIZE" ]; then
                        END_BYTES="$FILESIZE"
                fi
                local LENGTH=`expr $((END_BYTES+1)) - $START_BYTES`
                echo $LENGTH
                DATA=`dd if=$FULL_PATH skip=$((CHUNCK*1))M bs=1M count=1 status=noxfer 2> /dev/null`
                local RESPONSE=`curl -s -D- -X "PUT" "$SESSION_URI" \
                        --header "Authorization: Bearer $ACCESS_TOKEN" \
                        --header "Content-Type: application/json; charset=UTF-8" \
                        --header "Content-Length: $LENGTH" \
                        --header "Content-Type: $MIME_TYPE" \
                        --header "Content-Range: bytes $START_BYTES-$END_BYTES/$FILESIZE" \
                        --data "$DATA"`
        done
fi
}

function gd_verify_destdir {
local DESTDIR="$1"
local QUERY="title%3D%27"$DESTDIR"%27%20and%20mimeType%3D%27application%2Fvnd.google-apps.folder%27"
local RESPONSE=`curl --silent "https://www.googleapis.com/drive/v2/files/root/children?q=$QUERY" \
        --header "Authorization: Bearer $ACCESS_TOKEN"`
local DESTDIR_ID=`echo $RESPONSE | prettyjson | grep '"id":' | cut -d ':' -f 2  | sed 's/,//g'| sed 's/\ //g' | sed 's/"//g'`
if [ -z "$DESTDIR_ID" ]; then
        DESTDIR_ID=$(gd_create_destdir $DESTDIR)
fi
echo $DESTDIR_ID
}

function gd_create_destdir {
local DESTDIR="$1"
local BOUNDARY=`cat /dev/urandom | head -c 16 | xxd -ps`
DATA_JSON="{ \"title\": \"$DESTDIR\",  \"parents\": [{\"id\":\"root\"}],  \"mimeType\": \"application/vnd.google-apps.folder\"}"
local DATA_SIZE=${#DATA_JSON}
local RESPONSE=`curl --silent -X "POST" "https://www.googleapis.com/drive/v2/files" \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Content-Type: application/json" \
        --header "Content-Length: $DATA_SIZE" \
        --data "$DATA_JSON"`
local DESTDIR_ID=`echo $RESPONSE | prettyjson | grep -m 1 '"id":'| cut -d ':' -f 2 \
 | sed 's/,//g'| sed 's/\ //g' | sed 's/"//g' | cut -d ' ' -f 1`
echo $DESTDIR_ID
}

function create_opt {
auth2 create
	cat >/usr/local/bin/.gd_bakfile.opt <<EOL
ACCESS_TOKEN=${ACCESS_TOKEN}
REFRESH_TOKEN=${REFRESH_TOKEN}
EOL
}

function gd_delete_file {
local DEL_ID="$1"
local RESPONSE=`curl --silent -X "DELETE" "https://www.googleapis.com/drive/v2/files/$DEL_ID" \
        --header "Authorization: Bearer $ACCESS_TOKEN"`
}

function gd_get_file_info {
local GD_FILE_ID=$1
local RESPONSE=`curl --silent "https://www.googleapis.com/drive/v2/files/$GD_FILE_ID" \
        --header "Authorization: Bearer $ACCESS_TOKEN"`
local GD_FILE_NAME=`echo "$RESPONSE" | prettyjson | grep "title" | cut -d '"' -f 4`
local GD_FILE_SIZE=`echo "$RESPONSE" | prettyjson | grep "fileSize" | cut -d '"' -f 4`
local ARRAY_GD_INFO_FILE=("$GD_FILE_ID" "$GD_FILE_NAME" "$GD_FILE_SIZE")
echo ${ARRAY_GD_INFO_FILE[*]}
}

function gd_get_existing_file_list {
GD_ARRAY_FILE=()
local RESPONSE=`curl --silent "https://www.googleapis.com/drive/v2/files/$UPLOAD_DIR_ID/children?q=trashed%3Dfalse" \
        --header "Authorization: Bearer $ACCESS_TOKEN"`
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
for BAK_FILE in `ls ${BAKDIR}*.zip`; do
        local BAK_FILESIZE=$(stat -c%s "$BAK_FILE")
        local BAK_FILENAME=$(basename "$BAK_FILE")
        MY_ARRAY='bak_id'$count_index'=('$BAK_FILE' '$BAK_FILENAME' '$BAK_FILESIZE')'
        BAK_ARRAY_FILE=("${BAK_ARRAY_FILE[@]}" "$MY_ARRAY")
        count_index=`expr $count_index + 1`
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
fi
if [ -r /usr/local/bin/.gd_bakfile.opt ]; then
        . /usr/local/bin/.gd_bakfile.opt
        auth2 refresh $REFRESH_TOKEN
        refresh_opt
else
    	create_opt
        . /usr/local/bin/.gd_bakfile.opt
fi
if [ ! -z "$UPLOAD_DIR" ] && [ -z "$UPLOAD_DIR_ID" ]; then
        UPLOAD_DIR_ID=$(gd_verify_destdir $UPLOAD_DIR)
        cat >/etc/default/gd_bakfile.conf <<EOL
BAKDIR="${BAKDIR}"
UPLOAD_DIR="${UPLOAD_DIR}"
UPLOAD_DIR_ID="${UPLOAD_DIR_ID}"
CLIENT_ID="${CLIENT_ID}"
CLIENT_SECRET="${CLIENT_SECRET}"
SCOPE=${SCOPE:-"https://docs.google.com/feeds"}
EOL
fi

gd_get_existing_file_list
bak_get_existing_file_list
count_index=0
for gd_file in "${GD_ARRAY_FILE[@]}"; do
        eval "$gd_file"
        eval "FILE=`echo '$BAKDIR${gd_id'$count_index'[1]}'`"
        if [ ! -r "$FILE" ]; then
                eval "FILE_ID=`echo '${gd_id'$count_index'[0]}'`"
                gd_delete_file "$FILE_ID"
        fi
	count_index=`expr $count_index + 1`
done
BAK_TO_GD=()
for file in `ls ${BAKDIR}*.zip`; do
        DO_BAK="1"
        BAK_FILESIZE=$(stat -c%s "$file")
        for count_index in $(seq 0 `expr ${#GD_ARRAY_FILE[@]} - 1`);do
                eval "GD_FILEID=`echo '${gd_id'$count_index'[0]}'`"
                eval "GD_FILENAME=`echo $BAKDIR'${gd_id'$count_index'[1]}'`"
                eval "GD_FILESIZE=`echo '${gd_id'$count_index'[2]}'`"
                if [ "$file" == "$GD_FILENAME" ]; then
                        if [ "$BAK_FILESIZE" -ne "$GD_FILESIZE" ]; then
                                gd_delete_file "$GD_FILEID"
                                                        else
                            	DO_BAK="0"
                        fi
                fi
        done
	if [ "$DO_BAK" -eq "1" ]; then
                BAK_TO_GD=("${BAK_TO_GD[@]}" "$file")
        fi
done
for BAK_FILENAME in "${BAK_TO_GD[@]}"; do
#        echo "Upload $BAK_FILENAME"
#        if [ $(stat -c%s "$BAK_FILENAME") -lt "1048576" ]; then
                upload "$ACCESS_TOKEN" "$BAK_FILENAME"
#        else
#                echo "too big"
#        fi
done
