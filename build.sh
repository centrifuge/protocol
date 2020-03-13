#!/usr/bin/env bash

set -e

rm -f Options.tex

if [ -d ".git" ]; then

SHA=`git rev-parse --short --verify HEAD`
DATE=`git show -s --format="%cd" --date=short HEAD`
REV="$SHA - $DATE"
echo "\def\ProtocolPaperVersionNumber{$REV}" >> Options.tex

fi

docker run --rm -i --user="$(id -u):$(id -g)" --net=none -v "$PWD":/data "blang/latex:ctanfull" latexmk -pdf -outdir=./build main.tex
mv build/main.pdf build/centrifuge-protocol.pdf
rm -f Options.tx
