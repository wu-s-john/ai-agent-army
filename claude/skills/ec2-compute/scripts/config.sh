#!/bin/bash
# Shared configuration for ec2-compute scripts.
# Adding a new region: tag its subnet + security group with project=agent-army, then add it here.

PROJECT_TAG="agent-army"
REGIONS=("us-west-2" "eu-west-1")
