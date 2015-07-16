Waht is "gd_bakfile"

gd_bakfile is a script that can upload all file in a local directory to a remote directory on Google Drive.
All that you need is a Google Drive Account and you also  need to create a Google App with Google Drive's Api enabled.

How to Use "gd_bakfile"

First, connect Google's account and go to https://console.developers.google.com/project.
Click on "Create Project", give a name to our project on the new window,  and click "Create".
Refresh the page and click on your project.
Go to "API and authentication"->"API", choose "Drive API" on the right panel then enable it and go back.
Always in "API and authentication", choose "Identifiers" (under "API") and "Create Customer Login".
Select "Installed App", configure "Screen Authorization" and accept.
Now, you have your "Client Id" and "Client Secret", keep the page open.

Secondly, copy gd_bakfile's script to "/usr/local/bin/gd_bakfile.sh" :
nano /usr/local/bin/gd_bakfile.sh
paste the script and save (Ctrl+x)
Give it executable right :
chmod +x /usr/local/bin/gd_bakfile.sh
and run it (with root right) :
/usr/local/bin/gd_bakfile.sh

At first run, you should answer at 5 questions :
- Your Client ID
- Your Secret's ID
- The Google Scope's (you can leave it blank)
- The local directory that contains all files to backup
- The directory on Google Drive where you'll store files (if it not exist it will be created at first backup)

Si tout est ok , il va stocker toutes les infos pour une utilisation ultérieure et obtenir tous Token d'autoriser toutes les demandes avenir.

How It Work

It will get "Acces Token" and "Refresh Token" and he'll automatically get new "Acces Token" when expired.
With "Acces Token", he'll verify that remote directory exist, if not he'll create him, and get his ID's.
He'll search into remote directory for all file in it.
Tehn, he'll look into local directory for file to backup.
All files that are presents on remote directory but not on local directory will be destroyed.
All file that are present both on remote directory and local will  not be saved (only if are not of the same size, in this case the remote file 
is erased and local file is uploaded again).
All files that are only present on local directory are uploaded to remote directory.
By default, all file larger than 1Mb are uploaded in "resumable" mode with parts of 1Mb.

In case Of trouble
You can delete the config file (/etc/default/gd_bakfile.conf), it contains all answers from the 5 questions.
You can also delete the file /usr/local/bin/.gd_bakfile.opt who contains "Acces Token", "Refresh Token" and expiration timestamp of "Acces Token".

