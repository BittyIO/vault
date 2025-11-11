#!/bin/bash

rm -rf ./coverage && forge -vvv coverage --ir-minimum --no-match-coverage 'test|node_modules|script' --report lcov && genhtml lcov.info --branch-coverage --output-dir coverage --ignore-errors inconsistent