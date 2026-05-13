# VPC Baseline

Provisions a VPC with public/private subnets across multiple Availability Zones.

## Features

- Custom VPC CIDR
- Public and private subnets across 2-3 AZs
- Internet Gateway for public subnets
- NAT Gateways (configurable) for private subnets
- VPC Flow Logs to CloudWatch (configurable)
- Route tables with proper associations
- DNS hostnames and resolution enabled

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| VpcCIDR | 10.0.0.0/16 | VPC CIDR block |
| AvailabilityZoneCount | 3 | Number of AZs (2 or 3) |
| EnableNATGateways | Yes | Deploy NAT gateways |
| EnableFlowLogs | Yes | Enable Flow Logs |

## TODO

- [ ] Implement VPC resource
- [ ] Implement subnets (public/private per AZ)
- [ ] Implement Internet Gateway
- [ ] Implement NAT Gateways
- [ ] Implement route tables and associations
- [ ] Implement VPC Flow Logs
- [ ] Add parameter files for dev/qa/uat/prod
