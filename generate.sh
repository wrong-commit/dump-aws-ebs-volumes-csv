# Generate a CSV file for all mounted EBS volumes, 
# including partition information
# QP:2025

AWS_PROFILE_NAME=rh-legacy

# Query EC2 API for instance, snapshot and volume information
aws ec2 describe-instances --profile=$AWS_PROFILE_NAME > instances.json
aws ec2 describe-volumes --profile=$AWS_PROFILE_NAME > volumes.json
aws ec2 describe-snapshots --profile=$AWS_PROFILE_NAME > snapshots.json

# List all instance IDs
AWS_VMS=$(jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .InstanceId' instances.json)
readarray -t AWS_VMS_ARRAY <<< $(echo -e "${AWS_VMS}")

# Print CSV Header 
print_csv_headers 
for EC2_VM in "${AWS_VMS_ARRAY[@]}"
do
	# Process EC2
	EC2_VM_PARTIION_DATA=$(run_ec2 "$EC2_VM")
	# Output CSV lines 
	echo "$EC2_VM_PARTIION_DATA"
done

# Process a single EC2 VM instance ID 
# 1. Prompt user for `lsblk` and `df` outputs from remote server
# 2. Iterate volumes attached to each VM
# 3. Nitro vs Xen. Map volume to partition through Serial Number or device name
# 4. Format df outputs to match each partition 
# 5. Combine root partition and root device into one partition in output 
# 6. Print output CSV to stdout 
function run_ec2 () { 
	EC2_VM="$1"
	EC2_VM_NAME=$(jq -r ".Reservations[].Instances[] | select(.InstanceId == \"$EC2_VM\") | .Tags[] | select(.Key == \"Name\") | .Value" instances.json)

	# Create lsblk.txt and df.txt for recording EC2 volume information
	create_ssh_text_files "$EC2_VM" "$EC2_VM_NAME"

	# Ensure df.txt and lsblk.txt are populated
	vim + -o /tmp/lsblk-$1.txt >/dev/tty
	if [[ $(cat /tmp/lsblk-$1.txt | grep -v "#" | wc -l) -eq 1 ]]; then 
		echo "No lsblk-$1.txt provided, skipping VM $EC2_VM"
		exit 0
	fi 
	vim + -o /tmp/df-$1.txt >/dev/tty
	if [[ $(cat /tmp/df-$1.txt | grep -v "#" | wc -l) -eq 1 ]]; then 
		echo "No df-$1.txt provided, skipping VM $EC2_VM"
		exit 0
	fi 

	# List just the information desired from volumes.json for instance
	VOLUME_INFORMATION=$(jq -c ".Volumes[] | select(.Attachments[].InstanceId == \"$EC2_VM\") | [.Size,.Attachments[].VolumeId,.Attachments[].Device,.Attachments[].State]" volumes.json )

	readarray -t VOLUME_INFORMATION_ARRAY <<< $(echo -e "${VOLUME_INFORMATION}")
	for VOLUME_INFO in "${VOLUME_INFORMATION_ARRAY[@]}"
	do
		# AWS Volume ID
		VOLUME_ID=$(echo "$VOLUME_INFO" | jq -r .[1])
		VOLUME_ID_FLAT=$(echo $VOLUME_ID | sed "s/-//")
		# AWS Volume Size
		VOLUME_SIZE=$(echo $VOLUME_INFO | jq -r .[0])
		# AWS Volume Name (needs to be mapped to correct device on the OS)
		VOLUME_NAME=$(echo $VOLUME_INFO | jq -r .[2])

		# Handle Nitro vs Xen systems
		if [[ $(cat /tmp/lsblk-$1.txt | grep nvme | wc -l) -gt 0 ]]; then
			NVME_DATA=$(cat /tmp/lsblk-$1.txt | grep $VOLUME_ID_FLAT)
			OS_DISK_NAME=$(echo $NVME_DATA | awk '{print $1}')
			# OS_DISK_NAME should contain nvme0n1
			# Check if OS Disk is root device 
			if [[ $(echo $NVME_DATA | awk '{print NF}') == 3 ]]; then 
				# echo NVME Root Device found, looking for remaining partition data
				NVME_WWN=$(echo $NVME_DATA | awk '{print $3}')
				# Look up NVME Root Device Partition by WWN 
				OTHER_NVME_DATA=$(cat /tmp/lsblk-$1.txt | grep $NVME_WWN)
				# Get partition (below disk) in lsblk output
				OS_DISK_NAME=$(echo "$OTHER_NVME_DATA" | awk '{print $1}' | tail -n 1)
			fi
			LSBLK_DISK_NAME=/dev/$OS_DISK_NAME
		else 
			# Convert volume name into OS lsblk output
			OS_DISK_NAME=$(convert_aws_to_xen $VOLUME_NAME)
			LSBLK_DISK_NAME=$(convert_xen_to_lsblk $VOLUME_NAME)
		fi 

		# Get Partition Information from lsblk.txt 
		OS_VOLUME_FS=$(cat /tmp/lsblk-$1.txt | grep $LSBLK_DISK_NAME | awk '{print $2}')
		
		# Get Partition Information from df.txt
		OS_VOLUME_MOUNTPOINT=$(cat /tmp/df-$1.txt | grep $OS_DISK_NAME | awk '{print $6}')
		OS_VOLUME_SIZE=$(cat /tmp/df-$1.txt | grep $OS_DISK_NAME | awk '{print $2}')
		OS_VOLUME_USED=$(cat /tmp/df-$1.txt | grep $OS_DISK_NAME | awk '{print $3}')
		OS_VOLUME_FREE=$(cat /tmp/df-$1.txt | grep $OS_DISK_NAME | awk '{print $4}')
		OS_VOLUME_PERCENT=$(cat /tmp/df-$1.txt | grep $OS_DISK_NAME | awk '{print $5}')
		
		# Get Snapshot Information 
		SNAPSHOTS_COUNT=$(jq ".Snapshots[] | select(.VolumeId == \"$VOLUME_ID\") | length" snapshots.json | wc -l)
		# Sum all snapshot sizes into one integer
		SNAPSHOTS_SIZE=$(jq ".Snapshots[] | select(.VolumeId == \"$VOLUME_ID\") | .VolumeSize" snapshots.json | awk '{s+=$1} END {printf "%.0f", s}')
		
		# Print CSV 
		CSV=$(echo -n $EC2_VM,)
		CSV+=$(echo -n $EC2_VM_NAME,)
		CSV+=$(echo -n $VOLUME_ID,)
		CSV+=$(echo -n $VOLUME_NAME,)
		CSV+=$(echo -n $VOLUME_SIZE,)
		CSV+=$(echo -n $OS_DISK_NAME,)
		CSV+=$(echo -n $OS_VOLUME_FS,)
		CSV+=$(echo -n $OS_VOLUME_MOUNTPOINT,)
		CSV+=$(echo -n $OS_VOLUME_SIZE,)
		CSV+=$(echo -n $OS_VOLUME_USED,)
		CSV+=$(echo -n $OS_VOLUME_FREE,)
		CSV+=$(echo -n $OS_VOLUME_PERCENT,)
		CSV+=$(echo -n $SNAPSHOTS_COUNT,)
		CSV+=$(echo $SNAPSHOTS_SIZE)
		CSV+=$(echo "")
		echo "$CSV"
	done
}

# Prompt for lsblk and df output using specially crafted commands
# lsblk outputs SERIAL as that provides us the AWS volume ID
# lsblk outputs WWN for effectively linking root device and partition 
# df outputs in GB format for the CSV
# The output of each command is in the /tmp directory, allowing for the 
# command to be rerun more easily. 
function create_ssh_text_files () { 
	EC2_VM="$1"
	EC2_VM_NAME="$2"
	if [[ ! -f /tmp/lsblk-$1.txt ]]; then 
		echo "# Run the command"  > /tmp/lsblk-$1.txt
		echo "# lsblk -l -f -o NAME,FSTYPE,MOUNTPOINT,SERIAL,WWN | grep -v squashfs"  >> /tmp/lsblk-$1.txt 
		echo "# on $EC2_VM - $EC2_VM_NAME" >> /tmp/lsblk-$1.txt
		echo "" >> /tmp/lsblk-$1.txt
	fi
	if [[ ! -f /tmp/df-$1.txt ]]; then 
		echo "# Run the command" > /tmp/df-$1.txt
		echo "# df -B G on $EC2_VM - $EC2_VM_NAME" >> /tmp/df-$1.txt
		echo "" >> /tmp/df-$1.txt
	fi 
}

# Convert /dev/sda1 into /dev/xvda1
function convert_aws_to_xen () { 
	#echo "AWS Volume Name = $1"
	echo "$1" | sed "s/\/dev\/sd/\/dev\/xvd/"
}

# Convert /dev/xvda1 into xvda1
function convert_xen_to_lsblk () { 
	#echo "AWS Volume Name = $1"
	echo "$1" | sed "s/\/dev\/sd/xvd/"
}

# Print CSV headers
function print_csv_headers () { 
	echo -n "EC2_ID,EC2_NAME,VOLUME_ID,AWS_VOLUME_NAME,AWS_VOLUME_SIZE,"
	echo -n "OS_VOLUME_NAME,OS_VOLUME_FS,OS_VOLUME_MOUNTPOINT,OS_VOLUME_SIZE,OS_VOLUME_USED,OS_VOLUME_FREE,"
	echo "OS_VOLUME_PERCENT,SNAPSHOTS_COUNT,SNAPSHOTS_SIZE"
}

