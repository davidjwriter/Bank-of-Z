#!/bin/env bash

# Location of the configured CBS scripts on USS - https://github.com/IBM/dbb/tree/main/Templates/Common-Backend-Scripts
# Not yet used
export PIPELINE_SCRIPTS=/u/dbehm/git/dbb/Templates/Common-Backend-Scripts

# Pipeline Workspace / use a shared folder/zfs
export PIPELINE_WORKSPACE=/u/dbehm/git/workspace

# Adding pipeline scripts to PATH of the user running this script
export PATH=$PIPELINE_SCRIPTS:$PATH
export TMPHLQ="DBEHM"

# Using a timestamp to simulate the buildIdentifier and unique workspace
timestamp=$(date +%F_%H-%M-%S)
rc=0

# Use later when the repository is migrated to Github
#gitRepository=https://github.com/dennis-behm/base.git
branchName="main"
application="MortgageApplication"

# Define workspace
workspaceDir=$PIPELINE_WORKSPACE/$application/build-$timestamp
mkdir -p workspaceDir

# This script simulates the entire pipeline process (clone, build, package & deploy)

# 
if [ $rc -eq 0 ]; then
   
    # Take a copy of the existing MortgageApplication / will be replaced by cloning
    mkdir -p $workspaceDir/$application
    cp -R /u/dbehm/git/MortgageApplication $workspaceDir/
    rc=$?
    
    # For later use
    #gitClone.sh -w $workspaceDir -r $gitRepository -b $branchName
fi


if [ $rc -eq 0 ]; then
    
    # Set the DBB environment variables
    export DBB_HOME=/usr/lpp/dbb/v3r0/
    export PATH=$DBB_HOME:$PATH
    export DBB_BUILD=/u/dbehm/git/build-lc
    
    # Run build
    cd $workspaceDir/$application
    dbb build full --hlq DBEHM.BASE.MORT.BLD --verbose
    rc=$?
    
    # For later use
    #zBuilder.sh -w $workspaceDir -a $application -b $branchName -p build -v -t 'full'
    
fi

echo "Build completed in $workspaceDir with rc:$rc"

exit

### NOT in use yet, can be activated/customized later, once we have the Common Backend scripts configured

if [ $rc -eq 0 ]; then
    packageBuildOutputs.sh -w $workspaceDir -a $application -b main -p build -i $timestamp -r $timestamp -u
    rc=$?
fi

exit

if [ $rc -eq 0 ]; then
    wazideploy-generate.sh -w  $application/$branchName/${buildImplementation}build_$timestamp -a $application -b $branchName -P release -R $release -I $timestamp
    rc=$?
fi
