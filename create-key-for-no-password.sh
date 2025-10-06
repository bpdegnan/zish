#!/bin/bash
#Before anything else, set the PATH_SCRIPT variable
 pushd `dirname $0` > /dev/null; PATH_SCRIPT=`pwd -P`; popd > /dev/null
 PROGNAME=${0##*/}; PROGVERSION=0.1.0 

printf '\nWarning!\nThis script creates the ssh key pair so that one does not need\n
to type a password to login more than once.  If you know that you\n
need to do this, you probably can check this scripts source\n
to see what is being done.\n\n'

read -r -p "Are you sure you want to continue? [y/N] " response
case "$response" in
    [yY][eE][sS]|[yY]) 
        ;;
    *)
        exit 1
        ;;
esac
printf "This script will put public key on the remove server\n
and now it will ask for your USERNAME and the REMOTESERVER\n"
printf "USERNAME [ENTER]:"
read USERNAME
printf "REMOTESERVER [ENTER]:"
read REMOTESERVER

echo "Will send pair to $USERNAME@$REMOTESERVER"

if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
   echo "$HOME/.ssh/id_rsa.pub exists, skipping rsa key generation"
else
   #create the key pair
   echo "ssh-keygen -t rsa"
   ssh-keygen -t rsa
fi

#create the remote directory if it doesn't exist and change the mode
echo "ssh $USERNAME@$REMOTESERVER 'mkdir -p .ssh && chmod 700 .ssh'"
ssh $USERNAME@$REMOTESERVER 'mkdir -p .ssh && chmod 700 .ssh'

echo "cat .ssh/id_rsa.pub | ssh $USERNAME@$REMOTESERVER 'cat >> .ssh/authorized_keys'"
cat $HOME/.ssh/id_rsa.pub | ssh $USERNAME@$REMOTESERVER 'cat >> .ssh/authorized_keys'

