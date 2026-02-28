terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "your_ip" {
  description = "Your local IP address for SSH access"
  type        = string
  default     = "96.231.241.237/32"
}

variable "github_repo" {
  description = "Your forked GitHub repo URL"
  type        = string
  default     = "https://github.com/aeonlevy/anomaly-detection.git"
}

variable "key_name" {
  description = "Your EC2 key pair name"
  type        = string
  default     = "ds5220-anomaly-key"
}

variable "ami_id" {
  description = "Ubuntu 24.04 LTS AMI ID"
  type        = string
  default     = "ami-0ec10929233384c7f"
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "anomaly-detection-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "anomaly_bucket" {
  bucket = local.bucket_name
}

resource "aws_sns_topic" "anomaly_topic" {
  name = "ds5220-dp1"
}

resource "aws_sns_topic_policy" "anomaly_topic_policy" {
  arn = aws_sns_topic.anomaly_topic.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.anomaly_topic.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3:::${local.bucket_name}"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.anomaly_bucket.id

  topic {
    topic_arn     = aws_sns_topic.anomaly_topic.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sns_topic_policy.anomaly_topic_policy]
}

resource "aws_sns_topic_subscription" "anomaly_subscription" {
  topic_arn              = aws_sns_topic.anomaly_topic.arn
  protocol               = "http"
  endpoint               = "http://${aws_eip.anomaly_eip.public_ip}:8000/notify"
  endpoint_auto_confirms = true
}

resource "aws_iam_role" "ec2_role" {
  name = "anomaly-detection-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_s3_policy" {
  name = "S3BucketAccess"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.anomaly_bucket.arn,
          "${aws_s3_bucket.anomaly_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "anomaly-detection-instance-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_security_group" "anomaly_sg" {
  name        = "anomaly-detection-sg"
  description = "Anomaly Detection Security Group"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "anomaly_instance" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.anomaly_sg.id]

  root_block_device {
    volume_size = 16
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e
    export BUCKET_NAME="${local.bucket_name}"
    echo "BUCKET_NAME=${local.bucket_name}" >> /etc/environment
    apt-get update -y
    apt-get install -y git python3 python3-pip python3-venv
    git clone ${var.github_repo} /opt/anomaly-detection
    cd /opt/anomaly-detection
    python3 -m venv /opt/anomaly-detection/venv
    /opt/anomaly-detection/venv/bin/pip install --upgrade pip
    /opt/anomaly-detection/venv/bin/pip install -r /opt/anomaly-detection/requirements.txt
    touch /opt/anomaly-detection/app.log
    nohup /opt/anomaly-detection/venv/bin/fastapi run \
      /opt/anomaly-detection/app.py \
      --host 0.0.0.0 \
      --port 8000 \
      >> /opt/anomaly-detection/startup.log 2>&1 &
  EOF

  tags = {
    Name = "anomaly-detection-instance"
  }
}

resource "aws_eip" "anomaly_eip" {
  instance = aws_instance.anomaly_instance.id
  domain   = "vpc"
}

output "public_ip" {
  value       = aws_eip.anomaly_eip.public_ip
  description = "Your EC2 public Elastic IP address"
}

output "bucket_name" {
  value       = aws_s3_bucket.anomaly_bucket.id
  description = "Your S3 bucket name"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.anomaly_topic.arn
  description = "Your SNS topic ARN"
}

output "api_endpoint" {
  value       = "http://${aws_eip.anomaly_eip.public_ip}:8000"
  description = "Your FastAPI base URL"
}
