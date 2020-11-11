#!/bin/bash

command -v recode >/dev/null 2>&1 || { echo >&2 "Package dependency \"recode\" isn\'t installed. You can install it using \"sudo apt-get install recode\"."; exit 1; }

git add . --all > /dev/null;

username=$(git config user.name);
email=$(git config user.email);

read -p "Enter the username to be spoofed:" spoofas;
read -p "Enter the email of $spoofas:" spoofasemail;

content=$(wget "https://github.com/$spoofas" -q -O -);

if [[ $content == *"$before"* ]];
then
    spoofasemail=$(echo $content | recode html/.. | grep -EiEio '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}\b' | head -1);
    echo "Enter the email of $spoofas:$spoofasemail";
fi;

read -p "Enter a commit message:" message;

git config --global user.name "$spoofas";
git config --global user.email "$spoofasemail";

git commit -m "$message";

git config --global user.name "$username";
git config --global user.email "$email";

