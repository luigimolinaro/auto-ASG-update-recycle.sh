#!/bin/bash
#Luigi Molinaro - luigi.molinaro@neen.it
if [ "$#" -lt 2 ]; then
	echo "Expected at least 2 parameters"
	echo "Example : ./auto-ASG-update-recycle.sh ASG-05012021 i-0cf332417a5b81a82 [--deregister]" 
else
	#Some Variabiles
	export ASG_NAME="$1"
	export INSTANCE_ID="$2"
	export DATETODAY=$(date +%d%m%Y)
	export DEREGISTER="$3"

	#Imposto output text
	alias aws=''`which aws`' --output text'

	#FIX BUG 
	shopt -s expand_aliases

	# Get launch configuration name from ASG_NAME
	export LC_NAME="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query 'AutoScalingGroups[].LaunchConfigurationName')"
	export NEW_LC_NAME="$(echo $LC_NAME | sed 's/-.*//')"-"$DATETODAY"-"$RANDOM"
	#GET IMAGEID to deregister
	export OLD_AMI=$(aws autoscaling describe-launch-configurations --launch-configuration-names $LC_NAME --query 'LaunchConfigurations[].ImageId')

	if [ ! -z "$INSTANCE_ID" ]; then
		echo "Using $INSTANCE_ID instead of random instance."
		export RANDOM_INST_ID="$INSTANCE_ID"
	else
		# Get 1 random instance ID from the list of instances running under ASG_NAME
		echo "Using any random instance from $ASG_NAME ASG."
		export RANDOM_INST_ID="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query 'AutoScalingGroups[].Instances[?HealthStatus==`Healthy`].InstanceId' | tr -s '\t' '\n' | shuf -n 1)";
	fi
	if [ -z "$RANDOM_INST_ID" ]; then
		echo "No instances running in this ASG; Quitting"
		exit 1
	else
		# Create AMI from the Instance without reboot
		export AMI_ID="$(aws ec2 create-image --instance-id $RANDOM_INST_ID --name "$ASG_NAME"-"$DATETODAY"-"$RANDOM" --no-reboot)"

		if [ ! -z "$AMI_ID" ]; then
			# Wait for image to complete
			while true; do
				export AMI_STATE="$(aws ec2 describe-images --filters Name=image-id,Values="$AMI_ID" --query 'Images[*].State')"
				if [ "$AMI_STATE" == "available" ]; then
					# Extract existing launch configuration
					aws autoscaling describe-launch-configurations --launch-configuration-names "$LC_NAME" --output json --query 'LaunchConfigurations[0]' > /tmp/"$LC_NAME".json

					# Remove unnecessary and empty entries from the launch configuration JSON and fill up with latest AMI ID
					cat /tmp/"$LC_NAME".json | \
						jq 'walk(if type == "object" then with_entries(select(.value != null and .value != "" and .value != [] and .value != {} and .value != [""] )) else . end )' | \
						jq 'del(.CreatedTime, .LaunchConfigurationARN, .BlockDeviceMappings)' | \
						jq ".ImageId = \"$AMI_ID\" | .LaunchConfigurationName = \"$NEW_LC_NAME\"" > /tmp/"$NEW_LC_NAME".json

					# Create new launch configuration with new name
					if [ -z "$(jq .UserData /tmp/$LC_NAME.json --raw-output)" ]; then
						aws autoscaling create-launch-configuration --cli-input-json file:///tmp/"$NEW_LC_NAME".json
					else
						aws autoscaling create-launch-configuration --cli-input-json file:///tmp/"$NEW_LC_NAME".json --user-data file://<(jq .UserData /tmp/"$NEW_LC_NAME".json --raw-output | base64 --decode)
					fi

					# Update autoscaling group with new launch configuration
					aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --launch-configuration-name "$NEW_LC_NAME"

					# Resetting aws binary alias
					unalias aws
					break
				fi
				echo "AMI creation still under progress. Retrying in 15 seconds..."
				sleep 15
			done
			if [ ! -z "$DEREGISTER" ]; then
				# Deregistering OLD AMI
				echo "Deregistering $OLD_AMI"
				aws ec2 deregister-image --image-id $OLD_AMI
				# Removing OLD LC
				Deleting OLD launch configuration $LC_NAME
				aws autoscaling delete-launch-configuration --launch-configuration-name $LC_NAME
			fi	
		else
			echo "Error creating AMI"
			exit 1
		fi
	fi
fi
