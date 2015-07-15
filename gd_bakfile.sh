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

function chunck_file {
PYTHON_ARG="$*" /usr/bin/python - <<END
import sys, getopt
import os

class Unbuffered(object):
	def __init__(self, stream):
		self.stream = stream
	def write(self, data):
		self.stream.write(data)
		self.stream.flush()
	def __getattr__(self, attr):
		return getattr(self.stream, attr)

argv=os.environ['PYTHON_ARG'].split(' ')
inputfile = ''
chunck_size = 0
skip_size = 0
try:
	opts, args = getopt.getopt(argv,"hi:c:s:",["help","ifile=","chunck_size=","skip_size="])
except getopt.GetoptError:
	print 'chunck_file -i <inputfile> -c <chunck_size> -s <skip_size>'
	sys.exit(2)
for opt, arg in opts:
	if opt  in ("-h", "--help"):
		print 'chunck_file -i <inputfile> -c <chunck_size> -s <skip_size>'
		sys.exit()
	elif opt in ("-i", "--ifile"):
		inputfile = arg
	elif opt in ("-c", "--chunck_size"):
		chunck_size = int(arg)
	elif opt in ("-s", "--skip_size"):
	skip_size = int(arg)
sys.stdout = Unbuffered(sys.stdout)
f = open(inputfile,'rb',0)
f.seek(skip_size,0)
data = f.read(chunck_size)
sys.stdout.write(data)
f.close
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
#	if [ "$ENTER_KEY" == "timeout" ]; then exit 1
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
	local CHUNCK_SIZE="1048576"
	local DATA_JSON="{ \"title\": \"$FILENAME\", \"parents\": [ { \"id\": \"$UPLOAD_DIR_ID\" } ] }"
	local DATA_SIZE=${#DATA_JSON}
	local RESPONSE=`curl -s -D- -X "POST" "https://www.googleapis.com/upload/drive/v2/files?uploadType=resumable" \
		--header "Authorization: Bearer $ACCESS_TOKEN" \
		--header "Content-Type: application/json; charset=UTF-8" \
		--header "Content-Length: $DATA_SIZE" \
		--header "X-Upload-Content-Type: $MIME_TYPE" \
		--header "X-Upload-Content-Length: $FILESIZE" \
		--data "$DATA_JSON"`
	local SESSION_URI=`echo "$RESPONSE" | grep 'Location:' | cut -d ' ' -f 2 | sed 's/\ //g'`
	local START_BYTES=0
	local END_BYTES=0
	local LENGTH=0
	local HTTP_ERCODE_SERVER='500|502|503|504'
	while [ "$START_BYTES" -lt "$FILESIZE" ]; do
		END_BYTES=`expr $((START_BYTES + CHUNCK_SIZE)) - 1`
		if [ "$END_BYTES" -gt "$FILESIZE" ]; then
			END_BYTES=$((FILESIZE-1))
		fi
		chunck_file -i "$FULL_PATH" -c 128 -s 2
		LENGTH=`expr $((END_BYTES+1)) - $START_BYTES`
		local RESPONSE=""
		local RETRY=0
		local RESPONSE=`chunck_file -i "$FULL_PATH" -c $CHUNCK_SIZE -s $START_BYTES | \
			curl -i --silent --write-out %{http_code} -X "PUT" "$SESSION_URI" \
			--header "Authorization: Bearer $ACCESS_TOKEN" \
			--header "Content-Type: application/json; charset=UTF-8" \
			--header "Content-Length: $LENGTH" \
			--header "Content-Type: $MIME_TYPE" \
			--header "Content-Range: bytes $START_BYTES-$END_BYTES/$FILESIZE" \
			--data-binary "@-" | grep 'HTTP/1.1'`
		if [ ! -z "`echo "$RESPONSE" | grep '308'`" ]; then
			local UPLOADED_BYTES=`curl -s -D- -X "PUT" "$SESSION_URI" \
				--header "Authorization: Bearer $ACCESS_TOKEN" \
				--header "Content-Length: 0" \
				--header "Content-Range: bytes */$FILESIZE" 2>&1 | grep 'Range: bytes=' | cut -d '-' -f 2 \
				| sed 's/\ //g'	| sed 's/\n//g'| sed 's/\r//g'`
			START_BYTES=`expr $UPLOADED_BYTES + 1`
		elif [ ! -z "`echo "$RESPONSE" | grep '201'`" ]; then
			break
		elif [ ! -z "`echo "$RESPONSE" | grep '200'`" ]; then
			break
		elif [ ! -z "`echo "$RESPONSE" | grep '404'`" ]; then
			break
		else
		   	RESPONSE=""
			local RETRY=0
			while [ ! -z "`echo "$RESPONSE" | grep '308\|200\|201'`" ]||[ "$RETRY" -le "10" ]; do
				local UPLOADED_BYTES=`curl -s -D- -X "PUT" "$SESSION_URI" \
					--header "Authorization: Bearer $ACCESS_TOKEN" \
					--header "Content-Length: 0" \
					--header "Content-Range: bytes */$FILESIZE" 2>&1 | grep 'Range: bytes=' | cut -d '-' -f 2 \
					| sed 's/\ //g' | sed 's/\n//g'| sed 's/\r//g'`
				if [ ! -z "`echo "$RESPONSE" | grep "\'$HTTP_ERCODE_SERVER\'"`" ]; then
					RETRY=`expr $RETRY + 1`
					local SLEEP_TIME=`expr $((2**RETRY)) + $(( $(( ( RANDOM % 1000 )  + 1 )) / 1000 ))`
					sleep $SLEEP_TIME
				fi
			done
			if [ "$RETRY" -le "10" ]; then
				START_BYTES=$((`echo "$RESPONSE" | grep 'Range:' | cut -d '-' -f 2` + 1))
			else
		    	break
			fi
		fi
	done
fi
}

function gd_verify_destdir {
local DESTDIR="$1"
local QUERY="title%3D%27"$DESTDIR"%27%20and%20mimeType%3D%27application%2Fvnd.google-apps.folder%27"
local RESPONSE=`curl --silent "https://www.googleapis.com/drive/v2/files/root/children?q=$QUERY" \
	--header "Authorization: Bearer $ACCESS_TOKEN"`
local DESTDIR_ID=`echo $RESPONSE | prettyjson | grep '"id":' | cut -d ':' -f 2  | sed 's/,//g'\
	| sed 's/\ //g' | sed 's/"//g'`
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
	upload "$ACCESS_TOKEN" "$BAK_FILENAME"
done
