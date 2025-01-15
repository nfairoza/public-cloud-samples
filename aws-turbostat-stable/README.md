# Turbostat Hardware Feature Visibility on AWS EC2 Instances

## Overview
On AWS EC2 instances, hardware feature visibility is limited by virtualization. The level of access to hardware metrics and features varies based on the instance type and virtualization layer.

## Instance Types and Hardware Access

### Bare Metal Instances
* Instances like `m7a.metal` and `c7a.metal` provide direct access to hardware, offering more detailed metrics and features
* Full visibility into hardware capabilities and performance counters

### Virtualized Instances
* Non-bare-metal instances have limited access to hardware features
* Many hardware features are abstracted or hidden by the AWS hypervisor
* Access to MSRs (Model-Specific Registers) may be restricted

## Available Performance Metrics on Virtualized/EC2 Instances

### Core Metrics
* **Avg_MHz**: Average processor frequency
* **Busy%**: CPU utilization percentage
* **Bzy_MHz**: Processor frequency during active periods
* **TSC_MHz**: Time Stamp Counter frequency
* **IPC**: Instructions Per Cycle
* **IRQ**: Interrupt count statistics

### Power Management States
* **POLL%**: Time spent in polling state
* **C1%**: Time in light sleep state
* **C2%**: Time in deeper sleep state (values over 99% indicate system idling)

## Instance Profile Configuration

The EC2 instance running the CPU monitoring stack requires IAM permissions to interact with AWS services (CloudWatch, EC2, and Systems Manager):
- cloudwatch:PutMetricData
- ec2:DescribeInstances
- ec2:DescribeInstanceStatus
- ec2:MonitorInstances
- ssm:SendCommand
- ssm:GetCommandInvocation
- ssm:UpdateInstanceInformation
- ssm:UpdateAssociationStatus
- ssm:DescribeAssociation
- ssm:GetDocument

## Notes: Limitations

```bash
CPUID(6): APERF, No-TURBO, No-DTS, No-PTM, No-HWP, No-HWPnotify, No-HWPwindow, No-HWPepp, No-HWPpkg, No-EPB
```
This shows many hardware power management features are not exposed to the EC2 VM by design.

Even though the AMD EPYC processor physically supports more C-states (C3-C6), the AWS hypervisor abstracts these away and presents a simplified model with just POLL, C1, and C2.

These limitations are intentional design choices in the AWS virtualization infrastructure.

Please note the "AWS/EC2" CPUUtilization metric in widget 2 in the cloudwatch dashboard continues to appear even after our turbostat script exits because it's a default EC2 metric that Amazon provides automatically for all EC2 instances.

## Deployment Command
Please replace `<your_instance_id>` with your EC2 instance ID from the AWS console and `<your_timeout_duration>` with timeout duration in minutes. If this parameter is not given default is 30 minutes.

```bash
aws cloudformation create-stack --stack-name cpu-stress-test-stable --template-body file://turbostat.yaml --parameters ParameterKey=TargetInstanceId,ParameterValue=<your_instance_id> ParameterKey=MonitoringTimeout,ParameterValue=<your_timeout_duration> --capabilities CAPABILITY_IAM
```
## Get Coudformation output from CLI
```bash
aws cloudformation wait stack-create-complete \
    --stack-name cpu-stress-test-stable && \
aws cloudformation describe-stacks \
    --stack-name cpu-stress-test-stable \
    --query 'Stacks[0].Outputs[*]' \
    --output text
```

## Stress Testing Commands
Please ignore this if you are testing using your own application.
I have used M7a.24XL and used stress-ng to simulate load with following commands.

```bash
#  OPTIONAL stress test for 10 min
sudo sudo stress-ng --cpu 96 --cpu-load 100 --cpu-method matrixprod --timeout 10m &

# Stop stress test
sudo pkill stress-ng
```

## SSM Agent Management
If you started the CloudFormation without the IAM role and then attached it later, please restart the SSM agent to refresh the credentials:
```bash
sudo systemctl restart amazon-ssm-agent
sudo systemctl status amazon-ssm-agent
```

## Sample CPU Dashboard

![Alt text](/aws-turbostat-stable/example.png)

## Cleanup Instructions
### CloudFormation Stack Cleanup
To clean up all resources created by this template, run the following command.

```bash
aws cloudformation delete-stack --stack-name cpu-stress-test-stable && aws cloudformation wait stack-delete-complete --stack-name cpu-stress-test-stable
```
