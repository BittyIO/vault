#!/bin/bash

rm -rf ./coverage && forge coverage --ir-minimum --no-match-coverage 'test|node_modules|script|src/libs' --report lcov --lcov-version '5.2.0' && genhtml lcov.info --branch-coverage --output-dir coverage --ignore-errors inconsistent