#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Define AWS-related variables at the top of the script
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-""}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-""}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-west-2}
INSTANCE_TYPE=${INSTANCE_TYPE:-i7ie.12xlarge}
# AMI_ID=${AMI_ID:-}
AMI_ID=${AMI_ID:-}
KEY_NAME=${KEY_NAME:-workshops}
SECURITY_GROUP=${SECURITY_GROUP:-}
SUBNET_ID=${SUBNET_ID:-}

# Function to display help message
function print_help() {
  echo "Usage: $0 [create|list|delete|stop|help] [options]"
  echo "Commands:"
  echo "  create [count] [user_data_file]  Create the specified number of EC2 instances (default: 2). Optionally provide a user data file."
  echo "  list                          List all running EC2 instances created by this script."
  echo "  delete [instance_id]          Delete a specific EC2 instance by ID, or all created instances if no ID is provided."
  echo "  stop [instance_id]            Stop a specific EC2 instance by ID, or all running instances created by this script if no ID is provided."
  echo "  help                          Show this help message."
  echo "Environment Variables:"
  echo "  INSTANCE_TYPE                EC2 instance type (default: i7ie.12xlarge)"
  echo "  AMI_ID                       AMI ID to use (default: ami-0b98f8942a2a82745)"
  echo "  KEY_NAME                     Key pair name (default: workshops)"
  echo "  SECURITY_GROUP               Security group ID (default: sg-05325210e8f304f8d)"
  echo "  SUBNET_ID                    Subnet ID (default: subnet-071fd0ba5b5b610d5)"
}

# Function to display instance information in a clean table
function display_instances_table() {
  echo -e "\nInstance Information:"
  echo "---------------------------------------------"
  printf "| %-15s | %-15s | %-20s |\n" "Instance ID" "Public IP" "Name"
  echo "---------------------------------------------"

  for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Name" --query "Tags[0].Value" --output text)
    printf "| %-15s | %-15s | %-20s |\n" "$INSTANCE_ID" "$PUBLIC_IP" "$NAME"
  done

  echo "---------------------------------------------"
}

# Function to create EC2 instances
function create_instances() {
  local count=${1:-2}
  local user_data_file=${2:-}

  echo "Creating $count EC2 instance(s)..."

  INSTANCE_IDS=()
  PUBLIC_IPS=()

  for ((i=1; i<=count; i++)); do
    INSTANCE_NAME="workshop_instance$i"

    # Check if an instance with the desired name already exists
    EXISTING_INSTANCE_ID=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text)

    if [ -n "$EXISTING_INSTANCE_ID" ]; then
      echo "Instance with name $INSTANCE_NAME already exists (ID: $EXISTING_INSTANCE_ID). Fetching details..."
      PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $EXISTING_INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
      INSTANCE_IDS+=("$EXISTING_INSTANCE_ID")
      PUBLIC_IPS+=("$PUBLIC_IP")
      printf "%-20s %-15s\n" "$INSTANCE_NAME" "$PUBLIC_IP"
      continue
    fi

    # Add user data if provided
    if [ -n "$user_data_file" ]; then
      USER_DATA_OPTION="--user-data file://$user_data_file"
    else
      USER_DATA_OPTION=""
    fi

    INSTANCE_ID=$(aws ec2 run-instances \
      --image-id $AMI_ID \
      --count 1 \
      --instance-type $INSTANCE_TYPE \
      --key-name $KEY_NAME \
      --security-group-ids $SECURITY_GROUP \
      ${SUBNET_ID:+--subnet-id $SUBNET_ID} \
      $USER_DATA_OPTION \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
      --query 'Instances[0].InstanceId' \
      --output text)

    if [ -z "$INSTANCE_ID" ]; then
      echo "Failed to create instance $i. Exiting."
      exit 1
    fi

    INSTANCE_IDS+=("$INSTANCE_ID")
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    PUBLIC_IPS+=("$PUBLIC_IP")
    echo "Created instance $INSTANCE_NAME with Public IP: $PUBLIC_IP"
  done

  echo "Waiting for instances to be running..."
  aws ec2 wait instance-running --instance-ids ${INSTANCE_IDS[@]}
  echo "All instances are now running."

  # Display instance information in a table
  display_instances_table
}

