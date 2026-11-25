# ~/lab-checkov/terraform/main.tf
# Versi setelah remediasi (Lab 03, Perbaikan 1-5) + hardening lanjutan (Lab 06)

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

# PERBAIKAN 1: S3 Bucket aman
resource "aws_s3_bucket" "data" {
  # checkov:skip=CKV_AWS_18:Bucket lab, tidak ada bucket log terpisah untuk access logging
  # checkov:skip=CKV_AWS_144:Lab satu region (ap-southeast-1), cross-region replication di luar cakupan
  # checkov:skip=CKV2_AWS_62:Belum ada SNS/SQS tujuan event notification di lab ini
  bucket = "my-company-data-bucket-secure"
}

# Hardening lanjutan: lifecycle untuk versi objek lama
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "hapus-versi-lama"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Blokir seluruh akses publik
resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Aktifkan enkripsi server-side dengan KMS
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Aktifkan versioning
resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

# PERBAIKAN 2: Security Group terbatas
resource "aws_security_group" "web" {
  name        = "web-sg"
  description = "Security group untuk web server"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "SSH akses terbatas dari internal network"
  }

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.10.0.0/16"]
    description = "MySQL akses terbatas dari subnet aplikasi"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
    description = "Outbound terbatas ke jaringan internal"
  }
}

# PERBAIKAN 3: IAM Policy dengan prinsip least privilege
resource "aws_iam_policy" "s3_read_only" {
  name        = "s3-read-only-policy"
  description = "Read-only access ke S3 bucket tertentu"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::my-company-data-bucket-secure",
          "arn:aws:s3:::my-company-data-bucket-secure/*"
        ]
      }
    ]
  })
}

# PERBAIKAN 4: Variable sensitif & RDS yang aman
variable "db_password" {
  description = "Password untuk database RDS"
  type        = string
  sensitive   = true
}

resource "aws_db_instance" "main" {
  identifier                = "mydb-secure"
  engine                    = "mysql"
  engine_version            = "8.0"
  instance_class            = "db.t3.micro"
  allocated_storage         = 20
  username                  = "admin"
  password                  = var.db_password
  publicly_accessible       = false
  storage_encrypted         = true
  deletion_protection       = true
  backup_retention_period   = 7
  skip_final_snapshot       = false
  final_snapshot_identifier = "mydb-final-snapshot"

  # Hardening lanjutan
  multi_az                            = true
  auto_minor_version_upgrade          = true
  copy_tags_to_snapshot               = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["audit", "error", "general", "slowquery"]

  # checkov:skip=CKV_AWS_118:Enhanced monitoring butuh IAM role monitoring terpisah, belum dibuat di lab
}

# PERBAIKAN 5: EC2 dengan EBS terenkripsi & IMDSv2
resource "aws_instance" "web" {
  # checkov:skip=CKV2_AWS_41:Instance lab tidak memanggil API AWS sehingga belum butuh instance profile
  ami                    = "ami-0c02fb55956c7d316"
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.web.id]
  monitoring             = true
  ebs_optimized          = true

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  metadata_options {
    http_tokens = "required"
  }
}
