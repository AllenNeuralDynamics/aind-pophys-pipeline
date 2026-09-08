#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' x-access-token ;;
    *Password*) cat /run/secrets/github_token ;;
    *) exit 1 ;;
esac