# Function to list EC2 instances
function list_instances() {
  echo "Listing all EC2 instances created by this script (workshop_instance*)..."

  # Fetch all instances with the specific tag pattern and format the output
  INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=workshop_instance*" \
    --query "Reservations[].Instances[].{InstanceID: InstanceId, PublicIP: PublicIpAddress, Name: Tags[?Key=='Name'] | [0].Value, Status: State.Name}" \
    --output json)

  # Print table header
  echo -e "\nInstance Information:"
  echo "--------------------------------------------------------------------------------------"
  printf "| %-19s | %-16s | %-30s | %-12s |\n" "Instance ID" "Public IP" "Name" "Status"
  echo "--------------------------------------------------------------------------------------"


  # Use jq to parse, sort by Name, and print each instance row (tab-separated), then format with bash
  echo "$INSTANCES" | jq -r 'sort_by(.Name | sub("workshop_instance"; "") | tonumber) | .[] | [.InstanceID, (.PublicIP // "NA"), .Name, .Status] | @tsv' | while IFS=$'\t' read -r id ip name status; do
    printf "| %-18s | %-16s | %-30s | %-12s |\n" "$id" "$ip" "$name" "$status"
  done

  echo "--------------------------------------------------------------------------------------"
}

# Function to delete EC2 instances
function delete_instances() {
  if [ -n "$1" ]; then
    # Delete a specific instance
    INSTANCE_ID=$1

    # Check if the instance exists and is in the running state
    INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null)
    if [ "$INSTANCE_STATE" != "running" ]; then
      echo "Instance $INSTANCE_ID is not in a running state (current state: $INSTANCE_STATE)."
      return
    fi

    echo "Stopping instance with ID: $INSTANCE_ID..."
    aws ec2 stop-instances --instance-ids $INSTANCE_ID
    echo "Waiting for the instance to stop..."
    aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID
    echo "Instance $INSTANCE_ID has been stopped."

    echo "Deleting instance with ID: $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID
    echo "Terminate command sent for instance: $INSTANCE_ID"
    echo "Waiting for the instance to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
    echo "Instance $INSTANCE_ID has been terminated."
  else
    # Delete all created instances
    echo "Stopping all created EC2 instances..."
    INSTANCE_IDS=($(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=workshop_instance*" "Name=instance-state-name,Values=running" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text))

    if [ -z "$INSTANCE_IDS" ]; then
      echo "No running instances found to delete."
      return
    fi

    aws ec2 stop-instances --instance-ids ${INSTANCE_IDS[@]}
    echo "Waiting for all instances to stop..."
    aws ec2 wait instance-stopped --instance-ids ${INSTANCE_IDS[@]}
    echo "All instances have been stopped."

    echo "Deleting all created EC2 instances..."
    aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS[@]}
    echo "Terminate command sent for: ${INSTANCE_IDS[@]}"
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids ${INSTANCE_IDS[@]}
    echo "All instances have been terminated."
  fi
}

# Function to stop EC2 instances
function stop_instances() {
  if [ -n "$1" ]; then
    # Stop a specific instance
    INSTANCE_ID=$1

    # Check if the instance exists, is in the running state, and was created by this script
    INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null)
    INSTANCE_NAME=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].Tags[?Key=='Name'].Value" --output text 2>/dev/null)
    if [[ "$INSTANCE_STATE" != "running" || "$INSTANCE_NAME" != workshop_instance* ]]; then
      echo "Instance $INSTANCE_ID is either not in a running state or was not created by this script."
      return
    fi

    echo "Stopping instance with ID: $INSTANCE_ID..."
    aws ec2 stop-instances --instance-ids $INSTANCE_ID
    echo "Waiting for the instance to stop..."
    aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID
    echo "Instance $INSTANCE_ID has been stopped."
  else
    # Stop all running instances created by this script
    echo "Stopping all running EC2 instances created by this script..."
    INSTANCE_IDS=($(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=workshop_instance*" "Name=instance-state-name,Values=running" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text))

    if [ -z "$INSTANCE_IDS" ]; then
      echo "No running instances found to stop."
      return
    fi

    aws ec2 stop-instances --instance-ids ${INSTANCE_IDS[@]}
    echo "Waiting for all instances to stop..."
    aws ec2 wait instance-stopped --instance-ids ${INSTANCE_IDS[@]}
    echo "All instances created by this script have been stopped."
  fi
}

# Function to configure AWS CLI
function configure_aws() {
  echo "Configuring AWS CLI..."
  read -p "Enter AWS Access Key ID: " AWS_ACCESS_KEY_ID
  read -p "Enter AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
  read -p "Enter Default Region: " AWS_DEFAULT_REGION

  aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
  aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
  aws configure set default.region $AWS_DEFAULT_REGION

  echo "AWS CLI configured successfully."
}

# Main script logic
if [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
  print_help
  exit 0
fi

case "$1" in
  configure)
    configure_aws
    ;;
  create)
    create_instances "$2" "$3"
    ;;
  list)
    list_instances
    ;;
  delete)
    delete_instances "$2"
    ;;
  stop)
    stop_instances "$2"
    ;;
  *)
    echo "Invalid command. Use 'help' for usage information."
    exit 1
    ;;
esac
