#!/bin/bash
swift build -c release -Xswiftc -static-stdlib
strip .build/release/BearNanny
cp -p .build/release/BearNanny bin/BearNanny
